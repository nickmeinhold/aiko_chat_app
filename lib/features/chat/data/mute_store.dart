/// Per-account mute sets — the durable store behind "show me the messages, stop
/// demanding my attention".
///
/// MUTE IS NOT BLOCK. A block is a moderation act: server-enforced, mutual, and
/// the content disappears (see `moderation/`). A mute is an ATTENTION
/// preference: the messages stay fully visible and the conversation stays open —
/// only the unread badge (and, later, notifications) goes quiet. Nothing about a
/// mute is anyone else's business, so nothing about it goes to the island.
///
/// That is also why this is device-local [SharedPreferences] and not island
/// state: it needs no enforcement, no fanout, and no trust boundary. The cost,
/// named rather than hidden: a mute does NOT follow you to another device. Fold
/// it into the island only if cross-device sync is asked for.
///
/// **Per-user, one key per user**, exactly like [ChannelReadStore] and for the
/// same reason: ids are opaque server strings that may contain any character, so
/// a flat `<userId>_<targetId>` key would collide across the delimiter
/// (`(user:a, target:b_c)` and `(user:a_b, target:c)` both flatten the same).
/// Nesting the ids inside a per-user JSON value leaves the user id as the only
/// key segment, so the keyspace is injective by construction.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The two things a user can mute. Kept as an enum (not two stores) because the
/// storage, lifecycle, and per-user scoping are identical — only the id space
/// differs.
enum MuteTarget {
  /// A conversation: channel or DM. Muting it silences everything in it.
  channel('channels'),

  /// An account. Silences that sender's messages EVERYWHERE, so one noisy
  /// participant doesn't have to be muted channel by channel.
  user('users');

  const MuteTarget(this.jsonKey);

  final String jsonKey;
}

class MuteStore {
  MuteStore(this._prefs);

  final SharedPreferences _prefs;

  static const _prefix = 'aiko_muted_';

  String _key(String userId) => '$_prefix$userId';

  /// The last snapshot this store was ASKED to persist, per user — recorded
  /// synchronously by [replaceAll] and preferred by [readAll] over the encoded
  /// payload.
  ///
  /// This store is keep-alive while `mutesProvider` is `.autoDispose`, which
  /// makes it the only component that outlives every write it starts. Without
  /// this, a mute made just before the chat surface tore down could be read back
  /// STALE by the next incarnation — the notifier hydrates from a payload the
  /// queued write has not reached, publishes "unmuted", and then the in-flight
  /// write lands "muted": memory and disk in opposite phases, resurrecting a mute
  /// the user cannot see at the next launch (cage-match #135 round 8, Tesla; the
  /// same class as round 7's undo race, in the other direction).
  ///
  /// Recording the intent at CALL time rather than at completion means "what this
  /// account has muted" has exactly one answer from the moment it is decided, and
  /// disk is purely the durable copy that catches up.
  ///
  /// PRECONDITION, named because it is load-bearing (cage-match #135 round 11,
  /// Tesla): this store must be the ONLY writer of `aiko_muted_*` within the
  /// process. It is — nothing else touches that key — but if a second writer or
  /// an in-process prefs wipe ever appears, this shadow would win over the real
  /// payload for the life of the process. An out-of-process wipe (app data
  /// cleared) is safe: it takes the process with it.
  final Map<String, Map<MuteTarget, Set<String>>> _latest = {};

