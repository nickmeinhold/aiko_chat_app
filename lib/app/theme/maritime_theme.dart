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

/// Grounds.
const _seaNight = Color(0xFF0A1720); // base surface — deep sea at night
const _seaPanel = Color(0xFF0F2330); // raised panel — others' bubbles, sidebar
const _seaPanelHigh = Color(0xFF15303F); // highest panel — menus, sheets
const _seaPanelMine = Color(0xFF123A44); // cyan-tinted panel — my own bubbles
const _parchment = Color(0xFFE7E0CF); // primary ink on the grounds
const _parchmentDim = Color(0xFF93A2A3); // secondary ink — timestamps, captions
const _hairline = Color(0xFF24384A); // panel edges + dividers (no elevation)

/// Accents.
const _signalCyan = Color(0xFF57C9D8); // primary — links, focus, my-bubble tint
const _beaconAmber = Color(0xFFF0B649); // secondary — beacons, FAB, highlights
const _signalRed = Color(0xFFE0715E); // error — a warm maritime red, not stock

/// Type — the platform-native UI font (SF on Apple, Roboto on Android; set by
/// leaving `fontFamily` unset) for text; IBM Plex Mono (the instrument voice) for
/// ids/timestamps, applied at the call site.
const kMaritimeMono = 'IBM Plex Mono';

const _maritimeColors = ColorScheme(
  brightness: Brightness.dark,
  primary: _signalCyan,
  onPrimary: _seaNight,
  primaryContainer: _seaPanelMine,
  onPrimaryContainer: _parchment,
  secondary: _beaconAmber,
  onSecondary: _seaNight,
  secondaryContainer: _seaPanelHigh,
  onSecondaryContainer: _parchment,
  tertiary: _beaconAmber,
  onTertiary: _seaNight,
  error: _signalRed,
  onError: _seaNight,
  surface: _seaNight,
  onSurface: _parchment,
  surfaceContainerLowest: _seaNight,
  surfaceContainerLow: _seaPanel,
  surfaceContainer: _seaPanel,
  surfaceContainerHigh: _seaPanelHigh,
  surfaceContainerHighest: _seaPanel,
  onSurfaceVariant: _parchmentDim,
  outline: _hairline,
  outlineVariant: _hairline,
  shadow: Color(0x00000000), // no shadows — separation is by hairline
  scrim: Color(0x99000000),
  inverseSurface: _parchment,
  onInverseSurface: _seaNight,
  inversePrimary: _seaPanelMine,
);

TextTheme _maritimeText(TextTheme base) {
  // Body text uses the platform default (no fontFamily set); the mono voice is
  // applied explicitly at id/timestamp call sites (chat_screen.dart).
  final t = base.apply(
    bodyColor: _parchment,
    displayColor: _parchment,
  );
  return t.copyWith(
    labelSmall: t.labelSmall?.copyWith(color: _parchmentDim, letterSpacing: 0.2),
  );
}

/// The one hairline-bordered, zero-elevation panel shape used everywhere a
/// Material surface would normally cast a shadow.
const _panelBorder = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(10)),
  side: BorderSide(color: _hairline),
);

ThemeData maritimeTheme() {
  final base = ThemeData(
    colorScheme: _maritimeColors,
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: _seaNight,
    canvasColor: _seaNight,
    dividerColor: _hairline,
    shadowColor: const Color(0x00000000),
    splashFactory: InkSparkle.splashFactory,
  );

  return base.copyWith(
    textTheme: _maritimeText(base.textTheme),
    // Flat chrome — separation by hairline, never elevation.
    appBarTheme: const AppBarTheme(
      backgroundColor: _seaNight,
      foregroundColor: _parchment,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: _parchment,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: _hairline,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: _seaPanel,
      hintStyle: const TextStyle(color: _parchmentDim),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _signalCyan, width: 1.5),
      ),
    ),
    cardTheme: const CardThemeData(
      color: _seaPanel,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: _panelBorder,
      margin: EdgeInsets.zero,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: _seaPanel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: _panelBorder,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: _seaPanel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: _seaPanelHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: _panelBorder,
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(_seaPanelHigh),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: _seaPanelHigh,
      contentTextStyle: TextStyle(color: _parchment),
      actionTextColor: _signalCyan,
      behavior: SnackBarBehavior.floating,
    ),
    listTileTheme: const ListTileThemeData(
      textColor: _parchment,
      iconColor: _parchmentDim,
      selectedColor: _signalCyan,
      selectedTileColor: _seaPanel,
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: _seaNight,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: _seaNight,
      selectedIconTheme: IconThemeData(color: _signalCyan),
      unselectedIconTheme: IconThemeData(color: _parchmentDim),
      selectedLabelTextStyle: TextStyle(color: _parchment),
      unselectedLabelTextStyle: TextStyle(color: _parchmentDim),
    ),
    iconTheme: const IconThemeData(color: _parchmentDim),
    chipTheme: ChipThemeData(
      backgroundColor: _seaPanel,
      side: const BorderSide(color: _hairline),
      labelStyle: const TextStyle(color: _parchment),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? _signalCyan : _parchmentDim,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? _seaPanelMine : _seaPanel,
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: _beaconAmber,
      foregroundColor: _seaNight,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: _signalCyan,
        foregroundColor: _seaNight,
        elevation: 0,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: _signalCyan,
        foregroundColor: _seaNight,
        elevation: 0,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: _signalCyan),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(_hairline),
      thickness: const WidgetStatePropertyAll(6),
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: _seaPanelHigh,
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      textStyle: TextStyle(color: _parchment),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: _signalCyan),
  );
}
