import 'dart:async';

import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show
        AccountSuspended,
        Forbidden,
        MessageHistoryItem,
        RetractionHistoryItem,
        Unauthorized;
import 'package:aiko_chat_app/features/chat/data/gateway_rest_api.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart';
import 'package:aiko_chat_app/features/chat/data/transport/gateway_transport.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/domain/origin_envelope.dart';
import 'dart:typed_data';

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

    test('getHistory parses messages + both cursors', () async {
      final api = apiWith((_) => jsonBody(200,
          '{"channel_id":"c1","messages":[{"msg_id":"01J","channel_id":"c1","sender":{"kind":"human","label":"A"},"body":"hi","created_at":"2026-06-21T00:00:00Z","reply_to":null}],"next_before":"01J","next_after":"01K"}'));
      final page = await api.getHistory('c1');
      expect((page.items.single as MessageHistoryItem).message.body, 'hi');
      expect(page.nextBefore, '01J');
      expect(page.nextAfter, '01K');
    });

    test('getHistory parses a HETEROGENEOUS page: message + typed message + '
        'retraction, and SKIPS an unknown future type (island #104)', () async {
      // A page interleaving: a legacy untyped message, a {"type":"message"} item,
      // a retraction, and a future {"type":"reaction"} the island might add. The
      // unknown type must be SKIPPED (not throw) — the recast's single forward
      // stream will grow item types, and a hard parse would wedge history
      // catch-up (re-strike D7-A2).
      final api = apiWith((_) => jsonBody(200, '''
        {"channel_id":"c1","messages":[
          {"msg_id":"01A","channel_id":"c1","sender":{"kind":"human","label":"A"},"body":"legacy","created_at":"2026-06-21T00:00:00Z","reply_to":null},
          {"type":"message","msg_id":"01B","channel_id":"c1","sender":{"kind":"human","label":"A"},"body":"typed","created_at":"2026-06-21T00:00:01Z","reply_to":null},
          {"type":"retraction","id":"01C","target_msg_id":"01A","channel_id":"c1"},
          {"type":"reaction","id":"01D","emoji":"x"}
        ],"next_after":"01D"}'''));
      final page = await api.getHistory('c1');
      expect(page.items.length, 3, reason: 'the unknown "reaction" is skipped');
      expect((page.items[0] as MessageHistoryItem).message.body, 'legacy');
      expect((page.items[1] as MessageHistoryItem).message.id, '01B');
      final r = page.items[2] as RetractionHistoryItem;
      expect(r.retraction.targetMsgId, '01A');
      expect(r.retraction.id, '01C');
      expect(r.retraction.channelId, 'c1');
      // Cursor still comes from the LAST raw row's id (next_after), untouched by
      // the client-side skip.
      expect(page.nextAfter, '01D');
    });

    // task #1896 — the HTTP path of getCapabilities, the branch prod is in TODAY
    // (/capabilities 404s). Cage-match Maxwell + Tesla + Carnot all flagged it
    // untested. Three-state at the wire: explicit bool → value; every "can't
    // determine" path (404, non-Map, missing field) → null.
    test('getCapabilities: explicit {carriage:{origin:true}} → carriesOrigin',
        () async {
      final api = apiWith((_) => jsonBody(200, '{"carriage":{"origin":true}}'));
      final caps = await api.getCapabilities();
      expect(caps?.carriesOrigin, isTrue);
    });

    test('getCapabilities: explicit origin:false → carriesOrigin false',
        () async {
      final api = apiWith((_) => jsonBody(200, '{"carriage":{"origin":false}}'));
      final caps = await api.getCapabilities();
      expect(caps?.carriesOrigin, isFalse);
    });

    test('getCapabilities: 404 → null (the live prod branch)', () async {
      final api = apiWith((_) => jsonBody(404, '{"detail":"not found"}'));
      expect(await api.getCapabilities(), isNull);
    });

    test('getCapabilities: stub 200 with missing origin → null (NOT false)',
        () async {
      // The bug: this must be unknown, so the resolver keeps the seed.
      final api = apiWith((_) => jsonBody(200, '{"carriage":{}}'));
      expect(await api.getCapabilities(), isNull);
      final api2 = apiWith((_) => jsonBody(200, '{}'));
      expect(await api2.getCapabilities(), isNull);
    });

    test('getCapabilities: non-object / non-JSON body → null', () async {
      final api = apiWith((_) => jsonBody(200, '"just a string"'));
      expect(await api.getCapabilities(), isNull);
      final api2 = apiWith((_) => jsonBody(200, 'not json at all'));
      expect(await api2.getCapabilities(), isNull);
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
      String body = '{}',
    }) {
      final tokens = DefaultTokenProvider(
          store: InMemoryTokenStore(_seed), remoteRefresh: remoteRefresh);
      ResponseBody handler(RequestOptions _) => jsonBody(statusCode, body);
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

    test(
        'a plain (non-suspended) 403 → Forbidden, NOT Unauthorized — an authZ '
        'denial must not log the user out (A3 taxonomy unbundle)', () async {
      final api =
          backend(remoteRefresh: (_) async => 'unused', statusCode: 403);
      await expectLater(
        api.getHistory('c1'),
        // Forbidden is NOT a subtype of Unauthorized, so the terminal-auth
        // routers (_isAuthError / on Unauthorized) never fire → no logout.
        throwsA(allOf(isA<Forbidden>(), isNot(isA<Unauthorized>()))),
      );
    });

    test('a ban-403 (body {"detail":"account suspended"}) → AccountSuspended '
        '(still terminal, unchanged by the unbundle)', () async {
      final api = backend(
        remoteRefresh: (_) async => 'unused',
        statusCode: 403,
        body: '{"detail":"account suspended"}',
      );
      await expectLater(
        api.getHistory('c1'),
        // AccountSuspended extends Unauthorized → stays terminal (logout path),
        // and is matched BEFORE the plain-403 → Forbidden branch.
        throwsA(allOf(isA<AccountSuspended>(), isA<Unauthorized>())),
      );
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

    test(
        'connectionState replays the CURRENT state to a late subscriber '
        '(state, not an event log)', () async {
      // A consumer that mounts AFTER `connected` fired (e.g. a repository
      // rebuilt by the gateway-recovery channel refetch, task #16) must still
      // learn the socket is live — its connected-driven choreography would
      // otherwise never run.
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: tokens(),
        channelFactory: (uri) => FakeWebSocketChannel(),
      );
      expect(await t.connectionState.first, ConnectionState.idle,
          reason: 'pre-connect subscriber is seeded with idle — no socket has '
              'been requested yet, which is NOT a server drop (a disconnected '
              'seed would flash a false "unreachable" banner at startup)');
      await t.connect();
      expect(await t.connectionState.first, ConnectionState.connected,
          reason: 'a late subscriber is seeded with the live state');
    });

    // A well-formed origin (32-byte key, 64-byte sig, id == frame id) passes the
    // real _originWire self-assert and IS serialised onto the wire frame.
    test('sendMessage emits a well-formed origin through the real wire path',
        () async {
      late FakeWebSocketChannel fake;
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: tokens(),
        channelFactory: (uri) => fake = FakeWebSocketChannel(),
        carriesOrigin: () => true, // gate open (default is now fail-closed)
      );
      await t.connect();
      t.sendMessage(OutgoingMessage(
        clientTempId: 'tmp1',
        channelId: 'c1',
        body: 'hello',
        origin: OriginEnvelope(
          keyVersion: 1,
          rawPublicKey: Uint8List(32),
          clientMsgId: 'tmp1',
          signedAtMs: 1,
          sig: Uint8List(64),
        ),
      ));
      final sent = fake.sent.firstWhere((f) => f.contains('"type":"send"'));
      expect(sent.contains('"origin"'), isTrue);
      expect(sent.contains('"sender_pubkey"'), isTrue);
    });

    // cage-match Carnot F1 + Tesla: a MALFORMED self-built origin (bad-length
    // key) makes toWire() throw OriginError. The strip must catch it (never-throws
    // contract) and emit the message UNSIGNED — origin stripped, delivery intact.
    test('sendMessage STRIPS a malformed origin and does not throw '
        '(fail-safe covers construction, not just validation)', () async {
      late FakeWebSocketChannel fake;
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: tokens(),
        channelFactory: (uri) => fake = FakeWebSocketChannel(),
        carriesOrigin: () => true, // gate open, so we exercise the STRIP path
      );
      await t.connect();
      // 10-byte key → encodeMultikey (inside toWire) throws OriginError.
      final id = t.sendMessage(OutgoingMessage(
        clientTempId: 'tmp1',
        channelId: 'c1',
        body: 'hello',
        origin: OriginEnvelope(
          keyVersion: 1,
          rawPublicKey: Uint8List(10),
          clientMsgId: 'tmp1',
          signedAtMs: 1,
          sig: Uint8List(64),
        ),
      ));
      expect(id, 'tmp1', reason: 'never throws — the message still sends');
      final sent = fake.sent.firstWhere((f) => f.contains('"type":"send"'));
      expect(sent.contains('"origin"'), isFalse,
          reason: 'malformed origin stripped; message emitted unsigned');
      expect(sent.contains('"body":"hello"'), isTrue);
    });

    // task #1896: a gateway that does NOT advertise `origin` carriage would
    // `bad_origin`-reject the whole message. The capability gate WITHHOLDS a
    // perfectly valid origin and sends the message unsigned instead.
    test('sendMessage WITHHOLDS a well-formed origin when the gateway does '
        'not carry it (capability gate, #1896)', () async {
      late FakeWebSocketChannel fake;
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: tokens(),
        channelFactory: (uri) => fake = FakeWebSocketChannel(),
        carriesOrigin: () => false, // gateway advertises NO origin carriage
      );
      await t.connect();
      final id = t.sendMessage(OutgoingMessage(
        clientTempId: 'tmp1',
        channelId: 'c1',
        body: 'hello',
        origin: OriginEnvelope(
          keyVersion: 1,
          rawPublicKey: Uint8List(32), // a VALID origin — gate, not malformation
          clientMsgId: 'tmp1',
          signedAtMs: 1,
          sig: Uint8List(64),
        ),
      ));
      expect(id, 'tmp1', reason: 'the message still sends, just unsigned');
      final sent = fake.sent.firstWhere((f) => f.contains('"type":"send"'));
      expect(sent.contains('"origin"'), isFalse,
          reason: 'non-carriage gateway → origin withheld, message unsigned');
      expect(sent.contains('"body":"hello"'), isTrue);
    });

    test('sendMessage EMITS a well-formed origin when the gateway carries it '
        '(gate open, #1896)', () async {
      late FakeWebSocketChannel fake;
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: tokens(),
        channelFactory: (uri) => fake = FakeWebSocketChannel(),
        carriesOrigin: () => true,
      );
      await t.connect();
      t.sendMessage(OutgoingMessage(
        clientTempId: 'tmp1',
        channelId: 'c1',
        body: 'hello',
        origin: OriginEnvelope(
          keyVersion: 1,
          rawPublicKey: Uint8List(32),
          clientMsgId: 'tmp1',
          signedAtMs: 1,
          sig: Uint8List(64),
        ),
      ));
      final sent = fake.sent.firstWhere((f) => f.contains('"type":"send"'));
      expect(sent.contains('"origin"'), isTrue);
    });

    // The transport TRIGGERS a capability re-resolve on each connect so the gate
    // reads a value that tracks the live (possibly switched) gateway (#1896).
    test('onConnected fires when the socket reaches connected', () async {
      var refreshed = 0;
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: tokens(),
        channelFactory: (uri) => FakeWebSocketChannel(),
        onConnected: () async => refreshed++,
      );
      await t.connect();
      expect(refreshed, 1, reason: 'capability refresh triggered on connect');
    });

    // cage-match Carnot: a throwing onConnected hook must NOT corrupt the live
    // socket — it runs isolated from the connect try, so no spurious reconnect.
    test('a throwing onConnected hook leaves the socket connected', () async {
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: tokens(),
        channelFactory: (uri) => FakeWebSocketChannel(),
        onConnected: () async => throw StateError('hook boom'),
      );
      await t.connect();
      // The connect completed and the state is connected, not thrown back into
      // a reconnect cycle by the hook's failure.
      expect(await t.connectionState.first, ConnectionState.connected);
    });

    // cage-match Carnot: prove the full loop — a stranger seeds OFF, the
    // on-connect refresh flips the gate ON, and a subsequent send then emits.
    test('onConnected refresh flips the gate → a later send emits origin',
        () async {
      late FakeWebSocketChannel fake;
      var carries = false; // stranger seed: OFF until proven
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: tokens(),
        channelFactory: (uri) => fake = FakeWebSocketChannel(),
        carriesOrigin: () => carries,
        onConnected: () async => carries = true, // endpoint proves carriage
      );
      await t.connect();
      await Future<void>.delayed(Duration.zero); // let the fire-and-forget hook run
      OutgoingMessage msg(String id) => OutgoingMessage(
            clientTempId: id,
            channelId: 'c1',
            body: 'hi',
            origin: OriginEnvelope(
              keyVersion: 1,
              rawPublicKey: Uint8List(32),
              clientMsgId: id,
              signedAtMs: 1,
              sig: Uint8List(64),
            ),
          );
      t.sendMessage(msg('after'));
      final sent = fake.sent.lastWhere((f) => f.contains('"type":"send"'));
      expect(sent.contains('"origin"'), isTrue,
          reason: 'gate flipped ON by the refresh → this send carries origin');
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
