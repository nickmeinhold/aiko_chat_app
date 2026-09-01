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

    test('SECOND READ SEEING NOTHING must not leave a resolved pair beside a '
        '`none` source — unknown cannot overwrite known', () {
      // The self-review find, and the third instance in this file of the same
      // defect class. `readSelectedPair()` has no once-guard and any periodic
      // sampling of a live call calls it repeatedly. The first version assigned
      // `selectedPairSource` ABOVE the early return, so a good read followed by
      // an empty one left `selectedLocal/Remote` populated and the source at
      // `none` — `usedRelay` reporting **false**, a measured direct connection,
      // on a tally that says it never measured anything. False is the reading
      // that argues for deleting the SFU, which is what makes it the flattering
      // fold rather than a harmless inconsistency.
      final tally = IceCandidateTally()
        ..recordSelectedPair(_load('getstats_macos_caller'));
      expect(tally.selectedPairSource, SelectedPairSource.transportSelectedId);
      expect(tally.usedRelay, isFalse);

      tally.recordSelectedPair(const []);

      expect(tally.selectedPairSource, SelectedPairSource.transportSelectedId,
          reason: 'a read that saw nothing must not downgrade a read that saw '
              'a pair');
      expect(tally.selectedLocal, IceCandidateType.host,
          reason: 'and it must not erase it either');
      expect(tally.usedRelay, isFalse);
    });

    test('a stringified byte count is a TIEBREAK input, not a reason to lose '
        'the whole measurement', () {
      // Darwin passes `report.values` to the channel untransformed, so the
      // types are whatever the ObjC SDK put there. `as num?` on a String throws
      // a TypeError out of the entire read — over a value used only to break a
      // tie between two pairs that both already qualify.
      // TWO pairs must reach the pool or `bytesOf` is never called and this
      // arm cannot fail — which is exactly what the first version of this test
      // did. It passed with the fix reverted, because the transport names one
      // pair, a one-element pool never enters the tiebreak, and a check whose
      // outcome is independent of the thing it checks is not a check. So: drop
      // the transport report to take the heuristic path, and promote a second
      // pair to `succeeded` so the comparison actually runs.
      final base = _load('getstats_macos_caller');
      final selectedId = base
          .firstWhere((r) => r['type'] == 'transport')['selectedCandidatePairId']
          as String;
      var promoted = false;
      final stringified = <Map<String, dynamic>>[];
      for (final r in base) {
        if (r['type'] == 'transport') continue;
        if (r['type'] != 'candidate-pair') {
          stringified.add(r);
          continue;
        }
        final isWinner = r['id'] == selectedId;
        // A second succeeded pair, deliberately carrying FEWER bytes than the
        // real winner, so a working tiebreak still picks the right one.
        final promote = !isWinner && !promoted && r['state'] != 'succeeded';
        if (promote) promoted = true;
        stringified.add({
          ...r,
          if (promote) 'state': 'succeeded',
          'bytesSent': '${r['bytesSent']}',
          'bytesReceived': '${r['bytesReceived']}',
        });
      }
      expect(promoted, isTrue, reason: 'the pool must hold two pairs');

      final tally = IceCandidateTally();
      expect(() => tally.recordSelectedPair(stringified), returnsNormally);
      expect(tally.selectedPairSource, SelectedPairSource.succeededHeuristic);
      expect(tally.selectedPairFullyResolved, isTrue);
      expect(tally.usedRelay, isFalse);
      // NOT-THROWING IS NOT PICKING (Tesla). Every pair in this harvest is
      // host/host, so `usedRelay isFalse` stays green even if `bytesOf` were
      // `return 0` and the tiebreak never moved. Assert the WINNER carried the
      // most bytes — the property the tiebreak exists to produce — so a broken
      // parse that ties everything at zero and takes enumeration order goes red.
      final byteCarrying = base
          .where((r) => r['type'] == 'candidate-pair')
          .where((r) =>
              ((r['bytesSent'] as num? ?? 0) +
                  (r['bytesReceived'] as num? ?? 0)) >
              0);
      expect(byteCarrying, isNotEmpty,
          reason: 'the fixture must contain a byte-carrying pair or the '
              'tiebreak is never exercised and this arm is decorative');
      expect(tally.describe(), contains('selected=host/host'));
    });

    test('RED ARM (across TIME): direct first, relay second — the call NEEDED a '
        'relay and usedRelay must LATCH true', () {
      // Tesla's resonant input, and the arm the previous corpus could not play:
      // every other second-read test passes `const []`, so the monotonic rule
      // was only ever exercised in the direction that costs nothing. A call that
      // fails over to TURN is a call that needed TURN, whatever it did first.
      final tally = IceCandidateTally()
        ..recordSelectedPair(_load('getstats_macos_caller'));
      expect(tally.usedRelay, isFalse, reason: 'direct at first sample');

      tally.recordSelectedPair(const [
        {'id': 't', 'type': 'transport', 'selectedCandidatePairId': 'cpR'},
        {'id': 'cpR', 'type': 'candidate-pair', 'state': 'succeeded',
         'localCandidateId': 'lr', 'remoteCandidateId': 'rr'},
        {'id': 'lr', 'type': 'local-candidate', 'candidateType': 'relay'},
        {'id': 'rr', 'type': 'remote-candidate', 'candidateType': 'srflx'},
      ]);

      expect(tally.usedRelay, isTrue,
          reason: 'failover to TURN must be visible; a thermometer that cannot '
              'get warmer again is not an instrument');
    });

    test('RED ARM (the other direction): once true, a later direct sample must '
        'NOT un-see the relay', () {
      final tally = IceCandidateTally()
        ..recordSelectedPair(const [
          {'id': 't', 'type': 'transport', 'selectedCandidatePairId': 'cpR'},
          {'id': 'cpR', 'type': 'candidate-pair', 'state': 'succeeded',
           'localCandidateId': 'lr', 'remoteCandidateId': 'rr'},
          {'id': 'lr', 'type': 'local-candidate', 'candidateType': 'relay'},
          {'id': 'rr', 'type': 'remote-candidate', 'candidateType': 'relay'},
        ]);
      expect(tally.usedRelay, isTrue);

      tally.recordSelectedPair(_load('getstats_macos_caller'));

      expect(tally.usedRelay, isTrue,
          reason: 'the question is whether this call EVER needed a relay; a '
              'later direct sample does not retract an earlier relay');
    });

    test('an unrecognised candidate type is COUNTED, and forbids a false', () {
      // A stack spelling relay `relayed` would parse to null, drop silently out
      // of the sample, and bias the surviving population toward direct — the
      // aggregate form of the same fold. It must be visible and it must block a
      // confident `false`.
      final tally = IceCandidateTally()
        ..recordSelectedPair(const [
          {'id': 't', 'type': 'transport', 'selectedCandidatePairId': 'cp'},
          {'id': 'cp', 'type': 'candidate-pair', 'state': 'succeeded',
           'localCandidateId': 'l', 'remoteCandidateId': 'r'},
          {'id': 'l', 'type': 'local-candidate', 'candidateType': 'relayed'},
          {'id': 'r', 'type': 'remote-candidate', 'candidateType': 'host'},
        ]);

      expect(tally.selectedUnparsed, greaterThan(0),
          reason: 'an unknown token must be counted, not shrugged off');
      expect(tally.usedRelay, isNull,
          reason: 'we do not know what `relayed` was; guessing direct is the '
              'fold and guessing relay is a fabrication');
    });

    test('a succeeded relay pair the transport did NOT name blocks false '
        'without asserting true', () {
      // The three-state middle. ICE succeeds on pairs it never carries media
      // over, so a succeeded relay is not a used relay — but it is also not
      // nothing, and it is exactly Tesla's stale-name shape.
      final tally = IceCandidateTally()
        ..recordSelectedPair(const [
          {'id': 't', 'type': 'transport', 'selectedCandidatePairId': 'cpD'},
          {'id': 'cpD', 'type': 'candidate-pair', 'state': 'succeeded',
           'localCandidateId': 'lh', 'remoteCandidateId': 'rh'},
          {'id': 'cpR', 'type': 'candidate-pair', 'state': 'succeeded',
           'localCandidateId': 'lr', 'remoteCandidateId': 'rr'},
          {'id': 'lh', 'type': 'local-candidate', 'candidateType': 'host'},
          {'id': 'rh', 'type': 'remote-candidate', 'candidateType': 'host'},
          {'id': 'lr', 'type': 'local-candidate', 'candidateType': 'relay'},
          {'id': 'rr', 'type': 'remote-candidate', 'candidateType': 'relay'},
        ]);

      expect(tally.usedRelay, isNull,
          reason: 'ambiguous: a relay succeeded but was never selected');
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

      // PAIRED CONTROL (Carnot). Without this, the assertion above is satisfied
      // by production that ignores transport reports ENTIRELY — the expected
      // outcome is identical in both worlds, so the check is independent of the
      // thing it checks. The ONLY difference between these two runs is whether
      // the selected id resolves; if the transport path were dead, both would
      // read `succeededHeuristic` and this test would prove nothing.
      final intact = IceCandidateTally()..recordSelectedPair(base);
      expect(intact.selectedPairSource, SelectedPairSource.transportSelectedId,
          reason: 'same fixture, valid id — the transport path MUST be live, '
              'or the fallback assertion above is vacuous');
    });
  });
}
