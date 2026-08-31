/// App-wide structured logging — the seam a RELEASE build can report through.
///
/// ## Why this exists at all
///
/// Before this, the app had 40 `debugPrint` calls and one good-but-local
/// telemetry interface. `debugPrint` writes to stdout and `developer.log` needs
/// a VM service attached, so **neither is observable in a shipped build on a
/// real handset** — there was no channel by which the app in a user's hand could
/// say what it did. That is not "under-logged"; it is unobservable by
/// construction, and it cost a four-hour diagnosis that had to proceed from the
/// island's access log plus the user's eyes (claude-tasks#3591).
///
/// ## The shape, and why it is two layers rather than one
///
/// [LogSink] is a TRANSPORT and nothing else. Feature code is not expected to
/// call it directly — it calls a per-subsystem typed facade (the pattern
/// `ChatTelemetry` already established), and the facade calls this.
///
/// That split is the redaction discipline, not an aesthetic. A facade method
/// like `originVerificationFailed({required String channelId, ...})` cannot log
/// a message body, because there is no parameter for one: the never-log rule is
/// a property of the SIGNATURE rather than a convention each call site must
/// remember. A single `log(String)` would put that rule back in the hands of
/// whoever writes the next format string.
///
/// See [RedactingLogSink] for the second, independent layer.
library;

import 'dart:collection';
import 'dart:developer' as developer;

/// Severity, using the `logging` package's numeric convention so records
/// interleave sensibly with [LoggingChatTelemetry]'s existing `developer.log`
/// levels (INFO 800 / WARNING 900 / SEVERE 1000) rather than starting a second,
/// conflicting scale.
enum LogLevel {
  debug(500),
  info(800),
  warning(900),
  severe(1000);

  const LogLevel(this.value);

  /// The numeric level handed to `dart:developer`.
  final int value;
}

/// One structured record.
///
/// [event] is a STABLE, machine-readable name (`ring.refused`, not "the ring was
/// refused because…"). Prose goes nowhere near it: the whole point of a named
/// event is that a reader grepping an exported report can count occurrences and
/// correlate them without parsing English that a later edit will reword.
///
/// [fields] carries opaque correlation ids and scalars. It is `Object?` rather
/// than a sealed value type deliberately — a sealed type would force every
/// caller through a constructor that a determined caller could still smuggle a
/// body through (`LogValue.id(message.body)` type-checks), so it would buy
/// ceremony rather than safety. The real enforcement is the facade layer above
/// and [RedactingLogSink] below.
class LogRecord {
  LogRecord({
    required this.at,
    required this.subsystem,
    required this.level,
    required this.event,
    this.fields = const {},
    this.error,
    this.stackTrace,
  });

  /// UTC, injected by the logger's clock so tests are deterministic.
  final DateTime at;

  /// Dotted subsystem name, e.g. `aiko.call.ring`.
  final String subsystem;

  final LogLevel level;

  /// Stable machine-readable event name.
  final String event;

  final Map<String, Object?> fields;
  final Object? error;
  final StackTrace? stackTrace;

  /// One line, stable field order (insertion order of [fields]).
  ///
  /// Deterministic on purpose: this string lands in a user-shared problem report
  /// and in test expectations, and a map with nondeterministic iteration order
  /// would make both flaky in a way that reads as a real defect.
  String format() {
    final b = StringBuffer()
      ..write(at.toIso8601String())
      ..write(' ')
      ..write(level.name.toUpperCase())
      ..write(' ')
      ..write(subsystem)
      ..write(' ')
      ..write(event);
    for (final e in fields.entries) {
      b.write(' ${e.key}=${e.value}');
    }
    if (error != null) b.write(' error=$error');
    return b.toString();
  }
}

/// Where records go. Implementations must NEVER throw: a logging failure that
/// takes down the path it was observing is worse than the missing log, and it
/// would be a swallowed failure of exactly the kind this module exists to end.
abstract class LogSink {
  const LogSink();

  void add(LogRecord record);
}

/// The silent default, so tests and any un-wired path stay quiet.
///
/// Mirrors `_NoopTelemetry`. Note the hazard that pattern already caused once:
/// production fell back to the no-op and swallowed every must-be-seen signal
/// until a cage-match caught it (PR #45, Carnot). `provider_wiring_test.dart`
/// pins the production default against exactly that regression.
class NoopLogSink extends LogSink {
  const NoopLogSink();

  @override
  void add(LogRecord record) {}
}

/// Routes to `dart:developer` — visible in the IDE console and DevTools.
///
/// Debug/profile only in practice. It is NOT the release channel and must not be
/// mistaken for one; [RingBufferLogSink] is what a shipped build can report
/// through.
class DeveloperLogSink extends LogSink {
  const DeveloperLogSink();

  @override
  void add(LogRecord record) => developer.log(
    record.format(),
    name: record.subsystem,
    level: record.level.value,
    error: record.error,
    stackTrace: record.stackTrace,
  );
}

/// A bounded, in-memory ring of the most recent records — the tier a RELEASE
/// build can actually report through.
///
/// BOUNDED IS THE POINT. An unbounded buffer on a long-lived chat session is a
/// memory leak that grows with usage and fails on the devices least able to
/// afford it. [capacity] records are kept and the oldest is dropped; the
/// [dropped] count is preserved and reported, so a truncated tail is legible as
/// truncation rather than silently reading as "nothing else happened" — which is
/// the silence-reads-as-success failure this whole module exists to remove.
class RingBufferLogSink extends LogSink {
  RingBufferLogSink({this.capacity = 500})
    : assert(capacity > 0, 'a zero-capacity buffer records nothing');

  final int capacity;
  final Queue<LogRecord> _records = Queue<LogRecord>();

  /// How many records fell off the back. Never reset by [snapshot].
  int get dropped => _dropped;
  int _dropped = 0;

  @override
  void add(LogRecord record) {
    _records.addLast(record);
    while (_records.length > capacity) {
      _records.removeFirst();
      _dropped++;
    }
  }

  /// Oldest first. A copy — a caller iterating this while the app logs must not
  /// hit a concurrent-modification error on the diagnostic path.
  List<LogRecord> snapshot() => List.unmodifiable(_records);

  void clear() {
    _records.clear();
    _dropped = 0;
  }
}

/// Fans one record out to several sinks.
///
/// A throwing sink must not stop the others, and must not propagate into the
/// caller: the alternative is that turning logging ON introduces crashes on
/// paths that were previously fine, which would teach everyone to turn it off.
class FanOutLogSink extends LogSink {
  const FanOutLogSink(this._sinks);

  final List<LogSink> _sinks;

  @override
  void add(LogRecord record) {
    for (final s in _sinks) {
      try {
        s.add(record);
      } catch (_) {
        // Deliberately swallowed — see the class doc. There is nowhere safe to
        // report a logging failure except logging.
      }
    }
  }
}
