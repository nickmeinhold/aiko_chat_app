import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../chat/data/chat_rest_api.dart';
import '../data/pending_unregister_store.dart';
import 'push_telemetry.dart';
import '../domain/apns_environment.dart';
import '../domain/push_token_source.dart';

/// Keeps this island's belief about "where do I push to reach this user" in step
/// with the platform's belief about "what is this device's token".
///
/// Three events move that pairing and all three must be handled, because the
/// failure mode of missing one is silence rather than an error — the island
/// holds a token the push service will simply refuse to deliver to, and nothing
/// anywhere reports a problem:
///
///   sign-in          → register the current token
///   token rotation   → register the new one (reinstall, restore, platform whim)
///   sign-out         → unregister, so the next person to hold this handset does
///                      not receive the previous owner's pushes
///
/// NOT A GATE. Every failure here degrades reach and nothing else: a device that
/// cannot register is a device that will not be woken. Sign-in must never fail
/// because a push service was unreachable, so [start] swallows and logs.
///
/// ## The unpair is a DEBT, not a step
///
/// [unpair] returns without awaiting anything, and that is the whole design.
/// `DELETE /v1/devices` is authenticated, so it wants to run before the
/// credential is cleared; but nothing slow may sit there, because a re-login
/// inside that window writes fresh tokens the trailing clear then stomps. The
/// two constraints are genuinely opposed, and every guard that tried to honour
/// both just relocated the contradiction (five of them — see the design doc).
///
/// So the unpair is not something the teardown waits for. It writes a durable
/// debt, fires a best-effort attempt out of band with a credential carried by
/// value, and returns. There is no instant two operations contend for.
///
/// ## Why the debt can be paid by a different user, and why ORDER is the proof
///
/// The debt records only an island and its owed device tokens — never a
/// credential, and never a user. (A SET of tokens, not one: they rotate, so two
/// offline sign-outs can leave two live rows — cage-match round 3, Carnot.) It does not need one, and the reason is a property of the
/// island rather than a guess about ours:
///
///   - `unregister_device` matches on `(user_id, token)`. Draining a debt while
///     signed in as someone ELSE deletes nothing and returns 204 — a no-op we
///     could not distinguish from success even if we tried.
///   - `register_device` upserts on the token and REASSIGNS `user_id`. So the
///     moment that other user registers, the previous owner's row becomes
///     theirs; the residual closes without our DELETE having done anything.
///
/// [drainPending] therefore runs STRICTLY BEFORE [start], on every sign-in edge,
/// and that single ordering discharges every case:
///
///   same user returns  → the DELETE matches, the row goes, then we re-register
///   a different user   → the DELETE no-ops, then THEIR register takes the row
///   nobody signs in    → the row survives (below)
///
/// WHY THE ORDER, STATED ACCURATELY — the obvious reason is no longer the real
/// one, and a live run proved it (`docs/runbooks/arm2-teardown-ordering.md`).
///
/// The reversed order was justified here as "the DELETE matches the row the
/// register just created and destroys the live pairing". For a CONFIRMED
/// register of the SAME token that is now false: `_settle` discharges the debt
/// on proven success, so by the time a late drain ran the ledger would already
/// be empty. Reversing the two and signing out offline was measured live — the
/// island saw a POST and NO DELETE, and the row survived. The write-ahead
/// obligation closed that path independently.
///
/// What the ordering still buys is narrower and does not depend on that:
/// A DRAIN MUST NEVER BE A SESSION-START'S LAST WRITE. An AMBIGUOUS register
/// (response lost) deliberately leaves its obligation standing, so a drain that
/// ran afterwards could delete a row that POST may have just created, with
/// nothing following to re-create it. Draining FIRST means whatever it removes,
/// the register behind it puts back.
///
/// Both facts matter and neither replaces the other: keep the order, and do not
/// re-derive its justification from the sentence that used to be here.
///
/// NAMED RESIDUAL: sign out while offline and never sign in again on this
/// handset, and the island keeps a routable row. The out-of-band attempt closes
/// this whenever the network is up, which is the common case; what remains is
/// bounded by "no session is ever started here again", and no client-side
/// mechanism can reach past that. It needs a server-side expiry — filed, not
/// half-built here.
class DeviceRegistrar {
  DeviceRegistrar({
    required PushTokenSource source,
    required ChatRestApi api,
    required PendingUnregisterStore pending,
    required String islandBaseUrl,
    /// Defaults to the silent no-op so existing tests stay quiet. Production
    /// wires the real one through `pushTelemetryProvider` — pinned by
    /// `provider_wiring_test`, because a telemetry seam that silently falls back
    /// to a no-op in the shipped app is a failure this project has already had
    /// once (PR #45, Carnot).
    PushTelemetry telemetry = PushTelemetry.noop,
  }) : _source = source,
       _api = api,
       _pending = pending,
       _islandBaseUrl = islandBaseUrl,
       _telemetry = telemetry;

