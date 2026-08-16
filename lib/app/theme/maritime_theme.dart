import 'package:flutter/material.dart';

/// The maritime/nautical-logbook theme — aiko's design language ported from the
/// `docs/design/` explainers into the running app. Rationale, rejected
/// alternatives, and why this ships hardcoded (not as a skin system yet) live in
/// `docs/crucible/chatskin/` (TEMPER.md).
///
/// The whole surface is skinned through [ColorScheme] + [TextTheme] + component
/// subthemes — NOT a bespoke token layer read by a handful of widgets. A
/// `ThemeExtension` reaches only widgets taught to read it, so Material chrome
/// (AppBar, TextField, dialogs, menus) would render half-skinned; routing every
/// value through standard `ThemeData` fields is what makes a stock widget
/// maritime for free.
///
/// There are two palettes — [_night] and [_noon] — and ONE builder, [_build].
/// That is deliberate. Light mode spent four months as a four-line
/// `ColorScheme.fromSeed` while dark got twenty hand-authored component
/// subthemes, and it stayed that way precisely because the two themes were
/// independent objects: a component could be dressed in one and forgotten in the
/// other, silently. With a single builder over a palette record, "dressed in
/// dark but not in light" is unrepresentable. The invariants both palettes must
/// satisfy are asserted in `test/app/theme/theme_relationships_test.dart` as
/// RELATIONSHIPS, never fixed hexes, so they survive any future palette —
/// including one a user authors.

/// Public maritime tokens for the few ALWAYS-maritime surfaces that live outside
/// `ThemeData` and can't read the [ColorScheme] (the immersive call screen; the
/// status banner). Everything else inherits maritime through ColorScheme +
/// component subthemes — reach for these only when a widget is deliberately
/// theme-independent.
const kMaritimeSeaNight = Color(0xFF0A1720);
const kMaritimeSignalCyan = Color(0xFF57C9D8);
const kMaritimeBeaconAmber = Color(0xFFF0B649);

/// Type — the platform-native UI font (SF on Apple, Roboto on Android; set by
/// leaving `fontFamily` unset) for text; IBM Plex Mono (the instrument voice) for
/// ids/timestamps, applied at the call site.
const kMaritimeMono = 'IBM Plex Mono';

/// The irreducible set. Everything else in a [ThemeData] is derived from these
/// by [_build] — which is what makes the pair comparable, and what a skin would
/// eventually supply.
class _Palette {
  const _Palette({
    required this.brightness,
    required this.ground,
    required this.panel,
    required this.panelHigh,
    required this.panelMine,
    required this.ink,
    required this.inkDim,
    required this.hairline,
    required this.signal,
    required this.beacon,
    required this.alarm,
    required this.onAccent,
  });

  final Brightness brightness;

  /// Grounds — the base surface, then panels lifted away from it.
  final Color ground;
  final Color panel; // others' bubbles, sidebar, cards
  final Color panelHigh; // menus, sheets, tooltips
  final Color panelMine; // signal-tinted — my own bubbles

  /// Inks.
  final Color ink; // body text
  final Color inkDim; // timestamps, captions, unselected icons
  final Color hairline; // panel edges + dividers (the ONLY separator)

  /// Accents.
  final Color signal; // primary — links, focus, the lit waterline
  final Color beacon; // secondary — the send lamp, FAB, highlights
  final Color alarm; // error
  final Color onAccent; // labels drawn ON signal/beacon/alarm
}

