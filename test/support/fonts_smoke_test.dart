// Does the harness draw LETTERS, or boxes?
//
// The distinguishing measurement is ink density inside the text's own rect. The
// test font paints every character as a solid filled rectangle, so it inks
// essentially the whole box; a real letterform leaves most of its em empty.
// That ratio is the one property that separates the two, and it is why this
// test can go red — an assertion on "the text widget exists" would be green in
// both worlds, which is the failure mode this whole file exists to close.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fonts.dart';
import 'pixels.dart';

/// Fraction of pixels inside [rect] that are not the background colour.
double _inkRatio(PaintedFrame frame, Rect rect, Color background) {
  var inked = 0;
  var total = 0;
  for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
    for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
      total++;
      final c = frame.at(Offset(x.toDouble(), y.toDouble()));
      // Any pixel meaningfully darker than the background counts as ink;
      // antialiased edges land in between and are counted, which biases the
      // ratio UP — i.e. against the claim being made. A conservative direction.
      if ((c.computeLuminance() - background.computeLuminance()).abs() > 0.05) {
        inked++;
      }
    }
  }
  return total == 0 ? 1 : inked / total;
}

void main() {
  testWidgets('real fonts render letterforms, not filled boxes', (tester) async {
    await loadRealFonts();

    const background = Color(0xFFFFFFFF);
    await tester.pumpWidget(
      const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ColoredBox(
          color: background,
          child: Center(
            child: Text(
              'HHHHHH',
              style: TextStyle(
                fontFamily: 'Roboto',
                fontSize: 64,
                color: Color(0xFF000000),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final frame = await capturePainted(tester);
    final rect = tester.getRect(find.text('HHHHHH'));
    final ink = _inkRatio(frame, rect, background);

    // 'H' is a deliberately ink-HEAVY glyph, so this bound is generous in the
    // direction that makes the test hard to pass by accident. A box render
    // measures ~1.0 here; Roboto measures well under half.
    expect(
      ink,
      lessThan(0.6),
      reason:
          'ink ratio $ink — the harness is drawing filled boxes, so every '
          'render in this suite is blind to type',
    );
    expect(ink, greaterThan(0.05), reason: 'ink ratio $ink — nothing drew at all');
  });
}
