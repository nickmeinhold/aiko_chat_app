// The walker's own must-fail arms.
//
// `app_walk_test.dart` is eight green walks over the real app. Green is only
// worth something if red is reachable: a walker whose predicate matched nothing,
// whose taps silently missed, or whose invariants were vacuous would produce the
// exact same eight passes. So each invariant is pointed at an app built to
// violate it, and asserted to go red.
//
// This is the control arm, and it is permanent rather than a one-off check —
// the walker will be extended (text entry, gestures, sign-out cycles), and every
// extension is a chance to quietly break the part that does the detecting.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_walker.dart';

void main() {
  /// An app whose single button leads somewhere broken.
  Widget appLeadingTo(Widget destination) => MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(builder: (_) => destination),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );

  testWidgets('BLANK FRAME is caught — a screen that renders no text', (
    tester,
  ) async {
    // pushReplacement, so there is no back route: the failure must be the blank
    // frame itself and not the walker merely running out of places to go.
    await tester.pumpWidget(
      appLeadingTo(const Scaffold(body: Center(child: Icon(Icons.abc)))),
    );
    await tester.pumpAndSettle();

    await expectLater(
      () => walkApp(tester, seed: 1, steps: 5),
      throwsA(
        isA<TestFailure>().having(
          (f) => f.message,
          'message',
          contains('BLANK FRAME'),
        ),
      ),
    );
  });

  testWidgets('DEAD END is caught — a screen with nothing to tap and no way '
      'back', (tester) async {
    await tester.pumpWidget(
      appLeadingTo(const Scaffold(body: Center(child: Text('stranded')))),
    );
    await tester.pumpAndSettle();

    await expectLater(
      () => walkApp(tester, seed: 1, steps: 5),
      throwsA(
        isA<TestFailure>().having(
          (f) => f.message,
          'message',
          contains('DEAD END'),
        ),
      ),
    );
  });

  testWidgets('a throwing tap is caught, and the trail names the control', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => throw StateError('boom'),
              child: const Text('detonate'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      () => walkApp(tester, seed: 1, steps: 5),
      throwsA(
        isA<TestFailure>().having(
          (f) => f.message,
          'message',
          // Both halves matter: that it failed, and that the report names WHICH
          // control did it. A failure without the trail costs a day to localise.
          allOf(contains('detonate'), contains('seed=1')),
        ),
      ),
    );
  });

  testWidgets('the escape hatch recovers rather than false-alarming', (
    tester,
  ) async {
    // The counter-case to the DEAD END test above: same empty screen, but PUSHED
    // rather than pushReplacement, so system back restores the previous route.
    // Without this, the dead-end invariant could be "correct" by simply firing
    // on every modal, popup and pushed screen in the app.
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const Scaffold(body: Center(child: Text('cul-de-sac'))),
                  ),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final trail = await walkApp(tester, seed: 1, steps: 6);
    expect(trail.steps, contains('<system back>'));
  });
}
