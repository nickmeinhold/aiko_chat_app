// Pins GatewayRestApi.openDm's error mapping (POST /v1/dm find-or-create). The
// 404-branch (target isn't a real user → DmTargetNotFound) lives OUTSIDE
// _authedCall, mirroring requestVideoToken's video-specific 404 branch, so it
// needs its own pin: a regression would re-surface a raw DioException or
// mis-map it to a logout (cage-match Tesla #6).

import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:aiko_chat_app/features/chat/data/gateway_rest_api.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  GatewayRestApi apiThatAnswers(int status, String body) {
    final dio = Dio(BaseOptions(baseUrl: 'http://x'))
      ..httpClientAdapter = FakeHttpAdapter((_) => jsonBody(status, body));
    return GatewayRestApi(bare: dio, authed: dio);
  }

  GatewayRestApi apiThatThrows(DioException e) {
    final dio = Dio(BaseOptions(baseUrl: 'http://x'))
      ..httpClientAdapter = FakeHttpAdapter((_) => throw e);
    return GatewayRestApi(bare: dio, authed: dio);
  }

  test('200 → Channel with the DM id + kind', () async {
    final api = apiThatAnswers(200, '{"channel_id":"dm:a:b","kind":"dm"}');
    final c = await api.openDm('peer-key');
    expect(c.id, 'dm:a:b');
    expect(c.kind, ChannelKind.dm);
  });

  test('404 (no such user) → DmTargetNotFound (NOT a logout)', () async {
    final api = apiThatAnswers(404, '{"error":"no such user"}');
    await expectLater(api.openDm('ghost'), throwsA(isA<DmTargetNotFound>()));
    // And specifically NOT the terminal-auth type that would eject the session.
    await expectLater(
      api.openDm('ghost'),
      throwsA(
        isA<Object>().having(
          (e) => e is Unauthorized,
          'is Unauthorized',
          isFalse,
        ),
      ),
    );
  });

  test('terminal 401 → Unauthorized', () async {
    final api = apiThatAnswers(401, '{"error":"nope"}');
    await expectLater(api.openDm('peer'), throwsA(isA<Unauthorized>()));
  });

  test('connection-class failure → NetworkUnavailable', () async {
    final api = apiThatThrows(
      DioException(
        requestOptions: RequestOptions(path: '/v1/dm'),
        type: DioExceptionType.connectionError,
        error: 'Failed host lookup',
      ),
    );
    await expectLater(api.openDm('peer'), throwsA(isA<NetworkUnavailable>()));
  });
}
