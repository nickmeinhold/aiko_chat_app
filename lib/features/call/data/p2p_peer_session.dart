/// One side of a DIRECT (peer-to-peer) call — the media half of the P2P thesis,
/// with no SFU, no room, and no LiveKit.
///
/// ## Status: SPIKE. Not wired to anything. Not a product path.
///
/// Nothing constructs this outside tests. `LiveKitCallService` remains the only
/// call path the app ships. This exists to answer one question with a running
/// artifact rather than an argument:
///
/// > **claude-tasks#3740:** the hard part of P2P WebRTC is *rendezvous*, not
/// > media — so the centralised media plane is a workaround for a problem the
/// > Dart port dissolves, not a technical necessity.
///
/// If that is right, the media half should be unremarkable: `flutter_webrtc`
/// standalone, an offer, an answer, some candidates, a connection. This file is
/// that claim written down in a form that can go red.
///
/// ## What it deliberately does NOT do
///
/// - **No wire.** Signalling goes through [CallSignalling], whose only
///   implementation in the tree is an in-memory loopback. Carrying SDP in a
///   signed message would be a one-way door on a cross-repo contract; see that
///   file's own header.
/// - **No transport policy decision.** [iceTransportPolicy] is a constructor
///   argument with no default opinion baked in, because the force-relay question
///   *inverts* on a direct path — on an SFU there is no participant-to-participant
///   channel so `.all` leaks nothing, and on a direct path that channel is the
///   entire mechanism. Whichever way that lands is a decision for the design,
///   not a constant this spike gets to smuggle in.
/// - **No reconnect policy.** `CallSession` owns backoff for the SFU path; the
///   direct path's equivalent is a separate design (ICE restart, not reconnect).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../domain/call_connection_state.dart';
import '../domain/call_signalling.dart';
import '../domain/ice_candidate_tally.dart';

/// Which side of the call this peer is. The offerer creates the offer; the
/// answerer waits for one.
///
/// A closed set, because "who offers?" is exactly the kind of thing that becomes
/// a bool named `isCaller` and then acquires a third case.
enum P2pRole { offerer, answerer }

class P2pPeerSession {
  P2pPeerSession({
    required this.role,
    required CallSignalling signalling,
    this.iceServers = const [],
    this.iceTransportPolicy,
  }) : _signalling = signalling;

  final P2pRole role;
  final CallSignalling _signalling;

  /// STUN/TURN servers, in the `flutter_webrtc` config shape
  /// (`{'urls': 'stun:...'}`). Empty means host candidates only — which is
  /// exactly right for a loopback test and useless on the internet.
  final List<Map<String, dynamic>> iceServers;

  /// `'all'` or `'relay'`. Null leaves it unset, i.e. the stack default (`all`).
  /// See the header: this spike takes no position.
  final String? iceTransportPolicy;

  /// How this call connected. Populated as candidates flow, and completed by
  /// [readSelectedPair].
  final tally = IceCandidateTally();

  final state = ValueNotifier<CallConnectionState>(
    CallConnectionState.connecting,
  );

  RTCPeerConnection? _pc;
  StreamSubscription<CallSignal>? _signalSub;
  bool _disposed = false;

