import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/app_fonts.dart';
import '../../../app/theme/skin_selection.dart';
import '../../../app/theme/theme_laws.dart';
import '../../../app/theme/theme_builder.dart';
import '../../../app/theme/theme_presets.dart';

/// SharedPreferences key for the chosen look. A DEVICE preference, like
/// `themeModePrefKey` beside it — it is not carried across islands the way
/// identity is, and it is not part of the signed record of anything.
///
/// The key is UNCHANGED from the version that stored a bare preset id, and
/// [SkinSelection.decode] still reads that shape. Anyone running the build that
/// shipped in PR #143 has a bare id sitting in this slot right now; a new key
/// would have silently reset their choice, which is a rude way to announce a
/// feature.
const themePresetPrefKey = 'aiko_theme_preset';

/// The reader's chosen look, including any colours they have changed.
///
/// Composes with — never replaces — the light/dark preference: this answers
/// "which look", `themeModeProvider` answers "how bright". Both halves of the
/// resolved preset are handed to `MaterialApp`, so System-following keeps
/// working under any preset or custom palette.
final skinSelectionProvider =
    NotifierProvider<SkinSelectionController, SkinSelection>(
      SkinSelectionController.new,
    );

/// The look as actually rendered — the chosen preset with the reader's
/// overrides applied (and any override that would break the design language
/// dropped; see [SkinSelection.resolve]).
final themePresetProvider = Provider<ThemePreset>(
  (ref) => ref.watch(skinSelectionProvider).resolve(),
);

/// The reader's chosen body face.
final appFontProvider = Provider<AppFont>(
  (ref) => ref.watch(skinSelectionProvider).font,
);

/// The two ThemeData objects the app actually renders with — palette, edits and
/// typeface composed. This is the ONLY place the three preferences meet; every
/// consumer takes a finished theme rather than reassembling the pieces (and
/// risking a surface that gets the colours but not the font).
final lightThemeProvider = Provider<ThemeData>(
  (ref) => buildTheme(
    ref.watch(themePresetProvider).light,
    font: ref.watch(appFontProvider),
  ),
);

final darkThemeProvider = Provider<ThemeData>(
  (ref) => buildTheme(
    ref.watch(themePresetProvider).dark,
    font: ref.watch(appFontProvider),
  ),
);

class SkinSelectionController extends Notifier<SkinSelection> {
  @override
  SkinSelection build() {
    final raw = ref
        .watch(sharedPreferencesProvider)
        .getString(themePresetPrefKey);
    return SkinSelection.decode(raw); // fail-soft: garbage/legacy → sane value
  }

  /// Choose a different preset. Drops any per-role edits — they were deltas
  /// against the previous preset's colours.
  void selectPreset(ThemePreset preset) => _write(state.withPreset(preset.id));

  /// Change one colour of the current preset, in one brightness.
  ///
  /// Passing a null [colour] reverts that role to the preset's own value, which
  /// is what makes a per-role "revert" genuinely remove the override rather
  /// than store the preset's colour as an edit that merely looks the same. The
  /// difference shows up later, when the preset's own value changes.
  void setRole({
    required Brightness brightness,
    required PaletteRole role,
    required Color? colour,
  }) => _write(
    state.withOverride(brightness: brightness, role: role, colour: colour),
  );

  /// Choose the body typeface.
  void selectFont(AppFont font) => _write(state.withFont(font.id));

  /// Adopt a look imported from someone else.
  ///
  /// Replaces preset, font and colour edits together — a shared look is one
  /// thing, and merging it with the reader's existing edits would produce a
  /// palette neither person chose. The import path has already validated it;
  /// this is the only entry point that takes a whole selection, so there is
  /// exactly one door for foreign state.
  void applyImported(SkinSelection imported) => _write(imported);

  /// Back to the preset's own colours. Keeps the chosen font — it was never a
  /// colour edit.
  void resetToPreset() => _write(state.reset);

  void _write(SkinSelection next) {
    // In-memory first: the app re-themes on the next frame, not after the disk
    // write. The prefs write is fire-and-forget, matching the other lightweight
    // device stores.
    state = next;
    ref
        .read(sharedPreferencesProvider)
        .setString(themePresetPrefKey, next.encode());
  }
}
