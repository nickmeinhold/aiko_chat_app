// The anomaly pass: ask the screen "is anything wrong here?", with no goal.
//
// WHY THIS EXISTS. The blind playtester finds whether a capability is
// REACHABLE. Every goal it is given is an ACT goal — "silence this", "block
// them" — so it scans each frame for affordances and never for defects. Its
// first sweep walked past a solid black app-bar title twice without remarking
// on it; a human found that bug by looking at the same screenshots afterwards,
// and that step existed nowhere in the harness. This is that step.
//
// IT IS A DIFFERENT QUESTION, NOT A BETTER PROMPT. "Where do I tap to mute?"
// and "is anything on this screen broken?" pull attention in incompatible
// directions, and asking both at once gets a worse answer to each. The pass
// therefore runs SEPARATELY over captured frames, which also makes it free to
// re-run over frames that were captured for something else entirely.
//
// WHAT THE MEASUREMENT IS, and this is the part that decides whether any of it
// is worth having:
//
//   THE NUMBER IS THE FALSE-POSITIVE RATE ON CLEAN FRAMES.
//
// Not the catch. An agent that flags every screen catches every defect and is
// worthless, and it passes a catch-only check perfectly. So the clean arm is
// the headline and the defect arm is confirmation — and BOTH must run in the
// same report, because either alone is trivially gamed by a degenerate agent.
// `blind_anomaly_calibration_test.dart` holds the arms and the one assertion
// that decides whether a run's number may be recorded at all.
//
// STOCHASTIC. This is a model, not a function. One reading per frame is an
// observation, not a rate — `trials` exists so the numbers are rates, and the
// report prints the denominator next to every one of them.
import 'dart:convert';
import 'dart:io';

/// What the agent said about one frame.
sealed class AnomalyVerdict {
  const AnomalyVerdict(this.said);

  /// The agent's own words. Kept even for [Clean] — a clean verdict that
  /// describes the wrong screen is a finding about the instrument.
  final String said;
}

/// Nothing wrong on this screen.
final class Clean extends AnomalyVerdict {
  const Clean(super.said);
  @override
  String toString() => 'CLEAN — $said';
}

/// Something on this screen is broken, unreadable, or obscured.
final class Anomaly extends AnomalyVerdict {
  const Anomaly(super.said);
  @override
  String toString() => 'ANOMALY — $said';
}

/// Grammar the model must answer in. Two shapes, one line.
///
/// Deliberately NOT a confidence score. A number between 0 and 1 invites a
/// threshold, a threshold invites tuning, and tuning a threshold on eleven
/// frames would encode this corpus rather than measure the agent. The verdict
/// is binary and the rate is what carries the nuance.
const anomalyGrammar = '''
Reply with EXACTLY ONE line, nothing else, in one of these two forms:

  OK | <one sentence describing what this screen is>
  ANOMALY | <what is wrong, and roughly where on the screen>

Answer OK if the screen looks like a normal, working screen — even if it is
plain, empty, or you do not know what the app is for. Answer ANOMALY only if
something is actually WRONG with it: text you cannot read, an element drawn on
top of another, something cut off, overlapping, or missing where the layout
clearly expects it.
''';

/// Turn the model's reply into a verdict.
///
/// Unparseable output THROWS. Same discipline as `parseMove`, and it matters
/// more here: this instrument's entire output is "is something wrong", so a
/// harness failure that degraded into `Anomaly` would manufacture exactly the
/// bug reports the tool exists to produce, and a harness failure that degraded
/// into `Clean` would silently improve the false-positive rate — the headline
/// number. Both directions corrupt the measurement, so neither is allowed.
AnomalyVerdict parseVerdict(List<String> lines) {
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    final ok = RegExp(
      r'^OK\s*(?:\|\s*(.*))?$',
      caseSensitive: false,
    ).firstMatch(line);
    if (ok != null) return Clean((ok.group(1) ?? '').trim());

    final bad = RegExp(
      r'^ANOMALY\s*(?:\|\s*(.*))?$',
      caseSensitive: false,
    ).firstMatch(line);
    if (bad != null) return Anomaly((bad.group(1) ?? '').trim());
  }
  throw FormatException(
    'no verdict in the reply — the harness cannot tell a clean screen from a '
    'model that answered off-grammar, and guessing either way corrupts the '
    'rate this instrument exists to report: ${lines.join(' / ')}',
  );
}

