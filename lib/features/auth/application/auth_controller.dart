/// The authentication state machine — the app-layer owner of "who is logged in".
///
/// It exposes the current [AppUser] (null = logged out) and the sign-in,
/// sign-out and switch transitions. Every change to what the app shows about
/// the session runs as one transition in a serial lane, checked against the
/// session vault's lease, so an outcome that belongs to a session that has
/// since ended can't end, revive or show the one that replaced it (design 27).
///
/// What the router reads is one value, [SessionPicture]: the user, a pending
/// handle and the suspended flag, written together by a transition.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/boot_telemetry.dart';

import '../../../app/config.dart';
import '../../../app/providers.dart';
import '../../../core/auth/token_provider.dart';
import '../../../services/session_vault.dart';
import '../../chat/data/chat_rest_api.dart';
import '../data/owed_handle_store.dart';
import '../../notifications/application/push_providers.dart';
import '../data/auth_exceptions.dart';
import '../data/cached_user_store.dart';
import '../data/passkey_auth_client.dart';
import '../domain/auth_models.dart';
import '../domain/identity_models.dart';

final authControllerProvider = AsyncNotifierProvider<AuthController, AppUser?>(
  AuthController.new,
);

/// Everything the router reads about the session, written as one value so it
/// never sees half of a change.
final class SessionPicture {
  final AsyncValue<AppUser?> auth;

  /// A new identity verified but without a handle yet: drives `/claim-handle`
  /// while logged out.
  final PendingHandle? pending;

  /// This island has suspended the account: drives `/suspended`.
  final bool suspended;

  const SessionPicture(this.auth, {this.pending, this.suspended = false});

  static const resolving = SessionPicture(AsyncValue<AppUser?>.loading());
  static const signedOut = SessionPicture(AsyncValue<AppUser?>.data(null));
}

final sessionPictureProvider =
    NotifierProvider<SessionPictureNotifier, SessionPicture>(
      SessionPictureNotifier.new,
    );

/// Written only by [AuthController]'s transitions.
class SessionPictureNotifier extends Notifier<SessionPicture> {
  @override
  SessionPicture build() => SessionPicture.resolving;

  void _show(SessionPicture picture) => state = picture;
}

/// The pending handle in the current [SessionPicture].
final pendingHandleProvider = Provider<PendingHandle?>(
  (ref) => ref.watch(sessionPictureProvider).pending,
);

/// Whether this island has suspended the current account, in the current
/// [SessionPicture]. A soft gate: "try again" ([AuthController.dismissSuspension])
/// returns to `/login`, and a switch clears it. In memory only: a cold start
/// finds the ban again on its first authed call.
final suspendedProvider = Provider<bool>(
  (ref) => ref.watch(sessionPictureProvider).suspended,
);

/// The handles owed on this device (see [OwedHandles]): a sign-up's draft and
/// accounts' debts. Read by the router: while the signed-in account owes one,
/// it is held on `/choose-handle`.
final owedHandleProvider = NotifierProvider<OwedHandleNotifier, OwedHandles>(
  OwedHandleNotifier.new,
);

class OwedHandleNotifier extends Notifier<OwedHandles> {
  /// Fail-open like the passkey hint: no prefs (a test container) means the
  /// record lives in memory only, and it can never fail a sign-in.
  OwedHandleStore? get _store {
    try {
      return OwedHandleStore(ref.read(sharedPreferencesProvider));
    } catch (_) {
      return null;
    }
  }

  @override
  OwedHandles build() => _store?.read() ?? OwedHandles.empty;

  Future<void> _publish(OwedHandles next) async {
    state = next;
    // A write that THROWS must not fail a sign-in either. `bindDraft` runs
    // after `register/finish` has made the account and before the session is
    // adopted, so an escaping prefs exception aborted a registration the
    // island had already committed (Carnot, cage-match #440 round 3). The
    // router reads [state], so the cost of a lost write is at most being asked
    // again on the next launch.
    try {
      await _store?.write(next);
    } catch (_) {}
  }

