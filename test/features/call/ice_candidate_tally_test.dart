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

    test('a nominated pair outranks a merely-succeeded one', () {
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
      expect(t.usedRelay, isFalse, reason: 'the nominated pair is the one that carried media');
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
  });
}
