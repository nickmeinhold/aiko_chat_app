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
// WHAT THIS FILE CAN AND CANNOT GUARANTEE, because it used to confuse the two.
//
// Three claims live in this directory wearing the same clothes, and only two of
// them are guarantees:
//
//   A PATH EXISTS, and costs N presses to someone who knows where it is.
//   Deterministic, no model. That is `blind_playtest_reachable_test`, and it is
//   the strongest thing here — a real gate on the app that goes red if the path
//   breaks.
//
//   THE INSTRUMENT IS NOT BROKEN. Deterministic, proved for free with its own
//   must-fail arms in `blind_playtest_self_test`.
//
//   A NAIVE READER WILL FIND IT. This file. NOT guaranteeable — not with a
//   better threshold, not with a cleverer assertion. It is one sample from a
//   distribution, and one sample has no error bars. The sweep scored
//   `mute-conversation` NOT REACHED in 6; a later run reached it in 6. Those two
//   numbers do not disagree with each other, because there is not yet anything
//   there to disagree about.
//
// So this file ASSERTS ONLY THAT THE INSTRUMENT RAN, and PRINTS the number. A
// measurement whose value is longitudinal — is this getting easier or harder
// across builds — has no business being pass/fail on a single run. Its home is a
// record you keep, not a gate you trip. The previous version asserted
// `presses <= 3`, a threshold frozen before any baseline existed, which is the
// thing the sweep's own header refuses to do one file over.
//
// The trail of PNGs under /tmp/aiko-playtest is how you check whether you agree
// with what it found.
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

      // The only assertion: the instrument ran. Reachability and press count are
      // MEASUREMENTS printed above, not gates — see the header. A model that
      // hunts for six presses is telling us something about the app; a suite
      // that goes red for it is telling us nothing, and trains us to stop
      // reading it.
      expect(
        run.moves,
        isNotEmpty,
        reason:
            'the agent produced no moves at all — that is the instrument '
            'failing, which is the one thing this file does gate on',
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
