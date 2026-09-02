// The app says "island". ADR-0001: ISLAND is the user-facing federation word,
// GATEWAY is the bridge service INSIDE an island, and SERVER is the host it runs
// on. Only the first two may appear in shipped text; the third is sayable as a
// NAME with a reason (see [_permittedIdentifiers]).
//
// Scans every string literal and every identifier under lib/ and test/. Comment
// lines are excluded — a comment is not something the app says.
//
// The allowlists are themselves guarded: an entry must contain a banned word (or
// it exempts nothing) and must occur as a live literal (or its reason has gone).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Literals that carry a banned word because the user never reads them.
///
/// COVERAGE BOUNDARY: [_banned] is word-boundary anchored, so a snake_case
/// token (`server_ulid`) never matches. Deliberate — this hunts prose.
const _permitted = <String>{
  // A developer `assert` about the gateway service's own REST contract (is
  // `after` exclusive?). Aimed at us, and "gateway" is the CORRECT word — the
  // cursor belongs to the bridge service, not to the island.
  '— is the gateway `after` cursor exclusive?',
};

/// Exemptions scoped to one file, so a wire-field name cannot be exempted
/// everywhere.
const _permittedInFile = <String, Set<String>>{};

/// Identifiers that may carry "gateway" because they NAME THE BRIDGE SERVICE
/// the client speaks to — ADR-0001's Gateway, not its Island — plus the legacy
/// storage-key constants, which are strings-as-names and cannot move.
/// Identifiers exempt from the rule, each with its reason. A map, not a set:
/// an exemption without a stated reason is how a wrong one survives.
///
/// Meaning 3 (the HOST) belongs here too, with a reason naming the host —
/// not bent into island or gateway to get past this.
const _permittedIdentifiers = <String, String>{
  // Meaning 2 — the bridge service and everything that speaks to it.
  'GatewayRestApi': 'the REST client for the bridge service',
  'buildGatewayBackend': 'constructs GatewayRestApi',
  'gateway_rest_api': 'file for the above',
  'GatewayTransport': 'the WSS transport to the bridge service',
  'gateway_transport': 'file for the above',
  'GatewayCapabilities': 'what the bridge service advertises it carries',
  'gateway_capabilities': 'file for the above',
  'gatewayCapabilities': 'field holding the above',
  'GatewayFrame': 'a frame arriving on the gateway socket',
  'closeFromGateway': 'test fake: a WS close from the bridge service',
  '_parseGatewayTime':
      'parses a timestamp field of an AckFrame, which IS a GatewayFrame — the '
      'bin its sibling closeFromGateway landed in',
  // Legacy storage keys, read-only until task #25 retires the migration.
  'kLegacyIslandBaseUrlPrefKey': 'names the pre-vocabulary pref key',
  'kLegacyKnownIslandsPrefKey': 'names the pre-vocabulary pref key',
  'aiko_gateway_base_url': 'the pref key itself; renaming strands installs',
  'aiko_known_gateways': 'the pref key itself; renaming strands installs',
  'GATEWAY_BASE_URL':
      'the renamed-away dart-define, read only so a stale build flag throws '
      'instead of silently resolving to production',
  // Meaning 3 has no entries yet. When one is needed it belongs HERE, with a
  // reason naming the HOST — not bent into island or gateway to get past this.
};

/// Strings a person reads must use the product's word.
final _banned = RegExp(r'\b(server|gateway)s?\b', caseSensitive: false);

/// Dart string literals on one line, single- or double-quoted.
final _literal = RegExp(
  r"'([^'\\]*(?:\\.[^'\\]*)*)'"
  r'|"([^"\\]*(?:\\.[^"\\]*)*)"',
);

/// Triple-quoted literals, which span lines and are therefore invisible to a
/// line-oriented scan. Kelvin's catch, and this guard's biggest hole: the
/// single-line pattern matches the empty string between the first two quotes and
/// never sees the body, so a multi-line help string — exactly where user-facing
/// prose lives — passed in silence.
///
/// KNOWN BOUND, stated rather than papered over (Carnot): this is a regex, not
/// the Dart analyzer. Adjacent-fragment concatenation IS covered, because each
/// fragment sits on its own line and is scanned as its own literal; a banned word
/// split ACROSS fragments ('ser' 'ver') would pass. Nobody writes that by
/// accident, and buying it would cost an analyzer dependency in a vocabulary
/// test. If this ever needs to be airtight rather than high-yield, switch to
/// `package:analyzer` string-token parsing.
final _tripleLiteral = RegExp(
  r"'''([\s\S]*?)'''"
  r'|"""([\s\S]*?)"""',
);

/// Global exemptions plus any scoped to [path].
bool _isPermitted(String path, String value) =>
    _permitted.contains(value) ||
    (_permittedInFile[path]?.contains(value) ?? false);

/// An import/export path is machine-facing by construction.
bool _isPath(String s) =>
    s.startsWith('package:') ||
    s.startsWith('dart:') ||
    s.startsWith('../') ||
    s.endsWith('.dart');

/// SCOPE DIFFERS BY RULE, on purpose.
///
/// The STRING rule is about what the APP SAYS to a person, so it scans lib/ only —
/// a test description is not something the app says, and it legitimately discusses
/// the gateway service and island-assigned timestamps.
///
/// The IDENTIFIER rule is about code following the vocabulary, so it scans lib/ AND
/// test/. test/ sat outside every instrument's coverage until 2026-09-03, and seven
/// declarations named for the banned word had survived there.
List<File> _dartFiles(List<String> roots) => roots
    .map(Directory.new)
    .expand((d) => d.listSync(recursive: true))
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    // This file names the banned words in order to police them.
    .where((f) => !f.path.endsWith('island_vocabulary_test.dart'))
    .toList(growable: false);

