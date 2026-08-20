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

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/config.dart';
import '../../../app/providers.dart';
import '../../../core/auth/token_provider.dart';
import '../../chat/data/chat_rest_api.dart';
import '../../chat/data/transport/chat_transport.dart';
import '../../notifications/application/push_providers.dart';
import '../data/auth_exceptions.dart';
import '../data/cached_user_store.dart';
import '../data/passkey_auth_client.dart';
import '../domain/auth_models.dart';
import '../domain/identity_models.dart';

final authControllerProvider = AsyncNotifierProvider<AuthController, AppUser?>(
  AuthController.new,
);

/// The transient "a new identity has been verified but has not yet claimed a
/// handle" state (first-passkey-creates-account). It lives ALONGSIDE
/// [authControllerProvider]'s
/// `AppUser?` rather than inside it, so the logged-in/out state machine is
/// untouched: a non-null value here (while logged out) is what drives the
/// router to `/claim-handle`. Cleared once the handle is claimed (→ logged in)
/// or the user abandons the flow.
final pendingHandleProvider =
    NotifierProvider<PendingHandleNotifier, PendingHandle?>(
      PendingHandleNotifier.new,
    );

class PendingHandleNotifier extends Notifier<PendingHandle?> {
  @override
  PendingHandle? build() => null;
  void set(PendingHandle pending) => state = pending;
  void clear() => state = null;
}

/// Whether THIS island has suspended the current account (a ban — the gateway's
/// `403 {"detail":"account suspended"}`, surfaced as [AccountSuspended]). Like
/// [pendingHandleProvider] it lives ALONGSIDE the `AppUser?` machine rather than
/// inside it, and drives a dedicated router zone (`/suspended`) — a ban is a
/// terminal-for-this-island state, NOT "logged out, please sign in again"
/// (which loops). It is a SOFT gate: because suspension clears the (dead) tokens
/// like any terminal auth, the suspended screen lets the user DISMISS it — "try
/// again" clears the flag → /login (a re-auth re-flags if still banned, or lands
/// the user in if the ban lifted), "switch island" clears it via a gateway
/// switch. In-memory only: a cold restart re-discovers the ban on the next auth
/// attempt (task #29). The host to display is read from [configProvider], so
/// this stays a bare flag with a single owner for the host.
final suspendedProvider = NotifierProvider<SuspendedNotifier, bool>(
  SuspendedNotifier.new,
);

/// Whether the current user is a moderator on this island — the presentation
/// flag that shows/hides the operator seat (report queue + takedown/ban UI).
/// Derived from the logged-in [AppUser.isModerator]; false when logged out,
/// mid-restore, or on an older gateway that omits the field (fail-closed). This
/// is UI gating ONLY — every operator action is enforced server-side
/// (`ModeratorUser`), so this flag being wrong grants no authority, just a
/// visible-or-hidden door.
final isModeratorProvider = Provider<bool>(
  (ref) => ref.watch(authControllerProvider).value?.isModerator ?? false,
);

class SuspendedNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void flag() => state = true;
  void clear() => state = false;
}

class AuthController extends AsyncNotifier<AppUser?> {
  ChatRestApi get _rest => ref.read(restApiProvider);
  DefaultTokenProvider get _tokens => ref.read(tokenProviderProvider);
  PasskeyAuthClient get _passkey => ref.read(passkeyAuthClientProvider);
  CachedUserStore get _cachedUser => ref.read(cachedUserStoreProvider);

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

