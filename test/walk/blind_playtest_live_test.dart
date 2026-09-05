// The playtester with a real model in the loop, on the real app.
//
// OPT-IN. This costs wall-clock and shells out to a model, so it is skipped by
// default under its OWN tag:
//
//   flutter test --run-skipped --tags playtest
//
// Its own tag, and not `live`: that one means "a real island and real
// credentials", and this needs neither — only the `claude` CLI. Borrowing it
// would have inherited a skip reason that misdescribes why this is not running.
//
// The harness itself is proved deterministically and for free in
// `blind_playtest_self_test.dart`, including its must-fail arms. This file is
// about what the app looks like to someone who has never seen it.
//
// Read the failures here as reports about DISCOVERABILITY, not as a red suite.
// A goal the agent cannot reach is a goal a person may not reach either — that
// is the finding, and the trail of PNGs under /tmp/aiko-playtest is how you
// check whether you agree with it.
@Tags(['playtest'])
library;

import 'package:aiko_chat_app/features/chat/application/mute_controller.dart';
import 'package:aiko_chat_app/features/chat/data/mute_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/blind_agent_claude.dart';
import '../support/blind_playtest.dart';
import '../support/fonts.dart';
import '../support/test_helpers.dart';
import '../support/walk_harness.dart';

/// Where the trails land, one directory per goal.
const _trails = '/tmp/aiko-playtest';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
    await loadRealFonts();
  });

  testWidgets(
    'a newcomer can find how to silence a channel',
    (tester) async {
      hideDebugChrome();
      final container = (await pumpWalkableApp(tester, walkPhone)).container;

      final run = await playtest(
        tester,
        goal:
            'silence the conversation called "general" so it stops notifying '
            'you',
        agent: claudeEyes(
          tester: tester,
          scratchDir: '$_trails/silence-general',
        ),
        // Ground truth is read from the store, never from the agent's opinion
        // of its own success. A run where the two disagree is the interesting
        // one, and it can only be spotted if they are separate readings.
        reached: () async => container
            .read(mutesProvider.notifier)
            .isMuted(MuteTarget.channel, 'c1'),
        maxPresses: 6,
      );

      run.writeFrames('$_trails/silence-general/frames');
      // ignore: avoid_print
      print('\n$run\n${run.moves.map((m) => '  $m').join('\n')}\n'
          'trail: $_trails/silence-general\n');

      expect(
        run.reached,
        isTrue,
        reason:
            'the mute never landed in the store — either it cannot be reached '
            'from the pixels, or it can only be reached by someone who already '
            'knows where it is. Look at the trail.',
      );
      // Discoverability as a number. The designed path is two presses — hold
      // the app-bar title, press mute — so more than three is measured hunting.
      expect(
        run.presses,
        lessThanOrEqualTo(3),
        reason: 'reached, but took ${run.presses} presses — that is a hunt',
      );
    },
  );

  testWidgets(
    'what the app bar actually says to someone reading it',
    (tester) async {
      // The COMPOSITION class, which needs no interaction at all: show it the
      // bar and ask what it reads. There is no assertion to write here — the
      // finding is the gap between this sentence and what the bar is supposed
      // to mean, and judging that gap is a human's job. So this test asserts
      // only that the instrument produced a reading, and PRINTS the reading.
      hideDebugChrome();
      await pumpWalkableApp(tester, walkPhone);

      final run = await playtest(
        tester,
        goal:
            'describe, in one sentence, what the bar across the top of this '
            'screen is telling you about this conversation',
        agent: claudeEyes(tester: tester, scratchDir: '$_trails/read-the-bar'),
        reached: () async => false,
        maxPresses: 1,
      );

      run.writeFrames('$_trails/read-the-bar/frames');
      final reading = run.moves.whereType<Reading>().firstOrNull;
      // ignore: avoid_print
      print('\nTHE BAR READS AS: ${reading?.saw ?? '(no reading — $run)'}\n'
          'trail: $_trails/read-the-bar\n');

      expect(
        reading,
        isNotNull,
        reason: 'the agent acted instead of describing — no reading to compare',
      );
    },
  );
}
