/// Per-channel last-read watermarks — the durable store behind the channel
/// switcher's unread indicators.
///
/// Deliberately the LIGHTEST durable store ([SharedPreferences]): a watermark is
/// a tiny per-channel string (the newest server ULID the user has seen in that
/// channel), non-secret, and never leaves the device — so it wants neither the
/// encrypted key store nor a drift schema migration on the shared message cache.
///
/// **Per-user, one key per user.** All of a user's watermarks live under a single
/// key `aiko_channel_lastread_<userId>` holding a JSON `{channelId: ulid}` map.
/// This keeps the keyspace INJECTIVE: channel ids are opaque server strings that
/// may contain any character (including `_`), so a `<userId>_<channelId>` flat key
/// would collide — `(user:a, chan:b_c)` and `(user:a_b, chan:c)` both flatten to
/// `..._a_b_c`. Nesting channel ids inside a per-user JSON value removes the
/// delimiter ambiguity entirely (the only key segment is the user id).
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ChannelReadStore {
  ChannelReadStore(this._prefs);

  final SharedPreferences _prefs;

  static const _prefix = 'aiko_channel_lastread_';

  String _key(String userId) => '$_prefix$userId';

  /// A watermark must be either the empty-string floor (`''`, the first-sight
  /// baseline for a channel empty at settle-time) or a full 26-char ULID. A
  /// malformed/short id would sort OFF the timeline (`compareTo` is lexicographic)
  /// and, once persisted, pin a bad monotonic floor forever — so it is rejected at
  /// the boundary, in memory AND on disk.
  static bool isSortableWatermark(String ulid) =>
      ulid.isEmpty || ulid.length == 26;

  /// Every persisted watermark for [userId], as `channelId → newest-read ULID`.
  /// The map the in-memory notifier seeds from on login / user switch. A missing
  /// or corrupt payload reads as empty (self-heals on the next write).
  Map<String, String> readAll(String userId) {
    final raw = _prefs.getString(_key(userId));
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final out = <String, String>{};
        decoded.forEach((k, v) {
          // Validate on LOAD too: a corrupt/legacy value must not enter the marks
          // map, where it would poison lexicographic comparison OR (worse) block a
          // channel's first-sight baseline forever via the `containsKey` guard.
          if (v is String && isSortableWatermark(v)) out[k.toString()] = v;
        });
        return out;
      }
    } on FormatException {
      // Corrupt JSON — treat as empty; the next setWatermark rewrites it clean.
    }
    return const {};
  }

  /// Serializes durable writes so a read-modify-write of the per-user JSON map
  /// never interleaves with another. Chained (not awaited by callers) — the
  /// in-memory notifier is the UI's fast path; disk catches up in order.
  Future<void> _writes = Future<void>.value();

  /// Persist [ulid] as [channelId]'s watermark for [userId] — MONOTONICALLY and
  /// SERIALIZED. The write is chained onto [_writes] (so concurrent advances apply
  /// in call order, never a torn read-modify-write) and is a COMPARE-AND-SET: a
  /// [ulid] not strictly greater than the persisted one is dropped. Together these
  /// guarantee the durable value never goes backwards — even if two rapid advances
  /// (e.g. `…0B` then `…0C`) are issued/complete out of order, a cold restart
  /// reloads the NEWEST ULID, never a resurrected older one (which would clear a
  /// read badge back to unread).
  Future<void> setWatermark(String userId, String channelId, String ulid) {
    if (!isSortableWatermark(ulid)) return Future<void>.value(); // reject junk
    final result = _writes.then((_) async {
      final map = Map<String, String>.from(readAll(userId));
      final current = map[channelId];
      if (current != null && ulid.compareTo(current) <= 0) return; // CAS: no rewind
      map[channelId] = ulid;
      await _prefs.setString(_key(userId), jsonEncode(map));
    });
    // Keep the chain alive past a failed write (a persistence error must not wedge
    // every subsequent watermark) — the next advance still runs.
    _writes = result.catchError((_) {});
    return result;
  }
}