  /// Cold-start session restore — offline-first.
  ///
  ///   tokens == null           → logged out (never signed in)
  ///   me() ok                  → authenticated; refresh the cached user
  ///   terminal Unauthorized    → logged out; clear the (dead) tokens + cache
  ///   NetworkUnavailable       → OPTIMISTIC restore from the cached user, IFF
  ///                              tokens are still present at commit time
  ///   any OTHER error          → fail CLOSED (keep tokens, show login)
  ///
  /// The optimistic branch fixes the returning-user-locked-out-offline bug: a
  /// user with valid tokens must be able to open the app and read cached content
  /// when the *network is down*, not be bounced to the login wall.
  ///
  /// Two deliberate safety choices, both from the PR #71 cage-match:
  ///  1. **Fail closed on anything but a reachable-network failure.** Only
  ///     [NetworkUnavailable] (server truly unreachable — DNS/connect/timeout,
  ///     mapped in the REST seam) triggers optimism. A server that ANSWERED with
  ///     an unexpected non-auth error, or any unclassified error, returns null →
  ///     login. "Not [Unauthorized]" is NOT treated as "transient" (that was the
  ///     trust-laundering Carnot/Tesla flagged).
  ///  2. **Commit-time token guard.** We re-read the token AFTER the failed
  ///     `me()` and only publish the cached user if it is STILL present. This
  ///     closes the cold-start race (Tesla): a concurrent terminal signal
  ///     (transport/REST `unauthenticated`) that fired during `me()` clears the
  ///     tokens and flips state to logged-out; without this guard, returning the
  ///     cached user here would clobber that with a resurrected session.
  ///
  /// Session-VALIDITY is not asserted here — it is reconciled by the transport
  /// (`ConnectionState.unauthenticated` → [_becomeUnauthenticated]) and the REST
  /// interceptor once the network can speak. The bounded claim: an optimistically
  /// restored session can DISPLAY cached identity/content, but every
  /// authenticated action fails closed on a terminal 401, and the session is
  /// corrected on the next successful round-trip. (Named tradeoff: profile fields
  /// may be one session stale until the next online `me()`.)
  Future<AppUser?> _restoreSession() async {
    final existing = await _tokens.currentAccessToken();
    if (existing == null) return null; // never logged in
    try {
      final user = await _rest.me();
      await _writeCachedUser(
        user,
      ); // keep the offline cache fresh (best-effort)
      _clearSuspended(); // a successful me() means the ban (if any) lifted
      return user;
    } on AccountSuspended {
      // BAN (403) — a terminal-for-this-island state, distinct from a revoked
      // session. Must be caught BEFORE `on Unauthorized` (its supertype). Clear
      // the dead tokens + all partial auth state like any terminal auth, then
      // flag the suspended zone so the router shows /suspended instead of /login
      // (which would loop: a re-auth 403s again).
      await _tokens.clearTokens();
      await _cachedUser.clear();
      // Clear EVERY partial auth state, symmetric with _settleSuspension (cage-match
      // Carnot): a stale in-memory pending handle during a rebuild-then-ban would
      // otherwise send a soft-gate dismiss to /claim-handle instead of /login (router
      // order: suspended → pendingHandle → login).
      ref.read(pendingHandleProvider.notifier).clear();
      // Flag SYNCHRONOUSLY (post-await, before return) so it lands atomically with
      // build resolving to data(null) — the first non-loading redirect already sees
      // the ban zone, no /login flash (cage-match Tesla). Safe: past build's first
      // await, the window the file already trusts for sibling mutation (the
      // _becomeUnauthenticated teardown clears pendingHandle here too).
      ref.read(suspendedProvider.notifier).flag();
      return null;
    } on Unauthorized {
      await _tokens.clearTokens(); // tokens are genuinely dead
      await _cachedUser.clear();
      return null;
    } on NetworkUnavailable {
      // Server unreachable — restore optimistically from the cached identity,
      // but ONLY if the tokens survived any concurrent terminal signal.
      final cached = _cachedUser.read();
      if (cached == null) return null;
      final stillAuthed = await _tokens.currentAccessToken();
      return stillAuthed == null ? null : cached;
    } catch (_) {
      // The server answered with something we didn't expect (not a clean
      // unreachable-network signal). Fail CLOSED: keep the tokens for a later
      // retry, but do NOT grant an optimistic session on an unknown error.
      return null;
    }
  }

