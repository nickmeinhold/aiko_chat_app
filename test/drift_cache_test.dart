// Acceptance tests for Component 3 — the drift cache.
// These encode the invariants from docs/design/03-drift-cache.html:
//   U (non-null serverUlid unique) · A (stream atomicity) · O (outbox-as-query)
//   and the W1-W5 writer contracts. Written test-first against the merged design.

import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

DriftCache makeCache() => DriftCache(NativeDatabase.memory());

const _me = MessageSender(userId: 'me', kind: SenderKind.human, label: 'Me');
const _alice =
    MessageSender(userId: 'u2', kind: SenderKind.human, label: 'Alice');

/// An optimistic (un-acked) message as the composer would build it.
Message optimistic(String tempId, String channel, String body,
        {DateTime? at}) =>
    Message(
      clientTempId: tempId,
      channelId: channel,
      sender: _me,
      body: body,
      createdAt: at ?? DateTime.utc(2026, 1, 1, 12),
      deliveryState: DeliveryState.sending,
    );

/// A server-authoritative message (inbound fanout / history).
Message server(String ulid, String channel, String body,
        {DateTime? at, MessageSender sender = _alice}) =>
    Message(
      clientTempId: ulid,
      id: ulid,
      channelId: channel,
      sender: sender,
      body: body,
      createdAt: at ?? DateTime.utc(2026, 1, 1, 12),
      deliveryState: DeliveryState.sent,
    );

