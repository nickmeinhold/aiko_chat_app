/// **The must-fail arm for the relay knob**, plus the true-positive arm, ready
/// to fire the moment TURN credentials exist.
///
/// ## Why this file exists
///
/// The round-1 cage-match left one residual above all the others (Tesla):
///
/// > The true-positive arm of the instrument has never rung. Twelve pure-Dart
/// > fixtures and a loopback with no TURN prove you can see *host*. The number
/// > you want is the other harmonic.
///
/// `IceCandidateTally` exists to count relays, and it has never seen one. Worse,
/// nothing yet proves `iceTransportPolicy` does anything at all — and if that
/// knob is inert, every relay measurement taken with it is meaningless while
/// looking exactly like a measurement.
///
/// So: two arms, in the order that matters.
///
/// **Arm 1 — the negative control, and it needs no credentials.** Force
/// relay-only with NO TURN server configured. A relay-only peer with nowhere to
/// relay through has no usable candidate pair, so the connection **must fail**.
/// If it connects anyway, the policy is being ignored, and that is the finding —
/// discovered here for the price of one test rather than discovered later as an
/// inexplicable "everything reports direct".
///
/// This is the arm the island tab argued for tonight, generalised from its own
/// night: *build the must-fail arm before examining whether the check works,
/// because a harness examined for whether it can fail tends to look like it can.*
///
/// **Arm 2 — the true positive**, which needs a real TURN endpoint. Gated on
/// `--dart-define` and **skipped loudly** rather than silently, because a test
/// that quietly passes without its subject is a check independent of the thing
/// it checks.
///
/// ### The credential does not exist as a static secret — corrected 2026-09-01
///
/// The first version of this arm asked for `TURN_URL/TURN_USER/TURN_PASS` as
/// though someone could hand them over. **They cannot.** The island tab checked
/// the live `livekit.yaml`: both islands run LiveKit's *embedded* TURN, whose
/// `turn:` block carries `enabled`, `domain`, `udp_port`, `tls_port: 443`,
/// `bind_addresses`, certs and `deny_peer_cidrs` — and no credential. **LiveKit
/// issues session-bound TURN credentials derived from the API key at JOIN
/// time.** So the arm was armed for a shape that does not exist, which is a
/// readiness that would never have fired: exactly the failure this file's own
/// loud-skip exists to prevent, one level up.
///
/// ### The real route, and it IS reachable from Dart (checked, locked 2.10.0)
///
/// The island tab flagged Dart-reachability as its own unchecked question,
/// because on their side the credential is stranded in the Rust FFI layer and
/// never reaches Python. **In Dart it is public.** Read from the locked
/// `livekit_client` 2.10.0:
///
/// - `livekit_rtc.pb.dart:3121` — `ICEServer` carries `urls`, `username`,
///   `credential`, and `JoinResponse.iceServers` carries a list of them.
/// - `engine.dart:1325` — the engine emits `EngineJoinResponseEvent(response:)`
///   on its own event bus, and `src/events.dart` is exported from
///   `livekit_client.dart`, so the event type is public.
/// - `room.dart:119` — `final Engine engine` is a public field on `Room`.
/// - `extensions.dart:41` → `types/other.dart:241` — the proto converts to a
///   public `RTCIceServer` that PRESERVES `username`/`credential`, with a
///   `toMap()` emitting exactly the shape `createPeerConnection` wants.
///
/// So the route is: mint a token from the island's existing endpoint, join,
/// take the issued `iceServers` off the join response, and hand them to
/// [P2pPeerSession] with [P2pIceTransportPolicy.relay]. **No new infrastructure
/// and no secret changes hands** — the credential is issued to this client, for
/// this session, by the legitimate path. That harness is not built here because
/// it needs a live token and a person awake to authorise pointing it at a real
/// island.
///
/// The `--dart-define`s below remain as the injection point for whatever
/// produces those values (the join harness, or a standalone test TURN).
///
///     flutter test integration_test/p2p_relay_policy_test.dart -d macos
///     #   --dart-define=TURN_URL=turns:chat.enspyr.co:443
///     #   --dart-define=TURN_USER=<session-issued>  --dart-define=TURN_PASS=<session-issued>
///
/// **Two live details, before anyone reads a red as a verdict** (island tab):
/// `bind_addresses: 10.0.0.22` on imagineering is a secondary IP and silently
/// kills the UDP relay if `rtc.node_ip` drifts from it (claude-tasks#3133); and
/// `deny_peer_cidrs: 100.64.0.0/10` means the TURN **refuses to relay into CGNAT
/// space by policy**, so a relay attempt toward such a peer fails BY DESIGN.
/// Reading that as "relay unavailable" would be a fresh instance of the very
/// class this file exists to close. Also claude-tasks#3353: one of seven
/// relay-only connects failed unreproducibly, so a single green is an
/// observation, not a distribution.
library;

