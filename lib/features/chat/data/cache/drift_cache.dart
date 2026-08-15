/// Component 3 — the cache (design: docs/design/03-drift-cache.html).
///
/// The on-device SQLite store the repository / B4 reconcile engine writes
/// through. This file owns *storage, atomic operations, and invariant
/// enforcement*; B4 owns *policy* (ordering, when to drain). The load-bearing
/// invariant is **U**: every NON-NULL `serverUlid` is UNIQUE, so duplication —
/// the app's worst failure — is structurally impossible at rest.
///
/// Writer census (every path that mutates a `messages` row):
///   W1 insertOptimistic · W2 reconcileAck · W3 upsertInbound ·
///   W4 markFailed · W5 retry · W6 applyRetraction (moderator takedown, #104 —
///   hard-deletes the taken-down row + records a presence-independent dead id;
///   W2 and W3 both suppress a dead id, the two-door invariant).
///
/// Storage engine: drift's RUNTIME only — no `drift_dev`/`build_runner` codegen.
/// The typed tables a generator would emit are hand-written here as [MessageRow]/
/// [ChannelRow] + raw SQL keyed on the column-name constants (`_M`/`_C`/`_S`/`_R`).
/// Reactivity is drift's string-keyed change tracking (`notifyUpdates`/
/// `tableUpdates`); atomicity is drift's `transaction()` (raw statements inside it
/// resolve the transaction executor via a zone, so they commit together). The DDL
/// reuses the previous generated column names + types (snake_case), so the schema
/// is upgrade-compatible and existing installs migrate in place — verified by the
/// migration test (real downgrade→reopen) and the schema-consistency test (live
/// `PRAGMA` == the declared schema, the guarantee the generator gave for free).
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/channel.dart';
import '../../domain/message.dart';
import '../../domain/message_signing.dart';
import '../../domain/origin_envelope.dart';
import '../../domain/retraction.dart';
import '../../domain/ulid.dart';

/// The observable result of a [DriftCache.reconcileAck] (design 04 Gap 1). Turns
/// the cache's previously-silent defensive branches into a contract B4 can act
/// on: happy-path stamp, birth-race collapse, an impossible orphan, or a
/// takedown that raced the ack.
///
/// * [reconciled] — the optimistic row was stamped with its server ULID (happy
///   path) OR was already stamped (idempotent re-ack).
/// * [collapsed] — a server copy of this message (self-echo / history) had
///   already landed under its ULID; the two rows collapsed into one.
/// * [orphaned] — NO optimistic row matched `clientTempId` and the id is not a
///   known dead id. Ordinarily unreachable (an ack implies we sent it and the
///   row is committed-before-wire), so B4 treats it as an invariant assertion +
///   telemetry, never a recovery path.
/// * [retracted] — the ack is for an own-message that was TAKEN DOWN before its
///   ack landed (island #104). The retraction recorded a presence-independent
///   dead id; reconcileAck refuses to stamp/resurrect the optimistic row and
///   hard-deletes it instead (or finds it already gone). Benign — the second door
///   a dead id enters (the first is [upsertInbound]). B4 completes the ack waiter
///   and renders nothing; there is nothing to recover.
enum AckOutcome { reconciled, collapsed, orphaned, retracted }

// --- column-name single source of truth ------------------------------------
// The SQL names (snake_case) shared by the DDL, the row readers, and every
// query — matching the previous generated schema 1:1. A rename touches one
// place; the schema-consistency test asserts these match the live DB.

/// `messages` table columns. PK `client_temp_id`; `server_ulid` UNIQUE but
/// nullable (many un-acked NULLs coexist — Invariant U).
abstract final class _M {
  static const table = 'messages';
  static const clientTempId = 'client_temp_id';
  static const serverUlid = 'server_ulid';
  static const channelId = 'channel_id';
  static const senderUserId = 'sender_user_id';
  static const senderKind = 'sender_kind';
  static const senderLabel = 'sender_label';
  static const kind = 'kind';
  static const body = 'body';
  static const replyToId = 'reply_to_id';
  static const createdAt = 'created_at';
  static const localSeq = 'local_seq';
  static const deliveryState = 'delivery_state';
  static const sig = 'sig';
  static const senderPubkey = 'sender_pubkey';
  static const signedAtMs = 'signed_at_ms';
  static const keyVersion = 'key_version';
  static const signedClientMsgId = 'signed_client_msg_id';
  static const originCryptoValid = 'origin_crypto_valid';

  static const schema = <String, String>{
    clientTempId: 'TEXT NOT NULL',
    serverUlid: 'TEXT UNIQUE',
    channelId: 'TEXT NOT NULL',
    senderUserId: 'TEXT',
    senderKind: 'TEXT NOT NULL',
    senderLabel: 'TEXT',
    kind: 'TEXT NOT NULL',
    body: 'TEXT NOT NULL',
    replyToId: 'TEXT',
    createdAt: 'INTEGER NOT NULL',
    localSeq: 'INTEGER NOT NULL DEFAULT 0',
    deliveryState: 'TEXT NOT NULL',
    sig: 'TEXT',
    senderPubkey: 'TEXT',
    signedAtMs: 'INTEGER',
    keyVersion: 'INTEGER',
    signedClientMsgId: 'TEXT',
    originCryptoValid: 'INTEGER',
  };
}

/// `channels` table columns. PK `id`.
abstract final class _C {
  static const table = 'channels';
  static const id = 'id';
  static const name = 'name';
  static const kind = 'kind';
  static const aikoChannel = 'aiko_channel';
  static const ordinal = 'ordinal';

  static const schema = <String, String>{
    id: 'TEXT NOT NULL',
    name: 'TEXT NOT NULL',
    kind: 'TEXT NOT NULL',
    aikoChannel: 'TEXT',
    ordinal: 'INTEGER NOT NULL DEFAULT 0',
  };
}

