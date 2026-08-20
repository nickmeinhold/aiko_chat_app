// RENDER the themes, don't just assert about them.
//
// Everything else in this directory reasons about DECLARED values — a contrast
// ratio computed from two `Color`s, an elevation field that reads 0. That is a
// real gate, and it is also exactly the gap that let a "correct" light theme
// look like mud for four months: a declared property is not a rendered pixel.
//
// So this test actually rasterises a representative slice of chrome under every
// preset and asserts against the PIXELS that come out — the layer a reader
// meets. It also writes each render to disk when AIKO_THEME_RENDER_DIR is set:
//
//   AIKO_THEME_RENDER_DIR=/tmp/themes flutter test test/app/theme/theme_render_test.dart
//
// which is a headless way to LOOK at every theme without booting macOS, waiting
// on a build, or getting past the passkey gate.
//
// WHAT IT CANNOT SEE, stated up front: the test harness substitutes a test font,
// so glyph shapes here are not the shipped typography — this instrument measures
// COLOUR and LAYOUT, never type. `tool/theme_specimen.dart` on a real device
// remains the instrument for type.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aiko_chat_app/app/theme/theme_presets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// A slice of ordinary chrome — all STOCK Material widgets, which is the point:
/// the theme's claim is that an undecorated widget comes out dressed, so an
/// undecorated widget is what we render.
Widget _slice(ThemeData theme) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: theme,
  home: Scaffold(
    appBar: AppBar(title: const Text('# general')),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text('a message on a panel'),
          ),
        ),
        const Divider(),
        const ListTile(
          leading: Icon(Icons.tag),
          title: Text('a list tile'),
          subtitle: Text('with a dimmer second line'),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              FilledButton(onPressed: () {}, child: const Text('Send')),
              const SizedBox(width: 12),
              TextButton(onPressed: () {}, child: const Text('Cancel')),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(12),
          child: TextField(decoration: InputDecoration(hintText: 'Message')),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: () {},
      child: const Icon(Icons.send),
    ),
  ),
);

/// The pixel at [x],[y] of a rasterised widget tree.
Color _pixelAt(ByteData bytes, int width, int x, int y) {
  final o = (y * width + x) * 4;
  return Color.fromARGB(
    bytes.getUint8(o + 3),
    bytes.getUint8(o),
    bytes.getUint8(o + 1),
    bytes.getUint8(o + 2),
  );
}

void main() {
  final outDir = Platform.environment['AIKO_THEME_RENDER_DIR'];

  // Every preset × both brightnesses in ONE test body, deliberately. Splitting
  // this into one `testWidgets` per theme hangs after the first capture — the
  // binding does not schedule the frame the second `toImage()` awaits — so the
  // loop lives inside a single test. The failure `reason` on each expect carries
  // the theme name, so a failure is still identifiable without separate cases.
  testWidgets('every preset actually PAINTS in its own colours', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (final preset in kThemePresets) {
      for (final isDark in [false, true]) {
        final palette = isDark ? preset.dark : preset.light;
        final name = '${preset.id}-${isDark ? 'dark' : 'light'}';

        await tester.pumpWidget(
          RepaintBoundary(
            key: ValueKey(name),
            child: _slice(isDark ? preset.darkTheme : preset.lightTheme),
          ),
        );
        await tester.pump(const Duration(milliseconds: 32));

        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(ValueKey(name)),
        );
        // `toImage()` must run on the REAL event loop. Awaited directly, the
        // first capture succeeds (a frame was just rasterised) and every one
        // after it hangs forever: the fake-async scheduler never produces the
        // frame the future is waiting on. `runAsync` is what lets the engine
        // actually complete the rasterisation. This cost an hour; it is written
        // down so it costs nobody else one.
        final (image, bytes) = (await tester.runAsync(() async {
          final img = await boundary.toImage();
          final b = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
          return (img, b!);
        }))!;

        // THE ASSERTION THAT COULD NOT BE MADE FROM DECLARED VALUES: the actual
        // background pixel is this palette's ground. A theme that silently fell
        // back to Material's default surface passes every contrast test in
        // `theme_relationships_test.dart` — its ColorScheme is still internally
        // consistent — and fails right here.
        final bg = _pixelAt(bytes, image.width, image.width - 4, 4);
        expect(
          bg,
          palette.ground,
          reason:
              '$name painted $bg where its ground is ${palette.ground} — '
              'the palette did not reach the pixels',
        );

        // And nothing was painted under the app bar: the flatness law, checked
        // as ink on screen rather than as an `elevation: 0` field.
        expect(
          _pixelAt(bytes, image.width, image.width - 4, 120),
          bg,
          reason:
              '$name has something under the app bar that is not the '
              'ground — a shadow or a surface tint got painted',
        );

        if (outDir != null) {
          final png = await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.png),
          );
          Directory(outDir).createSync(recursive: true);
          File(
            '$outDir/$name.png',
          ).writeAsBytesSync(png!.buffer.asUint8List(), flush: true);
        }
        image.dispose();
      }
    }
  });
}