  final PushTokenSource _source;
  final PushTelemetry _telemetry;
  final ChatRestApi _api;
  final PendingUnregisterStore _pending;

  /// Which island this registrar speaks for. A debt is keyed by it, so a token
  /// registered here is never deleted at the island the user switched TO.
  final String _islandBaseUrl;

  StreamSubscription<String>? _refreshes;

  /// The token this island is believed to hold, so [unpair] owes the right one
  /// after a rotation. Without it a rotate-then-sign-out would owe a token the
  /// island never had and leave the live one routing.
  String? _registered;

  /// Which pairing attempt is current. Bumped by BOTH [start] and [unpair], and
  /// sampled at the TOP of start rather than after the permission prompt — the
  /// earlier version sampled it late, so an unpair that happened while the OS
  /// sheet was up was invisible to the registration that followed it, and the
  /// previous account's token went to the island under a session that had ended.
  int _generation = 0;

  Future<void>? _settling;

  /// Which register ISSUE is the newest. Bumped when a register goes on the
  /// wire, and checked again on the far side — see [_register].
  int _registerEpoch = 0;

  /// The newest issue that has reached its far side. `_registerEpoch` ahead of
  /// this means a register is ON THE WIRE right now — the one fact [_restate]
  /// needs and could not otherwise see.
  int _settledEpoch = 0;

  /// A push token is a routing secret — the REST layer deliberately keeps it out
  /// of URLs so it never reaches an access log or a proxy trace, and a debug
  /// print that dumps it whole quietly undoes that (cage-match round 4, Carnot).
  /// Enough prefix to correlate two log lines, never enough to route with.
  /// Whether a token is currently registered — for tests and diagnostics.
  String? get registeredToken => _registered;

  /// The out-of-band work [unpair] left running.
  ///
  /// TESTS ONLY, and deliberately not part of the teardown path: a caller that
  /// awaited this would re-create the window the debt record exists to remove.
  @visibleForTesting
  Future<void> get settled => _settling ?? Future<void>.value();

  /// Pay off anything this island is still owed, BEFORE registering anything.
  ///
  /// Ordering relative to [start] is load-bearing — see the class doc. Failure
  /// KEEPS the debt: an unreachable island now is an island we still owe, and
  /// the record is the only thing that will remember at the next opportunity.
  /// Pays off EVERY token owed, not just the newest — the ledger is a set,
  /// because tokens rotate and two offline sign-outs can leave two live rows.
  /// One failure does not abandon the rest.
  Future<void> drainPending() async {
    for (final token in _pending.read(_islandBaseUrl)) {
      try {
        await _api.unregisterDevice(token);
        if (!await _pending.forget(_islandBaseUrl, token)) {
          _telemetry.debtPaidButUnclearable(PushTelemetry.ref(token));
        }
      } catch (e) {
        _telemetry.debtDrainFailed(e);
      }
    }
  }

  /// Begin keeping the pairing current for the signed-in user. Idempotent.
  Future<void> start() async {
    if (_refreshes != null) return;
    final generation = ++_generation;

    // Subscribe BEFORE asking for the first token. A rotation that lands between
    // the two would otherwise be dropped, and the window is not theoretical —
    // the platform can reissue during the permission grant. The listener CLOSES
    // OVER this generation rather than reading the current one at delivery: a
    // refresh queued before an unpair belongs to the session that was live when
    // it was issued, and reading `_generation` late made the callback compare the
    // tombstone against itself and always match (cage-match round 4, Tesla). The
    // prose here said the opposite of the code until a reviewer read both.
    // TERMINAL CATCH on the listener. `_register` rethrows `Unauthorized` by
    // design, and a listener callback's future is awaited by nobody — so a
    // rotation arriving while the session is dying surfaced as an unhandled
    // ZONE ERROR rather than a log line. Found by writing the not-landed
    // control for the register invariant, not by review.
    _refreshes = _source.tokenRefreshes().listen(
      (t) => unawaited(
        _register(t, generation).catchError((Object e) {
          _telemetry.rotationRegisterFailed(e);
        }),
      ),
    );

    if (!await _source.requestPermission()) {
      // RELEASE the subscription on a denial (cage-match round 3, Carnot). A
      // denial left `_refreshes` non-null, so `start`'s idempotency guard made
      // every later call a no-op — and push permission changes OUT OF BAND, in
      // system settings. A user who declined, then turned notifications on, was
      // permanently unreachable with nothing reporting a problem. There is still
      // no retry and no nag; the next SESSION EDGE simply gets to ask again.
      unawaited(_refreshes?.cancel().catchError((_) {}));
      _refreshes = null;
      return;
    }
    if (generation != _generation) return; // unpaired while the sheet was up
    final token = await _source.currentToken();
    if (generation != _generation) return;
    if (token != null) await _register(token, generation);
  }

