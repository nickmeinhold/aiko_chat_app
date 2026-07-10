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

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/message.dart';
import '../../domain/message_signing.dart';
import '../../domain/origin_envelope.dart';
import '../../domain/ulid.dart';

part 'drift_cache.g.dart';

/// The observable result of a [DriftCache.reconcileAck] (design 04 Gap 1). Turns
/// the cache's previously-silent defensive branches into a contract B4 can act
/// on. Adds no writer — the census stays closed.
///
/// * [reconciled] — the optimistic row was stamped with its server ULID (happy
///   path), or was already stamped (an idempotent re-ack — no regression).
/// * [collapsed] — history had already inserted the server row; the ack merged
///   server truth onto the optimistic row and freed the duplicate (one row).
/// * [orphaned] — no optimistic row matched the ack. **Unreachable in Phase 1
///   by construction** (W1 always persists before the wire send; no local
///   delete until W6/Phase 2), so B4 treats it as an invariant assertion +
///   telemetry, never a recovery path.
enum AckOutcome { reconciled, collapsed, orphaned }

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

  /// Sovereign message signature (sovereign-message-signing, schema v3). All
  /// nullable: pre-feature rows and inbound rows have none. LOCAL verifiable
  /// history only — NOT emitted on the wire yet (gated on gateway carriage). See
  /// `docs/crucible/sovereign-message-signing/SIGNING-SPEC.md`.
  TextColumn get sig => text().nullable()(); // base64 raw-64 Ed25519
  TextColumn get senderPubkey => text().nullable()(); // base64 raw-32 key
  /// The SIGNED compose time — persisted separately from [createdAt] because ack
  /// reconciliation overwrites createdAt with server time, which would break
  /// verification of the signed bytes.
  IntColumn get signedAtMs => integer().nullable()();
  IntColumn get keyVersion => integer().nullable()();

  /// The SIGNED `client_msg_id` (wire-half, schema v4). For an OUTBOUND row the
  /// signed id IS [clientTempId], so this stays NULL and readers fall back to it.
  /// For an INBOUND row [clientTempId] is the server ULID — NOT what was signed —
  /// so the sender's signed `origin.client_msg_id` is stored here, keeping the
  /// persisted signature independently re-verifiable (same rationale as storing
  /// [signedAtMs] separately from [createdAt]).
  TextColumn get signedClientMsgId => text().nullable()();

  /// The local verify verdict for an INBOUND origin, computed once at ingest
  /// (wire-half, schema v4). NULL = no origin / our own outbound sig (self-
  /// verified at sign-time, never re-checked); 1 = carried-and-verified; 0 =
  /// carried-but-invalid. DATA, not UI (no "verified sender" badge until PR B).
  IntColumn get originCryptoValid => integer().nullable()();

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

/// Per-channel sync bookkeeping. Phase 1 holds one column: the reconnect resume
/// watermark (design 04 §Gap 2, round 4). Kept in its own table (not a column on
/// `channels`) so the watermark exists independently of channel-list sync.
class SyncMeta extends Table {
  TextColumn get channelId => text()();

  /// The newest ULID through which history is *contiguously* cached for this
  /// channel — the reconnect resume cursor. **SINGLE WRITER: the pager loop
  /// only** (`advanceHistoryContiguous`). Live W3 inserts never touch it; that
  /// separation is the round-4 fix (MAX(serverUlid) had two writers and lost
  /// messages on an interrupted sync). NULL = nothing fetched yet → page from
  /// the start.
  TextColumn get historyContiguousThrough => text().nullable()();

  @override
  Set<Column> get primaryKey => {channelId};
}

