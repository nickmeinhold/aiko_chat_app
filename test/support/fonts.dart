// Real glyphs in the widget-test harness.
//
// `flutter test` substitutes a test font, so every character rasterises as a
// filled box and MaterialIcons with it. Everything that renders here therefore
// measured COLOUR and LAYOUT and was structurally blind to TYPE — which also
// made it blind to any defect whose meaning lives in the words: two sign-in
// ingresses at different emphasis are identical grey slabs to a box render.
//
// Loading the SDK's Roboto plus the app's own IBM Plex Mono closes that. The
// typeface is not the shipped one on any platform (the app uses the platform
// UI font for body text), so this still is NOT a typography instrument —
// `tool/theme_specimen.dart` on a real device stays that. It is an instrument
// for whether the words are the right words, legible, and weighted as intended.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Where the Flutter SDK keeps Roboto + MaterialIcons.
///
/// Derived from the running engine's own path rather than an env var, so a
/// second SDK on the machine cannot silently supply different glyphs. Under
/// `flutter test` that executable is
/// `<sdk>/bin/cache/artifacts/engine/<platform>/flutter_tester`, so walk up to
/// the `cache` directory by NAME — a fixed number of `.parent` hops encodes a
/// platform-specific depth and lands somewhere plausible-but-wrong.
String get _materialFonts {
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.path != dir.parent.path) {
    if (dir.path.endsWith('/cache')) {
      return '${dir.path}/artifacts/material_fonts';
    }
    dir = dir.parent;
  }
  throw StateError(
    'no flutter cache above ${Platform.resolvedExecutable} — cannot locate '
    'the SDK fonts, and rendering would silently fall back to box glyphs',
  );
}

bool _loaded = false;

/// Load real fonts into the harness. Idempotent; call before `pumpWidget`.
///
/// MUST read the font bytes SYNCHRONOUSLY. `File.readAsBytes()` is real async
/// I/O, and a real future awaited under `flutter_test`'s fake-async scheduler
/// never completes — the test hangs silently rather than failing, the same
/// wedge documented for `toImage()` in `pixels.dart`.
Future<void> loadRealFonts() async {
  if (_loaded) return;
  _loaded = true;
  await _load('Roboto', [
    '$_materialFonts/Roboto-Regular.ttf',
    '$_materialFonts/Roboto-Medium.ttf',
    '$_materialFonts/Roboto-Bold.ttf',
  ]);
  await _load('MaterialIcons', ['$_materialFonts/MaterialIcons-Regular.otf']);
  await _load('IBM Plex Mono', [
    'assets/fonts/IBMPlexMono-Regular.ttf',
    'assets/fonts/IBMPlexMono-Medium.ttf',
  ]);
}

Future<void> _load(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) {
      // Never skip. A missing font file that loads "successfully" leaves the
      // box-glyph fallback in place, and every render then measures nothing
      // while reporting green.
      throw StateError('font missing for $family: $path');
    }
    final bytes = file.readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}
