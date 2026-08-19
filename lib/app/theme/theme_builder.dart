import 'package:flutter/material.dart';

import 'app_fonts.dart';

/// The one door: a [ThemePalette] of twelve colours in, a fully-dressed
/// [ThemeData] out.
///
/// The whole surface is skinned through [ColorScheme] + [TextTheme] + component
/// subthemes — NOT a bespoke token layer read by a handful of widgets. A
/// `ThemeExtension` reaches only widgets taught to read it, so Material chrome
/// (AppBar, TextField, dialogs, menus) would render half-skinned; routing every
/// value through standard `ThemeData` fields is what makes a stock widget
/// maritime — or blueprint, or radar — for free.
///
/// ONE builder over a palette record is what stops a look from rotting. Light
/// mode spent four months as a four-line `ColorScheme.fromSeed` while dark got
/// twenty hand-authored component subthemes, and it stayed that way precisely
/// because the two themes were independent objects: a component could be dressed
/// in one and forgotten in the other, silently. Here, "dressed in one palette but
/// not another" is unrepresentable.
///
/// It is also the safety property. **The palette supplies hue; the builder owns
/// every relationship.** No choice of the twelve colours below can decide that a
/// control has no contrast against what it sits on, because no palette gets to
/// state that relationship — the builder computes it. That is what will make
/// user-chosen colour safe, and it is asserted for every shipped palette in
/// `test/app/theme/theme_relationships_test.dart`.
///
/// Scope note: that guarantee covers COLOUR AND CONTRAST ONLY. It says nothing
/// about layout (which controls are shown, where, at what density) — a skin that
/// could express layout could hide things a skin that can only recolour cannot.
/// See claude-tasks#2715.

/// The irreducible set. Everything else in a [ThemeData] is derived from these
/// by [buildTheme] — which is what makes any two palettes comparable, and what a
/// user-authored skin would eventually supply.
class ThemePalette {
  const ThemePalette({
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

ColorScheme _scheme(ThemePalette p) => ColorScheme(
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

TextTheme _text(TextTheme base, ThemePalette p, AppFont font) {
  // The reader's chosen face first, THEN the palette's inks — applying colour
  // before the family would have the family's own null colours overwrite it.
  final t = font.apply(base).apply(bodyColor: p.ink, displayColor: p.ink);
  return t.copyWith(
    labelSmall: t.labelSmall?.copyWith(color: p.inkDim, letterSpacing: 0.2),
  );
}

/// The one hairline-bordered, zero-elevation panel shape used everywhere a
/// Material surface would normally cast a shadow.
RoundedRectangleBorder _panelBorder(ThemePalette p) => RoundedRectangleBorder(
      borderRadius: const BorderRadius.all(Radius.circular(10)),
      side: BorderSide(color: p.hairline),
    );

/// Dress the entire app from [p]. Every preset, in both brightnesses, comes
/// through here — there is no second path to a [ThemeData] in this app.
ThemeData buildTheme(ThemePalette p, {AppFont font = systemFont}) {
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
    textTheme: _text(base.textTheme, p, font),
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
