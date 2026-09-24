import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/logging/boot_clock.dart';
import 'features/chat/data/transport/chat_transport.dart' as wire;
import 'core/logging/boot_telemetry.dart';
import 'app/font_licences.dart';
import 'app/providers.dart';
import 'app/router.dart';
import 'features/call/application/call_end_announcer.dart';
import 'features/call/presentation/ring_overlay.dart';
import 'features/call/presentation/system_call_navigator.dart';
import 'features/notifications/presentation/notification_tap_navigator.dart';
import 'features/notifications/data/fcm_token_source.dart';
import 'features/notifications/application/push_providers.dart';
import 'features/settings/application/island_manifest_provider.dart';
import 'features/settings/application/theme_mode_controller.dart';
import 'features/settings/application/theme_preset_controller.dart';

Future<void> main() async {
  // FIRST STATEMENT, deliberately. Everything before it is engine boot, AOT
  // load and plugin registration, and the gap between the island's push and
  // this instant is the part of a VoIP wake that no log could see — the part
  // that decides whether an invitation still looks fresh. See [BootTelemetry].
  appMainEnteredAt = DateTime.now().toUtc();
  // The picker (#4) persists the chosen gateway; SharedPreferences is async to
  // obtain, so load it once here and inject it so `configProvider` can resolve
  // the persisted value synchronously at first build.
  WidgetsFlutterBinding.ensureInitialized();
  // Bundled typefaces carry licence obligations that Flutter's automatic
  // package-licence collection cannot see (it does not read `assets/`).
  registerFontLicences();
  // ANDROID ONLY, and the guard is inside the callee. Without this
  // `FirebaseMessaging.instance` throws `noAppExists` on the first Android push
  // call, `DeviceRegistrar.start()` throws at its first line, and the failure is
  // swallowed into `pairingFailed` telemetry — so no Android device has ever
  // registered a token and nothing ever said so. The method has existed with
  // zero callers; its own doc warned against calling it from `main`
  // unconditionally, which its internal platform guard already prevents.
  await FcmTokenSource.ensureInitialized();
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
    ref.read(bootTelemetryProvider).bootStarted();
    // The true deadline a push-woken ring is racing: no invitation can arrive
    // before this fires, and the freshness gate is counting the whole time.
    // `wire.` prefixed: Flutter's material library exports its own
    // `ConnectionState`, and the unprefixed name here would silently be that
    // one — an enum whose `connected` case does not exist, which is the good
    // version of this collision. The bad version is the one that compiles.
    ref.listen(connectionStateProvider, (_, next) {
      if (next.value == wire.ConnectionState.connected) {
        ref.read(bootTelemetryProvider).socketConnected();
      }
    });
    final router = ref.watch(routerProvider);
    // Ask the island who it is, once, and cache the answer. Fire-and-forget —
    // the mark renders from its URL fallback meanwhile.
    ref.watch(islandManifestFetcherProvider);
    // Keep the push pairing current for whoever is signed in. Watched HERE, at
    // the root, because it must be listening before the session restore
    // publishes a user — a listener created any later misses the very
    // transition it exists to observe, and the failure is silence.
    ref.watch(pushPairingProvider);
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
      builder: (context, child) => NotificationTapNavigator(
        // OUTSIDE the ring overlay: a tapped notification must be honoured even
        // when nothing is ringing — the ring is long over by the time a human
        // picks the phone up (measured: 17.55s from invite to tap).
        //
        // The system-call navigator sits OUTSIDE the ring overlay too, and for a
        // stronger version of the same reason: an answer from the lock screen
        // arrives when this app has no ring of its own at all — the process was
        // dead and CallKit did the ringing (claude-tasks#4420).
        child: SystemCallNavigator(
          child: RingOverlay(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
  }
}
