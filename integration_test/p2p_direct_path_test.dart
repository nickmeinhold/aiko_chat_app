/// **The claim, made falsifiable:** two `flutter_webrtc` peers connect to each
/// other with no SFU, no LiveKit, and no signalling server — so the centralised
/// media plane is a workaround for a rendezvous problem, not a technical
/// necessity (claude-tasks#3740).
///
/// ## Why this is an integration test and not a unit test
///
/// `createPeerConnection` is a platform plugin call. In `flutter test` there is
/// no native implementation behind the method channel, so a "unit test" of this
/// would be testing a mock of the thing under test — a check whose result is
/// independent of what it checks. This runs on a real host (macOS is the cheap
/// one: `flutter test integration_test/p2p_direct_path_test.dart -d macos`),
/// where the native WebRTC stack is actually present.
///
/// ## What this test DOES prove
///
/// That the full offer → answer → trickle → connected lifecycle works against
/// the locked `flutter_webrtc` 1.6.0, driven by this app's own session class,
/// with LiveKit nowhere in the path.
///
/// ## What it does NOT prove, stated because a green here is easy to over-read
///
/// **Nothing about NAT traversal.** Both peers are the same host, so they
/// connect on `host` candidates over loopback. The 10-20%-of-calls-need-a-relay
/// question — the one that decides whether the SFU is a fallback or a deletion —
/// **cannot be answered by this test and is not answered by it.** That needs two
/// devices on real, different networks. The tally is asserted here only to prove
/// the instrument reads a real stack; its verdict on this run (`host`) is a fact
/// about a loopback, not about the internet.
library;

import 'dart:async';

import 'package:aiko_chat_app/features/call/data/loopback_signalling.dart';
import 'package:aiko_chat_app/features/call/data/p2p_peer_session.dart';
import 'package:aiko_chat_app/features/call/domain/call_connection_state.dart';
import 'package:aiko_chat_app/features/call/domain/call_signalling.dart';
import 'package:aiko_chat_app/features/call/domain/ice_candidate_tally.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('two peers connect directly, with no SFU in the path',
      (tester) async {
    final pipe = createLoopbackSignallingPair();

    final caller = P2pPeerSession(role: P2pRole.offerer, signalling: pipe.a);
    final callee = P2pPeerSession(role: P2pRole.answerer, signalling: pipe.b);
    // Registered IMMEDIATELY after construction, not after the expects.
    // Carnot and Tesla both caught the original: teardown sat at the end of the
    // body, so a red assertion or the 30s timeout skipped `close()` and left two
    // native PeerConnections, their ICE threads and their sockets alive — and
    // the next test in the process then runs in a different universe. For a
    // network-dependent spike, failure is an expected measurement outcome, so
    // cleanup cannot be on the success path.
    addTearDown(() async {
      await caller.dispose();
      await callee.dispose();
      await pipe.a.dispose();
      await pipe.b.dispose();
    });

    // The answerer starts FIRST. If the offerer sent its offer before the
    // answerer was listening, a broadcast stream would drop it and the call
    // would hang — the ordering hazard a real transport has to solve too, and
    // the reason this line is not a stylistic choice.
    await callee.start();
    await caller.start();

    final results = await Future.wait([
      caller.connected,
      callee.connected,
    ]).timeout(const Duration(seconds: 30));

    expect(results, [true, true], reason: 'both peers should reach connected');
    expect(caller.state.value, CallConnectionState.connected);
    expect(callee.state.value, CallConnectionState.connected);

    await caller.readSelectedPair();

    // BOTH ends asserted. The original checked only `selectedLocal`, which a
    // half-resolved pair satisfies — the verifier sharing the instrument's blind
    // spot (Tesla). `selectedPairFullyResolved` is the single assertion that
    // cannot be satisfied by a partial parse.
    expect(
      caller.tally.selectedPairFullyResolved,
      isTrue,
      reason: 'getStats() should yield a fully-resolved nominated pair',
    );
    expect(caller.tally.selectedRemote, isNotNull);
    expect(caller.tally.usedRelay, isFalse,
        reason: 'no TURN configured, so a relay pair would be impossible');

    // Loopback: expect host candidates. Asserted so that if this ever starts
    // reporting srflx/relay, someone has changed the harness and the "what this
    // does not prove" caveat above has silently changed meaning.
    expect(caller.tally.selectedLocal, IceCandidateType.host);

    // ignore: avoid_print — the point of the run is this line in the log.
    print('[P2P-SPIKE] caller: ${caller.tally.describe()}');
    // ignore: avoid_print
    print('[P2P-SPIKE] callee gathered: ${callee.tally.gatheredLocal}');
  });

  testWidgets('a candidate that arrives BEFORE the offer is buffered, not dropped',
      (tester) async {
    // FORCED, not hoped for. The original version asserted only that the call
    // connected and that some remote candidates were seen — both true whether
    // candidates hit `_pendingRemoteCandidates` or went straight to
    // `addCandidate`. Remove the buffer and it still passed. Carnot and Tesla
    // both named it: a check whose result is independent of the thing it checks.
    //
    // This double GUARANTEES the race by holding the offer back until at least
    // one candidate has been delivered ahead of it — the ordering a real
    // at-least-once, locally-out-of-order transport produces, and the exact
    // ordering `addCandidate`-before-`setRemoteDescription` throws on.
    final pipe = createLoopbackSignallingPair();
    final reordered = _OfferDelayingSignalling(pipe.b);

    final caller = P2pPeerSession(role: P2pRole.offerer, signalling: pipe.a);
    final callee = P2pPeerSession(role: P2pRole.answerer, signalling: reordered);
    addTearDown(() async {
      await caller.dispose();
      await callee.dispose();
      await reordered.dispose();
      await pipe.a.dispose();
    });

    await callee.start();
    await caller.start();

    expect(
      await Future.wait([caller.connected, callee.connected])
          .timeout(const Duration(seconds: 30)),
      [true, true],
      reason: 'a candidate delivered before the offer must not break the call',
    );

    expect(
      reordered.candidatesDeliveredBeforeOffer,
      greaterThan(0),
      reason: 'the double must actually have produced the race it exists to '
          'force — zero here means this test proved nothing',
    );
    // ignore: avoid_print
    print('[P2P-SPIKE] candidates delivered BEFORE the offer: '
        '${reordered.candidatesDeliveredBeforeOffer}');
  });
}

