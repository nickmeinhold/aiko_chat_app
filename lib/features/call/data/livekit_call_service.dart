import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../domain/call_connection_state.dart';
import '../domain/video_token.dart';

/// The ICE transport policy for A/V calls: **always relay-only** (`.relay`).
///
/// Peer-IP privacy is a HARD requirement (Nick, 2026-08-11): media must never
/// traverse a direct path that exposes participant IPs, so all media is forced
/// through TURN. This is NOT flippable and NOT per-island adaptive — `.all`
/// (direct UDP/srflx alongside relay) leaks peer IPs and is an explicitly
/// REJECTED fallback (this rejects the island tab's "default ICE / don't force
/// relay" Correction 2 on claude-tasks#2726, which traded the privacy property
/// away).
///
/// Consequence: force-relay makes **TURN a hard dependency of any video-enabled
/// island**. An island without TURN (e.g. enspyr as of 2026-08-11) cannot offer
/// privacy-preserving video and must fail CLOSED server-side (503
/// video-not-enabled), never mint a token that can't connect. TURN-provisioning
/// + the fail-closed 503 are tracked in the island handoff; see
/// claude-tasks#2726 and ADR-0005 grounding note.
const RTCIceTransportPolicy kCallIceTransportPolicy =
    RTCIceTransportPolicy.relay;

/// Raw LiveKit room lifecycle for a single A/V call — connect / media toggles /
/// teardown, plus a connection-lost signal. No reconnect policy lives here (that
/// is [CallSession]); no identity is passed (server-baked into the token).
///
/// Lifted from AITW `livekit_service.dart` with three deliberate changes:
/// 1. Token is passed in (from the island REST endpoint), not fetched from a
///    Firebase callable.
/// 2. adaptiveStream / dynacast / simulcast are all **ON** — AITW disables them
///    because it renders remote video onto a Flame canvas (which never signals
///    viewport demand, so the SFU stops forwarding). We render through
///    [VideoTrackRenderer], which *does* signal demand, so the AITW defaults are
///    exactly wrong for us.
/// 3. The URL comes from the token response, never hardcoded.
class LiveKitCallService {
  Room? _room;
  EventsListener<RoomEvent>? _listener;

  /// 3-state guard: replaces an illegal (isConnecting && isConnected) boolean
  /// pair so a double-connect is a clean no-op.
  CallConnectionState _state = CallConnectionState.failed;
  bool _hasConnected = false;

  final _connectionLostController = StreamController<String?>.broadcast();

  /// Fires when the room drops after a successful connect (terminal
  /// `RoomDisconnectedEvent`). [CallSession] listens and runs the backoff loop.
  Stream<String?> get connectionLost => _connectionLostController.stream;

  /// Mirror-of-truth toggles for the media toolbar. Flipped only after the
  /// underlying enable/disable actually lands, so the UI never lies.
  final cameraEnabled = ValueNotifier<bool>(false);
  final micEnabled = ValueNotifier<bool>(false);

  /// Ticks on any track/participant change. The UI rebuilds off THIS, not off
  /// [events] directly, because the underlying [EventsListener] is recreated on
  /// every reconnect (a fresh [Room] each time) — this notifier is owned by the
  /// service and survives, so the screen's subscription never goes stale.
  final tracksRevision = ValueNotifier<int>(0);

  /// Set true by [dispose]; read after every `await` in the media methods so a
  /// slow enable/toggle that resumes AFTER the user left can't write a disposed
  /// [ValueNotifier] (`leave()` → `service.dispose()` disposes these notifiers
  /// while an in-flight `setCameraEnabled` await is still pending — cage-match
  /// Carnot+Tesla HIGH: dispose is generation-unsafe without this).
  bool _disposed = false;

  /// The publish grant from the last connected token (`can_publish`). When
  /// false this participant is subscribe-only, so [enableMedia] and any
  /// enable-side toggle no-op — the single door through which every publish
  /// attempt passes its capability check, so a receive-only member never
  /// triggers a doomed camera prompt and the UI can hide the media controls.
  bool _canPublish = true;
  bool get canPublish => _canPublish;

  Room? get room => _room;
  LocalParticipant? get localParticipant => _room?.localParticipant;
  Map<String, RemoteParticipant> get remoteParticipants =>
      _room?.remoteParticipants ?? const {};

  /// The room event stream the UI listens on to rebuild on track/participant
  /// changes. Null until [connect] succeeds.
  EventsListener<RoomEvent>? get events => _listener;

