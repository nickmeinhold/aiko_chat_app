import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../domain/call_connection_state.dart';
import '../domain/video_token.dart';

/// The ICE transport policy for A/V calls: **always relay-only** (`.relay`).
///
/// KEEP THE CONSTANT. THE REASON IS SCOPED TO A TOPOLOGY — READ WHICH ONE.
///
/// **This reasoning describes the SFU path, which is what exists today.** It is
/// not a general fact about `.relay`, and it stops applying the moment a direct
/// `PeerConnection` exists — see the note at the end, because that may be where
/// 1:1 calls are going (claude-tasks#3740).
///
/// The reason printed here until 2026-08-31 said `.all` leaks peer IPs. That is
/// a mesh/P2P rationale applied to an SFU, and it does not survive that
/// topology. LiveKit's signalling proto carries
/// `TrickleRequest { candidateInit, SignalTarget target }` with exactly two
/// targets — `PUBLISHER` and `SUBSCRIBER`, the client's own two peer connections
/// — and `ParticipantInfo`, the struct the server broadcasts about you, has no
/// address field at all. **There is no channel by which another participant
/// could learn your address**, under either policy. Under `.all` the party that
/// learns it is the operator's SFU; under `.relay` it is the operator's TURN,
/// which on both live islands is the *same process* (LiveKit's embedded TURN in
/// `livekit.yaml`, one container per box, no coturn). Both tabs agree; the
/// reasoning is island design 13 Decision 9f, strengthened 2026-08-31.
///
/// What `.relay` actually buys, and why it stays: **NAT traversal from
/// restrictive networks**, and on our boxes **forcing media over 443 through the
/// SNI mux** so it reads as HTTPS to a middlebox. Reachability and traffic
/// shape, not peer-IP privacy. Recorded at the constant because the inversion is
/// more dangerous than a wrong comment — the next reader to correctly falsify
/// "it protects peer IPs" would have a clean-looking argument for deleting
/// something we need.
///
/// Still not flippable and not per-island adaptive, and this still rejects the
/// island tab's "default ICE / don't force relay" Correction 2 on
/// claude-tasks#2726 — now on the reachability grounds, not the privacy ones.
/// The cost is real and unpriced: 100% of media egress crosses the operator
/// (claude-tasks#3699, #3716).
///
/// Consequence, unchanged: force-relay makes **TURN a hard dependency of any
/// video-enabled island**. An island without TURN cannot connect a call at all
/// and must fail CLOSED server-side (503 video-not-enabled), never mint a token
/// that can't connect. See claude-tasks#2726 and the ADR-0005 grounding note.
///
/// ## The reason above INVERTS on a direct path, and that path is being designed
///
/// The whole argument rests on one structural fact — an SFU has no
/// participant-to-participant channel, so no peer can learn another's address.
/// **On a direct `PeerConnection` that channel is the entire mechanism**: peers
/// trade host and srflx ICE candidates with each other, so `.all` would expose
/// peer IPs exactly as the old docstring claimed. The retired rationale is not
/// wrong in general — it was **premature**, describing a topology the system
/// does not have yet and may grow into (claude-tasks#3740: 1:1 media over a
/// registrar/bus rendezvous instead of the SFU).
///
/// So the next reader gets the trap named rather than sprung: **do not carry
/// "force-relay buys nothing on peer-IP privacy" across into a P2P design.** It
/// is a fact about the topology it was measured in. Under a direct path this
/// constant becomes load-bearing for the reason it was originally given, and
/// forcing relay there also forfeits the egress saving that motivates P2P at
/// all — which makes it a genuine fork to price, not a constant to inherit.
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
          // `vp8` IS LOAD-BEARING, not a rendering preference — do not
          // "modernise" it to AV1 without reading claude-tasks#3426 first.
          //
          // LiveKit REFUSES AV1 outright under end-to-end encryption
          // (`av1 is not yet supported for end to end encryption`, thrown from
          // the frame cryptor), and H.264/H.265 need NALU-aware handling with a
          // fallback. So if #3426 rules media E2EE on, an AV1 pin here is a
          // hard throw at connect time.
          //
          // It is also WHY that decision's cost column came out empty
          // (verified independently by both tabs, 2026-08-31, against the
          // LOCKED `livekit_client 2.10.0` rather than whatever is newest in
          // the pub cache): E2EE's only publish-side effects are disabling the
          // backup video codec and RED. The backup codec exists to fall back
          // FROM VP9/AV1 TO VP8 — we already publish the fallback floor, so
          // disabling it removes a path we never take. `simulcast` is untouched
          // by E2EE, and RED is already off by default on this path.
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
    _disposed =
        true; // set FIRST: in-flight media awaits now skip notifier writes.
    await disconnect();
    cameraEnabled.dispose();
    micEnabled.dispose();
    tracksRevision.dispose();
    if (!_connectionLostController.isClosed) {
      await _connectionLostController.close();
    }
  }
}
