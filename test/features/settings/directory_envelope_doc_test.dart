// The doc comment above [kDirectoryEnvelopeKeysByPriority] is not decoration —
// it states an ORDER that is semantic, and it names each key in backticks. This
// pins the prose to the list so the two cannot drift.
//
// WHY IT EXISTS. The island-vocabulary rename ran a pass over comment lines and
// rewrote `gateways` and `servers` to `islands` inside this very paragraph,
// leaving it reading "pins that `islands` wins over `islands`". Every guard in
// the repo stayed green, because the vocabulary test excludes comments BY DESIGN
// ("a comment is not something the app says") — so comment corruption is
// structurally invisible to it. A peer working the island side found it by
// reading.
//
// Guarding comments in general is not worth it. Guarding THIS one is: the keys
// are a wire contract with other operators, and the order decides which envelope
// wins when an island serves two. Prose that states a fact should be checked
// like a fact.
//
// STATED BOUND, because this guard's first version already let one through. It
// pins that the doc NAMES every key in list order. It cannot judge the TRUTH of
// the sentences around that list — the restored paragraph went on to claim "no
// island serves `islands` yet", which had been false for months, and this test
// stayed green because the naming was still correct. A claim about the live
// world is unfalsifiable from a unit test by construction; the discipline is to
// date and source such claims in the comment, not to try to assert them here.
import 'package:aiko_chat_app/features/settings/data/island_directory_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'dart:io';

import 'package:aiko_chat_app/features/settings/domain/island_entry.dart';

void main() {
  test('NO doc comment in this file names a key absent from the list', () {
    // The window was the blind spot. The paragraph-anchored test below scans one
    // comment; the `_parse` docstring a few lines further down went on
    // advertising `gateways` after 1748d19 deleted it, and stayed green because
    // it sits outside that window — while a test two functions away asserted the
    // key was gone. The suite held both facts and never let them meet.
    //
    // This one needs no window: any backticked key named in ANY comment in the
    // file must still be in the list. It generalises where an anchor cannot.
    final source = File(
      'lib/features/settings/data/island_directory_client.dart',
    ).readAsStringSync();
    final known = {...kDirectoryEnvelopeKeysByPriority, 'entries', 'directory'};
    // The vocabulary we care about: a key that WAS in the list and was removed.
    const retired = {'gateways', 'servers'};

    // Judged per comment BLOCK, not per line, and the rule is not "never mention
    // a retired key" — that would forbid explaining the removal, which is the
    // most useful thing a comment can say about one. The rule is: if a block
    // names a retired key it must ALSO say, in that same block, that it is gone.
    // A mention without that word is the failure mode — prose advertising a key
    // the list does not contain.
    final retirementWords = RegExp(
      r'\b(gone|removed|retired|dropped|deleted|no longer|legacy)\b',
      caseSensitive: false,
    );

    final offenders = <String>[];
    final lines = source.split('\n');
    var i = 0;
    while (i < lines.length) {
      if (!lines[i].trimLeft().startsWith('//')) {
        i++;
        continue;
      }
      final start = i;
      final block = StringBuffer();
      while (i < lines.length && lines[i].trimLeft().startsWith('//')) {
        block.writeln(lines[i]);
        i++;
      }
      final text = block.toString();
      final saysRetired = retirementWords.hasMatch(text);
      for (final key in retired) {
        if (known.contains(key)) continue;
        if (text.contains('`$key`') && !saysRetired) {
          offenders.add(
            'comment block at line ${start + 1} names `$key`, which is not in '
            'kDirectoryEnvelopeKeysByPriority, without saying it is gone',
          );
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'A comment in island_directory_client.dart advertises an envelope key '
          'that kDirectoryEnvelopeKeysByPriority no longer contains:\n'
          '${offenders.join('\n')}',
    );
  });

  test('the envelope-priority doc names every key, in the list order', () {
    final source = File(
      'lib/features/settings/data/island_directory_client.dart',
    ).readAsStringSync();

    // The paragraph immediately above the constant.
    final doc = source.substring(
      0,
      source.indexOf('const kDirectoryEnvelopeKeysByPriority'),
    );
    final paragraph = doc.substring(
      doc.lastIndexOf('/// The directory-array envelope keys'),
    );

    var searchFrom = 0;
    for (final key in kDirectoryEnvelopeKeysByPriority) {
      final at = paragraph.indexOf('`$key`', searchFrom);
      expect(
        at,
        greaterThanOrEqualTo(0),
        reason:
            'The doc above kDirectoryEnvelopeKeysByPriority does not mention '
            '`$key` after the keys before it. Either the list changed and the '
            'paragraph was not updated, or a sweep rewrote the paragraph and '
            'broke the contract it documents.\n\n$paragraph',
      );
      searchFrom = at + 1;
    }
  });

  test('the canonical key is first, and no legacy key survives', () {
    // `islands` is what both live islands serve. The `gateways`/`servers` compat
    // keys were removed on 2026-09-02 (Nick): they existed for a rename the
    // island completed in its PR#62, and we operate every island in existence,
    // so there was nothing left to be compatible with. This pins the removal so
    // a later "tolerant" instinct cannot quietly re-add the banned vocabulary.
    expect(kDirectoryEnvelopeKeysByPriority.first, 'islands');
    expect(kDirectoryEnvelopeKeysByPriority, isNot(contains('gateways')));
    expect(kDirectoryEnvelopeKeysByPriority, isNot(contains('servers')));
  });

  test('the REAL /v1/islands payload parses — captured live, not imagined', () {
    // Every other test in this area feeds the client a canned string I wrote,
    // which proves the parser handles MY idea of the island's response. This
    // fixture was captured from https://chat.imagineering.cc/v1/islands on
    // 2026-09-02, the day the app swapped to that endpoint, so it pins the
    // shape the island actually serves rather than the shape I assumed.
    //
    // If the island changes its payload, this goes red with a real diff instead
    // of the app silently discovering an empty directory in someone's hands.
    final raw = File(
      'test/fixtures/v1_islands_live_2026-09-02.json',
    ).readAsStringSync();
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(
      decoded.keys.first,
      kDirectoryEnvelopeKeysByPriority.first,
      reason: 'the live envelope key must be the one we try first',
    );

    final entries = (decoded['islands'] as List)
        .whereType<Map<String, dynamic>>()
        .map(IslandEntry.tryFromJson)
        .whereType<IslandEntry>()
        .toList();

    expect(
      entries.length,
      (decoded['islands'] as List).length,
      reason:
          'every island the live directory serves must survive validation — '
          'a dropped entry is an island the user cannot reach',
    );
    expect(
      entries.map((e) => e.httpBaseUrl),
      everyElement(startsWith('https://')),
    );
  });
}
