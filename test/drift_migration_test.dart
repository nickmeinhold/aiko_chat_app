// Schema-migration tests for DriftCache.onUpgrade (cage-match PR #67 finding F1).
//
// THE BLIND SPOT this closes: every other test opens `NativeDatabase.memory()`,
// so onCreate builds the CURRENT schema (v6) and the `onUpgrade` branches NEVER
// execute. A broken ALTER (wrong name, dropped NOT-NULL, lost data) would ship
// green. The messages store is a trust-boundary (Invariant U — no duplication at
// rest), so its migrations earn a real test.
//
// Strategy (self-contained, no generated schema snapshots): build the CURRENT
// schema with a real DriftCache over a FILE, DOWNGRADE it by hand (drop the newer
// columns + set `PRAGMA user_version`), write an old-shape row, then REOPEN —
// which triggers drift's ACTUAL `onUpgrade` from that version. We assert the row
// survives with NULLs in the freshly-added columns. This exercises the production
// migration code, not a regenerated stand-in.
//
// Assertions use raw SQL (`customSelect`/`customStatement`) rather than a typed
// query builder — the store is now hand-authored over drift's runtime, so there
// is no generated table DSL to select through. The migration STRATEGY is
// unchanged; only the read/write API is raw SQL (as half this file already was).

import 'dart:io';

