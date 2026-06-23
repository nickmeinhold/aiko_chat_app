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
import '../features/auth/presentation/login_screen.dart';
import '../features/chat/presentation/chat_screen.dart';
import '../features/chat/presentation/splash_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  // Bridge the auth AsyncValue into a Listenable so GoRouter re-runs `redirect`
  // on every login/logout transition.
  final refresh = ValueNotifier<int>(0);
  ref.onDispose(refresh.dispose);
  ref.listen(authControllerProvider, (_, _) => refresh.value++);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final loc = state.matchedLocation;

      // Cold-start restore in flight: hold on the splash.
      if (auth.isLoading) return loc == '/splash' ? null : '/splash';

      final loggedIn = auth.value != null;

      // Restore finished: leave the splash for the right destination.
      if (loc == '/splash') return loggedIn ? '/' : '/login';

      if (!loggedIn) return loc == '/login' ? null : '/login';
      if (loc == '/login') return '/'; // already in — skip login
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/', builder: (_, _) => const ChatScreen()),
    ],
  );
});
