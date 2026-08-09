/// The app router + auth guard.
///
/// The redirect is a pure function of [eulaAcceptanceProvider] +
/// [authControllerProvider] state, and re-evaluates whenever either changes
/// (bridged into [refreshListenable] via a [ValueNotifier]). Zones, in order:
///   - Terms not yet accepted on this device → `/eula` (the first-run gate, ahead
///     of auth — a fresh-install reviewer sees it before signing in);
///   - auth *loading* (cold-start session restore in flight) → `/splash`, so we
///     never flash the login screen before the restore resolves (but `/login`,
///     `/claim-handle`, and `/suspended` hold through loading);
///   - this island suspended (banned) this account → `/suspended`, ahead of the
///     logged-out routing so a ban never loops on `/login`; `/settings/gateway`
///     stays reachable so the user can switch islands;
///   - logged out → `/login`;
///   - logged in → `/` (chat) — ejecting off any auth/gate/suspended screen.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/application/auth_controller.dart';
import '../features/chat/data/chat_rest_api.dart' show AccountSuspended;
import '../features/auth/presentation/claim_handle_screen.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/suspended_screen.dart';
import '../features/chat/presentation/carried_record_screen.dart';
import '../features/chat/presentation/chat_screen.dart';
import '../features/chat/presentation/search_screen.dart';
import '../features/chat/presentation/splash_screen.dart';
import '../features/legal/application/eula_controller.dart';
import '../features/legal/presentation/eula_screen.dart';
import '../features/moderation/presentation/blocked_users_screen.dart';
import '../features/moderation/presentation/report_queue_screen.dart';
import '../features/settings/presentation/gateway_picker_screen.dart';
import '../features/settings/presentation/settings_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  // Bridge the auth AsyncValue into a Listenable so GoRouter re-runs `redirect`
  // on every login/logout transition.
  final refresh = ValueNotifier<int>(0);
  ref.onDispose(refresh.dispose);
  ref.listen(authControllerProvider, (_, _) => refresh.value++);
  // A new identity awaiting its handle is a redirect trigger too.
  ref.listen(pendingHandleProvider, (_, _) => refresh.value++);
  // A ban on this island (→ /suspended) is a redirect trigger too.
  ref.listen(suspendedProvider, (_, _) => refresh.value++);
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
      // passkey sign-in/register call submitted FROM the login OR claim-handle
      // screen also flips state to loading — and that must keep that screen
      // (with its own in-button progress + error UI), not flash the full-screen
      // splash (Maxwell F1).
      if (auth.isLoading) {
        // /suspended holds through a rebuild/restore too — a ban is
        // terminal-for-this-island, so a flagged user must not flash to /splash
        // while auth re-resolves (cage-match Tesla).
        if (loc == '/login' || loc == '/claim-handle' || loc == '/suspended') {
          return null;
        }
        return loc == '/splash' ? null : '/splash';
      }

      final loggedIn = auth.value != null;
      // A verified-but-handle-less identity (only meaningful while logged out —
      // see [pendingHandleProvider]).
      final pendingHandle = ref.read(pendingHandleProvider) != null;

      // A ban is EITHER the settled flag OR a transient AsyncError(AccountSuspended)
      // still on the machine. The ceremony doors (_ingress / claimHandle) publish
      // the ban as AsyncValue.guard error state for an instant before the
      // controller settles it to data(null)+flag; treating that error as the
      // suspended zone here makes routing correct REGARDLESS of whether the router
      // observes that transient — no one-frame /login flash on ban arrival, no
      // dependence on Riverpod/GoRouter notification timing (cage-match Carnot +
      // Tesla converged: the forbidden intermediate must not route to /login).
      final banned = ref.read(suspendedProvider) ||
          (auth.hasError && auth.error is AccountSuspended);

      // Ban on THIS island (→ /suspended), ahead of the logged-out routing so a
      // banned account never lands on /login to loop on re-auth. Guarded on
      // `!loggedIn`: a LIVE session wins (suspended ⊥ logged-in — cage-match
      // Tesla), so a flag set while authenticated falls through to the logged-in
      // eject below rather than trapping a live user on the ban screen. In the
      // normal ban path tokens are cleared, so loggedIn is already false. The
      // gateway picker stays reachable so the user can switch islands
      // (switchGateway clears the flag).
      if (!loggedIn && banned) {
        if (loc == '/settings/gateway') return null;
        return loc == '/suspended' ? null : '/suspended';
      }

      // Restore finished: leave the splash for the right destination.
      if (loc == '/splash') {
        if (loggedIn) return '/';
        return pendingHandle ? '/claim-handle' : '/login';
      }

      if (loggedIn) {
        // Already in — leave any auth/gate screen for chat. /suspended is in the
        // eject list so a logged-in user can never idle on it (cage-match Tesla:
        // suspended ⊥ logged-in — e.g. a deferred-clear race or a stale deep
        // link must bounce to chat, not sit on the ban screen while live).
        return (loc == '/login' ||
                loc == '/claim-handle' ||
                loc == '/eula' ||
                loc == '/suspended')
            ? '/'
            : null;
      }

      // The gateway picker is a PRE-LOGIN act (#35): choosing a server precedes
      // having an account on it. A user stranded on a gateway they can't sign
      // into (down, wrong URL, registration closed) must be able to switch away
      // without reinstalling — so it stays reachable while logged out, ahead of
      // both the login and claim-handle gates. switchGateway clears the
      // pending-handle + tokens, so a switch from here lands cleanly on the new
      // gateway's /login (via the loading → /splash → /login redirect).
      if (loc == '/settings/gateway') return null;

      // Logged out: a pending identity must claim a handle first;
      // otherwise the login screen.
      if (pendingHandle) return loc == '/claim-handle' ? null : '/claim-handle';
      return loc == '/login' ? null : '/login';
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/eula', builder: (_, _) => const EulaScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(
          path: '/suspended', builder: (_, _) => const SuspendedScreen()),
      GoRoute(
          path: '/claim-handle', builder: (_, _) => const ClaimHandleScreen()),
      GoRoute(path: '/', builder: (_, _) => const ChatScreen()),
      GoRoute(path: '/search', builder: (_, _) => const SearchScreen()),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
      GoRoute(
          path: '/settings/carried-record',
          builder: (_, _) => const CarriedRecordScreen()),
      GoRoute(
          path: '/settings/gateway',
          builder: (_, _) => const GatewayPickerScreen()),
      GoRoute(
          path: '/settings/blocked',
          builder: (_, _) => const BlockedUsersScreen()),
      // Operator seat (#33/#35). The Settings ENTRY is moderator-gated, but this
      // typed path itself is not router-gated — a deep link mounts it for any
      // logged-in user, at which point the screen's own isModeratorProvider gate
      // shows "no longer a moderator" and every action is ModeratorUser-gated
      // server-side (the real boundary). Router-level gating is deferred polish,
      // not a security gap (cage-match Tesla).
      GoRoute(
          path: '/moderation/reports',
          builder: (_, _) => const ReportQueueScreen()),
      GoRoute(
          path: '/settings/eula',
          builder: (_, _) => const EulaScreen(gate: false)),
    ],
  );
});
