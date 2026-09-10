@Tags(['render'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:aiko_chat_app/core/widgets/island_daylight.dart';
import 'package:aiko_chat_app/core/widgets/island_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A contact sheet of island marks across one day, so a human reacts to PIXELS
/// rather than to a description of pixels.
///
/// **NO WIDGET TREE.** [IslandPainter] is a `CustomPainter`; painting it onto a
/// `PictureRecorder` needs `dart:ui` and nothing else. Going through
/// `testWidgets` cost three attempts and two silent hangs — the fake-async
/// scheduler, a Tooltip timer inside `IslandMark`, and a render view that is
/// not a RepaintBoundary are all problems this instrument simply does not have.
/// The rule generalises: to look at a painter, drive the painter.
void main() {
  test('contact sheet: two islands across one day', () async {
    const islands = ['https://chat.imagineering.cc', 'https://chat.enspyr.co'];
    const hours = [0, 3, 6, 9, 12, 15, 18, 21];
    const cell = 84.0;
    const mark = 56.0;
    final width = cell * hours.length;
    final height = cell * islands.length + 30;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, height),
      Paint()..color = const Color(0xFF14181D),
    );

    for (var col = 0; col < hours.length; col++) {
      final label = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 12))
        ..pushStyle(ui.TextStyle(color: const Color(0xB3FFFFFF)))
        ..addText('${hours[col].toString().padLeft(2, '0')}:00');
      final p = label.build()
        ..layout(const ui.ParagraphConstraints(width: cell));
      canvas.drawParagraph(
        p,
        Offset(col * cell + (cell - p.maxIntrinsicWidth) / 2, 8),
      );
    }

    for (var row = 0; row < islands.length; row++) {
      final identity = IslandIdentity.of(islands[row]);
      for (var col = 0; col < hours.length; col++) {
        final alt = sunAltitudeAt(DateTime(2026, 9, 10, hours[col]));
        canvas.save();
        canvas.translate(
          col * cell + (cell - mark) / 2,
          30 + row * cell + (cell - mark) / 2,
        );
        IslandPainter(
          identity: identity,
          rim: const Color(0x33FFFFFF),
          sunAltitude: alt,
        ).paint(canvas, const Size(mark, mark));
        canvas.restore();
      }
    }

    final image = await recorder.endRecording().toImage(
      width.toInt(),
      height.toInt(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final out = File('/tmp/island-daylight.png');
    await out.writeAsBytes(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('WROTE ${out.path} (${bytes.lengthInBytes} bytes)');
    expect(bytes.lengthInBytes, greaterThan(1000));
  });
}
