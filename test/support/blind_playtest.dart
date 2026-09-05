// A playtester that can only see the screen.
//
// Every other instrument here reads the app the way the CODE describes it: the
// walker enumerates handlers, route coverage enumerates routes, tests address
// widgets through `find.byType` and `find.text`. Three defect classes live
// outside that window, and all three shipped:
//
//   COMPOSITION — meaning that exists only in rendered pixels. An unread badge
//   6px from a mute bell read as one compound signal saying the OPPOSITE of
//   what it said. Both sites individually correct, composed across two files
//   that never appear in one diff.
//
//   AFFORDANCE — what LOOKS pressable versus what is. A caret drawn beside its
//   button rather than inside it had no hit area at all, and 1185 tests passed
//   against it, because every one of them tapped by type or by label.
//
//   ABSENCE — no code exists, so nothing that reads code can see it. Route
//   coverage cannot go red on a route that was never written.
//
// So this harness hands an agent a PNG and a goal in plain verbs, and accepts
// back A COORDINATE. That single constraint is what earns all three classes: an
// agent that can name a widget will find the widget, and stop being able to
// notice that nothing on screen looks like it. The blindness is therefore
// enforced HERE, by the types — `BlindAgent` receives a [BlindView] and there
// is no path from a [BlindView] to the element tree — and not by asking a
// prompt nicely.
//
// It is the walker's exact inverse: the walker knows the tree and is blind to
// the screen. Two verifiers are only worth having when they fail differently.
//
// The second output is the one no human checklist can produce: DISCOVERABILITY
// AS A NUMBER. Every goal carries a harness-side ground-truth check, so a goal
// reached in 8 taps that should take 2 is a measured "had to hunt" — repeatable,
// no handset required.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Everything the agent is permitted to know.
///
/// Deliberately a closed record of PIXELS, a goal in verbs, and what it has
/// already tried. There is no finder here, no widget, no label list, and no
/// route name — and there is no accessor that would let a caller reach one.
/// The moment this class can answer "where is the mute button", the instrument
/// stops being able to report that nothing on screen looks like a mute button.
final class BlindView {
  const BlindView({
    required this.png,
    required this.size,
    required this.goal,
    required this.history,
  });

  /// The screen as a reader meets it.
  final Uint8List png;

  /// Logical size of that screen. Coordinates in a [Tap] are in this space.
  final Size size;

  /// What the agent is trying to accomplish, in verbs a person would use.
  final String goal;

  /// Moves already made this attempt, oldest first. An agent that keeps tapping
  /// the same dead pixel should be able to notice it is doing so.
  final List<Move> history;
}

/// The only three things an agent may say.
sealed class Move {
  const Move();
}

/// Press this point. The harness taps positionally, never semantically.
final class Tap extends Move {
  const Tap(this.at, {this.because = ''});

  /// In the [BlindView.size] logical coordinate space.
  final Offset at;

  /// Optional, for the trail. Never read by the harness.
  final String because;

  @override
  String toString() =>
      'Tap(${at.dx.round()}, ${at.dy.round()})${because.isEmpty ? '' : ' — $because'}';
}

/// "I cannot find a way from here."
///
/// This is the ABSENCE class becoming an observable event. A missing
/// affordance produces no failing assertion anywhere else in the suite,
/// because there is nothing to assert about.
final class Stuck extends Move {
  const Stuck(this.because);

  final String because;

  @override
  String toString() => 'Stuck — $because';
}

/// "Here is what this screen says to me."
///
/// For COMPOSITION goals, which need no interaction at all: show the agent the
/// bar and ask what it reads. Its disagreement with ground truth IS the finding
/// — there is no assertion to write.
final class Reading extends Move {
  const Reading(this.saw);

  final String saw;

  @override
  String toString() => 'Reading — $saw';
}

/// Decides where to press, seeing only [BlindView].
typedef BlindAgent = Future<Move> Function(BlindView view);

/// What the harness observed. The trail of PNGs is the artifact worth keeping.
final class PlaytestRun {
  PlaytestRun({
    required this.goal,
    required this.reached,
    required this.moves,
    required this.frames,
  });

