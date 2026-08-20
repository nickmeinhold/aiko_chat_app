import 'package:flutter/material.dart';

// `maritime_theme.dart` re-exports ThemePalette + buildTheme, so it is the one
// import a palette author needs.
import 'maritime_theme.dart';

/// The looks a reader can choose between, and the record that makes "choose"
/// mean something.
///
/// A preset is a PAIR — a light palette and a dark one — not a single flat
/// choice. That is deliberate: picking a look must not cost you system
/// following. `ThemeMode` (System/Light/Dark) keeps answering "how bright",
/// this answers "which look", and the two compose instead of competing. A
/// preset that existed in only one brightness would silently break the OS
/// hand-off every time the sun went down.
///
/// Every palette here goes through the same [buildTheme], so a new look costs
/// twelve colours rather than twenty component subthemes — and inherits every
/// relationship the builder owns (contrast, flatness, hairline separation)
/// whether its author thought about them or not. `theme_relationships_test.dart`
/// runs the full law over every preset in [kThemePresets] in BOTH brightnesses,
/// so adding an entry to this list is what subjects a look to the design
/// language. A palette that cannot clear the bar does not ship.
///
/// All three presets keep the same STRUCTURE — flat, hairline-separated, no
/// shadows, a chart rather than an object. What varies is what the chart is
/// drawn on and in. They are instruments, not costumes.
@immutable
class ThemePreset {
  const ThemePreset({
    required this.id,
    required this.label,
    required this.blurb,
    required this.light,
    required this.dark,
  });

  /// Stable persisted key. NEVER change one — it is what a stored preference
  /// resolves against, and a renamed id silently resets every reader's choice.
  final String id;

  /// Shown in the picker.
  final String label;

  /// One line under the label — what the look IS, not which colours it uses.
  final String blurb;

  final ThemePalette light;
  final ThemePalette dark;

  ThemeData get lightTheme => buildTheme(light);
  ThemeData get darkTheme => buildTheme(dark);
}

/// The look a reader gets before they ever open Settings, and the fallback for
/// a missing or unrecognised stored id.
const kDefaultPresetId = 'maritime';

/// Sea at night / sun on water — aiko's own design language. The default.
const _maritime = ThemePreset(
  id: kDefaultPresetId,
  label: 'Maritime',
  blurb: 'A nautical chart — read by lamplight, or at noon.',
  light: maritimeNoon,
  dark: maritimeNight,
);

/// THE DRAFTING TABLE. Cyanotype: a plan drawn in white on prussian blue, and
/// its diazo cousin printed dark-on-pale. Where maritime is warm parchment,
/// blueprint is cold paper — the same instrument, a different trade. The beacon
/// stays warm on purpose: on a blue ground, the one warm mark in the room is
/// unmistakably the thing you are meant to act on.
const _blueprintDark = ThemePalette(
  brightness: Brightness.dark,
  ground: Color(0xFF0B1B3B),
  panel: Color(0xFF122450),
  panelHigh: Color(0xFF1A2F62),
  panelMine: Color(0xFF15355C),
  ink: Color(0xFFE8EEF7), // chalk
  inkDim: Color(0xFF9FB0CC),
  hairline: Color(0xFF24406E),
  signal: Color(0xFF6EA8FF), // drafting blue, lit
  beacon: Color(0xFFFFC15E), // the one warm mark
  alarm: Color(0xFFFF6B5B),
  onAccent: Color(0xFF0B1B3B),
);

const _blueprintLight = ThemePalette(
  brightness: Brightness.light,
  ground: Color(0xFFEEF2FA), // cold paper
  panel: Color(0xFFE3EAF6),
  panelHigh: Color(0xFFF8FAFE),
  panelMine: Color(0xFFD6E4F7),
  ink: Color(0xFF0B1B3B),
  inkDim: Color(0xFF4A5A78),
  hairline: Color(0xFFB9C7DE),
  signal: Color(0xFF1B4FA8), // the same blue, pressed into the page
  beacon: Color(0xFF8A5A08), // brass, as at noon
  alarm: Color(0xFF8C2318),
  onAccent: Color(0xFFF8FAFE),
);

const _blueprint = ThemePreset(
  id: 'blueprint',
  label: 'Blueprint',
  blurb: 'A drafting table — cold paper, drawn in ink.',
  light: _blueprintLight,
  dark: _blueprintDark,
);

/// THE SCOPE. A radar plot: phosphor green on near-black at night, and the pale
/// sage of the plotting table it feeds by day. The one look where the dark half
/// is the ORIGINAL and the light half is the derivation — the reverse of
/// maritime, whose chart came first and whose lamplit reading came second.
const _radarDark = ThemePalette(
  brightness: Brightness.dark,
  ground: Color(0xFF06120C),
  panel: Color(0xFF0B1D14),
  panelHigh: Color(0xFF10281B),
  panelMine: Color(0xFF0E2A1E),
  ink: Color(0xFFD8F0DF),
  inkDim: Color(0xFF8AA894),
  hairline: Color(0xFF1E3A2A),
  signal: Color(0xFF45D97F), // phosphor
  beacon: kMaritimeBeaconAmber, // the sweep
  alarm: Color(0xFFE0715E),
  onAccent: Color(0xFF06120C),
);

const _radarLight = ThemePalette(
  brightness: Brightness.light,
  ground: Color(0xFFE8EFE6), // the plotting table
  panel: Color(0xFFDEE8DB),
  panelHigh: Color(0xFFF5F8F3),
  panelMine: Color(0xFFD2E6D9),
  ink: Color(0xFF0E1F16),
  inkDim: Color(0xFF4C5F53),
  hairline: Color(0xFFB6C6B6),
  signal: Color(0xFF106B3C), // phosphor, gone to ink
  beacon: Color(0xFF8F6210),
  alarm: Color(0xFF8C2318),
  onAccent: Color(0xFFF5F8F3),
);

const _radar = ThemePreset(
  id: 'radar',
  label: 'Radar',
  blurb: 'A scope at night, and the table it plots onto by day.',
  light: _radarLight,
  dark: _radarDark,
);

/// Every selectable look, in picker order. Maritime is first because it is the
/// default and the house style.
const kThemePresets = <ThemePreset>[_maritime, _blueprint, _radar];

/// Resolve a stored id to a preset, FAIL-SOFT: a missing, unknown, or
/// since-removed id falls back to the default rather than throwing. A stored
/// preference is device state that can outlive the build that wrote it —
/// downgrading, or a preset we retire, must never leave a reader with no theme.
ThemePreset presetById(String? id) => kThemePresets.firstWhere(
  (p) => p.id == id,
  orElse: () => kThemePresets.firstWhere((p) => p.id == kDefaultPresetId),
);
