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
import '../data/social_auth_client.dart';
import '../domain/auth_models.dart';
import '../domain/social_models.dart';

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AppUser?>(AuthController.new);

/// The transient "a new social identity has been verified but has not yet
/// claimed a handle" state. It lives ALONGSIDE [authControllerProvider]'s
/// `AppUser?` rather than inside it, so the logged-in/out state machine is
/// untouched: a non-null value here (while logged out) is what drives the
/// router to `/claim-handle`. Cleared once the handle is claimed (→ logged in)
/// or the user abandons the flow.
final pendingHandleProvider =
    NotifierProvider<PendingHandleNotifier, PendingHandle?>(
        PendingHandleNotifier.new);

class PendingHandleNotifier extends Notifier<PendingHandle?> {
  @override
  PendingHandle? build() => null;
  void set(PendingHandle pending) => state = pending;
  void clear() => state = null;
}

class AuthController extends AsyncNotifier<AppUser?> {
  ChatRestApi get _rest => ref.read(restApiProvider);
  DefaultTokenProvider get _tokens => ref.read(tokenProviderProvider);
  SocialAuthClient get _social => ref.read(socialAuthClientProvider);

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

  /// Sign in with a social [provider]. Drives the native SDK for a credential,
  /// hands the ID token to the gateway, then either logs straight in (known
  /// identity) or parks a [PendingHandle] (new identity) so the router shows the
  /// claim-handle screen. A user cancellation restores the prior state silently
  /// — no error banner.
  Future<void> signInWith(SocialProvider provider) async {
    // Social sign-in is ingress-only: ignore it when already authenticated, so a
    // stray call can't park a PendingHandle behind a live session (Carnot).
    if (state.value != null) return;
    final prior = state.value;
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final SocialCredential cred;
      try {
        cred = await _social.signIn(provider);
      } on SocialSignInCancelled {
        return prior; // user backed out — no-op, restore prior state
      }
      final outcome = await _rest.socialSignIn(
        provider: provider,
        idToken: cred.idToken,
        rawNonce: cred.rawNonce,
        name: cred.name,
      );
      switch (outcome) {
        case Authenticated(:final session):
          await _tokens.setTokens(session.tokens);
          return session.user;
        case PendingHandle pending:
          // Stay logged out; the pending state drives the router to
          // /claim-handle, where claimHandle() completes the sign-in.
          ref.read(pendingHandleProvider.notifier).set(pending);
          return prior;
      }
    });
  }

  /// Complete a new social identity's sign-in by claiming a handle. Requires a
  /// pending identity (set by [signInWith]); on success adopts the tokens,
  /// clears the pending state, and publishes the user (→ chat).
  Future<void> claimHandle(String handle, String displayName) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final pending = ref.read(pendingHandleProvider);
      if (pending == null) {
        throw StateError('claimHandle called with no pending social identity');
      }
      final session = await _rest.claimHandle(
        provisioningToken: pending.provisioningToken,
        handle: handle,
        displayName: displayName,
      );
      await _tokens.setTokens(session.tokens);
      ref.read(pendingHandleProvider.notifier).clear();
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
  /// Tear down the realtime session. The per-session CACHE and repo are NOT
  /// touched here: they are `autoDispose`-scoped to the chat screen, so logging
  /// out unmounts the screen and the autoDispose chain disposes the repo (writes
  /// stop, `_disposed` flips) and THEN closes the cache — leaf-to-root. A fresh
  /// login builds a fresh empty cache, so session isolation falls out of the
  /// lifecycle: no manual clear, and no writer-vs-clear race (Carnot R2-1/C3).
  /// Only the app-scoped transport (kept alive by [connectionStateProvider])
  /// needs an explicit disconnect.
  ///
  /// Tokens are cleared FIRST, before the (slower, awaited) disconnect — so the
  /// token-clear is effectively immediate. If it ran last, a fast re-login
  /// during the disconnect-await could write fresh tokens that the trailing
  /// clear would then stomp, leaving a logged-in-but-tokenless session (Carnot
  /// R3-B). Clearing first means any human-paced re-login's `setTokens` always
  /// lands after this clear, never before it.
  Future<void> _teardownResources() async {
    // Clear any half-finished social provisioning so a teardown ALWAYS lands in
    // a clean logged-out state — otherwise an abandoned PendingHandle survives
    // logout/terminal-auth and the router keeps forcing /claim-handle (Carnot).
    ref.read(pendingHandleProvider.notifier).clear();
    await _tokens.clearTokens();
    await ref.read(transportProvider).disconnect();
  }

  /// Explicit, user-initiated logout.
  Future<void> logout() async {
    state = const AsyncValue.data(null);
    await _teardownResources();
  }

  /// Permanently delete the account (Apple 5.1.1(v)). Unlike [logout], which
  /// cannot fail and so flips to logged-out immediately, this calls the gateway
  /// FIRST and only tears down on success — a failure (e.g. [SoleAdminDeletion
  /// Blocked]) must leave the user logged in so the settings UI can show why.
  /// On the gateway's 204 the local teardown is identical to logout, and the
  /// router's auth guard redirects to /login (no manual navigation). The thrown
  /// error propagates to the caller for an inline message.
  Future<void> deleteAccount() async {
    await _rest.deleteAccount(); // throws on 409/terminal-401 → stays logged in
    // Past this line the gateway has committed an IRREVERSIBLE delete (204): the
    // operation has SUCCEEDED. Local teardown is best-effort cleanup, so a failure
    // here must NEVER surface as "delete failed" (cage-match, Carnot). Tokens are
    // cleared inside _teardownResources before the awaited disconnect, so the
    // security-critical step still runs; a disconnect error only leaves an inert,
    // auth-less socket the next launch rebuilds.
    state = const AsyncValue.data(null);
    try {
      await _teardownResources();
    } catch (_) {
      // Swallowed — the account is already gone; nothing actionable for the user.
    }
  }

  /// The idempotent terminal-logout both dead-session signals converge on
  /// (transport `unauthenticated` + REST `onUnauthenticated`). State is flipped
  /// SYNCHRONOUSLY before the async teardown, so a second concurrent terminal
  /// signal in the same microtask drain sees null and short-circuits — the
  /// teardown runs exactly once (Carnot R2-2).
  void _becomeUnauthenticated() {
    if (state.value == null && !state.isLoading) return; // already logged out
    state = const AsyncValue.data(null);
    unawaited(_teardownResources());
  }
}
