/// The instrument that decides fallback-vs-deletion, tested where it can go red.
///
/// These are pure-Dart and run in `flutter test` — no platform plugin, no
/// PeerConnection. The *connectivity* claim needs a real stack and lives in
/// `integration_test/p2p_direct_path_test.dart`; this file proves the parsing
/// and the tri-state, which is where a silent miscount would come from.
library;

import 'package:aiko_chat_app/features/call/domain/ice_candidate_tally.dart';
import 'package:flutter_test/flutter_test.dart';

// Real candidate lines, shaped as the stacks emit them (trailing extension
// fields vary, which is exactly why the parser scans for `typ` rather than
// indexing a fixed position).
const _host =
    'candidate:842163049 1 udp 2122260223 192.168.1.5 51234 typ host generation 0 ufrag abcd network-id 1';
const _srflx =
    'candidate:842163049 1 udp 1686052607 203.0.113.7 51234 typ srflx raddr 192.168.1.5 rport 51234 generation 0';
const _relay =
    'candidate:842163049 1 udp 41885439 198.51.100.2 60000 typ relay raddr 203.0.113.7 rport 51234 generation 0';

void main() {
  group('candidate line parsing', () {
    test('reads the typ token regardless of trailing fields', () {
      expect(iceTypeOfCandidateLine(_host), IceCandidateType.host);
      expect(iceTypeOfCandidateLine(_srflx), IceCandidateType.srflx);
      expect(iceTypeOfCandidateLine(_relay), IceCandidateType.relay);
    });

    test('an unknown or absent typ is null, never a guess', () {
      expect(iceTypeOfCandidateLine('candidate:1 1 udp 1 1.2.3.4 1 typ wat'), isNull);
      expect(iceTypeOfCandidateLine('candidate:1 1 udp 1 1.2.3.4 1'), isNull);
      expect(iceTypeOfCandidateLine(''), isNull);
    });

    test('a line ending exactly on `typ` does not read past the end', () {
      // The positional scan reads parts[i+1]; without the bounds check this
      // throws rather than returning null.
      expect(iceTypeOfCandidateLine('candidate:1 1 udp 1 1.2.3.4 1 typ'), isNull);
    });
  });

  group('tally', () {
    test('counts gathered candidates by type on both sides', () {
      final t = IceCandidateTally()
        ..recordLocalCandidate(_host)
        ..recordLocalCandidate(_host)
        ..recordLocalCandidate(_srflx)
        ..recordRemoteCandidate(_relay);

      expect(t.gatheredLocal[IceCandidateType.host], 2);
      expect(t.gatheredLocal[IceCandidateType.srflx], 1);
      expect(t.gatheredRemote[IceCandidateType.relay], 1);
      expect(t.unparsed, 0);
    });

    test('an unparseable candidate is COUNTED, not dropped', () {
      // A silent drop would make the tally under-report and read as a cleaner
      // result than it is — the failure mode this counter exists to prevent.
      final t = IceCandidateTally()..recordLocalCandidate('garbage');
      expect(t.unparsed, 1);
      expect(t.gatheredLocal, isEmpty);
    });

    test('gathering a relay candidate is NOT using one', () {
      // The whole point of reading the selected pair. A peer gathers relay
      // candidates whenever TURN is configured; that says nothing about the
      // path the call took.
      final t = IceCandidateTally()..recordLocalCandidate(_relay);
      expect(t.gatheredLocal[IceCandidateType.relay], 1);
      expect(t.usedRelay, isNull, reason: 'unmeasured, not "no relay"');
    });
  });

  group('selected pair — the number the SFU decision needs', () {
    List<Map<String, dynamic>> statsWith({
      required String localType,
      required String remoteType,
      bool nominated = true,
      String state = 'succeeded',
    }) =>
        [
          {'id': 'cp1', 'type': 'candidate-pair', 'state': state, 'nominated': nominated,
           'localCandidateId': 'lc1', 'remoteCandidateId': 'rc1'},
          {'id': 'lc1', 'type': 'local-candidate', 'candidateType': localType},
          {'id': 'rc1', 'type': 'remote-candidate', 'candidateType': remoteType},
          {'id': 'x', 'type': 'inbound-rtp', 'bytesReceived': 42},
        ];

    test('a direct srflx/srflx pair reports usedRelay false', () {
      final t = IceCandidateTally()
        ..recordSelectedPair(statsWith(localType: 'srflx', remoteType: 'srflx'));
      expect(t.selectedLocal, IceCandidateType.srflx);
      expect(t.usedRelay, isFalse);
    });

    test('a relay on EITHER end counts as the fallback', () {
      final a = IceCandidateTally()
        ..recordSelectedPair(statsWith(localType: 'relay', remoteType: 'srflx'));
      final b = IceCandidateTally()
        ..recordSelectedPair(statsWith(localType: 'srflx', remoteType: 'relay'));
      expect(a.usedRelay, isTrue);
      expect(b.usedRelay, isTrue);
    });

    test('a succeeded-but-not-nominated pair is still read', () {
      // Stacks differ on which field they populate; requiring both would record
      // nothing on half of them — a check whose result is independent of the
      // thing it checks.
      final t = IceCandidateTally()
        ..recordSelectedPair(statsWith(
          localType: 'relay',
          remoteType: 'relay',
          nominated: false,
        ));
      expect(t.usedRelay, isTrue);
    });

    test('a MIXED succeeded set with no transport report and no bytes moved is '
        'UNMEASURED — this assertion used to be the bug', () {
      // CHANGED DELIBERATELY, and the change is the finding. This test used to
      // assert `usedRelay == false` here, with the reason "the nominated pair is
      // the one that carried media". Two things killed it:
      //
      //  1. `nominated == true` appeared on ZERO of ~200 pairs across four live
      //     macOS captures on both ICE roles. The rule this test enshrined has
      //     never fired against a real stack; it was a belief about the W3C spec.
      //  2. Asserting `false` on this data IS the flattering fold. A relay pair
      //     succeeded. Nothing here says which pair carried the call — there is
      //     no transport report and no pair has moved a byte. Answering "direct"
      //     is a guess in the direction that argues for deleting the SFU.
      //
      // The honest answer is `null`: unmeasured. A test that asserted otherwise
      // was not protecting the behaviour, it was pinning the defect in place —
      // which is why this file's own suite could stay green through three
      // instances of the same bug.
      final stats = [
        {'id': 'cp0', 'type': 'candidate-pair', 'state': 'succeeded', 'nominated': false,
         'localCandidateId': 'lcR', 'remoteCandidateId': 'rcR'},
        {'id': 'cp1', 'type': 'candidate-pair', 'state': 'succeeded', 'nominated': true,
         'localCandidateId': 'lcD', 'remoteCandidateId': 'rcD'},
        {'id': 'lcR', 'type': 'local-candidate', 'candidateType': 'relay'},
        {'id': 'rcR', 'type': 'remote-candidate', 'candidateType': 'relay'},
        {'id': 'lcD', 'type': 'local-candidate', 'candidateType': 'srflx'},
        {'id': 'rcD', 'type': 'remote-candidate', 'candidateType': 'srflx'},
      ];
      final t = IceCandidateTally()..recordSelectedPair(stats);
      expect(t.usedRelay, isNull,
          reason: 'a succeeded relay pair with no selection and no bytes is '
              'ambiguous; it must block a false without asserting a true');
    });

    test('POSITIVE CONTROL for the test above: ONE knob — add the transport '
        'report and the same data stops being undecidable', () {
      // Tesla caught the first version of this control turning TWO knobs: it
      // added a transport report AND rewrote the relay pair to host, so it
      // could not isolate which change produced the verdict. One knob now.
      //
      // Note what follows, because it is not `false`: naming the direct pair
      // resolves WHICH pair carried the call, but the relay pair still
      // succeeded without being named, so the reading is ambiguous rather than
      // direct. The control proves the transport report is READ — the source
      // advances and the representative pair resolves — not that it manufactures
      // a convenient answer.
      const stats = [
        {'id': 'tr0', 'type': 'transport', 'selectedCandidatePairId': 'cp1'},
        {'id': 'cp0', 'type': 'candidate-pair', 'state': 'succeeded', 'nominated': false,
         'localCandidateId': 'lcR', 'remoteCandidateId': 'rcR'},
        {'id': 'cp1', 'type': 'candidate-pair', 'state': 'succeeded', 'nominated': true,
         'localCandidateId': 'lcD', 'remoteCandidateId': 'rcD'},
        {'id': 'lcR', 'type': 'local-candidate', 'candidateType': 'relay'},
        {'id': 'rcR', 'type': 'remote-candidate', 'candidateType': 'relay'},
        {'id': 'lcD', 'type': 'local-candidate', 'candidateType': 'srflx'},
        {'id': 'rcD', 'type': 'remote-candidate', 'candidateType': 'srflx'},
      ];
      final t = IceCandidateTally()..recordSelectedPair(stats);
      expect(t.selectedPairSource, SelectedPairSource.transportSelectedId,
          reason: 'the ONE knob turned: the transport report is read');
      expect(t.selectedLocal, IceCandidateType.srflx,
          reason: 'and it resolved the NAMED pair, not the relay one');
      expect(t.usedRelay, isNull,
          reason: 'an unnamed relay that succeeded is still ambiguous — the '
              'control must not manufacture a false');
    });

    test('stats with no succeeded pair leave the tally UNMEASURED', () {
      // The must-not-lie arm: a call that never connected must not read as a
      // successful direct connection.
      final t = IceCandidateTally()
        ..recordSelectedPair([
          {'id': 'cp1', 'type': 'candidate-pair', 'state': 'in-progress', 'nominated': false},
        ]);
      expect(t.selectedLocal, isNull);
      expect(t.usedRelay, isNull);
    });

    test('a dangling candidate id degrades to null rather than throwing', () {
      final t = IceCandidateTally()
        ..recordSelectedPair([
          {'id': 'cp1', 'type': 'candidate-pair', 'state': 'succeeded', 'nominated': true,
           'localCandidateId': 'missing', 'remoteCandidateId': 'alsoMissing'},
        ]);
      expect(t.selectedLocal, isNull);
      expect(t.usedRelay, isNull);
    });

    // THE ARM THAT COULD NOT GO RED, and the bug it was missing.
    //
    // Carnot and Tesla found this independently. The dangling-id test above
    // dangles BOTH ids, so both sides read null and the old `&&` returned null
    // by luck. With only ONE side unresolved the old getter returned FALSE — a
    // measured direct connection — on a call whose other end could have been a
    // relay. Tesla: "the verifier shares the instrument's blind spot."
    test('ONE unresolved end is unmeasured, never a direct connection', () {
      final t = IceCandidateTally()
        ..recordSelectedPair([
          {'id': 'cp1', 'type': 'candidate-pair', 'state': 'succeeded', 'nominated': true,
           'localCandidateId': 'lc1', 'remoteCandidateId': 'danglingRemote'},
          {'id': 'lc1', 'type': 'local-candidate', 'candidateType': 'host'},
        ]);
      expect(t.selectedLocal, IceCandidateType.host);
      expect(t.selectedRemote, isNull);
      expect(t.selectedPairFullyResolved, isFalse);
      expect(t.usedRelay, isNull,
          reason: 'unknown heat loss is not zero heat loss (Carnot)');
    });

    test('a KNOWN relay still reports true even when the other end is unknown', () {
      // The asymmetry is deliberate: positive evidence of a relay is
      // conclusive; absence of evidence is not evidence of absence.
      final t = IceCandidateTally()
        ..recordSelectedPair([
          {'id': 'cp1', 'type': 'candidate-pair', 'state': 'succeeded', 'nominated': true,
           'localCandidateId': 'lc1', 'remoteCandidateId': 'dangling'},
          {'id': 'lc1', 'type': 'local-candidate', 'candidateType': 'relay'},
        ]);
      expect(t.usedRelay, isTrue);
      expect(t.selectedPairFullyResolved, isFalse);
    });

    test('a NOMINATED but not-succeeded pair is ignored', () {
      // Stats order is not ICE priority. A nominated pair that never succeeded
      // carried nothing, and the old first-nominated-wins rule took it anyway.
      final t = IceCandidateTally()
        ..recordSelectedPair([
          {'id': 'cpBad', 'type': 'candidate-pair', 'state': 'in-progress', 'nominated': true,
           'localCandidateId': 'lcR', 'remoteCandidateId': 'rcR'},
          {'id': 'cpGood', 'type': 'candidate-pair', 'state': 'succeeded', 'nominated': false,
           'localCandidateId': 'lcD', 'remoteCandidateId': 'rcD'},
          {'id': 'lcR', 'type': 'local-candidate', 'candidateType': 'relay'},
          {'id': 'rcR', 'type': 'remote-candidate', 'candidateType': 'relay'},
          {'id': 'lcD', 'type': 'local-candidate', 'candidateType': 'srflx'},
          {'id': 'rcD', 'type': 'remote-candidate', 'candidateType': 'srflx'},
        ]);
      expect(t.usedRelay, isFalse,
          reason: 'the in-progress nominated pair never carried media');
      expect(t.selectedLocal, IceCandidateType.srflx);
    });

    test('among succeeded non-nominated pairs, the one carrying bytes wins', () {
      // Multiple succeeded pairs are ordinary (several m-lines, or an ICE
      // restart). Enumeration order is not a tiebreak.
      final t = IceCandidateTally()
        ..recordSelectedPair([
          {'id': 'cpIdle', 'type': 'candidate-pair', 'state': 'succeeded',
           'bytesSent': 0, 'bytesReceived': 0,
           'localCandidateId': 'lcD', 'remoteCandidateId': 'rcD'},
          {'id': 'cpBusy', 'type': 'candidate-pair', 'state': 'succeeded',
           'bytesSent': 900000, 'bytesReceived': 120000,
           'localCandidateId': 'lcR', 'remoteCandidateId': 'rcR'},
          {'id': 'lcD', 'type': 'local-candidate', 'candidateType': 'srflx'},
          {'id': 'rcD', 'type': 'remote-candidate', 'candidateType': 'srflx'},
          {'id': 'lcR', 'type': 'local-candidate', 'candidateType': 'relay'},
          {'id': 'rcR', 'type': 'remote-candidate', 'candidateType': 'relay'},
        ]);
      expect(t.usedRelay, isTrue,
          reason: 'the pair that moved the media is the pair that was the call');
    });
  });
}
