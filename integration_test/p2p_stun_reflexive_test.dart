/// **NETWORK-DEPENDENT. Run deliberately, not in a suite.**
///
/// The loopback test in `p2p_direct_path_test.dart` proves the offer/answer/
/// trickle lifecycle, and proves nothing about the internet — both peers are the
/// same host. This one goes one step closer to reality: it asks a **public STUN
/// server** for this machine's server-reflexive address, which is the actual
/// precondition for a direct call between two devices behind different NATs.
///
/// If a peer cannot gather an `srflx` candidate, it cannot do P2P across the
/// internet at all, and the whole direct-path thesis stops at the first hop.
/// That is worth knowing separately from "the API works".
///
/// ## Why this FAILS rather than skips when offline
///
/// A test that quietly passes without a network is a check whose result is
/// independent of the thing it checks. Offline, this goes red and says so — an
/// honest "could not measure", not a green.
///
/// ## What it still does NOT prove
///
/// Gathering an `srflx` candidate says this host can discover its public
/// address. It does **not** say two peers behind two particular NATs can reach
/// each other — symmetric NAT on either end defeats the pair even when both
/// gathered srflx fine. **The fallback-vs-deletion fraction is still unmeasured
/// and still needs two devices on two real networks.**
///
///     flutter test integration_test/p2p_stun_reflexive_test.dart -d macos
library;

import 'package:aiko_chat_app/features/call/data/loopback_signalling.dart';
import 'package:aiko_chat_app/features/call/data/p2p_peer_session.dart';
import 'package:aiko_chat_app/features/call/domain/ice_candidate_tally.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Public STUN, used read-only for address discovery. Two independent operators
/// so a single one being down is not read as "this host cannot do STUN" — the
/// instrument's own positive control.
const _stunServers = [
  {'urls': 'stun:stun.l.google.com:19302'},
  {'urls': 'stun:stun.cloudflare.com:3478'},
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('this host can discover its public address via STUN',
      (tester) async {
    final pipe = createLoopbackSignallingPair();

    // Only the offerer needs to gather for this measurement; the answerer exists
    // so negotiation proceeds far enough for gathering to start at all.
    final caller = P2pPeerSession(
      role: P2pRole.offerer,
      signalling: pipe.a,
      iceServers: _stunServers,
    );
    final callee = P2pPeerSession(
      role: P2pRole.answerer,
      signalling: pipe.b,
      iceServers: _stunServers,
    );

    // Teardown registered before anything can fail — a red STUN assertion or a
    // timeout must still close two native PeerConnections (Carnot + Tesla).
    addTearDown(() async {
      await caller.dispose();
      await callee.dispose();
      await pipe.a.dispose();
      await pipe.b.dispose();
    });

    await callee.start();
    await caller.start();

    await Future.wait([caller.connected, callee.connected])
        .timeout(const Duration(seconds: 30));

    // Gathering continues after connection; give the STUN round-trips room.
    await Future<void>.delayed(const Duration(seconds: 5));

    final gathered = caller.tally.gatheredLocal;
    // ignore: avoid_print
    print('[P2P-STUN] gathered: $gathered');
    // ignore: avoid_print
    print('[P2P-STUN] selected: ${caller.tally.describe()}');

    expect(
      gathered[IceCandidateType.host] ?? 0,
      greaterThan(0),
      reason: 'host candidates should always gather; if these are absent the '
          'harness is broken, not the network',
    );

    expect(
      gathered[IceCandidateType.srflx] ?? 0,
      greaterThan(0),
      reason: 'NO SERVER-REFLEXIVE CANDIDATE. Either this host is offline (in '
          'which case this is a fact about the run, not about the design), or '
          'it cannot discover its public address — which would mean direct '
          'calls across the internet are not available from here at all.',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