  /// End the pairing, and do not return until the DEBT IS DURABLE.
  ///
  /// AWAIT THIS, then clear credentials — in that order (cage-match round 4,
  /// Carnot). An earlier version returned synchronously and wrote the debt in a
  /// later microtask, which meant a process kill or app suspension between
  /// logout and that write lost the only retry record while the credential was
  /// already gone. "Durability that exists only after a future runs is not
  /// durability at teardown time."
  ///
  /// What is awaited is a LOCAL PREFERENCES WRITE — microseconds, no network —
  /// so this does not re-open the window the whole design exists to remove. The
  /// thing that must never sit ahead of the credential clear is the authenticated
  /// ROUND TRIP, and that stays out of band in [_attemptUnregister].
  ///
  /// [credential] is the one about to be destroyed; it is carried by value into
  /// that attempt precisely so the attempt need not happen before the clear.
  /// Passing null is fine — the debt is still recorded and [drainPending] pays
  /// it at the next sign-in.
  Future<void> unpair({String? credential}) async {
    _generation++; // any in-flight registration is now stale
    // `.catchError` because an unawaited cancel() can complete with an error
    // from an upstream onCancel — unhandled, that surfaces as a zone error
    // rather than a log line, on the session-teardown path of all places.
    unawaited(_refreshes?.cancel().catchError((_) {}));
    _refreshes = null;

    final token = _registered;
    _registered = null;
    if (token == null) return;
    // The write's RESULT is checked, not discarded: SharedPreferences reports a
    // persistence failure by returning false rather than throwing, and a debt
    // that did not persist is a backstop that does not exist.
    if (!await _pending.remember(_islandBaseUrl, token)) {
      _telemetry.debtRecordFailed(PushTelemetry.ref(token));
    }
    _settling = _attemptUnregister(token, credential);
  }

  /// Release the refresh subscription WITHOUT recording a debt.
  ///
  /// For provider teardown only. A rebuild (a gateway switch, a hot restart) is
  /// not a sign-out: the user is still signed in and the island's row is still
  /// the correct one, so owing ourselves a DELETE here would drain at the next
  /// sign-in edge and unregister a pairing nobody ended. The genuine end-of-
  /// session path is [unpair], and `switchGateway` calls it explicitly before
  /// invalidating the config that disposes this.
  void dispose() {
    unawaited(_refreshes?.cancel().catchError((_) {}));
    _refreshes = null;
  }

  /// The out-of-band DELETE, and the SIGNAL that follows it.
  ///
  /// THIS PATH DOES NOT WRITE. The island offers no fencing token and answers
  /// 204 either way, so an in-flight DELETE can neither be recalled nor
  /// observed — and a write issued from here would carry a dead session's
  /// credential and a check sampled before its own await. That was defect five.
  ///
  /// So if the pairing is live when our DELETE resolves, [_restate] asks the
  /// LIVE door to say so again, at the current generation. The straggler is not
  /// corrected; it is merely when we learned to look.
  ///
  /// The signal fires on the failure path too: a DELETE whose response was lost
  /// may still have removed the row, so "it threw" is not "nothing happened".
  ///
  /// Full history of the five guards this replaces:
  /// `docs/design/15-device-pairing-single-writer.md`.
  Future<void> _attemptUnregister(String token, String? credential) async {
    if (credential == null) return;
    try {
      await _api.unregisterDevice(token, credential: credential);
      await _pending.forget(_islandBaseUrl, token);
    } catch (e) {
      _telemetry.unregisterDeferred(e);
    }
    if (_registered == token) _restate();
  }