/// `sync_meta` table columns. PK `channel_id`.
abstract final class _S {
  static const table = 'sync_meta';
  static const channelId = 'channel_id';
  static const historyContiguousThrough = 'history_contiguous_through';

  static const schema = <String, String>{
    channelId: 'TEXT NOT NULL',
    historyContiguousThrough: 'TEXT',
  };
}

/// `retracted_ids` table columns. PK `target_msg_id`.
abstract final class _R {
  static const table = 'retracted_ids';
  static const targetMsgId = 'target_msg_id';
  static const channelId = 'channel_id';
  static const retractionId = 'retraction_id';

  static const schema = <String, String>{
    targetMsgId: 'TEXT NOT NULL',
    channelId: 'TEXT NOT NULL',
    retractionId: 'TEXT NOT NULL',
  };
}

/// `ifNotExists` mirrors drift's `Migrator.createTable` (which is a no-op when
/// the table is already present) — used on the onUpgrade paths, where an
/// artificially-downgraded DB may still carry a table the ladder re-creates.
String _createTable(String table, Map<String, String> schema, String pk,
        {bool ifNotExists = false}) =>
    'CREATE TABLE ${ifNotExists ? 'IF NOT EXISTS ' : ''}$table ('
    '${schema.entries.map((e) => '${e.key} ${e.value}').join(', ')}, '
    'PRIMARY KEY ($pk))';

// --- typed rows (the hand-written equivalent of the generated data classes) --

/// A `messages` row. The `MessageRow -> Message` mapping ([DriftCache._toDomain])
/// is unchanged; only the row's construction (from a raw [QueryRow]) is hand-written.
class MessageRow {
  const MessageRow({
    required this.clientTempId,
    this.serverUlid,
    required this.channelId,
    this.senderUserId,
    required this.senderKind,
    this.senderLabel,
    required this.kind,
    required this.body,
    this.replyToId,
    required this.createdAt,
    this.localSeq = 0,
    required this.deliveryState,
    this.sig,
    this.senderPubkey,
    this.signedAtMs,
    this.keyVersion,
    this.signedClientMsgId,
    this.originCryptoValid,
  });

  final String clientTempId;
  final String? serverUlid;
  final String channelId;
  final String? senderUserId;
  final String senderKind;
  final String? senderLabel;
  final String kind;
  final String body;
  final String? replyToId;
  final int createdAt;
  final int localSeq;
  final String deliveryState;
  final String? sig;
  final String? senderPubkey;
  final int? signedAtMs;
  final int? keyVersion;
  final String? signedClientMsgId;
  final int? originCryptoValid;

  factory MessageRow.fromRow(QueryRow r) => MessageRow(
        clientTempId: r.read<String>(_M.clientTempId),
        serverUlid: r.readNullable<String>(_M.serverUlid),
        channelId: r.read<String>(_M.channelId),
        senderUserId: r.readNullable<String>(_M.senderUserId),
        senderKind: r.read<String>(_M.senderKind),
        senderLabel: r.readNullable<String>(_M.senderLabel),
        kind: r.read<String>(_M.kind),
        body: r.read<String>(_M.body),
        replyToId: r.readNullable<String>(_M.replyToId),
        createdAt: r.read<int>(_M.createdAt),
        localSeq: r.read<int>(_M.localSeq),
        deliveryState: r.read<String>(_M.deliveryState),
        sig: r.readNullable<String>(_M.sig),
        senderPubkey: r.readNullable<String>(_M.senderPubkey),
        signedAtMs: r.readNullable<int>(_M.signedAtMs),
        keyVersion: r.readNullable<int>(_M.keyVersion),
        signedClientMsgId: r.readNullable<String>(_M.signedClientMsgId),
        originCryptoValid: r.readNullable<int>(_M.originCryptoValid),
      );
}

/// Component 3 — the on-device cache. Hand-authored typed layer over drift's
/// runtime; see the library doc for the no-codegen rationale.
class DriftCache extends GeneratedDatabase {
  DriftCache(super.executor);

  @override
  int get schemaVersion => 6;

  /// The declared schema (table → its column-fragment map + PK column), exposed
  /// so the schema-consistency test can assert the LIVE DB matches it exactly —
  /// type, nullability, default, and PK, not just column names. This is the
  /// generator's schema-sync guarantee made explicit. Not a runtime API.
  static const tableSchemas =
      <String, ({Map<String, String> columns, String pk})>{
    _M.table: (columns: _M.schema, pk: _M.clientTempId),
    _C.table: (columns: _C.schema, pk: _C.id),
    _S.table: (columns: _S.schema, pk: _S.channelId),
    _R.table: (columns: _R.schema, pk: _R.targetMsgId),
  };

