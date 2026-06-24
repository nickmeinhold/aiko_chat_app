import 'dart:async';

import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show Unauthorized;
import 'package:aiko_chat_app/features/chat/data/gateway_rest_api.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart';
import 'package:aiko_chat_app/features/chat/data/transport/gateway_transport.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _seed = AuthTokens(accessToken: 'access0', refreshToken: 'refresh0');

void main() {
  group('DefaultTokenProvider single-flight refresh', () {
    test('concurrent refreshes share ONE remote call (finding 2)', () async {
      var calls = 0;
      final gate = Completer<void>();
      final tp = DefaultTokenProvider(
        store: InMemoryTokenStore(_seed),
        remoteRefresh: (rt) async {
          calls++;
          await gate.future;
          return 'access1';
        },
      );
      final f1 = tp.refreshAccessToken();
      final f2 = tp.refreshAccessToken();
      final f3 = tp.refreshAccessToken();
      gate.complete();
      final results = await Future.wait([f1, f2, f3]);
      expect(calls, 1, reason: 'only one refresh should hit the network');
      expect(results, ['access1', 'access1', 'access1']);
    });

    test('a second refresh AFTER the first completes does run again', () async {
      var calls = 0;
      final tp = DefaultTokenProvider(
        store: InMemoryTokenStore(_seed),
        remoteRefresh: (rt) async {
          calls++;
          return 'access$calls';
        },
      );
      expect(await tp.refreshAccessToken(), 'access1');
      expect(await tp.refreshAccessToken(), 'access2');
      expect(calls, 2);
    });
  });

  group('DefaultTokenProvider success/failure semantics', () {
    test('success caches new access token + writes store', () async {
      final store = InMemoryTokenStore(_seed);
      final tp = DefaultTokenProvider(
        store: store,
        remoteRefresh: (rt) async => 'access1',
      );
      final t = await tp.refreshAccessToken();
      expect(t, 'access1');
      expect(await tp.currentAccessToken(), 'access1');
      expect(store.current?.accessToken, 'access1');
      expect(store.current?.refreshToken, 'refresh0',
          reason: 'refresh token is NOT rotated');
    });

    test('RefreshRejected -> null, clears store, fires onUnauthenticated',
        () async {
      final store = InMemoryTokenStore(_seed);
      var unauth = 0;
      final tp = DefaultTokenProvider(
        store: store,
        onUnauthenticated: () => unauth++,
        remoteRefresh: (rt) async => throw const RefreshRejected(),
      );
      expect(await tp.refreshAccessToken(), isNull);
      expect(store.current, isNull, reason: 'logout clears tokens');
      expect(unauth, 1);
    });

    test('transient error -> THROWS, store NOT cleared (no logout on blip)',
        () async {
      final store = InMemoryTokenStore(_seed);
      var unauth = 0;
      final tp = DefaultTokenProvider(
        store: store,
        onUnauthenticated: () => unauth++,
        remoteRefresh: (rt) async => throw Exception('network down'),
      );
      await expectLater(tp.refreshAccessToken(), throwsA(isA<Exception>()));
      expect(store.current, _seed, reason: 'transient failure keeps tokens');
      expect(unauth, 0, reason: 'a network blip must NOT log out');
    });
  });

  group('AuthInterceptor 401 -> refresh -> retry', () {
    test('401 once -> refresh -> retry succeeds with new token', () async {
      final store = InMemoryTokenStore(_seed);
      final tp = DefaultTokenProvider(
        store: store,
        remoteRefresh: (rt) async => 'access1',
      );
      var call = 0;
      final headersSeen = <String?>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://x'));
      dio.interceptors.add(AuthInterceptor(tp, dio));
      dio.httpClientAdapter = FakeHttpAdapter((opts) {
        call++;
        headersSeen.add(opts.headers['Authorization'] as String?);
        if (call == 1) return jsonBody(401, '{"detail":"expired"}');
        return jsonBody(200, '{"ok":true}');
      });

      final r = await dio.get('/v1/me');
      expect(r.statusCode, 200);
      expect(call, 2);
      expect(headersSeen[0], 'Bearer access0');
      expect(headersSeen[1], 'Bearer access1', reason: 'retry uses new token');
    });

    test('persistent 401 -> retried once then propagates', () async {
      final store = InMemoryTokenStore(_seed);
      final tp = DefaultTokenProvider(
        store: store,
        remoteRefresh: (rt) async => 'access1',
      );
      var call = 0;
      final dio = Dio(BaseOptions(baseUrl: 'http://x'));
      dio.interceptors.add(AuthInterceptor(tp, dio));
      dio.httpClientAdapter =
          FakeHttpAdapter((opts) => (call++, jsonBody(401, '{}')).$2);

      await expectLater(dio.get('/v1/me'), throwsA(isA<DioException>()));
      expect(call, 2, reason: 'original + one retry, no infinite loop');
    });
  });

  group('GatewayRestApi parsing', () {
    GatewayRestApi apiWith(ResponseBody Function(RequestOptions) handler) {
      final bare = Dio(BaseOptions(baseUrl: 'http://x'))
        ..httpClientAdapter = FakeHttpAdapter(handler);
      final authed = Dio(BaseOptions(baseUrl: 'http://x'))
        ..httpClientAdapter = FakeHttpAdapter(handler);
      return GatewayRestApi(bare: bare, authed: authed);
    }

    test('login parses AuthSession', () async {
      final api = apiWith((_) => jsonBody(200,
          '{"access_token":"a","refresh_token":"r","user":{"user_id":"u1","username":"alice","display_name":"Alice","aiko_username":"alice"}}'));
      final s = await api.login('alice', 'pw');
      expect(s.tokens.accessToken, 'a');
      expect(s.user.username, 'alice');
    });

    test('getHistory parses messages + both cursors', () async {
      final api = apiWith((_) => jsonBody(200,
          '{"channel_id":"c1","messages":[{"msg_id":"01J","channel_id":"c1","sender":{"kind":"human","label":"A"},"body":"hi","created_at":"2026-06-21T00:00:00Z","reply_to":null}],"next_before":"01J","next_after":"01K"}'));
      final page = await api.getHistory('c1');
      expect(page.messages.single.body, 'hi');
      expect(page.nextBefore, '01J');
      expect(page.nextAfter, '01K');
    });

    test('getHistory forwards the `after` cursor as a query param', () async {
      RequestOptions? captured;
      final api = apiWith((opts) {
        captured = opts;
        return jsonBody(200, '{"channel_id":"c1","messages":[],"next_after":null}');
      });
      await api.getHistory('c1', after: '01ABC');
      expect(captured!.queryParameters['after'], '01ABC');
      // before is omitted (null-aware element) when not supplied
      expect(captured!.queryParameters.containsKey('before'), isFalse);
    });
  });

  group('authed REST: terminal Unauthorized vs transient 401 (cage-match fix)', () {
    // Full backend WITH the AuthInterceptor in play (apiWith above skips it), so
    // the interceptor's transient-vs-terminal refresh taxonomy is exercised.
    GatewayRestApi backend({
      required Future<String> Function(String) remoteRefresh,
      required int statusCode,
    }) {
      final tokens = DefaultTokenProvider(
          store: InMemoryTokenStore(_seed), remoteRefresh: remoteRefresh);
      ResponseBody handler(RequestOptions _) => jsonBody(statusCode, '{}');
      final authed = Dio(BaseOptions(baseUrl: 'http://x'))
        ..httpClientAdapter = FakeHttpAdapter(handler)
        ..interceptors.add(AuthInterceptor(
            tokens, Dio(BaseOptions(baseUrl: 'http://x'))..httpClientAdapter = FakeHttpAdapter(handler)));
      final bare = Dio(BaseOptions(baseUrl: 'http://x'))
        ..httpClientAdapter = FakeHttpAdapter(handler);
      return GatewayRestApi(bare: bare, authed: authed);
    }

    test('a TERMINAL 401 (refresh rejected) → Unauthorized', () async {
      final api = backend(
          remoteRefresh: (_) async => throw const RefreshRejected(),
          statusCode: 401);
      await expectLater(api.getHistory('c1'), throwsA(isA<Unauthorized>()));
    });

    test('a TRANSIENT 401 (refresh network blip) → NOT Unauthorized — stays a '
        'DioException so rows redrain and the user is not logged out', () async {
      final api = backend(
          remoteRefresh: (_) async => throw Exception('refresh network blip'),
          statusCode: 401);
      await expectLater(
        api.getHistory('c1'),
        throwsA(allOf(isA<DioException>(), isNot(isA<Unauthorized>()))),
      );
    });

    test('a 403 → Unauthorized (terminal; no refresh attempted)', () async {
      final api =
          backend(remoteRefresh: (_) async => 'unused', statusCode: 403);
      await expectLater(api.getHistory('c1'), throwsA(isA<Unauthorized>()));
    });
  });

  group('GatewayTransport demux + send', () {
    DefaultTokenProvider tokens() => DefaultTokenProvider(
          store: InMemoryTokenStore(_seed),
          remoteRefresh: (rt) async => 'access1',
        );

    test('connect passes token in query; frames demux to typed streams',
        () async {
      late FakeWebSocketChannel fake;
      Uri? connectedUri;
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: tokens(),
        channelFactory: (uri) {
          connectedUri = uri;
          return fake = FakeWebSocketChannel();
        },
      );
      await t.connect();
      expect(connectedUri.toString(), 'ws://host/v1/ws?token=access0');

      final gotAck = expectLater(t.acks, emits(predicate<AckResult>(
          (a) => a.clientMsgId == 'tmp1' && a.msgId == '01J')));
      final gotMsg = expectLater(
          t.messages, emits(predicate<Message>((m) => m.body == 'hi')));
      // The raw wire `code` is preserved verbatim AND classified at the parse
      // boundary: an unrecognised code (`bad`) maps to `unknown`, never silently
      // to a known/transient code.
      final gotErr = expectLater(
          t.errors,
          emits(predicate<TransportError>((e) =>
              e.code == 'bad' &&
              e.parsedCode == TransportErrorCode.unknown)));

      fake.emit('{"type":"ack","client_msg_id":"tmp1","msg_id":"01J"}');
      fake.emit(
          '{"type":"message","msg":{"msg_id":"02J","channel_id":"c1","sender":{"kind":"human","label":"A"},"body":"hi","created_at":"2026-06-21T00:00:00Z"}}');
      fake.emit('{"type":"error","code":"bad","detail":"x"}');
      fake.emit('{"type":"typing"}'); // unknown -> dropped, must not crash

      await Future.wait([gotAck, gotMsg, gotErr]);
    });

    test('subscribe + sendMessage write frames to the socket', () async {
      late FakeWebSocketChannel fake;
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: tokens(),
        channelFactory: (uri) => fake = FakeWebSocketChannel(),
      );
      await t.connect();
      final subF = t.subscribe(['c1']);
      fake.emit('{"type":"suback","channel_fences":{"c1":"01J"}}');
      await subF; // resolved by the suback
      final id = t.sendMessage(const OutgoingMessage(
          clientTempId: 'tmp1', channelId: 'c1', body: 'hello'));
      expect(id, 'tmp1');
      expect(fake.sent.any((f) => f.contains('"type":"subscribe"')), isTrue);
      expect(
          fake.sent.any(
              (f) => f.contains('"type":"send"') && f.contains('"body":"hello"')),
          isTrue);
    });

    test('subscribe awaits the suback and returns the per-channel fence map',
        () async {
      late FakeWebSocketChannel fake;
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: tokens(),
        channelFactory: (uri) => fake = FakeWebSocketChannel(),
      );
      await t.connect();
      final subF = t.subscribe(['c1', 'c2']);
      // c2 is an empty channel -> "" fence (no history boundary).
      fake.emit('{"type":"suback","channel_fences":{"c1":"01J","c2":""}}');
      expect(await subF, {'c1': '01J', 'c2': ''});
    });

    test('a suback with no pending subscribe is ignored, not fatal', () async {
      // The transport's reconnect resubscribe fires a frame without an awaiter;
      // its suback must be dropped quietly, never crash the socket or error.
      late FakeWebSocketChannel fake;
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: tokens(),
        channelFactory: (uri) => fake = FakeWebSocketChannel(),
      );
      await t.connect();
      fake.emit('{"type":"suback","channel_fences":{"c1":"01J"}}');
      await Future<void>.delayed(Duration.zero);
      // Socket still usable: a subsequent real subscribe still resolves.
      final subF = t.subscribe(['c1']);
      fake.emit('{"type":"suback","channel_fences":{"c1":"01K"}}');
      expect(await subF, {'c1': '01K'});
    });

    test('an uncorrelated suback does not steal a pending subscribe '
        '(resubscribe-ack race — Carnot)', () async {
      late FakeWebSocketChannel fake;
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: tokens(),
        channelFactory: (uri) => fake = FakeWebSocketChannel(),
      );
      await t.connect();
      final subF = t.subscribe(['c2']);
      // A reconnect resubscribe ack for the OLD {c1} set arrives first. Under
      // blind FIFO this would resolve our c2 call with a c2-less map. Content
      // correlation drops it (it doesn't cover c2).
      fake.emit('{"type":"suback","channel_fences":{"c1":"01A"}}');
      // The real ack for our subscribe (covers c2) arrives next.
      fake.emit('{"type":"suback","channel_fences":{"c1":"01A","c2":"01B"}}');
      expect(await subF, {'c1': '01A', 'c2': '01B'},
          reason: 'must resolve with the ack that actually carries c2');
    });

    test('a pending subscribe rejects when the socket drops before its suback',
        () async {
      late FakeWebSocketChannel fake;
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: tokens(),
        channelFactory: (uri) => fake = FakeWebSocketChannel(),
      );
      await t.connect();
      final subF = t.subscribe(['c1']); // no suback emitted
      fake.closeFromServer(); // drop before the ack arrives
      await expectLater(subF, throwsA(isA<TransportError>()));
    });

    test('connect failure with dead refresh -> unauthenticated', () async {
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: DefaultTokenProvider(
          store: InMemoryTokenStore(_seed),
          remoteRefresh: (rt) async => throw const RefreshRejected(),
        ),
        channelFactory: (uri) =>
            FakeWebSocketChannel(readyError: Exception('refused')),
      );
      final gotUnauth = expectLater(
          t.connectionState, emitsThrough(ConnectionState.unauthenticated));
      await t.connect();
      await gotUnauth;
    });
  });
}
