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
      // the merge DIRECTION, not just the count).
      await cache.upsertInbound(server('01ULID_A', 'chan', 'server-body',
          sender: _alice));
      // Now our ack lands, mapping c1 -> 01ULID_A.
      await cache.reconcileAck('c1', '01ULID_A', DateTime.utc(2026, 1, 1, 12, 9));

      final rows = await cache.watchChannel('chan').first;
      expect(rows, hasLength(1), reason: 'collapse must leave exactly one row');
      final m = rows.single;
      expect(m.clientTempId, 'c1', reason: 'optimistic-wins-on-PK (UI key)');
      expect(m.id, '01ULID_A');
      expect(m.body, 'server-body', reason: 'server-wins-on-fields');
      expect(m.sender.label, 'Alice', reason: 'server-wins-on-fields');
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

  group('Invariant A — stream atomicity (no transient observed duplicate)', () {
    test('collapse never emits a list containing two rows for one serverUlid',
        () async {
      await cache.insertOptimistic(optimistic('c1', 'chan', 'mine'));
      await cache.upsertInbound(server('01ULID_A', 'chan', 'server-body'));

      final emissions = <List<Message>>[];
      final sub = cache.watchChannel('chan').listen(emissions.add);
      await Future<void>.delayed(Duration.zero); // first emission

      await cache.reconcileAck('c1', '01ULID_A', DateTime.utc(2026, 1, 1, 12, 9));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      for (final list in emissions) {
        final ulids = list.map((m) => m.id).where((id) => id != null).toList();
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
