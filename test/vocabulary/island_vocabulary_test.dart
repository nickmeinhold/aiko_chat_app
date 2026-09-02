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
// prose is re-broken by the next person writing a snackbar at speed.
//
// HOW IT WORKS. Every Dart string literal under `lib/` is checked — single-line
// and triple-quoted, with comment lines skipped, because a comment is not
// something the app says. Anything containing "server" or "gateway" must appear
// verbatim in [_permitted], which holds only strings the USER NEVER SEES.
//
// THE ALLOWLIST IS ITSELF GUARDED, which is the lesson of this file's own
// cage-match. Two reviewers attacked it independently and both were right: the
// corpus-wide rename edited the allowlist along with the code, so an entry
// hollowed out silently (`r'server=$serverUlid'` became `r'server=$islandUlid'`
// and went on matching, keeping the suite green by tracking the very thing it
// polices), and thirteen more entries stopped containing a banned word at all.
// An allowlist is authoritative state that drifts exactly like the code it
// polices, so it gets the same treatment: the meta-tests below fail on a DEAD
// entry (no banned word — it can never match, so it is residue wearing policy's
// clothes) and on an ORPHAN entry (no occurrence in the corpus — the exemption
// outlived its reason).
//
// If this test fails on a string a person reads, the fix is the word, not the
// allowlist.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Literals that legitimately carry "server"/"gateway" because the user never
/// reads them.
///
/// COVERAGE BOUNDARY, learned from the DEAD meta-test on its first run.
/// [_banned] is word-boundary anchored, so a SNAKE_CASE token carrying the word
/// does not match: in `server_ulid` the word is followed by `_`, itself a word
/// character, so there is no boundary. `server_ulid`, `aiko_gateway_base_url`
/// and `aiko_known_gateways` sat here exempting a match that could never happen
/// — and their presence made that silence look deliberate rather than
/// unexamined. They are gone. The boundary is correct on purpose (this guard
/// hunts user-facing PROSE, and a snake_case token is never prose), but it is a
/// boundary, and it is now written down instead of hidden behind exemptions.
const _permitted = <String>{
  // A developer `assert` about the gateway service's own REST contract (is
  // `after` exclusive?). Aimed at us, and "gateway" is the CORRECT word — the
  // cursor belongs to the bridge service, not to the island.
  '— is the gateway `after` cursor exclusive?',
};

/// Exemptions SCOPED TO A FILE. Carnot's catch: a bare `'servers'` on the global
/// allowlist exempts that word ANYWHERE, so a future user-facing `Text('servers')`
/// would sail through the very policy that exists to stop it. These are the
/// island directory's own wire field names, and they are legitimate in exactly
/// one file.
const _permittedInFile = <String, Set<String>>{};

/// Identifiers that may carry "gateway" because they NAME THE BRIDGE SERVICE
/// the client speaks to — ADR-0001's Gateway, not its Island — plus the legacy
/// storage-key constants, which are strings-as-names and cannot move.
/// Identifiers exempt from the vocabulary rule, EACH WITH ITS REASON.
///
/// THERE ARE THREE MEANINGS, and until 2026-09-02 only two had a rule:
///
///   1. ISLAND  — the sovereign deployment. The user-facing word (ADR-0001).
///   2. GATEWAY — the bridge service INSIDE an island. Kept deliberately: an
///      island HAS a gateway, and the client dials it.
///   3. SERVER  — the physical or virtual HOST the thing runs on. NO RULE WAS
///      EVER WRITTEN for this one, and its absence caused a real defect.
///
/// The proof that the gap was structural rather than careless: one sweep made
/// the same call twice and split. `closeFromServer` became `closeFromGateway`
/// (correct — a close frame comes from the bridge service) while
/// `_parseServerTime` became `_parseIslandTime` (wrong — it parses a field of an
/// AckFrame, which IS a GatewayFrame). Same category, opposite bins. Neither the
/// guard nor a four-family cage-match could have caught it, because both were
/// handed the two-bin taxonomy as a premise.
///
/// The asymmetry that produced it: STRINGS could always exempt `server` with a
/// reason, but IDENTIFIERS banned it outright with no escape — so anyone needing
/// meaning 3 (`serverClockSkew`, `serverDiskFull`) had to pick island or gateway
/// by feel, and the coin lands wrong about half the time. Nick's call,
/// 2026-09-02: give identifiers the same reason-carrying escape. A name meaning
/// THE HOST is legitimate; it just has to say so here.
///
/// A bare allowlist is what let two local variables named `servers` sail through
/// for a week, so this is a map: no entry without a reason.
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

List<File> _dartFilesUnderLib() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList(growable: false);

void main() {
  test('no user-facing string says "server" or "gateway" — the app says '
      '"island" (ADR-0001)', () {
    final offenders = <String>[];

    for (final entity in _dartFilesUnderLib()) {
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
      final hits = _dartFilesUnderLib()
          .where((f) => f.readAsStringSync().contains('/settings/gateway'))
          .map((f) => f.path)
          .toList();
      expect(hits, isEmpty);
    },
  );

  test('no allowlist entry is DEAD — every one must contain a banned word', () {
    // A corpus-wide rename edits this file too. An entry whose banned word was
    // renamed away can never match again: not policy, residue that LOOKS like
    // policy, and it will quietly permit any future string equal to it.
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
    // Kelvin's catch. An exemption whose justification has left the codebase is
    // an open door: valid forever, reread by nobody. Requiring a live occurrence
    // means an exemption dies with the code that earned it.
    final corpus = _dartFilesUnderLib().map((f) => f.readAsStringSync()).join();
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
    // THE FINDING THIS TEST EXISTS FOR. The 470-site rename that introduced this
    // vocabulary used a word-boundary pattern, so any identifier where the token
    // sat INSIDE a longer name was silently skipped: `serverUlidFor`,
    // `serverIdFor`, `noServerId`, `_parseServerTime`, `_GatewayPickerScreenState`,
    // `gatewaySeedStoreProvider` and five more survived, and `flutter analyze`
    // stayed green the whole time because they are internally consistent. A
    // reviewer found ONE of them by reading; this finds all of them, and stops
    // the next sweep from having the same blind spot.
    //
    // Strings are guarded above; this is the same policy one layer down, where a
    // rename actually goes wrong.
    final ident = RegExp(r'[A-Za-z_][A-Za-z0-9_]*');
    final offenders = <String>[];

    for (final file in _dartFilesUnderLib()) {
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
          // MATCH ON THE IDENTIFIER'S OWN WORDS, not a substring and not a
          // regex word boundary — both are wrong here, in opposite directions.
          // A substring flags `observer` (ob|server) as saying "server"; a `\b`
          // boundary MISSES `serverUlidFor`, which is the exact miss round 3
          // existed to catch. The unit the question is really about is the
          // camelCase/snake_case COMPONENT: `serverUlidFor` -> [server, ulid,
          // for] flags, `observer` -> [observer] does not.
          //
          // Today `observer` appears once in lib/ and only inside a comment, so
          // the substring version passed by luck of placement. The first person
          // to name a variable `observer` in real code would have hit a false
          // positive on a guard that is supposed to be trustworthy.
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
