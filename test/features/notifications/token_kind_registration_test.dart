// Pins the `token_kind` contract end to end: what goes on the wire, what the
// island must echo back, and what the app does when the echo is not the kind it
// asked for.
//
// WHY THIS IS FAIL-CLOSED AND NOT BEST-EFFORT. A VoIP token registered as an
// `alert` row is not a degraded ring, it is a silent one: the island sends an
// ordinary alert push to a PushKit token, and the handset never rings for a call
// it was told about. Nothing in the app observes that. The only moment the
// mismatch is visible is the 201's echo, so the echo is the check.
//
// THE CASE THIS FILE EXISTS FOR is `an OLD island answers a VoIP register`. Read
// `absent means alert` on the RESPONSE the same way it is read on the REQUEST
// and the two interesting rows fall out of one comparison — an old island is
// fine for an alert token and fatal for a VoIP one.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aiko_chat_app/features/chat/data/gateway_rest_api.dart';
import 'package:aiko_chat_app/features/notifications/domain/device_platform.dart';
import 'package:aiko_chat_app/features/notifications/domain/token_kind.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

/// Captures each request body and answers with a caller-chosen 201 body, so a
/// test can state the island's echo as data rather than as a mock expectation.
class _EchoingAdapter implements HttpClientAdapter {
  _EchoingAdapter(this.bodies, this.echo);
  final List<Map<String, dynamic>> bodies;

  /// The full 201 body this island answers with. Deliberately the WHOLE object
  /// and not just the kind: an island that omits the field is a real island
  /// (every build before the field existed), and it has to be expressible here
  /// or the backward-compatibility row cannot be written.
  final Map<String, dynamic>? echo;

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
    // `null` echo means a 201 with a body we cannot read at all — an empty
    // body, a content-type drift, a proxy that ate it. A real state, and
    // distinct from every key-level state below.
    return jsonBody(201, echo == null ? '' : jsonEncode(echo));
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  (GatewayRestApi, List<Map<String, dynamic>>) island(
    Map<String, dynamic>? echo,
  ) {
    final bodies = <Map<String, dynamic>>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://x'))
      ..httpClientAdapter = _EchoingAdapter(bodies, echo);
    return (GatewayRestApi(bare: dio, authed: dio), bodies);
  }

  Map<String, dynamic> row(String? kind) => {
    'id': 'dev-1',
    'platform': 'apns',
    'apns_environment': 'production',
    'token_kind': ?kind,
  };

  group('what goes on the wire', () {
    test('declares token_kind: voip for a PushKit token', () async {
      final (api, bodies) = island(row('voip'));
      await api.registerDevice(
        platform: DevicePlatform.apns,
        token: 'tok-voip',
        kind: TokenKind.voip,
      );
      expect(bodies.single['token_kind'], 'voip');
    });

    // The SAME rule `apns_environment` follows, and for the same reason: absent
    // is a meaningful value island-side (it resolves to `alert`), so omitting is
    // how a client says "the default" without depending on the default's name.
    test(
      'OMITS token_kind for an alert token rather than sending it',
      () async {
        final (api, bodies) = island(row('alert'));
        await api.registerDevice(
          platform: DevicePlatform.apns,
          token: 'tok-alert',
          kind: TokenKind.alert,
        );
        expect(bodies.single.containsKey('token_kind'), isFalse);
      },
    );
  });

  group('what comes back', () {
    // Success is the ABSENCE of a refusal — `registerDevice` returns nothing,
    // because the only caller already knows the kind it asked for and a bare
    // TokenKind could not say whether the island stated it or we inferred it.
    test('ACCEPTS a voip register the island echoed back as voip', () async {
      final (api, _) = island(row('voip'));
      await expectLater(
        api.registerDevice(
          platform: DevicePlatform.apns,
          token: 'tok-voip',
          kind: TokenKind.voip,
        ),
        completes,
      );
    });

    test('REFUSES a voip register the island resolved to alert', () async {
      final (api, _) = island(row('alert'));
      await expectLater(
        api.registerDevice(
          platform: DevicePlatform.apns,
          token: 'tok-voip',
          kind: TokenKind.voip,
        ),
        throwsA(isA<DeviceKindRefused>()),
      );
    });

    // An island built before the field existed. It stored an alert row for a
    // PushKit token and said nothing about it — the exact silent failure.
    test('REFUSES a voip register an old island did not echo', () async {
      final (api, _) = island(row(null));
      await expectLater(
        api.registerDevice(
          platform: DevicePlatform.apns,
          token: 'tok-voip',
          kind: TokenKind.voip,
        ),
        throwsA(isA<DeviceKindRefused>()),
      );
    });

    // THE DISCRIMINATING ROW. A literal reading of "an absent field in the
    // response means fail closed" would go red here and take every alert
    // registration on every un-upgraded island with it — a working capability
    // deleted to guard one that is not on those islands anyway. Absent means
    // alert on the way back exactly as it does on the way out, and then one
    // comparison decides both rows.
    test('ACCEPTS an alert register an old island did not echo', () async {
      final (api, _) = island(row(null));
      await expectLater(
        api.registerDevice(
          platform: DevicePlatform.apns,
          token: 'tok-alert',
          kind: TokenKind.alert,
        ),
        completes,
      );
    });

    // CARNOT, ROUND 1 — and it is this check committing the very defect it
    // exists to catch. `body?['token_kind']` was null for THREE different
    // worlds, and only one of them is a compatible old island. Collapsing them
    // made the check's SUCCESS value identical to its SAW-NOTHING value.
    test('REFUSES an alert register whose 201 had no readable body', () async {
      final (api, _) = island(null);
      await expectLater(
        api.registerDevice(
          platform: DevicePlatform.apns,
          token: 'tok-alert',
          kind: TokenKind.alert,
        ),
        throwsA(isA<DeviceKindRefused>()),
      );
    });

    // The response schema types `token_kind` non-nullable and REQUIRED, so an
    // explicit null is a contract violation, not an old island being quiet.
    // `Map[]` cannot tell it from an omitted key; `containsKey` can.
    test('REFUSES an explicit token_kind: null — absent and null are not the '
        'same answer', () async {
      final (api, _) = island({
        'id': 'dev-1',
        'platform': 'apns',
        'apns_environment': 'production',
        'token_kind': null,
      });
      await expectLater(
        api.registerDevice(
          platform: DevicePlatform.apns,
          token: 'tok-alert',
          kind: TokenKind.alert,
        ),
        throwsA(isA<DeviceKindRefused>()),
      );
    });

    // A value our enum cannot parse is NOT quietly folded into alert here, even
    // though `fromWire` is total. `fromWire`'s totality serves the debt ledger,
    // where a throw would read as "nothing owed"; on this path an unknown kind
    // means the island resolved to something we have no model of, and pairing a
    // token to a semantics we cannot name is the thing being refused.
    test('REFUSES an echo naming a kind this build has no model of', () async {
      final (api, _) = island(row('critical'));
      await expectLater(
        api.registerDevice(
          platform: DevicePlatform.apns,
          token: 'tok-alert',
          kind: TokenKind.alert,
        ),
        throwsA(isA<DeviceKindRefused>()),
      );
    });
  });
}