/// Sea at night. The original maritime palette (PR #128).
const _night = _Palette(
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
/// Three decisions carry it, and none of them is an inversion of [_night]:
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
///    pale cyan WASH for fills in [panelMine].
///
/// 3. STILL NO SHADOWS. Daylight is the one place a shadow could have earned its
///    keep, and it is refused: the metaphor is a chart READ in daylight, not an
///    object lit by the sun, and a chart is flat in any light. Hairline
///    separation is also literally how nautical charts work.
///
/// The non-obvious constraint that falls out of (2): once the beacon stops being
/// a light and becomes an ink, it lands in the same dark-warm register as the
/// alarm, and the two roles collide — armed and failed should never be
/// neighbours. [_night] never had to solve this because its beacon is BRIGHT and
/// its alarm is mid, so lightness separated them for free. Here the gap has to
/// be built deliberately: the brass is held above the oxblood in luminance, not
/// merely beside it in hue. Enforced for every accent pair by
/// `theme_relationships_test.dart`.
const _noon = _Palette(
  brightness: Brightness.light,
  ground: Color(0xFFE7E0CF), // chart paper — night's ink
  panel: Color(0xFFF2EDE1), // sailcloth, lifted off the chart
  panelHigh: Color(0xFFFAF7EF), // bleached — menus, sheets
  panelMine: Color(0xFFD5E7E6), // a pale signal wash — my own bubbles
  ink: kMaritimeSeaNight, // night's ground
  inkDim: Color(0xFF4F5D64), // lighter print, still AA at body size
  hairline: Color(0xFFC7BCA4), // a fine warm rule
  signal: Color(0xFF0B5F6C), // deep teal — signal as stroke, not glow
  beacon: Color(0xFF8F6210), // brass in sun — the stamp
  alarm: Color(0xFF8C2318), // oxblood, kept DARKER than the brass (see below)
  onAccent: Color(0xFFFAF7EF),
);

ColorScheme _scheme(_Palette p) => ColorScheme(
      brightness: p.brightness,
      primary: p.signal,
      onPrimary: p.onAccent,
      primaryContainer: p.panelMine,
      onPrimaryContainer: p.ink,
      secondary: p.beacon,
      onSecondary: p.onAccent,
      secondaryContainer: p.panelHigh,
      onSecondaryContainer: p.ink,
      tertiary: p.beacon,
      onTertiary: p.onAccent,
      error: p.alarm,
      onError: p.onAccent,
      surface: p.ground,
      onSurface: p.ink,
      surfaceContainerLowest: p.ground,
      surfaceContainerLow: p.panel,
      surfaceContainer: p.panel,
      surfaceContainerHigh: p.panelHigh,
      surfaceContainerHighest: p.panel,
      onSurfaceVariant: p.inkDim,
      outline: p.hairline,
      outlineVariant: p.hairline,
      shadow: const Color(0x00000000), // no shadows — separation is by hairline
      scrim: const Color(0x99000000),
      inverseSurface: p.ink,
      onInverseSurface: p.ground,
      inversePrimary: p.panelMine,
    );

TextTheme _text(TextTheme base, _Palette p) {
  // Body text uses the platform default (no fontFamily set); the mono voice is
  // applied explicitly at id/timestamp call sites (chat_screen.dart).
  final t = base.apply(bodyColor: p.ink, displayColor: p.ink);
  return t.copyWith(
    labelSmall: t.labelSmall?.copyWith(color: p.inkDim, letterSpacing: 0.2),
  );
}

/// The one hairline-bordered, zero-elevation panel shape used everywhere a
/// Material surface would normally cast a shadow.
RoundedRectangleBorder _panelBorder(_Palette p) => RoundedRectangleBorder(
      borderRadius: const BorderRadius.all(Radius.circular(10)),
      side: BorderSide(color: p.hairline),
    );

ThemeData _build(_Palette p) {
  final scheme = _scheme(p);
  final border = _panelBorder(p);
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: p.brightness,
    scaffoldBackgroundColor: p.ground,
    canvasColor: p.ground,
    dividerColor: p.hairline,
    shadowColor: const Color(0x00000000),
    splashFactory: InkSparkle.splashFactory,
  );

  return base.copyWith(
    textTheme: _text(base.textTheme, p),
    // Flat chrome — separation by hairline, never elevation.
    appBarTheme: AppBarTheme(
      backgroundColor: p.ground,
      foregroundColor: p.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: p.ink,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: p.hairline,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.panel,
      hintStyle: TextStyle(color: p.inkDim),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: p.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: p.signal, width: 1.5),
      ),
    ),
    cardTheme: CardThemeData(
      color: p.panel,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: border,
      margin: EdgeInsets.zero,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: border,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.panelHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: border,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.panelHigh),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.panelHigh,
      contentTextStyle: TextStyle(color: p.ink),
      actionTextColor: p.signal,
      behavior: SnackBarBehavior.floating,
    ),
    listTileTheme: ListTileThemeData(
      textColor: p.ink,
      iconColor: p.inkDim,
      selectedColor: p.signal,
      selectedTileColor: p.panel,
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: p.ground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.ground,
      selectedIconTheme: IconThemeData(color: p.signal),
      unselectedIconTheme: IconThemeData(color: p.inkDim),
      selectedLabelTextStyle: TextStyle(color: p.ink),
      unselectedLabelTextStyle: TextStyle(color: p.inkDim),
    ),
    iconTheme: IconThemeData(color: p.inkDim),
    chipTheme: ChipThemeData(
      backgroundColor: p.panel,
      side: BorderSide(color: p.hairline),
      labelStyle: TextStyle(color: p.ink),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.signal : p.inkDim,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.panelMine : p.panel,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.beacon,
      foregroundColor: p.onAccent,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: p.signal,
        foregroundColor: p.onAccent,
        elevation: 0,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.signal,
        foregroundColor: p.onAccent,
        elevation: 0,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: p.signal),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(p.hairline),
      thickness: const WidgetStatePropertyAll(6),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.panelHigh,
        borderRadius: const BorderRadius.all(Radius.circular(6)),
      ),
      textStyle: TextStyle(color: p.ink),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.signal),
  );
}

/// Sea at night — the maritime redesign (PR #128).
ThemeData maritimeTheme() => _build(_night);

/// The same chart at noon. See [_noon] for what changes and what refuses to.
ThemeData lightTheme() => _build(_noon);
