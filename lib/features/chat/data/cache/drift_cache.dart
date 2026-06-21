/// Component 3 — the drift cache (design: docs/design/03-drift-cache.html).
///
/// The on-device SQLite store the repository / B4 reconcile engine writes
/// through. This file owns *storage, atomic operations, and invariant
/// enforcement*; B4 owns *policy* (ordering, when to drain). The load-bearing
/// invariant is **U**: every NON-NULL `serverUlid` is UNIQUE, so duplication —
/// the app's worst failure — is structurally impossible at rest.
///
/// Writer census (every path that mutates a `messages` row):
///   W1 insertOptimistic · W2 reconcileAck · W3 upsertInbound ·
///   W4 markFailed · W5 retry · W6 delete (Phase 2, unsupported here).
library;

import 'package:drift/drift.dart';

import '../../domain/message.dart';

part 'drift_cache.g.dart';

/// The `messages` table. `@DataClassName('MessageRow')` avoids colliding with
/// the domain [Message] type.
@DataClassName('MessageRow')
class Messages extends Table {
  /// Durable PK — client uuid for optimistic rows, the server ULID for inbound.
  TextColumn get clientTempId => text()();

  /// Dedup authority. NULL until acked; SQLite allows many NULLs in a UNIQUE
  /// index, which is exactly what lets un-acked optimistic rows coexist
  /// (Invariant U is "every NON-NULL serverUlid is unique").
  TextColumn get serverUlid => text().nullable().unique()();

  TextColumn get channelId => text()();
  TextColumn get senderUserId => text().nullable()();
  TextColumn get senderKind => text()();
  TextColumn get senderLabel => text().nullable()();
  TextColumn get kind => text()();
  TextColumn get body => text()();
  TextColumn get replyToId => text().nullable()();

  /// UTC unix millis. Server time once acked; clamped client time while pending.
  IntColumn get createdAt => integer()();

  /// DB-derived monotonic compose counter (W1: MAX+1 in-txn). Send-order
  /// tiebreak so rapid sends under a skewed clock keep compose order. 0 inbound.
  IntColumn get localSeq => integer().withDefault(const Constant(0))();

  TextColumn get deliveryState => text()();

  @override
  Set<Column> get primaryKey => {clientTempId};
}

/// The `channels` table (CH1 channel-list sync is its only Phase-1 writer).
class Channels extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get kind => text()();
  TextColumn get aikoChannel => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Messages, Channels])
class DriftCache extends _$DriftCache {
  DriftCache(super.e);

  @override
  int get schemaVersion => 1;

  // --- conversion -----------------------------------------------------------

