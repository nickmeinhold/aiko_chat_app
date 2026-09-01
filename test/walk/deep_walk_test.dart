@Tags(['deep'])
library;

// The pre-submission sweep — a wider sample of the same walk.
//
// `app_walk_test.dart` is the fast arm that runs with every `flutter test`: a
// few seeds, enough to catch a break. This is the arm you run BEFORE a store
// submission, when the cost of a missed regression stops being a rerun and
// starts being a week of App Store review.
//
// It is the same walker and the same invariants — only the sample is bigger.
// Excluded from the default run by tag, because a suite people skip because it
// is slow protects nothing:
//
//   flutter test --tags deep
import 'package:flutter_test/flutter_test.dart';

import '../support/app_walker.dart';
import '../support/test_helpers.dart';
import '../support/walk_harness.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  for (var seed = 100; seed < 130; seed++) {
    testWidgets('deep narrow walk seed=$seed', (tester) async {
      await pumpWalkableApp(tester, walkPhone);
      await walkApp(tester, seed: seed, steps: 60);
    });
  }

  for (var seed = 200; seed < 220; seed++) {
    testWidgets('deep wide walk seed=$seed', (tester) async {
      await pumpWalkableApp(tester, walkDesktop);
      await walkApp(tester, seed: seed, steps: 60);
    });
  }
}
