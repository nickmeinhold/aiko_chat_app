// Pins the `push_environment` field end to end — the enum's wire strings, and
// the two shapes of the register body that the island tells apart.
//
// The failure this exists to catch is SILENT IN BOTH DIRECTIONS. A wrong value
// sends a TestFlight handset's production token to the sandbox APNs host, which
// answers a bare 400 and never rings; a present-but-null key is out-of-set at
// the island's boundary and 422s the whole registration. Neither surfaces
// anywhere in the app (claude-tasks#3450, island #3386).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aiko_chat_app/features/chat/data/gateway_rest_api.dart';
import 'package:aiko_chat_app/features/notifications/domain/device_platform.dart';
import 'package:aiko_chat_app/features/notifications/domain/push_environment.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

/// Reads the ENCODED REQUEST BYTES, which is the layer at which "sent as null"
/// and "omitted" stop looking the same. `options.data` at the adapter is still
/// the Dart map we handed dio — asserting on that would pass even if the
/// encoder dropped or added the key on its way out.
class _BodyCapturingAdapter implements HttpClientAdapter {
  _BodyCapturingAdapter(this.bodies);
  final List<Map<String, dynamic>> bodies;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final chunks = await requestStream!.toList();
    bodies.add(
      jsonDecode(utf8.decode(chunks.expand((c) => c).toList()))
          as Map<String, dynamic>,
    );
    return jsonBody(204, '{}');
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('PushEnvironment wire strings', () {
    // Verified against the DEPLOYED island rather than the design note:
    // `/openapi.json` -> components.schemas.PushEnvironment.enum is
    // ["sandbox", "production"], and alembic 0023 pins the DB CHECK to the same
    // pair. Asserted rather than derived from `name` so a rename cannot start
    // sending a value that fails the constraint.
    test('are exactly what the island accepts', () {
      expect(PushEnvironment.sandbox.wire, 'sandbox');
      expect(PushEnvironment.production.wire, 'production');
    });

    // THE BUG THIS PINS. Apple's entitlement says `development`; the island's
    // closed set says `sandbox`. `production` collides between the two, so
    // passing Apple's string through unchanged is correct on the release path
    // and 422s the ENTIRE registration on the debug one — which is every build
    // that has ever been tested against a real ring.
    test('translate Apple\'s aps-environment, never pass it through', () {
      expect(
        PushEnvironment.fromApsEnvironment('development'),
        PushEnvironment.sandbox,
      );
      expect(
        PushEnvironment.fromApsEnvironment('production'),
        PushEnvironment.production,
      );
      expect(
        PushEnvironment.values.map((e) => e.wire),
        isNot(contains('development')),
        reason:
            'the island rejects `development` at a DB CHECK — it must never be '
            'reachable as an outbound wire value',
      );
    });

    test('an unknown or absent value is null, never a guess', () {
      expect(PushEnvironment.fromApsEnvironment(null), isNull);
      expect(PushEnvironment.fromApsEnvironment(''), isNull);
      expect(PushEnvironment.fromApsEnvironment('Development'), isNull);
      expect(PushEnvironment.fromApsEnvironment('sandbox'), isNull);
    });
  });

  group('POST /v1/devices body', () {
    /// Captures the JSON body of the one request the api makes.
    (GatewayRestApi, List<Map<String, dynamic>>) capturing() {
      final bodies = <Map<String, dynamic>>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://x'))
        ..httpClientAdapter = _BodyCapturingAdapter(bodies);
      return (GatewayRestApi(bare: dio, authed: dio), bodies);
    }

    test('carries push_environment when the platform declared one', () async {
      final (api, bodies) = capturing();
      await api.registerDevice(
        platform: DevicePlatform.apns,
        token: 'tok-1',
        pushEnvironment: PushEnvironment.production,
      );
      expect(bodies.single, {
        'platform': 'apns',
        'token': 'tok-1',
        'push_environment': 'production',
      });
    });

    test('OMITS the key when null — it is not sent as null', () async {
      final (api, bodies) = capturing();
      await api.registerDevice(platform: DevicePlatform.fcm, token: 'tok-2');
      expect(bodies.single.containsKey('push_environment'), isFalse);
      expect(bodies.single, {'platform': 'fcm', 'token': 'tok-2'});
    });
  });
}
