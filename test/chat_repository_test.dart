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
import 'package:aiko_chat_app/features/chat/domain/ulid.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
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
  // The orphan test runs an isolated second in-memory cache concurrently with
  // the shared fixture (to capture its debug assert in a guarded zone). That is
  // exactly the case drift's multiple-database warning exists for; silence it.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

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
      transport.emitErrorCode('no_channel', detail: 'x', refClientMsgId: 'tmp0');
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
      transport.emitErrorCode('rate_limited', detail: 'slow down');
      await pump();
      expect((await rows()).single.deliveryState, DeliveryState.sending,
          reason: 'transient systemic error must not fail the row');
      expect(await cache.outbox(), hasLength(1));
    });

    test('rerun-no-resurrection — a disconnect after a queued rerun cancels it '
        '(no choreography against a disconnected transport)', () async {
      // connected (wedged in getHistory) → connected (queues a rerun) →
      // disconnected (must CANCEL the queued rerun). When the dead run finishes,
      // it must NOT resurrect the choreography: there is no live `connected`
      // justifying it. A genuine reconnect later would emit a fresh `connected`.
      transport.fences = {_chan: '01A'};
      rest.pagesByAfter[''] = HistoryPage(
          channelId: _chan, messages: [_server('01A', 'a')], nextAfter: '01A');
      rest.getHistoryGate = Completer<void>();

      transport.emitConn(ConnectionState.connected);
      await pump(); // first run wedged inside getHistory
      expect(transport.subscribeCalls, hasLength(1));

      transport.emitConn(ConnectionState.connected); // queues a rerun
      await pump();
      transport.emitConn(ConnectionState.disconnected); // must cancel the rerun
      await pump();

      rest.getHistoryGate!.complete(); // dead run resolves (aborted by epoch)
      await pump();

      expect(transport.subscribeCalls, hasLength(1),
          reason: 'the queued rerun was cancelled by the disconnect — no '
              'subscribe/drain/history against a disconnected transport');
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

  // --- the remaining design-04 ATDD specs (round-2..5 tail) ------------------

  group('ack-reorder (named tradeoff: server time wins)', () {
    test('a forward-skewed optimistic createdAt settles UPWARD to server time '
        'on ack', () async {
      // The optimistic row is clamped to `max(now, ...)` — with a fast-forward
      // client clock that is AHEAD of the server. On ack, W2 stamps the
      // authoritative server time, which is EARLIER, so the row moves up the
      // timeline. This is accepted (server time is the only order all clients
      // agree on); the test pins it so it can't masquerade as a regression.
      await repo.sendMessage(_chan, 'hi');
      final optimisticAt = (await rows()).single.createdAt;
      // Server time deliberately far in the PAST relative to any real `now`.
      const serverIso = '2020-01-01T00:00:00Z';
      transport.emitAck('tmp0', '01U', createdAt: serverIso);
      await pump();

      final r = (await rows()).single;
      expect(r.id, '01U');
      expect(r.deliveryState, DeliveryState.sent);
      expect(r.createdAt, DateTime.parse(serverIso).toUtc(),
          reason: 'server time wins — even though it moves the row upward');
      expect(r.createdAt.isBefore(optimisticAt), isTrue,
          reason: 'the named tradeoff: the row settles upward at ack');
    });
  });

  group('ack-already-acked (drain does not burn the timeout)', () {
    test('a row whose ack already settled does NOT make the drain wait', () async {
      // Ack lands while connected → the row leaves the outbox. A later reconnect
      // drain has nothing to await, so history runs PROMPTLY (well under the
      // 80ms ackTimeout) rather than burning the full timeout.
      await repo.sendMessage(_chan, 'hi');
      transport.emitAck('tmp0', '01U');
      await pump();
      expect(await cache.outbox(), isEmpty);

      transport.fences = {_chan: '01U'};
      rest.pagesByAfter[''] =
          HistoryPage(channelId: _chan, messages: [_server('01U', 'hi')], nextAfter: '01U');
      rest.getHistoryCalls.clear();

      transport.emitConn(ConnectionState.connected);
      // A probe SHORTER than the ackTimeout (80ms): if the drain wrongly waited
      // on the already-settled row, history would not have run yet.
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(rest.getHistoryCalls, isNotEmpty,
          reason: 'already-acked row left the outbox → drain did not wait');
    });

    test('counter-case — a self-echo alone does NOT early-complete the waiter '
        '(round-3 distinction)', () async {
      // W3 echo writes R_u keyed by serverUlid, but the optimistic row stays
      // serverUlid==NULL (collapse happens on ACK, not echo). So the row is
      // still in the outbox on reconnect, and the drain MUST wait for the real
      // ack — history is gated behind the ackTimeout, not the echo.
      await repo.sendMessage(_chan, 'hi');
      transport.emitMessage(_server('01U', 'hi')); // echo only, no ack
      await pump();
      expect(await cache.outbox(), hasLength(1),
          reason: 'optimistic row stays pending until the ACK collapse');

      transport.emitConn(ConnectionState.disconnected);
      await pump();
      transport.fences = {_chan: '01U'};
      rest.pagesByAfter[''] =
          HistoryPage(channelId: _chan, messages: [_server('01U', 'hi')], nextAfter: '01U');
      rest.getHistoryCalls.clear();

      transport.emitConn(ConnectionState.connected);
      // SHORT probe (< 80ms): the drain is still awaiting the ack, so no history.
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(rest.getHistoryCalls, isEmpty,
          reason: 'self-echo did not settle the row → drain waits for the ack');
      // After the timeout elapses, history runs anyway (drain does not hang).
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(rest.getHistoryCalls, isNotEmpty,
          reason: 'past the ackTimeout, history proceeds');
    });
  });

  group('B-live multi (one listener wiring, no leak across reconnects)', () {
    test('THREE reconnect cycles → one suback each; ack reconciles once; no '
        'handler fires after dispose', () async {
      await repo.sendMessage(_chan, 'hi'); // tmp0, pending
      transport.fences = {_chan: ''}; // empty channel → no history paging

      for (var i = 0; i < 3; i++) {
        transport.emitConn(ConnectionState.disconnected);
        await pump();
        transport.emitConn(ConnectionState.connected);
        await pump();
      }
      // A leaked/doubled connection-state listener would re-run the choreography
      // and subscribe MORE than once per reconnect. Exactly one per cycle proves
      // the streams were wired ONCE and outlive every reconnect (invariant B-live).
      expect(transport.subscribeCalls, hasLength(3),
          reason: 'one suback per reconnect — no doubled connection listener');

      transport.emitAck('tmp0', '01U');
      await pump();
      final r = await rows();
      expect(r, hasLength(1), reason: 'the ack reconciled exactly once');
      expect(r.single.id, '01U');
      expect(r.single.deliveryState, DeliveryState.sent);

      // After dispose, the inbound streams still exist but the repo cancelled its
      // subscriptions — a leaked W3 listener would upsert this; it must NOT appear.
      await repo.dispose();
      transport.emitMessage(_server('02Z', 'after dispose'));
      await pump();
      expect((await rows()).any((m) => m.id == '02Z'), isFalse,
          reason: 'no handler fires after dispose (subscriptions cancelled)');
    });
  });

  group('auth-terminal-catch (getHistory 401 routes to unauthenticated)', () {
    test('a terminal Unauthorized from getHistory disconnects (no transient '
        'redrain loop)', () async {
      // No pending row → the drain is empty and we reach getHistory directly.
      rest.throwOnGetHistory = const Unauthorized(401);
      transport.fences = {_chan: '01A'};

      transport.emitConn(ConnectionState.connected);
      await pump();

      expect(spy.reconnectErrors, isNotEmpty,
          reason: 'the auth failure is observed, not an unobserved async throw');
      expect(spy.reconnectErrors.last, isA<Unauthorized>());
      expect(transport.disconnectCalls, 1,
          reason: 'terminal auth → route to unauthenticated, not a transient redrain');
    });
  });

  group('systemic-terminal (auth error FRAME stops draining)', () {
    // Each terminal-auth wire code must route to disconnect (unauthenticated)
    // via the TYPED classification — NOT a raw-string compare a typo could break.
    for (final code in ['unauthorized', 'token_expired', 'forbidden']) {
      test('an auth-coded ($code) systemic error disconnects; rows stay sending',
          () async {
        await repo.sendMessage(_chan, 'hi'); // tmp0, pending
        transport.emitErrorCode(code, detail: 'auth');
        await pump();

        expect(transport.disconnectCalls, 1,
            reason: 'auth-coded systemic error routes to unauthenticated');
        expect((await rows()).single.deliveryState, DeliveryState.sending,
            reason: 'pending row untouched; it resumes after re-auth');
        expect(await cache.outbox(), hasLength(1));
      });
    }

    test('an UNKNOWN systemic code does NOT route to disconnect (not silently '
        'treated as auth-terminal)', () async {
      await repo.sendMessage(_chan, 'hi'); // tmp0, pending
      // A code we don't recognise (a typo or an additive server code) maps to
      // TransportErrorCode.unknown → NOT auth-terminal: it must not log the user
      // out. The row stays `sending` for the next reconnect's redrain.
      transport.emitErrorCode('unauthorised_typo', detail: 'oops');
      await pump();

      expect(transport.disconnectCalls, 0,
          reason: 'an unknown code must NOT be classified as auth-terminal');
      expect((await rows()).single.deliveryState, DeliveryState.sending,
          reason: 'unknown systemic code leaves the row sending (transient-safe)');
      expect(await cache.outbox(), hasLength(1));
    });

    test('TransportErrorCode.fromWire — known codes map; everything else is '
        'unknown (NOT other, NOT auth-terminal)', () {
      expect(TransportErrorCode.fromWire('unauthorized'),
          TransportErrorCode.unauthorized);
      expect(TransportErrorCode.fromWire('token_expired'),
          TransportErrorCode.tokenExpired);
      expect(
          TransportErrorCode.fromWire('forbidden'), TransportErrorCode.forbidden);
      expect(
          TransportErrorCode.fromWire('rate_limited'), TransportErrorCode.other);
      // The load-bearing assertion: a typo/additive code is `unknown`, and
      // `unknown` is NOT auth-terminal (so it can't downgrade a terminal auth
      // rejection into a logout, and can't masquerade as a known transient).
      expect(TransportErrorCode.fromWire('Unauthorized'),
          TransportErrorCode.unknown,
          reason: 'case-sensitive: canonical wire codes are lowercase');
      expect(
          TransportErrorCode.fromWire('totally_new'), TransportErrorCode.unknown);
      expect(TransportErrorCode.unknown.isAuthTerminal, isFalse);
      expect(TransportErrorCode.other.isAuthTerminal, isFalse);
      expect(TransportErrorCode.unauthorized.isAuthTerminal, isTrue);
    });
  });

  group('lifecycle guards (cage-match round-1 fixes)', () {
    test('start() is not idempotent — a second call is a loud StateError '
        '(B-live: streams wire ONCE)', () {
      // setUp already called start() once. A second call would double every
      // listener (doubled ack reconciliation + reconnect choreography).
      expect(() => repo.start(), throwsStateError);
    });

    test('an inbound W3 write that throws is OWNED via telemetry, not leaked '
        'as an unhandled async error', () async {
      // A message with a null serverUlid violates the cache contract
      // (upsertInbound requires id != null) → it throws. The handler must catch
      // it and surface it, leaving the stream alive.
      transport.emitMessage(Message(
        clientTempId: 'noid',
        id: null, // <- invalid for an inbound row; upsertInbound throws
        channelId: _chan,
        sender: const MessageSender(
            userId: 'u2', kind: SenderKind.human, label: 'Alice'),
        body: 'bad',
        createdAt: DateTime.parse('2026-01-01T12:00:00Z').toUtc(),
        deliveryState: DeliveryState.sent,
      ));
      await pump();

      expect(spy.inboundWriteErrors, hasLength(1),
          reason: 'the failed inbound write is observed, not an unowned throw');
      // The stream is still alive: a subsequent valid message lands fine.
      transport.emitMessage(_server('01U', 'ok'));
      await pump();
      expect((await rows()).any((m) => m.id == '01U'), isTrue);
    });

    test('post-dispose sendMessage/retry are a silent no-op (no write, no throw) '
        '— PR#7 finding 3', () async {
      await repo.dispose();
      // DECISION: silent-drop, not StateError — a post-dispose call is a benign
      // autoDispose lifecycle race, not a programming error. It must neither
      // crash nor touch the (closing) cache.
      await expectLater(repo.sendMessage(_chan, 'after dispose'), completes);
      await expectLater(repo.retry('whatever'), completes);
      await pump();
      // Nothing was written and no wire send was dispatched.
      expect(await rows(), isEmpty);
      expect(transport.sent, isEmpty);
    });
  });

  group('orphan (the impossible case is OBSERVED, not swallowed)', () {
    test('an ack for an unknown clientMsgId fires telemetry AND trips the debug '
        'assert (observed, never swallowed)', () async {
      // Unreachable in Phase 1 by construction (W1 persists before send), but the
      // enum + telemetry make it OBSERVABLE if it ever fires. The design's
      // tripwire is a debug `assert(false)` in `_onAck` — which surfaces as an
      // uncaught async error from the stream handler. We run on an ISOLATED
      // harness inside a guarded zone so that error is captured here (not leaked
      // into the shared fixtures), proving BOTH halves of the contract:
      // telemetry fires (the production signal) AND the assert trips (the dev
      // tripwire). In release the assert is stripped → telemetry-only, no crash.
      final localSpy = SpyTelemetry();
      final localCache = DriftCache(NativeDatabase.memory());
      final localTransport = FakeChatTransport();
      final caught = <Object>[];
      final localRepo = ChatRepository(
        cache: localCache,
        transport: localTransport,
        rest: FakeChatRestApi(),
        me: _me,
        subscribedChannelIds: const [_chan],
        telemetry: localSpy,
        ackTimeout: const Duration(milliseconds: 80),
        newTempId: () => 'x',
      );

      await runZonedGuarded(() async {
        localRepo.start(); // listeners run in THIS zone → its errors land here
        localTransport.emitAck('ghost', '01U'); // no optimistic row → orphaned
        await pump();
      }, (e, _) => caught.add(e));

      // The production-observable contract: telemetry surfaced the orphan.
      expect(localSpy.orphans, hasLength(1),
          reason: 'the orphan ack is surfaced to telemetry');
      expect(localSpy.orphans.single, ('ghost', '01U'));
      // The dev tripwire: the debug assert tripped (captured, not crashing).
      expect(caught, hasLength(1));
      expect(caught.single, isA<AssertionError>());
      // No row was created — the orphan is observed, NOT backfilled.
      expect(await localCache.watchChannel(_chan).first, isEmpty);

      await localRepo.dispose();
      await localTransport.dispose();
      await localCache.close();
    });
  });

  group('inbound serialization queue (PR#7 finding 2)', () {
    test('a slow inbound message BLOCKS a later ack — mutations run in arrival '
        'order, never interleaved', () async {
      // Isolated harness with a cache whose FIRST upsertInbound is gated, so we
      // can freeze message-A mid-write and prove the later ack waits behind it.
      final gate = Completer<void>();
      final order = <String>[];
      final gatedCache = _GatedCache(NativeDatabase.memory(),
          firstUpsertGate: gate, log: order);
      final t = FakeChatTransport();
      final r = ChatRepository(
        cache: gatedCache,
        transport: t,
        rest: FakeChatRestApi(),
        me: _me,
        subscribedChannelIds: const [_chan],
        ackTimeout: const Duration(milliseconds: 80),
        newTempId: () => 'tmp',
      );
      r.start();

      // Seed an optimistic row so the ack has something to reconcile.
      await r.sendMessage(_chan, 'mine');

      // Emit a message (its upsert will block on the gate) THEN an ack. Without
      // the FIFO, the ack's reconcile could interleave ahead of the stuck
      // upsert. With it, the ack cannot start until the upsert completes.
      t.emitMessage(_server('01B', 'theirs'));
      t.emitAck('tmp', '01A');
      await pump();

      // The message upsert started and is STILL blocked; the ack has NOT run.
      expect(order, ['upsert:01B-start'],
          reason: 'ack must wait behind the in-flight message (FIFO)');

      gate.complete(); // release message-A
      await pump();

      // Now both ran, in arrival order: message fully applied, THEN ack.
      expect(order, ['upsert:01B-start', 'upsert:01B-done', 'ack:tmp'],
          reason: 'mutations applied strictly in arrival order');

      await r.dispose();
      await t.dispose();
      await gatedCache.close();
    });
  });

  group('ULID canonical-case discipline (PR#7 finding 4)', () {
    test('isCanonicalUlidCase — uppercase Crockford passes, any lowercase fails',
        () {
      expect(isCanonicalUlidCase('01ARZ3NDEKTSV4RRFFQ69G5FAV'), isTrue);
      expect(isCanonicalUlidCase(''), isTrue); // empty fence sentinel
      expect(isCanonicalUlidCase('01arz3ndektsv4rrffq69g5fav'), isFalse);
      expect(isCanonicalUlidCase('01ARZ3NDEKTSV4RRFFQ69G5FAv'), isFalse,
          reason: 'a single lowercase char breaks compareTo monotonicity');
    });

    test('advanceHistoryContiguous asserts canonical case — a lowercase ULID '
        'fails LOUDLY, not silently', () async {
      // Canonical advances fine.
      await cache.advanceHistoryContiguous(_chan, '01ARZ3NDEKTSV4RRFFQ69G5FAV');
      expect(await cache.historyContiguousThrough(_chan),
          '01ARZ3NDEKTSV4RRFFQ69G5FAV');
      // A non-canonical (lowercase) watermark would sort wrongly — it must trip
      // the debug assert rather than silently corrupt the monotonic compare.
      expect(
        () => cache.advanceHistoryContiguous(_chan, '01arz3ndektsv4rrffq69g5fz'),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}

/// A [DriftCache] that gates its FIRST `upsertInbound` on a completer and logs
/// the start/finish of each inbound mutation — so a test can freeze one write
/// mid-flight and observe whether a later mutation interleaves (it must not,
/// once they share the repository's FIFO queue).
class _GatedCache extends DriftCache {
  _GatedCache(super.e, {required this.firstUpsertGate, required this.log});

  final Completer<void> firstUpsertGate;
  final List<String> log;
  bool _gated = false;

  @override
  Future<void> upsertInbound(Message serverMsg) async {
    log.add('upsert:${serverMsg.id}-start');
    if (!_gated) {
      _gated = true;
      await firstUpsertGate.future; // freeze the first message write
    }
    await super.upsertInbound(serverMsg);
    log.add('upsert:${serverMsg.id}-done');
  }

  @override
  Future<AckOutcome> reconcileAck(
      String clientTempId, String serverUlid, DateTime serverCreatedAt) {
    log.add('ack:$clientTempId');
    return super.reconcileAck(clientTempId, serverUlid, serverCreatedAt);
  }
}