void main() {
  late DriftCache cache;
  setUp(() => cache = makeCache());
  tearDown(() => cache.close());

  group('W1 — optimistic insert + Invariant O (outbox-as-query)', () {
    test('optimistic row appears in the outbox as sending', () async {
      await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
      final out = await cache.outbox();
      expect(out, hasLength(1));
      expect(out.single.clientTempId, 'c1');
      expect(out.single.id, isNull);
      expect(out.single.deliveryState, DeliveryState.sending);
    });

    test('acked and failed rows leave the outbox', () async {
      await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
      await cache.insertOptimistic(optimistic('c2', 'chan', 'yo'));
      await cache.reconcileAck('c1', '01ULID_A', DateTime.utc(2026, 1, 1, 12, 1));
      await cache.markFailed('c2');
      final out = await cache.outbox();
      expect(out, isEmpty);
    });

    // cage-match Carnot F2 + Tesla: a corrupt persisted signature column must
    // DEGRADE to null, never throw — a throw in the reconnect-drain rebuild would
    // abort the whole outbox flush and stall delivery.
    test('outboundOrigin yields null on a corrupt signature column (no throw)',
        () async {
      await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
      // Populate the sig columns with INVALID base64 (a partial/corrupt persist).
      await cache.customStatement(
          "UPDATE messages SET sig = '!!!not-base64!!!', "
          "sender_pubkey = 'AAAA', signed_at_ms = 1, key_version = 1 "
          "WHERE client_temp_id = 'c1'");
      // Must not throw; degrades to null (message emits unsigned, drain survives).
      expect(await cache.outboundOrigin('c1'), isNull);
    });

    // cage-match Carnot R2: valid base64 but WRONG length (a 4-byte "key") must
    // also degrade to null, so the emit path never relies on a downstream throw.
    test('outboundOrigin yields null on valid-base64 wrong-length crypto',
        () async {
      await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
      await cache.customStatement(
          "UPDATE messages SET sig = 'AAAA', sender_pubkey = 'AAAA', "
          "signed_at_ms = 1, key_version = 1 WHERE client_temp_id = 'c1'");
      expect(await cache.outboundOrigin('c1'), isNull);
    });
  });

  group('W2 — ack reconcile', () {
    test('happy path: stamps serverUlid + marks sent, one row', () async {
      await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
      await cache.reconcileAck('c1', '01ULID_A', DateTime.utc(2026, 1, 1, 12, 5));

      final rows = await cache.watchChannel('chan').first;
      expect(rows, hasLength(1));
      expect(rows.single.clientTempId, 'c1');
      expect(rows.single.id, '01ULID_A');
      expect(rows.single.deliveryState, DeliveryState.sent);
    });

    test(
        'collapse: history wins first, ack merges server truth INTO optimistic '
        'row, keeps clientTempId, deletes R_u (THE CRUX)', () async {
      // Optimistic row we sent.
      await cache.insertOptimistic(optimistic('c1', 'chan', 'mine'));
      // History fetched the server copy first (different body/sender to prove
      // the merge DIRECTION, not just the count). Distinct history time to
      // prove the collapse stamps the ACK time, not R_u's, consistently with
      // the happy path (Carnot finding).
      await cache.upsertInbound(server('01ULID_A', 'chan', 'server-body',
          sender: _alice, at: DateTime.utc(2026, 1, 1, 12, 0)));
      // Now our ack lands, mapping c1 -> 01ULID_A, with its own server time.
      final ackTime = DateTime.utc(2026, 1, 1, 12, 9);
      await cache.reconcileAck('c1', '01ULID_A', ackTime);

      final rows = await cache.watchChannel('chan').first;
      expect(rows, hasLength(1), reason: 'collapse must leave exactly one row');
      final m = rows.single;
      expect(m.clientTempId, 'c1', reason: 'optimistic-wins-on-PK (UI key)');
      expect(m.id, '01ULID_A');
      expect(m.body, 'server-body', reason: 'server-wins-on-fields');
      expect(m.sender.label, 'Alice', reason: 'server-wins-on-fields');
      expect(m.createdAt, ackTime,
          reason: 'collapse stamps the ACK time, same as the happy path');
      expect(m.deliveryState, DeliveryState.sent);
    });

    test('guard: a late ack does not regress an already-reconciled row',
        () async {
      await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
      await cache.reconcileAck('c1', '01ULID_A', DateTime.utc(2026, 1, 1, 12, 5));
      // A duplicate/late ack for the same tempId must be a no-op.
      await cache.reconcileAck('c1', '01ULID_A', DateTime.utc(2026, 1, 1, 12, 6));
      final rows = await cache.watchChannel('chan').first;
      expect(rows, hasLength(1));
      expect(rows.single.id, '01ULID_A');
    });
  });

  group('Invariant A — stream atomicity', () {
    test(
        'collapse commits as exactly ONE emission (no mid-transaction '
        'delete/update emission) AND never shows a duplicate serverUlid',
        () async {
      await cache.insertOptimistic(optimistic('c1', 'chan', 'mine'));
      await cache.upsertInbound(server('01ULID_A', 'chan', 'server-body'));

      final emissions = <List<Message>>[];
      final sub = cache.watchChannel('chan').listen(emissions.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final before = emissions.length; // the initial 2-row emission

      await cache.reconcileAck('c1', '01ULID_A', DateTime.utc(2026, 1, 1, 12, 9));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();

      // The collapse's delete + update are ONE transaction, so the watcher
      // fires ONCE post-commit. Without the transaction, delete-then-update
      // would emit the intermediate [R_c(null)] state too (an extra emission).
      // This is what actually tests Invariant A — the same-serverUlid check
      // below is necessary but, with delete-first ordering, not sufficient.
      expect(emissions.length - before, 1,
          reason: 'collapse must emit exactly once (single transaction)');
      expect(emissions.last, hasLength(1));

      for (final list in emissions) {
        final ulids = list.map((m) => m.id).whereType<String>().toList();
        expect(ulids.length, ulids.toSet().length,
            reason: 'no emission may contain two rows for one serverUlid');
      }
    });
  });

  group('W3 — inbound dedup-upsert', () {
    test('delivering the same ULID twice keeps one row', () async {
      await cache.upsertInbound(server('01ULID_A', 'chan', 'v1'));
      await cache.upsertInbound(server('01ULID_A', 'chan', 'v2'));
      final rows = await cache.watchChannel('chan').first;
      expect(rows, hasLength(1));
      expect(rows.single.body, 'v2', reason: 'upsert updates, never blind-drop');
    });

    test('cross-channel serverUlid match is corruption (fails loudly)',
        () async {
      await cache.upsertInbound(server('01ULID_A', 'chanA', 'x'));
      expect(
        () => cache.upsertInbound(server('01ULID_A', 'chanB', 'x')),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('W4 — error handler', () {
    test('per-message error fails a sending row; it leaves the outbox',
        () async {
      await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
      await cache.markFailed('c1');
      final rows = await cache.watchChannel('chan').first;
      expect(rows.single.deliveryState, DeliveryState.failed);
      expect(await cache.outbox(), isEmpty);
    });

    test('a late error does NOT regress an already-sent row', () async {
      await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
      await cache.reconcileAck('c1', '01ULID_A', DateTime.utc(2026, 1, 1, 12, 5));
      await cache.markFailed('c1'); // late error for a now-sent row
      final rows = await cache.watchChannel('chan').first;
      expect(rows.single.deliveryState, DeliveryState.sent,
          reason: 'guard: only serverUlid IS NULL rows can be failed');
    });

    test('null-ref (systemic) error surfaces pending rows, never silent-drops',
        () async {
      await cache.insertOptimistic(optimistic('c1', 'chan', 'a'));
      await cache.insertOptimistic(optimistic('c2', 'chan', 'b'));
      final affected = await cache.markFailed(null, systemicChannelId: 'chan');
      expect(affected.map((m) => m.clientTempId), containsAll(['c1', 'c2']));
    });

    test('systemic error scoped to a channel does NOT leak other channels',
        () async {
      await cache.insertOptimistic(optimistic('c1', 'chanA', 'a'));
      await cache.insertOptimistic(optimistic('c2', 'chanB', 'b'));
      final affected = await cache.markFailed(null, systemicChannelId: 'chanA');
      expect(affected.map((m) => m.clientTempId), ['c1'],
          reason: 'the channel filter must AND with serverUlid IS NULL');
    });
  });

  group('W5 — manual retry', () {
    test('failed row returns to sending, re-enters the outbox', () async {
      await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
      await cache.markFailed('c1');
      expect(await cache.outbox(), isEmpty);
      await cache.retry('c1');
      final out = await cache.outbox();
      expect(out, hasLength(1));
      expect(out.single.deliveryState, DeliveryState.sending);
    });

    test('retry PRESERVES timeline position (does not teleport to the bottom)',
        () async {
      // Distinct times so position is sort-determined, not bucket-tied —
      // c1 is earlier and must STAY earlier after a retry.
      await cache.insertOptimistic(
          optimistic('c1', 'chan', 'first', at: DateTime.utc(2026, 1, 1, 12)));
      await cache.insertOptimistic(optimistic('c2', 'chan', 'second',
          at: DateTime.utc(2026, 1, 1, 12, 5)));
      await cache.markFailed('c1');
      await cache.retry('c1');
      final out = await cache.outbox();
      expect(out.map((m) => m.clientTempId).toList(), ['c1', 'c2'],
          reason: 'retry keeps the message in its original timeline position');
    });
  });

  group('localSeq — send-order tiebreak under clock collision', () {
    test('two sends with the SAME createdAt render in compose order', () async {
      final t = DateTime.utc(2049, 1, 1); // grossly skewed, but identical
      await cache.insertOptimistic(optimistic('first', 'chan', '1', at: t));
      await cache.insertOptimistic(optimistic('second', 'chan', '2', at: t));
      final rows = await cache.watchChannel('chan').first;
      expect(rows.map((m) => m.clientTempId).toList(), ['first', 'second'],
          reason: 'localSeq preserves compose order, not random uuid order');
    });
  });
}