/// Looks at one PNG and says whether anything is wrong with it.
typedef AnomalyEyes = Future<AnomalyVerdict> Function(File png);

/// An [AnomalyEyes] backed by a real model, through headless Claude Code —
/// the zero-cost Max path, never the metered API.
///
/// TWO CONTAMINATION CHANNELS ARE CLOSED HERE, both learned the hard way.
///
/// 1. THE WORKING DIRECTORY. A `claude -p` inheriting the repo's cwd
///    auto-loads this project's CLAUDE.md and can Grep the source, so it
///    arrives already knowing what an "island" is and what each screen is for.
///    Measured in PR #188: cwd=repo answered "aiko_chat_app — the Flutter/Dart
///    client… islands… signed-at-birth" when asked what project it was in;
///    cwd=empty answered "NONE". So it runs from a scratch directory with
///    `Read` as its only tool.
///
/// 2. THE FILE PATH ITSELF. The sweep writes frames to
///    `sweep/change-island/frames/03.png`. Handing the agent that path names
///    the goal, the feature and the step number before it has looked at a
///    pixel — and on an anomaly pass that is worse than a briefing, because
///    "change-island" invites it to reason about what an island screen SHOULD
///    contain instead of reporting what it sees. Every frame is therefore
///    copied to an opaque name in the scratch dir first.
///
/// RESIDUAL, stated rather than papered over: `Read` is not jailed to the
/// working directory. What this removes is the POINTER, not the capability —
/// the honest claim is "not briefed and not browsing", never "cannot reach".
AnomalyEyes claudeAnomalyEyes({
  String claudeBin = 'claude',
  Duration timeout = const Duration(minutes: 3),
  required String scratchDir,
}) {
  var n = 0;
  return (png) async {
    final dir = Directory(scratchDir)..createSync(recursive: true);
    // Opaque name. See contamination channel 2.
    final anon = File('${dir.path}/frame-${n++}.png')
      ..writeAsBytesSync(png.readAsBytesSync());

    final prompt =
        '''
Here is a picture of one screen of a phone app. You have never seen this app
before and you have not been told what it does.

Read the image at ${anon.path} with the Read tool.

Look at it the way someone would who just picked up the phone: is anything on
this screen BROKEN? Judge only by what you can see. Do not assume a control is
missing because apps usually have one — a screen can be plain or empty and be
perfectly fine.

$anomalyGrammar''';

    final result = await Process.run(
      claudeBin,
      [
        '-p',
        prompt,
        '--allowedTools',
        'Read',
        '--output-format',
        'text',
      ],
      workingDirectory: dir.path,
    ).timeout(timeout);

    if (result.exitCode != 0) {
      throw StateError('claude exited ${result.exitCode}: ${result.stderr}');
    }
    return parseVerdict(const LineSplitter().convert(result.stdout as String));
  };
}

/// One labelled frame in the calibration corpus.
typedef Frame = ({String name, bool defective, String note});

/// The tally for one arm of the calibration.
class Arm {
  Arm(this.label);

  final String label;
  int flagged = 0;
  int total = 0;

  void add({required bool flaggedIt}) {
    total++;
    if (flaggedIt) flagged++;
  }

  double get rate => total == 0 ? double.nan : flagged / total;

  String get line =>
      '${label.padRight(28)} $flagged/$total  '
      '${total == 0 ? '   —' : '${(rate * 100).toStringAsFixed(0).padLeft(3)}%'}';
}
