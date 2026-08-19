import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The typefaces a reader can choose for BODY text.
///
/// Fetched at runtime from Google Fonts and cached on the device, not bundled.
/// Bundling four families would have cost the better part of a megabyte across
/// three app stores for faces most readers will never select; fetching costs
/// nothing until someone actually picks one.
///
/// TWO PROPERTIES THAT FALL OUT OF THAT, both deliberate:
///
/// 1. THE DEFAULT MAKES NO NETWORK REQUEST. [systemFont] leaves `fontFamily`
///    unset, which is how the app has always rendered — the platform's own UI
///    face, SF on Apple, Roboto on Android. A reader who never opens this
///    setting never talks to Google. For an app whose thesis is sovereign
///    identity that is not a small detail, and it is why the default is not
///    merely "a nice face we picked".
///
/// 2. FAILURE IS COSMETIC. If the fetch fails — offline, blocked, flaky —
///    google_fonts logs and the text renders in the platform fallback. Nothing
///    throws into the frame; you get the default face until the download
///    succeeds. Verified against the package source, not assumed.
///
/// The MONO voice is deliberately NOT part of this choice: IBM Plex Mono stays
/// bundled and fixed. It is the instrument voice for ids, timestamps and keys —
/// closer to aiko's identity than to a reader's preference — and being bundled
/// is what lets it render on a first run with no network at all.
@immutable
class AppFont {
  const AppFont({
    required this.id,
    required this.label,
    required this.blurb,
    this.googleFamily,
  });

  /// Stable persisted key. Never change one.
  final String id;
  final String label;
  final String blurb;

  /// The Google Fonts family to fetch, or null for the platform's own face.
  final String? googleFamily;

  bool get isSystem => googleFamily == null;

  /// Dress [base] in this face. For the system font this is the identity
  /// function — leaving `fontFamily` unset is what selects the platform face,
  /// so there is nothing to apply.
  TextTheme apply(TextTheme base) =>
      isSystem ? base : GoogleFonts.getTextTheme(googleFamily!, base);
}

const systemFont = AppFont(
  id: 'system',
  label: 'System',
  blurb: "Your platform's own face. No download, works offline.",
);

/// The curated set. Small on purpose, and every entry has a REASON — a font
/// list is a menu, not a warehouse.
const kAppFonts = <AppFont>[
  systemFont,
  AppFont(
    id: 'inter',
    label: 'Inter',
    blurb: 'A screen-first humanist sans. Even colour at small sizes.',
    googleFamily: 'Inter',
  ),
  AppFont(
    id: 'literata',
    label: 'Literata',
    blurb: 'A reading serif — the logbook register, for long threads.',
    googleFamily: 'Literata',
  ),
  AppFont(
    id: 'atkinson',
    label: 'Atkinson Hyperlegible',
    blurb: 'Drawn by the Braille Institute to separate easily-confused '
        'letterforms. Pick this if text is ever a struggle.',
    googleFamily: 'Atkinson Hyperlegible',
  ),
];

const kDefaultFontId = 'system';

/// Resolve a stored id, FAIL-SOFT: unknown or missing lands on the system face,
/// which is the one choice guaranteed to render on any device with no network.
AppFont fontById(String? id) => kAppFonts.firstWhere(
      (f) => f.id == id,
      orElse: () => systemFont,
    );
