/// Harvest a REPLAYABLE `getStats()` report from the platform under test.
///
/// ## Why this exists
///
/// `IceCandidateTally.recordSelectedPair` decides whether a call went through a
/// relay — the number the fallback-vs-deletion question turns on. Every fixture
/// that parser was tested against was written by this repo, which proves it is
/// self-consistent and nothing else. A corpus invented from a mental model of
/// the W3C stats spec would be coherent, would go green, and would be a fact
/// about its author. Four adversarial families reviewed the parser against that
/// same model; the first harvest of a live stack contradicted it on the
/// answering side.
///
/// So this test asserts almost nothing. **It produces the corpus**, from a real
/// connection, and `test/features/call/ice_candidate_tally_corpus_test.dart`
/// replays what it produced.
///
/// ## Pseudonymised, not redacted — the distinction is load-bearing
///
/// The first version blanket-redacted every id, which destroyed the exact
/// relation the parser walks (`transport.selectedCandidatePairId` →
/// `candidate-pair.id` → `local/remoteCandidateId` → `candidate.candidateType`)
/// and produced a fixture that could not be replayed. Ids are therefore mapped
/// to stable synthetic tokens: structure survives, and no address, credential or
/// certificate leaves the machine. Addresses are dropped outright rather than
/// tokenised — nothing in the parser reads them.
///
/// ## The coverage boundary, stated because a corpus implies completeness
///
/// One run describes ONE platform and ONE call shape (loopback, data channel
/// only, no TURN). It is not evidence about Android, about a relayed call, or
/// about multiple m-lines. The two serialisers do not even agree in principle:
/// Darwin (`common/darwin/Classes/FlutterRTCPeerConnection.m`) passes
/// `report.values` through untransformed, while Android
/// (`PeerConnectionObserver.java:231-277`) filters members through an allowlist
/// type-switch and silently DROPS anything unlisted. Re-run this per platform.
library;

import 'dart:convert';

import 'package:aiko_chat_app/features/call/data/loopback_signalling.dart';
import 'package:aiko_chat_app/features/call/data/p2p_peer_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Keys whose value is an address, credential or certificate. Dropped, not
/// tokenised — the parser never reads them, so preserving them would be risk
/// with no test value.
const _dropped = {
  'address',
  'ip',
  'relatedAddress',
  'url',
  'usernameFragment',
  'iceLocalUsernameFragment',
  'dtlsCipher',
  'srtpCipher',
  'tlsVersion',
  'localCertificateId',
  'remoteCertificateId',
};

/// Keys whose value is an id that must stay REFERENTIALLY INTACT.
const _idKeys = {
  'id',
  'localCandidateId',
  'remoteCandidateId',
  'transportId',
  'selectedCandidatePairId',
  'foundation',
};

const _typesOfInterest = {
  'candidate-pair',
  'local-candidate',
  'remote-candidate',
  'transport',
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('harvest a replayable getStats() corpus from a live stack',
      (tester) async {
    final pipe = createLoopbackSignallingPair();
    final caller = P2pPeerSession(role: P2pRole.offerer, signalling: pipe.a);
    final callee = P2pPeerSession(role: P2pRole.answerer, signalling: pipe.b);
    addTearDown(() async {
      await caller.dispose();
      await callee.dispose();
      await pipe.a.dispose();
      await pipe.b.dispose();
    });

    await callee.start();
    await caller.start();
    final connected = await Future.wait([caller.connected, callee.connected])
        .timeout(const Duration(seconds: 30));
    expect(connected, [true, true], reason: 'a harvest needs a live connection');

    // BOTH ICE roles. The offerer is `controlling` and the answerer
    // `controlled`, they do not report alike, and a harvest of one is not
    // evidence about the other — this is the axis a single run leaves unvaried.
    await _harvest('caller', caller);
    await _harvest('callee', callee);
  });
}

Future<void> _harvest(String label, P2pPeerSession session) async {
  final reports = await session.peerConnection!.getStats();

  final pseudonyms = <String, String>{};
  String tokenFor(String real) =>
      pseudonyms.putIfAbsent(real, () => 'x${pseudonyms.length}');

  final out = <Map<String, Object?>>[];
  for (final r in reports) {
    if (!_typesOfInterest.contains(r.type)) continue;
    // id/type are overlaid LAST, matching production's
    // `{...r.values, 'id': r.id, 'type': r.type}` precedence. Painting them
    // FIRST and letting `values` overwrite (the original) gives the harvester
    // the OPPOSITE precedence to the reader — so if a platform ever put `type`
    // inside `values`, the corpus would not be the projection the tally sees,
    // and every replay would be testing a shape production never receives.
    // Round 1 killed this exact clobber in the reader; it survived in the
    // writer of the ground truth (Tesla).
    final row = <String, Object?>{};
    for (final e in r.values.entries) {
      final k = e.key.toString();
      if (_dropped.contains(k)) continue;
      final v = e.value;
      if (_idKeys.contains(k)) {
        row[k] = v is String ? tokenFor(v) : v;
      } else {
        // Everything else verbatim, INCLUDING its runtime type — the point of
        // the corpus is that `state`, `nominated`, `bytesSent` and
        // `candidateType` arrive exactly as the platform sent them.
        row[k] = v;
      }
    }
    row['id'] = tokenFor(r.id);
    row['type'] = r.type;
    out.add(row);
  }

  // ignore: avoid_print — the corpus IS the output of this test.
  print('[CORPUS:$label]${jsonEncode(out)}[/CORPUS:$label]');

  expect(out.where((r) => r['type'] == 'candidate-pair'), isNotEmpty,
      reason: 'a connected peer must emit candidate-pair reports; an empty '
          'harvest is a fact about the instrument, not about the platform');

  // The PRIMARY read path is `transport.selectedCandidatePairId`. A harvest
  // that goes green while emitting no transport report, or a transport with no
  // selected id, would be silently publishing a corpus that cannot exercise the
  // mechanism it exists to prove (Tesla). Assert the field is THERE and that it
  // NAMES a pair actually present — a dangling id is a different corpus.
  final transports = out.where((r) => r['type'] == 'transport').toList();
  expect(transports, isNotEmpty, reason: 'no transport report harvested');
  final selectedIds = transports
      .map((t) => t['selectedCandidatePairId'])
      .whereType<String>()
      .toSet();
  expect(selectedIds, isNotEmpty,
      reason: 'the transport named no selected pair — this corpus cannot '
          'exercise the primary read path');
  final pairIds =
      out.where((r) => r['type'] == 'candidate-pair').map((r) => r['id']).toSet();
  expect(selectedIds.every(pairIds.contains), isTrue,
      reason: 'a selected id naming no harvested pair means the harvest '
          'dropped the very report the tally will resolve');
}