  /// Connect to the LiveKit room named by [token].room. Returns
  /// [ConnectionResult.roomFailed] on any connect error (auth is resolved
  /// upstream at token-mint time, so a failure here is transport, not identity).
  Future<ConnectionResult> connect(VideoToken token) async {
    if (_state == CallConnectionState.connecting ||
        _state == CallConnectionState.connected) {
      return ConnectionResult.alreadyConnected;
    }
    _state = CallConnectionState.connecting;
    _canPublish = token.canPublish;

    try {
      // A FRESH Room per connect — never patch a dead one across a reconnect.
      _room = Room(
        roomOptions: const RoomOptions(
          // All three ON — we render via VideoTrackRenderer (signals demand),
          // unlike AITW's Flame canvas. (AITW gotcha #1, inverted.)
          adaptiveStream: true,
          dynacast: true,
          defaultCameraCaptureOptions: CameraCaptureOptions(
            maxFrameRate: 30,
            params: VideoParametersPresets.h540_169,
          ),
          defaultVideoPublishOptions: VideoPublishOptions(
            simulcast: true,
            videoCodec: 'vp8',
          ),
          defaultAudioCaptureOptions: AudioCaptureOptions(
            noiseSuppression: true,
            echoCancellation: true,
            autoGainControl: true,
          ),
        ),
      );

      // Listener BEFORE connect so no early event is missed.
      _listener = _room!.createListener();
      void bump(dynamic _) {
        if (!_disposed) tracksRevision.value++;
      }
      _listener!
        ..on<RoomDisconnectedEvent>((e) {
          // Only a drop AFTER a good connect is a "lost" event worth
          // reconnecting; a failed initial connect is handled by the catch below.
          if (_hasConnected) _connectionLostController.add(e.reason?.name);
        })
        ..on<TrackSubscribedEvent>(bump)
        ..on<TrackUnsubscribedEvent>(bump)
        ..on<LocalTrackPublishedEvent>(bump)
        ..on<LocalTrackUnpublishedEvent>(bump)
        // Mute/unmute must bump too: the UI's _videoOf() filters on pub.muted,
        // so toggling camera or a remote muting video would otherwise leave the
        // video area/PiP stale (cage-match Carnot+Tesla — tracksRevision was
        // blind to mute state).
        ..on<TrackMutedEvent>(bump)
        ..on<TrackUnmutedEvent>(bump)
        ..on<ParticipantConnectedEvent>(bump)
        ..on<ParticipantDisconnectedEvent>(bump);

      await _room!.connect(
        token.url,
        token.token,
        connectOptions: ConnectOptions(
          rtcConfiguration: RTCConfiguration(
            iceTransportPolicy: kCallIceTransportPolicy,
          ),
        ),
        // Join with media OFF; enableMedia() publishes after connect so a
        // permission prompt failure can't abort the connect itself.
        fastConnectOptions: FastConnectOptions(
          microphone: const TrackOption(enabled: false),
          camera: const TrackOption(enabled: false),
        ),
      );

      _state = CallConnectionState.connected;
      _hasConnected = true;
      return ConnectionResult.connected;
    } catch (e) {
      // Clean up the half-built room/listener; each wrapped so one failure
      // doesn't prevent the other.
      try {
        await _listener?.dispose();
      } catch (_) {}
      _listener = null;
      try {
        await _room?.disconnect();
      } catch (_) {}
      _room = null;
      _state = CallConnectionState.failed;
      return ConnectionResult.roomFailed;
    }
  }

  /// Enable the local camera + mic after a successful connect. Camera failure
  /// (permission denied) degrades to audio-only rather than crashing the call.
  Future<void> enableMedia() async {
    if (!_canPublish) return; // subscribe-only — never prompt for the camera.
    final lp = _room?.localParticipant;
    if (lp == null) return;
    try {
      await lp.setCameraEnabled(true);
      if (_disposed) return; // left mid-enable → notifiers already disposed.
      cameraEnabled.value = true;
    } catch (_) {
      if (!_disposed) cameraEnabled.value = false; // denied → audio-only.
    }
    try {
      await lp.setMicrophoneEnabled(true);
      if (_disposed) return;
      micEnabled.value = true;
    } catch (_) {
      if (!_disposed) micEnabled.value = false;
    }
  }

  Future<void> setCameraEnabled(bool enabled) async {
    if (enabled && !_canPublish) return; // subscribe-only can't publish.
    final lp = _room?.localParticipant;
    if (lp == null) return;
    // Same catch as enableMedia (Tesla: "same door, same catch") — a mid-call
    // permission revocation must not surface as an unhandled async error. The
    // disposed guard covers a toggle racing teardown.
    try {
      await lp.setCameraEnabled(enabled);
      if (!_disposed) cameraEnabled.value = enabled;
    } catch (_) {
      if (!_disposed) cameraEnabled.value = false;
    }
  }

  Future<void> setMicrophoneEnabled(bool enabled) async {
    if (enabled && !_canPublish) return; // subscribe-only can't publish.
    final lp = _room?.localParticipant;
    if (lp == null) return;
    try {
      await lp.setMicrophoneEnabled(enabled);
      if (!_disposed) micEnabled.value = enabled;
    } catch (_) {
      if (!_disposed) micEnabled.value = false;
    }
  }

  /// Tear down the current room without disposing the service (a reconnect will
  /// build a fresh room). Safe to call when already disconnected.
  Future<void> disconnect() async {
    _hasConnected = false;
    try {
      await _room?.disconnect();
    } catch (_) {}
    try {
      await _listener?.dispose();
    } catch (_) {}
    _listener = null;
    _room = null;
    if (!_disposed) {
      cameraEnabled.value = false;
      micEnabled.value = false;
    }
    _state = CallConnectionState.failed;
  }

  /// Permanently dispose the service (call on leave). Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true; // set FIRST: in-flight media awaits now skip notifier writes.
    await disconnect();
    cameraEnabled.dispose();
    micEnabled.dispose();
    tracksRevision.dispose();
    if (!_connectionLostController.isClosed) {
      await _connectionLostController.close();
    }
  }
}
