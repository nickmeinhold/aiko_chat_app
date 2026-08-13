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

  /// Serializes durable writes so a read-modify-write of the per-user JSON blob
  /// never interleaves with another. Chained (not awaited by callers): the
  /// in-memory notifier is the UI's fast path, disk catches up in order.
  Future<void> _writes = Future<void>.value();

  /// Add or remove [id] from [userId]'s [target] set. Unlike a read watermark
  /// this is NOT monotonic — mute and unmute are equally legitimate in both
  /// directions — so ordering, not compare-and-set, is what has to hold: the
  /// chain guarantees the last call wins on disk, never a torn intermediate.
  Future<void> setMuted(
    String userId,
    MuteTarget target,
    String id, {
    required bool muted,
  }) {
    if (id.isEmpty) return Future<void>.value();
    final result = _writes.then((_) async {
      final all = readAll(userId);
      final set = all[target]!;
      if (muted ? !set.add(id) : !set.remove(id)) return; // already in that state
      await _prefs.setString(
        _key(userId),
        jsonEncode({
          for (final t in MuteTarget.values) t.jsonKey: all[t]!.toList(),
        }),
      );
    });
    // Keep the chain alive past a failed write — one persistence error must not
    // wedge every subsequent mute.
    _writes = result.catchError((_) {});
    return result;
  }
}