  /// Ask the live door to restate the current pairing.
  ///
  /// NOT A COMPENSATING WRITE: it corrects no specific prior operation and
  /// samples nothing before an await. It reads the desired state fresh, at the
  /// current generation, and hands it to the one door — subject to the same
  /// post-await check as every other register. Best-effort; reach is never a
  /// gate.
  void _restate() {
    final token = _registered;
    if (token == null) return;
    // NEVER RESTATE OVER A REGISTER ALREADY IN FLIGHT (cage-match, Tesla).
    // `_registered` is the last CONFIRMED token, not the desired one — so while
    // a rotation is on the wire it is deliberately stale, and restating it there
    // makes a THIRD writer that fights the second with a NEWER epoch. Tesla's
    // sequence: sign-in registers tok-1, the platform rotates to tok-2 (in
    // flight), the dead session's DELETE lands and restates tok-1 with a higher
    // epoch; tok-2 then settles STALE and gets owed a delete — the live platform
    // token — while the memo rolls back to tok-1. Silently unreachable, and no
    // refresh re-emits until the next real rotation.
    //
    // The in-flight register is already asserting the pairing this would assert,
    // and it knows the newer token. Yielding to it is not a guard on a window;
    // there is simply nothing left for this call to do.
    if (_registerEpoch != _settledEpoch) return;
    unawaited(
      _register(token, _generation, force: true).catchError((Object _) {}),
    );
  }

  /// THE ONE POST DOOR. `start`, a rotation and a restatement all enter here,
  /// so the check on the far side is inherited rather than re-implemented — a
  /// second copy of it would be the next guard.
  ///
  /// [force] exists because skip-if-same returns BEFORE the wire, which is
  /// exactly the steady state a restatement needs to restate. It is an
  /// optimisation for the refresh path, not a wall the self-heal cannot pass.
  Future<void> _register(
    String token,
    int generation, {
    bool force = false,
  }) async {
    if (generation != _generation) return;
    // Re-registering an unchanged token is harmless island-side (the upsert is
    // keyed on the token) but it is a pointless round trip on every rotation
    // event that reports the same value.
    if (!force && token == _registered) return;
    // Which register is the newest ISSUE. `_generation` answers session
    // liveness and cannot see a rotation: a POST for tok-1 in flight while the
    // platform rotates to tok-2 lands with the generation still matching, and a
    // tail that accepted it would roll the pairing back to the stale token while
    // tok-2's row routes to a handset nothing will ever clear.
    final epoch = ++_registerEpoch;
    // WRITE THE OBLIGATION AHEAD OF THE WRITE (cage-match, Carnot P1 x2). The
    // moment this POST is on the wire the island may hold a row, and the two
    // ways of learning otherwise both fail: a lost response never tells us, and
    // a process kill never gets to ask. `unpair` owes only what `_registered`
    // names, and `_registered` is set on CONFIRMED success — so both a
    // maybe-landed register and a register still in flight at logout left a
    // routable row nothing would ever clear.
    //
    // So a register is a debt until it is proven to be the pairing we want. The
    // cost is one local preferences write on a path that runs at session edges,
    // and the drain that pays it runs strictly before the next `start`, so a
    // debt discharged in error costs one redundant DELETE and never a lost row.
    // This is the same fail-toward-deletion the design's governing principle
    // names: an over-delete degrades reach, an under-delete leaks.
    if (!await _pending.remember(_islandBaseUrl, token)) {
      _telemetry.registerObligationUnrecorded(PushTelemetry.ref(token));
    }
    try {
      await _api.registerDevice(
        platform: _source.platform,
        token: token,
        apnsEnvironment: await _apnsEnvironment(),
      );
    } on Unauthorized {
      // DEFINITELY-NOT-LANDED: the island rejected this before writing, so the
      // obligation written above is owed for a row that does not exist. Discharge
      // it — an unearned debt aims a DELETE at whatever holds this token next.
      // Not ours to handle otherwise: the auth controller owns that transition.
      await _pending.forget(_islandBaseUrl, token);
      rethrow;
    } catch (e) {
      _telemetry.registerFailed(PushTelemetry.ref(token), e);
      // MAYBE-LANDED. A POST whose response was lost may still have written the
      // row, and no later event re-examines a register that threw. Everything
      // that is not a rejection is treated as ambiguous, and ambiguity settles
      // through the same tail as success.
      await _settle(token, generation, epoch, confirmed: false);
      return;
    }
    await _settle(token, generation, epoch, confirmed: true);
  }