  final String goal;

  /// Did the harness-side ground truth become true? Never the agent's opinion —
  /// an agent that believes it succeeded is not evidence that it did.
  final bool reached;

  final List<Move> moves;

  /// One PNG per screen the agent was shown, including the final one.
  final List<Uint8List> frames;

  /// Taps spent. The discoverability number: this only means something when
  /// [reached] is true.
  int get taps => moves.whereType<Tap>().length;

  /// Why it stopped, when it stopped itself.
  String? get stuckReason => moves.whereType<Stuck>().isEmpty
      ? null
      : moves.whereType<Stuck>().last.because;

  /// Write the trail to disk. A failed goal is worth looking at.
  void writeFrames(String dir) {
    Directory(dir).createSync(recursive: true);
    for (var i = 0; i < frames.length; i++) {
      File('$dir/${i.toString().padLeft(2, '0')}.png')
          .writeAsBytesSync(frames[i]);
    }
  }

  @override
  String toString() =>
      '${reached ? 'REACHED' : 'FAILED '} in $taps tap(s): $goal'
      '${stuckReason == null ? '' : ' [$stuckReason]'}';
}

/// Rasterise the current frame as PNG bytes.
///
/// `toImage` must run inside `tester.runAsync` — awaited under the fake-async
/// scheduler it waits on a frame that is never produced and hangs silently
/// rather than failing.
Future<Uint8List> capturePng(WidgetTester tester) async {
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  return (await tester.runAsync(() async {
    final image = await layer.toImage(view.paintBounds);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return bytes!.buffer.asUint8List();
  }))!;
}

/// Let [agent] pursue [goal] on the currently pumped app, seeing only pixels.
///
/// [reached] is the ground truth, evaluated by the HARNESS between moves — it
/// may read the provider container, the store, anything. Keeping it here rather
/// than in the agent is the point: the agent's belief about its own success is
/// not evidence, and a run where the two disagree is exactly the finding.
///
/// [maxTaps] bounds the hunt. Exhausting it is a result, not an error: an
/// affordance that takes more than [maxTaps] presses to find is undiscoverable
/// whether or not it exists.
Future<PlaytestRun> playtest(
  WidgetTester tester, {
  required String goal,
  required BlindAgent agent,
  required Future<bool> Function() reached,
  int maxTaps = 8,
}) async {
  final moves = <Move>[];
  final frames = <Uint8List>[];

  // Checked BEFORE the first move. A goal already satisfied by the starting
  // state would otherwise be scored as a success the agent earned, and every
  // tap count downstream would be measuring nothing.
  if (await reached()) {
    frames.add(await capturePng(tester));
    return PlaytestRun(
      goal: goal,
      reached: true,
      moves: const [],
      frames: frames,
    );
  }

  while (moves.whereType<Tap>().length < maxTaps) {
    final png = await capturePng(tester);
    frames.add(png);

    final move = await agent(
      BlindView(
        png: png,
        size: tester.view.physicalSize / tester.view.devicePixelRatio,
        goal: goal,
        history: List.unmodifiable(moves),
      ),
    );
    moves.add(move);

    switch (move) {
      case Stuck():
        return PlaytestRun(
          goal: goal,
          reached: false,
          moves: moves,
          frames: frames,
        );
      case Reading():
        // An observation changes nothing on screen; the caller reads it off the
        // run. Returning immediately keeps a composition goal from silently
        // becoming an interaction goal.
        return PlaytestRun(
          goal: goal,
          reached: await reached(),
          moves: moves,
          frames: frames,
        );
      case Tap(:final at):
        await tester.tapAt(at);
        await tester.pumpAndSettle();
        if (await reached()) {
          frames.add(await capturePng(tester));
          return PlaytestRun(
            goal: goal,
            reached: true,
            moves: moves,
            frames: frames,
          );
        }
    }
  }

  frames.add(await capturePng(tester));
  return PlaytestRun(goal: goal, reached: false, moves: moves, frames: frames);
}
