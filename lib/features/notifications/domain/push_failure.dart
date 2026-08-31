import 'package:dio/dio.dart';

/// Why a push-registration call failed, as a closed set.
///
/// ## The defect this replaces
///
/// Every failure on this path was logged as `error: e`, and [RedactingLogSink]
/// projects an error to `runtimeType.toString()` — correctly, because a
/// `DioException`'s string can carry the request body. The result was that a
/// real diagnostic report said:
///
/// ```
/// 05:17:15 INFO aiko.push push.unregister.deferred error=DioException
/// ```
///
/// A dead credential, a timeout and a DNS failure are all `DioException`, so the
/// one question a reader has — *will this ever succeed on its own?* — was
/// unanswerable from the report. Establishing the answer took reading three
/// source files (2026-08-31); it should have taken reading one line.
///
/// This is the same move that made `RingRefusal` work: the log carries the FACT,
/// and the reader does no inference. `reason=stale` closed a diagnosis the same
/// afternoon that `error=DioException` failed to.
///
/// ## Why this cannot leak, by construction rather than by regex
///
/// [of] reads exactly two things: [DioExceptionType] (an enum) and
/// `response.statusCode` (an int). It never touches `message`, `data`,
/// `requestOptions.path`, or any other open-ended field. So no value from the
/// wire can reach the log through this reason — not because a redactor cleans it
/// afterwards, but because it is never carried in the first place.
///
/// That is deliberately the same shape as the redactor's own comment: the fix
/// for a dangerous string is not to scrub it, it is not to stringify it.
///
/// The `error:` field is UNCHANGED and still projects to the type name. This
/// reason is additive — it does not widen what is recorded, it narrows what the
/// reader must guess.
enum PushFailure {
  /// The island was not reachable at all (DNS, refused, offline).
  unreachable(transient: true),

  /// A timeout on connect, send or receive.
  timedOut(transient: true),

  /// The request was cancelled — teardown races this path routinely.
  cancelled(transient: true),

  /// TLS rejected. Not transient: retrying an untrusted certificate is how you
  /// train a client to accept one.
  badCertificate(transient: false),

  /// 401/403 — the credential this call was made with is dead.
  ///
  /// THE ONE TO WATCH, and the reason this enum exists. It is the only value
  /// that says a retry can never work without re-authenticating, which is
  /// exactly the discrimination the unregister-debt path needs: a debt that
  /// failed transiently is owed and payable, and a debt that failed with a dead
  /// credential is owed and NOT payable by this client at all
  /// (claude-tasks#3723).
  credentialRejected(transient: false, credentialIsDead: true),

  /// 429 — the island is shedding load, not refusing us.
  ///
  /// A retryable 4xx, and the reason this member exists separately: an earlier
  /// version of the ladder classified EVERY non-401/403 4xx as permanent, so a
  /// rate-limited island read as `reason=rejected retry=false` and a reader
  /// would close the diagnosis wrong. Worse downstream: once claude-tasks#3723
  /// reads `!transient` to declare a debt unpayable, a throttled island would
  /// mint an orphaned routable row this client never clears. Found by two
  /// reviewer families independently, which is what a real defect looks like.
  rateLimited(transient: true),

  /// Any other 4xx. Our bug or our stale assumption, not a dead session — kept
  /// distinct from [credentialRejected] so "the session expired" cannot absorb
  /// "we sent a malformed body".
  rejected(transient: false),

  /// 5xx. The island is unwell; the request was probably fine.
  islandError(transient: true),

  /// Not classifiable.
  ///
  /// FAILS OPEN, deliberately. Weak-signal capture fails open where irreversible
  /// mutation fails closed: reporting an unclassifiable failure as permanent
  /// would licence abandoning a debt nobody has shown to be unpayable, and an
  /// abandoned debt is a routable row this client can never clear.
  unknown(transient: true);

  const PushFailure({required this.transient, this.credentialIsDead = false});

  /// Whether an identical retry could plausibly succeed later.
  final bool transient;

  /// Whether the credential used is dead, so no retry of any schedule helps.
  ///
  /// Strictly narrower than `!transient`: [badCertificate] and [rejected] are
  /// also not worth retrying, but for reasons a fresh sign-in would not fix. A
  /// test pins this to exactly one member, because a flag that spreads to
  /// "roughly the bad ones" stops carrying information.
  ///
  /// ## NO RUNTIME CONSUMER YET — read this before relying on it
  ///
  /// Nothing branches on this today. `_attemptUnregister` still catches, logs
  /// and moves on identically whichever value it gets, and this flag's only
  /// non-test reader is the log line. It is stated here rather than left to a
  /// PR description because "we DISTINGUISH a dead credential" is one careless
  /// sentence away from "we HANDLE a dead credential", and the second is false.
  ///
  /// The consumer is claude-tasks#3723: paying a debt owed to an island whose
  /// credential is gone needs an island-side contract change (a DELETE signed by
  /// the sovereign key), so the branch that reads this cannot be written on this
  /// side of the wire yet. Raised independently by Carnot and by the author's
  /// own pass, round 1 — a capability that is tested but never driven.
  final bool credentialIsDead;

  /// Classify [error]. Reads only closed values — never a message or a body.
  static PushFailure of(Object? error) {
    if (error is! DioException) return unknown;
    switch (error.type) {
      case DioExceptionType.connectionError:
        return unreachable;
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return timedOut;
      case DioExceptionType.cancel:
        return cancelled;
      case DioExceptionType.badCertificate:
        return badCertificate;
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        final status = error.response?.statusCode;
        if (status == null) return unknown;
        if (status == 401 || status == 403) return credentialRejected;
        // BEFORE the generic 4xx arm: 408 and 429 are retryable 4xx, and
        // collapsing them into `rejected` is the defect this ladder shipped with.
        if (status == 408) return timedOut;
        if (status == 429) return rateLimited;
        if (status >= 500) return islandError;
        if (status >= 400) return rejected;
        return unknown;
    }
  }
}
