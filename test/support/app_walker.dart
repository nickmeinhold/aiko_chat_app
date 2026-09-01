// A seeded state-space walker for the real app widget tree.
//
// The technique is automated playtesting: rather than scripting the paths a
// human thought of, drive the app with a reproducible pseudo-random sequence of
// taps and assert INVARIANTS at every step. A scripted test proves the path its
// author imagined still works; a walker finds the screen nobody thought to open
// twice in a row.
//
// The three properties that make it useful rather than a curiosity:
//
//   SEEDED — every walk is reproducible from one integer. A failure prints the
//   seed and the exact trail of labels tapped, so a random discovery becomes a
//   deterministic regression test instead of a ghost story.
//
//   INVARIANT-DRIVEN — the walker does not know what any screen is supposed to
//   look like, and must not: it asserts properties that hold EVERYWHERE (no
//   exception, something rendered, somewhere to go). Encoding per-screen
//   expectations here would just be the scripted suite again, more slowly.
//
//   IN-PROCESS — it rides `pumpApp`, so it runs at unit-test speed against the
//   real `AikoChatApp` with faked seams. No device, no emulator; it belongs in
//   the normal suite rather than in a nightly job nobody reads.
//
// Deliberately NOT covered yet: text entry, gestures other than tap, and the
// sign-out/sign-in cycle (the "recover" verb). Sign-out is excluded because it
// ends the session and truncates every walk that finds it — it deserves its own
// walk that starts there, not a rail that makes ordinary walks short.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Labels the walker will not tap.
///
/// Two kinds, and the distinction matters. **Destructive** actions (delete the
/// account, block a person, file a report) mutate state the walk cannot undo,
/// so one unlucky tap makes every later step a walk through a different app
/// than the one under test. **Terminal** actions (sign out) end the session and
/// truncate the walk.
///
/// This is a rail, not a claim that those paths are unimportant — each has its
/// own scripted suite, and matching is on the visible label precisely so a rail
/// here can never silently hide a screen from the walker without a human
/// reading this list and seeing why.
const kWalkerAvoids = <String>[
  'delete account',
  'delete',
  'sign out',
  'log out',
  'logout',
  'block',
  'report',
  'suspend',
  'unregister',
];

/// One interactive element the walker could tap, with the label it will record.
class WalkCandidate {
  WalkCandidate(this.finder, this.label);

  final Finder finder;
  final String label;

  @override
  String toString() => label;
}

/// The record of a walk — enough to replay it exactly.
class WalkTrail {
  WalkTrail(this.seed);

  final int seed;
  final List<String> steps = [];

  /// A copy-pasteable reproduction, printed on any failure. Without this a
  /// random walk reports "something broke somewhere", which is worse than no
  /// test at all because it costs a day and teaches nothing.
  String describe() =>
      'seed=$seed, ${steps.length} steps:\n'
      '${steps.asMap().entries.map((e) => '  ${e.key + 1}. ${e.value}').join('\n')}';
}

/// Collect the visible, hit-testable, non-avoided things a user could tap.
List<WalkCandidate> walkCandidates(WidgetTester tester) {
  final finder = find
      .byWidgetPredicate(
        (w) =>
            w is ListTile ||
            w is TextButton ||
            w is IconButton ||
            w is ElevatedButton ||
            w is OutlinedButton ||
            w is FilledButton ||
            w is FloatingActionButton ||
            w is SwitchListTile ||
            w is Switch ||
            w is Checkbox ||
            w is PopupMenuButton ||
            // Menu ENTRIES, not just the button that opens them. Omitting these
            // made an open popup look like a dead end: its barrier hides
            // everything underneath, so the walker saw a screen with nothing on
            // it and reported the app had stranded the user.
            w is PopupMenuEntry ||
            w is DropdownMenuItem ||
            w is RadioListTile ||
            w is CheckboxListTile ||
            w is SegmentedButton ||
            w is Tab,
      )
      .hitTestable();

  final out = <WalkCandidate>[];
  final elements = finder.evaluate().toList();
  for (var i = 0; i < elements.length; i++) {
    final label = _labelOf(elements[i]);
    if (kWalkerAvoids.any(label.toLowerCase().contains)) continue;
    // Address by INDEX into the same predicate, not by the element: tapping
    // rebuilds the tree, and a captured Element is stale the moment it does.
    out.add(
      WalkCandidate(finder.at(i), label.isEmpty ? '<unlabelled>' : label),
    );
  }
  return out;
}

