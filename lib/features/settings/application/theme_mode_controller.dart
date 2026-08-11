import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';

/// SharedPreferences key for the light/dark preference. A DEVICE preference (not
/// per-user): it rides the OS setting by default and is not carried across
/// islands the way identity is.
const themeModePrefKey = 'aiko_theme_mode';

/// The app's appearance preference — System (follow the OS), Light, or Dark.
/// Persisted so a choice survives a restart; defaults to System on a
/// missing/garbage value (fail-soft, like the other prefs-backed stores).
final themeModeProvider =
    NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);

class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(themeModePrefKey);
    return switch (raw) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system, // missing OR unrecognised → follow the OS
    };
  }

  /// Apply and persist [mode]. The in-memory state is the fast path (the app
  /// re-themes on the next frame); the prefs write is fire-and-forget, matching
  /// the other lightweight device stores.
  void set(ThemeMode mode) {
    state = mode;
    ref.read(sharedPreferencesProvider).setString(themeModePrefKey, mode.name);
  }
}
