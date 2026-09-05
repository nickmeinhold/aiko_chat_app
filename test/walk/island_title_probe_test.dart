// Why does the island screen's app-bar title draw as a solid block?
//
// claude-tasks#3958. The blind playtester's sweep captured `/settings/island`
// with a ~123px filled rectangle where the word "Island" belongs, while the
// chat screen's app-bar title rendered real glyphs in the same run, same theme,
// neither setting a `fontFamily`.
//
// This probe measures rather than argues. It reports the painted extent of the
// title on BOTH screens, so the two can be compared directly, and it prints the
// ink density of each — the same discriminator the font smoke test uses, where
// a filled box measures 1.0 and a letterform measures well under half.
//
// Deliberately a MEASUREMENT, not an assertion about a cause. The failure mode
// to avoid here is inventing a plausible mechanism and then reading the numbers
// through it.
@Tags(['playtest'])
library;

import 'package:aiko_chat_app/app/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/blind_playtest.dart';
import '../support/fonts.dart';
import '../support/pixels.dart';
import '../support/test_helpers.dart';
import '../support/walk_harness.dart';

/// Ink density inside [rect]: the fraction of pixels differing from the
/// background. A box glyph inks essentially all of its cell; a letterform
/// leaves most of the em empty.
///
/// The background is taken as the MODAL colour inside the rect, not sampled
/// from a nearby point. The first version of this probe sampled 40px below the
/// title and reported 1.000 for BOTH titles — including one we have a
/// screenshot of rendering as real glyphs — because the sample landed on
/// something dark and then every light pixel counted as ink. A number that
/// confirms the hypothesis is the one to distrust.
double _ink(PaintedFrame frame, Rect rect) {
  final counts = <int, int>{};
  final pixels = <int>[];
  for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
    for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
      final v = frame.at(Offset(x.toDouble(), y.toDouble())).toARGB32();
      pixels.add(v);
      counts[v] = (counts[v] ?? 0) + 1;
    }
  }
  if (pixels.isEmpty) return -1;
  final bg = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  return pixels.where((v) => v != bg).length / pixels.length;
}

/// How many DISTINCT colours the title's box contains, and what the dominant
/// one is.
///
/// This is the discriminator the ink ratio cannot supply on its own. Ink is
/// measured against the modal colour, so a rect that is UNIFORM reads 0.000
/// whether it is empty or a solid slab — the modal colour becomes the ink. An
/// antialiased letterform paints hundreds of distinct values; a filled block
/// paints one.
(int distinct, int modal) _palette(PaintedFrame frame, Rect rect) {
  final counts = <int, int>{};
  for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
    for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
      final v = frame.at(Offset(x.toDouble(), y.toDouble())).toARGB32();
      counts[v] = (counts[v] ?? 0) + 1;
    }
  }
  final modal = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  return (counts.length, modal);
}

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
    await loadRealFonts();
  });

  testWidgets('measure both app-bar titles under the same run', (tester) async {
    hideDebugChrome();
    final world = await pumpWalkableApp(tester, walkPhone);

    Future<double> report(String label, Finder title) async {
      final rect = tester.getRect(title);
      final frame = await capturePainted(tester);
      final ink = _ink(frame, rect);
      final (distinct, modal) = _palette(frame, rect);
      final text = (title.evaluate().first.widget as Text).data!;
      // ignore: avoid_print
      print(
        'TITLE[$label] text="$text" '
        'rect=${rect.width.toStringAsFixed(1)}x${rect.height.toStringAsFixed(1)} '
        'perChar=${(rect.width / text.length).toStringAsFixed(1)} '
        'ink=${ink.toStringAsFixed(3)} '
        'distinctColours=$distinct '
        'modal=0x${modal.toRadixString(16).padLeft(8, '0')}',
      );
      return ink;
    }

    // THE CONTROL, asserted rather than merely printed. This title is known —
    // by screenshot — to render as real glyphs. If it does not measure like
    // letterforms, the measurement below is void and must not be interpreted.
    final chat = await report('chat', find.text('general').first);
    expect(
      chat,
      lessThan(0.6),
      reason:
          'the control title measured $chat, so this probe cannot tell glyphs '
          'from boxes and the island reading means nothing',
    );

    world.container.read(routerProvider).go('/settings/island');
    await tester.pumpAndSettle();

    await report('island', find.text('Island').first);
    // Read the verdict off distinctColours, not off ink: one colour is a slab,
    // many is type. Stated here rather than asserted, because this file is a
    // probe and the conclusion belongs in the issue.
  });
}
