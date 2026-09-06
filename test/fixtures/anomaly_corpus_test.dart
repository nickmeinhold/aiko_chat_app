// The anomaly corpus must exist, in the ordinary suite.
//
// Deliberately NOT tagged `playtest`. The calibration run is tagged and
// therefore skipped by default, so a check living inside it would be skipped
// too — and a corpus quietly disappearing would surface only the next time
// someone ran the model, which may be weeks.
//
// Five of these frames CANNOT BE REGENERATED from current source: they capture
// the bare-`TextStyle` family bug in `appBarTheme` and five sibling slots,
// fixed in 654bbdf and 36cda47. They are the defect arm of a measurement, not
// sample data, so losing one silently degrades a number rather than breaking a
// build. This is what makes that loud.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/blind_anomaly.dart';
import '../support/anomaly_corpus.dart';

void main() {
  test('every labelled frame is on disk', () {
    for (final Frame f in kAnomalyCorpus) {
      expect(
        File('$kAnomalyCorpusDir/${f.name}.png').existsSync(),
        isTrue,
        reason:
            'missing fixture ${f.name}.png — this is ground truth for the '
            'anomaly-pass calibration and five of the frames cannot be '
            'rebuilt from current source',
      );
    }
  });

  test('both arms have frames — a one-armed corpus cannot calibrate', () {
    // Not a tally for its own sake. The clean arm alone is gamed by an agent
    // that never flags; the defect arm alone by one that always does. A corpus
    // that has lost either one produces a number that looks fine and means
    // nothing.
    expect(kAnomalyCorpus.where((f) => !f.defective), hasLength(6));
    expect(kAnomalyCorpus.where((f) => f.defective), hasLength(5));
  });
}