  /// No generated tables. Reads/writes go through raw SQL keyed on the `_M`/`_C`/
  /// `_S`/`_R` name constants; change tracking is by table-name string.
  @override
  Iterable<TableInfo> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await customStatement(_createTable(_M.table, _M.schema, _M.clientTempId));
          await customStatement(_createTable(_C.table, _C.schema, _C.id));
          await customStatement(_createTable(_S.table, _S.schema, _S.channelId));
          await customStatement(_createTable(_R.table, _R.schema, _R.targetMsgId));
        },
        onUpgrade: (m, from, to) async {
          // v1 -> v2: the reconnect resume watermark (design 04 round 4).
          if (from < 2) {
            await customStatement(
                _createTable(_S.table, _S.schema, _S.channelId, ifNotExists: true));
          }
          // v2 -> v3: sovereign message-signing columns (all nullable — existing
          // rows keep NULLs). LOCAL verifiable history; not on the wire yet.
          if (from < 3) {
            await customStatement('ALTER TABLE ${_M.table} ADD COLUMN ${_M.sig} TEXT');
            await customStatement(
                'ALTER TABLE ${_M.table} ADD COLUMN ${_M.senderPubkey} TEXT');
            await customStatement(
                'ALTER TABLE ${_M.table} ADD COLUMN ${_M.signedAtMs} INTEGER');
            await customStatement(
                'ALTER TABLE ${_M.table} ADD COLUMN ${_M.keyVersion} INTEGER');
          }
          // v3 -> v4: wire-half inbound carriage — the signed client_msg_id + the
          // local verify verdict. Both nullable — existing rows keep NULLs.
          if (from < 4) {
            await customStatement(
                'ALTER TABLE ${_M.table} ADD COLUMN ${_M.signedClientMsgId} TEXT');
            await customStatement(
                'ALTER TABLE ${_M.table} ADD COLUMN ${_M.originCryptoValid} INTEGER');
          }
          // v4 -> v5: channel-list ordinal so the offline read preserves the
          // authoritative server order (default 0 — self-heals on the next
          // saveChannels, which rewrites every row's ordinal).
          if (from < 5) {
            await customStatement(
                'ALTER TABLE ${_C.table} ADD COLUMN ${_C.ordinal} INTEGER NOT NULL DEFAULT 0');
          }
          // v5 -> v6: the retraction dead-id table (moderator takedowns, #104).
          // A new empty table — existing rows are untouched; a takedown that
          // predates the upgrade re-arrives on the next history catch-up and is
          // recorded then (presence-independent), so no backfill is needed.
          if (from < 6) {
            await customStatement(
                _createTable(_R.table, _R.schema, _R.targetMsgId, ifNotExists: true));
          }
        },
      );

  // --- raw-SQL helpers -------------------------------------------------------

  /// A partial UPDATE that reproduces drift companion semantics: a column
  /// PRESENT in [set] is written (a null value ⇒ `SET col = NULL`); a column
  /// ABSENT from [set] is left untouched (the old `Value.absent()`). Callers
  /// build [set] conditionally, exactly as they built companions.
  ///
  /// Returns the number of rows changed (via `customUpdate`), so a writer whose
  /// WHERE may match nothing — an already-sent row under `serverUlid IS NULL` —
  /// can gate its `notifyUpdates` on a real mutation, the "no spurious emit on a
  /// zero-row no-op" half of the manual-notify contract PR #130 made explicit.
  Future<int> _update(String table, Map<String, Object?> set, String where,
      List<Object?> whereArgs) async {
    if (set.isEmpty) return 0;
    final assignments = set.keys.map((c) => '$c = ?').join(', ');
    return customUpdate(
      'UPDATE $table SET $assignments WHERE $where',
      variables: [...set.values, ...whereArgs].map((v) => Variable(v)).toList(),
      updateKind: UpdateKind.update,
    );
  }

  Future<void> _insert(String table, Map<String, Object?> cols) async {
    final names = cols.keys.join(', ');
    final placeholders = List.filled(cols.length, '?').join(', ');
    await customStatement(
      'INSERT INTO $table ($names) VALUES ($placeholders)',
      cols.values.toList(),
    );
  }

  Future<MessageRow?> _messageBy(String column, String value) async {
    final rows = await customSelect(
      'SELECT * FROM ${_M.table} WHERE $column = ?',
      variables: [Variable(value)],
    ).get();
    return rows.isEmpty ? null : MessageRow.fromRow(rows.first);
  }

  /// A reactive stream that emits the current [fetch] result on listen, then
  /// re-emits whenever [table] changes. drift's own `.watch()` primitive
  /// (`createStream`/`QueryStreamFetcher`) is not on the public API, so this
  /// rebuilds its contract from the public `tableUpdates`.
  ///
  /// `Stream.multi` matches drift's watch cardinality: it is multi-subscription
  /// (multiple widgets may watch the same query concurrently), each listener
  /// running this callback fresh — its OWN initial fetch, update subscription,
  /// and cancel. `isBroadcast: true` reports that to downstream transformers, as
  /// drift's `.watch()` did. (Unlike a shared broadcast stream, each listener
  /// re-queries independently — correct here, since every listener wants current
  /// rows.) Within a listener, updates are subscribed BEFORE the initial fetch
  /// (no missed write) and fetches are chained so emissions stay in arrival order.
  Stream<T> _watch<T>(String table, Future<T> Function() fetch) {
    return Stream.multi((controller) {
      var chain = Future<void>.value();
      void schedule() {
        // .catchError keeps the chain from settling into a rejected state — a
        // rejected future would make every later .then a no-op and silently
        // deafen the listener while the DB keeps mutating.
        chain = chain.then((_) async {
          if (controller.isClosed) return;
          try {
            controller.add(await fetch());
          } catch (e, st) {
            if (!controller.isClosed) controller.addError(e, st);
          }
        }).catchError((_) {});
      }

      final sub =
          tableUpdates(TableUpdateQuery.onTableName(table)).listen((_) => schedule());
      controller.onCancel = sub.cancel;
      schedule(); // initial emission
    }, isBroadcast: true);
  }

  // --- channel-list cache (offline-first) -----------------------------------

  /// Replace the cached channel list with [channels]. The server's list is
  /// AUTHORITATIVE, so this is a full replace in one transaction (a channel the
  /// user can no longer see must disappear from the cache too — a stale local
  /// row for a gone channel is drift wearing a tombstone). Called after a
  /// successful `listChannels()`; the offline read below serves it back.
  Future<void> saveChannels(List<Channel> channels) async {
    await transaction(() async {
      await customStatement('DELETE FROM ${_C.table}');
      for (final (i, c) in channels.indexed) {
        await _insert(_C.table, {
          _C.id: c.id,
          _C.name: c.name,
          _C.kind: c.kind.wire,
          _C.aikoChannel: c.aikoChannel,
          _C.ordinal: i, // preserve authoritative list order
        });
      }
    });
    notifyUpdates({const TableUpdate(_C.table)});
  }

  /// The cached channel list — the offline fallback when `listChannels()` can't
  /// reach the gateway. Empty when nothing has been cached yet (first-ever launch
  /// offline): the UI shows an empty list, never the raw-error screen.
  Future<List<Channel>> readChannels() async {
    // Deterministic tiebreak on id: pre-v5 rows all migrate to ordinal 0, so
    // without a secondary key an immediately-offline migrated user could get
    // nondeterministic default-channel selection (Carnot, PR #72). Self-heals on
    // the first online saveChannels (real indexes).
    final rows = await customSelect(
      'SELECT * FROM ${_C.table} ORDER BY ${_C.ordinal} ASC, ${_C.id} ASC',
    ).get();
    return rows
        .map((r) => Channel(
              id: r.read<String>(_C.id),
              name: r.read<String>(_C.name),
              kind: ChannelKind.fromWire(r.read<String>(_C.kind)),
              aikoChannel: r.readNullable<String>(_C.aikoChannel),
            ))
        .toList();
  }

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
        originCryptoValid:
            r.originCryptoValid == null ? null : r.originCryptoValid == 1,
      );

  /// Rebuild the CARRIED [OriginEnvelope] from the typed signature columns (there
  /// is NO stored JSON — wire-half TEMPER T3). The signed `client_msg_id` is
  /// [MessageRow.signedClientMsgId] for inbound rows, else [MessageRow.clientTempId].
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
  /// carriage gate. `client_msg_id` is [MessageRow.signedClientMsgId] for inbound
  /// rows, else [MessageRow.clientTempId] (an outbound row's PK IS its wire
  /// client_msg_id). Shared by [_originFromRow] (gated, inbound) and
  /// [outboundOrigin] (ungated, our own send being emitted).
  OriginEnvelope? _originFromColumns(MessageRow r) {
    final sig = r.sig, pub = r.senderPubkey, ts = r.signedAtMs, kv = r.keyVersion;
    if (sig == null || pub == null || ts == null || kv == null) return null;
    try {
      final rawPub = base64Decode(pub);
      final rawSig = base64Decode(sig);
      // Reject valid-base64 but WRONG-LENGTH material (cage-match Carnot R2): a
      // 32-byte ed25519 key and 64-byte sig are the only legal shapes. Wrong
      // lengths → null, so the outbound emit never relies on toWire() throwing
      // downstream and the inbound path never surfaces an OriginEnvelope carrying
      // illegal-length crypto.
      if (rawPub.length != 32 || rawSig.length != 64) return null;
      return OriginEnvelope(
        keyVersion: kv,
        rawPublicKey: rawPub,
        clientMsgId: r.signedClientMsgId ?? r.clientTempId,
        signedAtMs: ts,
        sig: rawSig,
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
    final r = await _messageBy(_M.clientTempId, clientTempId);
    return r == null ? null : _originFromColumns(r);
  }

  /// The full column map for [m] (the old `_fromDomain` companion). Signature
  /// columns are null when there is no inbound origin; [signedClientMsgId] is
  /// null (falls back to clientTempId) unless it genuinely differs — i.e. inbound,
  /// where the PK is the ULID.
  Map<String, Object?> _cols(Message m, {required int localSeq}) {
    final o = m.origin;
    return {
      _M.clientTempId: m.clientTempId,
      _M.serverUlid: m.id,
      _M.channelId: m.channelId,
      _M.senderUserId: m.sender.userId,
      _M.senderKind: m.sender.kind.wire,
      _M.senderLabel: m.sender.label,
      _M.kind: m.kind.wire,
      _M.body: m.body,
      _M.replyToId: m.replyToId,
      _M.createdAt: m.createdAt.toUtc().millisecondsSinceEpoch,
      _M.localSeq: localSeq,
      _M.deliveryState: m.deliveryState.wire,
      _M.sig: o == null ? null : base64Encode(o.sig),
      _M.senderPubkey: o == null ? null : base64Encode(o.rawPublicKey),
      _M.signedAtMs: o?.signedAtMs,
      _M.keyVersion: o?.keyVersion,
      _M.signedClientMsgId:
          (o == null || o.clientMsgId == m.clientTempId) ? null : o.clientMsgId,
      _M.originCryptoValid:
          m.originCryptoValid == null ? null : (m.originCryptoValid! ? 1 : 0),
    };
  }

  /// `MAX(localSeq)+1`. Race-free ONLY because SQLite is single-writer and the
  /// enclosing transaction's SELECT-then-INSERT can't interleave with another.
  /// Holds for Phase 1 (one isolate, one cache instance). If multiple isolates/
  /// connections ever open the same file this becomes a TOCTOU — switch to a
  /// dedicated atomic counter table then (flagged in the design's §schema).
  Future<int> _nextLocalSeq() async {
    final rows = await customSelect('SELECT MAX(${_M.localSeq}) AS m FROM ${_M.table}').get();
    return (rows.first.readNullable<int>('m') ?? 0) + 1;
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
      final cols = _cols(optimistic, localSeq: seq);
      if (signature != null) {
        // Sovereign signature persisted in the SAME txn as the optimistic row,
        // so the commit-before-wire invariant covers it too. base64 for text
        // columns; LOCAL history only (not on the wire).
        cols[_M.sig] = base64Encode(signature.sig);
        cols[_M.senderPubkey] = base64Encode(signature.rawPublicKey);
        cols[_M.signedAtMs] = signature.signedAtMs;
        cols[_M.keyVersion] = signature.keyVersion;
      }
      await _insert(_M.table, cols);
    });
    notifyUpdates({const TableUpdate(_M.table)});
  }

  // --- W2: ack reconcile -----------------------------------------------------

  /// W2 — reconcile the optimistic row for [clientTempId] with its server
  /// [serverUlid]. Happy path stamps the ULID; on collision (history fetched
  /// the row first) it collapses, merging server truth INTO the optimistic row
  /// and keeping `clientTempId`/`localSeq` for UI continuity. Guard: only a row
  /// still `serverUlid IS NULL` is reconciled (never regress a sent row).
  Future<AckOutcome> reconcileAck(
      String clientTempId, String serverUlid, DateTime serverCreatedAt) async {
    var wrote = false;
    final outcome = await transaction(() async {
      final rc = await _messageBy(_M.clientTempId, clientTempId);
      if (rc == null) {
        // Door B of two-door retraction suppression (island #104). No optimistic
        // row matched. Ordinarily unreachable (see AckOutcome.orphaned), but a
        // retraction of an own-message that had ALREADY been acked+stamped
        // hard-deletes the row (keyed by serverUlid), so a late/duplicate ack now
        // finds nothing. That is EXPECTED, not an invariant violation — classify
        // it as [retracted] so B4 doesn't fire the orphan tripwire.
        if (await _isRetracted(serverUlid)) return AckOutcome.retracted;
        return AckOutcome.orphaned; // see AckOutcome.orphaned.
      }
      // Already reconciled (idempotent re-ack) — reconciled, never a regression.
      // (A retracted row would have been hard-deleted, landing in the rc == null
      // branch above; the inbound FIFO serializes ack vs retraction, so a stamped
      // row is never concurrently a live dead id here.)
      if (rc.serverUlid != null) return AckOutcome.reconciled;

      // The optimistic row is still pending (serverUlid NULL). If its server id
      // was taken down while the ack was in flight, DO NOT stamp it — that would
      // resurrect a taken-down message. Hard-delete the optimistic row instead
      // (applyRetraction's delete-by-serverUlid never reached it — serverUlid was
      // NULL), same transaction as the dead-id read (no TOCTOU).
      if (await _isRetracted(serverUlid)) {
        await customStatement(
            'DELETE FROM ${_M.table} WHERE ${_M.clientTempId} = ?', [clientTempId]);
        wrote = true;
        return AckOutcome.retracted;
      }

      final ru = await _messageBy(_M.serverUlid, serverUlid);

      if (ru == null) {
        // Happy path: stamp the ULID + server time, mark sent.
        await _update(_M.table, {
          _M.serverUlid: serverUlid,
          _M.createdAt: serverCreatedAt.toUtc().millisecondsSinceEpoch,
          _M.deliveryState: DeliveryState.sent.wire,
        }, '${_M.clientTempId} = ?', [clientTempId]);
        wrote = true;
        return AckOutcome.reconciled;
      } else {
        // Collapse: merge ALL server-authoritative fields from R_u onto R_c,
        // keeping R_c's clientTempId + localSeq. DELETE R_u FIRST to free the
        // ULID — SQLite checks UNIQUE per-statement (immediate), so claiming
        // serverUlid=u on R_c while R_u still holds u would violate U
        // mid-transaction. Order is load-bearing; both statements are in one
        // txn (Invariant A), so no intermediate state is ever observed.
        await customStatement(
            'DELETE FROM ${_M.table} WHERE ${_M.clientTempId} = ?', [ru.clientTempId]);
        // Collapse is a ULID-COLLISION (birth-race) path, not a mutation path: a
        // self-echo / history row (ru) landed before our ack, and the SURVIVING
        // row is our SIGNED optimistic row (rc). In the common self-echo case
        // ru's body/reply/channel equal what rc signed, so our sig is STILL VALID
        // — clearing unconditionally would erase valid local history by race order
        // (cage-match Tesla R3). Clear ONLY when a signed field truly diverges;
        // otherwise preserve rc's existing signature (absent from the set).
        final signedFieldChanged = rc.body != ru.body ||
            rc.replyToId != ru.replyToId ||
            rc.channelId != ru.channelId;
        // ru carried a verified origin off the wire (its verdict is non-null only
        // via the inbound verify path) → the survivor adopts it (see below).
        final adoptCarried = !signedFieldChanged && ru.originCryptoValid != null;

        final set = <String, Object?>{
          _M.serverUlid: serverUlid,
          _M.channelId: ru.channelId,
          _M.senderUserId: ru.senderUserId,
          _M.senderKind: ru.senderKind,
          _M.senderLabel: ru.senderLabel,
          _M.kind: ru.kind,
          _M.body: ru.body,
          _M.replyToId: ru.replyToId,
          // createdAt from the ACK (serverCreatedAt), NOT ru.createdAt — so the
          // collapse path and the happy path stamp the SAME value for the same
          // reconciliation. They are provably equal anyway (the gateway sends
          // ack.created_at = view["created_at"] from one row, ws.py:82), but
          // using one source removes the path-dependent asymmetry.
          _M.createdAt: serverCreatedAt.toUtc().millisecondsSinceEpoch,
          _M.deliveryState: DeliveryState.sent.wire,
        };
        // Signature columns (cage-match Carnot/Tesla): diverged → drop the stale
        // sig (SET NULL); identical + ru CARRIED a verified origin (post-emit
        // self-echo) → ADOPT ru's carriage state so the discriminator survives the
        // deleted row; identical + ru carries nothing (pre-emit) → preserve rc's
        // LOCAL seal (absent). rc's sig == ru's origin sig for our own send, so
        // adopting is coherent AND additionally carries ru's verdict/signed-id.
        void sigCol(String col, Object? ruVal) {
          if (signedFieldChanged) {
            set[col] = null; // Value(null)
          } else if (adoptCarried) {
            set[col] = ruVal; // Value(ru.x)
          } // else: absent → preserve rc
        }

        sigCol(_M.sig, ru.sig);
        sigCol(_M.senderPubkey, ru.senderPubkey);
        sigCol(_M.signedAtMs, ru.signedAtMs);
        sigCol(_M.keyVersion, ru.keyVersion);
        sigCol(_M.signedClientMsgId, ru.signedClientMsgId);
        sigCol(_M.originCryptoValid, ru.originCryptoValid);

        await _update(_M.table, set, '${_M.clientTempId} = ?', [clientTempId]);
        wrote = true;
        return AckOutcome.collapsed;
      }
    });
    // Only signal watchers when a row actually changed — an orphaned or
    // already-reconciled ack writes nothing, and drift's typed streams likewise
    // only fired on real mutations (cage-match Tesla: spurious re-emissions).
    if (wrote) notifyUpdates({const TableUpdate(_M.table)});
    return outcome;
  }

  // --- W3: inbound dedup-upsert ----------------------------------------------

  /// W3 — ingest an inbound server message (fanout echo or history). Dedups on
  /// `serverUlid`: if present, UPDATE with server fields (never blind-drop);
  /// else INSERT. Identity guard: a matched row in a *different* channel is
  /// corruption (ULIDs are globally unique) — fail loudly, never overwrite.
  /// Returns `true` iff this write NEWLY recorded a carried-but-invalid origin —
  /// the row's stored verdict transitioned to false (a first insert of an invalid
  /// origin, or a re-signed divergence), and was not already false. A re-delivery
  /// of an already-invalid row (live+history dual delivery, reconnect replay,
  /// history re-walk) returns `false`, so a per-message base-rate probe can fire
  /// once per message instead of once per delivery (PR #93 R1, cage-match
  /// Carnot + Tesla).
  Future<({bool inserted, bool newlyInvalid})> upsertInbound(
      Message serverMsg) async {
    final u = serverMsg.id;
    if (u == null) {
      throw ArgumentError('upsertInbound requires a server ULID (id != null)');
    }
    // Invariant (production-true via the single door `_persistInbound`, which
    // computes the verdict before persisting): a CARRIED origin arrives WITH its
    // ingest-time verdict. Reject the illegal origin-present/verdict-null input at
    // the mutator rather than trying to coerce/preserve/clear it — that ill-defined
    // state (new origin fields but no verdict for them) has no coherent storage,
    // and every attempt to paper over it leaked a different bug (cage-match R2–R4).
    // Making it unrepresentable dissolves the class (consistent with the id guard).
    if (serverMsg.origin != null && serverMsg.originCryptoValid == null) {
      throw ArgumentError('upsertInbound: a carried origin must arrive with its '
          'ingest-time verdict (verify runs before persist in _persistInbound); '
          'origin-present with a null verdict is illegal');
    }
    var wrote = false;
    var inserted = false;
    final newlyInvalid = await transaction(() async {
      // Door A of two-door retraction suppression (island #104). A dead id is
      // presence-independent, so a taken-down message that arrives AFTER its
      // retraction (reconnect re-walk, buffered fanout frame, live+history dual
      // delivery) must never be (re)inserted. Checked FIRST inside the txn — same
      // transaction as the insert/update below, so no TOCTOU. Returns false: no
      // row was written, so no per-message origin probe should fire either.
      if (await _isRetracted(u)) return false;
      final existing = await _messageBy(_M.serverUlid, u);
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

        final set = <String, Object?>{
          _M.senderUserId: serverMsg.sender.userId,
          _M.senderKind: serverMsg.sender.kind.wire,
          _M.senderLabel: serverMsg.sender.label,
          _M.kind: serverMsg.kind.wire,
          _M.body: serverMsg.body,
          _M.replyToId: serverMsg.replyToId,
          _M.createdAt: serverMsg.createdAt.toUtc().millisecondsSinceEpoch,
        };
        // Precedence: SET-from-origin wins; else clear-on-diverge; else keep (absent).
        void originCol(String col, Object? Function(OriginEnvelope) f) {
          if (o != null) {
            set[col] = f(o);
          } else if (signedFieldChanged) {
            set[col] = null;
          } // else: absent → preserve
        }

        originCol(_M.sig, (e) => base64Encode(e.sig));
        originCol(_M.senderPubkey, (e) => base64Encode(e.rawPublicKey));
        originCol(_M.signedAtMs, (e) => e.signedAtMs);
        originCol(_M.keyVersion, (e) => e.keyVersion);
        // Store the signed id only when it differs from the PK (inbound).
        originCol(_M.signedClientMsgId,
            (e) => e.clientMsgId != existing.clientTempId ? e.clientMsgId : null);
        // Origin present ⟹ verdict non-null (guarded at method entry). Store the
        // ingest-time verdict; an incoming origin REPLACES, and the verdict is
        // cleared only when no origin arrives and a signed field changed.
        if (o != null) {
          set[_M.originCryptoValid] = serverMsg.originCryptoValid! ? 1 : 0;
        } else if (signedFieldChanged) {
          set[_M.originCryptoValid] = null;
        }

        await _update(_M.table, set, '${_M.serverUlid} = ?', [u]);
        wrote = true;
        // Newly-invalid: the row's stored verdict transitions INTO false (origin
        // present + verdict false) AND was not already false. A re-echo of an
        // already-false row (existing == 0), including a false→false re-sign, is
        // suppressed — the unit is the server ULID (one count per message), by
        // design for a base-rate meter.
        return o != null &&
            serverMsg.originCryptoValid == false &&
            existing.originCryptoValid != 0;
      } else {
        await _insert(_M.table, _cols(serverMsg, localSeq: 0));
        wrote = true;
        inserted = true;
        // First insert: newly-invalid iff a carried origin verified false (origin
        // present ⟹ verdict non-null, guarded at method entry).
        return serverMsg.origin != null && serverMsg.originCryptoValid == false;
      }
    });
    // A dead-id suppression (early return) writes nothing — don't signal watchers
    // for a no-op (cage-match Tesla), matching drift's write-only stream signals.
    if (wrote) notifyUpdates({const TableUpdate(_M.table)});
    // TWO distinct facts, no longer sharing one bool (cage-match #139 R5,
    // Carnot). `inserted` is true ONLY for a first-time insert of this server
    // ULID — false for a dead-id suppression (nothing written) AND for an
    // update/re-echo of a row we already had. That is exactly the predicate an
    // ingest ANNOUNCEMENT needs, and it is computed INSIDE the transaction, so
    // there is no post-write read and no window for a retraction to land
    // between the write and the decision.
    return (inserted: inserted, newlyInvalid: newlyInvalid);
  }

  // --- W6: retraction (moderator takedown, island #104) ----------------------

  /// Is [ulid] a recorded dead id? MUST be called from inside an enclosing
  /// [transaction] (both doors do) so the read and the caller's write commit
  /// atomically — no TOCTOU between "is it retracted?" and the insert/stamp.
  /// String-identity match on the CANONICAL id — canonical-ULID is a debug-asserted
  /// cross-repo contract throughout this component (the watermark, the history
  /// cursor, and serverUlid dedup all assume it), so both sides are the same case
  /// by contract. See [applyRetraction] for why this path does NOT do a bespoke
  /// release-time case-normalization.
  Future<bool> _isRetracted(String ulid) async {
    final rows = await customSelect(
      'SELECT 1 FROM ${_R.table} WHERE ${_R.targetMsgId} = ?',
      variables: [Variable(ulid)],
    ).get();
    return rows.isNotEmpty;
  }

  /// W6 — apply a moderator takedown [r]. One transaction, two effects:
  ///   1. RECORD the dead id (presence-independent, idempotent via PK) so both
  ///      write doors ([upsertInbound], [reconcileAck]) suppress it thereafter,
  ///      whether or not the target row currently exists;
  ///   2. HARD-DELETE the present target row (matched by `serverUlid`). The
  ///      reactive `watchChannel` read has no hide-filter, so a delete disappears
  ///      from the UI with zero query change. An optimistic (`serverUlid NULL`)
  ///      own-message row is intentionally NOT matched here — it is handled at
  ///      Door B when its ack lands (the dead id above makes that safe).
  ///
  /// Idempotent (re-applying is a no-op insert + a no-op delete) and does NOT
  /// touch the history watermark — a live retraction is suppress-only; the pager
  /// remains the single writer of `historyContiguousThrough` (round-4 invariant).
  /// The same retraction also arrives as a history item and re-applies harmlessly.
  Future<void> applyRetraction(Retraction r) async {
    // Dead-id suppression + the hard-delete are STRING-IDENTITY equality against a
    // serverUlid. Canonical-ULID (UPPERCASE Crockford) is a CROSS-REPO CONTRACT the
    // whole component already relies on via DEBUG asserts — the watermark
    // (advanceHistoryContiguous), the history cursor, and serverUlid dedup all
    // assume it and none release-normalize. So assert canonical here too (loud in
    // dev on a contract violation) and store/compare the id as-is, matching that
    // discipline on ALL THREE surfaces (dead-id store, _isRetracted lookup,
    // hard-delete) so they stay mutually consistent.
    //
    // NOT a bespoke release-time toUpperCase() on this path (reverted after
    // cage-match Tesla, PR #102): normalizing only the dead-id table left
    // messages.serverUlid raw, so the hard-delete could MISS a case-skewed present
    // row — a half-wound coil worse than raw-vs-raw. The complete fix is to
    // canonicalize serverUlid at the INGEST stamp (W2/W3) so the identity string is
    // canonical system-wide; that is a whole-component change tracked as a follow-up
    // (claude-tasks), not a retraction-local patch. Under the island's canonical
    // contract, raw-vs-raw matches exactly and the debug assert guards dev.
    assertCanonicalUlid(r.targetMsgId, context: 'retraction target');
    assertCanonicalUlid(r.id, context: 'retraction id');
    await transaction(() async {
      // INSERT OR REPLACE = idempotent record via the target_msg_id PK.
      await customStatement(
        'INSERT OR REPLACE INTO ${_R.table} '
        '(${_R.targetMsgId}, ${_R.channelId}, ${_R.retractionId}) VALUES (?, ?, ?)',
        [r.targetMsgId, r.channelId, r.id],
      );
      await customStatement(
          'DELETE FROM ${_M.table} WHERE ${_M.serverUlid} = ?', [r.targetMsgId]);
    });
    notifyUpdates({const TableUpdate(_M.table), const TableUpdate(_R.table)});
  }

  /// DEFERRED prune hook (unused today): drop dead ids whose retraction ULID is
  /// strictly below [floorRetractionId]. Growth is one row per takedown ever —
  /// negligible at current scale — so this is not wired to any watermark. Present
  /// so the prune policy has a home when/if it is needed, not because it is.
  Future<void> pruneRetractedBelow(String floorRetractionId) async {
    await customStatement(
        'DELETE FROM ${_R.table} WHERE ${_R.retractionId} < ?', [floorRetractionId]);
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
      // Gate notify on a real change: the `serverUlid IS NULL` guard means a late
      // error for an already-sent row matches zero rows — finishing the octave
      // with reconcileAck/upsertInbound/advanceHistoryContiguous (cage-match Tesla).
      final changed = await _update(
          _M.table,
          {_M.deliveryState: DeliveryState.failed.wire},
          '${_M.clientTempId} = ? AND ${_M.serverUlid} IS NULL',
          [refClientMsgId]);
      if (changed > 0) notifyUpdates({const TableUpdate(_M.table)});
      return const [];
    }
    // Systemic: surface the affected pending rows to B4 (it decides policy).
    final where = StringBuffer('${_M.serverUlid} IS NULL');
    final args = <Object?>[];
    if (systemicChannelId != null) {
      where.write(' AND ${_M.channelId} = ?');
      args.add(systemicChannelId);
    }
    final rows = await customSelect(
      'SELECT * FROM ${_M.table} WHERE $where',
      variables: args.map((a) => Variable(a)).toList(),
    ).get();
    return rows.map((r) => _toDomain(MessageRow.fromRow(r))).toList();
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
    // Same zero-row gate as markFailed: a retry of an already-sent row (serverUlid
    // no longer NULL) matches nothing and must not emit a spurious re-query.
    final changed = await _update(
        _M.table,
        {_M.deliveryState: DeliveryState.sending.wire},
        '${_M.clientTempId} = ? AND ${_M.serverUlid} IS NULL',
        [clientTempId]);
    if (changed > 0) notifyUpdates({const TableUpdate(_M.table)});
  }

  // --- reads -----------------------------------------------------------------

  /// Reactive ordered message list for a channel. Ordering key:
  /// `(createdAt, localSeq, COALESCE(serverUlid, clientTempId))` — see design.
  Stream<List<Message>> watchChannel(String channelId) {
    return _watch(_M.table, () => _readChannel(channelId));
  }

  Future<List<Message>> _readChannel(String channelId) async {
    final rows = await customSelect(
      'SELECT * FROM ${_M.table} WHERE ${_M.channelId} = ? '
      'ORDER BY ${_M.createdAt}, ${_M.localSeq}, '
      'COALESCE(${_M.serverUlid}, ${_M.clientTempId})',
      variables: [Variable(channelId)],
    ).get();
    return rows.map((r) => _toDomain(MessageRow.fromRow(r))).toList();
  }

  /// Case-insensitive substring search over the body of ALL cached messages (the
  /// grep tier of #8). One-shot (not a stream): the search screen re-runs it per
  /// debounced keystroke.
  ///
  /// Visibility parity with the message list (concept_visibility_consistency):
  /// RETRACTED messages are already hard-deleted from this table by
  /// [applyRetraction], so a plain scan can never surface a taken-down message —
  /// the suppression is baked into the table's contents, not re-applied here.
  /// BLOCKED-sender filtering is NOT the cache's job (it has no block list); the
  /// provider layer applies it, exactly as [messagesProvider] layers it over the
  /// visibility-agnostic [watchChannel]. Newest-first, capped at [limit] so a
  /// broad query can't build an unbounded list.
  Future<List<Message>> searchMessages(String query, {int limit = 200}) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    // `%`/`_` are LIKE wildcards; escape them (and the escape char) and declare an
    // ESCAPE so a literal `50%` search is a literal substring, not a pattern. The
    // pattern itself is a BOUND variable, so this is injection-safe regardless of
    // contents.
    final escaped = needle
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    final rows = await customSelect(
      "SELECT * FROM ${_M.table} WHERE LOWER(${_M.body}) LIKE ? ESCAPE '\\' "
      'ORDER BY ${_M.createdAt} DESC LIMIT ?',
      variables: [Variable('%$escaped%'), Variable(limit)],
    ).get();
    return rows.map((r) => _toDomain(MessageRow.fromRow(r))).toList();
  }

  /// Invariant O — the outbox is a QUERY, not a table: every un-acked,
  /// not-failed row, in send order.
  Future<List<Message>> outbox() async {
    final rows = await customSelect(
      'SELECT * FROM ${_M.table} WHERE ${_M.serverUlid} IS NULL '
      "AND ${_M.deliveryState} != ? "
      'ORDER BY ${_M.createdAt}, ${_M.localSeq}',
      variables: [Variable(DeliveryState.failed.wire)],
    ).get();
    return rows.map((r) => _toDomain(MessageRow.fromRow(r))).toList();
  }

  // --- reconnect resume watermark (design 04 §Gap 2, round 4) -----------------

  /// The reconnect resume cursor for [channelId]: the newest ULID through which
  /// history is contiguously cached. NULL until the first page is durably
  /// applied (fresh install) → the pager fetches from the start.
  Future<String?> historyContiguousThrough(String channelId) async {
    final rows = await customSelect(
      'SELECT ${_S.historyContiguousThrough} AS h FROM ${_S.table} WHERE ${_S.channelId} = ?',
      variables: [Variable(channelId)],
    ).get();
    return rows.isEmpty ? null : rows.first.readNullable<String>('h');
  }

  /// Reactive [historyContiguousThrough]: emits the resume fence for [channelId]
  /// and re-emits when the pager advances it. NULL until the first page is durably
  /// applied — i.e. non-null means "history sync has SETTLED for this channel"
  /// (including `''`, the empty-channel sentinel). Read-only (no writer added); the
  /// unread indicator uses it to know when a channel's baseline may be taken,
  /// rather than trusting a pre-sync empty stream emission.
  Stream<String?> watchHistoryContiguousThrough(String channelId) {
    // Wrap in a 1-element list so the fetched value is a non-null Object (the
    // stream helper is generic over Object); unwrap on the way out.
    return _watch(_S.table, () async => [await historyContiguousThrough(channelId)])
        .map((wrapped) => wrapped.single);
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
    var wrote = false;
    await transaction(() async {
      final current = await historyContiguousThrough(channelId);
      if (current != null && ulid.compareTo(current) <= 0) {
        return; // not strictly forward — never rewind.
      }
      // INSERT OR REPLACE = upsert on the channel_id PK.
      await customStatement(
        'INSERT OR REPLACE INTO ${_S.table} '
        '(${_S.channelId}, ${_S.historyContiguousThrough}) VALUES (?, ?)',
        [channelId, ulid],
      );
      wrote = true;
    });
    // A non-monotonic (rewind-attempt) call writes nothing — don't re-emit the
    // unchanged watermark to an edge-triggered consumer (cage-match Tesla).
    if (wrote) notifyUpdates({const TableUpdate(_S.table)});
  }
}
