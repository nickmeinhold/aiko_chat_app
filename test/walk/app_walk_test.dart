// Automated playtesting over the real app tree.
//
// Runs before a store submission: 0.0.4 carries ~48 commits of UI (the maritime
// redesign, theme presets, the palette editor, the typeface picker, navigable
// DMs, mute, the island mark) that the scripted suite covers a path at a time.
// These walks cover the COMBINATIONS — the screen reached by three taps nobody
// sequenced together.
//
// Each seed is a separate test so a failure names one walk rather than "the
// walker failed", and a fixed seed that once found a bug can be kept forever as
// an ordinary regression test.
import 'package:flutter_test/flutter_test.dart';

import '../support/app_walker.dart';
import '../support/test_helpers.dart';
import '../support/walk_harness.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  // A spread of seeds rather than one: a single walk is one sample of the state
  // space, and the whole point is to visit combinations a single path misses.
  for (final seed in [1, 2, 3, 4, 5]) {
    testWidgets('narrow layout survives walk seed=$seed', (tester) async {
      await pumpWalkableApp(tester, walkPhone);
      final trail = await walkApp(tester, seed: seed, steps: 30);
      expect(trail.steps, hasLength(30));
    });
  }

  for (final seed in [1, 2, 3]) {
    testWidgets('wide layout survives walk seed=$seed', (tester) async {
      await pumpWalkableApp(tester, walkDesktop);
      final trail = await walkApp(tester, seed: seed, steps: 30);
      expect(trail.steps, hasLength(30));
    });
  }
}
