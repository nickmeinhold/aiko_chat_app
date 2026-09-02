// Contract tests for the MANUAL-notify invariant (claude-tasks#2905).
//
// PR #130 made `notifyUpdates` manual on every writer (`allTables => []`, so drift
// no longer infers table-dirtiness from raw SQL). That bought a footgun: a future
// writer could mutate `messages` and forget to notify, leaving `watchChannel`
// silently stale while SQLite holds the truth. These tests lock BOTH halves of the
// contract so the footgun fails CI instead of shipping:
//   1. every public writer that changes a row EMITS on watchChannel;
//   2. the two no-op-prone writers (markFailed / retry) stay SILENT when their
//      `islandUlid IS NULL` guard matches zero rows (already-sent) — the "finish
//      the octave" consistency fix that gates their notify on rows-changed.
//
// Chosen over a `_mutate()` choke-point wrapper (the other option in #2905): a test
// encodes the same invariant without threading a `(result, wrote)` tuple through
// eight writers on the signed-at-birth trust boundary. Failure-visible > convenient.
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/domain/retraction.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

DriftCache makeCache() => DriftCache(NativeDatabase.memory());

const _me = MessageSender(userId: 'me', kind: SenderKind.human, label: 'Me');
const _alice = MessageSender(
  userId: 'u2',
  kind: SenderKind.human,
  label: 'Alice',
);

Message optimistic(String tempId, String channel, String body) => Message(
  clientTempId: tempId,
  channelId: channel,
  sender: _me,
  body: body,
  createdAt: DateTime.utc(2026, 1, 1, 12),
  deliveryState: DeliveryState.sending,
);

Message server(String ulid, String channel, String body) => Message(
  clientTempId: ulid,
  id: ulid,
  channelId: channel,
  sender: _alice,
  body: body,
  createdAt: DateTime.utc(2026, 1, 1, 12),
  deliveryState: DeliveryState.sent,
);

void main() {
  // Subscribe to watchChannel, drain the initial emission, run [act], and return
  // how many NEW emissions [act] produced. The whole point of the contract.
  Future<int> emissionsFrom(
    DriftCache cache,
    String channel,
    Future<void> Function() act,
  ) async {
    final seen = <List<Message>>[];
    final sub = cache.watchChannel(channel).listen(seen.add);
    await pumpEventQueue();
    final baseline = seen.length; // the initial on-listen emission
    expect(baseline, 1, reason: 'watchChannel emits once on listen');
    await act();
    await pumpEventQueue();
    await sub.cancel();
    return seen.length - baseline;
  }

  group('every writer emits on a real mutation', () {
    test('W1 insertOptimistic', () async {
      final cache = makeCache();
      expect(
        await emissionsFrom(
          cache,
          'c',
          () => cache.insertOptimistic(optimistic('t1', 'c', 'hi')),
        ),
        greaterThan(0),
      );
    });

    test('W2 reconcileAck (happy-path stamp)', () async {
      final cache = makeCache();
      await cache.insertOptimistic(optimistic('t1', 'c', 'hi'));
      expect(
        await emissionsFrom(
          cache,
          'c',
          () => cache.reconcileAck('t1', 'ULID1', DateTime.utc(2026, 1, 1, 12)),
        ),
        greaterThan(0),
      );
    });

    test('W3 upsertInbound (insert)', () async {
      final cache = makeCache();
      expect(
        await emissionsFrom(
          cache,
          'c',
          () => cache.upsertInbound(server('ULID2', 'c', 'yo')),
        ),
        greaterThan(0),
      );
    });

    test('W4 markFailed on a pending row', () async {
      final cache = makeCache();
      await cache.insertOptimistic(optimistic('t1', 'c', 'hi'));
      expect(
        await emissionsFrom(cache, 'c', () => cache.markFailed('t1')),
        greaterThan(0),
      );
    });

    test('W5 retry on a failed row', () async {
      final cache = makeCache();
      await cache.insertOptimistic(optimistic('t1', 'c', 'hi'));
      await cache.markFailed('t1'); // → failed
      expect(
        await emissionsFrom(cache, 'c', () => cache.retry('t1')),
        greaterThan(0),
      );
    });

    test('W6 applyRetraction on a present row', () async {
      final cache = makeCache();
      await cache.upsertInbound(server('ULID3', 'c', 'gone soon'));
      expect(
        await emissionsFrom(
          cache,
          'c',
          () => cache.applyRetraction(
            const Retraction(
              channelId: 'c',
              id: 'RETRACT1',
              targetMsgId: 'ULID3',
            ),
          ),
        ),
        greaterThan(0),
      );
    });
  });

  group('no-op writers stay silent (finish the octave)', () {
    test('markFailed on an already-sent row does NOT emit', () async {
      final cache = makeCache();
      await cache.insertOptimistic(optimistic('t1', 'c', 'hi'));
      await cache.reconcileAck(
        't1',
        'ULID1',
        DateTime.utc(2026, 1, 1, 12),
      ); // sent
      expect(
        // WHERE islandUlid IS NULL now matches zero rows.
        await emissionsFrom(cache, 'c', () => cache.markFailed('t1')),
        0,
      );
    });

    test('retry on an already-sent row does NOT emit', () async {
      final cache = makeCache();
      await cache.insertOptimistic(optimistic('t1', 'c', 'hi'));
      await cache.reconcileAck(
        't1',
        'ULID1',
        DateTime.utc(2026, 1, 1, 12),
      ); // sent
      expect(await emissionsFrom(cache, 'c', () => cache.retry('t1')), 0);
    });

    test('markFailed for an unknown ref does NOT emit', () async {
      final cache = makeCache();
      await cache.insertOptimistic(optimistic('t1', 'c', 'hi'));
      expect(
        await emissionsFrom(
          cache,
          'c',
          () => cache.markFailed('no-such-temp-id'),
        ),
        0,
      );
    });
  });
}
