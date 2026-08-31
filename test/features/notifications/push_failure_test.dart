import 'package:aiko_chat_app/core/logging/aiko_log.dart';
import 'package:aiko_chat_app/core/logging/aiko_logger.dart';
import 'package:aiko_chat_app/core/logging/redacting_log_sink.dart';
import 'package:aiko_chat_app/features/notifications/application/push_telemetry.dart';
import 'package:aiko_chat_app/features/notifications/domain/push_failure.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// A SYNTHETIC token of the right SHAPE — 64 hex characters, which is what an
/// APNs device token is — so the leak assertions exercise something the
/// redactor would actually catch, rather than a short stand-in it would ignore.
///
/// Deliberately not derived from any real token. A first draft of this file
/// built the fixture from the leading bytes of a production device token read
/// out of the island database; a staged-diff scan caught it before the commit.
/// A recognisable prefix is still production data, and git history is forever.
const _secret =
    'deadbeef0000000000000000000000000000000000000000000000000000cafe';

DioException _dio(DioExceptionType type, {int? status, String? body}) {
  final req = RequestOptions(path: '/v1/devices');
  return DioException(
    requestOptions: req,
    type: type,
    message: 'failed for token $_secret',
    response: status == null
        ? null
        : Response<dynamic>(
            requestOptions: req,
            statusCode: status,
            data: body ?? {'token': _secret},
          ),
  );
}

class _Capture extends LogSink {
  final records = <LogRecord>[];
  @override
  void add(LogRecord record) => records.add(record);
}

