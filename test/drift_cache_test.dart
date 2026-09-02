// Acceptance tests for Component 3 — the drift cache.
// These encode the invariants from docs/design/03-drift-cache.html:
//   U (non-null islandUlid unique) · A (stream atomicity) · O (outbox-as-query)
//   and the W1-W5 writer contracts. Written test-first against the merged design.

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

/// An optimistic (un-acked) message as the composer would build it.
Message optimistic(
  String tempId,
  String channel,
  String body, {
  DateTime? at,
}) => Message(
  clientTempId: tempId,
  channelId: channel,
  sender: _me,
  body: body,
  createdAt: at ?? DateTime.utc(2026, 1, 1, 12),
  deliveryState: DeliveryState.sending,
);

/// A server-authoritative message (inbound fanout / history).
Message server(
  String ulid,
  String channel,
  String body, {
  DateTime? at,
  MessageSender sender = _alice,
}) => Message(
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
      await cache.reconcileAck(
        'c1',
        '01ULID_A',
        DateTime.utc(2026, 1, 1, 12, 1),
      );
      await cache.markFailed('c2');
      final out = await cache.outbox();
      expect(out, isEmpty);
    });

    // cage-match Carnot F2 + Tesla: a corrupt persisted signature column must
    // DEGRADE to null, never throw — a throw in the reconnect-drain rebuild would
    // abort the whole outbox flush and stall delivery.
    test(
      'outboundOrigin yields null on a corrupt signature column (no throw)',
      () async {
        await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
        // Populate the sig columns with INVALID base64 (a partial/corrupt persist).
        await cache.customStatement(
          "UPDATE messages SET sig = '!!!not-base64!!!', "
          "sender_pubkey = 'AAAA', signed_at_ms = 1, key_version = 1 "
          "WHERE client_temp_id = 'c1'",
        );
        // Must not throw; degrades to null (message emits unsigned, drain survives).
        expect(await cache.outboundOrigin('c1'), isNull);
      },
    );

    // cage-match Carnot R2: valid base64 but WRONG length (a 4-byte "key") must
    // also degrade to null, so the emit path never relies on a downstream throw.
    test(
      'outboundOrigin yields null on valid-base64 wrong-length crypto',
      () async {
        await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
        await cache.customStatement(
          "UPDATE messages SET sig = 'AAAA', sender_pubkey = 'AAAA', "
          "signed_at_ms = 1, key_version = 1 WHERE client_temp_id = 'c1'",
        );
        expect(await cache.outboundOrigin('c1'), isNull);
      },
    );
  });

  group('W2 — ack reconcile', () {
    test('happy path: stamps islandUlid + marks sent, one row', () async {
      await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
      await cache.reconcileAck(
        'c1',
        '01ULID_A',
        DateTime.utc(2026, 1, 1, 12, 5),
      );

      final rows = await cache.watchChannel('chan').first;
      expect(rows, hasLength(1));
      expect(rows.single.clientTempId, 'c1');
      expect(rows.single.id, '01ULID_A');
      expect(rows.single.deliveryState, DeliveryState.sent);
    });

    test(
      'collapse: history wins first, ack merges server truth INTO optimistic '
      'row, keeps clientTempId, deletes R_u (THE CRUX)',
      () async {
        // Optimistic row we sent.
        await cache.insertOptimistic(optimistic('c1', 'chan', 'mine'));
        // History fetched the server copy first (different body/sender to prove
        // the merge DIRECTION, not just the count). Distinct history time to
        // prove the collapse stamps the ACK time, not R_u's, consistently with
        // the happy path (Carnot finding).
        await cache.upsertInbound(
          server(
            '01ULID_A',
            'chan',
            'server-body',
            sender: _alice,
            at: DateTime.utc(2026, 1, 1, 12, 0),
          ),
        );
        // Now our ack lands, mapping c1 -> 01ULID_A, with its own server time.
        final ackTime = DateTime.utc(2026, 1, 1, 12, 9);
        await cache.reconcileAck('c1', '01ULID_A', ackTime);

        final rows = await cache.watchChannel('chan').first;
        expect(
          rows,
          hasLength(1),
          reason: 'collapse must leave exactly one row',
        );
        final m = rows.single;
        expect(m.clientTempId, 'c1', reason: 'optimistic-wins-on-PK (UI key)');
        expect(m.id, '01ULID_A');
        expect(m.body, 'server-body', reason: 'server-wins-on-fields');
        expect(m.sender.label, 'Alice', reason: 'server-wins-on-fields');
        expect(
          m.createdAt,
          ackTime,
          reason: 'collapse stamps the ACK time, same as the happy path',
        );
        expect(m.deliveryState, DeliveryState.sent);
      },
    );

    test(
      'guard: a late ack does not regress an already-reconciled row',
      () async {
        await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
        await cache.reconcileAck(
          'c1',
          '01ULID_A',
          DateTime.utc(2026, 1, 1, 12, 5),
        );
        // A duplicate/late ack for the same tempId must be a no-op.
        await cache.reconcileAck(
          'c1',
          '01ULID_A',
          DateTime.utc(2026, 1, 1, 12, 6),
        );
        final rows = await cache.watchChannel('chan').first;
        expect(rows, hasLength(1));
        expect(rows.single.id, '01ULID_A');
      },
    );
  });

  group('Invariant A — stream atomicity', () {
    test(
      'collapse commits as exactly ONE emission (no mid-transaction '
      'delete/update emission) AND never shows a duplicate islandUlid',
      () async {
        await cache.insertOptimistic(optimistic('c1', 'chan', 'mine'));
        await cache.upsertInbound(server('01ULID_A', 'chan', 'server-body'));

        final emissions = <List<Message>>[];
        final sub = cache.watchChannel('chan').listen(emissions.add);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final before = emissions.length; // the initial 2-row emission

        await cache.reconcileAck(
          'c1',
          '01ULID_A',
          DateTime.utc(2026, 1, 1, 12, 9),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await sub.cancel();

        // The collapse's delete + update are ONE transaction, so the watcher
        // fires ONCE post-commit. Without the transaction, delete-then-update
        // would emit the intermediate [R_c(null)] state too (an extra emission).
        // This is what actually tests Invariant A — the same-islandUlid check
        // below is necessary but, with delete-first ordering, not sufficient.
        expect(
          emissions.length - before,
          1,
          reason: 'collapse must emit exactly once (single transaction)',
        );
        expect(emissions.last, hasLength(1));

        for (final list in emissions) {
          final ulids = list.map((m) => m.id).whereType<String>().toList();
          expect(
            ulids.length,
            ulids.toSet().length,
            reason: 'no emission may contain two rows for one islandUlid',
          );
        }
      },
    );
  });

  group('W3 — inbound dedup-upsert', () {
    test('delivering the same ULID twice keeps one row', () async {
      await cache.upsertInbound(server('01ULID_A', 'chan', 'v1'));
      await cache.upsertInbound(server('01ULID_A', 'chan', 'v2'));
      final rows = await cache.watchChannel('chan').first;
      expect(rows, hasLength(1));
      expect(
        rows.single.body,
        'v2',
        reason: 'upsert updates, never blind-drop',
      );
    });

    test(
      'cross-channel islandUlid match is corruption (fails loudly)',
      () async {
        await cache.upsertInbound(server('01ULID_A', 'chanA', 'x'));
        expect(
          () => cache.upsertInbound(server('01ULID_A', 'chanB', 'x')),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('W4 — error handler', () {
    test(
      'per-message error fails a sending row; it leaves the outbox',
      () async {
        await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
        await cache.markFailed('c1');
        final rows = await cache.watchChannel('chan').first;
        expect(rows.single.deliveryState, DeliveryState.failed);
        expect(await cache.outbox(), isEmpty);
      },
    );

    test('a late error does NOT regress an already-sent row', () async {
      await cache.insertOptimistic(optimistic('c1', 'chan', 'hi'));
      await cache.reconcileAck(
        'c1',
        '01ULID_A',
        DateTime.utc(2026, 1, 1, 12, 5),
      );
      await cache.markFailed('c1'); // late error for a now-sent row
      final rows = await cache.watchChannel('chan').first;
      expect(
        rows.single.deliveryState,
        DeliveryState.sent,
        reason: 'guard: only islandUlid IS NULL rows can be failed',
      );
    });

    test(
      'null-ref (systemic) error surfaces pending rows, never silent-drops',
      () async {
        await cache.insertOptimistic(optimistic('c1', 'chan', 'a'));
        await cache.insertOptimistic(optimistic('c2', 'chan', 'b'));
        final affected = await cache.markFailed(
          null,
          systemicChannelId: 'chan',
        );
        expect(affected.map((m) => m.clientTempId), containsAll(['c1', 'c2']));
      },
    );

    test(
      'systemic error scoped to a channel does NOT leak other channels',
      () async {
        await cache.insertOptimistic(optimistic('c1', 'chanA', 'a'));
        await cache.insertOptimistic(optimistic('c2', 'chanB', 'b'));
        final affected = await cache.markFailed(
          null,
          systemicChannelId: 'chanA',
        );
        expect(affected.map((m) => m.clientTempId), [
          'c1',
        ], reason: 'the channel filter must AND with islandUlid IS NULL');
      },
    );
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

    test(
      'retry PRESERVES timeline position (does not teleport to the bottom)',
      () async {
        // Distinct times so position is sort-determined, not bucket-tied —
        // c1 is earlier and must STAY earlier after a retry.
        await cache.insertOptimistic(
          optimistic('c1', 'chan', 'first', at: DateTime.utc(2026, 1, 1, 12)),
        );
        await cache.insertOptimistic(
          optimistic(
            'c2',
            'chan',
            'second',
            at: DateTime.utc(2026, 1, 1, 12, 5),
          ),
        );
        await cache.markFailed('c1');
        await cache.retry('c1');
        final out = await cache.outbox();
        expect(out.map((m) => m.clientTempId).toList(), [
          'c1',
          'c2',
        ], reason: 'retry keeps the message in its original timeline position');
      },
    );
  });

  group('localSeq — send-order tiebreak under clock collision', () {
    test('two sends with the SAME createdAt render in compose order', () async {
      final t = DateTime.utc(2049, 1, 1); // grossly skewed, but identical
      await cache.insertOptimistic(optimistic('first', 'chan', '1', at: t));
      await cache.insertOptimistic(optimistic('second', 'chan', '2', at: t));
      final rows = await cache.watchChannel('chan').first;
      expect(rows.map((m) => m.clientTempId).toList(), [
        'first',
        'second',
      ], reason: 'localSeq preserves compose order, not random uuid order');
    });
  });

  // --- W6: retraction (moderator takedown, island #104) ---------------------
  // The two-door suppression invariant (crucible F1+F3): a takedown records a
  // presence-independent dead id, and BOTH cache write doors (upsertInbound W3,
  // reconcileAck W2) suppress it thereafter — so a taken-down message can never
  // (re)appear regardless of arrival order or which door it comes through.
  Retraction retract(
    String targetMsgId,
    String retractionId, {
    String channel = 'chan',
  }) => Retraction(
    channelId: channel,
    id: retractionId,
    targetMsgId: targetMsgId,
  );

  Future<List<Message>> chanRows([String channel = 'chan']) =>
      cache.watchChannel(channel).first;

  group('W6 — applyRetraction (hard-delete + dead id)', () {
    test('hard-deletes a present target row and records the dead id', () async {
      await cache.upsertInbound(server('01A', 'chan', 'objectionable'));
      expect(await chanRows(), hasLength(1));
      await cache.applyRetraction(retract('01A', '01Z'));
      expect(await chanRows(), isEmpty, reason: 'target hard-deleted');
    });

    test('is idempotent — applying twice is a no-op (PK dead id)', () async {
      await cache.upsertInbound(server('01A', 'chan', 'x'));
      await cache.applyRetraction(retract('01A', '01Z'));
      await cache.applyRetraction(retract('01A', '01Z')); // again
      expect(await chanRows(), isEmpty);
      // And a later re-upsert is still suppressed (dead id persisted once).
      expect(
        (await cache.upsertInbound(server('01A', 'chan', 'x'))).inserted,
        isFalse,
        reason: 'dead id persisted once — still suppressed, nothing written',
      );
      expect(await chanRows(), isEmpty);
    });

    test(
      'does NOT touch the history watermark (D4: suppress-only, pager is the '
      'single writer)',
      () async {
        await cache.advanceHistoryContiguous('chan', '01M');
        await cache.applyRetraction(retract('01A', '01Z'));
        expect(
          await cache.historyContiguousThrough('chan'),
          '01M',
          reason: 'a retraction never advances or rewinds the watermark',
        );
      },
    );
  });

  group('W3 Door A — upsertInbound suppresses a dead id', () {
    test('retraction BEFORE the message → message never inserted '
        '(presence-independent)', () async {
      // The target was NEVER synced (e.g. a takedown of an already-husked msg, or
      // a reconnect where the retraction is seen first). Recording the dead id
      // must not require the row to exist.
      await cache.applyRetraction(retract('01A', '01Z'));
      final r = await cache.upsertInbound(server('01A', 'chan', 'late'));
      // `inserted` is the field that actually means "nothing written" — the old
      // bool was `newlyInvalid` and only coincidentally false here, so this
      // assertion now tests the reason it always claimed to (cage-match #139 R5).
      expect(
        r.inserted,
        isFalse,
        reason: 'suppressed at Door A, nothing written',
      );
      expect(await chanRows(), isEmpty);
    });

    test(
      'message AFTER a delete (buffered frame / reconnect re-walk) stays gone',
      () async {
        await cache.upsertInbound(server('01A', 'chan', 'x'));
        await cache.applyRetraction(retract('01A', '01Z')); // deletes it
        // A buffered fanout frame or a history re-walk re-delivers 01A.
        final r = await cache.upsertInbound(server('01A', 'chan', 'x'));
        expect(r.inserted, isFalse, reason: 'no resurrection, nothing written');
        expect(await chanRows(), isEmpty, reason: 'no resurrection');
      },
    );

    test('an UNrelated message is unaffected by a dead id', () async {
      await cache.applyRetraction(retract('01A', '01Z'));
      // (upsertInbound's bool is the #1896 invalid-origin probe, not an
      // insert flag — for a plain message it is false either way; the row's
      // PRESENCE is the real proof the dead id didn't suppress it.)
      await cache.upsertInbound(server('01B', 'chan', 'fine'));
      expect(await chanRows(), hasLength(1));
      expect((await chanRows()).single.id, '01B');
    });
  });

  group('W2 Door B — reconcileAck suppresses a dead id (own-message takedown)', () {
    test('pending own-message taken down, THEN its ack → retracted + '
        'optimistic row hard-deleted, never resurrected', () async {
      await cache.insertOptimistic(optimistic('tmp', 'chan', 'my message'));
      // The takedown lands while the ack is still in flight. applyRetraction
      // deletes by islandUlid, but the optimistic row has islandUlid NULL, so it
      // is NOT matched here — it is the second door the dead id must cover.
      await cache.applyRetraction(retract('01A', '01Z'));
      expect(
        await chanRows(),
        hasLength(1),
        reason: 'optimistic (islandUlid NULL) row untouched by applyRetraction',
      );
      final outcome = await cache.reconcileAck(
        'tmp',
        '01A',
        DateTime.utc(2026, 1, 1, 12, 1),
      );
      expect(outcome, AckOutcome.retracted);
      expect(
        await chanRows(),
        isEmpty,
        reason:
            'the ack hard-deletes the optimistic row instead of stamping it',
      );
    });

    test('acked+stamped own-message taken down, THEN a duplicate ack → retracted '
        '(NOT orphaned — no false tripwire)', () async {
      await cache.insertOptimistic(optimistic('tmp', 'chan', 'my message'));
      final first = await cache.reconcileAck(
        'tmp',
        '01A',
        DateTime.utc(2026, 1, 1, 12, 1),
      );
      expect(first, AckOutcome.reconciled); // stamped
      await cache.applyRetraction(retract('01A', '01Z')); // hard-deletes it
      expect(await chanRows(), isEmpty);
      // A duplicate/late ack now finds no row. Under the dead id this is EXPECTED
      // (retracted), not the orphan invariant violation.
      final dup = await cache.reconcileAck(
        'tmp',
        '01A',
        DateTime.utc(2026, 1, 1, 12, 1),
      );
      expect(dup, AckOutcome.retracted);
    });

    test(
      'a normal orphan ack (no dead id) is still orphaned, not retracted',
      () async {
        final outcome = await cache.reconcileAck(
          'nope',
          '01A',
          DateTime.utc(2026, 1, 1, 12, 1),
        );
        expect(
          outcome,
          AckOutcome.orphaned,
          reason: 'the retracted split must not swallow a genuine orphan',
        );
      },
    );
  });

  group('searchMessages — grep tier (#8)', () {
    test(
      'case-insensitive substring match across channels, newest first',
      () async {
        await cache.upsertInbound(
          server(
            '01A',
            'chanA',
            'The quick brown fox',
            at: DateTime.utc(2026, 1, 1, 12, 0),
          ),
        );
        await cache.upsertInbound(
          server(
            '01B',
            'chanB',
            'lazy FOX sleeping',
            at: DateTime.utc(2026, 1, 1, 12, 5),
          ),
        );
        await cache.upsertInbound(
          server(
            '01C',
            'chanA',
            'no match here',
            at: DateTime.utc(2026, 1, 1, 12, 9),
          ),
        );

        final hits = await cache.searchMessages('fox');
        expect(hits.map((m) => m.id), [
          '01B',
          '01A',
        ], reason: 'both channels matched, case-insensitive, newest-first');
      },
    );

    test(
      'a retracted message never appears in results (hard-deleted)',
      () async {
        await cache.upsertInbound(server('01A', 'chan', 'secret plans'));
        expect(await cache.searchMessages('secret'), hasLength(1));
        await cache.applyRetraction(
          Retraction(channelId: 'chan', id: '01Z', targetMsgId: '01A'),
        );
        expect(
          await cache.searchMessages('secret'),
          isEmpty,
          reason:
              'retraction hard-deletes the row, so search cannot surface it',
        );
      },
    );

    test(
      'LIKE wildcards in the query are literal (escaped), not patterns',
      () async {
        await cache.upsertInbound(
          server('01A', 'chan', 'discount is 50% today'),
        );
        await cache.upsertInbound(server('01B', 'chan', 'plain text'));
        // '%' must match the literal percent, NOT act as a match-anything wildcard.
        final pct = await cache.searchMessages('50%');
        expect(pct.map((m) => m.id), ['01A']);
        expect(
          await cache.searchMessages('%'),
          hasLength(1),
          reason: 'a bare % is a literal, matching only the row containing it',
        );
      },
    );

    test('empty / whitespace query returns nothing without scanning', () async {
      await cache.upsertInbound(server('01A', 'chan', 'anything'));
      expect(await cache.searchMessages(''), isEmpty);
      expect(await cache.searchMessages('   '), isEmpty);
    });
  });
}
