/// The app router + auth guard.
///
/// The redirect is a pure function of [eulaAcceptanceProvider] +
/// [authControllerProvider] state, and re-evaluates whenever either changes
/// (bridged into [refreshListenable] via a [ValueNotifier]). Zones, in order:
///   - Terms not yet accepted on this device → `/eula` (the first-run gate, ahead
///     of auth — a fresh-install reviewer sees it before signing in);
///   - auth *loading* (cold-start session restore in flight) → `/splash`, so we
///     never flash the login screen before the restore resolves;
///   - logged out → `/login`;
///   - logged in → `/` (chat).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/application/auth_controller.dart';
import '../features/auth/presentation/claim_handle_screen.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/chat/presentation/chat_screen.dart';
import '../features/chat/presentation/splash_screen.dart';
import '../features/legal/application/eula_controller.dart';
import '../features/legal/presentation/eula_screen.dart';
import '../features/moderation/presentation/blocked_users_screen.dart';
import '../features/settings/presentation/settings_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  // Bridge the auth AsyncValue into a Listenable so GoRouter re-runs `redirect`
  // on every login/logout transition.
  final refresh = ValueNotifier<int>(0);
  ref.onDispose(refresh.dispose);
  ref.listen(authControllerProvider, (_, _) => refresh.value++);
  // A new social identity awaiting its handle is a redirect trigger too.
  ref.listen(pendingHandleProvider, (_, _) => refresh.value++);
  // Accepting the Terms is a redirect trigger (gate → login/chat).
  ref.listen(eulaAcceptanceProvider, (_, _) => refresh.value++);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final loc = state.matchedLocation;

      // EULA gate (device-level, ahead of auth). Until the current Terms are
      // accepted on this device, nothing else is reachable. While acceptance is
      // still loading from local storage, park on the splash (same as an
      // in-flight session restore) rather than flashing the gate.
      final eula = ref.read(eulaAcceptanceProvider);
      if (eula.isLoading) {
        return loc == '/splash' ? null : '/splash';
      }
      if (!(eula.value ?? false)) {
        return loc == '/eula' ? null : '/eula';
      }

      final auth = ref.read(authControllerProvider);

      // Auth in flight. The COLD-START restore parks on the splash, but a
      // login/register/social call submitted FROM the login OR claim-handle
      // screen also flips state to loading — and that must keep that screen
      // (with its own in-button progress + error UI), not flash the full-screen
      // splash (Maxwell F1).
      if (auth.isLoading) {
        if (loc == '/login' || loc == '/claim-handle') return null;
        return loc == '/splash' ? null : '/splash';
      }

      final loggedIn = auth.value != null;
      // A verified-but-handle-less social identity (only meaningful while
      // logged out — see [pendingHandleProvider]).
      final pendingHandle = ref.read(pendingHandleProvider) != null;

      // Restore finished: leave the splash for the right destination.
      if (loc == '/splash') {
        if (loggedIn) return '/';
        return pendingHandle ? '/claim-handle' : '/login';
      }

      if (loggedIn) {
        // Already in — leave any auth/gate screen for chat.
        return (loc == '/login' || loc == '/claim-handle' || loc == '/eula')
            ? '/'
            : null;
      }

      // Logged out: a pending social identity must claim a handle first;
      // otherwise the login screen.
      if (pendingHandle) return loc == '/claim-handle' ? null : '/claim-handle';
      return loc == '/login' ? null : '/login';
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/eula', builder: (_, _) => const EulaScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(
          path: '/claim-handle', builder: (_, _) => const ClaimHandleScreen()),
      GoRoute(path: '/', builder: (_, _) => const ChatScreen()),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
      GoRoute(
          path: '/settings/blocked',
          builder: (_, _) => const BlockedUsersScreen()),
      GoRoute(
          path: '/settings/eula',
          builder: (_, _) => const EulaScreen(gate: false)),
    ],
  );
});
