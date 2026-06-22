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
  late SpyTelemetry spy;
  late int seq;

  setUp(() {
    cache = DriftCache(NativeDatabase.memory());
    transport = FakeChatTransport();
    rest = FakeChatRestApi();
    spy = SpyTelemetry();
    seq = 0;
    repo = ChatRepository(
      cache: cache,
      transport: transport,
      rest: rest,
      me: _me,
      subscribedChannelIds: const [_chan],
      telemetry: spy,
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

  // Let stream listeners + their async handlers (+ drift IO) drain. A small real
  // delay is more robust than counting microtasks for the multi-await
  // choreography paths.
  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 15));

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

  group('watermark single-writer (round-4 spine)', () {
    test('interrupted-sync — watermark advances ONLY on completion; resume '
        'refills with no gap', () async {
      transport.fences = {_chan: '01D'};
      rest.pagesByAfter[''] = HistoryPage(
          channelId: _chan,
          messages: [_server('01A', 'a'), _server('01B', 'b')],
          nextAfter: '01B');
      rest.pagesByAfter['01B'] = HistoryPage(
          channelId: _chan,
          messages: [_server('01C', 'c'), _server('01D', 'd')],
          nextAfter: '01D');
      // First sync crashes mid-paging (page 2 fails).
      rest.throwOnAfter.add('01B');
      transport.emitConn(ConnectionState.connected);
      await pump();

      // Page 1 ingested, but the watermark did NOT advance (sync incomplete).
      expect(await cache.historyContiguousThrough(_chan), isNull);
      final after1 = (await rows()).map((m) => m.id).toSet();
      expect(after1, containsAll(['01A', '01B']));
      expect(after1.contains('01C'), isFalse);

      // Recover: the second reconnect resumes from the TRUE contiguous boundary
      // (null → from the start), refetches page 1 (deduped) + page 2.
      rest.throwOnAfter.clear();
      rest.getHistoryCalls.clear();
      transport.emitConn(ConnectionState.disconnected);
      await pump();
      transport.emitConn(ConnectionState.connected);
      await pump();

      expect(rest.getHistoryCalls.first, '',
          reason: 'resume from the contiguous boundary, not the live edge');
      expect((await rows()).map((m) => m.id),
          containsAll(['01A', '01B', '01C', '01D'])); // no gap
      expect(await cache.historyContiguousThrough(_chan), '01D');
    });

    test('live-W3-watermark — resume uses historyContiguousThrough, NOT '
        'MAX(serverUlid)', () async {
      // Sync 1 completes: watermark = 01B.
      transport.fences = {_chan: '01B'};
      rest.pagesByAfter[''] = HistoryPage(
          channelId: _chan,
          messages: [_server('01A', 'a'), _server('01B', 'b')],
          nextAfter: '01B');
      transport.emitConn(ConnectionState.connected);
      await pump();
      expect(await cache.historyContiguousThrough(_chan), '01B');

      // A LIVE message Z lands far ahead — MAX(serverUlid) jumps to 01Z. W3 only;
      // it must NOT touch the watermark.
      transport.emitMessage(_server('01Z', 'live'));
      await pump();

      // Reconnect: the 01C..01D gap must refill. The resume cursor MUST be the
      // watermark (01B), NOT MAX (01Z) — else 01C,01D are skipped forever.
      transport.fences = {_chan: '01D'};
      rest.pagesByAfter['01B'] = HistoryPage(
          channelId: _chan,
          messages: [_server('01C', 'c'), _server('01D', 'd')],
          nextAfter: '01D');
      rest.getHistoryCalls.clear();
      transport.emitConn(ConnectionState.disconnected);
      await pump();
      transport.emitConn(ConnectionState.connected);
      await pump();

      expect(rest.getHistoryCalls.first, '01B',
          reason: 'resume from the single-writer watermark, not MAX=01Z');
      final ids = (await rows()).map((m) => m.id).toSet();
      expect(ids.containsAll({'01A', '01B', '01C', '01D', '01Z'}), isTrue);
    });
  });

  group('outbox lifecycle', () {
    test('no-teleport — retry preserves createdAt + timeline position', () async {
      await repo.sendMessage(_chan, 'first');
      await repo.sendMessage(_chan, 'second');
      transport.emitError(const TransportError(
          code: 'no_channel', detail: 'x', refClientMsgId: 'tmp0'));
      await pump();
      final failed = (await rows()).firstWhere((m) => m.clientTempId == 'tmp0');
      expect(failed.deliveryState, DeliveryState.failed);
      final origAt = failed.createdAt;

      await repo.retry('tmp0');
      await pump();
      final retried = (await rows()).firstWhere((m) => m.clientTempId == 'tmp0');
      expect(retried.deliveryState, DeliveryState.sending);
      expect(retried.createdAt, origAt, reason: 'retry must not teleport');
      // Still before 'second' in the timeline (position preserved).
      final ordered = (await rows()).map((m) => m.clientTempId).toList();
      expect(ordered.indexOf('tmp0'), lessThan(ordered.indexOf('tmp1')));
      // Re-sent on retry.
      expect(transport.sent.where((m) => m.clientTempId == 'tmp0').length,
          greaterThanOrEqualTo(2));
    });

    test('offline-send — stays sending (never failed) + drains on reconnect',
        () async {
      transport.emitConn(ConnectionState.disconnected);
      await pump();
      await repo.sendMessage(_chan, 'offline');
      expect((await rows()).single.deliveryState, DeliveryState.sending);
      expect(await cache.outbox(), hasLength(1));

      transport.fences = {_chan: ''};
      final before = transport.sent.length;
      transport.emitConn(ConnectionState.connected);
      await pump();
      expect(transport.sent.length, greaterThan(before),
          reason: 'reconnect drains the offline row');
    });

    test('already-acked row is not re-drained on reconnect', () async {
      await repo.sendMessage(_chan, 'hi');
      transport.emitAck('tmp0', '01U');
      await pump();
      expect((await rows()).single.id, '01U');
      expect(await cache.outbox(), isEmpty);

      transport.fences = {_chan: ''};
      transport.emitConn(ConnectionState.connected);
      await pump();
      expect(transport.sent.where((m) => m.clientTempId == 'tmp0').length, 1,
          reason: 'acked row left the outbox; never re-sent');
    });
  });

  group('terminal cancellation', () {
    test('unauthenticated mid-choreography aborts: no history, rows stay sending',
        () async {
      await repo.sendMessage(_chan, 'hi');
      transport.emitConn(ConnectionState.disconnected);
      await pump();

      // Wedge subscribe so the terminal event lands mid-choreography.
      transport.subscribeGate = Completer<void>();
      transport.fences = {_chan: '01U'};
      rest.pagesByAfter[''] = HistoryPage(
          channelId: _chan, messages: [_server('01U', 'hi')], nextAfter: '01U');
      transport.emitConn(ConnectionState.connected);
      await pump(); // started, wedged on subscribe

      transport.emitConn(ConnectionState.unauthenticated); // terminal mid-flight
      await pump();
      transport.subscribeGate!.complete(); // release; post-await abort fires
      await pump();

      expect(rest.getHistoryCalls, isEmpty, reason: 'aborted before history');
      expect((await rows()).single.deliveryState, DeliveryState.sending,
          reason: 'pending row untouched; resumes after re-auth');
    });
  });

  group('reconnect concurrency (round 2/3/4 fixes)', () {
    test('re-entrancy — two connected events → ONE concurrent choreography + '
        'ONE coalesced re-run', () async {
      transport.fences = {_chan: '01A'};
      rest.pagesByAfter[''] = HistoryPage(
          channelId: _chan, messages: [_server('01A', 'a')], nextAfter: '01A');
      rest.getHistoryGate = Completer<void>(); // wedge the first paging

      transport.emitConn(ConnectionState.connected);
      await pump(); // first choreography wedged inside getHistory
      expect(transport.subscribeCalls, hasLength(1));
      expect(rest.getHistoryCalls, hasLength(1));

      transport.emitConn(ConnectionState.connected); // coalesces, no 2nd run
      await pump();
      expect(transport.subscribeCalls, hasLength(1),
          reason: 'second connected coalesced; no concurrent choreography');
      expect(rest.getHistoryCalls, hasLength(1),
          reason: 'no concurrent getHistory');

      rest.getHistoryGate!.complete(); // release first; the re-run fires
      await pump();
      expect(transport.subscribeCalls, hasLength(2),
          reason: 'exactly ONE coalesced re-run, not N');
    });

    test('epoch-rerun — a disconnect between two connected events does NOT '
        'suppress the legit reconnect', () async {
      transport.fences = {_chan: '01A'};
      rest.pagesByAfter[''] = HistoryPage(
          channelId: _chan, messages: [_server('01A', 'a')], nextAfter: '01A');
      rest.getHistoryGate = Completer<void>();

      transport.emitConn(ConnectionState.connected);
      await pump(); // wedged (epoch E)
      transport.emitConn(ConnectionState.disconnected); // epoch bumps E -> E+1
      await pump();
      transport.emitConn(ConnectionState.connected); // queues a re-run
      await pump();

      rest.getHistoryGate!.complete(); // release the dead run
      await pump();
      expect(transport.subscribeCalls.length, greaterThanOrEqualTo(2),
          reason: 'the fresh reconnect ran despite the mid-flight disconnect');
    });

    test('history-TOCTOU — a disconnect during getHistory drops the resolved '
        'page (no write, no watermark advance)', () async {
      transport.fences = {_chan: '01B'};
      rest.pagesByAfter[''] = HistoryPage(
          channelId: _chan,
          messages: [_server('01A', 'a'), _server('01B', 'b')],
          nextAfter: '01B');
      rest.getHistoryGate = Completer<void>();

      transport.emitConn(ConnectionState.connected);
      await pump(); // wedged inside getHistory, page in flight
      transport.emitConn(ConnectionState.disconnected); // epoch bumps mid-await
      await pump();
      rest.getHistoryGate!.complete(); // the await now resolves with a page
      await pump();

      expect(await rows(), isEmpty,
          reason: 'post-await abort: the resolved page must NOT be upserted');
      expect(await cache.historyContiguousThrough(_chan), isNull,
          reason: 'watermark must NOT advance on an aborted sync');
    });

    test('completer-race — disconnect + ack for the same drained row → no '
        'StateError escapes', () async {
      await repo.sendMessage(_chan, 'hi'); // tmp0, pending
      transport.emitConn(ConnectionState.disconnected);
      await pump();
      transport.fences = {_chan: ''};
      transport.emitConn(ConnectionState.connected);
      await pump(); // drain registered a waiter, awaiting the ack

      // Race both completion paths on the SAME waiter Completer.
      transport.emitConn(ConnectionState.disconnected); // _failAllAckWaiters
      transport.emitAck('tmp0', '01U'); // _completeAckWaiter
      await pump();

      // No StateError poisoned the loop: a fresh send still works.
      await repo.sendMessage(_chan, 'again');
      await pump();
      expect((await rows()).any((m) => m.body == 'again'), isTrue);
    });

    test('reconnect-failure — getHistory 500 is caught + telemetered, guard '
        'clears (a later reconnect still runs)', () async {
      transport.fences = {_chan: '01A'};
      rest.throwOnGetHistory = StateError('boom 500');

      transport.emitConn(ConnectionState.connected);
      await pump();
      expect(spy.reconnectErrors, isNotEmpty,
          reason: 'the error is observed, not an unobserved async throw');

      // Guard cleared: a later reconnect (with history working) runs to success.
      rest.throwOnGetHistory = null;
      rest.pagesByAfter[''] = HistoryPage(
          channelId: _chan, messages: [_server('01A', 'a')], nextAfter: '01A');
      transport.emitConn(ConnectionState.disconnected);
      await pump();
      transport.emitConn(ConnectionState.connected);
      await pump();
      expect(await cache.historyContiguousThrough(_chan), '01A');
    });

    test('systemic-transient — a null-ref error leaves pending rows `sending` '
        '(not failed)', () async {
      await repo.sendMessage(_chan, 'hi');
      transport.emitError(const TransportError(
          code: 'rate_limited', detail: 'slow down', refClientMsgId: null));
      await pump();
      expect((await rows()).single.deliveryState, DeliveryState.sending,
          reason: 'transient systemic error must not fail the row');
      expect(await cache.outbox(), hasLength(1));
    });

    test('handoff-fence — a message ≤ fence is pulled by history even if the '
        'channel then goes silent', () async {
      // Z (01E) committed in the REST-vs-subscribe window, ≤ fence; no live emit.
      transport.fences = {_chan: '01F'};
      rest.pagesByAfter[''] = HistoryPage(
          channelId: _chan,
          messages: [
            _server('01C', 'c'),
            _server('01E', 'z'), // the quiet-channel message
            _server('01F', 'f'),
          ],
          nextAfter: '01F');

      transport.emitConn(ConnectionState.connected);
      await pump();
      // No further live messages, no reconnect — the channel is silent.
      final ids = (await rows()).map((m) => m.id).toSet();
      expect(ids.contains('01E'), isTrue,
          reason: 'history paged up to the fence, capturing Z');
      expect(await cache.historyContiguousThrough(_chan), '01F');
    });
  });
}
