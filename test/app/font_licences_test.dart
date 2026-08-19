// Every typeface we SHIP must carry its licence.
//
// This exists because the failure mode is total silence. Flutter gathers
// package licences by itself but cannot see a `.ttf` in `assets/`, so a bundled
// font with no registered licence looks exactly like one with a licence: the
// app builds, renders and ships. IBM Plex Mono reached three app stores under
// SIL OFL 1.1 with the licence text nowhere in the bundle, and nothing anywhere
// said so.
//
// The check reads the REAL pubspec rather than a copy, so it cannot drift from
// what actually ships.
import 'dart:io';

import 'package:aiko_chat_app/app/font_licences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Font families declared in pubspec.yaml's `fonts:` section.
///
/// Deliberately a small hand-rolled parse rather than a yaml dependency: the
/// shape is `    - family: NAME` and adding a package to read six lines is a
/// worse trade than a regex that fails loudly if the shape changes.
Set<String> _declaredFamilies() {
  final text = File('pubspec.yaml').readAsStringSync();
  return RegExp(r'^\s*-\s*family:\s*(.+)$', multiLine: true)
      .allMatches(text)
      .map((m) => m.group(1)!.trim())
      .toSet();
}

void main() {
  test('pubspec really does declare fonts — a parse that silently finds none '
      'would make every assertion below vacuous', () {
    expect(_declaredFamilies(), isNotEmpty);
  });

  test('every bundled font family has a registered licence', () {
    final undeclared =
        _declaredFamilies().difference(kBundledFontLicences.keys.toSet());
    expect(undeclared, isEmpty,
        reason: 'These families are bundled in pubspec.yaml but have no '
            'licence registered in lib/app/font_licences.dart: $undeclared. '
            'Bundle the licence text and add it to kBundledFontLicences — '
            'shipping a font without its licence is a compliance failure that '
            'nothing else in the toolchain will catch.');
  });

  test('no licence is registered for a font we do NOT ship — a stale entry '
      'claims a licence obligation we are not under and misleads the reader',
      () {
    final orphans =
        kBundledFontLicences.keys.toSet().difference(_declaredFamilies());
    expect(orphans, isEmpty, reason: 'stale licence entries: $orphans');
  });

  test('every referenced licence file actually exists on disk', () {
    for (final asset in kBundledFontLicences.values.toSet()) {
      expect(File(asset).existsSync(), isTrue,
          reason: '$asset is registered but missing — the licences page would '
              'throw at the moment a reader opened it');
    }
  });

  test('every referenced licence file is declared as an ASSET, or it will not '
      'be in the bundle at runtime', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final asset in kBundledFontLicences.values.toSet()) {
      expect(pubspec, contains(asset),
          reason: '$asset exists on disk but is not listed under assets: — it '
              'would load fine in a test and fail in the shipped app');
    }
  });

  testWidgets('every declared family reaches the registry with real licence '
      'text — the reader-visible end of the obligation', (tester) async {
    registerFontLicences();
    final entries = await LicenseRegistry.licenses.toList();

    for (final family in kBundledFontLicences.keys) {
      final forFamily =
          entries.where((e) => e.packages.contains(family)).toList();
      expect(forFamily, isNotEmpty,
          reason: '$family has no entry in the licences page');

      final text = forFamily.first.paragraphs.map((p) => p.text).join(' ');
      expect(text, contains('SIL Open Font License'),
          reason: '$family registered an entry with no actual licence text');
    }
  });
}