void main() {
  test('no user-facing string says "server" or "gateway" — the app says '
      '"island" (ADR-0001)', () {
    final offenders = <String>[];

    for (final entity in _dartFiles(['lib'])) {
      final source = entity.readAsStringSync();

      // Triple-quoted literals first, over the WHOLE file — a line-oriented
      // pass structurally cannot see them.
      for (final m in _tripleLiteral.allMatches(source)) {
        final value = m.group(1) ?? m.group(2) ?? '';
        if (!_banned.hasMatch(value)) continue;
        if (_isPermitted(entity.path, value)) continue;
        final line = '\n'.allMatches(source.substring(0, m.start)).length + 1;
        offenders.add('${entity.path}:$line  (triple-quoted) "$value"');
      }

      final lines = source.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        var scannable = line;
        final trimmed = line.trimLeft();
        // A comment is not something the app SAYS. Doc comments legitimately
        // discuss the gateway service by its correct internal name.
        if (trimmed.startsWith('//')) continue;
        if (trimmed.startsWith('*')) {
          // A block-comment line — but the CLOSE of a block comment can carry
          // real code after it (`*/ final s = 'server';`), and skipping the
          // whole line would blind the guard to that literal (Carnot's catch).
          // Scan only what follows the terminator; skip the line when there is
          // none, because then it is comment all the way to the newline.
          final close = line.indexOf('*/');
          if (close < 0) continue;
          scannable = line.substring(close + 2);
        }
        for (final m in _literal.allMatches(scannable)) {
          final value = m.group(1) ?? m.group(2) ?? '';
          if (!_banned.hasMatch(value)) continue;
          if (_isPath(value) || _isPermitted(entity.path, value)) continue;
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
      final hits = _dartFiles(['lib'])
          .where((f) => f.readAsStringSync().contains('/settings/gateway'))
          .map((f) => f.path)
          .toList();
      expect(hits, isEmpty);
    },
  );

  test('no allowlist entry is DEAD — every one must contain a banned word', () {
    // An entry with no banned word can never match: residue, not policy.
    final all = {..._permitted, ..._permittedInFile.values.expand((e) => e)};
    final dead = all.where((e) => !_banned.hasMatch(e)).toList();
    expect(
      dead,
      isEmpty,
      reason:
          'These allowlist entries contain no "server"/"gateway", so they '
          'exempt nothing and are almost certainly rename residue. Delete '
          'them:\n${dead.join('\n')}',
    );
  });

  test('no allowlist entry is an ORPHAN — every one must occur in lib/', () {
    // An exemption whose justification has left the codebase stays valid
    // forever and is reread by nobody.
    final corpus = _dartFiles(['lib']).map((f) => f.readAsStringSync()).join();
    final all = {..._permitted, ..._permittedInFile.values.expand((e) => e)};
    final orphans = all.where((e) => !corpus.contains(e)).toList();
    expect(
      orphans,
      isEmpty,
      reason:
          'These allowlist entries no longer appear anywhere under lib/, so '
          'the exemption has outlived its reason. Delete them:\n'
          '${orphans.join('\n')}',
    );
  });

  test('no IDENTIFIER under lib/ says "server", and "gateway" only names the '
      'bridge service', () {
    // Identifier-level twin of the string rule above — where a rename actually
    // goes wrong.
    final ident = RegExp(r'[A-Za-z_][A-Za-z0-9_]*');
    final offenders = <String>[];

    for (final file in _dartFiles(['lib', 'test'])) {
      final lines = file.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final trimmed = line.trimLeft();
        if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;
        // Strip string literals first: their CONTENTS are prose, policed by the
        // string test above, and leaving them in makes this guard double-report
        // every finding that one already owns. An identifier check must look at
        // identifiers.
        final code = line
            .replaceAll(_literal, '""')
            .replaceAll(RegExp(r'//.*'), '');
        for (final m in ident.allMatches(code)) {
          final name = m.group(0)!;
          if (_permittedIdentifiers.containsKey(name)) continue;
          // Match the identifier's own camelCase/snake components: a substring
          // flags `observer`, a word boundary misses a token inside a name.
          final words = name
              .split('_')
              .expand((part) => part.split(RegExp(r'(?=[A-Z])')))
              .map((w) => w.toLowerCase())
              .where((w) => w.isNotEmpty);
          if (words.any((w) => w == 'server' || w == 'servers')) {
            offenders.add('${file.path}:${i + 1}  $name  (says "server")');
          } else if (words.any((w) => w == 'gateway' || w == 'gateways')) {
            offenders.add('${file.path}:${i + 1}  $name  (says "gateway")');
          }
        }
      }
    }

    expect(
      offenders.toSet().toList()..sort(),
      isEmpty,
      reason:
          'Identifiers must follow ADR-0001 too. "server" is banned outright; '
          '"gateway" is allowed only for the bridge service the client speaks '
          'to, and each such name is listed in _permittedIdentifiers with its '
          'reason.\n\n${(offenders.toSet().toList()..sort()).join('\n')}',
    );
  });
}
