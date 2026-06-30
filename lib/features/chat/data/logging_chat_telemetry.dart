import 'dart:developer' as developer;

import 'chat_repository.dart';

/// Production [ChatTelemetry] — routes the reconcile engine's "must be seen,
/// never swallowed" events to `dart:developer` structured logs (visible in the
/// IDE console + DevTools timeline). Without this, [ChatRepository] falls back
/// to the silent `_NoopTelemetry` default and every signal — including the loud
/// [historySyncFault] (#16) — is swallowed in the shipped app.
///
/// Levels follow the `logging` package convention (INFO=800, WARNING=900,
/// SEVERE=1000): a benign visibility-shrink gap is INFO; a persisting sync fault
/// or a failed cache write is SEVERE.
class LoggingChatTelemetry extends ChatTelemetry {
  const LoggingChatTelemetry();

  static const String _name = 'aiko.chat.reconcile';

  @override
  void orphanAck(String clientMsgId, String serverUlid) => developer.log(
        'orphan ack (unreachable in Phase 1): client=$clientMsgId '
        'server=$serverUlid',
        name: _name,
        level: 900,
      );

  @override
  void reconnectFailed(Object error, StackTrace stack) => developer.log(
        'reconnect choreography failed',
        name: _name,
        level: 1000,
        error: error,
        stackTrace: stack,
      );

  @override
  void historyGapBeforeFence(String channelId, String? cursor, String fence) =>
      developer.log(
        'history gap before fence (benign visibility shrink): '
        'channel=$channelId cursor=$cursor fence=$fence',
        name: _name,
        level: 800,
      );

  @override
  void historySyncFault(
          String channelId, String? cursor, String fence, int streak) =>
      // The loud #16 signal: a fence unreachable across [streak] sync attempts
      // is no longer a benign shrink. Logged at SEVERE so it surfaces distinctly
      // from the INFO-level benign gap. NOTE: fires once per sync attempt WHILE
      // the gap persists (the signal reflects ongoing state) — any destructive
      // remediation a consumer wires (e.g. a forced full resync) MUST debounce.
      developer.log(
        'SYNC FAULT — fence unreachable across $streak sync attempts: '
        'channel=$channelId cursor=$cursor fence=$fence. History may be '
        'incomplete; a full resync may be required.',
        name: _name,
        level: 1000,
      );

  @override
  void inboundWriteFailed(Object error, StackTrace stack) => developer.log(
        'inbound (W3) cache write failed',
        name: _name,
        level: 1000,
        error: error,
        stackTrace: stack,
      );
}
