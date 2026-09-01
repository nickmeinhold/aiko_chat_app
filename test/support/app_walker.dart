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
// Deliberately NOT covered yet: text entry, drag/scroll, and the
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
/// TRAILING SPACES ARE LOAD-BEARING. `'block'` also matches *"Blocked users"*,
/// the Settings row — so the rail meant to stop the walker BLOCKING A PERSON was
/// silently stopping it NAVIGATING TO A SCREEN, and `/settings/blocked` sat
/// unreachable and uncounted. `'block '` matches "Block Alice" and not "Blocked
/// users", because the character after `block` is `e`. Same for `'report '`,
/// which admits the "Reports" operator row while still refusing both "Report
/// message" and "Report a problem" (the latter opens a platform share sheet).
///
/// Verified by asserting each pattern against real labels rather than by
/// reading them — the route-coverage test is what surfaced the mistake, and an
/// over-broad rail is invisible until something counts what it excluded.
const kWalkerAvoids = <String>[
  'delete',
  'sign out',
  'log out',
  'logout',
  'block ',
  'report ',
  'suspend',
  'unregister',
];

/// How the walker will drive a control.
///
/// Tap is not enough for this app: the moderation sheet — Message, Call, Mute,
/// Report, Block — hangs off `onLongPress` on a message bubble and is reachable
/// no other way, so a tap-only walker is structurally blind to the entire UGC
/// surface however many seeds it runs.
enum WalkAction { tap, longPress }

/// One interactive element the walker could drive, with the label it records.
class WalkCandidate {
  WalkCandidate(this.finder, this.label, this.action);

  final Finder finder;
  final String label;
  final WalkAction action;

  @override
  String toString() =>
      action == WalkAction.longPress ? 'long-press $label' : label;
}

/// The record of a walk — enough to replay it exactly.
class WalkTrail {
  WalkTrail(this.seed);

  final int seed;
  final List<String> steps = [];

  /// Route PATTERNS visited (`/settings/gateway`, `/call/:channelId`), not
  /// concrete locations — so they can be compared against the router's own
  /// table without re-deriving which segments were parameters.
  final Set<String> routes = {};

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

  // Anything that declares a long-press handler. Targeted rather than generic:
  // this is how a message bubble offers the moderation sheet, and a walker that
  // cannot press-and-hold cannot see Mute, Report, Block or Message at all.
  final longPressFinder = find
      .byWidgetPredicate((w) => w is GestureDetector && w.onLongPress != null)
      .hitTestable();

  final out = <WalkCandidate>[];

  void collect(Finder f, WalkAction action) {
    final elements = f.evaluate().toList();
    for (var i = 0; i < elements.length; i++) {
      final label = _labelOf(elements[i]);
      if (kWalkerAvoids.any(label.toLowerCase().contains)) continue;
      // Address by INDEX into the same predicate, not by the element: acting
      // rebuilds the tree, and a captured Element is stale the moment it does.
      out.add(
        WalkCandidate(f.at(i), label.isEmpty ? '<unlabelled>' : label, action),
      );
    }
  }

  collect(finder, WalkAction.tap);
  collect(longPressFinder, WalkAction.longPress);
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

  /// Where the app currently is, as a route PATTERN. Supplied by the caller
  /// because the walker has no container of its own; when given, every step
  /// records the route it landed on, which is what lets a test assert the
  /// walker can actually REACH each screen the router registers.
  String? Function()? locationOf,
}) async {
  final rng = Random(seed);
  final trail = WalkTrail(seed);

  // Own error reporting for the duration of the walk.
  //
  // A framework assertion (`setState() called during build`, a failed layout) is
  // dispatched to `FlutterError.onError` from inside the frame — it is not
  // thrown from `tap` or `pumpAndSettle`, so it never travels through the code
  // below and the default handler fails the test with a stack trace and NO
  // trail. That is the difference between "the app broke somewhere in 60 taps"
  // and a one-line reproduction, which is the entire value of a random walk.
  FlutterErrorDetails? captured;
  final previousOnError = FlutterError.onError;
  // Deliberately NOT chaining to `previousOnError`: it would fail the test
  // immediately with its own message, and the failure the developer reads
  // should be the one carrying the trail.
  FlutterError.onError = (details) => captured ??= details;

  void checkCaptured(String context) {
    final d = captured;
    if (d == null) return;
    FlutterError.onError = previousOnError;
    fail('$context raised ${d.exception}\n${trail.describe()}');
  }

  try {
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
      trail.steps.add(pick.toString());

      try {
        switch (pick.action) {
          case WalkAction.tap:
            await tester.tap(pick.finder, warnIfMissed: false);
          case WalkAction.longPress:
            await tester.longPress(pick.finder, warnIfMissed: false);
        }
        await settleOrAdvance(tester);
      } catch (e) {
        fail('Driving $pick threw: $e\n${trail.describe()}');
      }

      final thrown = tester.takeException();
      expect(
        thrown,
        isNull,
        reason: 'Driving $pick raised $thrown\n${trail.describe()}',
      );

      expect(
        find.byType(Text).hitTestable(),
        findsWidgets,
        reason:
            'BLANK FRAME after $pick — the screen rendered no '
            'visible text at all.\n${trail.describe()}',
      );

      final where = locationOf?.call();
      if (where != null) trail.routes.add(where);

      checkCaptured('Driving $pick');
    }
  } finally {
    FlutterError.onError = previousOnError;
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
  } on FlutterError catch (e) {
    // ONLY the timeout. Catching every FlutterError here silently swallowed a
    // real framework assertion (`setState() called during build`) and left the
    // walk to fail later with no trail attached — the instrument hiding the
    // exact class of bug it exists to surface. Anything that is not the
    // perpetual-animation timeout is the app's, and is rethrown.
    if (!e.message.contains('pumpAndSettle timed out')) rethrow;
    // Perpetual animation in flight. Advance real frames instead so any
    // post-frame callback, navigation, or future still runs.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}
