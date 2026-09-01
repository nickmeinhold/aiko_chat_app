/// The parity corpus: `IceCandidateTally` against reports a real stack emitted.
///
/// ## What makes this different from the fixture tests beside it
///
/// `ice_candidate_tally_test.dart` feeds the parser maps this repo wrote. That
/// proves the parser is self-consistent, which it will be, because the same
/// understanding authored both sides. The parser was ALSO reviewed by four
/// adversarial families working from that same understanding — and the first
/// harvest of a live stack contradicted all of us.
///
/// These fixtures were not authored. They were **harvested** from a live macOS
/// WebRTC connection by `integration_test/stats_shape_harvest_test.dart`, both
/// ICE roles, ids pseudonymised so the referential structure survives and no
/// address or credential is committed. Nothing else was touched: `state`,
/// `nominated`, `bytesSent` and `candidateType` are exactly what the platform
/// sent.
///
/// ## The coverage boundary — stated, because a corpus implies completeness
///
/// | axis | covered here | how |
/// |---|---|---|
/// | Darwin serialiser | **yes** | harvested, macOS, `flutter_webrtc` 1.6.0 |
/// | both ICE roles | **yes** | `controlling` + `controlled` |
/// | Android serialiser | **no** | needs a device; see the note below |
/// | a relayed (TURN) pair | **no** | never once observed — the true-positive arm |
/// | multiple m-lines / BUNDLE off | **no** | one data channel, one transport |
/// | ICE restart | **no** | |
///
/// Android is not merely unharvested, it is known to differ *in kind*. Darwin
/// (`common/darwin/Classes/FlutterRTCPeerConnection.m`) passes `report.values`
/// to the channel untransformed. Android
/// (`PeerConnectionObserver.java:231-277`) filters every member through an
/// allowlist type-switch — String, String[], Integer, Long, Double, Boolean,
/// BigInteger, LinkedHashMap — and anything unlisted is logged and **dropped
/// from the map**. So on Android an unexpected type yields an ABSENT key, while
/// on Darwin it yields a present key of a surprising type. Those two failures
/// need different handling, and only one of them is exercised below.
library;

import 'dart:convert';
import 'dart:io';

import 'package:aiko_chat_app/features/call/domain/ice_candidate_tally.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, dynamic>> _load(String name) {
  final file = File('test/features/call/fixtures/$name.json');
  expect(file.existsSync(), isTrue,
      reason: 'the corpus fixture must exist; a missing file must fail the '
          'test rather than silently reduce its coverage to nothing');
  return (jsonDecode(file.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();
}

void main() {
  group('harvested macOS corpus — both ICE roles', () {
    for (final role in ['caller', 'callee']) {
      test('$role resolves a fully-known pair from the transport report', () {
        final tally = IceCandidateTally()
          ..recordSelectedPair(_load('getstats_macos_$role'));

        expect(tally.selectedPairSource, SelectedPairSource.transportSelectedId,
            reason: 'the stack names its own selected pair; reconstructing it '
                'when it has been stated is how the controlled role got lost');
        expect(tally.selectedPairFullyResolved, isTrue);
        expect(tally.selectedLocal, IceCandidateType.host);
        expect(tally.selectedRemote, IceCandidateType.host);
        expect(tally.usedRelay, isFalse,
            reason: 'loopback, no TURN — a relay here would mean the harness '
                'changed and this fixture no longer describes what it says');
      });
    }

    test('the fixtures are REAL: nominated is false on every pair, both roles',
        () {
      // Not a property we want — a property we found. The selection rule
      // prefers a `nominated` pair, and across 50 harvested pairs on two ICE
      // roles not one was nominated. That branch has never fired against a real
      // stack; it is exercised only by fixtures this repo wrote. Asserted so
      // that if a future harvest DOES produce a nominated pair, this goes red
      // and someone re-reads the rule instead of inheriting it.
      for (final role in ['caller', 'callee']) {
        final pairs = _load('getstats_macos_$role')
            .where((r) => r['type'] == 'candidate-pair');
        expect(pairs, isNotEmpty);
        expect(pairs.where((p) => p['nominated'] == true), isEmpty,
            reason: 'no harvested $role pair was nominated');
      }
    });
  });

  group('the transport path earns its place — controls, not illustrations', () {
    test('POSITIVE CONTROL: strip the transport report and the heuristic still '
        'resolves this particular capture', () {
      final withoutTransport = _load('getstats_macos_callee')
          .where((r) => r['type'] != 'transport')
          .toList();
      final tally = IceCandidateTally()..recordSelectedPair(withoutTransport);

      expect(tally.selectedPairSource, SelectedPairSource.succeededHeuristic);
      expect(tally.selectedPairFullyResolved, isTrue,
          reason: 'this capture happens to contain a succeeded pair, so the '
              'fallback works here — which is exactly why the failure below '
              'was invisible for a whole review round');
    });

    test('RED ARM: a capture whose selected pair is not yet `succeeded` is '
        'UNMEASURED under the heuristic and MEASURED via the transport', () {
      // Derived, not harvested, and labelled as such. The state is set to
      // `in-progress` because that is what was observed once in four live runs
      // on the controlled role: 25 pairs, ZERO succeeded, `iceState: connected`,
      // 1234 bytes moved, and a transport report naming the pair the whole time.
      // A run-to-run race, not a constant — which is worse than a constant,
      // because the resulting bias is intermittent and would have looked like
      // noise in the fallback-vs-deletion fraction rather than like a bug.
      final base = _load('getstats_macos_callee');
      final selectedId = base
          .firstWhere((r) => r['type'] == 'transport')['selectedCandidatePairId']
          as String;
      final degraded = base.map((r) {
        if (r['id'] != selectedId) return r;
        return {...r, 'state': 'in-progress'};
      }).toList();

      // Heuristic alone: blind. This is the must-fail arm — if it ever reports
      // a pair, the fallback has silently changed and the assertion below stops
      // proving anything.
      final heuristicOnly = IceCandidateTally()
        ..recordSelectedPair(
            degraded.where((r) => r['type'] != 'transport').toList());
      expect(heuristicOnly.selectedPairSource, SelectedPairSource.none);
      expect(heuristicOnly.usedRelay, isNull,
          reason: 'unmeasured, not "no relay" — the tri-state is what kept this '
              'from becoming a wrong number instead of a missing one');

      // With the transport report: measured.
      final withTransport = IceCandidateTally()..recordSelectedPair(degraded);
      expect(
          withTransport.selectedPairSource, SelectedPairSource.transportSelectedId);
      expect(withTransport.selectedPairFullyResolved, isTrue);
      expect(withTransport.usedRelay, isFalse);
    });

    test('a transport naming a pair that is not in the report falls back rather '
        'than reporting nothing', () {
      final base = _load('getstats_macos_caller');
      final broken = base.map((r) {
        if (r['type'] != 'transport') return r;
        return {...r, 'selectedCandidatePairId': 'no-such-pair'};
      }).toList();

      final tally = IceCandidateTally()..recordSelectedPair(broken);
      expect(tally.selectedPairSource, SelectedPairSource.succeededHeuristic,
          reason: 'a dangling selected-pair id is a broken stack, not a reason '
              'to throw away a reading the heuristic can still make');
      expect(tally.selectedPairFullyResolved, isTrue);
    });
  });
}
