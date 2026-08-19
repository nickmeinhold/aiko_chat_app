import 'package:flutter/material.dart';

import 'theme_builder.dart';

export 'theme_builder.dart' show ThemePalette, buildTheme;

/// The maritime/nautical-logbook palettes — aiko's design language ported from
/// the `docs/design/` explainers into the running app. Rationale, rejected
/// alternatives, and why this shipped hardcoded first live in
/// `docs/crucible/chatskin/` (TEMPER.md).
///
/// This file holds only the two MARITIME palettes and the app's default look.
/// The builder that dresses the app from any palette lives in
/// `theme_builder.dart`; the other selectable looks live in `theme_presets.dart`.

/// Public maritime tokens for the few ALWAYS-maritime surfaces that live outside
/// `ThemeData` and can't read the [ColorScheme] (the immersive call screen; the
/// status banner). Everything else inherits its look through ColorScheme +
/// component subthemes — reach for these only when a widget is deliberately
/// theme-independent.
///
/// NOTE these stay maritime even under another preset, by design: they dress
/// surfaces that are aiko's identity rather than the reader's preference.
const kMaritimeSeaNight = Color(0xFF0A1720);
const kMaritimeSignalCyan = Color(0xFF57C9D8);
const kMaritimeBeaconAmber = Color(0xFFF0B649);

/// Type — the platform-native UI font (SF on Apple, Roboto on Android; set by
/// leaving `fontFamily` unset) for text; IBM Plex Mono (the instrument voice) for
/// ids/timestamps, applied at the call site.
const kMaritimeMono = 'IBM Plex Mono';

/// Sea at night. The original maritime palette (PR #128).
const maritimeNight = ThemePalette(
  brightness: Brightness.dark,
  ground: kMaritimeSeaNight,
  panel: Color(0xFF0F2330),
  panelHigh: Color(0xFF15303F),
  panelMine: Color(0xFF123A44),
  ink: Color(0xFFE7E0CF), // parchment
  inkDim: Color(0xFF93A2A3),
  hairline: Color(0xFF24384A),
  signal: kMaritimeSignalCyan,
  beacon: kMaritimeBeaconAmber,
  alarm: Color(0xFFE0715E), // a warm maritime red, not stock
  onAccent: kMaritimeSeaNight,
);

/// Sun on water — the same chart, read at noon.
///
/// Three decisions carry it, and none of them is an inversion of [maritimeNight]:
///
/// 1. THE TIDE TURNS. Night's ground (`#0A1720`) is noon's ink, and night's ink
///    (parchment `#E7E0CF`) is noon's ground — the same two colours in opposite
///    roles. Only the two ANCHORS trade; everything else is re-derived, because
///    inverting every token mechanically is what produces a bleached corpse of
///    the night palette.
///
/// 2. THE BEACON BECOMES THE STAMP. A beacon is a light seen in the dark; at
///    noon nobody sees a lamp, so the role cannot survive as luminosity. In
///    daylight authority is INK DENSITY — the harbourmaster's stamp, the printed
///    depth sounding. So amber inverts into dark brass: the send lamp stops
///    glowing and starts pressing. Signal cyan takes the same treatment (on
///    paper it would read as a highlighter) and darkens to deep teal, keeping a
///    pale cyan WASH for fills in [ThemePalette.panelMine].
///
/// 3. STILL NO SHADOWS. Daylight is the one place a shadow could have earned its
///    keep, and it is refused: the metaphor is a chart READ in daylight, not an
///    object lit by the sun, and a chart is flat in any light. Hairline
///    separation is also literally how nautical charts work.
///
/// 4. MY OWN SURFACE PRESSES, IT DOES NOT LIFT. [ThemePalette.panelMine] is the
///    one panel that is DARKER than the ground here, while `panel` and
///    `panelHigh` are lighter — which looks like an inconsistency and is the
///    same rule as (2) one layer down. A lift needs headroom, and at noon the
///    ground already sits near the top of the range: a tint pale enough to lift
///    off parchment has no chroma left to be a tint. So my bubble does what a
///    tint block does on real paper and presses into it. Enforced as a law —
///    my own surface is never LESS separated from the ground than a plain panel
///    (`theme_relationships_test.dart`); the first cut of this palette inverted
///    it at 1.03:1, distinguishing my messages from the page by hue alone.
///
/// The non-obvious constraint that falls out of (2): once the beacon stops being
/// a light and becomes an ink, it lands in the same dark-warm register as the
/// alarm, and the two roles collide — armed and failed should never be
/// neighbours. [maritimeNight] never had to solve this because its beacon is
/// BRIGHT and its alarm is mid, so lightness separated them for free. Here the
/// gap has to be built deliberately: the brass is held above the oxblood in
/// luminance, not merely beside it in hue. Now enforced for EVERY palette by
/// `theme_relationships_test.dart` — the rule outlived the palette that taught
/// it, which is why every preset since has had to clear the same bar.
const maritimeNoon = ThemePalette(
  brightness: Brightness.light,
  ground: Color(0xFFE7E0CF), // chart paper — night's ink
  panel: Color(0xFFF2EDE1), // sailcloth, lifted off the chart
  panelHigh: Color(0xFFFAF7EF), // bleached — menus, sheets
  panelMine: Color(0xFFB8D5D3), // a signal wash PRESSED into the paper
  ink: kMaritimeSeaNight, // night's ground
  inkDim: Color(0xFF4F5D64), // lighter print, still AA at body size
  hairline: Color(0xFFC7BCA4), // a fine warm rule
  signal: Color(0xFF006170), // deep teal, at full chroma — stroke, not glow
  beacon: Color(0xFF8F6210), // brass in sun — the stamp
  alarm: Color(0xFF8C2318), // oxblood, kept DARKER than the brass (see below)
  onAccent: Color(0xFFFAF7EF),
);

/// Sea at night — the maritime redesign (PR #128).
ThemeData maritimeTheme() => buildTheme(maritimeNight);

/// The same chart at noon. See [maritimeNoon] for what changes and what refuses
/// to.
ThemeData lightTheme() => buildTheme(maritimeNoon);