  /// The sign-up in progress on this device. The ceremony writes and clears
  /// ONLY this, so it can never reach a debt an account owes.
  Future<void> draft(OwedHandle owed) => _publish(
    state.withDraft(
      OwedHandle(handle: owed.handle, displayName: owed.displayName),
    ),
  );

  Future<void> clearDraft() => _publish(state.withDraft(null));

  /// The ceremony made [userId]: its draft becomes that account's debt.
  Future<void> bindDraft(String userId) {
    final draft = state.draft;
    if (draft == null) return Future.value();
    return _publish(state.withDraft(null).withDebt(userId, draft));
  }

  /// [userId] owes [owed] (a handle chosen on `/choose-handle`).
  Future<void> owe(String userId, OwedHandle owed) =>
      _publish(state.withDebt(userId, owed));

  /// The island has [userId]'s handle.
  Future<void> paid(String userId) => _publish(state.withDebt(userId, null));

  /// Remember why the island refused [userId]'s debt, for the screen. Not
  /// persisted.
  void refused(String userId, Object failure) {
    final debt = state.forAccount(userId);
    if (debt != null) state = state.withDebt(userId, debt.refusedWith(failure));
  }
}

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

/// A sign-in attempt: its identity, the lease it began under, and the pending
/// handle it began with.
typedef _Attempt = ({Object id, int lease, PendingHandle? pending});

class AuthController extends AsyncNotifier<AppUser?> {
  ChatRestApi get _rest => ref.read(restApiProvider);
  DefaultTokenProvider get _tokens => ref.read(tokenProviderProvider);
  SessionVault get _vault => _tokens.vault;
  PasskeyAuthClient get _passkey => ref.read(passkeyAuthClientProvider);
  CachedUserStore get _cachedUser => ref.read(cachedUserStoreProvider);

  /// Every transition queues here, behind the ones before it.
  Future<void> _lane = Future<void>.value();

  /// The sign-in attempt that may still commit, or null. A new attempt can
  /// start only while there is none and nobody is signed in.
  Object? _attempt;

