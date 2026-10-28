import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The handle a new account chose BEFORE its passkey existed, and still owes
/// the island (#436: handle-first sign-up, Nick 2026-10-28).
///
/// The island creates every passkey account with an auto-assigned `aiko-…`
/// handle (its Design 04: a handle is a profile edit, never a gate on account
/// creation), so the app applies the chosen one with `PATCH /v1/me` right
/// after. This record is what survives the app being killed in between. It is
/// written before the ceremony, bound to the new account's id the moment the
/// island answers, and cleared only once the island has the handle. While it
/// names the signed-in account, the router keeps that account out of chat.
class OwedHandle {
  const OwedHandle({
    required this.handle,
    required this.displayName,
    this.userId,
    this.failure,
  });

  final String handle;
  final String displayName;

  /// Null until `register/finish` answers. A record with no account behind it
  /// is never a gate: it means the ceremony made no account.
  final String? userId;

  /// Why the island last refused it (taken, no network). In memory only: after
  /// a relaunch the screen simply asks again.
  final Object? failure;

  OwedHandle bindTo(String userId) =>
      OwedHandle(handle: handle, displayName: displayName, userId: userId);

  OwedHandle refusedWith(Object failure) => OwedHandle(
    handle: handle,
    displayName: displayName,
    userId: userId,
    failure: failure,
  );

  Map<String, dynamic> toJson() => {
    'handle': handle,
    'display_name': displayName,
    if (userId != null) 'user_id': userId,
  };

  static OwedHandle? fromJson(Object? j) {
    if (j is! Map) return null;
    final handle = j['handle'];
    final displayName = j['display_name'];
    final userId = j['user_id'];
    if (handle is! String || displayName is! String) return null;
    return OwedHandle(
      handle: handle,
      displayName: displayName,
      userId: userId is String ? userId : null,
    );
  }
}

/// Persistence for [OwedHandle]. Nullable prefs so a test container without
/// them still runs, in memory: like the passkey hint, this must never be able
/// to fail a sign-in.
class OwedHandleStore {
  static const _key = 'aiko_owed_handle';

  final SharedPreferences? _prefs;

  OwedHandleStore(this._prefs);

  /// The persisted record, or null if none or unreadable. A corrupt value is
  /// "nothing owed" rather than a throw: a bad record must never brick launch.
  OwedHandle? read() {
    final raw = _prefs?.getString(_key);
    if (raw == null) return null;
    try {
      return OwedHandle.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<bool> write(OwedHandle owed) =>
      _prefs?.setString(_key, jsonEncode(owed.toJson())) ?? Future.value(false);

  Future<bool> clear() => _prefs?.remove(_key) ?? Future.value(false);
}