/// Holds the offer back until at least one ICE candidate has been delivered,
/// forcing the trickle-before-SDP ordering the session's buffer exists for.
///
/// A real transport produces this ordering by accident; a loopback never will,
/// because it delivers in send order and the offer is sent first. So the race is
/// manufactured deterministically rather than waited for.
class _OfferDelayingSignalling implements CallSignalling {
  _OfferDelayingSignalling(this._inner) {
    _sub = _inner.inbound.listen(_onInbound);
  }

  final CallSignalling _inner;
  late final StreamSubscription<CallSignal> _sub;
  final _out = StreamController<CallSignal>.broadcast();

  CallOffer? _heldOffer;
  int candidatesDeliveredBeforeOffer = 0;

  void _onInbound(CallSignal s) {
    switch (s) {
      case CallOffer():
        // Hold it. It is released by the first candidate to arrive after it.
        _heldOffer = s;
      case CallIceCandidate():
        if (_heldOffer != null) {
          // Deliver the CANDIDATE first — the whole point — then the offer.
          candidatesDeliveredBeforeOffer++;
          _out.add(s);
          _out.add(_heldOffer!);
          _heldOffer = null;
        } else {
          _out.add(s);
        }
      case CallAnswer():
        _out.add(s);
    }
  }

  @override
  Stream<CallSignal> get inbound => _out.stream;

  @override
  Future<void> send(CallSignal signal) => _inner.send(signal);

  @override
  Future<void> dispose() async {
    await _sub.cancel();
    // Release a still-held offer's memory; nothing is listening by now.
    _heldOffer = null;
    await _out.close();
    await _inner.dispose();
  }
}