@DriftDatabase(tables: [Messages, Channels, SyncMeta])
class DriftCache extends _$DriftCache {
  DriftCache(super.e);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          // v1 -> v2: the reconnect resume watermark (design 04 round 4).
          if (from < 2) await m.createTable(syncMeta);
          // v2 -> v3: sovereign message-signing columns (all nullable — existing
          // rows keep NULLs). LOCAL verifiable history; not on the wire yet.
          if (from < 3) {
            await m.addColumn(messages, messages.sig);
            await m.addColumn(messages, messages.senderPubkey);
            await m.addColumn(messages, messages.signedAtMs);
            await m.addColumn(messages, messages.keyVersion);
          }
          // v3 -> v4: wire-half inbound carriage. The signed client_msg_id (for
          // inbound rows whose PK is the ULID, not the signed id) + the local
          // verify verdict. Both nullable — existing rows keep NULLs.
          if (from < 4) {
            await m.addColumn(messages, messages.signedClientMsgId);
            await m.addColumn(messages, messages.originCryptoValid);
          }
        },
      );

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
        origin: _originFromRow(r),
        originCryptoValid: r.originCryptoValid == null ? null : r.originCryptoValid == 1,
      );

  /// Rebuild the CARRIED [OriginEnvelope] from the typed signature columns (there
  /// is NO stored JSON — wire-half TEMPER T3). The signed `client_msg_id` is
  /// [signedClientMsgId] for inbound rows, else [clientTempId].
  ///
  /// Gated on `originCryptoValid != null` (cage-match Carnot): the SAME columns
  /// are populated by our own OUTBOUND local signature (LOCAL verifiable history,
  /// never carried on the wire), and those must NOT masquerade as a carried
  /// `origin` — `Message.origin` means "the envelope carried WITH this message".
  /// `originCryptoValid` is written ONLY on the inbound verify path, so it is the
  /// carriage discriminator. (Post-emit, our own self-echo carries origin and gets
  /// a verdict, so it too surfaces correctly.)
  OriginEnvelope? _originFromRow(MessageRow r) {
    if (r.originCryptoValid == null) return null; // local-only sig, not carried
    return _originFromColumns(r);
  }

  /// Rebuild an [OriginEnvelope] from the typed signature columns WITHOUT the
  /// carriage gate. `client_msg_id` is [signedClientMsgId] for inbound rows,
  /// else [clientTempId] (an outbound row's PK IS its wire client_msg_id).
  /// Shared by [_originFromRow] (gated, inbound) and [outboundOrigin] (ungated,
  /// our own send being emitted).
  OriginEnvelope? _originFromColumns(MessageRow r) {
    final sig = r.sig, pub = r.senderPubkey, ts = r.signedAtMs, kv = r.keyVersion;
    if (sig == null || pub == null || ts == null || kv == null) return null;
    try {
      return OriginEnvelope(
        keyVersion: kv,
        rawPublicKey: base64Decode(pub),
        clientMsgId: r.signedClientMsgId ?? r.clientTempId,
        signedAtMs: ts,
        sig: base64Decode(sig),
      );
    } on FormatException {
      // A corrupt persisted signature column (bad base64) must DEGRADE to null,
      // never throw (cage-match Carnot F2 + Tesla): on the reconnect drain a
      // throw here aborts the whole outbox flush and stalls delivery. Return null
      // → the message emits UNSIGNED (outbound) or the inbound origin is dropped
      // while the message is kept — both the intended graceful-degradation path.
      return null;
    }
  }

  /// The OUTBOUND origin for an outbox row (retry / reconnect drain), rebuilt
  /// from the persisted signature columns. Deliberately BYPASSES the
  /// [_originFromRow] inbound-carriage gate: this is our OWN local signature
  /// (originCryptoValid NULL) being emitted on the wire, not a carried inbound
  /// one — the gate exists to keep `Message.origin` inbound-only, and the emit
  /// path must not be subject to it. Null when the row is unsigned or absent.
  Future<OriginEnvelope?> outboundOrigin(String clientTempId) async {
    final r = await (select(messages)
          ..where((t) => t.clientTempId.equals(clientTempId)))
        .getSingleOrNull();
    return r == null ? null : _originFromColumns(r);
  }

  MessagesCompanion _fromDomain(Message m, {required int localSeq}) {
    final o = m.origin;
    return MessagesCompanion.insert(
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
      // Persist an inbound origin as the typed signature columns (the framework
      // serializes them — no JSON blob). Only store signedClientMsgId when it
      // DIFFERS from clientTempId (i.e. inbound, where the PK is the ULID) so an
      // outbound row keeps NULL and falls back to its own clientTempId.
      sig: o == null ? const Value.absent() : Value(base64Encode(o.sig)),
      senderPubkey:
          o == null ? const Value.absent() : Value(base64Encode(o.rawPublicKey)),
      signedAtMs: o == null ? const Value.absent() : Value(o.signedAtMs),
      keyVersion: o == null ? const Value.absent() : Value(o.keyVersion),
      signedClientMsgId: (o == null || o.clientMsgId == m.clientTempId)
          ? const Value.absent()
          : Value(o.clientMsgId),
      originCryptoValid: m.originCryptoValid == null
          ? const Value.absent()
          : Value(m.originCryptoValid! ? 1 : 0),
    );
  }

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
  Future<void> insertOptimistic(Message optimistic,
      {MessageSignature? signature}) async {
    await transaction(() async {
      final seq = await _nextLocalSeq();
      var row = _fromDomain(optimistic, localSeq: seq);
      if (signature != null) {
        // Sovereign signature persisted in the SAME txn as the optimistic row,
        // so the commit-before-wire invariant covers it too. base64 for text
        // columns; LOCAL history only (not on the wire).
        row = row.copyWith(
          sig: Value(base64Encode(signature.sig)),
          senderPubkey: Value(base64Encode(signature.rawPublicKey)),
          signedAtMs: Value(signature.signedAtMs),
          keyVersion: Value(signature.keyVersion),
        );
      }
      await into(messages).insert(row);
    });
  }

  // --- W2: ack reconcile -----------------------------------------------------

  /// W2 — reconcile the optimistic row for [clientTempId] with its server
  /// [serverUlid]. Happy path stamps the ULID; on collision (history fetched
  /// the row first) it collapses, merging server truth INTO the optimistic row
  /// and keeping `clientTempId`/`localSeq` for UI continuity. Guard: only a row
  /// still `serverUlid IS NULL` is reconciled (never regress a sent row).
  Future<AckOutcome> reconcileAck(
      String clientTempId, String serverUlid, DateTime serverCreatedAt) async {
    return transaction(() async {
      final rc = await (select(messages)
            ..where((t) => t.clientTempId.equals(clientTempId)))
          .getSingleOrNull();
      if (rc == null) return AckOutcome.orphaned; // see AckOutcome.orphaned.
      // Already reconciled (idempotent re-ack) — reconciled, never a regression.
      if (rc.serverUlid != null) return AckOutcome.reconciled;

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
        return AckOutcome.reconciled;
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
        // Collapse is a ULID-COLLISION (birth-race) path, not a mutation path: a
        // self-echo / history row (ru) landed before our ack, and the SURVIVING
        // row is our SIGNED optimistic row (rc). In the common self-echo case
        // ru's body/reply/channel equal what rc signed, so our sig is STILL VALID
        // — clearing unconditionally would erase valid local history by race order
        // (cage-match Tesla R3). Clear ONLY when a signed field truly diverges;
        // otherwise preserve rc's existing signature via Value.absent().
        final signedFieldChanged = rc.body != ru.body ||
            rc.replyToId != ru.replyToId ||
            rc.channelId != ru.channelId;
        // ru carried a verified origin off the wire (its verdict is non-null only
        // via the inbound verify path) → the survivor adopts it (see below).
        final adoptCarried = !signedFieldChanged && ru.originCryptoValid != null;
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
          // Diverged → drop the now-stale sig. Identical: if the deleted ru CARRIED
          // a verified origin (post-emit self-echo — `ru.originCryptoValid != null`),
          // ADOPT ru's carriage state onto the survivor, else the discriminator dies
          // with the deleted row and _originFromRow can't surface the origin
          // (cage-match Carnot/Tesla: the collapse must SET from ru, not only
          // preserve rc). Pre-emit ru carries nothing → preserve rc's LOCAL seal via
          // Value.absent() (Tesla R3). rc's sig == ru's origin sig for our own send,
          // so adopting is coherent, and it additionally carries ru's verdict/signed-id.
          sig: signedFieldChanged
              ? const Value(null)
              : (adoptCarried ? Value(ru.sig) : const Value.absent()),
          senderPubkey: signedFieldChanged
              ? const Value(null)
              : (adoptCarried ? Value(ru.senderPubkey) : const Value.absent()),
          signedAtMs: signedFieldChanged
              ? const Value(null)
              : (adoptCarried ? Value(ru.signedAtMs) : const Value.absent()),
          keyVersion: signedFieldChanged
              ? const Value(null)
              : (adoptCarried ? Value(ru.keyVersion) : const Value.absent()),
          signedClientMsgId: signedFieldChanged
              ? const Value(null)
              : (adoptCarried ? Value(ru.signedClientMsgId) : const Value.absent()),
          originCryptoValid: signedFieldChanged
              ? const Value(null)
              : (adoptCarried ? Value(ru.originCryptoValid) : const Value.absent()),
        ));
        return AckOutcome.collapsed;
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
        // Origin coherence (wire-half T4 — the FULL law). The origin follows the
        // INCOMING body, so the axis is "does this echo carry an origin?", NOT
        // "did the body change?" (cage-match Tesla: an edit-then-re-sign must
        // REPLACE, not clear). channelId can't differ (the guard above throws).
        //   * incoming origin present → SET it: it signs the incoming body and was
        //     verified at ingest (fills a null origin OR replaces a re-signed one),
        //     whether or not the body diverged;
        //   * no incoming origin + a signed field diverged → CLEAR: the old sig
        //     signed the old body we're overwriting (absent = unverified, no lie);
        //   * no incoming origin + unchanged → absent = preserve the still-valid sig.
        final signedFieldChanged = existing.body != serverMsg.body ||
            existing.replyToId != serverMsg.replyToId;
        final o = serverMsg.origin;
        // Precedence helpers: SET-from-origin wins; else clear-on-diverge; else keep.
        Value<String?> str(String? Function(OriginEnvelope) f) => o != null
            ? Value(f(o))
            : (signedFieldChanged ? const Value(null) : const Value.absent());
        Value<int?> intg(int? Function(OriginEnvelope) f) => o != null
            ? Value(f(o))
            : (signedFieldChanged ? const Value(null) : const Value.absent());
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
            sig: str((e) => base64Encode(e.sig)),
            senderPubkey: str((e) => base64Encode(e.rawPublicKey)),
            signedAtMs: intg((e) => e.signedAtMs),
            keyVersion: intg((e) => e.keyVersion),
            // Store the signed id only when it differs from the PK (inbound).
            signedClientMsgId:
                str((e) => e.clientMsgId != existing.clientTempId ? e.clientMsgId : null),
            // Verdict comes from the ingest-time verify (serverMsg), not the raw
            // envelope; when origin is present it is always non-null.
            originCryptoValid: o != null
                ? Value(serverMsg.originCryptoValid == true ? 1 : 0)
                : (signedFieldChanged ? const Value(null) : const Value.absent()),
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

  // --- reconnect resume watermark (design 04 §Gap 2, round 4) -----------------

  /// The reconnect resume cursor for [channelId]: the newest ULID through which
  /// history is contiguously cached. NULL until the first page is durably
  /// applied (fresh install) → the pager fetches from the start.
  Future<String?> historyContiguousThrough(String channelId) async {
    final row = await (select(syncMeta)
          ..where((t) => t.channelId.equals(channelId)))
        .getSingleOrNull();
    return row?.historyContiguousThrough;
  }

  /// Advance the resume watermark for [channelId] to [ulid]. The **ONLY** writer
  /// of this column (round-4 single-writer invariant) — call it ONLY from the
  /// history pager, ONLY after the pages up to [ulid] are durably applied. The
  /// write is **monotonic**: an [ulid] not strictly greater than the stored
  /// value is ignored, so even a stray out-of-order call can never rewind the
  /// contiguity boundary (single-writer AND monotonic — the coordination-variable
  /// discipline this whole component is built on).
  Future<void> advanceHistoryContiguous(String channelId, String ulid) async {
    // The monotonic compare below assumes canonical (UPPERCASE) ULID case; a
    // non-canonical [ulid] would sort wrongly and could rewind/skip the
    // watermark. Assert at the boundary (debug-only; PR#7 finding 4). Empty
    // fence ('' = below every ULID) is the valid empty-channel sentinel.
    if (ulid.isNotEmpty) assertCanonicalUlid(ulid, context: 'watermark');
    await transaction(() async {
      final current = await (select(syncMeta)
            ..where((t) => t.channelId.equals(channelId)))
          .getSingleOrNull();
      if (current?.historyContiguousThrough != null &&
          ulid.compareTo(current!.historyContiguousThrough!) <= 0) {
        return; // not strictly forward — never rewind.
      }
      await into(syncMeta).insertOnConflictUpdate(
        SyncMetaCompanion.insert(
            channelId: channelId, historyContiguousThrough: Value(ulid)),
      );
    });
  }
}
