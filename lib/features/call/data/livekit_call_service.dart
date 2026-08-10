import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../domain/call_connection_state.dart';
import '../domain/video_token.dart';

/// The ICE transport policy for A/V calls.
///
/// The island handoff (#2726) states **"FORCE RELAY"** but parenthesises
/// `iceTransportPolicy.all` — a contradiction: `.all` allows direct UDP + srflx
/// *alongside* relay, so it is NOT force-relay. `.relay` is (relay-only, peer
/// IPs never exposed, all media through `turn.imagineering.cc`). We honour the
/// stated security *intent* and ship `.relay`, isolated here as a single
/// flippable constant: if TURN is unreachable during a rehearsal, flip to
/// `.all` as a one-line fallback. Surfaced to the island tab to fix the wording
/// (claude-tasks#2726). See ADR-0005 grounding note.
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
      void bump(dynamic _) => tracksRevision.value++;
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
    final lp = _room?.localParticipant;
    if (lp == null) return;
    try {
      await lp.setCameraEnabled(true);
      cameraEnabled.value = true;
    } catch (_) {
      cameraEnabled.value = false; // denied → audio-only, toolbar shows off.
    }
    try {
      await lp.setMicrophoneEnabled(true);
      micEnabled.value = true;
    } catch (_) {
      micEnabled.value = false;
    }
  }

  Future<void> setCameraEnabled(bool enabled) async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    await lp.setCameraEnabled(enabled);
    cameraEnabled.value = enabled;
  }

  Future<void> setMicrophoneEnabled(bool enabled) async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    await lp.setMicrophoneEnabled(enabled);
    micEnabled.value = enabled;
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
    cameraEnabled.value = false;
    micEnabled.value = false;
    _state = CallConnectionState.failed;
  }

  /// Permanently dispose the service (call on leave). Idempotent.
  Future<void> dispose() async {
    await disconnect();
    cameraEnabled.dispose();
    micEnabled.dispose();
    tracksRevision.dispose();
    if (!_connectionLostController.isClosed) {
      await _connectionLostController.close();
    }
  }
}
