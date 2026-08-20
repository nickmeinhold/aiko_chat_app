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
import 'package:aiko_chat_app/app/theme/app_fonts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Font families declared in pubspec.yaml's `fonts:` section.
///
/// Deliberately a small hand-rolled parse rather than a yaml dependency: the
/// shape is `    - family: NAME` and adding a package to read six lines is a
/// worse trade than a regex that fails loudly if the shape changes.
Set<String> _declaredFamilies() {
  final text = File('pubspec.yaml').readAsStringSync();
  return RegExp(
    r'^\s*-\s*family:\s*(.+)$',
    multiLine: true,
  ).allMatches(text).map((m) => m.group(1)!.trim()).toSet();
}

/// Every family this app can put in front of a reader: the ones BUNDLED in
/// pubspec, plus the ones FETCHED at runtime from Google Fonts. Both carry the
/// same obligation — fetching a font does not transfer its licence to whoever
/// served it, and google_fonts registers nothing on our behalf.
Set<String> _shippableFamilies() => {
  ..._declaredFamilies(),
  for (final f in kAppFonts)
    if (f.googleFamily != null) f.googleFamily!,
};

void main() {
  test('pubspec really does declare fonts — a parse that silently finds none '
      'would make every assertion below vacuous', () {
    expect(_declaredFamilies(), isNotEmpty);
  });

  test('the fetchable set is non-empty too, for the same reason', () {
    expect(
      _shippableFamilies().length,
      greaterThan(_declaredFamilies().length),
    );
  });

  test('every family we bundle OR fetch has a registered licence', () {
    final undeclared = _shippableFamilies().difference(
      kBundledFontLicences.keys.toSet(),
    );
    expect(
      undeclared,
      isEmpty,
      reason:
          'These families are shipped or fetched but have no licence '
          'registered in lib/app/font_licences.dart: $undeclared. '
          'Bundle the licence text and add it to kBundledFontLicences — '
          'shipping a font without its licence is a compliance failure that '
          'nothing else in the toolchain will catch.',
    );
  });

  test(
    'no licence is registered for a font we do NOT ship — a stale entry '
    'claims a licence obligation we are not under and misleads the reader',
    () {
      final orphans = kBundledFontLicences.keys.toSet().difference(
        _shippableFamilies(),
      );
      expect(orphans, isEmpty, reason: 'stale licence entries: $orphans');
    },
  );

  test('every referenced licence file actually exists on disk', () {
    for (final asset in kBundledFontLicences.values.toSet()) {
      expect(
        File(asset).existsSync(),
        isTrue,
        reason:
            '$asset is registered but missing — the licences page would '
            'throw at the moment a reader opened it',
      );
    }
  });

  test('every referenced licence file is declared as an ASSET, or it will not '
      'be in the bundle at runtime', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    // Flutter bundles an asset declared EITHER by exact path or by its
    // containing directory (a trailing-slash entry takes the whole folder), so
    // both count. Checking only for the literal path would fail a perfectly
    // bundled file and tempt someone to delete the test.
    for (final asset in kBundledFontLicences.values.toSet()) {
      final dir = '${asset.substring(0, asset.lastIndexOf('/'))}/';
      expect(
        pubspec.contains(asset) || pubspec.contains(dir),
        isTrue,
        reason:
            '$asset exists on disk but neither it nor its directory '
            '($dir) is listed under assets: — it would load fine in a test '
            'and be absent in the shipped app',
      );
    }
  });

  testWidgets('every declared family reaches the registry with real licence '
      'text — the reader-visible end of the obligation', (tester) async {
    registerFontLicences();
    final entries = await LicenseRegistry.licenses.toList();

    for (final family in kBundledFontLicences.keys) {
      final forFamily = entries
          .where((e) => e.packages.contains(family))
          .toList();
      expect(
        forFamily,
        isNotEmpty,
        reason: '$family has no entry in the licences page',
      );

      final text = forFamily.first.paragraphs.map((p) => p.text).join(' ');
      expect(
        text,
        contains('SIL Open Font License'),
        reason: '$family registered an entry with no actual licence text',
      );
    }
  });
}
