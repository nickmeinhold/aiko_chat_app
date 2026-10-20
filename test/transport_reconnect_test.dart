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
    t.reconnectNow(TransportWakeReason.online);
    await pumpEventQueue();
    expect(refreshCalls, 1, reason: 'a fresh token is not refreshed again');

    now = now.add(kRefreshFloor);
    t.reconnectNow(TransportWakeReason.online);
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
      t.reconnectNow(TransportWakeReason.answered);
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
      t.reconnectNow(TransportWakeReason.resume);
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
    t.reconnectNow(TransportWakeReason.online);
    await pumpEventQueue();
    expect(island.attempts, 0);
  });

  test(
    'ROUND-1 RACE: a kick that connects while a failure\'s refresh is in '
    'flight is not orphaned by the timer that refresh would have armed',
    () async {
      final island = _Island();
      final gate = Completer<String>();
      var refreshCalls = 0;
      final states = <ConnectionState>[];
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: DefaultTokenProvider(
          store: InMemoryTokenStore(
            const AuthTokens(accessToken: 'access0', refreshToken: 'r0'),
          ),
          remoteRefresh: (_) {
            refreshCalls++;
            return gate.future; // the drop's refresh hangs until released
          },
        ),
        channelFactory: island.connect,
      );
      addTearDown(t.disconnect);
      t.connectionState.listen(states.add);

      await t.connect();
      island.sockets.last.closeFromGateway(); // drop → refresh awaits the gate
      await pumpEventQueue();
      expect(refreshCalls, 1);

      t.reconnectNow(TransportWakeReason.answered); // connects meanwhile
      await pumpEventQueue();
      expect(island.attempts, 2);
      final live = island.sockets.last;

      gate.complete('access0'); // the stale refresh returns
      // The old timer fired after 1s; give it ample time to misbehave.
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      expect(island.attempts, 2, reason: 'no second socket over the live one');
      expect(
        (live.sink as FakeWebSocketSink).closed,
        isFalse,
        reason: 'the live socket survives',
      );
      expect(states.last, ConnectionState.connected);
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test('disconnect while a connect awaits its token: the late continuation '
      'opens nothing and never reports connected', () async {
    final island = _Island();
    final read = Completer<AuthTokens?>();
    final states = <ConnectionState>[];
    final t = GatewayTransport(
      wsBaseUrl: 'ws://host',
      tokens: DefaultTokenProvider(
        store: _GatedStore(read.future),
        remoteRefresh: (_) async => 'access0',
      ),
      channelFactory: island.connect,
    );
    t.connectionState.listen(states.add);

    unawaited(t.connect());
    await pumpEventQueue();
    await t.disconnect(); // logout mid-connect
    read.complete(const AuthTokens(accessToken: 'access0', refreshToken: 'r0'));
    await pumpEventQueue();

    expect(island.attempts, 0, reason: 'no socket after logout');
    expect(states, isNot(contains(ConnectionState.connected)));
  });

  test('a kick does not reset the backoff counter — flapping cannot turn '
      'backoff into a once-a-second storm against a down island', () async {
    final island = _Island()..down = true;
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

    await t.connect(); // fails: attempt 1 scheduled at 1s
    await pumpEventQueue();
    t.reconnectNow(TransportWakeReason.resume); // fails: next is attempt 2
    await pumpEventQueue();
    t.reconnectNow(TransportWakeReason.resume);
    await pumpEventQueue();

    final scheduled = [
      for (final r in rec.records)
        if (r.event == 'reconnect.scheduled') r.fields['seconds'],
    ];
    expect(scheduled, [1, 2, 4], reason: 'backoff keeps climbing across kicks');
  });

  test('disconnect during the handshake: the socket that completes late is '
      'closed, never installed', () async {
    final handshake = Completer<void>();
    late FakeWebSocketChannel ch;
    final states = <ConnectionState>[];
    final t = GatewayTransport(
      wsBaseUrl: 'ws://host',
      tokens: DefaultTokenProvider(
        store: InMemoryTokenStore(
          const AuthTokens(accessToken: 'access0', refreshToken: 'r0'),
        ),
        remoteRefresh: (_) async => 'access0',
      ),
      channelFactory: (_) =>
          ch = FakeWebSocketChannel(readyGate: handshake.future),
    );
    t.connectionState.listen(states.add);

    unawaited(t.connect());
    await pumpEventQueue(); // now awaiting ch.ready
    await t.disconnect();
    handshake.complete();
    await pumpEventQueue();

    expect((ch.sink as FakeWebSocketSink).closed, isTrue);
    expect(states, isNot(contains(ConnectionState.connected)));
  });

  test(
    'a handshake that FAILS after logout does not refresh — a dead '
    'attempt never calls the auth endpoint on a signed-out session',
    () async {
      final handshake = Completer<void>();
      var refreshCalls = 0;
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: DefaultTokenProvider(
          store: InMemoryTokenStore(
            const AuthTokens(accessToken: 'access0', refreshToken: 'r0'),
          ),
          remoteRefresh: (_) async {
            refreshCalls++;
            return 'access1';
          },
        ),
        channelFactory: (_) => FakeWebSocketChannel(
          readyGate: handshake.future.then((_) => throw StateError('403')),
        ),
      );

      unawaited(t.connect());
      await pumpEventQueue();
      await t.disconnect();
      handshake.complete();
      await pumpEventQueue();

      expect(refreshCalls, 0);
    },
  );

  test('ROUND-2 CLASS: a stale REJECTED refresh does not tear down the '
      'socket a kick connected meanwhile', () async {
    final island = _Island();
    final gate = Completer<String>();
    final states = <ConnectionState>[];
    final t = GatewayTransport(
      wsBaseUrl: 'ws://host',
      tokens: DefaultTokenProvider(
        store: InMemoryTokenStore(
          const AuthTokens(accessToken: 'access0', refreshToken: 'r0'),
        ),
        remoteRefresh: (_) => gate.future,
      ),
      channelFactory: island.connect,
    );
    addTearDown(t.disconnect);
    t.connectionState.listen(states.add);

    await t.connect();
    island.sockets.last.closeFromGateway(); // drop → refresh awaits the gate
    await pumpEventQueue();
    t.reconnectNow(TransportWakeReason.answered);
    await pumpEventQueue();
    final live = island.sockets.last;

    gate.completeError(
      RefreshRejected(),
    ); // the OLD refresh comes back rejected
    await pumpEventQueue();

    expect((live.sink as FakeWebSocketSink).closed, isFalse);
    expect(states.last, ConnectionState.connected);
  });

  test('ROUND-2 CLASS: dispose while a failure refresh is in flight — the '
      'late result publishes nothing into closed controllers', () async {
    final island = _Island();
    final gate = Completer<String>();
    final t = GatewayTransport(
      wsBaseUrl: 'ws://host',
      tokens: DefaultTokenProvider(
        store: InMemoryTokenStore(
          const AuthTokens(accessToken: 'access0', refreshToken: 'r0'),
        ),
        remoteRefresh: (_) => gate.future,
      ),
      channelFactory: island.connect,
    );

    await t.connect();
    island.sockets.last.closeFromGateway();
    await pumpEventQueue();
    await t.dispose();

    // flutter_test fails the test on any uncaught async error, so a
    // `Bad state: Cannot add new events after calling close` fails it here.
    gate.completeError(RefreshRejected());
    await pumpEventQueue();
  });

  test('ROUND-2 CLASS: a dying socket whose close handshake hangs does not '
      'occupy the channel — a kick right after the drop connects', () async {
    final island = _Island();
    final rec = _Recorder();
    final t = GatewayTransport(
      wsBaseUrl: 'ws://host',
      tokens: DefaultTokenProvider(
        store: InMemoryTokenStore(
          const AuthTokens(accessToken: 'access0', refreshToken: 'r0'),
        ),
        remoteRefresh: (_) =>
            Completer<String>().future, // isolate the corpse case
      ),
      channelFactory: island.connect,
      logger: AikoLogger(subsystem: 'aiko.transport', sink: rec),
    );
    addTearDown(t.disconnect);

    await t.connect();
    final dying = island.sockets.last;
    (dying.sink as FakeWebSocketSink).closeGate = Completer<void>().future;
    dying.closeFromGateway(); // its close() will never complete
    await pumpEventQueue();

    t.reconnectNow(TransportWakeReason.resume);
    await pumpEventQueue();

    expect(rec.events, isNot(contains('kick.ignored')));
    expect(island.attempts, 2);
  });

  test('ROUND-2 CLASS: a token read that THROWS does not wedge the transport '
      'in connecting', () async {
    final island = _Island();
    final store = _FlakyStore();
    final states = <ConnectionState>[];
    final t = GatewayTransport(
      wsBaseUrl: 'ws://host',
      tokens: DefaultTokenProvider(
        store: store,
        remoteRefresh: (_) async => 'access0',
      ),
      channelFactory: island.connect,
    );
    addTearDown(t.disconnect);
    t.connectionState.listen(states.add);

    await t.connect(); // the store read throws
    await pumpEventQueue();
    t.reconnectNow(TransportWakeReason.resume); // must not be ignored
    await _until(() => states.contains(ConnectionState.connected));
  });

  test('ROUND-2 CLASS: a stale TRANSIENT refresh arms no timer and leaves the '
      'backoff alone once a kick has connected', () async {
    final island = _Island();
    final gate = Completer<String>();
    final rec = _Recorder();
    final t = GatewayTransport(
      wsBaseUrl: 'ws://host',
      tokens: DefaultTokenProvider(
        store: InMemoryTokenStore(
          const AuthTokens(accessToken: 'access0', refreshToken: 'r0'),
        ),
        remoteRefresh: (_) => gate.future,
      ),
      channelFactory: island.connect,
      logger: AikoLogger(subsystem: 'aiko.transport', sink: rec),
    );
    addTearDown(t.disconnect);

    await t.connect();
    island.sockets.last.closeFromGateway();
    await pumpEventQueue();
    t.reconnectNow(TransportWakeReason.answered);
    await pumpEventQueue();
    rec.records.clear();

    gate.completeError(Exception('network blocked')); // stale, transient
    await pumpEventQueue();

    expect(rec.events, isNot(contains('reconnect.scheduled')));
    expect(rec.events, contains('attempt.abandoned'));
  });

  test('ROUND-3: an answer at the 30s backoff cap with an EXPIRED token joins '
      'at once — a fresh token retries now, not after the backoff', () async {
    final island = _Island()..down = true;
    var now = DateTime.utc(2026, 10, 20, 12);
    var refreshCalls = 0;
    final states = <ConnectionState>[];
    final rec = _Recorder();
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
      logger: AikoLogger(subsystem: 'aiko.transport', sink: rec),
    );
    addTearDown(t.disconnect);
    t.connectionState.listen(states.add);

    // Climb to the cap: every attempt fails while the island is down.
    await t.connect();
    await pumpEventQueue();
    for (var i = 0; i < 6; i++) {
      t.reconnectNow(TransportWakeReason.resume);
      await pumpEventQueue();
    }
    final scheduled = [
      for (final r in rec.records)
        if (r.event == 'reconnect.scheduled') r.fields['seconds'],
    ];
    expect(scheduled.last, 30, reason: 'precondition: backoff is at the cap');

    // The token expires while asleep; the island comes back.
    island
      ..down = false
      ..valid = 'access${refreshCalls + 1}';
    now = now.add(kRefreshFloor); // past the floor: a refresh is allowed

    final sw = Stopwatch()..start();
    t.reconnectNow(TransportWakeReason.answered); // 403 → refresh → retry now
    await _until(() => states.last == ConnectionState.connected, seconds: 5);
    expect(
      sw.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'the fresh-token attempt must not wait out the 30s backoff',
    );
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('ROUND-3: disconnect publishes at once and returns while the close '
      'handshake hangs', () async {
    final island = _Island();
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
    );
    t.connectionState.listen(states.add);
    await t.connect();
    (island.sockets.last.sink as FakeWebSocketSink).closeGate =
        Completer<void>().future; // the close never completes

    await t.disconnect().timeout(const Duration(seconds: 2));
    await pumpEventQueue();
    expect(states.last, ConnectionState.disconnected);
  });
}

class _FlakyStore extends InMemoryTokenStore {
  _FlakyStore()
    : super(const AuthTokens(accessToken: 'access0', refreshToken: 'r0'));
  var _reads = 0;
  @override
  Future<AuthTokens?> read() async {
    if (_reads++ == 0) throw StateError('keystore unavailable');
    return super.read();
  }
}

class _GatedStore extends InMemoryTokenStore {
  _GatedStore(this._read);
  final Future<AuthTokens?> _read;
  @override
  Future<AuthTokens?> read() => _read;
}
