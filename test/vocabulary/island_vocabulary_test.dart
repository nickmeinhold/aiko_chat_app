// The app never says "server" or "gateway" to a person. It says "island".
//
// Nick's ruling, 2026-09-02: "I don't want the app to ever say 'server' or
// 'gateway'... it should say 'island'." That is ADR-0001 restated at the UI:
// ISLAND is "the user-facing federation word", while GATEWAY names "a thin
// internal bridge service INSIDE an Island" — so `/settings/gateway` was not a
// loose synonym, it named a different thing, one scope level down. And "server"
// is the exact word ADR-0001's own motivation was written to kill: "Vocabulary
// drift is design drift. 'Server', 'user', and 'identity' each meant three
// different things."
//
// WHY A TEST AND NOT A NOTE. The drift did not arrive in one bad commit — it
// accumulated one honest string at a time, in seven files, over months, while a
// numbered ADR sat in `docs/adr/` saying otherwise. A rule that lives only in
// prose is re-broken by the next person writing a snackbar at speed. This is the
// enforcement point.
//
// HOW IT WORKS. Every Dart string literal under `lib/` is checked (comment lines
// are skipped — a comment is not something the app says). Anything containing
// "server" or "gateway" must appear verbatim in [_permitted] below, which holds
// only strings the USER NEVER SEES: SQL, storage keys, wire paths, telemetry,
// and developer assertions. A new one is a decision, so it has to be written
// down here to pass.
//
// If this test fails on a string a person reads, the fix is the word, not the
// allowlist.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Literals that legitimately carry "server"/"gateway" because the user never
/// reads them. Each is machine-facing: a column, a key, a route on the wire, a
/// log line, or an assertion aimed at us.
const _permitted = <String>{
  // Drift/SQL — `server_ulid` is the island-assigned message id column.
  'server_ulid',
  r'${_M.islandUlid} = ?',
  r'${_M.islandUlid} IS NULL',
  r'${_M.clientTempId} = ? AND ${_M.islandUlid} IS NULL',
  r'COALESCE(${_M.islandUlid}, ${_M.clientTempId})',
  r'DELETE FROM ${_M.table} WHERE ${_M.islandUlid} = ?',
  r'SELECT * FROM ${_M.table} WHERE ${_M.islandUlid} IS NULL ',
  r'islandUlid $u matched a row in channel ${existing.channelId} ',
  r'!= ${islandMsg.channelId} — corruption, refusing to overwrite',
  // LEGACY storage keys, read-only. These are the pre-vocabulary names, kept so
  // an existing install's island choice can be adopted forward under the new key
  // (see `pref_key_migration.dart`). They disappear when that fallback does.
  'aiko_gateway_base_url',
  'aiko_known_gateways',
  // Wire: the island's own directory endpoint and its JSON fields.
  r'$base/v1/gateways',
  'gateways',
  'servers',
  // Telemetry and debug output.
  r'sender=${senderUserId ?? "-"} channel=$channelId ulid=$islandUlid ',
  r'IslandConfig($httpBaseUrl)',
  'IslandDirectoryClient',
  // A developer `assert` about the gateway service's own REST contract (is
  // `after` exclusive?). Aimed at us, and "gateway" is the CORRECT word — the
  // cursor belongs to the bridge service, not to the island.
  '— is the gateway `after` cursor exclusive?',
};

/// Strings a person reads must use the product's word.
final _banned = RegExp(r'\b(server|gateway)s?\b', caseSensitive: false);

/// Dart string literals on one line, single- or double-quoted.
final _literal = RegExp(
  r"'([^'\\]*(?:\\.[^'\\]*)*)'"
  r'|"([^"\\]*(?:\\.[^"\\]*)*)"',
);

/// An import/export path is machine-facing by construction.
bool _isPath(String s) =>
    s.startsWith('package:') ||
    s.startsWith('dart:') ||
    s.startsWith('../') ||
    s.endsWith('.dart');

void main() {
  test('no user-facing string says "server" or "gateway" — the app says '
      '"island" (ADR-0001)', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final trimmed = line.trimLeft();
        // A comment is not something the app SAYS. Doc comments legitimately
        // discuss the gateway service by its correct internal name.
        if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;
        for (final m in _literal.allMatches(line)) {
          final value = m.group(1) ?? m.group(2) ?? '';
          if (!_banned.hasMatch(value)) continue;
          if (_isPath(value) || _permitted.contains(value)) continue;
          offenders.add('${entity.path}:${i + 1}  "$value"');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These strings say "server"/"gateway" where the app should say '
          '"island" (ADR-0001: Island is the user-facing federation word; '
          'Gateway is an internal service inside one).\n'
          'If a string here is genuinely machine-facing, add it verbatim to '
          '_permitted with a note saying why.\n\n${offenders.join('\n')}',
    );
  });

  test(
    'the island picker route is /settings/island, not /settings/gateway',
    () {
      // The route is semi-visible: it is what a deep link says out loud.
      final hits = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.readAsStringSync().contains('/settings/gateway')) {
          hits.add(entity.path);
        }
      }
      expect(hits, isEmpty);
    },
  );
}
