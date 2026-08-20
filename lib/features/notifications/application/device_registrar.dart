import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../chat/data/chat_rest_api.dart';
import '../domain/push_token_source.dart';

/// Keeps this island's belief about "where do I push to reach this user" in step
/// with the platform's belief about "what is this device's token".
///
/// Three events move that pairing and all three must be handled, because the
/// failure mode of missing one is silence rather than an error — the island
/// holds a token the push service will simply refuse to deliver to, and nothing
/// anywhere reports a problem:
///
///   sign-in          → register the current token
///   token rotation   → register the new one (reinstall, restore, platform whim)
///   sign-out         → unregister, so the next person to hold this handset does
///                      not receive the previous owner's pushes
///
/// NOT A GATE. Every failure here degrades reach and nothing else: a device that
/// cannot register is a device that will not be woken. Sign-in must never fail
/// because a push service was unreachable, so [start] swallows and logs.
class DeviceRegistrar {
  DeviceRegistrar({required PushTokenSource source, required ChatRestApi api})
    : _source = source,
      _api = api;

  final PushTokenSource _source;
  final ChatRestApi _api;

  StreamSubscription<String>? _refreshes;

  /// The token this island is believed to hold, so [stop] can unregister the
  /// right one after a rotation. Without it a rotate-then-sign-out unregisters a
  /// token the island never had and leaves the live one routing.
  String? _registered;

  /// Whether a token is currently registered — for tests and diagnostics.
  String? get registeredToken => _registered;

  /// Begin keeping the pairing current for the signed-in user. Idempotent.
  Future<void> start() async {
    if (_refreshes != null) return;

    // Subscribe BEFORE asking for the first token. A rotation that lands
    // between the two would otherwise be dropped, and the window is not
    // theoretical — the platform can reissue during the permission grant.
    _refreshes = _source.tokenRefreshes().listen(_register);

    if (!await _source.requestPermission()) return;
    final token = await _source.currentToken();
    if (token != null) await _register(token);
  }

  /// Stop, and tell the island to forget this device.
  ///
  /// ORDERING IS LOAD-BEARING: `DELETE /v1/devices` is an AUTHENTICATED call, so
  /// this has to run while the session is still alive. Called after the tokens
  /// are cleared it 401s, the row survives, and the handset keeps receiving that
  /// account's pushes — the exact outcome signing out is supposed to produce.
  /// It therefore belongs before the credential teardown in `logout()`, not
  /// after it or alongside it.
  ///
  /// NAMED TRADEOFF, not an oversight: an unregister that fails (island
  /// unreachable, offline sign-out) leaves a live row behind, so the handset can
  /// keep receiving opaque wakes for an account no longer signed in on it. That
  /// is a real residual — on a shared phone it is the privacy-relevant one. It
  /// is accepted for this increment because the alternative is blocking sign-out
  /// on a network call, which is worse. The fix is a pending-unregister retried
  /// on next launch; filed rather than half-built here.
  Future<void> stop() async {
    await _refreshes?.cancel();
    _refreshes = null;

    final token = _registered;
    _registered = null;
    if (token == null) return;
    try {
      await _api.unregisterDevice(token);
    } catch (e) {
      debugPrint(
        'DeviceRegistrar: unregister failed, row survives island-side: $e',
      );
    }
  }

  Future<void> _register(String token) async {
    // Re-registering an unchanged token is harmless island-side (the upsert is
    // keyed on the token) but it is a pointless round trip on every rotation
    // event that reports the same value.
    if (token == _registered) return;
    try {
      await _api.registerDevice(platform: _source.platform, token: token);
      _registered = token;
    } on Unauthorized {
      // The session died underneath us. Not ours to handle — the auth
      // controller owns that transition — and NOT recorded as registered, so a
      // later sign-in re-registers rather than assuming this one landed.
      rethrow;
    } catch (e) {
      debugPrint(
        'DeviceRegistrar: register failed, this device will not wake: $e',
      );
    }
  }
}
