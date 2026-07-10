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

import '../../../app/config.dart';
import '../../../app/providers.dart';
import '../../../core/auth/token_provider.dart';
import '../../chat/data/chat_rest_api.dart';
import '../../chat/data/transport/chat_transport.dart';
import '../data/auth_exceptions.dart';
import '../data/passkey_auth_client.dart';
import '../domain/auth_models.dart';
import '../domain/identity_models.dart';

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AppUser?>(AuthController.new);

/// The transient "a new identity has been verified but has not yet claimed a
/// handle" state (first-passkey-creates-account). It lives ALONGSIDE
/// [authControllerProvider]'s
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
  PasskeyAuthClient get _passkey => ref.read(passkeyAuthClientProvider);

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

  /// The shared ingress preamble for every "start a sign-in ceremony" entry
  /// point (passkey-authenticate, passkey-register). Ingress-only
  /// AND single-flight — the guard rejects when:
  ///   * a session is already live (`state.value != null`) — a stray call must
  ///     not park a PendingHandle behind a live session (Carnot, #37); OR
  ///   * a ceremony is already in flight (`state.isLoading`) — a second
  ///     concurrent ingress would issue a SECOND gateway challenge before the
  ///     first `finish` resolved, and for passkeys the start-of-ceremony
  ///     `cancelCurrentAuthenticatorOperation()` would silently cancel the first
  ///     sheet (mapped to a no-op restore), letting the LATER challenge win
  ///     (Carnot, #38). The `value != null` guard alone left this open because a
  ///     logged-out `AsyncLoading` has `value == null`.
  ///
  /// Centralised here so the guard CAN'T be forgotten on the next ingress added
  /// (it already was, once). [ceremony] receives the captured prior state to
  /// thread into a cancellation restore / [_applyOutcome].
  Future<void> _ingress(
      Future<AppUser?> Function(AppUser? prior) ceremony) async {
    if (state.value != null || state.isLoading) return;
    final prior = state.value;
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => ceremony(prior));
  }

  /// Sign in with an EXISTING passkey (WebAuthn). The ingress is a gateway
  /// challenge + an on-device authenticator assertion: fetch the request
  /// options, let the platform sign the challenge with a discoverable credential
  /// (usernameless), then redeem the assertion and route on the outcome. A user
  /// dismissal of the system sheet restores the prior state silently (no error
  /// banner). A "no passkey on this device" error is a real [AuthCeremonyFailed]
  /// — surfaced, not swallowed — so the UI can nudge toward [registerWithPasskey].
  Future<void> signInWithPasskey() => _ingress((prior) async {
        final challenge = await _rest.startPasskeyAuthentication();
        final String assertion;
        try {
          assertion = await _passkey.authenticate(challenge.optionsJson);
        } on AuthCeremonyCancelled {
          return prior; // user dismissed the sheet — no-op, restore prior state
        }
        final outcome = await _rest.finishPasskeyAuthentication(
            challenge.state, assertion);
        return _applyOutcome(outcome, prior);
      });

  /// Create a NEW passkey and account (first-passkey-creates-account). Mirrors
  /// [signInWithPasskey] with the registration ceremony: fetch creation options,
  /// let the platform mint a device-bound credential, then register it at the
  /// gateway (which stores only the public key and mints the account). Routes on
  /// the SAME outcome — typically a [PendingHandle] so the new user claims a
  /// handle before landing in chat. Cancellation restores the prior state.
  Future<void> registerWithPasskey() => _ingress((prior) async {
        final challenge = await _rest.startPasskeyRegistration();
        final String attestation;
        try {
          attestation = await _passkey.register(challenge.optionsJson);
        } on AuthCeremonyCancelled {
          return prior; // user dismissed the sheet — no-op, restore prior state
        }
        final outcome = await _rest.finishPasskeyRegistration(
            challenge.state, attestation);
        return _applyOutcome(outcome, prior);
      });

  /// Add a passkey to the CURRENTLY signed-in account (link-to-existing, #1727).
  /// This is the recovery path for a user who ALREADY has an account and wants a
  /// second passkey (e.g. a new device): routing them through
  /// [registerWithPasskey] would try to mint a SECOND account and — on a handle
  /// collision with their own account — orphan the device credential (the exact
  /// passkey-401 bug this closes).
  ///
  /// It deliberately does NOT go through [_ingress]: that guard REJECTS a live
  /// session (`state.value != null`), which is precisely the precondition here.
  /// It also does NOT touch the logged-in [state] — linking a passkey doesn't
  /// change who is signed in, and flipping to `loading` would bounce the router
  /// to /splash. The caller (Settings) awaits this with its own local spinner and
  /// surfaces the outcome. A sheet dismissal is a silent no-op; a real
  /// authenticator/gateway failure ([PasskeyAlreadyRegistered], [Unauthorized],
  /// [AuthCeremonyFailed]) propagates to the caller and leaves the session
  /// untouched (a failed link must not log the user out).
  ///
  /// Returns `true` when a passkey was linked, `false` when the user dismissed
  /// the system sheet (or a link is already in flight) — so the caller shows a
  /// success confirmation ONLY on a real add, never on a silent cancellation.
  ///
  /// Single-flight is enforced HERE, not by the caller: the same failure mode the
  /// [_ingress] guard documents applies to this ceremony too — a second concurrent
  /// `register` issues a second gateway challenge and the platform authenticator's
  /// start-of-ceremony `cancelCurrentAuthenticatorOperation()` silently cancels the
  /// first sheet (mapped to a no-op), letting the later challenge win. A widget's
  /// local disable-flag only covers one screen instance; the invariant belongs on
  /// the controller, where every passkey ceremony is coordinated. `_addingPasskey`
  /// is checked-and-set synchronously (no await between), so a second call in the
  /// same event-loop turn short-circuits before issuing a challenge.
  bool _addingPasskey = false;
  Future<bool> addPasskeyToCurrentAccount() async {
    if (state.value == null) {
      throw StateError('addPasskeyToCurrentAccount requires a signed-in user');
    }
    if (_addingPasskey) return false; // a link is already in flight — no 2nd sheet
    _addingPasskey = true;
    try {
      final challenge = await _rest.startPasskeyRegistration();
      final String attestation;
      try {
        attestation = await _passkey.register(challenge.optionsJson);
      } on AuthCeremonyCancelled {
        return false; // user dismissed the sheet — no-op, session untouched
      }
      await _rest.addPasskey(challenge.state, attestation);
      return true;
    } finally {
      _addingPasskey = false;
    }
  }

  /// Apply a verified [outcome] from a passkey finish (the gateway's single
  /// identity door): a known identity adopts the tokens and publishes the user;
  /// a new identity parks the [PendingHandle] (router → /claim-handle) and keeps
  /// the [prior] state (first-passkey-creates-account).
  Future<AppUser?> _applyOutcome(IdentityOutcome outcome, AppUser? prior) async {
    switch (outcome) {
      case Authenticated(:final session):
        await _tokens.setTokens(session.tokens);
        return session.user;
      case PendingHandle pending:
        ref.read(pendingHandleProvider.notifier).set(pending);
        return prior;
    }
  }

  /// Complete a new identity's sign-in by claiming a handle. Requires a pending
  /// identity (set by [registerWithPasskey]); on success adopts the tokens,
  /// clears the pending state, and publishes the user (→ chat).
  Future<void> claimHandle(String handle, String displayName) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final pending = ref.read(pendingHandleProvider);
      if (pending == null) {
        throw StateError('claimHandle called with no pending identity');
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
    // Clear any half-finished identity provisioning so a teardown ALWAYS lands in
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

  /// Re-point the app at a different gateway (the #4 picker). JWTs are minted by
  /// and only valid at the gateway that issued them, so a switch is a SESSION
  /// boundary. The ordering is load-bearing (Carnot):
  ///
  ///   1. No-op guard — re-selecting the CURRENT gateway never nukes a live
  ///      session (normalized, so `https://x/` == `https://x`).
  ///   2. Persist FIRST. If the write fails we abort with the session fully
  ///      intact — a failed switch must not strand the user logged-out (Carnot
  ///      F2). Writing the pref does NOT move the live config: [configProvider]
  ///      is cached and only re-reads on invalidate (step 4).
  ///   3. Publish `loading` BEFORE any teardown. This is the fix for the window
  ///      Carnot caught: if we published `data(null)` first (as a plain
  ///      `logout()` does), the router would land on /login against the OLD
  ///      gateway while teardown was still in flight, and a sign-in there would
  ///      mint a token the about-to-switch gateway can't honour. `loading` parks
  ///      the router on /splash, so login is impossible mid-switch.
  ///   4. Tear down (clear tokens + disconnect) → THEN `invalidate` so the live
  ///      config flips only AFTER the old credential is gone. Tokens-before-flip
  ///      is preserved.
  ///   5. `finally` publishes logged-out exactly once, so a teardown error can
  ///      never leave the app bricked on /splash.
  Future<void> switchGateway(String httpBaseUrl) async {
    final next = GatewayConfig.normalized(httpBaseUrl).httpBaseUrl;
    if (next == ref.read(configProvider).httpBaseUrl) return;

    final persisted = await ref
        .read(sharedPreferencesProvider)
        .setString(gatewayBaseUrlPrefKey, next);
    if (!persisted) {
      // Session untouched — surfaced to the picker for an inline error.
      throw const GatewaySwitchFailed('Could not save the server selection.');
    }

    state = const AsyncValue.loading(); // block login (router → /splash)
    try {
      // Tear down by hand (not the bundled _teardownResources) so the swallow is
      // NARROW: clearing the old credentials is security-critical and must NOT be
      // silently absorbed (Carnot) — a clear failure propagates to the picker's
      // error UI. Only the disconnect is best-effort.
      ref.read(pendingHandleProvider.notifier).clear();
      await _tokens.clearTokens(); // security-critical: old credential gone first
      try {
        await ref.read(transportProvider).disconnect(); // best-effort cleanup
      } catch (_) {
        // A disconnect hiccup must NOT surface as "switch failed" — the socket is
        // re-disconnected by the transport rebuild's onDispose below regardless.
      }
    } finally {
      // Flip the live config to the new (already-persisted) gateway BEFORE
      // publishing logged-out — in the `finally` so even a propagating clear
      // failure can't skip it and strand the app on /login against the OLD
      // cached gateway (Carnot, the error-path twin of F1). The config flip is
      // the load-bearing step; the rebuild from invalidate re-disconnects the
      // old transport via its onDispose anyway.
      ref.invalidate(configProvider);
      state = const AsyncValue.data(null); // logged out, now on the new gateway
    }
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

/// Thrown by [AuthController.switchGateway] when the chosen gateway could not be
/// persisted — raised BEFORE any session teardown, so the current session is
/// untouched and the picker can surface an inline error and stay put.
class GatewaySwitchFailed implements Exception {
  final String message;
  const GatewaySwitchFailed(this.message);
  @override
  String toString() => message;
}
