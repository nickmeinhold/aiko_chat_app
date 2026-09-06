// A discoverability sweep: several capability verbs, one blind agent, a table.
//
// The goals come from `docs/design/user-paths.html` — what the app owes a user,
// written before consulting the route table, which is the only reason that list
// can name a capability nobody built.
//
// THIS IS A REPORT GENERATOR, NOT A GATE. It asserts that the INSTRUMENT ran —
// every goal produced moves, nothing threw — and prints what the agent could
// and could not reach. Reachability is deliberately not asserted yet: nobody
// has measured a baseline, and freezing expectations before the first
// measurement is how you get a threshold that encodes an accident.
//
//   flutter test --run-skipped --tags playtest test/walk/blind_playtest_sweep_test.dart
//
// WHY ONLY SIX GOALS, said out loud rather than left as a silent cap: the
// expensive part of a sweep is not the model loop, it is writing a harness-side
// GROUND TRUTH for each verb. These six have honest ones. Verbs like "what is
// recorded about me" do not, and inventing one would manufacture a green that
// measures nothing — the exact failure this whole instrument exists to catch.
//
// Two predicate families, and they are not equally strong:
//   STATE   — a store actually changed (muted, blocked, reported). This is the
//             real thing: the capability happened.
//   ARRIVAL — the router reached a screen. Weaker on purpose, and labelled so:
//             arriving at /search is not the same as having searched. It scores
//             FINDABILITY of a destination, nothing about what happens there.
@Tags(['playtest'])
library;

import 'package:aiko_chat_app/app/router.dart';
import 'package:aiko_chat_app/features/chat/application/mute_controller.dart';
import 'package:aiko_chat_app/features/chat/data/mute_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/blind_agent_claude.dart';
import '../support/blind_playtest.dart';
import '../support/fonts.dart';
import '../support/test_helpers.dart';
import '../support/walk_harness.dart';

const _trails = '/tmp/aiko-playtest/sweep';

/// How strong the ground truth for a goal is. Printed with every result so a
/// reader never has to remember which kind they are looking at.
enum Truth { state, arrival }

typedef Goal = ({
  String slug,
  String verb,
  Truth truth,
  int budget,
  Future<bool> Function(WalkWorld world) reached,
});

/// The current route, read from the app's own router.
String? _where(WalkWorld world) =>
    world.container.read(routerProvider).state.fullPath;

final _goals = <Goal>[
  (
    slug: 'mute-conversation',
    verb: 'silence the conversation called "general" so it stops notifying you',
    truth: Truth.state,
    budget: 6,
    reached: (w) async => w.container
        .read(mutesProvider.notifier)
        .isMuted(MuteTarget.channel, 'c1'),
  ),
  (
    slug: 'block-person',
    verb: 'block the person called Alice so you stop seeing anything from them',
    truth: Truth.state,
    budget: 6,
    reached: (w) async => w.rest.blocks.isNotEmpty,
  ),
  (
    slug: 'report-message',
    verb: 'report one of Alice\'s messages to the people who run this place',
    truth: Truth.state,
    budget: 6,
    reached: (w) async => w.rest.reportCalls.isNotEmpty,
  ),
  (
    slug: 'see-blocked',
    verb: 'find the list of people you have already blocked',
    truth: Truth.arrival,
    budget: 6,
    reached: (w) async => _where(w) == '/settings/blocked',
  ),
  (
    slug: 'change-island',
    verb: 'find where you would connect to a different island',
    truth: Truth.arrival,
    budget: 6,
    reached: (w) async => _where(w) == '/settings/island',
  ),
  (
    slug: 'search',
    verb: 'find where you would search for an old message',
    truth: Truth.arrival,
    budget: 6,
    reached: (w) async => _where(w) == '/search',
  ),
];

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
    await loadRealFonts();
  });

  final results = <String>[];

  for (final goal in _goals) {
    testWidgets('sweep · ${goal.slug}', (tester) async {
      hideDebugChrome();
      final world = await pumpWalkableApp(tester, walkPhone);

      final run = await playtest(
        tester,
        goal: goal.verb,
        agent: claudeEyes(tester: tester, scratchDir: '$_trails/${goal.slug}'),
        reached: () => goal.reached(world),
        maxPresses: goal.budget,
      );
      run.writeFrames('$_trails/${goal.slug}/frames');

      final verdict = run.reached
          ? '${run.presses} press(es)'
          : 'NOT REACHED (${run.presses} tried)';
      results.add(
        '${goal.slug.padRight(20)} ${goal.truth.name.padRight(8)} $verdict'
        '${run.stuckReason == null ? '' : '\n${' ' * 30}gave up: ${run.stuckReason}'}',
      );
      // ignore: avoid_print
      print('\n[${goal.slug}] $run');

      // The only assertion: the INSTRUMENT worked. Reachability is the report,
      // not the gate — see the header.
      expect(
        run.moves,
        isNotEmpty,
        reason: 'the agent produced no move at all for ${goal.slug}',
      );
    });
  }

  tearDownAll(() {
    // ignore: avoid_print
    print(
      '\n=== DISCOVERABILITY SWEEP ===\n'
      'state   = a store actually changed; the capability happened\n'
      'arrival = the router reached a screen; findability only\n\n'
      '${results.join('\n')}\n\n'
      'trails: $_trails\n',
    );
  });
}
