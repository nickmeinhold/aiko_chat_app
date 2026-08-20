import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../chat/data/chat_rest_api.dart';
import '../data/pending_unregister_store.dart';
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
/// `DELETE /v1/devices` is authenticated, so an earlier version awaited it ahead
/// of the credential clear — but nothing slow may sit there, because a re-login
/// inside that window writes fresh tokens the trailing clear then stomps. The
/// two constraints are genuinely opposed, so every guard that tried to honour
/// both just relocated the contradiction: a token fence that mis-fired on an
/// ordinary 401 refresh and aborted the whole teardown, leaving the user parked
/// on /login holding a LIVE credential; a generation counter sampled after the
/// permission prompt, so a stop mid-prompt still POSTed the previous account's
/// token; and an inline undo that unregistered by token, which is stable per
/// install, so a stale completion deleted the NEXT session's live row.
///
/// So the unpair stopped being something the teardown waits for. It writes a
/// durable debt, fires a best-effort attempt out of band with a credential it
/// carries by value, and returns. The credential clear is unconditional and
/// immediate again, and the three races have nowhere to live because nothing is
/// racing: there is no instant that two operations are contending for.
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
/// Reversing it is the bug the ordering exists to prevent: drain AFTER start and
/// the debt's token has just been re-registered to the current user, so the
/// DELETE matches — and deletes the live row we created a moment ago.
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
  }) : _source = source,
       _api = api,
       _pending = pending,
       _islandBaseUrl = islandBaseUrl;

  final PushTokenSource _source;
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

  /// A push token is a routing secret — the REST layer deliberately keeps it out
  /// of URLs so it never reaches an access log or a proxy trace, and a debug
  /// print that dumps it whole quietly undoes that (cage-match round 4, Carnot).
  /// Enough prefix to correlate two log lines, never enough to route with.
  static String _redact(String token) =>
      '${token.length <= 8 ? token : token.substring(0, 8)}…[${token.length}]';

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
          debugPrint(
            'DeviceRegistrar: PAID the debt for ${_redact(token)} but could '
            'not clear the record — it will be re-attempted, a harmless no-op.',
          );
        }
      } catch (e) {
        debugPrint('DeviceRegistrar: pending unregister still owed: $e');
      }
    }
  }

  /// Begin keeping the pairing current for the signed-in user. Idempotent.
  Future<void> start() async {
    if (_refreshes != null) return;
    final generation = ++_generation;

    // Subscribe BEFORE asking for the first token. A rotation that lands between
    // the two would otherwise be dropped, and the window is not theoretical —
    // the platform can reissue during the permission grant. The listener reads
    // the CURRENT generation at delivery time rather than closing over this one,
    // because a refresh arriving now belongs to whatever session is live now.
    _refreshes = _source.tokenRefreshes().listen(
      (t) => _register(t, generation),
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
      debugPrint(
        'DeviceRegistrar: COULD NOT RECORD the unregister debt for '
        '${_redact(token)} — if the attempt below also fails, this island keeps '
        'a routable row and nothing will retry it.',
      );
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

  /// The out-of-band DELETE, plus the repair that makes its TIMING irrelevant.
  ///
  /// THE STRAGGLER CANNOT BE ORDERED, so it is repaired instead (cage-match
  /// round 4 — Carnot and Tesla converged here independently). Three rounds
  /// tried to order it: await the DELETE (lost the teardown), fence it (abandoned
  /// a live credential), pin the re-register behind it (correct, but unbounded),
  /// then bound that (reopened the race). The bound was the clearest lesson —
  /// `Future.timeout` in Dart does NOT cancel the original, it only stops
  /// listening, so the DELETE stayed in flight with a loaded gun while we
  /// re-registered in front of it.
  ///
  /// The island matches `(user_id, token)` and offers no fencing token, so a
  /// DELETE issued for a dead session and a DELETE issued for a live one are
  /// indistinguishable to it once in flight. We cannot make it land in order and
  /// we cannot recall it. What we CAN do is notice afterwards: if this pairing is
  /// still the current one when our DELETE finally completes, the row we just
  /// removed was live, so put it back. Convergence instead of choreography.
  Future<void> _attemptUnregister(String token, String? credential) async {
    if (credential == null) return;
    try {
      await _api.unregisterDevice(token, credential: credential);
      await _pending.forget(_islandBaseUrl, token);
    } catch (e) {
      debugPrint('DeviceRegistrar: unregister deferred to next sign-in: $e');
    }
    // REPAIR, on the failure path too: a DELETE whose response was lost may still
    // have deleted the row, so "it threw" is not "nothing happened". Re-POSTing a
    // token the island already holds is an idempotent upsert, which makes the
    // wrong guess here cheap and the right one load-bearing.
    if (_registered != token) return;
    try {
      await _api.registerDevice(platform: _source.platform, token: token);
      debugPrint(
        'DeviceRegistrar: a late unregister landed on the LIVE pairing for '
        '${_redact(token)} — re-registered it.',
      );
    } catch (e) {
      debugPrint('DeviceRegistrar: could not repair a late unregister: $e');
    }
  }

  Future<void> _register(String token, int generation) async {
    if (generation != _generation) return;
    // Re-registering an unchanged token is harmless island-side (the upsert is
    // keyed on the token) but it is a pointless round trip on every rotation
    // event that reports the same value.
    if (token == _registered) return;
    try {
      await _api.registerDevice(platform: _source.platform, token: token);
    } on Unauthorized {
      // The session died underneath us. Not ours to handle — the auth controller
      // owns that transition — and NOT recorded as registered, so a later
      // sign-in re-registers rather than assuming this one landed.
      rethrow;
    } catch (e) {
      debugPrint(
        'DeviceRegistrar: register failed, this device will not wake: $e',
      );
      return;
    }
    if (generation != _generation) {
      // Landed after the session ended. Owe it rather than deleting it inline:
      // the token is stable per install, so by the time an inline DELETE
      // completed it could be matching a row the NEXT session had already
      // registered — deleting a live pairing to clean up a dead one. As a debt
      // it is safe by ordering instead, since the drain runs strictly before the
      // next start.
      await _pending.remember(_islandBaseUrl, token);
      return;
    }
    _registered = token;
    // This pairing is live and ours, so any older debt for the same token is
    // discharged — it would otherwise drain at the next sign-in edge and delete
    // a row we want. Compare-and-clear, so a newer debt is left alone.
    await _pending.forget(_islandBaseUrl, token);
  }
}