void main() {
  group('classification is from CLOSED inputs only', () {
    test('transport failures map to their own transient reasons', () {
      expect(PushFailure.of(_dio(DioExceptionType.connectionError)),
          PushFailure.unreachable);
      expect(PushFailure.of(_dio(DioExceptionType.connectionTimeout)),
          PushFailure.timedOut);
      expect(PushFailure.of(_dio(DioExceptionType.sendTimeout)),
          PushFailure.timedOut);
      expect(PushFailure.of(_dio(DioExceptionType.receiveTimeout)),
          PushFailure.timedOut);
      expect(PushFailure.of(_dio(DioExceptionType.cancel)),
          PushFailure.cancelled);
      expect(PushFailure.of(_dio(DioExceptionType.badCertificate)),
          PushFailure.badCertificate);
    });

    test('a dead credential is distinguishable from every other 4xx', () {
      expect(
          PushFailure.of(_dio(DioExceptionType.badResponse, status: 401)),
          PushFailure.credentialRejected);
      expect(
          PushFailure.of(_dio(DioExceptionType.badResponse, status: 403)),
          PushFailure.credentialRejected);
      // NOT credentialRejected — a 400 is our bug, not a dead session.
      expect(PushFailure.of(_dio(DioExceptionType.badResponse, status: 400)),
          PushFailure.rejected);
      expect(PushFailure.of(_dio(DioExceptionType.badResponse, status: 404)),
          PushFailure.rejected);
    });

    test('the RETRYABLE 4xx are not collapsed into permanent rejection', () {
      // Carnot + Tesla, independently, round 1. Both 408 and 429 mean an
      // identical retry can succeed — the exact fact this enum exists to carry.
      expect(PushFailure.of(_dio(DioExceptionType.badResponse, status: 429)),
          PushFailure.rateLimited);
      expect(PushFailure.rateLimited.transient, isTrue);
      expect(PushFailure.of(_dio(DioExceptionType.badResponse, status: 408)),
          PushFailure.timedOut);
      expect(PushFailure.timedOut.transient, isTrue);
      // ...and they must not have been fixed by making the 4xx arm transient.
      expect(PushFailure.of(_dio(DioExceptionType.badResponse, status: 400))
          .transient, isFalse);
    });

    test('5xx is the island failing, and is worth retrying', () {
      expect(PushFailure.of(_dio(DioExceptionType.badResponse, status: 500)),
          PushFailure.islandError);
      expect(PushFailure.of(_dio(DioExceptionType.badResponse, status: 503)),
          PushFailure.islandError);
      expect(PushFailure.islandError.transient, isTrue);
    });

    test('a non-Dio error is unknown, and unknown FAILS OPEN', () {
      expect(PushFailure.of(StateError('boom')), PushFailure.unknown);
      expect(PushFailure.of(null), PushFailure.unknown);
      // Weak-signal capture fails OPEN: an unclassifiable failure must not be
      // reported as permanent, because that would licence giving up on a debt
      // we cannot prove is unpayable.
      expect(PushFailure.unknown.transient, isTrue,
          reason: 'unknown must never read as a permanent failure');
    });
  });

  group('the facts the enum carries', () {
    test('exactly one reason means the credential is dead', () {
      final lost =
          PushFailure.values.where((f) => f.credentialIsDead).toList();
      expect(lost, [PushFailure.credentialRejected],
          reason: 'credentialIsDead is the flag that answers "can a retry ever '
              'work?" — if it spreads, it stops meaning anything');
    });

    test('a dead credential is never also transient', () {
      for (final f in PushFailure.values) {
        if (f.credentialIsDead) {
          expect(f.transient, isFalse,
              reason: '${f.name} claims both a dead credential and a '
                  'worthwhile retry, which cannot both be true');
        }
      }
    });
  });

  group('the reason cannot carry a secret BY CONSTRUCTION', () {
    test('every classifiable failure yields a name with no payload in it', () {
      for (final type in DioExceptionType.values) {
        final f = PushFailure.of(_dio(type, status: 401));
        expect(f.name.contains(_secret), isFalse);
        expect(f.name, matches(RegExp(r'^[a-zA-Z]+$')),
            reason: 'a reason name must be a bare identifier — anything else '
                'means a value reached it');
      }
    });

    test('POSITIVE CONTROL: the secret really is in the exception we passed',
        () {
      // Without this, the assertion above passes just as happily against an
      // exception that never carried a secret at all — a check that cannot
      // go red.
      final e = _dio(DioExceptionType.badResponse, status: 401);
      expect(e.toString().contains(_secret), isTrue,
          reason: 'the fixture must actually carry the secret, or the '
              'no-leak assertions prove nothing');
    });

    // THE GUARD THAT ACTUALLY GUARDS. Captures the record BEFORE the redactor.
    //
    // The first version of this test wrapped the capture sink in
    // RedactingLogSink and asserted on the rendered line. That check could not
    // go red: if `_why` interpolated the exception, the redactor would trim the
    // token-shaped run and the assertion would stay green. Verified empirically
    // — a genuine `'\${f.name}:\$error'` mutation passed 9/9 through the
    // redacted path. The verifier shared a layer with the thing it verified,
    // which is the exact defect the PR body claimed to have avoided.
    //
    // (The mutation that supposedly proved the old test worked was ALSO broken:
    // a shell-escaping slip wrote an escaped dollar, so it never interpolated
    // and went red only by breaking a substring match. A red for the wrong
    // reason manufactures confidence — worse than no proof at all.)
    test('RAW fields carry no payload — asserted BEFORE redaction', () {
      final capture = _Capture();
      // NO RedactingLogSink. If the reason ever carries the secret, it arrives
      // here intact and this test fails, which is the whole point.
      final log = AikoLogger(subsystem: 'aiko', sink: capture);
      PushTelemetry(log.child('push')).unregisterDeferred(
        _dio(DioExceptionType.badResponse, status: 401),
      );

      expect(capture.records, hasLength(1));
      final r = capture.records.single;
      expect(r.event, 'push.unregister.deferred');
      expect(r.fields['reason'], 'credentialRejected');
      expect(r.fields['transient'], isFalse);
      expect(r.fields['credentialIsDead'], isTrue,
          reason: 'both facts the type carries must reach the record — a '
              'consumer must never reverse-map the enum NAME back into a fact');
      // Every field value, unredacted, must be free of the payload.
      for (final e in r.fields.entries) {
        expect(e.value.toString().contains(_secret), isFalse,
            reason: 'field ${e.key} carried the token into the record');
      }
    });

    test('and the rendered line is still correct through the real sink', () {
      final capture = _Capture();
      final log = AikoLogger(
        subsystem: 'aiko',
        sink: RedactingLogSink(capture),
      );
      PushTelemetry(log.child('push')).unregisterDeferred(
        _dio(DioExceptionType.badResponse, status: 401),
      );
      final line = capture.records.single.format();
      expect(line, contains('push.unregister.deferred'));
      expect(line, contains('reason=credentialRejected'));
      expect(line, contains('transient=false'));
      expect(line, contains('credentialIsDead=true'));
    });
  });
}
