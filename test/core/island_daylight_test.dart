import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aiko_chat_app/core/widgets/island_daylight.dart';
import 'package:aiko_chat_app/core/widgets/island_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sample one pixel from a painted mark.
///
/// Drives the PAINTER directly onto a `PictureRecorder` — no widget tree. Going
/// through `testWidgets` for this cost three attempts and two SILENT hangs: the
/// fake-async scheduler, a Tooltip timer inside `IslandMark`, and a test render
/// view that is not a RepaintBoundary. To test a painter, drive the painter.
Future<Color> _pixel(IslandPainter painter, double size, Offset at) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), Size(size, size));
  final image = await recorder.endRecording().toImage(
    size.toInt(),
    size.toInt(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = Uint8List.view(data!.buffer);
  final i = ((at.dy.toInt() * size.toInt()) + at.dx.toInt()) * 4;
  return Color.fromARGB(bytes[i + 3], bytes[i], bytes[i + 1], bytes[i + 2]);
}

const _url = 'https://chat.imagineering.cc';
const _noRim = Color(0x00000000);
// Water, well clear of the island and inside the disc.
const _water = Offset(8, 32);

void main() {
  group('sunAltitudeAt — the one input both expressions read', () {
    test('local noon is full day', () {
      expect(sunAltitudeAt(DateTime(2026, 9, 10, 12)), closeTo(1.0, 0.001));
    });
    test('local midnight is full night', () {
      expect(sunAltitudeAt(DateTime(2026, 9, 10, 0)), closeTo(-1.0, 0.001));
    });
    test('06:00 and 18:00 are the horizon — where the terminator crosses', () {
      expect(sunAltitudeAt(DateTime(2026, 9, 10, 6)), closeTo(0.0, 0.001));
      expect(sunAltitudeAt(DateTime(2026, 9, 10, 18)), closeTo(0.0, 0.001));
    });
    test('monotonic through the morning', () {
      var last = sunAltitudeAt(DateTime(2026, 9, 10, 0));
      for (var h = 1; h <= 12; h++) {
        final now = sunAltitudeAt(DateTime(2026, 9, 10, h));
        expect(now, greaterThan(last), reason: 'hour $h went backwards');
        last = now;
      }
    });
  });

  group('moonIlluminationAt — the second, slower clock', () {
    test('the anchor new moon is dark', () {
      expect(
        moonIlluminationAt(DateTime.utc(2000, 1, 6, 18, 14)),
        closeTo(0.0, 0.01),
      );
    });
    test('half a synodic month later is full', () {
      expect(
        moonIlluminationAt(
          DateTime.utc(
            2000,
            1,
            6,
            18,
            14,
          ).add(const Duration(hours: 354, minutes: 22)),
        ),
        closeTo(1.0, 0.01),
      );
    });
    test('stays in range across a year', () {
      for (var d = 0; d < 365; d++) {
        final v = moonIlluminationAt(DateTime.utc(2026).add(Duration(days: d)));
        expect(v, inInclusiveRange(0.0, 1.0), reason: 'day $d');
      }
    });
  });

  test(
    'NULL DRAWS THE ORIGINAL — the regression pin for all of this',
    () async {
      // No island publishes a timezone, so null is the COMMON path and every
      // pixel of it must be untouched. Without this, any of the daylight work
      // could silently change the mark that ships today and nothing would fail.
      final identity = IslandIdentity.of(_url);
      final plain = await _pixel(
        IslandPainter(identity: identity, rim: _noRim),
        64,
        _water,
      );
      expect(plain.r, closeTo(identity.water.r, 0.01));
      expect(plain.g, closeTo(identity.water.g, 0.01));
      expect(plain.b, closeTo(identity.water.b, 0.01));
    },
  );

  group('identity survives the night', () {
    test('THE HUE DOES NOT MOVE between noon and midnight', () async {
      // The mark's whole job is answering "which island am I on", and it has to
      // keep answering at 1am. Hue is the identity; only lightness and
      // saturation may ride the sun.
      final identity = IslandIdentity.of(_url);
      final day = await _pixel(
        IslandPainter(identity: identity, rim: _noRim, sunAltitude: 1),
        64,
        _water,
      );
      final night = await _pixel(
        IslandPainter(identity: identity, rim: _noRim, sunAltitude: -1),
        64,
        _water,
      );
      expect(
        (HSLColor.fromColor(day).hue - HSLColor.fromColor(night).hue).abs(),
        lessThan(10.0),
        reason: 'night repainted the island a different colour',
      );
      expect(
        HSLColor.fromColor(night).lightness,
        lessThan(HSLColor.fromColor(day).lightness),
        reason: 'midnight must actually be darker than noon',
      );
    });

    test('saturation is retained, not drained flat', () async {
      // Rendered as a fleet of 24, a heavier drain compressed every island
      // toward a common dusty pastel — identity preserved in principle,
      // unreadable in practice, at exactly the hour you most need it. n=2 could
      // not show that; n=24 showed it immediately.
      final identity = IslandIdentity.of(_url);
      final night = await _pixel(
        IslandPainter(identity: identity, rim: _noRim, sunAltitude: -1),
        64,
        _water,
      );
      expect(
        HSLColor.fromColor(night).saturation,
        greaterThan(HSLColor.fromColor(identity.water).saturation * 0.6),
      );
    });
  });
}
