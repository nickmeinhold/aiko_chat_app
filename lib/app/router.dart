/// The app router + auth guard.
///
/// The redirect is a pure function of [authControllerProvider]'s state, and
/// re-evaluates whenever that state changes (bridged into [refreshListenable]
/// via a [ValueNotifier]). Three zones:
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
import '../features/settings/presentation/settings_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  // Bridge the auth AsyncValue into a Listenable so GoRouter re-runs `redirect`
  // on every login/logout transition.
  final refresh = ValueNotifier<int>(0);
  ref.onDispose(refresh.dispose);
  ref.listen(authControllerProvider, (_, _) => refresh.value++);
  // A new social identity awaiting its handle is a redirect trigger too.
  ref.listen(pendingHandleProvider, (_, _) => refresh.value++);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final loc = state.matchedLocation;

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
        // Already in — leave any auth screen for chat.
        return (loc == '/login' || loc == '/claim-handle') ? '/' : null;
      }

      // Logged out: a pending social identity must claim a handle first;
      // otherwise the login screen.
      if (pendingHandle) return loc == '/claim-handle' ? null : '/claim-handle';
      return loc == '/login' ? null : '/login';
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(
          path: '/claim-handle', builder: (_, _) => const ClaimHandleScreen()),
      GoRoute(path: '/', builder: (_, _) => const ChatScreen()),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
    ],
  );
});
