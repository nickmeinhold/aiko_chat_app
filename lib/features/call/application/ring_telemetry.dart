import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/aiko_log.dart';
import '../../../core/logging/log_providers.dart';
import '../../../core/logging/aiko_logger.dart';
import '../domain/call_invite.dart';

/// The ring subsystem's typed telemetry facade.
///
/// Every method takes a channel id and a [RingRefusal] — an enum value, not a
/// string — so there is no parameter through which a message body, a public key
/// or a signature could reach a log. The invite body is a fixed sentinel and
/// therefore safe, but nothing here needs it, so nothing here accepts it.
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
  /// WARNING rather than INFO: every value that reaches here is
  /// [RingRefusal.noteworthy], meaning somebody tried to ring you and the gate
  /// said no. That is worth surfacing distinctly from ordinary chatter even
  /// when the refusal is correct — a blocked caller and a skewed clock are both
  /// "working as designed" and both worth seeing in a report.
  void ringRefused(String channelId, RingRefusal reason) => _log.warning(
    'call.ring.refused',
    fields: {'channel': channelId, 'reason': reason.name},
  );

  /// A hangup was refused. Rarer and more suspicious than a refused ring: the
  /// asymmetry is deliberate (an unadmitted end means KEEP RINGING), so a
  /// refusal here leaves a bell ringing for a call that may already be dead.
  void endRefused(String channelId, RingRefusal reason) => _log.warning(
    'call.end.refused',
    fields: {'channel': channelId, 'reason': reason.name},
  );

  /// The ring was admitted and the handset is ringing. INFO, and the positive
  /// control for the two above: without it, an empty report cannot distinguish
  /// "no call arrived" from "logging is broken".
  void ringAdmitted(String channelId, Duration age) => _log.info(
    'call.ring.admitted',
    fields: {'channel': channelId, 'ageMs': age.inMilliseconds},
  );

  static const RingTelemetry noop = RingTelemetry(
    AikoLogger(subsystem: 'aiko.call.ring', sink: NoopLogSink()),
  );
}

/// Wired to the REAL logger, never [RingTelemetry.noop] — pinned by
/// `ring_telemetry_test`, because this project has already shipped a telemetry
/// seam that silently fell back to a no-op (PR #45, Carnot).
final ringTelemetryProvider = Provider<RingTelemetry>(
  (ref) => RingTelemetry(ref.watch(rootLoggerProvider).child('call.ring')),
);
