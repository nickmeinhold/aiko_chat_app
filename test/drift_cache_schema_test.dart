// Schema-consistency: the guarantee drift_dev's codegen used to give for free.
//
// Without a generator keeping the typed tables in lockstep with the schema, the
// hand-written DDL (onCreate) and the column names the row readers use could
// silently drift apart. This test pins them: it opens a fresh DB (onCreate) and
// asserts every table's live schema — column names, TYPE, NULLABILITY, DEFAULT,
// and PRIMARY KEY — matches the DECLARED schema (`DriftCache.tableSchemas`, the
// same source of truth the DDL is built from). A column added/retyped/renullabled
// in the DDL but not reflected in a reader (or vice versa) fails loudly. This is
// the determinism the generator provided, replaced by an explicit test.

import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Parse a declared DDL column fragment (e.g. "INTEGER NOT NULL DEFAULT 0") into
/// the fields `PRAGMA table_info` reports: affinity type, notnull flag, default.
({String type, bool notNull, String? dflt}) parseFragment(String f) {
  final upper = f.toUpperCase();
  final type = f.split(RegExp(r'\s+')).first;
  final notNull = upper.contains('NOT NULL');
  String? dflt;
  final m = RegExp(r'DEFAULT\s+(\S+)', caseSensitive: false).firstMatch(f);
  if (m != null) dflt = m.group(1);
  return (type: type, notNull: notNull, dflt: dflt);
}

void main() {
  late DriftCache cache;
  setUp(() => cache = DriftCache(NativeDatabase.memory()));
  tearDown(() => cache.close());

  for (final entry in DriftCache.tableSchemas.entries) {
    final table = entry.key;
    final declared = entry.value;

    test('onCreate schema for $table matches the declared columns/types/nullability/pk',
        () async {
      await cache.customSelect('SELECT 1').get(); // force onCreate
      final info = await cache.customSelect('PRAGMA table_info($table)').get();

      final liveByName = {for (final r in info) r.read<String>('name'): r};

      // 1. Column SET matches exactly (no missing / extra columns).
      expect(liveByName.keys.toSet(), declared.columns.keys.toSet(),
          reason: '$table columns drifted from the declared schema');

      // 2. Per-column type, nullability, and default match the declaration.
      declared.columns.forEach((col, fragment) {
        final want = parseFragment(fragment);
        final row = liveByName[col]!;
        expect(row.read<String>('type'), want.type,
            reason: '$table.$col type');
        expect(row.read<int>('notnull') == 1, want.notNull,
            reason: '$table.$col nullability');
        expect(row.readNullable<String>('dflt_value'), want.dflt,
            reason: '$table.$col default');
      });

      // 3. PRIMARY KEY is exactly the declared PK column.
      final pkCols = {
        for (final r in info)
          if (r.read<int>('pk') > 0) r.read<String>('name')
      };
      expect(pkCols, {declared.pk}, reason: '$table primary key');
    });
  }

  test('messages.server_ulid is UNIQUE (Invariant U — no duplication at rest)', () async {
    await cache.customSelect('SELECT 1').get();
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