/// The visible text inside [element], joined — the walker's name for a control.
/// Falls back to the widget's runtime type so an icon-only button is still
/// nameable in a trail.
String _labelOf(Element element) {
  final texts = <String>[];
  void visit(Element e) {
    final w = e.widget;
    if (w is Text && w.data != null && w.data!.trim().isNotEmpty) {
      texts.add(w.data!.trim());
    }
    if (w is Icon && w.semanticLabel != null) texts.add(w.semanticLabel!);
    e.visitChildren(visit);
  }

  element.visitChildren(visit);
  if (texts.isEmpty) return '${element.widget.runtimeType}';
  return '${element.widget.runtimeType}("${texts.take(2).join(' / ')}")';
}

/// Walk the mounted app for [steps] taps, driven by [seed].
///
/// Asserts, after every single tap:
///
///   NO EXCEPTION — the tap did not throw. `takeException` is drained each step
///   rather than left to the end so the trail names the tap that broke, not
///   merely that the walk broke.
///
///   SOMETHING RENDERED — the frame is not blank. A screen that builds to
///   nothing passes every "no crash" check while being completely broken.
///
///   NO DEAD END — there is at least one thing left to tap. This is the
///   invariant this app actually needs: its expensive bugs have been
///   reachability bugs (a DM section you could only reach by placing a video
///   call), and a dead end is that bug's signature.
///
/// Returns the trail so a caller can assert on where it went.
Future<WalkTrail> walkApp(
  WidgetTester tester, {
  required int seed,
  int steps = 40,
}) async {
  final rng = Random(seed);
  final trail = WalkTrail(seed);

  for (var step = 0; step < steps; step++) {
    var candidates = walkCandidates(tester);

    // Before calling it a dead end, try to LEAVE. The distinction is the whole
    // value of this invariant: "there is nothing to tap" and "there is nothing
    // the walker RECOGNISES to tap" produce an identical empty list, and only
    // the first is a bug. A screen the user can back out of is not a trap, so
    // the claim is only made once the escape hatch has also failed.
    if (candidates.isEmpty) {
      await tester.binding.handlePopRoute();
      await settleOrAdvance(tester);
      candidates = walkCandidates(tester);
      if (candidates.isNotEmpty) trail.steps.add('<system back>');
    }

    expect(
      candidates,
      isNotEmpty,
      reason:
          'DEAD END after ${trail.steps.length} steps — nothing to tap and the '
          'system back gesture did not restore anything, so a user is stranded '
          'here.\n${trail.describe()}',
    );

    final pick = candidates[rng.nextInt(candidates.length)];
    trail.steps.add(pick.label);

    try {
      await tester.tap(pick.finder, warnIfMissed: false);
      await settleOrAdvance(tester);
    } catch (e) {
      fail('Tapping ${pick.label} threw: $e\n${trail.describe()}');
    }

    final thrown = tester.takeException();
    expect(
      thrown,
      isNull,
      reason: 'Tapping ${pick.label} raised $thrown\n${trail.describe()}',
    );

    expect(
      find.byType(Text).hitTestable(),
      findsWidgets,
      reason:
          'BLANK FRAME after tapping ${pick.label} — the screen rendered no '
          'visible text at all.\n${trail.describe()}',
    );
  }
  return trail;
}

/// Advance the clock after a tap, tolerating screens that never settle.
///
/// `pumpAndSettle` throws on ANY perpetual animation, and a loading spinner is
/// perpetual by design — so using it here would report every screen that fetches
/// something as a failure. That is the walker's own blind spot rather than the
/// app's bug, and the first run of this file hit it immediately (a spinner on
/// the Carried Record screen, which has no fetch to complete against a fake).
///
/// So: settle when the frame CAN settle, and otherwise advance a bounded number
/// of frames and carry on. A genuine hang still surfaces — as a blank frame, a
/// dead end, or a thrown exception on the next step — but an honest spinner no
/// longer masquerades as one.
Future<void> settleOrAdvance(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  } on FlutterError {
    // Perpetual animation in flight. Advance real frames instead so any
    // post-frame callback, navigation, or future still runs.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}
