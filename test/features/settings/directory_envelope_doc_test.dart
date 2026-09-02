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
import 'dart:io';

void main() {
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

  test('the keys the island actually serves are still accepted, in the '
      'documented order', () {
    // `islands` is what both live islands serve today; `gateways` is the
    // deprecated alias they still answer. Both must stay accepted, and
    // `islands` must win when an island serves both during its compat window.
    expect(kDirectoryEnvelopeKeysByPriority.first, 'islands');
    expect(kDirectoryEnvelopeKeysByPriority, contains('gateways'));
    expect(
      kDirectoryEnvelopeKeysByPriority.indexOf('islands'),
      lessThan(kDirectoryEnvelopeKeysByPriority.indexOf('gateways')),
    );
  });
}
