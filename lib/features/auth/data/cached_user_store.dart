import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/auth_models.dart';

/// Durable store for the last-known [AppUser] — the piece that makes offline-first
/// session restore possible.
///
/// The JWT pair lives in the encrypted [SecureTokenStore]; the *identity* the
/// tokens belong to only ever came from a live `me()` call, so an offline cold
/// start had a valid token but no user to show and fell back to the login wall.
/// Persisting the user here lets [AuthController] restore a session optimistically
/// when the network is down (see auth_controller `_restoreSession`).
///
/// Deliberately NOT in secure storage: these are non-secret profile fields
/// (id/username/display name), and SharedPreferences is already wired app-wide.
/// The cached user's lifecycle is kept SYMMETRIC with the tokens' — written
/// wherever a user becomes current, cleared wherever tokens are cleared — so the
/// two never drift (a kept cached-user for a cleared session would be a phantom
/// login).
class CachedUserStore {
  static const _key = 'aiko_cached_user';

  // Nullable so a test double can subclass and override all three methods
  // without a real SharedPreferences (mirrors InMemoryTokenStore). The real
  // store is always constructed by [cachedUserStoreProvider] with a non-null
  // instance, so the `!` uses below are safe on the production path.
  final SharedPreferences? _prefs;

  CachedUserStore(this._prefs);

  /// The persisted user, or null if none / unparseable. Synchronous: the read
  /// is off the already-loaded SharedPreferences, so cold-start restore doesn't
  /// add an await. A corrupt value returns null (treated as "no cached user")
  /// rather than throwing — a bad cache must never brick launch.
  AppUser? read() {
    final raw = _prefs!.getString(_key);
    if (raw == null) return null;
    try {
      return AppUser.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  Future<void> write(AppUser user) =>
      _prefs!.setString(_key, jsonEncode(user.toJson()));

  Future<void> clear() => _prefs!.remove(_key);
}
