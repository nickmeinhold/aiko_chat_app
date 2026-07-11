// Schema-migration tests for DriftCache.onUpgrade (cage-match PR #67 finding F1).
//
// THE BLIND SPOT this closes: every other test opens `NativeDatabase.memory()`,
// so drift runs `onCreate → createAll()` at the CURRENT schema (v4) and the
// `onUpgrade` branches NEVER execute. A broken addColumn (wrong name, dropped
// NOT-NULL, lost data) would ship green. The messages store is a trust-boundary
// (Invariant U — no duplication at rest), so its migrations earn a real test.
//
// Strategy (self-contained, no generated schema snapshots — those would need the
// historical code that produced v1/v2/v3): build the CURRENT schema with a real
// DriftCache over a FILE, DOWNGRADE it by hand (drop the newer columns + set
// `PRAGMA user_version`), write an old-shape row, then REOPEN — which triggers
// drift's ACTUAL `onUpgrade` from that version. We assert the row survives with
// NULLs in the freshly-added columns. This exercises the production migration
// code, not a regenerated stand-in.

import 'dart:io';

import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('aiko_migration_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File dbFile(String name) => File('${tmp.path}/$name.sqlite');

  /// Insert one minimal row using ONLY the columns that exist at every schema
  /// version >= 1 (the required, non-nullable, no-default set). Raw SQL because
  /// the Dart table definition still declares the newer columns — a drift insert
  /// would reference columns this downgraded table no longer has.
  Future<void> insertBaselineRow(DriftCache c, String id) => c.customStatement(
        "INSERT INTO messages "
        "(client_temp_id, channel_id, sender_kind, kind, body, created_at, delivery_state) "
        "VALUES (?, 'general', 'human', 'text', 'survives migration', 1735000000000, 'sent')",
        [id],
      );

  /// The count of rows in `messages` — a cheap survival probe over raw SQL so it
  /// works regardless of which columns the current schema has.
  Future<int> rowCount(DriftCache c) async {
    final r = await c.customSelect('SELECT COUNT(*) AS n FROM messages').getSingle();
    return r.read<int>('n');
  }

  test('v3 -> v4 upgrade adds the wire-half columns, keeping existing rows (NULLs)',
      () async {
    final file = dbFile('v3');

    // 1. Build the CURRENT (v4) schema, then hand-downgrade to v3.
    final v3 = DriftCache(NativeDatabase(file));
    await v3.select(v3.channels).get(); // force onCreate (createAll @ current)
    await v3.customStatement('ALTER TABLE messages DROP COLUMN signed_client_msg_id');
    await v3.customStatement('ALTER TABLE messages DROP COLUMN origin_crypto_valid');
    await v3.customStatement('ALTER TABLE channels DROP COLUMN ordinal'); // v5 col
    await insertBaselineRow(v3, 'row-v3');
    await v3.customStatement('PRAGMA user_version = 3');
    await v3.close();

    // 2. Reopen -> drift sees user_version 3 < 4 -> runs onUpgrade(from: 3).
    final v4 = DriftCache(NativeDatabase(file));
    addTearDown(v4.close);

    // 3. The pre-existing row survives, and the freshly-added columns are NULL.
    final rows = await v4.select(v4.messages).get();
    expect(rows.length, 1, reason: 'the v3 row must survive the migration');
    final row = rows.single;
    expect(row.body, 'survives migration');
    expect(row.signedClientMsgId, isNull,
        reason: 'a pre-v4 row has no signed client_msg_id');
    expect(row.originCryptoValid, isNull,
        reason: 'a pre-v4 row has no local verify verdict');

    // And a NEW row can use the added columns (the column is really there + typed).
    await v4.customStatement(
        "INSERT INTO messages "
        "(client_temp_id, channel_id, sender_kind, kind, body, created_at, "
        " delivery_state, signed_client_msg_id, origin_crypto_valid) "
        "VALUES ('row-v4', 'general', 'human', 'text', 'new', 1, 'sent', 'sig-cid', 1)");
    final fresh = await (v4.select(v4.messages)
          ..where((t) => t.clientTempId.equals('row-v4')))
        .getSingle();
    expect(fresh.signedClientMsgId, 'sig-cid');
    expect(fresh.originCryptoValid, 1);
  });

  test('v4 -> v5 upgrade adds channels.ordinal, keeping existing channel rows',
      () async {
    final file = dbFile('v4');

    // Downgrade to v4: drop only the v5 channels.ordinal column, seed a channel.
    final v4 = DriftCache(NativeDatabase(file));
    await v4.select(v4.channels).get();
    await v4.customStatement('ALTER TABLE channels DROP COLUMN ordinal');
    await v4.customStatement(
        "INSERT INTO channels (id, name, kind) VALUES ('c-old', 'general', 'standard')");
    await v4.customStatement('PRAGMA user_version = 4');
    await v4.close();

    // Reopen -> onUpgrade(from: 4) runs the from<5 addColumn(channels.ordinal).
    final v5 = DriftCache(NativeDatabase(file));
    addTearDown(v5.close);

    final channels = await v5.readChannels();
    expect(channels.length, 1, reason: 'the pre-v5 channel row survives');
    expect(channels.single.id, 'c-old');
    // The added ordinal column is really there + usable by a fresh save.
    await v5.saveChannels(const [
      Channel(id: 'a', name: 'A', kind: ChannelKind.standard),
      Channel(id: 'b', name: 'B', kind: ChannelKind.standard),
    ]);
    expect((await v5.readChannels()).map((c) => c.id).toList(), ['a', 'b']);
  });

  test('v2 -> v4 upgrade adds the v3 signing columns AND the v4 wire columns',
      () async {
    final file = dbFile('v2');

    // Downgrade to v2: drop the v3 signing columns AND the v4 wire columns.
    final v2 = DriftCache(NativeDatabase(file));
    await v2.select(v2.channels).get();
    for (final col in [
      'signed_client_msg_id',
      'origin_crypto_valid',
      'sig',
      'sender_pubkey',
      'signed_at_ms',
      'key_version',
    ]) {
      await v2.customStatement('ALTER TABLE messages DROP COLUMN $col');
    }
    await v2.customStatement('ALTER TABLE channels DROP COLUMN ordinal'); // v5 col
    await insertBaselineRow(v2, 'row-v2');
    await v2.customStatement('PRAGMA user_version = 2');
    await v2.close();

    // Reopen -> onUpgrade(from: 2) runs BOTH the from<3 and from<4 branches.
    final v4 = DriftCache(NativeDatabase(file));
    addTearDown(v4.close);

    expect(await rowCount(v4), 1, reason: 'the v2 row must survive');
    final row = await v4.select(v4.messages).getSingle();
    expect(row.body, 'survives migration');
    // All six columns added across v3 + v4 are NULL on the pre-existing row.
    expect(row.sig, isNull);
    expect(row.senderPubkey, isNull);
    expect(row.signedAtMs, isNull);
    expect(row.keyVersion, isNull);
    expect(row.signedClientMsgId, isNull);
    expect(row.originCryptoValid, isNull);
  });

  test('v1 -> v4 upgrade recreates sync_meta AND adds every signing column',
      () async {
    final file = dbFile('v1');

    // Downgrade to v1: drop sync_meta (added at v2) + all v3/v4 columns.
    final v1 = DriftCache(NativeDatabase(file));
    await v1.select(v1.channels).get();
    await v1.customStatement('DROP TABLE sync_meta');
    for (final col in [
      'signed_client_msg_id',
      'origin_crypto_valid',
      'sig',
      'sender_pubkey',
      'signed_at_ms',
      'key_version',
    ]) {
      await v1.customStatement('ALTER TABLE messages DROP COLUMN $col');
    }
    await v1.customStatement('ALTER TABLE channels DROP COLUMN ordinal'); // v5 col
    await insertBaselineRow(v1, 'row-v1');
    await v1.customStatement('PRAGMA user_version = 1');
    await v1.close();

    // Reopen -> onUpgrade(from: 1) runs from<2 (createTable syncMeta) + from<3 + from<4.
    final v4 = DriftCache(NativeDatabase(file));
    addTearDown(v4.close);

    expect(await rowCount(v4), 1, reason: 'the v1 row must survive');
    // sync_meta was recreated and is usable (advanceHistoryContiguous writes it).
    await v4.advanceHistoryContiguous('general', '01ULID');
    final meta = await v4
        .customSelect('SELECT COUNT(*) AS n FROM sync_meta')
        .getSingle();
    expect(meta.read<int>('n'), 1, reason: 'sync_meta recreated + writable');
    final row = await v4.select(v4.messages).getSingle();
    expect(row.sig, isNull);
    expect(row.originCryptoValid, isNull);
  });
}
