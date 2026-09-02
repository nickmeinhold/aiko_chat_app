import 'package:aiko_chat_app/core/logging/aiko_log.dart';
import 'package:aiko_chat_app/core/logging/aiko_logger.dart';
import 'package:aiko_chat_app/core/logging/redacting_log_sink.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captures records so a test can assert on them.
class _CapturingSink extends LogSink {
  final records = <LogRecord>[];
  @override
  void add(LogRecord record) => records.add(record);
}

class _ThrowingSink extends LogSink {
  @override
  void add(LogRecord record) => throw StateError('sink is broken');
}

final _at = DateTime.utc(2026, 8, 31, 1, 2, 3);

LogRecord _rec({
  String event = 'e',
  Map<String, Object?> fields = const {},
  Object? error,
}) => LogRecord(
  at: _at,
  subsystem: 'aiko.test',
  level: LogLevel.info,
  event: event,
  fields: fields,
  error: error,
);

void main() {
  group('RingBufferLogSink — the tier a release build reports through', () {
    test('keeps records oldest-first', () {
      final buf = RingBufferLogSink(capacity: 10);
      buf
        ..add(_rec(event: 'a'))
        ..add(_rec(event: 'b'));
      expect(buf.snapshot().map((r) => r.event), ['a', 'b']);
      expect(buf.dropped, 0);
    });

    test('is BOUNDED — drops oldest past capacity and COUNTS the loss', () {
      final buf = RingBufferLogSink(capacity: 3);
      for (final e in ['a', 'b', 'c', 'd', 'e']) {
        buf.add(_rec(event: e));
      }
      expect(buf.snapshot().map((r) => r.event), ['c', 'd', 'e']);
      // The count is the point: a truncated tail must read as truncation, not
      // as "nothing else happened". Silence reading as success is the failure
      // this whole module exists to remove, so the buffer must not reproduce it.
      expect(buf.dropped, 2);
    });

    test('snapshot is a copy — logging during iteration cannot blow up', () {
      final buf = RingBufferLogSink(capacity: 5);
      buf.add(_rec(event: 'a'));
      final snap = buf.snapshot();
      buf.add(_rec(event: 'b'));
      expect(snap.length, 1, reason: 'snapshot must not alias the live queue');
    });
  });

  group('RedactingLogSink — secret-shaped runs never reach a sink', () {
    // POSITIVE CONTROLS. Each is a real token shape from this app's own wire.
    // A scrubber proved only by "the output looked fine" is a check that cannot
    // go red; these force the bad state and assert it was caught.

    test(
      'cuts a 64-hex APNs device token, keeping 12 chars for correlation',
      () {
        const token =
            'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
        final out = RedactingLogSink.redact('token=$token');
        expect(out, 'token=a1b2c3d4e5f6…');
        expect(out.contains(token), isFalse, reason: 'the full token leaked');
      },
    );

    test('cuts a long FCM-shaped registration token', () {
      const token =
          'dX1sAbCdEfGhIjKlMnOpQr:APA91bHqZzYyXxWwVvUuTtSsRrQqPpOoNnMmLlKkJjIi'
          'HhGgFfEeDdCcBbAa0987654321';
      final out = RedactingLogSink.redact('t=$token');
      expect(out.contains(token), isFalse, reason: 'the full token leaked');
      expect(out, contains('…'));
    });

    // NEGATIVE CONTROL — the arm that catches a redactor which simply blanks
    // everything. A ULID is 26 chars of Crockford base32 and is THE correlation
    // key for messages; if it were eaten, the log would be safe and useless, and
    // every other test here would still pass.
    test('leaves a 26-char ULID intact — it is the correlation key', () {
      const ulid = '01J9ZQ8K3M7NPQR5TVWXYZ0123';
      expect(ulid.length, 26, reason: 'guard: fixture must really be a ULID');
      expect(RedactingLogSink.redact('ulid=$ulid'), 'ulid=$ulid');
    });

    test('leaves short hex (a colour, a status code) intact', () {
      expect(RedactingLogSink.redact('rgb=ff00aa n=404'), 'rgb=ff00aa n=404');
    });

    test('redacts inside FIELD VALUES, not just formatted text', () {
      const token =
          'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
      final inner = _CapturingSink();
      RedactingLogSink(inner).add(_rec(fields: {'token': token}));
      expect(inner.records.single.fields['token'], 'a1b2c3d4e5f6…');
    });

    test('projects an error to its TYPE, never its string', () {
      // The measured reason (cage-match #74): a DioException's toString() can
      // carry the request body, which on the claim path holds a
      // provisioning_token, the handle and the display name. Redacting that
      // string would be defence in the wrong place — it must not be stringified.
      final inner = _CapturingSink();
      RedactingLogSink(
        inner,
      ).add(_rec(error: FormatException('secret-value-in-here')));
      final logged = inner.records.single.error.toString();
      expect(logged, 'FormatException');
      expect(logged, isNot(contains('secret-value-in-here')));
    });
  });

  group('FanOutLogSink', () {
    test('a throwing sink does not stop the others, and does not propagate', () {
      // Turning logging ON must not introduce crashes on paths that were fine,
      // or everyone learns to turn it off.
      final good = _CapturingSink();
      final fan = FanOutLogSink([_ThrowingSink(), good]);
      expect(() => fan.add(_rec()), returnsNormally);
      expect(good.records, hasLength(1));
    });
  });

  group('AikoLogger', () {
    test('stamps subsystem, level and injected clock', () {
      final sink = _CapturingSink();
      AikoLogger(
        subsystem: 'aiko.call',
        sink: sink,
        clock: () => _at,
      ).warning('ring.refused', fields: {'reason': 'stale'});
      final r = sink.records.single;
      expect(r.subsystem, 'aiko.call');
      expect(r.level, LogLevel.warning);
      expect(r.event, 'ring.refused');
      expect(r.fields['reason'], 'stale');
      expect(r.at, _at);
    });

    test('child() nests the subsystem name', () {
      final sink = _CapturingSink();
      AikoLogger(
        subsystem: 'aiko.call',
        sink: sink,
        clock: () => _at,
      ).child('ring').info('x');
      expect(sink.records.single.subsystem, 'aiko.call.ring');
    });

    test('NoopLogSink records nothing — tests stay silent by default', () {
      expect(() => const NoopLogSink().add(_rec()), returnsNormally);
    });
  });

  group('LogRecord.format', () {
    test('is deterministic in field order', () {
      final line = _rec(
        event: 'ring.refused',
        fields: {'reason': 'stale', 'ageMs': 42},
      ).format();
      expect(
        line,
        '2026-08-31T01:02:03.000Z INFO aiko.test ring.refused '
        'reason=stale ageMs=42',
      );
    });
  });
}
