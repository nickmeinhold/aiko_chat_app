// Does the playtest harness work — and, more to the point, CAN IT FAIL?
//
// An instrument whose reading is independent of the thing it measures is not an
// instrument. So each capability here is proved in both directions: a scripted
// agent that presses the live control must be scored as reaching the goal, and
// a scripted agent that presses a dead one must be scored as failing. If the
// second arm passed, every green this harness ever produces would mean nothing.
//
// The agent is SCRIPTED rather than a model on purpose. This file tests the
// harness — tapping positionally, counting, stopping, recording the trail — and
// it must be deterministic and free. The model in the loop is a separate,
// opt-in run: see `blind_playtest_live_test.dart`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/blind_agent_claude.dart';
import '../support/blind_playtest.dart';
import '../support/fonts.dart';

/// An agent that presses a fixed list of points, then gives up.
///
/// It cannot see; it does not need to. What is under test is what the HARNESS
/// does with the answers.
BlindAgent _scripted(List<Offset> points) {
  var i = 0;
  return (view) async => i < points.length
      ? Tap(points[i++])
      : const Stuck('ran out of scripted moves');
}

/// A screen with one live button and one dead-looking decoration beside it —
/// the affordance defect in miniature.
Widget _screen({required VoidCallback onPressed}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    body: Column(
      children: [
        const SizedBox(height: 100),
        Row(
          children: [
            // Looks pressable. Is not. 60px tall, starting at y=100.
            Container(
              width: 200,
              height: 60,
              color: const Color(0xFF888888),
              alignment: Alignment.center,
              child: const Text('decoration'),
            ),
            SizedBox(
              width: 200,
              height: 60,
              child: FilledButton(
                onPressed: onPressed,
                child: const Text('live'),
              ),
            ),
          ],
        ),
      ],
    ),
  ),
);

void main() {
  setUpAll(loadRealFonts);

  /// Centre of the live button and of the dead decoration, in logical pixels.
  const liveButton = Offset(300, 130);
  const deadDecoration = Offset(100, 130);

  testWidgets('a tap on the live control reaches the goal, and is counted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var pressed = false;
    await tester.pumpWidget(_screen(onPressed: () => pressed = true));

    final run = await playtest(
      tester,
      goal: 'press the live control',
      agent: _scripted(const [liveButton]),
      reached: () async => pressed,
    );

    expect(run.reached, isTrue, reason: '$run');
    expect(run.taps, 1);
    // The trail: the screen before the tap, and the screen after it.
    expect(run.frames, hasLength(2));
  });

  testWidgets(
    'MUST FAIL ARM: tapping what only LOOKS pressable never reaches the goal',
    (tester) async {
      // This is the positive control. The harness has to be able to report a
      // dead affordance, or its greens are decoration too.
      tester.view.physicalSize = const Size(600, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var pressed = false;
      await tester.pumpWidget(_screen(onPressed: () => pressed = true));

      final run = await playtest(
        tester,
        goal: 'press the live control',
        agent: _scripted(const [
          deadDecoration,
          deadDecoration,
          deadDecoration,
        ]),
        reached: () async => pressed,
      );

      expect(run.reached, isFalse, reason: '$run');
      expect(pressed, isFalse);
      expect(run.taps, 3);
      expect(run.stuckReason, isNotNull);
    },
  );

  testWidgets('the tap budget bounds the hunt, and exhausting it is a result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_screen(onPressed: () {}));

    final run = await playtest(
      tester,
      goal: 'reach something unreachable',
      agent: (view) async => const Tap(deadDecoration),
      reached: () async => false,
      maxTaps: 4,
    );

    expect(run.reached, isFalse);
    expect(run.taps, 4, reason: 'the budget, not one more');
  });

  testWidgets('"I cannot find a way from here" ends the run as a failure', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_screen(onPressed: () {}));

    final run = await playtest(
      tester,
      goal: 'silence a channel',
      agent: (view) async => const Stuck('nothing here looks like a mute'),
      reached: () async => false,
    );

    expect(run.reached, isFalse);
    expect(run.taps, 0);
    expect(run.stuckReason, 'nothing here looks like a mute');
  });

  testWidgets('a goal already true before the first move scores zero taps', (
    tester,
  ) async {
    // Otherwise a goal the starting state already satisfies is banked as a
    // success the agent earned, and the discoverability number silently
    // measures nothing.
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_screen(onPressed: () {}));

    final run = await playtest(
      tester,
      goal: 'already done',
      agent: (view) async =>
          fail('the agent must not be consulted for a goal already reached'),
      reached: () async => true,
    );

    expect(run.reached, isTrue);
    expect(run.taps, 0);
  });

  testWidgets('the agent is shown the screen it is about to act on', (
    tester,
  ) async {
    // The view must carry real pixels of the CURRENT frame — an agent handed a
    // stale or empty image would still produce plausible coordinates, and the
    // run would look exactly like a working one.
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_screen(onPressed: () {}));

    late BlindView seen;
    await playtest(
      tester,
      goal: 'observe',
      agent: (view) async {
        seen = view;
        return const Reading('a grey slab and a green button');
      },
      reached: () async => false,
    );

    expect(seen.goal, 'observe');
    expect(seen.size, const Size(600, 400));
    // A PNG, not an empty buffer: the 8-byte signature, then real content.
    expect(seen.png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    expect(seen.png.length, greaterThan(1000));
  });

  group('the model\'s reply is parsed strictly', () {
    test('a tap, with its reason', () {
      final move = parseMove(['TAP 120 340 | the caret looks pressable']);
      expect(move, isA<Tap>());
      expect((move as Tap).at, const Offset(120, 340));
      expect(move.because, 'the caret looks pressable');
    });

    test('a tap with no reason still parses', () {
      expect(parseMove(['TAP 5 6']), isA<Tap>());
    });

    test('stuck carries what was looked for', () {
      final move = parseMove(['STUCK | nothing here looks like a mute']);
      expect((move as Stuck).because, 'nothing here looks like a mute');
    });

    test('a reading', () {
      expect(
        (parseMove(['SEE | three muted notifications']) as Reading).saw,
        'three muted notifications',
      );
    });

    test('preamble before the move is tolerated', () {
      // A model that says "Looking at the image..." first is answering, not
      // failing. Only a reply with no move at all is a harness fault.
      expect(
        parseMove(['Looking at the screenshot now.', '', 'TAP 1 2 | there']),
        isA<Tap>(),
      );
    });

    test('MUST FAIL ARM: an off-grammar reply THROWS, never degrades to Stuck', () {
      // If this ever returned Stuck, an instrument failure would be published
      // as a bug report about the app: "a person could not find this" when in
      // truth the harness could not read its own model. That is the worst
      // failure available to a tool whose entire output is findings.
      expect(
        () => parseMove(["I'm not sure what you're asking for."]),
        throwsA(isA<FormatException>()),
      );
      expect(() => parseMove(const []), throwsA(isA<FormatException>()));
      expect(() => parseMove(['TAP over there']), throwsA(isA<FormatException>()));
    });
  });
}