  /// Every mute [userId] holds, as `target → ids`. A missing or corrupt payload
  /// reads as empty sets (self-heals on the next write) — a lost mute costs a
  /// badge reappearing, which the user can see and redo, so failing OPEN here is
  /// strictly safer than failing closed on state we cannot repair.
  Map<MuteTarget, Set<String>> readAll(String userId) {
    final latest = _latest[userId];
    if (latest != null) {
      return {
        for (final t in MuteTarget.values) t: {...latest[t] ?? const {}},
      };
    }
    final empty = {for (final t in MuteTarget.values) t: <String>{}};
    final raw = _prefs.getString(_key(userId));
    if (raw == null || raw.isEmpty) return empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return empty;
      return {
        for (final t in MuteTarget.values)
          t: switch (decoded[t.jsonKey]) {
            final List<dynamic> ids => {
              for (final id in ids)
                if (id is String && id.isNotEmpty) id,
            },
            _ => <String>{},
          },
      };
    } catch (_) {
      // CATCH EVERYTHING, not just FormatException. Failing open on corrupt JSON
      // is a deliberate choice (a lost mute is a badge the user can see and redo);
      // letting any OTHER exception class escape would put `Mutes.build` into an
      // error state, and every unread surface indexes `state[MuteTarget.channel]!`
      // — so the sidebar goes down with it. Failing open on one decode path and
      // closed on the next is not a policy, it is an oversight (cage-match #135
      // round 7, Tesla).
      return empty;
    }
  }

  /// Serializes durable writes so two snapshots can never land out of order.
  /// Chained (not awaited by callers): the in-memory notifier is the UI's fast
  /// path, disk catches up behind it.
  Future<void> _writes = Future<void>.value();

  /// Persist [mutes] as the COMPLETE mute state for [userId] — a snapshot dump,
  /// deliberately NOT a read-modify-write of the stored blob.
  ///
  /// An RMW would make disk a second historian that can overrule memory: with
  /// mute A written and its `setString` failing, a later mute B would re-read a
  /// disk that never saw A and persist a world in which A does not exist. The
  /// session keeps showing both (the notifier committed them), and A silently
  /// evaporates at next login — a badge back from the dead, reachable from a
  /// SINGLE persistence error plus any later mute (cage-match #135, Tesla).
  ///
  /// Writing the caller's full map removes that coupling rather than guarding
  /// it: there is exactly one historian (the notifier's in-memory state), disk
  /// is its dump, and a failed write SELF-HEALS on the next one because that
  /// next write carries the whole truth rather than a delta onto a stale base.
  Future<void> replaceAll(String userId, Map<MuteTarget, Set<String>> mutes) {
    // Record the intent SYNCHRONOUSLY, before anything is queued, so a reader
    // arriving between now and the platform write sees what was decided rather
    // than what has landed (see [_latest]).
    _latest[userId] = {
      for (final t in MuteTarget.values) t: {...mutes[t] ?? const <String>{}},
    };
    final payload = jsonEncode({
      for (final t in MuteTarget.values)
        t.jsonKey: (mutes[t] ?? const <String>{})
            .where((id) => id.isNotEmpty)
            .toList(),
    });
    final Future<void> attempt = _writes.then((_) async {
      // `setString` reports failure by RETURNING false, not only by throwing —
      // so awaiting it without checking makes the result claim a success that
      // never happened, and the divergence this method promises to report would
      // evaporate silently (cage-match #135 round 4, Carnot).
      final ok = await _prefs.setString(_key(userId), payload);
      if (!ok) throw StateError('SharedPreferences rejected the mute snapshot');
    });
    // Keep the chain alive past a failure — one persistence error must not wedge
    // every later mute. The error is REPORTED rather than swallowed: with
    // snapshot writes the next mute repairs the divergence on its own, so this is
    // a transient-divergence signal, not a corruption alarm — but a silent
    // `catchError((_) {})` would hide the only evidence it ever happened
    // (cage-match #135, Tesla).
    final Future<void> reported = attempt.catchError((Object e, StackTrace _) {
      debugPrint(
        '[mute] persist failed (memory ahead of disk until the next '
        'mute rewrites the snapshot): $e',
      );
    });
    _writes = reported;
    // Return the REPORTED future, not the raw attempt. The only caller
    // fire-and-forgets this, so handing back a future that can still throw meant
    // the failure was logged AND rethrown into the zone as an unhandled async
    // error — running a high-voltage lead into a void and calling the spark a log
    // line (cage-match #135 round 6, Tesla). Every path now completes normally;
    // the log is the single report.
    return reported;
  }
}