import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/retraction.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('aiko_migration_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File dbFile(String name) => File('${tmp.path}/$name.sqlite');

  /// Force onCreate (createAll @ current schema) on a freshly-opened cache.
  Future<void> open(DriftCache c) => c.customSelect('SELECT 1').get();

  /// Insert one minimal row using ONLY the columns that exist at every schema
  /// version >= 1 (the required, non-nullable, no-default set).
  Future<void> insertBaselineRow(DriftCache c, String id) => c.customStatement(
        "INSERT INTO messages "
        "(client_temp_id, channel_id, sender_kind, kind, body, created_at, delivery_state) "
        "VALUES (?, 'general', 'human', 'text', 'survives migration', 1735000000000, 'sent')",
        [id],
      );

  Future<int> rowCount(DriftCache c) async {
    final r = await c.customSelect('SELECT COUNT(*) AS n FROM messages').getSingle();
    return r.read<int>('n');
  }

  Future<QueryRow> singleMessage(DriftCache c) =>
      c.customSelect('SELECT * FROM messages').getSingle();

  test('v3 -> v4 upgrade adds the wire-half columns, keeping existing rows (NULLs)',
      () async {
    final file = dbFile('v3');

    // 1. Build the CURRENT (v6) schema, then hand-downgrade to v3.
    final v3 = DriftCache(NativeDatabase(file));
    await open(v3);
    await v3.customStatement('ALTER TABLE messages DROP COLUMN signed_client_msg_id');
    await v3.customStatement('ALTER TABLE messages DROP COLUMN origin_crypto_valid');
    await v3.customStatement('ALTER TABLE channels DROP COLUMN ordinal'); // v5 col
    await insertBaselineRow(v3, 'row-v3');
    await v3.customStatement('PRAGMA user_version = 3');
    await v3.close();

    // 2. Reopen -> drift sees user_version 3 < 6 -> runs onUpgrade(from: 3).
    final v4 = DriftCache(NativeDatabase(file));
    addTearDown(v4.close);

    // 3. The pre-existing row survives, and the freshly-added columns are NULL.
    expect(await rowCount(v4), 1, reason: 'the v3 row must survive the migration');
    final row = await singleMessage(v4);
    expect(row.read<String>('body'), 'survives migration');
    expect(row.readNullable<String>('signed_client_msg_id'), isNull,
        reason: 'a pre-v4 row has no signed client_msg_id');
    expect(row.readNullable<int>('origin_crypto_valid'), isNull,
        reason: 'a pre-v4 row has no local verify verdict');

    // And a NEW row can use the added columns (the column is really there).
    await v4.customStatement(
        "INSERT INTO messages "
        "(client_temp_id, channel_id, sender_kind, kind, body, created_at, "
        " delivery_state, signed_client_msg_id, origin_crypto_valid) "
        "VALUES ('row-v4', 'general', 'human', 'text', 'new', 1, 'sent', 'sig-cid', 1)");
    final fresh = await v4
        .customSelect("SELECT * FROM messages WHERE client_temp_id = 'row-v4'")
        .getSingle();
    expect(fresh.readNullable<String>('signed_client_msg_id'), 'sig-cid');
    expect(fresh.readNullable<int>('origin_crypto_valid'), 1);
  });

  test('v4 -> v5 upgrade adds channels.ordinal, keeping existing channel rows',
      () async {
    final file = dbFile('v4');

    final v4 = DriftCache(NativeDatabase(file));
    await open(v4);
    await v4.customStatement('ALTER TABLE channels DROP COLUMN ordinal');
    await v4.customStatement(
        "INSERT INTO channels (id, name, kind) VALUES ('c-old', 'general', 'standard')");
    await v4.customStatement('PRAGMA user_version = 4');
    await v4.close();

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

    final v2 = DriftCache(NativeDatabase(file));
    await open(v2);
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

    final v4 = DriftCache(NativeDatabase(file));
    addTearDown(v4.close);

    expect(await rowCount(v4), 1, reason: 'the v2 row must survive');
    final row = await singleMessage(v4);
    expect(row.read<String>('body'), 'survives migration');
    // All six columns added across v3 + v4 are NULL on the pre-existing row.
    expect(row.readNullable<String>('sig'), isNull);
    expect(row.readNullable<String>('sender_pubkey'), isNull);
    expect(row.readNullable<int>('signed_at_ms'), isNull);
    expect(row.readNullable<int>('key_version'), isNull);
    expect(row.readNullable<String>('signed_client_msg_id'), isNull);
    expect(row.readNullable<int>('origin_crypto_valid'), isNull);
  });

  test('v5 -> v6 upgrade creates the retracted_ids table, keeping existing rows',
      () async {
    final file = dbFile('v5');

    final v5 = DriftCache(NativeDatabase(file));
    await open(v5);
    await v5.customStatement('DROP TABLE retracted_ids');
    await insertBaselineRow(v5, 'row-v5');
    await v5.customStatement('PRAGMA user_version = 5');
    await v5.close();

    final v6 = DriftCache(NativeDatabase(file));
    addTearDown(v6.close);

    expect(await rowCount(v6), 1, reason: 'the v5 message row must survive');
    expect((await singleMessage(v6)).read<String>('body'), 'survives migration');

    // retracted_ids was created and is usable: a takedown records + suppresses.
    await v6.applyRetraction(
        const Retraction(channelId: 'general', id: '01Z', targetMsgId: '01A'));
    final n =
        await v6.customSelect('SELECT COUNT(*) AS n FROM retracted_ids').getSingle();
    expect(n.read<int>('n'), 1, reason: 'retracted_ids recreated + writable');
  });

  test('v1 -> v4 upgrade recreates sync_meta AND adds every signing column',
      () async {
    final file = dbFile('v1');

    final v1 = DriftCache(NativeDatabase(file));
    await open(v1);
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

    final v4 = DriftCache(NativeDatabase(file));
    addTearDown(v4.close);

    expect(await rowCount(v4), 1, reason: 'the v1 row must survive');
    // sync_meta was recreated and is usable (advanceHistoryContiguous writes it).
    await v4.advanceHistoryContiguous('general', '01ULID');
    final meta =
        await v4.customSelect('SELECT COUNT(*) AS n FROM sync_meta').getSingle();
    expect(meta.read<int>('n'), 1, reason: 'sync_meta recreated + writable');
    final row = await singleMessage(v4);
    expect(row.readNullable<String>('sig'), isNull);
    expect(row.readNullable<int>('origin_crypto_valid'), isNull);
  });
}