  /// Which APNs host will accept the token we are about to register, or null to
  /// let the island resolve it from `APNS_USE_SANDBOX`.
  ///
  /// Resolved PER REGISTER rather than cached at construction, because the
  /// answer is only available once the platform channel is attached and the
  /// registrar is built before that. It is a build-invariant fact so the repeat
  /// reads agree; the cost is one channel hop on a path that already does a
  /// preferences write and a POST.
  ///
  /// A THROW HERE MUST NOT FAIL THE REGISTER. Both shipped sources already
  /// answer null instead of throwing, so this catch is for the seam rather than
  /// for them: an implementation that throws would otherwise convert "we cannot
  /// name the environment" into "this device does not register at all", which is
  /// strictly worse than the pre-field behaviour it replaces.
  Future<ApnsEnvironment?> _apnsEnvironment() async {
    try {
      return await _source.apnsEnvironment();
    } catch (e) {
      _telemetry.environmentUnresolved(e);
      return null;
    }
  }

  /// The far side of every register — the check that could not be sampled early.
  ///
  /// Three questions, and the third is the one round 2 of the design temper
  /// corrected: not just "is this still current?" but "what did the write DO?".
  Future<void> _settle(
    String token,
    int generation,
    int epoch, {
    required bool confirmed,
  }) async {
    // This issue has reached its far side. Only ever moves forward, so an older
    // straggler settling after a newer one cannot re-open the in-flight window.
    if (epoch > _settledEpoch) _settledEpoch = epoch;
    if (generation == _generation && epoch == _registerEpoch) {
      // STILL THE ONE WE WANT. On a confirmed write the pairing is live and
      // ours, so any older debt for the same token is discharged — it would
      // otherwise drain at the next sign-in edge and delete a row we want.
      // Compare-and-clear, so a newer debt is left alone.
      //
      // On an AMBIGUOUS one, nothing: the row may or may not exist, but it is
      // the row we want either way, so there is nothing to owe. It is
      // deliberately NOT recorded as registered — a failed register that reads
      // as landed makes the next sign-in skip it, and the device stays
      // unreachable forever.
      if (!confirmed) return;
      _registered = token;
      // PROVEN to be the pairing we want, so the obligation written at issue is
      // discharged. This is the ONLY place it is discharged on the success path —
      // a stale or ambiguous register leaves it standing, which is what makes a
      // lost response and a mid-flight kill both safe.
      await _pending.forget(_islandBaseUrl, token);
      return;
    }

    // A REASSIGNMENT, not a leftover. `register_device` upserts on
    // UNIQUE(token) and REASSIGNS user_id, so this late POST did not linger —
    // it took the row BACK from whoever holds it now. A debt cannot undo that:
    // `unregister` matches (user_id, token), and the current session's
    // credential no longer matches the row it would have to delete. Only a POST
    // from the CURRENT session reclaims it.
    // THIS TOKEN IS STILL THE LIVE PAIRING, so it is never owed a delete — the
    // question is only whether somebody took it from us.
    if (_registered == token) {
      // A SESSION EDGE is required for a reassignment: `register_device` only
      // takes the row from someone else if the credential that posted it belongs
      // to a different user. So a moved generation means our late POST handed the
      // row to the PREVIOUS session's user, and no DELETE this session can issue
      // will match it — only a POST from the current session reclaims it.
      if (generation != _generation) {
        _telemetry.registerReassignedLiveRow(PushTelemetry.ref(token));
        _restate();
      }
      // Otherwise the staleness is EPOCH-only: a newer register for the same
      // token and the same user already won. Same row, idempotent upsert,
      // nothing taken — and owing a delete here would aim the next drain at the
      // live pairing.
      return;
    }

    // Not the live pairing: this token is not the desired one and nobody holds it.
    //
    // RE-ASSERT the obligation rather than trusting the one written at issue.
    // The two are not redundant, they cover different losses, and reading them
    // as one cost a test: the write-ahead survives a process kill and a lost
    // response, but it can be DISCHARGED OUT FROM UNDER US — an `unpair` landing
    // while this POST is in flight fires its own DELETE, and that DELETE's
    // success calls `forget` on this very token. The tail then finds nothing
    // standing for a row its own POST may have just created.
    //
    // Owing a DELETE still beats issuing one inline: the token is stable per
    // install, so an inline delete could match a row the NEXT session already
    // registered, whereas the drain runs strictly before the next start.
    if (!await _pending.remember(_islandBaseUrl, token)) {
      _telemetry.registerStaleRowUnrecorded(PushTelemetry.ref(token));
    }
  }
}
