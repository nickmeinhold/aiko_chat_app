import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Declare the licences of the typefaces this app SHIPS.
///
/// Flutter's [LicenseRegistry] collects licences for every Dart package
/// automatically. It knows nothing about a `.ttf` sitting in `assets/`, so a
/// bundled font's licence is invisible unless it is registered by hand — and
/// nothing warns, nothing breaks, and nobody notices.
///
/// Nobody did notice: IBM Plex Mono shipped to three app stores under SIL OFL
/// 1.1 with the licence text nowhere in the bundle. The OFL requires the licence
/// travel with the Font Software.
///
/// The fix is a MAP rather than a procedure, so the obligation is data that can
/// be checked: `font_licences_test.dart` reads the font families out of
/// `pubspec.yaml` and fails if any of them is missing from [kBundledFontLicences].
/// Adding a font without its licence is therefore a red suite, not a discovery
/// made by a store reviewer.
const kBundledFontLicences = <String, String>{
  'IBM Plex Mono': 'assets/fonts/OFL.txt',
};

/// Register every bundled font's licence so it appears in the standard licences
/// page alongside the package licences Flutter gathers on its own.
void registerFontLicences() {
  LicenseRegistry.addLicense(() async* {
    // One entry per licence FILE, listing every family it covers — the OFL text
    // for a superfamily legitimately covers several families at once, and
    // yielding it repeatedly would show the reader the same licence N times.
    final byAsset = <String, List<String>>{};
    kBundledFontLicences.forEach((family, asset) {
      byAsset.putIfAbsent(asset, () => []).add(family);
    });

    for (final entry in byAsset.entries) {
      final text = await rootBundle.loadString(entry.key);
      yield LicenseEntryWithLineBreaks(entry.value, text);
    }
  });
}
