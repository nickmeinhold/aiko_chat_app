// The eyes: a model that sees the screenshot and nothing else.
//
// Invoked through headless Claude Code (`claude -p`), which is a zero-cost path
// on the Max plan. Never the metered API.
//
// WHERE THE BLINDNESS IS ACTUALLY ENFORCED, and it is not all in the types.
// `BlindView` closes the DART boundary: there is no path from it to the element
// tree. The live agent is a separate PROCESS, and that boundary is a different
// question with a different answer. Measured, not assumed:
//
//   cwd = the repo root  ->  asked what project it was in, WITHOUT using a tool,
//                            it answered "aiko_chat_app - the Flutter/Dart
//                            client for the aiko chat network ... islands ...
//                            signed-at-birth". That is this repo's CLAUDE.md,
//                            auto-loaded because the test process runs here.
//   cwd = an empty dir   ->  "NONE".
//
// A model briefed on the product is not the naive reader this instrument claims
// to simulate, and the contamination is WORST exactly where the finding is worth
// most: a real newcomer meeting the word "island" does not know what it means,
// and one handed this repo's CLAUDE.md does. So the agent runs from the frame
// directory, not the repo, and with Read as its only tool.
//
// RESIDUAL, stated rather than papered over: `Read` is NOT jailed to the working
// directory - given an absolute path it will read anything this user can read,
// which was also measured. What the isolated cwd removes is the POINTER, not the
// capability: no project instructions, and no Grep or Glob to go looking. The
// honest claim is "not briefed and not browsing", never "cannot reach". Closing
// it properly means auditing the run's tool-use transcript, which is a follow-up
// and not a thing this comment should pretend is done.
//
// The prompt is deliberately thin. Everything that makes this instrument worth
// having comes from what it is NOT told: no widget names, no label list, no
// route table, no hint about which control is the right one. It is told the
// goal in the words a person would use and shown the screen, and its job is to
// guess like a person guesses. Where it guesses wrong, a person would too.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'blind_playtest.dart';

/// Grammar the model must answer in. One line, three shapes.
const _grammar = '''
Reply with EXACTLY ONE line, nothing else, in one of these three forms:

  TAP <x> <y> | <a few words on why that spot>
  HOLD <x> <y> | <a few words on why that spot>
  STUCK | <what you looked for and could not find>
  SEE | <what this screen says to you, in one sentence>

Use TAP to press something. Use HOLD to press and hold it, the way you would on
a phone to reveal more options. Use STUCK when nothing on the screen looks like
it would get you closer to the goal — that is a useful answer, not a failure, so
prefer it over pressing something at random. Use SEE only when you were asked to
describe rather than to act.
''';

/// A [BlindAgent] backed by a real model looking at the real pixels.
///
/// [claudeBin] is the CLI; [timeout] bounds a single move. [scratchDir] is where
/// the frames it is shown get written — they are the artifact worth keeping when
/// a goal fails.
BlindAgent claudeEyes({
  String claudeBin = 'claude',
  Duration timeout = const Duration(minutes: 3),
  String scratchDir = '/tmp/aiko-playtest',
  required WidgetTester tester,
}) {
  var step = 0;
  return (view) async {
    // The image the model reads is in PHYSICAL pixels while a [Tap] is in
    // logical ones. Rather than teach the model a scale factor — a silent
    // source of coordinates that are wrong by a constant — the live agent
    // simply requires the two spaces to coincide.
    final dpr = tester.view.devicePixelRatio;
    if (dpr != 1.0) {
      throw StateError(
        'live playtest requires devicePixelRatio 1.0, got $dpr — otherwise the '
        'coordinates the model reads off the image are not the coordinates the '
        'harness taps',
      );
    }

    final dir = Directory(scratchDir)..createSync(recursive: true);
    final frame = File('${dir.path}/step-${step.toString().padLeft(2, '0')}.png')
      ..writeAsBytesSync(view.png);
    step++;

    final tried = view.history.isEmpty
        ? 'Nothing yet — this is your first move.'
        : view.history.map((m) => '  - $m').join('\n');

    final prompt =
        '''
You are using an app you have never seen before, on a ${view.size.width.round()}
by ${view.size.height.round()} screen. You can see it only as a picture.

Read the image at ${frame.path} with the Read tool. That picture IS the screen,
at 1:1 — a coordinate you read off it is a coordinate on the screen.

YOUR GOAL: ${view.goal}

What you have already tried this attempt:
$tried

Judge only by what you can see. Do not guess at the app's internals or assume a
control exists because apps usually have one. If the screen does not offer a way
toward the goal, say so.

$_grammar''';

    // Real process I/O, so it must run on the real event loop — awaited under
    // the fake-async scheduler it would wait forever on a future the test clock
    // never advances to.
    final result = await tester.runAsync(
      () => Process.run(
        claudeBin,
        [
          '-p',
          prompt,
          // Read only: no Grep or Glob, so the widget names are not one command
          // away from a model that is supposed to be guessing like a person.
          '--allowedTools',
          'Read',
          '--output-format',
          'text',
        ],
        // NOT the repo. Running here is what keeps this repo's CLAUDE.md out of
        // the agent's context - see the header for the measurement.
        workingDirectory: dir.path,
      ).timeout(timeout),
    );

    if (result == null || result.exitCode != 0) {
      throw StateError(
        'claude exited ${result?.exitCode}: ${result?.stderr}',
      );
    }
    return parseMove(const LineSplitter().convert(result.stdout as String));
  };
}

/// Turn the model's reply into a [Move].
///
/// Unparseable output THROWS rather than degrading to [Stuck]. The two mean
/// opposite things: `Stuck` is a finding about the app — "a person would not
/// find this" — while a bad parse is a fact about the harness. Collapsing them
/// would let an instrument failure print as a bug report, which is the worst
/// failure available to a tool whose whole output is bug reports.
Move parseMove(List<String> lines) {
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    final press = RegExp(
      r'^(TAP|HOLD)\s+(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s*'
      r'(?:\|\s*(.*))?$',
      caseSensitive: false,
    ).firstMatch(line);
    if (press != null) {
      final at = Offset(
        double.parse(press.group(2)!),
        double.parse(press.group(3)!),
      );
      final why = press.group(4)?.trim() ?? '';
      return press.group(1)!.toUpperCase() == 'HOLD'
          ? Hold(at, because: why)
          : Tap(at, because: why);
    }

    final stuck = RegExp(
      r'^STUCK\s*(?:\|\s*(.*))?$',
      caseSensitive: false,
    ).firstMatch(line);
    if (stuck != null) {
      return Stuck(
        (stuck.group(1) ?? '').trim().isEmpty
            ? 'no reason given'
            : stuck.group(1)!.trim(),
      );
    }

    final see = RegExp(
      r'^SEE\s*(?:\|\s*(.*))?$',
      caseSensitive: false,
    ).firstMatch(line);
    if (see != null) return Reading((see.group(1) ?? '').trim());
  }

  throw FormatException(
    'no move in the reply — the harness cannot tell an app with no affordance '
    'from a model that answered off-grammar, so it refuses to guess: '
    '${lines.join(' / ')}',
  );
}
