// Acceptance tests for Component B4 — the reconcile engine (design 04).
// Written test-first against the merged design. The crux is the lifecycle
// `send → disconnect → reconnect → ack` resolving to exactly ONE row — the AMR
// flaky-wifi reality where disconnect/reconnect is the MAIN case, not an edge.

import 'dart:async';

import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/chat_repository.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_transport.dart';

const _me = AppUser(
    userId: 'me', username: 'me', displayName: 'Me', aikoUsername: 'me');
const _chan = 'chan';

Message _server(String ulid, String body, {String at = '2026-01-01T12:00:01Z'}) =>
    Message(
      clientTempId: ulid,
      id: ulid,
      channelId: _chan,
      sender: const MessageSender(
          userId: 'u2', kind: SenderKind.human, label: 'Alice'),
      body: body,
      createdAt: DateTime.parse(at).toUtc(),
      deliveryState: DeliveryState.sent,
    );

void main() {
  late DriftCache cache;
  late FakeChatTransport transport;
  late FakeChatRestApi rest;
  late ChatRepository repo;
  late int seq;

  setUp(() {
    cache = DriftCache(NativeDatabase.memory());
    transport = FakeChatTransport();
    rest = FakeChatRestApi();
    seq = 0;
    repo = ChatRepository(
      cache: cache,
      transport: transport,
      rest: rest,
      me: _me,
      subscribedChannelIds: const [_chan],
      ackTimeout: const Duration(milliseconds: 80),
      newTempId: () => 'tmp${seq++}',
    );
    repo.start();
  });

  tearDown(() async {
    await repo.dispose();
    await transport.dispose();
    await cache.close();
  });

  // Let stream listeners + their async handlers drain.
  Future<void> pump() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<List<Message>> rows() => cache.watchChannel(_chan).first;

  group('W1 — optimistic send', () {
    test('commits one sending row + records a send + enters the outbox',
        () async {
      await repo.sendMessage(_chan, 'hi');
      final r = await rows();
      expect(r, hasLength(1));
      expect(r.single.deliveryState, DeliveryState.sending);
      expect(r.single.id, isNull);
      expect(transport.sent.single.body, 'hi');
      expect(await cache.outbox(), hasLength(1));
    });

    test('commits the optimistic row BEFORE the wire send (B-optimistic)',
        () async {
      final atSend = Completer<List<Message>>();
      transport.onSend = (_) => cache.watchChannel(_chan).first.then(atSend.complete);
      await repo.sendMessage(_chan, 'hi');
      final atSendRows = await atSend.future;
      expect(atSendRows, hasLength(1),
          reason: 'row must be committed by dispatch time');
    });
  });

  group('W2 — ack reconcile + self-echo', () {
    test('happy path: ack stamps the server ULID + sent + server time',
        () async {
      await repo.sendMessage(_chan, 'hi');
      final om = transport.sent.single;
      transport.emitAck(om.clientTempId, '01U', createdAt: '2026-01-01T12:00:05Z');
      await pump();
      final r = await rows();
      expect(r, hasLength(1));
      expect(r.single.id, '01U');
      expect(r.single.deliveryState, DeliveryState.sent);
      expect(r.single.createdAt, DateTime.parse('2026-01-01T12:00:05Z').toUtc());
    });

    test('self-echo A — ack THEN self-echo → exactly one row', () async {
      await repo.sendMessage(_chan, 'hi');
      final om = transport.sent.single;
      transport.emitAck(om.clientTempId, '01U');
      await pump();
      transport.emitMessage(_server('01U', 'hi')); // own fanout echo
      await pump();
      expect(await rows(), hasLength(1));
    });

    test('self-echo B — self-echo THEN ack → exactly one row (collapse)',
        () async {
      await repo.sendMessage(_chan, 'hi');
      final om = transport.sent.single;
      transport.emitMessage(_server('01U', 'hi')); // echo arrives first (W3)
      await pump();
      transport.emitAck(om.clientTempId, '01U'); // ack collapses
      await pump();
      final r = await rows();
      expect(r, hasLength(1));
      expect(r.single.clientTempId, om.clientTempId); // optimistic row survives
      expect(r.single.id, '01U');
      expect(r.single.deliveryState, DeliveryState.sent);
    });
  });

  group('reconnect choreography', () {
    test('CRUX — send → disconnect → reconnect → ack → exactly one row',
        () async {
      await repo.sendMessage(_chan, 'hi');
      final om = transport.sent.single;
      expect(await cache.outbox(), hasLength(1));

      transport.emitConn(ConnectionState.disconnected);
      await pump();

      // On reconnect the gateway fences at the message's ULID, and history
      // returns the same message (the lost-ack scenario's backstop).
      transport.fences = {_chan: '01U'};
      rest.pagesByAfter[''] =
          HistoryPage(channelId: _chan, messages: [_server('01U', 'hi')], nextAfter: '01U');

      transport.emitConn(ConnectionState.connected);
      await pump();
      expect(transport.sent.length, 2, reason: 'pending row re-sent on drain');

      transport.emitAck(om.clientTempId, '01U'); // the re-send's ack lands
      await pump();

      final r = await rows();
      expect(r, hasLength(1), reason: 'no duplicate across the lifecycle');
      expect(r.single.id, '01U');
      expect(r.single.deliveryState, DeliveryState.sent);
      // Watermark advanced to the fence (single-writer pager).
      expect(await cache.historyContiguousThrough(_chan), '01U');
    });

    test('drain-first — re-send is dispatched before history is fetched (B-order)',
        () async {
      await repo.sendMessage(_chan, 'hi');
      final order = <String>[];
      transport.onSend = (_) => order.add('send');
      rest.getHistoryCalls.clear();
      transport.fences = {_chan: '01U'};
      rest.pagesByAfter[''] =
          HistoryPage(channelId: _chan, messages: [_server('01U', 'hi')], nextAfter: '01U');

      transport.emitConn(ConnectionState.connected);
      await pump();
      // The re-send (drain) happened; history fetch happens after the ack/timeout.
      expect(order, contains('send'));
      transport.emitAck('tmp0', '01U');
      await pump();
      expect(rest.getHistoryCalls, isNotEmpty);
    });

    test('lost-ack — only the re-send acks (same ULID) → one row', () async {
      await repo.sendMessage(_chan, 'hi'); // first send, ack NEVER arrives
      transport.emitConn(ConnectionState.disconnected);
      await pump();
      transport.fences = {_chan: '01U'};
      rest.pagesByAfter[''] =
          HistoryPage(channelId: _chan, messages: [_server('01U', 'hi')], nextAfter: '01U');
      transport.emitConn(ConnectionState.connected);
      await pump();
      transport.emitAck('tmp0', '01U'); // the re-send's ack (gateway idempotent)
      await pump();
      expect(await rows(), hasLength(1));
    });

    test('ack-timeout — drain does not hang; history still runs; late ack collapses',
        () async {
      await repo.sendMessage(_chan, 'hi');
      transport.emitConn(ConnectionState.disconnected);
      await pump();
      transport.fences = {_chan: '01U'};
      rest.pagesByAfter[''] =
          HistoryPage(channelId: _chan, messages: [_server('01U', 'hi')], nextAfter: '01U');
      transport.emitConn(ConnectionState.connected);
      // No ack during the drain window → timeout (80ms) → history runs anyway.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(rest.getHistoryCalls, isNotEmpty, reason: 'reconnect did not hang');
      // History inserted 01U; the late ack collapses onto the optimistic row.
      transport.emitAck('tmp0', '01U');
      await pump();
      expect(await rows(), hasLength(1));
    });
  });

  group('empty channel', () {
    test('empty fence → no history paging, no spurious getHistory', () async {
      transport.fences = {_chan: ''}; // empty channel
      transport.emitConn(ConnectionState.connected);
      await pump();
      expect(rest.getHistoryCalls, isEmpty);
    });
  });
}
