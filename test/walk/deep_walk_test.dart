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
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_walker.dart';
import '../support/fake_chat_transport.dart';
import '../support/test_helpers.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = makeContainer(
      rest: FakeRestApi(),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
  }

  const phone = Size(400, 900);
  const desktop = Size(1400, 900);

  for (var seed = 100; seed < 130; seed++) {
    testWidgets('deep narrow walk seed=$seed', (tester) async {
      await pumpAt(tester, phone);
      await walkApp(tester, seed: seed, steps: 60);
    });
  }

  for (var seed = 200; seed < 220; seed++) {
    testWidgets('deep wide walk seed=$seed', (tester) async {
      await pumpAt(tester, desktop);
      await walkApp(tester, seed: seed, steps: 60);
    });
  }
}