import 'package:aiko_chat_app/features/call/data/loopback_signalling.dart';
import 'package:aiko_chat_app/features/call/data/p2p_peer_session.dart';
import 'package:aiko_chat_app/features/call/domain/ice_candidate_tally.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _turnUrl = String.fromEnvironment('TURN_URL');
const _turnUser = String.fromEnvironment('TURN_USER');
const _turnPass = String.fromEnvironment('TURN_PASS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'NEGATIVE CONTROL: relay-only with no TURN must NOT connect',
      (tester) async {
    // If this test goes green by CONNECTING, the relay policy is inert and every
    // relay measurement the tally will ever take is worthless. That is why it is
    // written as a must-fail rather than assumed.
    final pipe = createLoopbackSignallingPair();

    final caller = P2pPeerSession(
      role: P2pRole.offerer,
      signalling: pipe.a,
      iceTransportPolicy: P2pIceTransportPolicy.relay,
    );
    final callee = P2pPeerSession(
      role: P2pRole.answerer,
      signalling: pipe.b,
      iceTransportPolicy: P2pIceTransportPolicy.relay,
    );
    addTearDown(() async {
      await caller.dispose();
      await callee.dispose();
      await pipe.a.dispose();
      await pipe.b.dispose();
    });

    await callee.start();
    await caller.start();

    // A relay-only peer with no TURN gathers nothing usable. It will sit in
    // `connecting` and eventually fail; either way it must not reach connected.
    // The wait is bounded and a TIMEOUT IS A PASS here — the assertion is on the
    // absence of a connection, so we check the flag rather than the future.
    final settled = await Future.any([
      Future.wait([caller.connected, callee.connected]).then((r) => r),
      Future<List<bool>>.delayed(const Duration(seconds: 20), () => const []),
    ]);

    // ignore: avoid_print
    print('[P2P-RELAY] relay-only, no TURN → settled=$settled '
        'caller.gathered=${caller.tally.gatheredLocal}');

    expect(
      settled.contains(true),
      isFalse,
      reason: 'A relay-only peer with NO TURN server connected anyway. That '
          'means iceTransportPolicy is being ignored, and every relay '
          'measurement taken with this knob is meaningless.',
    );

    // The corroborating half: relay-only must also not have gathered host
    // candidates. If it did, the policy was ignored at gathering time too.
    expect(
      caller.tally.gatheredLocal[IceCandidateType.host] ?? 0,
      0,
      reason: 'relay-only gathered HOST candidates — the policy is not applied',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets(
      'TRUE POSITIVE: a forced relay connection reports usedRelay == true',
      (tester) async {
    if (_turnUrl.isEmpty) {
      // LOUD skip, never a silent pass. A green suite must not imply this arm
      // ran — the whole point of the arm is that the instrument has never seen
      // a relay, and pretending otherwise would be the exact failure the tally
      // itself was fixed for.
      // ignore: avoid_print
      print('[P2P-RELAY] TRUE-POSITIVE ARM NOT RUN — no TURN_URL provided. '
          'The instrument has still never observed an actual relay. NOTE: the '
          'credential is session-bound and issued at JOIN time; it is NOT a '
          'static secret anyone can supply. See this file header for the '
          'reachable-from-Dart route (Room.engine -> EngineJoinResponseEvent '
          '-> response.iceServers, which preserves username/credential).');
      markTestSkipped('TURN credentials not supplied — arm did not run');
      return;
    }

    final pipe = createLoopbackSignallingPair();
    final turn = <String, dynamic>{
      'urls': _turnUrl,
      if (_turnUser.isNotEmpty) 'username': _turnUser,
      if (_turnPass.isNotEmpty) 'credential': _turnPass,
    };

    final caller = P2pPeerSession(
      role: P2pRole.offerer,
      signalling: pipe.a,
      iceServers: [turn],
      iceTransportPolicy: P2pIceTransportPolicy.relay,
    );
    final callee = P2pPeerSession(
      role: P2pRole.answerer,
      signalling: pipe.b,
      iceServers: [turn],
      iceTransportPolicy: P2pIceTransportPolicy.relay,
    );
    addTearDown(() async {
      await caller.dispose();
      await callee.dispose();
      await pipe.a.dispose();
      await pipe.b.dispose();
    });

    await callee.start();
    await caller.start();

    expect(
      await Future.wait([caller.connected, callee.connected])
          .timeout(const Duration(seconds: 45)),
      [true, true],
      reason: 'relay-only connect failed. Note claude-tasks#3353: one of seven '
          'relay-only connects failed unreproducibly island-side, so a single '
          'red here is an observation, not a verdict on the endpoint.',
    );

    await caller.readSelectedPair();

    // ignore: avoid_print
    print('[P2P-RELAY] TRUE POSITIVE: ${caller.tally.describe()}');

    expect(caller.tally.selectedPairFullyResolved, isTrue);
    expect(caller.tally.selectedLocal, IceCandidateType.relay);
    expect(
      caller.tally.usedRelay,
      isTrue,
      reason: 'THE ARM THAT HAD NEVER RUNG: the tally must report true when a '
          'call genuinely went through TURN. Until this passes once against a '
          'live endpoint, usedRelay==false has only ever been observed, never '
          'usedRelay==true.',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
