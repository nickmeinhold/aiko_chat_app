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
  // Wire: the island's own directory endpoint and its JSON field names. The
  // island repo owns this shape; we do not rename it unilaterally.
  r'$base/v1/gateways',
  'gateways',
  'servers',
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
        if (_permitted.contains(value)) continue;
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
    final dead = _permitted.where((e) => !_banned.hasMatch(e)).toList();
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
    final orphans = _permitted.where((e) => !corpus.contains(e)).toList();
    expect(
      orphans,
      isEmpty,
      reason:
          'These allowlist entries no longer appear anywhere under lib/, so '
          'the exemption has outlived its reason. Delete them:\n'
          '${orphans.join('\n')}',
    );
  });
}
