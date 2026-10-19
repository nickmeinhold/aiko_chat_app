import 'package:aiko_chat_app/core/logging/aiko_log.dart';
import 'package:aiko_chat_app/core/logging/aiko_logger.dart';
import 'package:aiko_chat_app/core/logging/redacting_log_sink.dart';
import 'package:flutter_test/flutter_test.dart';

LogRecord _rec(String subsystem, {Map<String, Object?> fields = const {}}) =>
    LogRecord(
      at: DateTime.utc(2026, 10, 19),
      subsystem: subsystem,
      level: LogLevel.info,
      event: 'e',
      fields: fields,
    );

void main() {
  test('prints allowlisted subsystems and their children, nothing else', () {
    final lines = <String>[];
    final sink = ConsoleLogSink(
      subsystems: const ['aiko.call', 'aiko.transport'],
      printer: lines.add,
    );

    sink.add(_rec('aiko.call'));
    sink.add(_rec('aiko.call.ring'));
    sink.add(_rec('aiko.transport'));
    sink.add(_rec('aiko.callx')); // not a dotted child
    sink.add(_rec('aiko.chat'));
    sink.add(_rec('aiko'));

    expect(lines, hasLength(3));
    expect(lines.first, startsWith('[aiko] 2026-10-19T00:00:00.000Z INFO'));
    expect(lines.map((l) => l.split(' ')[3]), [
      'aiko.call',
      'aiko.call.ring',
      'aiko.transport',
    ]);
  });

  test('behind the redactor, a token never reaches the console', () {
    final lines = <String>[];
    final log = AikoLogger(
      subsystem: 'aiko.push',
      sink: RedactingLogSink(
        ConsoleLogSink(subsystems: const ['aiko.push'], printer: lines.add),
      ),
    );
    const token =
        'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';

    log.info('push.registered', fields: {'t': token});

    expect(lines, hasLength(1));
    expect(lines.single, isNot(contains(token)));
    expect(lines.single, contains('t=a1b2c3d4e5f6…'));
  });
}
