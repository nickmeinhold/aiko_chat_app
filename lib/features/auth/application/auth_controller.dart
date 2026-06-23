/// The authentication state machine — the app-layer owner of "who is logged in".
///
/// It exposes the current [AppUser] (null = logged out) and the login/register/
/// logout transitions. Crucially, it is the SINGLE reconciliation point for the
/// two independent "session is dead" signals (the #9 trust-boundary concern):
///
///   1. The transport's `ConnectionState.unauthenticated` — the WSS (re)connect
///      found the refresh token rejected.
///   2. The REST [DefaultTokenProvider]'s `onUnauthenticated` callback, surfaced
///      via [authEventsProvider] — a REST call found the refresh token rejected
///      while the socket may have been fine.
///
/// Both converge on one idempotent [_becomeUnauthenticated]. A *transient*
/// disconnect (`ConnectionState.disconnected`) must NEVER log out — that is the
/// transient-vs-terminal 401 boundary the whole data layer was built to preserve
/// (design 02 / auth_error_boundary). Only the terminal `unauthenticated` does.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/auth/token_provider.dart';
import '../../chat/data/chat_rest_api.dart';
import '../../chat/data/transport/chat_transport.dart';
import '../domain/auth_models.dart';

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AppUser?>(AuthController.new);

class AuthController extends AsyncNotifier<AppUser?> {
  ChatRestApi get _rest => ref.read(restApiProvider);
  DefaultTokenProvider get _tokens => ref.read(tokenProviderProvider);

  @override
  Future<AppUser?> build() async {
    // Reconcile signal (1): the WSS terminal-auth state. Only `unauthenticated`
    // logs out; `disconnected` is a transient drop the transport retries.
    ref.listen<AsyncValue<ConnectionState>>(connectionStateProvider, (_, next) {
      if (next.value == ConnectionState.unauthenticated) {
        _becomeUnauthenticated();
      }
    });

    // Reconcile signal (2): a REST refresh-token rejection.
    final events = ref.watch(authEventsProvider);
    final sub = events.stream.listen((_) => _becomeUnauthenticated());
    ref.onDispose(sub.cancel);

    return _restoreSession();
  }

  /// Cold-start session restore. With no in-memory session yet, a transient
  /// failure cannot lose live data, so the Phase-1 rule is simple: tokens +
  /// valid `me()` → authenticated; otherwise → logged out (show login). A
  /// terminal rejection clears the dead tokens; a transient error leaves them
  /// in place so a retry can still succeed (named Phase-1 tradeoff: a network
  /// blip at launch shows the login screen rather than a stale session).
  Future<AppUser?> _restoreSession() async {
    final existing = await _tokens.currentAccessToken();
    if (existing == null) return null; // never logged in
    try {
      return await _rest.me();
    } on Unauthorized {
      await _tokens.clearTokens(); // tokens are genuinely dead
      return null;
    } catch (_) {
      return null; // transient — tokens kept, just show login this launch
    }
  }

  /// Log in with username/password. Adopts the returned tokens so the REST
  /// interceptor and WSS connect can immediately use them, then publishes the
  /// user (which trips the router guard → chat).
  Future<void> login(String username, String password) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final session = await _rest.login(username, password);
      await _tokens.setTokens(session.tokens);
      return session.user;
    });
  }

  /// Register a new account, then sign straight in (the gateway returns tokens
  /// on register, same shape as login).
  Future<void> register(
      String username, String displayName, String password) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final session = await _rest.register(username, displayName, password);
      await _tokens.setTokens(session.tokens);
      return session.user;
    });
  }

  /// Full session teardown — the SINGLE owner of "end this session". Both the
  /// explicit [logout] and the signal-driven [_becomeUnauthenticated] route
  /// through it, so a terminal logout is ALWAYS complete, never partial:
  ///   - disconnect the realtime socket — else the session-singleton transport
  ///     keeps the old (now server-invalid) socket and the next login's
  ///     `connect()` early-returns on a live `_channel`, reusing a dead session
  ///     and never re-running subscribe→drain→history (Carnot C1);
  ///   - drop the in-memory cache — else a different user logging in on the same
  ///     app instance sees the previous user's messages (Carnot C3);
  ///   - clear tokens; publish logged-out (router → login).
  /// The cache is wiped via [DriftCache.clearAll] (a row delete) rather than
  /// `ref.invalidate(cacheProvider)` — invalidating the provider mid-teardown
  /// triggers a dependent rebuild during the widget build the auth-state change
  /// already kicked off ("setState during build"). Clearing rows is a normal
  /// data update the StreamProvider absorbs cleanly.
  Future<void> _endSession() async {
    await ref.read(transportProvider).disconnect();
    await ref.read(cacheProvider).clearAll(); // session isolation
    await _tokens.clearTokens();
    state = const AsyncValue.data(null);
  }

  /// Explicit, user-initiated logout.
  Future<void> logout() => _endSession();

  /// The idempotent terminal-logout both dead-session signals converge on
  /// (transport `unauthenticated` + REST `onUnauthenticated`). No-op if already
  /// logged out, so duplicate terminal signals tear down exactly once.
  void _becomeUnauthenticated() {
    if (state.value == null && !state.isLoading) return; // already logged out
    unawaited(_endSession());
  }
}
