import 'dart:async';

import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/core/logging/aiko_log.dart';
import 'package:aiko_chat_app/core/logging/aiko_logger.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/transport/gateway_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// The transport's release-visible trail (#223), staged against the #392
/// shape: a live socket drops and the refresh it awaits never returns.
class _Recorder extends LogSink {
  final records = <LogRecord>[];
  @override
  void add(LogRecord record) => records.add(record);
  List<String> get events => [for (final r in records) r.event];
}

void main() {
  test('connect then drop: the trail names each stage, scalars only', () async {
    final rec = _Recorder();
    final fakes = <FakeWebSocketChannel>[];
    final t = GatewayTransport(
      wsBaseUrl: 'ws://host',
      tokens: DefaultTokenProvider(
        island: 'https://island.test',
        store: InMemoryTokenStore(
          const AuthTokens(accessToken: 'access0', refreshToken: 'r0'),
        ),
        remoteRefresh: (_) async => 'access1',
      ),
      channelFactory: (_) {
        final f = FakeWebSocketChannel();
        fakes.add(f);
        return f;
      },
      logger: AikoLogger(subsystem: 'aiko.transport', sink: rec),
    );
    addTearDown(t.disconnect);

    await t.connect();
    expect(rec.events, [
      'state', // disconnected -> connecting
      'connect.token.read',
      'connect.token.done',
      'state', // -> connected
    ]);
    expect(rec.records.last.fields, {'to': 'connected'});

    rec.records.clear();
    fakes.single.closeFromGateway();
    await pumpEventQueue();
    // A fresh token retries NOW (round 3), so the trail continues straight
    // into the next connect; pin the stretch this test is about.
    expect(rec.events.take(5), [
      'drop',
      'state',
      'failure.refresh.start',
      'failure.refresh.done',
      'reconnect.now',
    ]);
    expect(rec.records[3].fields, {'outcome': 'token'});

    // No line carries a token — the WS URL holds one, and must never be logged.
    for (final r in rec.records) {
      expect(r.format(), isNot(contains('access')));
    }
  });

  test(
    'a refresh that never returns leaves a trail ending at '
    'failure.refresh.start — no reconnect is ever scheduled (#392)',
    () async {
      final rec = _Recorder();
      final hang = Completer<String>();
      final fakes = <FakeWebSocketChannel>[];
      final t = GatewayTransport(
        wsBaseUrl: 'ws://host',
        tokens: DefaultTokenProvider(
          island: 'https://island.test',
          store: InMemoryTokenStore(
            const AuthTokens(accessToken: 'access0', refreshToken: 'r0'),
          ),
          remoteRefresh: (_) => hang.future,
        ),
        channelFactory: (_) {
          final f = FakeWebSocketChannel();
          fakes.add(f);
          return f;
        },
        logger: AikoLogger(subsystem: 'aiko.transport', sink: rec),
      );
      addTearDown(t.disconnect);

      await t.connect();
      rec.records.clear();
      fakes.single.closeFromGateway();
      await pumpEventQueue();

      // This pins what the trail SAYS, not the defect: when #392's fix bounds
      // the refresh, this test changes to expect `reconnect.scheduled`.
      expect(rec.events, ['drop', 'state', 'failure.refresh.start']);
    },
  );

  test('a stranded connect is legible: a later attempt logs '
      'connect.skipped connecting=true (#392 suspect 1)', () async {
    final rec = _Recorder();
    final t = GatewayTransport(
      wsBaseUrl: 'ws://host',
      tokens: DefaultTokenProvider(
        island: 'https://island.test',
        store: _HangingStore(),
        remoteRefresh: (_) async => 'access1',
      ),
      channelFactory: (_) => FakeWebSocketChannel(),
      logger: AikoLogger(subsystem: 'aiko.transport', sink: rec),
    );

    unawaited(t.connect()); // stuck reading the token, _connecting set
    await pumpEventQueue();
    unawaited(t.connect());
    await pumpEventQueue();

    expect(rec.events, ['state', 'connect.token.read', 'connect.skipped']);
    expect(rec.records.last.fields, {
      'want': true,
      'connecting': true,
      'channel': false,
    });
  });
}

class _HangingStore extends InMemoryTokenStore {
  @override
  Future<AuthTokens?> read() => Completer<AuthTokens?>().future;
}