  /// Remote candidates that arrived before the remote description was set.
  ///
  /// THIS BUFFER IS NOT OPTIONAL. Trickle means candidates race the SDP, and
  /// `addCandidate` before `setRemoteDescription` throws on every stack — so
  /// without this, a call fails whenever the network happens to deliver a
  /// candidate first. It is the direct-path twin of `RingController._ended`
  /// holding a hangup that arrived before its invite: at-least-once, locally
  /// out-of-order delivery is ordinary, and the ordering is the part that
  /// survives.
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];
  bool _remoteDescriptionSet = false;

  final _connectedCompleter = Completer<bool>();

  /// Completes true when the peer connection reaches `connected`, false if it
  /// reaches a terminal failure. Never completes twice.
  Future<bool> get connected => _connectedCompleter.future;

  RTCPeerConnection? get peerConnection => _pc;

  /// Build the peer connection, attach handlers, and start signalling.
  ///
  /// [localStream] is optional so the connection lifecycle can be exercised
  /// without a camera or microphone — a test host has neither, and the question
  /// this spike answers is about connectivity, not capture. When absent, a
  /// data channel is opened instead so the connection still has something to
  /// negotiate; a peer connection with no media and no data channel has nothing
  /// to gather candidates *for* and never leaves `new`.
  Future<void> start({MediaStream? localStream}) async {
    _pc = await createPeerConnection({
      'iceServers': iceServers,
      if (iceTransportPolicy != null) 'iceTransportPolicy': iceTransportPolicy,
      // Unified Plan is the only plan modern stacks implement; naming it keeps
      // the spike from inheriting whatever a future default becomes.
      'sdpSemantics': 'unified-plan',
    });

    _pc!.onIceCandidate = _onLocalCandidate;
    _pc!.onConnectionState = _onConnectionState;

    if (localStream != null) {
      for (final track in localStream.getTracks()) {
        await _pc!.addTrack(track, localStream);
      }
    } else {
      // Negotiation needs *something* to negotiate. A data channel is the
      // cheapest something, and it is created only on the offerer — both sides
      // creating one produces two channels and a needlessly larger SDP.
      if (role == P2pRole.offerer) {
        await _pc!.createDataChannel('spike', RTCDataChannelInit());
      }
    }

    _signalSub = _signalling.inbound.listen(_onSignal);

    if (role == P2pRole.offerer) {
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      await _signalling.send(CallOffer(offer.sdp!));
    }
  }

  void _onLocalCandidate(RTCIceCandidate c) {
    final line = c.candidate;
    if (line == null || line.isEmpty) return; // end-of-candidates sentinel
    tally.recordLocalCandidate(line);
    // Fire-and-forget: a signalling send must never block candidate gathering.
    unawaited(
      _signalling.send(
        CallIceCandidate(
          candidate: line,
          sdpMid: c.sdpMid,
          sdpMLineIndex: c.sdpMLineIndex,
        ),
      ),
    );
  }

  void _onConnectionState(RTCPeerConnectionState s) {
    if (_disposed) return;
    switch (s) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        state.value = CallConnectionState.connected;
        if (!_connectedCompleter.isCompleted) _connectedCompleter.complete(true);
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        // DISCONNECTED IS NOT TERMINAL — it is ICE saying "I have stopped
        // hearing from the peer", and it recovers on its own more often than
        // not. Treating it as failure here would tear down calls that were
        // about to come back.
        state.value = CallConnectionState.reconnecting;
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        state.value = CallConnectionState.failed;
        if (!_connectedCompleter.isCompleted) _connectedCompleter.complete(false);
      case RTCPeerConnectionState.RTCPeerConnectionStateNew:
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        state.value = CallConnectionState.connecting;
    }
  }

  Future<void> _onSignal(CallSignal signal) async {
    final pc = _pc;
    if (pc == null || _disposed) return;
    switch (signal) {
      case CallOffer(:final sdp):
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
        await _drainPendingCandidates();
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        await _signalling.send(CallAnswer(answer.sdp!));
      case CallAnswer(:final sdp):
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        await _drainPendingCandidates();
      case CallIceCandidate(:final candidate, :final sdpMid, :final sdpMLineIndex):
        tally.recordRemoteCandidate(candidate);
        final ice = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
        if (_remoteDescriptionSet) {
          await pc.addCandidate(ice);
        } else {
          _pendingRemoteCandidates.add(ice);
        }
    }
  }

  Future<void> _drainPendingCandidates() async {
    _remoteDescriptionSet = true;
    final pending = List<RTCIceCandidate>.from(_pendingRemoteCandidates);
    _pendingRemoteCandidates.clear();
    for (final c in pending) {
      await _pc?.addCandidate(c);
    }
  }

  /// Read the nominated candidate pair into [tally].
  ///
  /// Call AFTER [connected] resolves true — before that there is no selected
  /// pair and the tally would record nothing, which
  /// [IceCandidateTally.usedRelay] correctly reports as null (unmeasured) rather
  /// than as a direct connection.
  Future<void> readSelectedPair() async {
    final pc = _pc;
    if (pc == null) return;
    final reports = await pc.getStats();
    tally.recordSelectedPair([
      for (final r in reports)
        {'id': r.id, 'type': r.type, ...r.values},
    ]);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _signalSub?.cancel();
    await _signalling.dispose();
    await _pc?.close();
    _pc = null;
    if (!_connectedCompleter.isCompleted) _connectedCompleter.complete(false);
    state.dispose();
  }
}
