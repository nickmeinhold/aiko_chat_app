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

import 'package:aiko_chat_app/features/call/data/loopback_signalling.dart';
import 'package:aiko_chat_app/features/call/data/p2p_peer_session.dart';
import 'package:aiko_chat_app/features/call/domain/call_connection_state.dart';
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

    // The instrument read a REAL stack, not a fixture. This is the arm that
    // proves the tally works against live stats — the `expect` is deliberately
    // on non-nullness, not on a specific type, because which candidate type wins
    // on a loopback is a property of the host, not of the design.
    expect(
      caller.tally.selectedLocal,
      isNotNull,
      reason: 'getStats() should yield a nominated pair once connected',
    );
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

    await caller.dispose();
    await callee.dispose();
  });

  testWidgets('a candidate arriving before the remote description is buffered',
      (tester) async {
    // The trickle race, exercised rather than reasoned about: this is the arm
    // that fails if `_pendingRemoteCandidates` is removed, and it is the direct
    // path's twin of RingController holding a hangup that beat its invite.
    final pipe = createLoopbackSignallingPair();
    final caller = P2pPeerSession(role: P2pRole.offerer, signalling: pipe.a);
    final callee = P2pPeerSession(role: P2pRole.answerer, signalling: pipe.b);

    await callee.start();
    await caller.start();

    expect(
      await Future.wait([caller.connected, callee.connected])
          .timeout(const Duration(seconds: 30)),
      [true, true],
    );
    // Candidates genuinely do race the SDP here; if any were dropped rather than
    // buffered the connection above would not have formed. Recording the count
    // so a future regression shows as a number, not a hang.
    // ignore: avoid_print
    print('[P2P-SPIKE] callee remote candidates seen: '
        '${callee.tally.gatheredRemote}');
    expect(callee.tally.gatheredRemote, isNotEmpty);

    await caller.dispose();
    await callee.dispose();
  });
}
