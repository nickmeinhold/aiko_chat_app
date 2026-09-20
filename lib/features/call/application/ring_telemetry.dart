import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/aiko_log.dart';
import '../../../core/logging/log_providers.dart';
import '../../../core/logging/aiko_logger.dart';
import '../domain/answer_outcome.dart';
import '../domain/call_invite.dart';

/// The ring subsystem's typed telemetry facade.
///
/// Every method takes a channel id plus scalars — a [RingRefusal] enum value, a
/// duration — never free text. So there is no parameter through which a message
/// body, a public key or a signature could reach a log. The invite body is a
/// fixed sentinel and therefore safe, but nothing here needs it, so nothing here
/// accepts it. (An earlier version of this sentence claimed EVERY method takes a
/// [RingRefusal]; the started / dead-on-arrival / duplicate arms do not, and a
/// docstring that describes its own completeness wrongly is the same class of
/// defect as the rest of this change — Tesla, round 3.)
///
/// ## The channel id IS logged, deliberately
///
/// It is the correlation key: without it a report says a ring was refused and
/// cannot say which conversation, which makes it unactionable. It is an opaque
/// ULID naming a conversation, not a person — a reader who does not already have
/// this device's channel list learns nothing from it, and one who does is the
/// device's owner. The island already treats a channel id as the one identifier
/// worth spending on the APNs wire (`push_service._payload`) after weighing the
/// same trade, so this is consistent with the recorded decision rather than a
/// fresh one. `RedactingLogSink` deliberately preserves ULIDs for this reason.
/// (Raised by Carnot, #3591 cage-match: the docstring argued only that bodies,
/// keys and signatures cannot reach the log, and said nothing about ids.)
///
/// ## Why the refusal is the whole feature
///
/// A ring that does not happen produces no exception, no UI change and no user-
/// visible event. Its entire symptom is a phone that stayed quiet, which is
/// indistinguishable from nobody having called. That is the purest form of
/// silence-reads-as-success in the app, and it is why the refusal reason —
/// not the admission — is what these methods exist to record.
class RingTelemetry {
  const RingTelemetry(this._log);

  final AikoLogger _log;

  /// A message was aimed at this handset and did not ring it.
  ///
  /// WARNING rather than INFO: every value that reaches here has
  /// [RingRefusal.refusedAnAttempt] set, meaning somebody tried to ring you and
  /// the gate said no. That is worth surfacing distinctly from ordinary chatter even
  /// when the refusal is correct — a blocked caller and a skewed clock are both
  /// "working as designed" and both worth seeing in a report.
  /// [age] is the invitation's measured age, present only for the refusals
  /// decided ON age ([RingRefusal.stale], [RingRefusal.clockSkew]) and omitted
  /// entirely otherwise — an absent field rather than a `null`, because
  /// `ageMs=null` on a blocked sender would invite a reader to wonder which
  /// clock failed, and no clock was consulted.
  ///
  /// It is the field that makes `reason=stale` actionable. The reason names the
  /// clause; the age names the fault. `ageMs=12000` is a push wake overrunning
  /// [kCallInviteFreshness] and argues the window is wrong for that path;
  /// `ageMs=300000` is a peer clock out by five minutes and argues nothing about
  /// the window at all; `ageMs=-4000` is our own clock ahead of the caller's.
  /// Three fixes that share one refusal, and before this field a report could
  /// not tell a reader which one they were looking at.
  void ringRefused(String channelId, RingRefusal reason, {Duration? age}) =>
      _log.warning(
        'call.ring.refused',
        fields: {
          'channel': channelId,
          'reason': reason.name,
          if (age != null) 'ageMs': age.inMilliseconds,
        },
      );

  /// An action arrived from the NATIVE call UI — answered, ended, anything.
  ///
  /// The only Dart-side witness to what CallKit did. `reportNewIncomingCall`,
  /// the answer and the end all happen natively, and on a background wake the
  /// Dart isolate can be frozen moments later — so this stream, written into a
  /// buffer that survives suspension, is how the native half's decisions reach
  /// a report at all.
  ///
  /// [kind] is a string rather than the enum because this facade sits below the
  /// platform channel's vocabulary and must not gain a compile-time dependency
  /// on it; the caller passes `kind.name`, which is the same value the channel
  /// puts on the wire.
  void systemCallAction(String channelId, String kind) => _log.info(
    'call.system.action',
    fields: {'channel': channelId, 'kind': kind},
  );