  Message _toDomain(MessageRow r) => Message(
        clientTempId: r.clientTempId,
        id: r.serverUlid,
        channelId: r.channelId,
        sender: MessageSender(
          userId: r.senderUserId,
          kind: SenderKind.fromWire(r.senderKind),
          label: r.senderLabel,
        ),
        kind: MessageKind.fromWire(r.kind),
        body: r.body,
        replyToId: r.replyToId,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt, isUtc: true),
        deliveryState: DeliveryState.fromWire(r.deliveryState),
      );

  MessagesCompanion _fromDomain(Message m, {required int localSeq}) =>
      MessagesCompanion.insert(
        clientTempId: m.clientTempId,
        serverUlid: Value(m.id),
        channelId: m.channelId,
        senderUserId: Value(m.sender.userId),
        senderKind: m.sender.kind.wire,
        senderLabel: Value(m.sender.label),
        kind: m.kind.wire,
        body: m.body,
        replyToId: Value(m.replyToId),
        createdAt: m.createdAt.toUtc().millisecondsSinceEpoch,
        localSeq: Value(localSeq),
        deliveryState: m.deliveryState.wire,
      );

  /// `MAX(localSeq)+1`. Race-free ONLY because drift serializes queries on a
  /// single connection and SQLite is single-writer, so the enclosing
  /// transaction's SELECT-then-INSERT can't interleave with another. This holds
  /// for Phase 1 (one isolate, one cache instance). If multiple isolates/
  /// connections ever open the same file, this becomes a TOCTOU — switch to a
  /// dedicated atomic counter table then (flagged in the design's §schema).
  Future<int> _nextLocalSeq() async {
    final q = selectOnly(messages)..addColumns([messages.localSeq.max()]);
    final row = await q.getSingleOrNull();
    final maxSeq = row?.read(messages.localSeq.max());
    return (maxSeq ?? 0) + 1;
  }

  // --- W1: optimistic insert -------------------------------------------------

  /// W1 — insert an optimistic (un-acked) row. Derives [localSeq] as MAX+1
  /// inside the transaction (restart-durable, never an in-memory counter).
  /// The caller supplies the clamped [Message.createdAt] and `deliveryState =
  /// sending`. MUST be committed before the wire send.
  Future<void> insertOptimistic(Message optimistic) async {
    await transaction(() async {
      final seq = await _nextLocalSeq();
      await into(messages).insert(_fromDomain(optimistic, localSeq: seq));
    });
  }

  // --- W2: ack reconcile -----------------------------------------------------

  /// W2 — reconcile the optimistic row for [clientTempId] with its server
  /// [serverUlid]. Happy path stamps the ULID; on collision (history fetched
  /// the row first) it collapses, merging server truth INTO the optimistic row
  /// and keeping `clientTempId`/`localSeq` for UI continuity. Guard: only a row
  /// still `serverUlid IS NULL` is reconciled (never regress a sent row).
  Future<void> reconcileAck(
      String clientTempId, String serverUlid, DateTime serverCreatedAt) async {
    await transaction(() async {
      final rc = await (select(messages)
            ..where((t) => t.clientTempId.equals(clientTempId)))
          .getSingleOrNull();
      if (rc == null) return; // orphan ack — B4 schedules a persisted repair.
      if (rc.serverUlid != null) return; // already reconciled; no regression.

      final ru = await (select(messages)
            ..where((t) => t.serverUlid.equals(serverUlid)))
          .getSingleOrNull();

      if (ru == null) {
        // Happy path: stamp the ULID + server time, mark sent.
        await (update(messages)
              ..where((t) => t.clientTempId.equals(clientTempId)))
            .write(MessagesCompanion(
          serverUlid: Value(serverUlid),
          createdAt: Value(serverCreatedAt.toUtc().millisecondsSinceEpoch),
          deliveryState: Value(DeliveryState.sent.wire),
        ));
      } else {
        // Collapse: merge ALL server-authoritative fields from R_u onto R_c,
        // keeping R_c's clientTempId + localSeq. DELETE R_u FIRST to free the
        // ULID — SQLite checks UNIQUE per-statement (immediate), so claiming
        // serverUlid=u on R_c while R_u still holds u would violate U
        // mid-transaction. Order is load-bearing; both statements are in one
        // txn (Invariant A), so no intermediate state is ever observed.
        await (delete(messages)
              ..where((t) => t.clientTempId.equals(ru.clientTempId)))
            .go();
        await (update(messages)
              ..where((t) => t.clientTempId.equals(clientTempId)))
            .write(MessagesCompanion(
          serverUlid: Value(serverUlid),
          channelId: Value(ru.channelId),
          senderUserId: Value(ru.senderUserId),
          senderKind: Value(ru.senderKind),
          senderLabel: Value(ru.senderLabel),
          kind: Value(ru.kind),
          body: Value(ru.body),
          replyToId: Value(ru.replyToId),
          // createdAt from the ACK (serverCreatedAt), NOT ru.createdAt — so the
          // collapse path and the happy path stamp the SAME value for the same
          // reconciliation. They are provably equal anyway (the gateway sends
          // ack.created_at = view["created_at"] from one row, ws.py:82), but
          // using one source removes the path-dependent asymmetry.
          createdAt: Value(serverCreatedAt.toUtc().millisecondsSinceEpoch),
          deliveryState: Value(DeliveryState.sent.wire),
        ));
      }
    });
  }

  // --- W3: inbound dedup-upsert ----------------------------------------------

  /// W3 — ingest an inbound server message (fanout echo or history). Dedups on
  /// `serverUlid`: if present, UPDATE with server fields (never blind-drop);
  /// else INSERT. Identity guard: a matched row in a *different* channel is
  /// corruption (ULIDs are globally unique) — fail loudly, never overwrite.
  Future<void> upsertInbound(Message serverMsg) async {
    final u = serverMsg.id;
    if (u == null) {
      throw ArgumentError('upsertInbound requires a server ULID (id != null)');
    }
    await transaction(() async {
      final existing = await (select(messages)
            ..where((t) => t.serverUlid.equals(u)))
          .getSingleOrNull();
      if (existing != null) {
        if (existing.channelId != serverMsg.channelId) {
          throw StateError(
              'serverUlid $u matched a row in channel ${existing.channelId} '
              '!= ${serverMsg.channelId} — corruption, refusing to overwrite');
        }
        await (update(messages)..where((t) => t.serverUlid.equals(u))).write(
          MessagesCompanion(
            senderUserId: Value(serverMsg.sender.userId),
            senderKind: Value(serverMsg.sender.kind.wire),
            senderLabel: Value(serverMsg.sender.label),
            kind: Value(serverMsg.kind.wire),
            body: Value(serverMsg.body),
            replyToId: Value(serverMsg.replyToId),
            createdAt:
                Value(serverMsg.createdAt.toUtc().millisecondsSinceEpoch),
          ),
        );
      } else {
        await into(messages).insert(_fromDomain(serverMsg, localSeq: 0));
      }
    });
  }

  // --- W4: error handler -----------------------------------------------------

  /// W4 — a gateway `ErrorFrame`. A per-message error ([refClientMsgId] != null)
  /// fails that row ONLY while `serverUlid IS NULL` (a late error must never
  /// regress a sent row). A null ref is a *systemic* error (rate-limit,
  /// channel-readonly) — returns the affected pending rows for B4 to act on,
  /// never a silent drop.
  Future<List<Message>> markFailed(String? refClientMsgId,
      {String? systemicChannelId}) async {
    if (refClientMsgId != null) {
      await (update(messages)
            ..where((t) =>
                t.clientTempId.equals(refClientMsgId) & t.serverUlid.isNull()))
          .write(MessagesCompanion(
        deliveryState: Value(DeliveryState.failed.wire),
      ));
      return const [];
    }
    // Systemic: surface the affected pending rows to B4 (it decides policy).
    final q = select(messages)..where((t) => t.serverUlid.isNull());
    if (systemicChannelId != null) {
      q.where((t) => t.channelId.equals(systemicChannelId));
    }
    final rows = await q.get();
    return rows.map(_toDomain).toList();
  }

  // --- W5: manual retry ------------------------------------------------------

  /// W5 — retry a `failed` row: flip `failed → sending`, only while
  /// `serverUlid IS NULL`. **Preserves `createdAt` and `localSeq`** so the
  /// message keeps its place in the conversation timeline — a retry must NOT
  /// teleport the message to the bottom of the view. (The earlier "bump
  /// localSeq → bottom of pending" contract was wrong: `createdAt` dominates
  /// the sort, so a bump only reorders within a same-time bucket anyway, and
  /// moving a retried message past later ones is the wrong UX. Cage-match
  /// caught the incoherent contract.)
  Future<void> retry(String clientTempId) async {
    await (update(messages)
          ..where((t) =>
              t.clientTempId.equals(clientTempId) & t.serverUlid.isNull()))
        .write(MessagesCompanion(
      deliveryState: Value(DeliveryState.sending.wire),
    ));
  }

  // --- reads -----------------------------------------------------------------

  /// Reactive ordered message list for a channel. Ordering key:
  /// `(createdAt, localSeq, COALESCE(serverUlid, clientTempId))` — see design.
  Stream<List<Message>> watchChannel(String channelId) {
    final q = select(messages)
      ..where((t) => t.channelId.equals(channelId))
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt),
        (t) => OrderingTerm(expression: t.localSeq),
        (t) => OrderingTerm(
            expression: coalesce([t.serverUlid, t.clientTempId])),
      ]);
    return q.watch().map((rows) => rows.map(_toDomain).toList());
  }

  /// Invariant O — the outbox is a QUERY, not a table: every un-acked,
  /// not-failed row, in send order.
  Future<List<Message>> outbox() async {
    final q = select(messages)
      ..where((t) => t.serverUlid.isNull() &
          t.deliveryState.equals(DeliveryState.failed.wire).not())
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt),
        (t) => OrderingTerm(expression: t.localSeq),
      ]);
    final rows = await q.get();
    return rows.map(_toDomain).toList();
  }
}
