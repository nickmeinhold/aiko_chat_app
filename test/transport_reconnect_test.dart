import 'dart:async';

import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/core/logging/aiko_log.dart';
import 'package:aiko_chat_app/core/logging/aiko_logger.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart';
import 'package:aiko_chat_app/features/chat/data/transport/gateway_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// #392 and #384, as measured on a Pixel 2026-10-19: a refresh that ran while
/// Doze blocked the network was never retried, the token expired, and every
/// reconnect drew a 403 until the app restarted; and a reconnect waited out
/// its backoff while a held answer timed out.
class _Recorder extends LogSink {
  final records = <LogRecord>[];
  @override
  void add(LogRecord record) => records.add(record);
  List<String> get events => [for (final r in records) r.event];
}

/// An island that rejects any token but [valid] — the 403 an expired access
/// token draws, which the client sees only as a failed `ready`.
class _Island {
  String valid = 'access0';
  bool down = false;
  final sockets = <FakeWebSocketChannel>[];
  int attempts = 0;

  FakeWebSocketChannel connect(Uri uri) {
    attempts++;
    final ok = !down && uri.queryParameters['token'] == valid;
    final f = ok
        ? FakeWebSocketChannel()
        : FakeWebSocketChannel(readyError: StateError('403'));
    sockets.add(f);
    return f;
  }
}

Future<void> _until(bool Function() done, {int seconds = 10}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('condition not reached');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('THE #392 REPLAY: a refresh that failed transiently is retried, so a '
      'token that expired meanwhile does not 403 forever', () async {
    final island = _Island();
    var refreshCalls = 0;
    final states = <ConnectionState>[];
    final t = GatewayTransport(
      wsBaseUrl: 'ws://host',
      tokens: DefaultTokenProvider(
        store: InMemoryTokenStore(
          const AuthTokens(accessToken: 'access0', refreshToken: 'r0'),
        ),
        remoteRefresh: (_) async {
          refreshCalls++;
          // The first refresh runs in Doze: the network is blocked.
          if (refreshCalls == 1) throw Exception('network blocked');
          return 'access1';
        },
      ),
      channelFactory: island.connect,
    );
    addTearDown(t.disconnect);
    t.connectionState.listen(states.add);

    await t.connect();
    await _until(() => states.last == ConnectionState.connected);

    // Doze: the socket drops, and while the refresh is failing the access
    // token expires at the island.
    island.valid = 'access1';
    island.sockets.last.closeFromGateway();

    // The real backoff timers run (1s, then 2s): the old rule's defect lived
    // exactly where backoff had left zero, so a kick would hide it.
    await _until(() => states.contains(ConnectionState.disconnected));
    states.clear();
    await _until(() => states.contains(ConnectionState.connected));
    expect(refreshCalls, 2, reason: 'the transient failure was retried');
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('a refresh that SUCCEEDED within kRefreshFloor is not repeated; '
      'past the floor it is', () async {
    final island = _Island();
    var now = DateTime.utc(2026, 10, 19, 12);
    var refreshCalls = 0;
    final t = GatewayTransport(
      wsBaseUrl: 'ws://host',
      tokens: DefaultTokenProvider(
        store: InMemoryTokenStore(
          const AuthTokens(accessToken: 'access0', refreshToken: 'r0'),
        ),
        remoteRefresh: (_) async => 'access${++refreshCalls}',
      ),
      channelFactory: island.connect,
      clock: () => now,
    );
    addTearDown(t.disconnect);

    await t.connect();
    island.down = true;
    island.sockets.last.closeFromGateway();
    await pumpEventQueue();
    expect(refreshCalls, 1, reason: 'the first failure refreshes');

    now = now.add(const Duration(seconds: 10));
    t.reconnectNow('test');
    await pumpEventQueue();
    expect(refreshCalls, 1, reason: 'a fresh token is not refreshed again');

    now = now.add(kRefreshFloor);
    t.reconnectNow('test');
    await pumpEventQueue();
    expect(
      refreshCalls,
      2,
      reason: 'past the floor the token may have expired during the outage',
    );
  });

  test(
    'reconnectNow skips the backoff: it connects at once and logs why',
    () async {
      final island = _Island();
      final rec = _Recorder();
      final states = <ConnectionState>[];
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: DefaultTokenProvider(
          store: InMemoryTokenStore(
            const AuthTokens(accessToken: 'access0', refreshToken: 'r0'),
          ),
          remoteRefresh: (_) async => 'access0',
        ),
        channelFactory: island.connect,
        logger: AikoLogger(subsystem: 'aiko.transport', sink: rec),
      );
      addTearDown(t.disconnect);
      t.connectionState.listen(states.add);

      await t.connect();
      island.down = true;
      island.sockets.last.closeFromGateway();
      await pumpEventQueue();
      final before = island.attempts;

      island.down = false; // the push lifts Doze's block
      t.reconnectNow('answered');
      await pumpEventQueue();

      expect(island.attempts, before + 1, reason: 'no backoff wait');
      expect(states.last, ConnectionState.connected);
      expect(rec.records.firstWhere((r) => r.event == 'kick').fields, {
        'reason': 'answered',
      });
    },
  );

  test(
    'reconnectNow is a no-op on a live socket — it never stacks a second',
    () async {
      final island = _Island();
      final rec = _Recorder();
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: DefaultTokenProvider(
          store: InMemoryTokenStore(
            const AuthTokens(accessToken: 'access0', refreshToken: 'r0'),
          ),
          remoteRefresh: (_) async => 'access0',
        ),
        channelFactory: island.connect,
        logger: AikoLogger(subsystem: 'aiko.transport', sink: rec),
      );
      addTearDown(t.disconnect);

      await t.connect();
      t.reconnectNow('resume');
      await pumpEventQueue();

      expect(island.attempts, 1);
      expect(rec.events, contains('kick.ignored'));
      expect(rec.events, isNot(contains('kick')));
    },
  );

  test('reconnectNow before connect() does nothing — a kick is not consent '
      'to connect a signed-out transport', () async {
    final island = _Island();
    final t = GatewayTransport(
      wsBaseUrl: 'ws://host',
      tokens: DefaultTokenProvider(
        store: InMemoryTokenStore(
          const AuthTokens(accessToken: 'access0', refreshToken: 'r0'),
        ),
        remoteRefresh: (_) async => 'access0',
      ),
      channelFactory: island.connect,
    );
    t.reconnectNow('online');
    await pumpEventQueue();
    expect(island.attempts, 0);
  });
}
