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
/// Every typeface this app puts in front of a reader, bundled OR fetched.
///
/// Fetching a font at runtime does NOT outsource the licence: `google_fonts`
/// touches `LicenseRegistry` nowhere in its source, so a face downloaded from
/// Google Fonts arrives with no licence attached and the obligation stays ours.
/// Each family's own OFL text — carrying its own copyright line, which is the
/// part that actually varies — is bundled beside the code. Four small text
/// files, no font binaries.
const kBundledFontLicences = <String, String>{
  'IBM Plex Mono': 'assets/fonts/OFL.txt',
  'Inter': 'assets/fonts/licences/inter.txt',
  'Literata': 'assets/fonts/licences/literata.txt',
  'Atkinson Hyperlegible': 'assets/fonts/licences/atkinsonhyperlegible.txt',
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
