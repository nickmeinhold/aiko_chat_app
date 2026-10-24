import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'aiko_log.dart';
import 'aiko_logger.dart';
import 'redacting_log_sink.dart';

/// The on-device ring of recent records — what a shipped build reports through.
///
/// Deliberately NOT `autoDispose`: the buffer's whole job is to still be holding
/// the run-up to a failure at the moment the user decides to report it, which is
/// always after the screen that caused it has gone. An autoDisposed buffer would
/// be empty exactly when it was needed.
///
/// 500 records is roughly a session's worth of the events we log (state
/// transitions and refusals, not per-frame chatter) and a few hundred KB at
/// most.
final logBufferProvider = Provider<RingBufferLogSink>(
  (_) => RingBufferLogSink(capacity: 500),
);

/// The production sink.
///
/// ORDER MATTERS AND IS THE SECURITY PROPERTY: redaction wraps the fan-out, so
/// it runs ONCE, before either destination sees the record. Putting a redactor
/// on each branch instead would mean a future third branch could be added
/// without one — and the branch that would leak is the buffer, because that is
/// the one whose contents a user hands to somebody else.
final logSinkProvider = Provider<LogSink>(
  (ref) => RedactingLogSink(
    FanOutLogSink([
      const DeveloperLogSink(),
      ref.watch(logBufferProvider),
      const ConsoleLogSink(subsystems: kConsoleSubsystems),
    ]),
  ),
);

/// What reaches the platform console (logcat / unified log) in a RELEASE
/// build (#223): the ring, the call, push delivery, boot, and the island
/// transport whose silent death left a ringing phone that could not join
/// (#392). Every one logs scalars and opaque ids only, by facade signature.
const kConsoleSubsystems = [
  'aiko.boot',
  'aiko.call',
  'aiko.push',
  'aiko.transport',
];

/// Root logger. Subsystem facades take `ref.watch(rootLoggerProvider).child(...)`.
final rootLoggerProvider = Provider<AikoLogger>(
  (ref) => AikoLogger(subsystem: 'aiko', sink: ref.watch(logSinkProvider)),
);
