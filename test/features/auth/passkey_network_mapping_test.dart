// Pins the offline-first correctness fix (PR3): the passkey ceremony paths and
// claimHandle now share the SAME connection-class → NetworkUnavailable mapping
// that me() has — so an offline FIRST sign-in surfaces the domain
// NetworkUnavailable (which the UI turns into "you're offline, reconnect to
// finish"), not a raw DioException rendered as "Sign-in failed: DioException…".
//
// Mirrors me_network_mapping_test's classification: a connection-class failure
// (no response) → NetworkUnavailable; a server that ANSWERED (even an error)
// propagates unchanged, so the mapping never widens the offline-first boundary.

import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:aiko_chat_app/features/chat/data/gateway_rest_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  GatewayRestApi apiThatThrows(DioException e) {
    final dio = Dio(BaseOptions(baseUrl: 'http://x'))
      ..httpClientAdapter = FakeHttpAdapter((_) => throw e);
    return GatewayRestApi(bare: dio, authed: dio);
  }

  GatewayRestApi apiThatAnswers(int status, String body) {
    final dio = Dio(BaseOptions(baseUrl: 'http://x'))
      ..httpClientAdapter = FakeHttpAdapter((_) => jsonBody(status, body));
    return GatewayRestApi(bare: dio, authed: dio);
  }

  DioException conn(String path) => DioException(
    requestOptions: RequestOptions(path: path),
    type: DioExceptionType.connectionError,
    error: 'Failed host lookup',
  );

  group('offline (connection-class, no response) → NetworkUnavailable', () {
    test('startPasskeyRegistration', () async {
      final api = apiThatThrows(conn('/v1/auth/passkey/register/start'));
      await expectLater(
        api.startPasskeyRegistration(),
        throwsA(isA<NetworkUnavailable>()),
      );
    });

    test('startPasskeyAuthentication', () async {
      final api = apiThatThrows(conn('/v1/auth/passkey/authenticate/start'));
      await expectLater(
        api.startPasskeyAuthentication(),
        throwsA(isA<NetworkUnavailable>()),
      );
    });

    test('finishPasskeyRegistration', () async {
      final api = apiThatThrows(conn('/v1/auth/passkey/register/finish'));
      await expectLater(
        api.finishPasskeyRegistration('st', '{"id":"c"}'),
        throwsA(isA<NetworkUnavailable>()),
      );
    });

    test('finishPasskeyAuthentication', () async {
      final api = apiThatThrows(conn('/v1/auth/passkey/authenticate/finish'));
      await expectLater(
        api.finishPasskeyAuthentication('st', '{"id":"c"}'),
        throwsA(isA<NetworkUnavailable>()),
      );
    });

    test('claimHandle', () async {
      final api = apiThatThrows(conn('/v1/auth/social/claim'));
      await expectLater(
        api.claimHandle(provisioningToken: 'p', handle: 'h', displayName: 'd'),
        throwsA(isA<NetworkUnavailable>()),
      );
    });
  });

  // A terminal auth status on a token-less _bare auth call maps to the domain
  // Unauthorized — so the expired-provisioning-token / rejected-assertion path
  // gets friendly copy AND never reaches the UI as a raw DioException whose
  // string could carry the request body (cage-match #74 R2, Carnot + Tesla).
  group('auth-terminal (401/403) on a _bare auth call → Unauthorized', () {
    test(
      'claimHandle 401 (expired provisioning token) → Unauthorized',
      () async {
        final api = apiThatAnswers(401, '{"error":"expired"}');
        await expectLater(
          api.claimHandle(
            provisioningToken: 'p',
            handle: 'h',
            displayName: 'd',
          ),
          throwsA(isA<Unauthorized>()),
        );
      },
    );

    test('claimHandle 403 → Unauthorized', () async {
      final api = apiThatAnswers(403, '{"error":"forbidden"}');
      await expectLater(
        api.claimHandle(provisioningToken: 'p', handle: 'h', displayName: 'd'),
        throwsA(isA<Unauthorized>()),
      );
    });

    test(
      'finishPasskeyAuthentication 401 (rejected assertion) → Unauthorized',
      () async {
        final api = apiThatAnswers(401, '{"error":"bad assertion"}');
        await expectLater(
          api.finishPasskeyAuthentication('st', '{"id":"c"}'),
          throwsA(isA<Unauthorized>()),
        );
      },
    );
  });

  group('a server that ANSWERED is NOT remapped (boundary stays narrow)', () {
    test('claimHandle 409 → HandleTaken, not NetworkUnavailable', () async {
      final api = apiThatAnswers(409, '{"error":"taken"}');
      await expectLater(
        api.claimHandle(provisioningToken: 'p', handle: 'h', displayName: 'd'),
        throwsA(isA<HandleTaken>()),
      );
    });

    test(
      'malformed finish response still fails LOUDLY (FormatException)',
      () async {
        final api = apiThatAnswers(200, '{"unexpected":"shape"}');
        await expectLater(
          api.finishPasskeyRegistration('st', '{"id":"c"}'),
          throwsA(isA<FormatException>()),
        );
      },
    );
  });
}
