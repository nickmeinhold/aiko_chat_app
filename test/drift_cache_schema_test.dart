// Schema-consistency: the guarantee drift_dev's codegen used to give for free.
//
// Without a generator keeping the typed tables in lockstep with the schema, the
// hand-written DDL (onCreate) and the column names the row readers use could
// silently drift apart. This test pins them: it opens a fresh DB (onCreate) and
// asserts every table's live columns are EXACTLY the documented set. A column
// added to the DDL but not here (or vice versa) fails loudly — the determinism
// the generator provided, replaced by an explicit test.

import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DriftCache cache;
  setUp(() => cache = DriftCache(NativeDatabase.memory()));
  tearDown(() => cache.close());

  Future<Set<String>> columnsOf(String table) async {
    final rows = await cache.customSelect('PRAGMA table_info($table)').get();
    return {for (final r in rows) r.read<String>('name')};
  }

  // The on-disk schema the app depends on (snake_case, matching the pre-codegen
  // generated schema 1:1 so existing installs upgrade in place).
  const expected = <String, Set<String>>{
    'messages': {
      'client_temp_id', 'server_ulid', 'channel_id', 'sender_user_id',
      'sender_kind', 'sender_label', 'kind', 'body', 'reply_to_id', 'created_at',
      'local_seq', 'delivery_state', 'sig', 'sender_pubkey', 'signed_at_ms',
      'key_version', 'signed_client_msg_id', 'origin_crypto_valid',
    },
    'channels': {'id', 'name', 'kind', 'aiko_channel', 'ordinal'},
    'sync_meta': {'channel_id', 'history_contiguous_through'},
    'retracted_ids': {'target_msg_id', 'channel_id', 'retraction_id'},
  };

  for (final entry in expected.entries) {
    test('onCreate schema for ${entry.key} matches the documented columns', () async {
      // Force onCreate.
      await cache.customSelect('SELECT 1').get();
      expect(await columnsOf(entry.key), entry.value,
          reason: 'live ${entry.key} columns drifted from the readers');
    });
  }

  test('messages PK is client_temp_id and server_ulid is UNIQUE', () async {
    await cache.customSelect('SELECT 1').get();
    final info = await cache.customSelect('PRAGMA table_info(messages)').get();
    final pk = {
      for (final r in info)
        if (r.read<int>('pk') > 0) r.read<String>('name')
    };
    expect(pk, {'client_temp_id'}, reason: 'PK must be client_temp_id');

    // server_ulid UNIQUE (Invariant U): a duplicate non-null insert must fail.
    await cache.customStatement(
        "INSERT INTO messages (client_temp_id, server_ulid, channel_id, "
        "sender_kind, kind, body, created_at, delivery_state) "
        "VALUES ('a', 'U1', 'c', 'human', 'text', 'x', 1, 'sent')");
    expect(
      () => cache.customStatement(
          "INSERT INTO messages (client_temp_id, server_ulid, channel_id, "
          "sender_kind, kind, body, created_at, delivery_state) "
          "VALUES ('b', 'U1', 'c', 'human', 'text', 'y', 2, 'sent')"),
      throwsA(anything),
      reason: 'a duplicate non-null server_ulid must violate UNIQUE',
    );
  });
}