  Future<T> _transition<T>(Future<T> Function() body) {
    final run = _lane.then((_) => body());
    _lane = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// Writes [picture] if [lease] is still the vault's: the check and the
  /// write are one synchronous run, so nothing can end the session between
  /// them. Returns whether it was written.
  bool _show(int lease, SessionPicture picture) {
    if (_vault.lease != lease) return false;
    // Riverpod carries the previous value under an error or loading state;
    // a picture with no user must not leave the last one readable.
    if (picture.auth.value == null && !picture.auth.hasValue) {
      state = const AsyncValue.data(null);
    }
    state = picture.auth;
    ref.read(sessionPictureProvider.notifier)._show(picture);
    return true;
  }

  /// Remember that a passkey ceremony succeeded for the ACTIVE island, so the
  /// login screen can lead with sign-in next time.
  ///
  /// CANNOT FAIL THE CEREMONY, and the catch is the whole point rather than
  /// laziness. This sits on the critical auth path purely to record which BUTTON
  /// to emphasise next launch — a cosmetic hint. The first cut of it had no
  /// guard, and a container without a SharedPreferences override made
  /// `passkeyHintStoreProvider` throw, which propagated out of
  /// `signInWithPasskey` and turned a SUCCESSFUL sign-in into a failed one. A
  /// decoration was able to break authentication.
  ///
  /// So it fails OPEN, which is the correct direction for weak-signal capture
  /// (an irreversible mutation would fail closed; this is the opposite kind of
  /// write). The cost of a lost hint is a de-emphasised — never absent — sign-in
  /// affordance, which is the same safe state a fresh install is already in.
  Future<void> _markPasskeySeen() async {
    try {
      await ref
          .read(passkeyHintStoreProvider)
          .markSeen(ref.read(configProvider).httpBaseUrl);
    } catch (_) {
      // Deliberately swallowed — see above. Never let this reach the ceremony.
    }
  }

  @override
  Future<AppUser?> build() async {
    // The one end nobody in the app asked for: the island rejected a refresh.
    final sub = _vault.ended.listen(
      (e) => _endSession(e.lease, () async => e.ended),
    );
    ref.onDispose(sub.cancel);

    await _restore();
    // A restore whose session ended meanwhile writes nothing; never leave
    // the router parked on the splash.
    final notifier = ref.read(sessionPictureProvider.notifier);
    if (ref.read(sessionPictureProvider).auth.isLoading) {
      notifier._show(SessionPicture.signedOut);
    }
    // Read at return, not taken from the restore: a transition that ran
    // meanwhile (a rejected refresh) has already written its picture.
    final user = ref.read(sessionPictureProvider).auth.value;
    ref.read(bootTelemetryProvider).authResolved(signedIn: user != null);
    return user;
  }

  /// Cold-start restore, offline-first. The network call runs outside the
  /// lane; its result commits through it.
  ///
  ///   no session            → logged out
  ///   me() ok               → signed in; the cached user refreshed
  ///   a 401 on the session  → that session ended, logged out
  ///   a ban on the session  → that session ended, suspended
  ///   NetworkUnavailable    → the cached user, while the session stands
  ///   anything else         → fail closed: logged out, the session kept
  Future<void> _restore() async {
    final held = await _tokens.current();
    final notifier = ref.read(sessionPictureProvider.notifier);
    if (held == null) {
      notifier._show(SessionPicture.signedOut);
      return;
    }
    AppUser? fresh;
    Object? failure;
    try {
      fresh = await _rest.me();
    } catch (e) {
      failure = e;
    }
    await _transition(() async {
      // An end that ran meanwhile has written its own picture.
      if (_vault.lease != held.lease) return;
      final (picture, lease) = await _restored(fresh, failure, held.lease);
      if (_vault.lease == lease) notifier._show(picture);
    });
  }

  /// The restored picture, and the lease it is for: the session's own, or
  /// the one its end advanced to.
  Future<(SessionPicture, int)> _restored(
    AppUser? fresh,
    Object? failure,
    int lease,
  ) async {
    if (fresh != null) {
      await _writeCachedUser(fresh);
      return (SessionPicture(AsyncValue.data(fresh)), lease);
    }
    switch (failure) {
      case SessionSuspended(:final presented):
        final gone = await _vault.endIfLease(presented.lease);
        final after = _vault.lease;
        await _cachedUser.clear();
        return (
          gone == null
              ? SessionPicture.signedOut
              : const SessionPicture(AsyncValue.data(null), suspended: true),
          after,
        );
      case SessionUnauthorized(:final presented):
        await _vault.endIf(presented);
        final after = _vault.lease;
        await _cachedUser.clear();
        return (SessionPicture.signedOut, after);
      case NetworkUnavailable():
        final cached = _cachedUser.read();
        return (
          cached == null
              ? SessionPicture.signedOut
              : SessionPicture(AsyncValue.data(cached)),
          lease,
        );
      default:
        return (SessionPicture.signedOut, lease);
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

  // ---- sign-in attempts ----------------------------------------------------

  /// Starts an attempt, or returns null when one can't start: someone is
  /// signed in, or another attempt is running. A tap during a transition
  /// queues behind it and is judged when it runs.
  Future<_Attempt?> _begin({bool needsPending = false}) => _transition(() async {
    final now = ref.read(sessionPictureProvider);
    if (state.value != null || _attempt != null) return null;
    if (needsPending && now.pending == null) return null;
    final id = Object();
    _attempt = id;
    final lease = _vault.lease;
    _show(
      lease,
      SessionPicture(const AsyncValue.loading(), pending: now.pending),
    );
    return (id: id, lease: lease, pending: now.pending);
  });

  /// Runs a sign-in ceremony as an attempt. The ceremony's network calls and
  /// authenticator sheet run outside the lane; what it produced commits as
  /// one transition. It returns null when the person dismissed the sheet.
  Future<void> _ingress(
    Future<IdentityOutcome?> Function(PendingHandle? pending) ceremony, {
    bool needsPending = false,
    bool paysOwedHandle = false,
  }) async {
    final attempt = await _begin(needsPending: needsPending);
    if (attempt == null) return;
    IdentityOutcome? outcome;
    Object? error;
    StackTrace? trace;
    try {
      outcome = await ceremony(attempt.pending);
    } catch (e, st) {
      error = e;
      trace = st;
    }
    final owing = await _transition(
      () => _commit(attempt, outcome, error, trace, paysOwedHandle),
    );
    if (owing != null) await _payOwedHandle(attempt, owing);
  }

  /// Commits an attempt's result. Every path consumes the attempt, except a
  /// sign-up that still owes its handle, which keeps it until the pay
  /// commits. Returns that sign-up's user and lease.
  Future<({AppUser user, int lease})?> _commit(
    _Attempt attempt,
    IdentityOutcome? outcome,
    Object? error,
    StackTrace? trace,
    bool paysOwedHandle,
  ) async {
    // Retired by an end or a switch that ran first: nothing to commit.
    if (!identical(_attempt, attempt.id)) return null;
    var keep = false;
    try {
      if (error != null) {
        _show(
          attempt.lease,
          error is AccountSuspended
              ? const SessionPicture(AsyncValue.data(null), suspended: true)
              : SessionPicture(
                  AsyncValue.error(error, trace ?? StackTrace.current),
                  pending: attempt.pending,
                ),
        );
        return null;
      }
      switch (outcome) {
        case null:
          _show(
            attempt.lease,
            SessionPicture(
              const AsyncValue.data(null),
              pending: attempt.pending,
            ),
          );
          return null;
        case PendingHandle pending:
          _show(
            attempt.lease,
            SessionPicture(const AsyncValue.data(null), pending: pending),
          );
          return null;
        case Authenticated(:final session):
          final int lease;
          try {
            lease = await _vault.adopt(
              _tokens.island,
              session.tokens,
              since: attempt.lease,
            );
          } on SessionSuperseded {
            // Whoever moved the lease has written their own picture.
            return null;
          }
          await _writeCachedUser(session.user);
          final owes =
              paysOwedHandle &&
              ref.read(owedHandleProvider).forAccount(session.user.userId) !=
                  null;
          if (owes) {
            keep = true;
            return (user: session.user, lease: lease);
          }
          _show(lease, SessionPicture(AsyncValue.data(session.user)));
          return null;
      }
    } catch (e, st) {
      // Never leave an attempt showing `loading`: show what went wrong.
      _show(
        _vault.lease,
        SessionPicture(AsyncValue.error(e, st), pending: attempt.pending),
      );
      return null;
    } finally {
      if (!keep && identical(_attempt, attempt.id)) _attempt = null;
    }
  }

  /// Sign in with an EXISTING passkey (WebAuthn). The ingress is a gateway
  /// challenge + an on-device authenticator assertion: fetch the request
  /// options, let the platform sign the challenge with a discoverable credential
  /// (usernameless), then redeem the assertion and route on the outcome. A user
  /// dismissal of the system sheet restores the prior state silently (no error
  /// banner). A "no passkey on this device" error is a real [AuthCeremonyFailed]
  /// — surfaced, not swallowed — so the UI can nudge toward [registerWithPasskey].
  Future<void> signInWithPasskey() => _ingress((_) async {
    final challenge = await _rest.startPasskeyAuthentication();
    final String assertion;
    try {
      assertion = await _passkey.authenticate(challenge.optionsJson);
    } on AuthCeremonyCancelled {
      return null;
    }
    // A completed ceremony PROVES a usable passkey is on this device, so record
    // it BEFORE the server round-trip: if the gateway call then fails, the
    // credential still exists and the login screen should still lead with sign-in.
    await _markPasskeySeen();
    return _rest.finishPasskeyAuthentication(challenge.state, assertion);
  });

  /// Create a NEW passkey and account (first-passkey-creates-account). Mirrors
  /// [signInWithPasskey] with the registration ceremony: fetch creation options,
  /// let the platform mint a device-bound credential, then register it at the
  /// gateway (which stores only the public key and mints the account).
  /// Cancellation restores the prior state.
  ///
  /// HANDLE FIRST. The island answers with a live session under an
  /// auto-assigned `aiko-…` handle, so the user picks [handle] BEFORE the
  /// ceremony: it labels the passkey in their password manager, and is applied
  /// with `PATCH /v1/me` the moment the account exists. An [OwedHandle] record
  /// carries it across a kill in between; until it is paid the router holds the
  /// account on `/choose-handle`, never in chat.
  ///
  /// The island is asked FIRST, because the ceremony can't be taken back: the
  /// phone saves the passkey before `register/finish` answers, so a refusal
  /// there leaves a credential the island will never accept. Only an explicit
  /// "no" stops here, and it raises the same [RegistrationClosed] the island
  /// would have, so the login screen has one path for both.
  Future<void> registerWithPasskey({
    required String handle,
    required String displayName,
  }) => _ingress(paysOwedHandle: true, (_) async {
    if (await _rest.passkeyCreatesAccounts() == false) {
      throw const RegistrationClosed();
    }
    final owed = ref.read(owedHandleProvider.notifier);
    // EVERYTHING the ceremony writes or clears is this device's DRAFT, never an
    // account's debt (see [OwedHandles]).
    final challenge = await _rest.startPasskeyRegistration(name: handle);
    // Written BEFORE the ceremony, which can't be taken back: if the app dies
    // after the island makes the account, this is how the next launch knows a
    // handle is still owed.
    await owed.draft(OwedHandle(handle: handle, displayName: displayName));
    final String attestation;
    try {
      attestation = await _passkey.register(challenge.optionsJson);
    } on AuthCeremonyCancelled {
      await owed.clearDraft();
      return null;
    } catch (_) {
      // No credential reached the island, so no account can exist.
      await owed.clearDraft();
      rethrow;
    }
    await _markPasskeySeen();
    // The draft is NOT cleared if this throws: a reply lost after the island
    // made the account looks exactly like a refusal from here. A draft never
    // gates anyone; it pre-fills the next signed-out sign-up.
    final outcome = await _rest.finishPasskeyRegistration(
      challenge.state,
      attestation,
    );
    switch (outcome) {
      case Authenticated(:final session):
        // Bound before the session is adopted, so a kill from here on still
        // lands the next launch on /choose-handle.
        await owed.bindDraft(session.user.userId);
      case PendingHandle():
        // An island that still asks for the handle itself: its claim screen
        // does, so this app owes nothing of its own.
        await owed.clearDraft();
    }
    return outcome;
  });

  /// Apply the handle a new account chose before its passkey existed, then
  /// commit the attempt. The network call runs outside the lane. A refusal
  /// (taken, no network) keeps the debt: the router holds the account on
  /// `/choose-handle`, which shows why. A terminal answer ends the session
  /// through its own door.
  Future<void> _payOwedHandle(
    _Attempt attempt,
    ({AppUser user, int lease}) signedIn,
  ) async {
    final owedNotifier = ref.read(owedHandleProvider.notifier);
    final owed = ref.read(owedHandleProvider).forAccount(signedIn.user.userId);
    var shown = signedIn.user;
    Unauthorized? terminal;
    if (owed != null) {
      try {
        shown = await _rest.updateProfile(
          handle: owed.handle,
          displayName: owed.displayName,
        );
        await owedNotifier.paid(signedIn.user.userId);
      } on Unauthorized catch (e) {
        terminal = e;
      } catch (e) {
        owedNotifier.refused(signedIn.user.userId, e);
      }
    }
    await _transition(() async {
      if (!identical(_attempt, attempt.id)) return;
      _attempt = null;
      if (!identical(shown, signedIn.user)) await _writeCachedUser(shown);
      _show(signedIn.lease, SessionPicture(AsyncValue.data(shown)));
    });
    if (terminal != null) await _settleTerminal(terminal);
  }

  /// Complete a new identity's sign-in by claiming a handle, from
  /// `/claim-handle`. Requires the pending identity in the picture.
  Future<void> claimHandle(String handle, String displayName) =>
      _ingress(needsPending: true, (pending) async {
        if (pending == null) {
          throw StateError('claimHandle called with no pending identity');
        }
        final session = await _rest.claimHandle(
          provisioningToken: pending.provisioningToken,
          handle: handle,
          displayName: displayName,
        );
        return Authenticated(session);
      });

  /// Leave `/claim-handle` without claiming: the pending identity is dropped.
  Future<void> abandonPendingHandle() => _transition(() async {
    if (_attempt != null) return; // a claim is in flight
    final now = ref.read(sessionPictureProvider);
    _show(_vault.lease, SessionPicture(now.auth, suspended: now.suspended));
  });

  /// "Try signing in again" from `/suspended`: back to `/login`. A re-auth
  /// re-flags it if the ban still stands.
  Future<void> dismissSuspension() => _transition(() async {
    final now = ref.read(sessionPictureProvider);
    _show(_vault.lease, SessionPicture(now.auth, pending: now.pending));
  });

  /// Pay the owed handle from `/choose-handle`, signed in: after the island
  /// refused the first choice, after a kill mid-sign-up, or for an account the
  /// island still reports as auto-handled ([AppUser.handleAuto]). Goes through
  /// [saveProfile], the same door as the Settings edit. [HandleTaken] and
  /// [HandleChangeOnCooldown] propagate for the screen to show inline.
  Future<AppUser?> chooseHandle(String handle, String displayName) async {
    final userId = state.value?.userId;
    if (userId == null) return null;
    final owed = ref.read(owedHandleProvider.notifier);
    await owed.owe(
      userId,
      OwedHandle(handle: handle, displayName: displayName),
    );
    final updated = await saveProfile(handle: handle, displayName: displayName);
    if (updated != null) await owed.paid(userId);
    return updated;
  }

  /// Add a passkey to the CURRENTLY signed-in account (link-to-existing).
  /// This is the recovery path for a user who ALREADY has an account and wants a
  /// second passkey (e.g. a new device): routing them through
  /// [registerWithPasskey] would try to mint a SECOND account.
  ///
  /// It does NOT change who is signed in, so it writes no session state and
  /// runs outside the lane. The caller (Settings) shows its own spinner. A sheet
  /// dismissal is a silent no-op; a real authenticator/gateway failure
  /// propagates to the caller and leaves the session untouched.
  ///
  /// Returns `true` when a passkey was linked, `false` when the user dismissed
  /// the system sheet (or a link is already in flight).
  ///
  /// Single-flight is enforced HERE: a second concurrent `register` issues a
  /// second gateway challenge, and the platform authenticator's
  /// start-of-ceremony cancel silently drops the first sheet. `_addingPasskey`
  /// is checked-and-set synchronously, so a second call in the same event-loop
  /// turn short-circuits before issuing a challenge.
  bool _addingPasskey = false;
  Future<bool> addPasskeyToCurrentAccount() async {
    if (state.value == null) {
      throw StateError('addPasskeyToCurrentAccount requires a signed-in user');
    }
    if (_addingPasskey) return false; // a link is already in flight
    _addingPasskey = true;
    try {
      // Labelled with the handle, so this passkey is recognisably theirs in the
      // password manager. Islands that predate the label ignore it.
      final challenge = await _rest.startPasskeyRegistration(
        name: state.value?.username,
      );
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

  // ---- signed-in calls -----------------------------------------------------

  /// Re-fetch `/v1/me` and republish the user, for the session that asked.
  ///
  /// Not a logout path: a [Forbidden], a network blip or any transient error
  /// leaves the session as it is. Only a terminal answer for this session (a
  /// 401 or a ban) ends it.
  Future<void> refreshUser() async {
    if (state.value == null) return;
    final lease = _vault.lease;
    final AppUser user;
    try {
      user = await _rest.me();
    } catch (e) {
      await _settleTerminal(e);
      return;
    }
    await _transition(() async {
      if (_vault.lease != lease) return;
      await _writeCachedUser(user);
      _show(lease, SessionPicture(AsyncValue.data(user)));
    });
  }

  /// Save a profile change (handle and/or display name) for the session that
  /// asked. Returns the updated [AppUser], or null when the session has ended
  /// (a terminal answer settled here, or an end that ran meanwhile): the
  /// router then redirects, so the caller must NOT pop or toast on null.
  /// [HandleTaken], [HandleChangeOnCooldown] and other errors propagate to the
  /// screen.
  Future<AppUser?> saveProfile({String? handle, String? displayName}) async {
    if (state.value == null) return null;
    final lease = _vault.lease;
    final AppUser user;
    try {
      user = await _rest.updateProfile(
        handle: handle,
        displayName: displayName,
      );
    } catch (e) {
      if (await _settleTerminal(e)) return null;
      rethrow;
    }
    return _transition(() async {
      if (_vault.lease != lease) return null;
      await _writeCachedUser(user);
      return _show(lease, SessionPicture(AsyncValue.data(user))) ? user : null;
    });
  }

  /// Settles a terminal answer to a signed-in call. Returns whether [error]
  /// was one. An [Unauthorized] that names no session ends nothing.
  Future<bool> _settleTerminal(Object error) async {
    switch (error) {
      case SessionSuspended():
        await settleBan(error);
        return true;
      case SessionUnauthorized(:final presented):
        await _endSession(presented.lease, () => _vault.endIf(presented));
        return true;
      case Unauthorized():
        return true;
      default:
        return false;
    }
  }

  /// Settle a ban learned on a signed-in call, without a confirming `/v1/me`.
  /// A ban is about the account, so it ends the session it was learned on
  /// while that session's lease is current, even after a refresh; a ban for a
  /// session already gone ends and flags nothing.
  Future<void> settleBan(AccountSuspended ban) async {
    if (ban is! SessionSuspended) return;
    final lease = ban.presented.lease;
    await _endSession(lease, () => _vault.endIfLease(lease), banned: true);
  }

  // ---- ends ----------------------------------------------------------------

  /// Ends a session as one transition, for [lease]: [end] ends it in the
  /// vault, the teardown uses the credential it ended, and the picture says
  /// signed out (and suspended, for a ban). If [end] ended nothing, nothing
  /// changes. The attempt current when the end was asked for is retired;
  /// one begun after it is kept.
  Future<void> _endSession(
    int lease,
    Future<Credential?> Function() end, {
    bool banned = false,
  }) {
    final issuedWith = _attempt;
    return _transition(() async {
      if (_vault.lease != lease) return;
      final gone = await end();
      if (gone == null) return;
      if (identical(_attempt, issuedWith)) _attempt = null;
      await _teardown(gone);
      _show(
        _vault.lease,
        SessionPicture(const AsyncValue.data(null), suspended: banned),
      );
    });
  }

  /// Unpair with the credential that ended, drop the cached user, and close
  /// the socket. Ends nothing itself; never throws.
  Future<void> _teardown(Credential? ended) async {
    if (ended != null) {
      try {
        // Records a durable debt and fires the DELETE out of band, carrying
        // the credential by value: the vault no longer holds it.
        await ref
            .read(deviceRegistrarProvider)
            ?.unpair(credential: ended.accessToken);
      } catch (e) {
        debugPrint('AuthController: could not unpair the device: $e');
      }
    }
    try {
      await _cachedUser.clear();
    } catch (_) {}
    try {
      await ref.read(transportProvider).disconnect();
    } catch (_) {}
  }

  /// The person's own sign-out: ends whatever is signed in now. If the end
  /// couldn't reach the disk, the picture says so, and signing out again
  /// retries it.
  Future<void> logout() => _transition(() async {
    _attempt = null;
    final out = await _vault.signOut();
    await _teardown(out.ended);
    _show(
      _vault.lease,
      SessionPicture(
        out.saved
            ? const AsyncValue.data(null)
            : AsyncValue.error(const SignOutUnsaved(), StackTrace.current),
      ),
    );
  });

  /// Permanently delete the account (Apple 5.1.1(v)). The gateway is called
  /// FIRST, and a failure (e.g. [SoleAdminDeletionBlocked]) propagates with the
  /// user still signed in. On success, the session that sent it ends: a
  /// session that signed in while the request was out is left alone.
  Future<void> deleteAccount() async {
    final lease = _vault.lease;
    await _rest.deleteAccount();
    await _endSession(lease, () => _vault.endIfLease(lease));
  }

  /// Re-point the app at a different island, as one transition. Island tokens
  /// are only valid where they were issued, so a switch is a session boundary:
  ///
  ///   1. No-op guard: re-selecting the current island keeps the session.
  ///   2. Sign out and tear down, so the end is on disk before the island
  ///      moves. If it isn't, stop: the island stays where it was.
  ///   3. Then save the new island. If that fails, the app is signed out on
  ///      the old island.
  ///   4. Then move the live config, and show signed out.
  ///
  /// Every failure leaves the app signed out with the live config and the
  /// saved island both on the old island. The failure is shown on `/login` and
  /// rethrown for the picker.
  Future<void> switchIsland(String httpBaseUrl) async {
    final next = IslandConfig.normalized(httpBaseUrl).httpBaseUrl;
    if (next == ref.read(configProvider).httpBaseUrl) return;
    Exception? failure;
    await _transition(() async {
      _attempt = null;
      final out = await _vault.signOut();
      await _teardown(out.ended);
      if (!out.saved) {
        failure = const SignOutUnsaved();
      } else if (!await _saveIsland(next)) {
        failure = const IslandSwitchFailed(
          'Could not save the island selection.',
        );
      } else {
        ref.invalidate(configProvider);
      }
      final failed = failure;
      _show(
        _vault.lease,
        SessionPicture(
          failed == null
              ? const AsyncValue.data(null)
              : AsyncValue.error(failed, StackTrace.current),
        ),
      );
    });
    final failed = failure;
    if (failed != null) throw failed;
  }

  Future<bool> _saveIsland(String httpBaseUrl) async {
    try {
      return await ref
          .read(sharedPreferencesProvider)
          .setString(islandBaseUrlPrefKey, httpBaseUrl);
    } catch (_) {
      return false;
    }
  }
}

/// Thrown by [AuthController.switchIsland] when the chosen island could not
/// be saved. The app is signed out on the island it was on.
class IslandSwitchFailed implements Exception {
  final String message;
  const IslandSwitchFailed(this.message);
  @override
  String toString() => message;
}

/// A sign-out ended the session in this process but couldn't record it on
/// disk, so the next launch would restore it. Signing out again retries.
class SignOutUnsaved implements Exception {
  const SignOutUnsaved();
  @override
  String toString() => "Couldn't finish signing out on this device.";
}
