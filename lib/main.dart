import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/providers.dart';
import 'app/router.dart';
import 'app/theme/maritime_theme.dart';
import 'features/call/presentation/ring_overlay.dart';
import 'features/settings/application/theme_mode_controller.dart';

Future<void> main() async {
  // The picker (#4) persists the chosen gateway; SharedPreferences is async to
  // obtain, so load it once here and inject it so `configProvider` can resolve
  // the persisted value synchronously at first build.
  WidgetsFlutterBinding.ensureInitialized();
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
    return MaterialApp.router(
      title: 'Aiko Chat',
      // Light echoes the original; dark is the maritime redesign. themeMode
      // follows the OS by default (ThemeMode.system) until the user overrides it
      // in Settings → Appearance.
      theme: lightTheme(),
      darkTheme: maritimeTheme(),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: router,
      // ABOVE the Navigator, so an incoming call reaches you on any route
      // (#2808). `child` is null only before the first route builds.
      builder: (context, child) =>
          RingOverlay(child: child ?? const SizedBox.shrink()),
    );
  }
}
