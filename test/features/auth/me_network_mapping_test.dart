// Pins the ONLY optimistic-restore door: GatewayRestApi.me() maps a
// connection-class DioException (server unreachable — no response) to the domain
// NetworkUnavailable, while a server that ANSWERED (even an error) propagates
// unchanged so the caller fails closed. If this classification ever widens by
// accident, the offline-first trust boundary widens with it (Tesla, PR #71).

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

  final connReq = RequestOptions(path: '/v1/me');

  test('connection-class failure (no response) → NetworkUnavailable', () async {
    final api = apiThatThrows(DioException(
      requestOptions: connReq,
      type: DioExceptionType.connectionError,
      error: 'Failed host lookup',
    ));
    await expectLater(api.me(), throwsA(isA<NetworkUnavailable>()));
  });

  test('connection timeout (no response) → NetworkUnavailable', () async {
    final api = apiThatThrows(DioException(
      requestOptions: connReq,
      type: DioExceptionType.connectionTimeout,
    ));
    await expectLater(api.me(), throwsA(isA<NetworkUnavailable>()));
  });

  test('server ANSWERED 500 → NOT NetworkUnavailable (fail closed)', () async {
    final api = apiThatAnswers(500, '{"error":"boom"}');
    await expectLater(
        api.me(), throwsA(isA<Object>().having((e) => e is NetworkUnavailable,
            'is NetworkUnavailable', isFalse)));
  });

  test('terminal 401 → Unauthorized (not NetworkUnavailable)', () async {
    final api = apiThatAnswers(401, '{"error":"nope"}');
    await expectLater(api.me(), throwsA(isA<Unauthorized>()));
  });
}
