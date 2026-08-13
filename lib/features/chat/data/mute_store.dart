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

  /// Every mute [userId] holds, as `target → ids`. A missing or corrupt payload
  /// reads as empty sets (self-heals on the next write) — a lost mute costs a
  /// badge reappearing, which the user can see and redo, so failing OPEN here is
  /// strictly safer than failing closed on state we cannot repair.
  Map<MuteTarget, Set<String>> readAll(String userId) {
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
    } on FormatException {
      return empty; // corrupt JSON — the next write rewrites it clean
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
    final payload = jsonEncode({
      for (final t in MuteTarget.values)
        t.jsonKey: (mutes[t] ?? const <String>{})
            .where((id) => id.isNotEmpty)
            .toList(),
    });
    final Future<void> result = _writes.then((_) async {
      // `setString` reports failure by RETURNING false, not only by throwing —
      // so awaiting it without checking makes the returned Future<void> claim a
      // success that never happened, and the divergence this method promises to
      // report would evaporate silently (cage-match #135 round 4, Carnot).
      final ok = await _prefs.setString(_key(userId), payload);
      if (!ok) throw StateError('SharedPreferences rejected the mute snapshot');
    });
    // Keep the chain alive past a failure — one persistence error must not wedge
    // every later mute. The error is REPORTED rather than swallowed: with
    // snapshot writes the next mute repairs the divergence on its own, so this is
    // a transient-divergence signal, not a corruption alarm — but a silent
    // `catchError((_) {})` would hide the only evidence it ever happened
    // (cage-match #135, Tesla).
    _writes = result.catchError((Object e, StackTrace _) {
      debugPrint('[mute] persist failed (memory ahead of disk until the next '
          'mute rewrites the snapshot): $e');
    });
    return result;
  }
}
