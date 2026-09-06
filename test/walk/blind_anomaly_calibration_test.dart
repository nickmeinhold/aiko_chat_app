// How often does the anomaly pass invent a defect that is not there?
//
//   flutter test --run-skipped --tags playtest \
//     test/walk/blind_anomaly_calibration_test.dart
//
// THIS IS A REPORT GENERATOR, NOT A GATE, and that is a decision rather than an
// omission. The reading is a property of a MODEL on a given day, not of this
// repo's code, so a threshold asserted here would go red for a reason no commit
// caused and be silenced within a week. What the file asserts is that the
// measurement is VALID; what it prints is the number. The number's home is a
// longitudinal record, where a series means something a single run cannot.
//
// THE ORIGINAL DONE-CONDITION WAS WRONG, and replacing it is the point of this
// file. The plan was: re-plant the app-bar bug, confirm the pass flags it. That
// is n=1 on a coin nobody has examined — AN AGENT THAT FLAGS EVERY SCREEN PASSES
// IT PERFECTLY. The measurement that decides whether this instrument is worth
// having is the opposite one: how often does it flag a screen that is FINE.
//
// So both arms run in one report and neither is allowed to stand alone:
//
//   CLEAN arm   6 frames known good   -> the FALSE-POSITIVE rate. The headline.
//   DEFECT arm  5 frames known broken -> the catch rate. Confirmation, and the
//                                        must-fail arm for the whole file: an
//                                        agent that never flags anything scores
//                                        a perfect 0% false positives, so a
//                                        catch rate of zero VOIDS the clean arm
//                                        rather than complementing it.
//
// THE CORPUS IS FROZEN, DELIBERATELY. These eleven PNGs are the unique screens
// from the blind playtester's first sweep on 2026-09-05 — 24 frames that dedupe
// to 11, because ten of them are the same chat home. Replaying all 24 would
// report n=24 for an independent sample of 11.
//
// Five of them can no longer be regenerated: they show the bare-`TextStyle`
// family bug in `appBarTheme` and five sibling slots, fixed in 654bbdf and
// 36cda47. That makes them MORE valuable, not less — a defect arm you cannot
// rebuild from current source is the only kind that stays honest — and it is
// why they live in `test/fixtures/` rather than in `/tmp`, which self-clears.
//
// COVERAGE BOUNDARY, said out loud so no green here is read wider than it is:
// every frame in the defect arm carries the SAME visual signature, a solid
// block of ink where glyphs belong. A catch rate measured on this corpus says
// nothing about whether the pass can see a layout defect, a contrast failure,
// an overflow, or a control that is present but wrong. Those need frames this
// corpus does not contain.
@Tags(['playtest'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/anomaly_corpus.dart';
import '../support/blind_anomaly.dart';

const _scratch = '/tmp/aiko-playtest/anomaly';

/// How many times each frame is shown. The verdict is stochastic; one reading
/// is an observation, not a rate.
const _trials = 3;

void main() {
  testWidgets('anomaly pass · calibration', (tester) async {
    final eyes = claudeAnomalyEyes(scratchDir: _scratch);

    final clean = Arm('clean frames flagged');
    final defect = Arm('defect frames flagged');
    final rows = <String>[];

    for (final f in kAnomalyCorpus) {
      final said = <String>[];
      var flags = 0;
      for (var i = 0; i < _trials; i++) {
        final v = await tester.runAsync(
          () => eyes(File('$kAnomalyCorpusDir/${f.name}.png')),
        );
        if (v == null) {
          throw StateError('runAsync returned null for ${f.name}');
        }
        if (v is Anomaly) flags++;
        said.add('    ${v.runtimeType == Anomaly ? '!' : ' '} ${v.said}');
        (f.defective ? defect : clean).add(flaggedIt: v is Anomaly);
      }
      rows.add(
        '${f.name.padRight(28)} ${f.defective ? 'DEFECT' : 'clean '} '
        'flagged $flags/$_trials\n${said.join('\n')}',
      );
    }

    final report =
        '\n=== ANOMALY PASS CALIBRATION ===\n'
        '$_trials trial(s) per frame, ${kAnomalyCorpus.length} frames\n\n'
        '${clean.line}   <- FALSE POSITIVES (the headline; lower is better)\n'
        '${defect.line}   <- CATCHES (confirmation; higher is better)\n\n'
        '${rows.join('\n\n')}\n';
    // ignore: avoid_print
    print(report);

    // THE MUST-FAIL ARM, and the only assertion in the file.
    //
    // It does not judge the agent — it judges whether the clean-arm number
    // MEANS anything. An agent that answers OK to everything scores a perfect
    // 0% false-positive rate while being completely blind, and every frame in
    // the defect arm is a screen where a human found a real bug by looking.
    // If none of them are flagged, this run measured a constant, and the
    // headline number above must not be recorded.
    expect(
      defect.flagged,
      greaterThan(0),
      reason:
          'the pass flagged NONE of ${defect.total} readings on frames known to '
          'be broken, so it cannot distinguish broken from fine and the '
          'false-positive rate of ${(clean.rate * 100).toStringAsFixed(0)}% is a '
          'fact about a constant answer, not about this instrument. Do not '
          'record the number from this run.',
    );
  });
}
