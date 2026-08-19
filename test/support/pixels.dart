// Read the colours a widget test ACTUALLY PAINTED.
//
// The suite is rigorous about wire formats, state lifecycles, concurrency and
// retraction ordering, and it was structurally blind to "did it draw". That is
// not hypothetical: the composer's lit waterline shipped at zero height,
// invisible in both themes, under a test that asserted its widthFactor animates
// 0 -> 1 — perfectly true of a box with no height.
//
// A declared property is not a rendered pixel. Where a test's CLAIM is visual
// ("the row is visibly distinct", "the rule ignites"), the assertion belongs
// here. Where the claim is semantic (`ListTile.selected`, a controller's text,
// whether a button is enabled), reading the widget is correct and this is the
// wrong tool.
//
// The rendered THEME slice has its own harness in
// `test/app/theme/theme_render_test.dart`, which also dumps PNGs; this is for
// probing a point inside a full pumped app.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// One rasterisation of the whole pumped app, probeable by logical offset.
///
/// Capture once and probe many times — each capture is a real rasterisation.
class PaintedFrame {
  PaintedFrame._(this._bytes, this._width, this._scale);

  final ByteData _bytes;
  final int _width;
  final double _scale;

  /// The colour painted at [point], in GLOBAL LOGICAL coordinates — the same
  /// space `tester.getRect` reports in.
  Color at(Offset point) {
    // `RenderView.paintBounds` is in PHYSICAL pixels (2400x1800 for an 800x600
    // test view at dpr 3), so a logical offset scales by the device pixel ratio
    // to index the capture. Treating the capture as a 1:1 logical space probes
    // a point a third of the way up the screen and reports whatever is there —
    // a wrong answer with no error, in the instrument built to prevent exactly
    // that.
    final o = (((point.dy * _scale).round() * _width) +
            (point.dx * _scale).round()) *
        4;
    return Color.fromARGB(
      _bytes.getUint8(o + 3),
      _bytes.getUint8(o),
      _bytes.getUint8(o + 1),
      _bytes.getUint8(o + 2),
    );
  }
}

/// Rasterise the current frame through the root repaint boundary.
///
/// The root, rather than a widget-local boundary, because the trees under test
/// do not contain RepaintBoundaries and inserting one would change the thing
/// being measured.
Future<PaintedFrame> capturePainted(WidgetTester tester) async {
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final (image, bytes) = (await tester.runAsync(() async {
    // `toImage` must run on the REAL event loop. Awaited under the fake-async
    // scheduler, the frame it is waiting on is never produced and it hangs
    // forever rather than failing — a silent wedge, not an error.
    final img = await layer.toImage(view.paintBounds);
    final b = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    return (img, b!);
  }))!;
  final frame =
      PaintedFrame._(bytes, image.width, tester.view.devicePixelRatio);
  image.dispose();
  return frame;
}

/// WCAG relative-luminance contrast between two opaque painted colours.
double paintedContrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
}
