import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/font_licences.dart';
import 'app/providers.dart';
import 'app/router.dart';
import 'features/call/application/call_end_announcer.dart';
import 'features/call/presentation/ring_overlay.dart';
import 'features/settings/application/island_manifest_provider.dart';
import 'features/settings/application/theme_mode_controller.dart';
import 'features/settings/application/theme_preset_controller.dart';

Future<void> main() async {
  // The picker (#4) persists the chosen gateway; SharedPreferences is async to
  // obtain, so load it once here and inject it so `configProvider` can resolve
  // the persisted value synchronously at first build.
  WidgetsFlutterBinding.ensureInitialized();
  // Bundled typefaces carry licence obligations that Flutter's automatic
  // package-licence collection cannot see (it does not read `assets/`).
  registerFontLicences();
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const AikoChatApp(),
    ),
  );
}

class AikoChatApp extends ConsumerWidget {
  const AikoChatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    // Ask the island who it is, once, and cache the answer. Fire-and-forget —
    // the mark renders from its URL fallback meanwhile.
    ref.watch(islandManifestFetcherProvider);
    // Held here so the announcer's lifetime is INTENTIONAL rather than
    // incidental — it must outlive any call screen (see CallEndAnnouncer).
    ref.watch(callEndAnnouncerProvider);
    // The chosen look supplies BOTH halves, so picking a preset never costs you
    // OS following: themeMode still decides how bright, the preset decides which
    // look, and the chosen typeface rides along in both. All three are set in
    // Settings → Appearance.
    return MaterialApp.router(
      title: 'Aiko Chat',
      theme: ref.watch(lightThemeProvider),
      darkTheme: ref.watch(darkThemeProvider),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: router,
      // ABOVE the Navigator, so an incoming call reaches you on any route
      // (#2808). `child` is null only before the first route builds.
      builder: (context, child) =>
          RingOverlay(child: child ?? const SizedBox.shrink()),
    );
  }
}
