import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The device-token unregisters this app still OWES an island.
///
/// It exists so that ending a session never has to choose between two things
/// that cannot both be true. `DELETE /v1/devices` is authenticated, so it wants
/// to run before the credential is cleared; but nothing slow may sit ahead of
/// that clear, because a re-login inside the window writes fresh tokens the
/// trailing clear then stomps. Every attempt to satisfy both at once produced a
/// guard, and every guard moved the contradiction somewhere else.
///
/// A debt record dissolves the conflict rather than arbitrating it. The
/// credential clear becomes unconditional and immediate; the unregister becomes
/// an obligation that outlives the session, is written durably before anything
/// is attempted, and is paid off at the next opportunity. There is no window to
/// guard because the two operations are no longer racing for the same instant.
///
/// KEYED BY ISLAND, deliberately. A token registered with island X must never be
/// deleted at island Y — after `switchGateway` the REST client already points at
/// the new island, and an un-keyed debt would send X's DELETE to Y (a 204 that
/// deletes nothing while reporting success, leaving X routing forever). One
/// outstanding debt per island is enough: the device token is stable per
/// install, so a newer debt for the same island supersedes the older one.
///
/// SharedPreferences rather than the drift cache, and the reason is lifecycle:
/// the cache is per-session and cleared on logout, which is the exact moment
/// this record is written. A debt stored somewhere that logout empties is not a
/// debt record.
class PendingUnregisterStore {
  static const _key = 'aiko_pending_device_unregisters';

  // Nullable so a test double can subclass and override the three methods
  // without a real SharedPreferences (mirrors [CachedUserStore]). The real store
  // is always constructed by its provider with a non-null instance.
  final SharedPreferences? _prefs;

  PendingUnregisterStore(this._prefs);

  /// The token owed to [islandBaseUrl], or null if nothing is outstanding.
  ///
  /// Synchronous: the read is off already-loaded SharedPreferences, so the drain
  /// adds no await to the sign-in path. A corrupt value reads as "nothing owed"
  /// rather than throwing — an unpayable debt must never brick a sign-in.
  String? read(String islandBaseUrl) => _all()[islandBaseUrl];

  /// Record that [islandBaseUrl] is owed a DELETE for [token].
  ///
  /// Written BEFORE any attempt, never after. The failures this exists to
  /// survive — offline sign-out, the app being killed mid-flight — are precisely
  /// the ones that never reach an "on failure, record it" line.
  Future<bool> remember(String islandBaseUrl, String token) =>
      _write(_all()..[islandBaseUrl] = token);

  /// Discharge the debt, but ONLY if [token] is still the one outstanding.
  ///
  /// A compare-and-clear, not a clear. A drain can be in flight when a fresh
  /// unpair records a NEWER token for the same island; an unconditional clear
  /// would then discharge a debt that was never paid, which is the one failure
  /// mode a debt record must not have.
  Future<bool> forget(String islandBaseUrl, String token) {
    final all = _all();
    if (all[islandBaseUrl] != token) return Future.value(true);
    all.remove(islandBaseUrl);
    return _write(all);
  }

  Map<String, String> _all() {
    final raw = _prefs!.getString(_key);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  Future<bool> _write(Map<String, String> all) => all.isEmpty
      ? _prefs!.remove(_key)
      : _prefs!.setString(_key, jsonEncode(all));
}
