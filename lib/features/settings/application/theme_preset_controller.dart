import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/theme_presets.dart';

/// SharedPreferences key for the chosen look. A DEVICE preference, like
/// `themeModePrefKey` beside it — it is not carried across islands the way
/// identity is, and it is not part of the signed record of anything.
const themePresetPrefKey = 'aiko_theme_preset';

/// The reader's chosen look. Composes with — never replaces — the light/dark
/// preference: this answers "which look", `themeModeProvider` answers "how
/// bright". Both halves of the chosen preset are handed to `MaterialApp`, so
/// System-following keeps working under any preset.
///
/// Defaults to Maritime on a missing OR unrecognised value (fail-soft, matching
/// the other prefs-backed device stores). Storing the ID rather than a resolved
/// palette is what lets a preset's colours be revised in a later build without
/// stranding readers on a frozen copy.
final themePresetProvider =
    NotifierProvider<ThemePresetController, ThemePreset>(
  ThemePresetController.new,
);

class ThemePresetController extends Notifier<ThemePreset> {
  @override
  ThemePreset build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(themePresetPrefKey);
    return presetById(raw); // fail-soft: unknown/missing → the default look
  }

  /// Apply and persist [preset]. The in-memory state is the fast path (the app
  /// re-themes on the next frame); the prefs write is fire-and-forget, matching
  /// the other lightweight device stores.
  void set(ThemePreset preset) {
    state = preset;
    ref.read(sharedPreferencesProvider).setString(themePresetPrefKey, preset.id);
  }
}