  /// The ring STOPPED, and why.
  ///
  /// The stop gate's success path, which had no name until 2026-09-20. An
  /// admitted hangup silences the ring through `stopRinging()`, which wrote
  /// nothing — so "the caller hung up" and "the ring evaporated for reasons
  /// unknown" were the same observation. [RingStopCause.callerHungUp] is the
  /// line that distinguishes them.
  void ringStopped(String? channelId, RingStopCause cause) => _log.info(
    'call.ring.stopped',
    fields: {'channel': ?channelId, 'cause': cause.name},
  );

  /// An answer was taken and is being held until the session can join it.
  ///
  /// Paired with [answerResolved]: a `held` with no `resolved` after it is an
  /// answer still waiting, and that is a REAL state (a restore that never
  /// resolves holds indefinitely, by design). Without the pair, that state and
  /// a crash look identical.
  void answerHeld(String channelId) =>
      _log.info('call.answer.held', fields: {'channel': channelId});

  /// What became of a held answer.
  ///
  /// INFO for [AnswerOutcome.joined], WARNING for every other value: each of
  /// the others is a call the user tried to take and did not get. That is the
  /// same reasoning [ringRefused] uses — a refusal that is working as designed
  /// is still worth seeing in a report.
  void answerResolved(String channelId, AnswerOutcome outcome) {
    final fields = {'channel': channelId, 'outcome': outcome.name};
    if (outcome == AnswerOutcome.joined) {
      _log.info('call.answer.resolved', fields: fields);
    } else {
      _log.warning('call.answer.resolved', fields: fields);
    }
  }

  /// The call screen mounted, and began connecting.
  ///
  /// THE DISCRIMINATOR THE ISLAND LOG COULD NOT PROVIDE. A missing room-token
  /// request proves the join did not finish; it cannot say whether the screen
  /// was never reached or was reached and torn down first. These two lines
  /// separate those.
  void callScreenOpened(String channelId) =>
      _log.info('call.screen.opened', fields: {'channel': channelId});

  /// The call screen was disposed — every exit lands here, including the one
  /// that ends the system call unconditionally.
  void callScreenDisposed(String channelId) =>
      _log.info('call.screen.disposed', fields: {'channel': channelId});

  /// A hangup was refused. Rarer and more suspicious than a refused ring: the
  /// asymmetry is deliberate (an unadmitted end means KEEP RINGING), so a
  /// refusal here leaves a bell ringing for a call that may already be dead.
  void endRefused(String channelId, RingRefusal reason) => _log.warning(
    'call.end.refused',
    fields: {'channel': channelId, 'reason': reason.name},
  );

  /// The ring was admitted and the handset is ringing. INFO, and the positive
  /// control for the refusals above: without it, an empty report cannot
  /// distinguish "no call arrived" from "logging is broken".
  void ringStarted(String channelId, Duration age) => _log.info(
    'call.ring.started',
    fields: {'channel': channelId, 'ageMs': age.inMilliseconds},
  );

  /// ADMITTED by every trust clause and then suppressed anyway, because the
  /// caller's hangup was already remembered. Not a gate refusal — the call was
  /// real and legitimate, it was simply already over.
  ///
  /// Recorded because the alternative is a vacuum, and a vacuum is the exact
  /// shape of the hole this work exists to close: `admitRing` says yes and the
  /// handset stays quiet. The next reader would not ask "which gate refused?" —
  /// they would ask "the gate said yes, so where did it go?" and find nothing.
  /// The out-of-order path is first-class here (delivery is at-least-once and
  /// locally unordered, and push makes an end-before-invite LIKELIER), so this
  /// is a routine event, not an exotic one. (Tesla, #3591 cage-match.)
  void ringDeadOnArrival(String channelId) =>
      _log.info('call.ring.dead_on_arrival', fields: {'channel': channelId});

  /// The same invitation delivered again while it is already ringing. Expected
  /// under at-least-once delivery; recorded at DEBUG so a report can show the
  /// duplicate rate without the hot path drowning the buffer.
  void ringDuplicate(String channelId) =>
      _log.debug('call.ring.duplicate', fields: {'channel': channelId});

  static const RingTelemetry noop = RingTelemetry(
    AikoLogger(subsystem: 'aiko.call.ring', sink: NoopLogSink()),
  );
}

/// Wired to the REAL logger, never [RingTelemetry.noop] — pinned by
/// `test/core/logging/log_providers_test.dart` — NOT a `ring_telemetry_test`,
/// which is what this comment used to cite and which does not exist (Tesla,
/// round 3: a doc naming a test that is not there is a claim, not a citation).
/// Pinned because this project has already shipped a telemetry
/// seam that silently fell back to a no-op (PR #45, Carnot).
final ringTelemetryProvider = Provider<RingTelemetry>(
  (ref) => RingTelemetry(ref.watch(rootLoggerProvider).child('call.ring')),
);