  /// Persist the cached user WITHOUT letting a storage failure break auth. A
  /// failed write is degraded to a CLEAR so the next offline restore can never
  /// pair fresh tokens with a stale/mismatched cached identity (Carnot) — worst
  /// case is "no offline restore", never "wrong identity". Never throws.
  Future<void> _writeCachedUser(AppUser user) async {
    // setString/remove return false on a persistence failure WITHOUT throwing
    // (Carnot, PR #71). The invariant to protect: a storage failure must never
    // leave a cached identity that MISMATCHES the current tokens. So a failed
    // write degrades to a clear; we check BOTH booleans.
    bool sanitized;
    try {
      if (await _cachedUser.write(user)) return; // wrote the correct identity
      sanitized = await _cachedUser
          .clear(); // write failed → erase, don't leave old
    } catch (_) {
      try {
        sanitized = await _cachedUser.clear();
      } catch (_) {
        sanitized = false;
      }
    }
    // Residual (both write AND clear silently failed — a rare platform-storage
    // pathology): a stale cached identity may remain. It is NOT a security hole —
    // the cache is only ever CONSULTED under valid tokens (restore checks tokens
    // first) and only to DISPLAY identity; every authed action still fails closed
    // on a terminal 401. And it SELF-HEALS: the next successful me() overwrites
    // the cache with the correct identity. We surface it via assert so it's never
    // silent in debug, but do not log the user out on a prefs hiccup.
    assert(
      sanitized,
      'CachedUserStore could not persist OR clear — stale identity may '
      'linger until the next successful me() (self-healing, display-only).',
    );
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
    Future<AppUser?> Function(AppUser? prior) ceremony,
  ) async {
    if (state.value != null || state.isLoading) return;
    final prior = state.value;
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => ceremony(prior));
    await _settleSuspension();
  }

  /// Terminal-auth settlement for a ban surfaced by a ceremony guard (the
  /// [_ingress] passkey finish/authenticate, or [claimHandle]) — the sign-in
  /// against a banned account resolves to [AccountSuspended] inside the guard,
  /// leaving `state` an `AsyncError`. This:
  ///   1. clears the dead tokens + cache, like any terminal auth (the invariant
  ///      the [_restoreSession] ban branch already honours — cage-match Carnot:
  ///      flagging without clearing left a stale credential in the reservoir);
  ///   2. RESETS the machine to a clean logged-out `AsyncData(null)` — so a
  ///      soft-gate dismiss ("try again") lands on a CLEAN /login, not the ban
  ///      re-painted as the login screen's inline `AsyncError` (cage-match Tesla:
  ///      a flag-only gate is "the loop wearing a friendlier mask");
  ///   3. flags the suspended zone.
  /// No-op (returns false) when the guard's error is not a ban — a network /
  /// ceremony-cancelled / handle-taken error passes through untouched so the
  /// login/claim screens still show it. Runs OUTSIDE build (post-guard), so the
  /// direct flag set is safe.
  Future<bool> _settleSuspension() async {
    if (state.error is! AccountSuspended) return false;
    // Set EVERY router-relevant piece of state SYNCHRONOUSLY, before any await,
    // so settlement is ATOMIC w.r.t. the router (cage-match Tesla): the first
    // redirect after the ceremony's AsyncError sees (logged-out + suspended) and
    // lands on /suspended directly — never a one-frame /login flash that would
    // paint the ban as the login screen's inline error (that sealed *dismiss*;
    // this seals *arrival*).
    //   - clear pending: a claimHandle ban leaves a live provisioning token, and
    //     the router orders suspended → pendingHandle, so an uncleared pending
    //     would send a soft-gate dismiss to /claim-handle, not /login (cage-match
    //     Carnot + Tesla converged: the reservoir isn't empty while a hidden
    //     state variable still holds usable work);
    //   - reset the machine to clean AsyncData(null) (no lingering ban error);
    //   - flag the suspended zone.
    // Flag BEFORE publishing the clean logged-out state (cage-match Carnot): the
    // router listens to BOTH providers, so if the auth-state notification ran the
    // redirect before `suspended` were true, an intermediate `(loggedOut,
    // suspended=false)` from /claim-handle would hop to /login. Flagging first
    // makes settlement order-INDEPENDENT — whichever notification the router
    // processes first, it already sees `suspended == true`.
    ref.read(pendingHandleProvider.notifier).clear();
    ref.read(suspendedProvider.notifier).flag();
    state = const AsyncValue.data(null);
    // The dead credential/cache drain is routing-irrelevant, so it runs AFTER —
    // the user is already parked on /suspended and can take no authed action.
    //
    // The unpair goes with it: a ban ends the session like any other terminal
    // state, and a row left here is unclearable afterwards. It rides in
    // `_clearCredentialAndUnpair` rather than sitting ahead of the clear, which
    // matters especially here — /suspended is a SOFT gate, so "try again" can
    // reach /login and sign in at any moment, and this path must therefore not
    // hold a window open at all. Best-effort as to the DELETE itself: a banned
    // account's credential may already be rejected, in which case the debt
    // record carries it to the next sign-in.
    await _clearCredentialAndUnpair();
    await _cachedUser.clear();
    return true;
  }

  /// Clear the suspended flag (ban lifted / session ended / gateway switched).
  /// SYNCHRONOUS, matching the sibling `pendingHandleProvider.clear()` it sits
  /// beside in every caller (_teardownResources / switchGateway / success /
  /// restore-success). Every mutation of the suspended flag is now synchronous,
  /// so ordering is by execution order, not event-loop timing: the cold-start
  /// ban flags as the LAST statement before `_restoreSession` returns (no await
  /// after it), and a concurrent terminal signal either fired earlier — clearing
  /// a still-false flag (no-op) — or fires after build resolves, where
  /// `_becomeUnauthenticated`'s `state.value == null && !isLoading` guard
  /// early-returns before it can reach a teardown clear. So the flag always wins.
  void _clearSuspended() => ref.read(suspendedProvider.notifier).clear();

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
      challenge.state,
      assertion,
    );
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
      challenge.state,
      attestation,
    );
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
    if (_addingPasskey)
      return false; // a link is already in flight — no 2nd sheet
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
  Future<AppUser?> _applyOutcome(
    IdentityOutcome outcome,
    AppUser? prior,
  ) async {
    switch (outcome) {
      case Authenticated(:final session):
        await _tokens.setTokens(session.tokens);
        await _writeCachedUser(session.user); // enable offline restore
        _clearSuspended(); // signed in successfully → not suspended here
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
      await _writeCachedUser(session.user); // enable offline restore
      ref.read(pendingHandleProvider.notifier).clear();
      _clearSuspended();
      return session.user;
    });
    // Corpus seal (cage-match Tesla): claimHandle is a THIRD door that can
    // surface a 403 ban (the claimed account/handle is banned) — settle it the
    // same way as _ingress so it routes to /suspended, not a claim-screen error.
    await _settleSuspension();
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
    _clearSuspended(); // symmetric with pendingHandle: a terminal teardown is a
    // THIRD exit (logout / _becomeUnauthenticated / deleteAccount) — an orphan
    // suspended flag would make the next logged-out redirect prefer /suspended
    // over an honest /login (cage-match Tesla). Safe re the cold-start flag: a
    // ban sets state=data(null), so _becomeUnauthenticated's guard early-returns
    // and never reaches this teardown to clobber a just-set flag.
    await _clearCredentialAndUnpair();
    await _cachedUser.clear(); // lifecycle-symmetric with the tokens
    await ref.read(transportProvider).disconnect();
  }

  /// Destroy this session's credential and hand the device pairing over to the
  /// debt record. THE SINGLE DOOR for both — every session-ending path uses it.
  ///
  /// The two statements are adjacent awaits on the same token store with nothing
  /// between them, and that adjacency is the property, not a coincidence. An
  /// earlier version awaited `DELETE /v1/devices` ahead of the clear, because
  /// that call is authenticated and needs a live credential; but this class
  /// already documents (Carnot R3-B) why nothing slow may sit there — `logout`
  /// publishes logged-out BEFORE awaiting, so a re-sign-in inside the window
  /// writes fresh tokens the trailing clear then stomps, leaving a logged-in-
  /// but-tokenless app. Fencing that window with a token comparison only moved
  /// the problem: an ordinary 401 refresh changes the access token too, so the
  /// fence mis-read a live session as a reborn one and abandoned the whole
  /// teardown — the user parked on /login still holding a working credential,
  /// which the next cold start restored.
  ///
  /// So the round trip is gone from this path entirely. [DeviceRegistrar.unpair]
  /// returns without awaiting anything: it records a durable debt and fires a
  /// best-effort DELETE out of band, carrying [credential] BY VALUE so it does
  /// not need the store we just emptied. Nothing is racing for an instant, so
  /// there is no window left to guard — and the offline-sign-out residual the
  /// old comment named as an accepted tradeoff closes on the way past.
  ///
  /// Called from THREE places. `_teardownResources` covers logout, the signal-
  /// driven teardown and account deletion; [switchGateway] and
  /// [_settleSuspension] each end a session without going through it.
  /// [_restoreSession] also clears tokens and is deliberately NOT a caller —
  /// nothing has registered yet in that process, so there is no debt to record.
  /// ORDER AND ISOLATION, and neither alone is enough — both orderings have a
  /// hole and the `try` is what closes the remaining one (cage-match round 3):
  ///
  ///   - clear-then-unpair loses the unpair whenever the clear THROWS, and in
  ///     [switchGateway] a throwing clear is an anticipated, documented outcome
  ///     ("a clear failure propagates to the picker's error UI"). The island
  ///     being left would keep a live routable row forever — the exact residual
  ///     this whole change exists to close.
  ///   - unpair-then-clear loses the CLEAR whenever building the registrar
  ///     throws, leaving a live credential on a logged-out app. Strictly worse —
  ///     and reachable: this change widened that provider graph
  ///     (`deviceRegistrarProvider` → `pendingUnregisterStoreProvider` →
  ///     `sharedPreferencesProvider`, which throws by design when unoverridden),
  ///     and two test fixtures started throwing on exactly that path.
  ///
  /// So the debt is recorded FIRST — it is a local write, not a round trip, so
  /// it opens no window — inside a `try` that makes the best-effort half
  /// structurally unable to skip the security-critical one. The clear then runs
  /// unconditionally, whatever the pairing did.
  Future<void> _clearCredentialAndUnpair() async {
    final credential = await _tokens.currentAccessToken();
    try {
      ref.read(deviceRegistrarProvider)?.unpair(credential: credential);
    } catch (e) {
      // Reach degrades; the session still ends. Never the other way round.
      debugPrint('AuthController: could not unpair the device: $e');
    }
    await _tokens.clearTokens();
  }

  /// Explicit, user-initiated logout.
  Future<void> logout() async {
    state = const AsyncValue.data(null);
    await _teardownResources();
  }

  /// Re-fetch `/v1/me` and republish the user WITHOUT a full session restore.
  ///
  /// Reconciles a stale DERIVED flag against the server — specifically a
  /// moderator flag that reads true locally while the island has since revoked
  /// it. When an operator endpoint returns [Forbidden] (authZ, not authN — see
  /// the REST seam's A3 taxonomy), the operator controller calls this so a fresh
  /// `me()` flips [isModeratorProvider] and the operator UI gates itself off.
  ///
  /// Non-destructive by contract: this is NOT a logout path. A [Forbidden], a
  /// network blip, or any transient error leaves the current session untouched —
  /// only a clean `me()` republishes, and only a genuine ban ([AccountSuspended])
  /// routes to the normal terminal-auth teardown. Contrast [logout] and the
  /// `_becomeUnauthenticated` reconcile signals, which DO end the session.
  Future<void> refreshUser() async {
    final startUserId = state.value?.userId;
    if (startUserId == null) return; // not authenticated — nothing to refresh
    try {
      final user = await _rest.me();
      // Commit-time SESSION fence (extends _restoreSession's token guard, PR #71
      // Tesla): between this refresh starting and here, the session can change out
      // from under us — a concurrent terminal signal clears tokens, OR a logout +
      // sign-in as a DIFFERENT user lands. Two DURABLE mutators must be fenced, not
      // just the publish: the offline CACHE and `state`. The fence is TOTAL —
      // tokens · userId · (cache) · publish (cage-match Tesla round 5): fencing
      // only `state` still let `_writeCachedUser(A)` land while tokens were already
      // B's, so a later offline restore would pair B's tokens with A's face (the
      // PR #71 mismatch class). Fence BEFORE the cache write (shrinking the window
      // to the negligible local write vs the whole me() network call), then a final
      // SYNCHRONOUS userId re-check immediately precedes the synchronous publish so
      // no teardown can interleave (a teardown nulls state.value → userId mismatch).
      if (await _tokens.currentAccessToken() == null) return;
      if (state.value?.userId != startUserId) return;
      await _writeCachedUser(
        user,
      ); // keep the offline cache fresh (best-effort)
      if (state.value?.userId != startUserId)
        return; // re-fence after the write
      state = AsyncData(user);
    } on AccountSuspended catch (e, st) {
      // A ban surfaced during the refresh — this IS terminal, but it is a BAN,
      // not a revoked session. Route it through the SAME single suspended-
      // settlement door as sign-in/restore (`_settleSuspension`), NOT the generic
      // `_becomeUnauthenticated` teardown — the latter lands on /login, which
      // 403-loops (a re-auth attempt re-bans). `_settleSuspension` reads
      // `state.error`, so surface the ban there first, then delegate.
      state = AsyncError(e, st);
      await _settleSuspension();
    } on Unauthorized {
      // Terminal authN during the refresh (a 401 that survived the interceptor's
      // refresh-and-retry) — the session is genuinely dead. Tear it down rather
      // than leaving a dead token published in UI state (cage-match Carnot round
      // 3). Idempotent with the interceptor's onUnauthenticated event path, so
      // double-firing is safe; being explicit here makes refreshUser self-
      // contained instead of relying on that event having already fired. (Caught
      // AFTER AccountSuspended, its subtype, so a ban still routes to /suspended.)
      _becomeUnauthenticated();
    } catch (_) {
      // Forbidden / NetworkUnavailable / any transient — leave the session as-is.
      // The caller already surfaced the originating action's failure.
    }
  }

  /// Save a profile change (handle and/or display name) through the SINGLE
  /// authed-mutation door, so the `PATCH /v1/me` inherits the same terminal-auth
  /// taxonomy AND the same total commit-time fence as [refreshUser] (cage-match
  /// #114 confirming round, Carnot + Wu). Splitting the mutation across the screen
  /// (a generic `catch`) and a userId-only [applyProfileUpdate] leaked two ways:
  /// a terminal 401 was swallowed as a snackbar (dead session left in the UI), and
  /// a same-identity logout→login mid-flight could pair one session's tokens with
  /// another's cached face (the PR #71 class). Both are dissolved by owning the
  /// whole thing here.
  ///
  /// The caller (settings screen) keeps ONLY the user-actionable outcomes —
  /// [HandleTaken] / [HandleChangeOnCooldown] are rethrown for inline field errors.
  /// Every terminal/authZ outcome is settled HERE and can never be swallowed:
  ///   - [AccountSuspended] (ban mid-edit) → the single suspended door.
  ///   - [Unauthorized] (a 401 that survived the interceptor's refresh) →
  ///     [_becomeUnauthenticated] teardown.
  /// Returns the updated [AppUser] on success, or null when a terminal signal was
  /// settled (the router then redirects — the caller must NOT pop/toast on null).
  Future<AppUser?> saveProfile({String? handle, String? displayName}) async {
    final startUserId = state.value?.userId;
    if (startUserId == null) return null; // not authenticated
    try {
      final user = await _rest.updateProfile(
        handle: handle,
        displayName: displayName,
      );
      // Total commit-time fence, identical to refreshUser (PR #71 / Tesla R5):
      // token · userId · cache · publish — so a logout, or a logout+sign-in as
      // the SAME identity, mid-flight can never pair one session's tokens with
      // another's cached face. Fence BEFORE the cache write, then re-fence
      // synchronously immediately before the publish.
      if (await _tokens.currentAccessToken() == null) return null;
      if (state.value?.userId != startUserId) return null;
      await _writeCachedUser(user);
      if (state.value?.userId != startUserId) return null;
      state = AsyncData(user);
      return user;
    } on AccountSuspended catch (e, st) {
      // Ban mid-edit — route through the single suspended door (NOT the generic
      // teardown, which lands on /login and 403-loops on re-auth). Surface the
      // ban in state first (_settleSuspension reads state.error), then delegate.
      state = AsyncError(e, st);
      await _settleSuspension();
      return null;
    } on Unauthorized {
      // Terminal authN (a 401 that survived the interceptor's refresh-and-retry)
      // — tear the dead session down rather than leave it published in UI state.
      // Idempotent with the interceptor's onUnauthenticated path.
      _becomeUnauthenticated();
      return null;
    }
    // HandleTaken / HandleChangeOnCooldown (user-actionable) and any other error
    // propagate to the screen — deliberately NOT caught here.
  }

  /// Settle a KNOWN ban directly, WITHOUT a confirming `/v1/me` round-trip.
  ///
  /// Use when a call already returned [AccountSuspended] — that response IS the
  /// terminal ban signal, so re-fetching `/me` to "confirm" it only adds a second
  /// network hop that can fail transiently and strand a banned user with no
  /// routing (cage-match Carnot + Tesla round 4). Routes through the single
  /// suspended door (`_settleSuspension` → `/suspended`), same as sign-in/restore.
  /// Idempotent: if suspension is already settled it is a harmless re-flag.
  Future<void> settleBan() async {
    state = AsyncError(const AccountSuspended(), StackTrace.current);
    await _settleSuspension();
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
      _clearSuspended(); // a different island may not have banned this account
      // Security-critical: old credential gone first. The unpair rides inside,
      // and must stay BEFORE the `invalidate(configProvider)` in the `finally` —
      // that invalidate rebuilds both the REST client and the registrar against
      // the NEW island, so a debt recorded after it would be keyed to the island
      // the user switched TO and its DELETE addressed there. Switching islands
      // is an ordinary thing to do, and without this the island being left keeps
      // a live, routable token for an account no longer signed in on it.
      await _clearCredentialAndUnpair();
      await _cachedUser.clear(); // old identity gone with the old credential
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
