import '../../../core/logging/aiko_log.dart';
import '../../../core/logging/aiko_logger.dart';

/// The push subsystem's typed telemetry facade — the layer where the never-log
/// rule is a property of the SIGNATURE rather than a convention.
///
/// Every method here takes opaque correlation values (an island base URL, a
/// short token prefix, an error TYPE) and has no parameter capable of carrying a
/// full device token. That is the point: `RedactingLogSink` is defence in depth,
/// but the primary discipline is that a caller cannot express the leak.
///
/// ## Why push, first
///
/// Registration failure is the canonical silent failure in this app. Every
/// failure mode here degrades REACH and nothing else — no exception surfaces, no
/// UI changes, and the user's first evidence is a call that never rang. The
/// existing code says so in its own words: *"the failure mode of missing one is
/// silence rather than an error — the island holds a token the push service will
/// simply refuse to deliver to, and nothing anywhere reports a problem."*
///
/// That is a subsystem whose entire failure surface reports success by default,
/// which is exactly where an observability seam earns its keep.
///
/// ## Levels
///
/// SEVERE is reserved for "this device will not wake" — the terminal reach
/// failure. WARNING is a degraded-but-recoverable state (a debt deferred, a
/// rotation that will be retried). INFO is a state transition worth correlating
/// against an island-side log.
class PushTelemetry {
  const PushTelemetry(this._log);

  final AikoLogger _log;

  /// Short, non-reversible handle for a token, for correlating a client line
  /// against an island row. Mirrors the 12-char trade `RedactingLogSink`
  /// documents; kept here too so a caller reading this file sees the discipline
  /// without having to know the sink exists.
  static String ref(String token) =>
      token.length <= 12 ? token : token.substring(0, 12);

  // --- registration ------------------------------------------------------

  /// The terminal reach failure: the island has no routable row for us.
  void registerFailed(String tokenRef, Object error) => _log.severe(
    'push.register.failed',
    fields: {'token': tokenRef, 'consequence': 'device-will-not-wake'},
    error: error,
  );

  /// A POST whose response was lost. The row MAY exist; nothing re-examines it.
  void registerObligationUnrecorded(String tokenRef) => _log.warning(
    'push.register.obligation_unrecorded',
    fields: {'token': tokenRef, 'risk': 'row-nothing-will-clear'},
  );

  /// A late register reassigned the live row; we restate under this session.
  void registerReassignedLiveRow(String tokenRef) =>
      _log.info('push.register.reassigned', fields: {'token': tokenRef});

  /// A stale register may have left a row and the debt could not be re-recorded.
  void registerStaleRowUnrecorded(String tokenRef) => _log.warning(
    'push.register.stale_row_unrecorded',
    fields: {'token': tokenRef},
  );

  void rotationRegisterFailed(Object error) =>
      _log.warning('push.rotation.register_failed', error: error);

  // --- the unregister debt ------------------------------------------------

  /// Paid, but the ledger entry survived. Harmless: the retry is a no-op.
  void debtPaidButUnclearable(String tokenRef) =>
      _log.info('push.debt.paid_unclearable', fields: {'token': tokenRef});

  void debtDrainFailed(Object error) =>
      _log.warning('push.debt.drain_failed', error: error);

  /// The debt could not be written. If the attempt also fails, the island keeps
  /// a routable row and NOTHING will retry it.
  void debtRecordFailed(String tokenRef) => _log.warning(
    'push.debt.record_failed',
    fields: {'token': tokenRef, 'risk': 'orphan-routable-row'},
  );

  /// Over the per-island cap — a debt nobody can retry is being discarded.
  void debtDropped(String islandBaseUrl, String tokenRef, int cap) =>
      _log.warning(
        'push.debt.dropped',
        fields: {'island': islandBaseUrl, 'token': tokenRef, 'cap': cap},
      );

  void unregisterDeferred(Object error) =>
      _log.info('push.unregister.deferred', error: error);

  // --- the platform seam --------------------------------------------------

  void permissionRequestFailed(String platform, Object error) => _log.warning(
    'push.permission.request_failed',
    fields: {'platform': platform},
    error: error,
  );

  /// No token from the platform — the commonest silent reach failure.
  void tokenUnavailable(String platform, Object error) => _log.severe(
    'push.token.unavailable',
    fields: {'platform': platform, 'consequence': 'device-will-not-wake'},
    error: error,
  );

  /// Could not resolve the APNs environment; the island's default decides.
  void environmentUnresolved(Object error) =>
      _log.info('push.environment.unresolved', error: error);

  /// The native platform channel is absent from this build — a `.swift` outside
  /// the Runner target, or a platform we do not implement. SEVERE because push
  /// can never work in this binary: it is a build defect, not a runtime one, and
  /// its only symptom is a handset that silently never rings.
  void nativeChannelMissing(String platform, Object error) => _log.severe(
    'push.native_channel.missing',
    fields: {'platform': platform, 'consequence': 'push-inoperable-in-build'},
    error: error,
  );

  /// The token-rotation stream faulted. The current token still routes; a future
  /// rotation may be missed, which degrades to a stale row on the island.
  void rotationStreamError(String platform, Object error) => _log.warning(
    'push.rotation.stream_error',
    fields: {'platform': platform},
    error: error,
  );

  void pairingFailed(Object error) =>
      _log.warning('push.pairing.failed', error: error);

  /// Silent by default, for tests. Mirrors `_NoopTelemetry`.
  static const PushTelemetry noop = PushTelemetry(
    AikoLogger(subsystem: 'aiko.push', sink: NoopLogSink()),
  );
}
