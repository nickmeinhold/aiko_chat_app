import 'aiko_log.dart';

/// A subsystem-scoped handle onto a [LogSink] — what a typed facade holds.
///
/// Feature code does not hold one of these either. The intended chain is:
///
///   feature code  ->  typed facade (RingTelemetry, PushTelemetry, ...)
///                 ->  AikoLogger  ->  LogSink
///
/// The facade is where the never-log rule lives, because a method with no
/// body/token/key parameter cannot pass one. This class exists only so each
/// facade does not have to re-thread a subsystem name and a clock through every
/// call.
///
/// The clock is injected for the ordinary reason — a deterministic timestamp
/// makes an exported report diffable and a test assertable without freezing real
/// time — and defaults to UTC so records from devices in different zones
/// interleave correctly in one report.
class AikoLogger {
  const AikoLogger({
    required this.subsystem,
    required LogSink sink,
    DateTime Function()? clock,
  }) : _sink = sink,
       _clock = clock;

  /// Dotted name, e.g. `aiko.call.ring`.
  final String subsystem;

  final LogSink _sink;
  final DateTime Function()? _clock;

  DateTime get _now => (_clock ?? DateTime.now)().toUtc();

  void log(
    LogLevel level,
    String event, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => _sink.add(
    LogRecord(
      at: _now,
      subsystem: subsystem,
      level: level,
      event: event,
      fields: fields,
      error: error,
      stackTrace: stackTrace,
    ),
  );

  void debug(String event, {Map<String, Object?> fields = const {}}) =>
      log(LogLevel.debug, event, fields: fields);

  /// INFO takes an [error] too: a caught-and-handled exception is often the
  /// whole content of a benign event ("unregister deferred to next sign-in"),
  /// and forcing those callers down to `log()` would push them toward
  /// stringifying the error into the event name instead — which is exactly the
  /// prose-in-a-machine-name failure the [LogRecord.event] doc warns about.
  void info(
    String event, {
    Map<String, Object?> fields = const {},
    Object? error,
  }) => log(LogLevel.info, event, fields: fields, error: error);

  void warning(
    String event, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    LogLevel.warning,
    event,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
  );

  void severe(
    String event, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    LogLevel.severe,
    event,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
  );

  /// A logger for a child subsystem, e.g. `forSubsystem('ring')` on
  /// `aiko.call` gives `aiko.call.ring`.
  AikoLogger child(String suffix) =>
      AikoLogger(subsystem: '$subsystem.$suffix', sink: _sink, clock: _clock);
}
