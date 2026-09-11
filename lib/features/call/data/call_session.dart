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
       _reconnectDelays = reconnectDelays ?? _defaultReconnectDelays {
    // Subscribed in the CONSTRUCTOR, not in `connect()`, so the arm is live
    // before `Room.connect` returns. `_evaluatePeerPresence` can fire from a
    // bump while `connect()` is still awaiting, and with no listener yet that
    // departure would be lost — while `connect()`'s tail went on to call
    // `enableMedia()` and open the camera into a room nobody is in.
    // `this.service`, not `service`: the constructor PARAMETER shadows the
    // field here and is nullable.
    _peerLeftSub = this.service.peerLeft.listen((_) => unawaited(end()));
  }

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
  StreamSubscription<void>? _peerLeftSub;

  /// The call is over. The SECOND terminal condition, alongside [_disposed],
  /// and every `_disposed` recheck below is widened to include it — without
  /// that the reconnect loop cheerfully re-mints a token and re-enables media
  /// after the peer has gone.
  bool _over = false;

  /// Set by [leave]; read after every `await` in the reconnect loop so work
  /// that resumes after the user left can't mutate disposed state.
  bool _disposed = false;

  // ---------------------------------------------------------------------------
  // Connect
  // ---------------------------------------------------------------------------

  /// Fetch a token and connect. Sets [state]/[message] for the UI and returns
  /// the [ConnectionResult] so the caller can react (e.g. skip media on fail).
  /// THE CALL IS OVER — one door, idempotent, the only transition into
  /// [CallConnectionState.ended].
  ///
  /// Both signals land here (the transport's `peerLeft`, and the peer's signed
  /// end once wired) so there is exactly one place that stops publishing and
  /// exactly one place that can race. The state flip PRECEDES the await
  /// deliberately: the UI must stop lying on the current frame, not after a
  /// network teardown completes.
  Future<void> end() async {
    if (_disposed || _over) return;
    _over = true;
    _isReconnecting = false; // nothing left to reconnect TO.
    state.value = CallConnectionState.ended;
    message.value = null; // else the banner repeats the centre copy.
    await service.disconnect(); // unpublishes + stops the tracks: camera off.
  }

  Future<ConnectionResult> connect() async {
    // BEFORE the state write, not after. Every other guard in this file sits
    // after an await, because it is protecting against a change that happened
    // DURING one; this one protects against re-entry into a terminal state, and
    // the very first line is already destructive — it would repaint "Call
    // ended" as "Connecting…" for a call with nobody left in it.
    if (_disposed || _over) return ConnectionResult.roomFailed;
    state.value = CallConnectionState.connecting;
    final result = await _connectOnce();
    if (_disposed || _over) return result;

    switch (result) {
      case ConnectionResult.connected:
      case ConnectionResult.alreadyConnected:
        _listenForConnectionLoss();
        await service.enableMedia();
        if (_disposed || _over) return result;
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
    if (_disposed || _over) return ConnectionResult.roomFailed;
    return service.connect(token);
  }

  // ---------------------------------------------------------------------------
  // Reconnect
  // ---------------------------------------------------------------------------

  void _listenForConnectionLoss() {
    _connectionLostSub?.cancel();
    // `_peerLeftSub` is NOT touched here. It is subscribed once in the
    // constructor and cancelled once in `leave()`: this method runs on every
    // connect, so cancelling it here would kill the departure arm before the
    // first call even started, and nothing re-subscribes.
    _connectionLostSub = service.connectionLost.listen(_handleConnectionLost);
  }

  Future<void> _handleConnectionLost(String? reason) async {
    if (_isReconnecting || _disposed || _over) return;
    _isReconnecting = true;
    state.value = CallConnectionState.reconnecting;

    try {
      final maxAttempts = _reconnectDelays.length;
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        message.value =
            'Connection lost — reconnecting '
            '(${attempt + 1}/$maxAttempts)…';

        await Future.delayed(_reconnectDelays[attempt]);
        if (_disposed || _over) return; // user left during the backoff.

        // The dead room must be torn down before a fresh connect — connect()
        // no-ops if it still thinks it is connected.
        await service.disconnect();
        if (_disposed || _over) return;

        final result = await _connectOnce();
        if (_disposed || _over) return;

        if (result == ConnectionResult.connected ||
            result == ConnectionResult.alreadyConnected) {
          _listenForConnectionLoss();
          await service.enableMedia();
          if (_disposed || _over) return;
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
    // `_disposed` ONLY — deliberately NOT `|| _over`. Every other recheck in
    // this file is widened to both because they guard work that must not happen
    // after the call ends; this one guards TEARDOWN, which must still happen.
    // Returning early on `_over` would leave an ended call's notifiers and its
    // LiveKit room undisposed for the life of the process.
    if (_disposed) return;
    _disposed = true;
    await _connectionLostSub?.cancel();
    _connectionLostSub = null;
    await _peerLeftSub?.cancel();
    _peerLeftSub = null;
    _isReconnecting = false;
    await service.dispose();
    state.dispose();
    message.dispose();
  }

  static String _messageFor(ConnectionResult result) => switch (result) {
    ConnectionResult.tokenAuthError => 'Session expired — please sign in again',
    ConnectionResult.accountSuspended => 'This account is suspended',
    ConnectionResult.tokenNetworkError =>
      'Could not reach the island — check your connection',
    ConnectionResult.videoUnavailable =>
      "Video calling isn't available here yet",
    ConnectionResult.channelUnavailable => 'This call is unavailable',
    _ => 'Call connection failed — try again',
  };
}
