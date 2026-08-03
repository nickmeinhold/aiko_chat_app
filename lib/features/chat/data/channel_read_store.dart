/// Per-channel last-read watermarks — the durable store behind the channel
/// switcher's unread indicators.
///
/// Deliberately the LIGHTEST durable store ([SharedPreferences]): a watermark is
/// a tiny per-channel string (the newest server ULID the user has seen in that
/// channel), non-secret, and never leaves the device — so it wants neither the
/// encrypted key store nor a drift schema migration on the shared message cache.
///
/// **Per-user scoped.** Keys embed the authenticated user id
/// (`aiko_channel_lastread_<userId>_<channelId>`) so two users on one device
/// never read each other's read-state — mirroring the per-user isolation the
/// message cache gets from a user-keyed database file (app/providers Carnot C3).
library;

import 'package:shared_preferences/shared_preferences.dart';

class ChannelReadStore {
  ChannelReadStore(this._prefs);

  final SharedPreferences _prefs;

  static const _prefix = 'aiko_channel_lastread_';

  String _userPrefix(String userId) => '$_prefix${userId}_';

  String _key(String userId, String channelId) =>
      '${_userPrefix(userId)}$channelId';

  /// Every persisted watermark for [userId], as `channelId → newest-read ULID`.
  /// The map the in-memory notifier seeds from on login / user switch.
  Map<String, String> readAll(String userId) {
    final p = _userPrefix(userId);
    final out = <String, String>{};
    for (final k in _prefs.getKeys()) {
      if (k.startsWith(p)) {
        final v = _prefs.getString(k);
        // The remainder after the exact `<prefix><userId>_` is the channel id
        // verbatim (channel ids may contain '_'; only the user segment is fixed).
        if (v != null) out[k.substring(p.length)] = v;
      }
    }
    return out;
  }

  /// Persist [ulid] as the newest-read watermark for ([userId], [channelId]).
  Future<void> setWatermark(String userId, String channelId, String ulid) =>
      _prefs.setString(_key(userId, channelId), ulid);
}
