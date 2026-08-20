import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chat/data/chat_rest_api.dart';
import '../domain/call_connection_state.dart';
import '../domain/video_token.dart';
import 'livekit_call_service.dart';

/// Orchestrates one A/V call: mint a token, connect, and — on a mid-call drop —
/// run a bounded-backoff reconnect that re-mints a *fresh* token each attempt
/// (the JWT is short-TTL and checked at connect).
///
/// Lifted from AITW `room_session.dart`, stripped of the Firestore presence and
/// game-world callbacks. The spine that survives (and that the cage-match must
/// verify) is the `[2s,4s,8s]` backoff, the `_isReconnecting` re-entrancy guard,
/// the auth-abort-vs-network-retry split, and the **`_disposed` recheck after
/// EVERY await** so a delayed reconnect racing with the user leaving can't touch
/// disposed notifiers.
class CallSession {
  CallSession({
    required ChatRestApi api,
    required this.channelId,
    LiveKitCallService? service,
    List<Duration>? reconnectDelays,
  }) : _api = api,
       service = service ?? LiveKitCallService(),
       _reconnectDelays = reconnectDelays ?? _defaultReconnectDelays;

  final ChatRestApi _api;
  final String channelId;
  final LiveKitCallService service;

  /// Observable call state for the UI.
  final state = ValueNotifier<CallConnectionState>(
    CallConnectionState.connecting,
  );

  /// Human-readable status/failure message, or null.
  final message = ValueNotifier<String?>(null);

  static const _defaultReconnectDelays = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];
  final List<Duration> _reconnectDelays;

  bool _isReconnecting = false;
  StreamSubscription<String?>? _connectionLostSub;

  /// Set by [leave]; read after every `await` in the reconnect loop so work
  /// that resumes after the user left can't mutate disposed state.
  bool _disposed = false;

  // ---------------------------------------------------------------------------
  // Connect
  // ---------------------------------------------------------------------------

  /// Fetch a token and connect. Sets [state]/[message] for the UI and returns
  /// the [ConnectionResult] so the caller can react (e.g. skip media on fail).
  Future<ConnectionResult> connect() async {
    state.value = CallConnectionState.connecting;
    final result = await _connectOnce();
    if (_disposed) return result;

    switch (result) {
      case ConnectionResult.connected:
      case ConnectionResult.alreadyConnected:
        _listenForConnectionLoss();
        await service.enableMedia();
        if (_disposed) return result;
        state.value = CallConnectionState.connected;
        message.value = null;
      case ConnectionResult.videoUnavailable:
        state.value = CallConnectionState.videoUnavailable;
        message.value = _messageFor(result);
      default:
        state.value = CallConnectionState.failed;
        message.value = _messageFor(result);
    }
    return result;
  }

  /// One mint-token-then-connect attempt. Maps the REST token exceptions onto
  /// the [ConnectionResult] taxonomy the reconnect loop understands.
  Future<ConnectionResult> _connectOnce() async {
    final VideoToken token;
    try {
      token = await _api.requestVideoToken(channelId);
    } on VideoNotEnabled {
      return ConnectionResult.videoUnavailable; // terminal, not an error
    } on AccountSuspended {
      // MUST precede Unauthorized (it's a subtype) — a ban is not a session
      // expiry, so it must not render "sign in again" (cage-match Carnot+Tesla
      // HIGH: ban-as-session-expired re-login theater).
      return ConnectionResult.accountSuspended;
    } on Unauthorized {
      return ConnectionResult.tokenAuthError; // abort, route to re-auth
    } on Forbidden {
      return ConnectionResult.channelUnavailable; // 404/denied; terminal
    } on NetworkUnavailable {
      return ConnectionResult.tokenNetworkError; // transient; retry
    } catch (_) {
      return ConnectionResult.roomFailed; // 5xx/other; retry
    }
    if (_disposed) return ConnectionResult.roomFailed;
    return service.connect(token);
  }

  // ---------------------------------------------------------------------------
  // Reconnect
  // ---------------------------------------------------------------------------

  void _listenForConnectionLoss() {
    _connectionLostSub?.cancel();
    _connectionLostSub = service.connectionLost.listen(_handleConnectionLost);
  }

  Future<void> _handleConnectionLost(String? reason) async {
    if (_isReconnecting || _disposed) return;
    _isReconnecting = true;
    state.value = CallConnectionState.reconnecting;

    try {
      final maxAttempts = _reconnectDelays.length;
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        message.value =
            'Connection lost — reconnecting '
            '(${attempt + 1}/$maxAttempts)…';

        await Future.delayed(_reconnectDelays[attempt]);
        if (_disposed) return; // user left during the backoff.

        // The dead room must be torn down before a fresh connect — connect()
        // no-ops if it still thinks it is connected.
        await service.disconnect();
        if (_disposed) return;

        final result = await _connectOnce();
        if (_disposed) return;

        if (result == ConnectionResult.connected ||
            result == ConnectionResult.alreadyConnected) {
          _listenForConnectionLoss();
          await service.enableMedia();
          if (_disposed) return;
          state.value = CallConnectionState.connected;
          message.value = null;
          return;
        }

        // Auth / ban / video-disabled / channel-gone won't heal on retry.
        if (result == ConnectionResult.tokenAuthError ||
            result == ConnectionResult.accountSuspended ||
            result == ConnectionResult.videoUnavailable ||
            result == ConnectionResult.channelUnavailable) {
          state.value = result == ConnectionResult.videoUnavailable
              ? CallConnectionState.videoUnavailable
              : CallConnectionState.failed;
          message.value = _messageFor(result);
          return;
        }
        // roomFailed / tokenNetworkError are transient — keep retrying.
      }

      // Exhausted.
      state.value = CallConnectionState.failed;
      message.value = 'Call lost — could not reconnect';
    } finally {
      _isReconnecting = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Teardown
  // ---------------------------------------------------------------------------

  /// Leave the call and dispose everything. Idempotent.
  Future<void> leave() async {
    if (_disposed) return;
    _disposed = true;
    await _connectionLostSub?.cancel();
    _connectionLostSub = null;
    _isReconnecting = false;
    await service.dispose();
    state.dispose();
    message.dispose();
  }

  static String _messageFor(ConnectionResult result) => switch (result) {
    ConnectionResult.tokenAuthError => 'Session expired — please sign in again',
    ConnectionResult.accountSuspended => 'This account is suspended',
    ConnectionResult.tokenNetworkError =>
      'Could not reach the server — check your connection',
    ConnectionResult.videoUnavailable =>
      "Video calling isn't available here yet",
    ConnectionResult.channelUnavailable => 'This call is unavailable',
    _ => 'Call connection failed — try again',
  };
}
