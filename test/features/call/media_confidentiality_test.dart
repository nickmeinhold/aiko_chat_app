// The disclosure Nick ruled on: "the user should always know if their call is
// going to go through an island unencrypted." (2026-08-31; island design 13,
// Decision 9d.)
//
// The load-bearing test here is the one for a state that DOES NOT SHIP.
// `MediaConfidentiality.endToEndEncrypted` is unreachable in production — the
// resolver cannot return it — so without an override the chip would be a
// constant wearing a widget, and every assertion about it would pass whether or
// not it read anything at all. Asserting the positive branch is what makes the
// negative assertions mean something: it proves the sentence is DERIVED.
import 'package:aiko_chat_app/features/call/domain/media_confidentiality.dart';
import 'package:aiko_chat_app/features/call/presentation/media_confidentiality_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget harness(MediaRouting routing) => ProviderScope(
    overrides: [mediaRoutingProvider.overrideWithValue(routing)],
    child: const MaterialApp(
      home: Scaffold(body: MediaConfidentialityChip()),
    ),
  );

  const unencrypted = MediaRouting(
    confidentiality: MediaConfidentiality.notEndToEndEncrypted,
    islandHost: 'chat.imagineering.cc',
  );
  const encrypted = MediaRouting(
    confidentiality: MediaConfidentiality.endToEndEncrypted,
    islandHost: 'chat.imagineering.cc',
  );

  // THE CLAIM IS TIED TO THE FACT IT RESTS ON.
  //
  // `resolveMediaConfidentiality` returns a hardcoded negative, and that is only
  // TRUE because this app never enables LiveKit's insertable-streams E2EE. Those
  // two facts live in different files with nothing linking them, so the day
  // someone switches media E2EE on, the disclosure would go on confidently
  // telling users their encrypted call is unencrypted — wrong in the safe
  // direction, but wrong, and silently.
  //
  // This is the link. It goes red the moment the premise changes, which is
  // exactly when a human needs to be told to revisit the resolver.
  test('the hardcoded negative still matches reality: no media E2EE in lib/', () {
    final offenders = <String>[];
    final pattern = RegExp(r'\b(e2eeOptions|E2EEOptions|frameCryptor|keyProvider)\b');
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      for (final line in f.readAsLinesSync()) {
        final code = line.trim();
        // This feature's own comments discuss the ABSENCE of these constantly;
        // only real code counts as enabling it.
        if (code.startsWith('//')) continue;
        if (pattern.hasMatch(code)) offenders.add('\${f.path}: \$code');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'media E2EE looks wired up now, so the disclosure is LYING — '
          '`resolveMediaConfidentiality` still returns a hardcoded '
          'notEndToEndEncrypted. Make it read the real state before you delete '
          'this test.\n\${offenders.join("\n")}',
    );
  });

  group('fail closed', () {
    test('the resolver answers NEGATIVE, and not "unknown"', () {
      // Forced relay + an SFU + no e2eeOptions. This is not an absence of
      // information; it is information. If this ever flips, it must flip
      // because something verified said so.
      expect(
        resolveMediaConfidentiality(),
        MediaConfidentiality.notEndToEndEncrypted,
      );
    });

    test('there is no third state to render', () {
      // A guard on the enum itself: adding `unknown` would let a widget draw a
      // shrug where a warning belongs, which is precisely the failure
      // fail-closed exists to prevent. Grow the enum only with a positive,
      // verified state.
      expect(MediaConfidentiality.values, hasLength(2));
    });
  });

  group('attribution is not an open string', () {
    // Carnot, round 2: `''` was a sentinel in an open type, so "empty",
    // "whitespace" and "not resolved yet" were the same value — and a
    // whitespace host would have rendered as a real attribution, printing
    // "Not end-to-end encrypted · " at the user.
    test('null means unattributed', () {
      const r = MediaRouting(
        confidentiality: MediaConfidentiality.notEndToEndEncrypted,
      );
      expect(r.hasAttribution, isFalse);
      expect(r.label, 'Not end-to-end encrypted');
    });

    test('whitespace is not an attribution', () {
      const r = MediaRouting(
        confidentiality: MediaConfidentiality.notEndToEndEncrypted,
        islandHost: '   ',
      );
      expect(r.hasAttribution, isFalse);
      expect(r.label, 'Not end-to-end encrypted');
      expect(r.sentence, isNot(contains('  can hear')));
    });
  });

  // DEGRADATION ORDER (Carnot, round 3, non-blocking). The chip is one line with
  // an ellipsis, so a very long host can truncate it. That is SAFE only because
  // the claim is the PREFIX and the attribution the suffix — ellipsis eats the
  // attribution first and the warning survives. That ordering is currently a
  // property of how the string happens to be built, which is exactly the kind of
  // accident that gets reversed by a well-meaning edit ("put the island first,
  // it reads better"). Pinned, so the reversal is loud.
  test('the claim is the PREFIX, so truncation eats the attribution first', () {
    const longHost = MediaRouting(
      confidentiality: MediaConfidentiality.notEndToEndEncrypted,
      islandHost: 'an-extremely-long-island-hostname.example.org',
    );
    expect(longHost.label, startsWith('Not end-to-end encrypted'));
    expect(
      longHost.label.indexOf('Not end-to-end encrypted'),
      lessThan(longHost.label.indexOf('an-extremely-long')),
      reason:
          'if the island name ever moves in front of the claim, truncation '
          'starts eating the warning instead of the attribution',
    );
  });

  // DRIFT GUARD. The sentence now renders on TWO surfaces — this chip and the
  // Call entry's subtitle. Two controls describing one fact differently is how
  // a disclosure becomes a lie on whichever one you did not look at, so both
  // read [MediaRouting] and this pins that they agree on the claim.
  test('the chip label and the spoken sentence make the same claim', () {
    expect(unencrypted.label, contains('Not end-to-end encrypted'));
    expect(unencrypted.sentence, contains('not end to end encrypted'));
    expect(unencrypted.label, contains('chat.imagineering.cc'));
    expect(unencrypted.sentence, contains('chat.imagineering.cc'));

    const enc = MediaRouting(
      confidentiality: MediaConfidentiality.endToEndEncrypted,
    );
    expect(enc.label, isNot(contains('Not')));
    expect(enc.sentence, isNot(contains('not end to end')));
  });

  testWidgets('it names the exposure in words, and names the island', (
    tester,
  ) async {
    await tester.pumpWidget(harness(unencrypted));
    expect(
      find.text('Not end-to-end encrypted · chat.imagineering.cc'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.lock_open), findsOneWidget);
  });

  // THE MUST-FAIL ARM. If the chip were hardcoded, this is the only test in the
  // file that would go red.
  testWidgets('the sentence is DERIVED — the encrypted branch says the '
      'opposite', (tester) async {
    await tester.pumpWidget(harness(encrypted));
    expect(find.text('End-to-end encrypted'), findsOneWidget);
    expect(find.textContaining('Not end-to-end'), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.byIcon(Icons.lock_open), findsNothing);
  });

  testWidgets('a screen reader hears the whole sentence, not the chip text', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(harness(unencrypted));
    // The spoken sentence says WHO CAN HEAR YOU, which the eight-word chip
    // cannot. A listener has no horizontal constraint, so it gets the full
    // thing rather than the label read aloud.
    expect(
      find.bySemanticsLabel(
        'This call is not end to end encrypted. chat.imagineering.cc can hear '
        'and see it.',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  // REGRESSION. The first version read `configProvider` unguarded, so mounting
  // the chip without SharedPreferences threw `ProviderException` and took the
  // whole ring banner down with it — a fail-closed feature failing OPEN at the
  // first missing dependency. Found by `call_gating_test`, which was not
  // testing this and had no reason to.
  //
  // No overrides at all here, deliberately: this is the bare condition that
  // crashed.
  testWidgets('with NO config at all it still warns, unattributed', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: MediaConfidentialityChip()),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    // The claim survives; only the name of the island is missing.
    expect(find.text('Not end-to-end encrypted'), findsOneWidget);
  });

  test('losing the attribution does not soften the claim', () {
    const unattributed = MediaRouting(
      confidentiality: MediaConfidentiality.notEndToEndEncrypted,
      islandHost: '',
    );
    expect(unattributed.hasAttribution, isFalse);
    expect(unattributed.isEndToEndEncrypted, isFalse);
  });

  // Carnot's catch, cage-match round 1. The media IS encrypted on the wire —
  // WebRTC mandates DTLS-SRTP — and is decrypted AT the island. So the bare
  // "Not encrypted" was the rhetorically stronger sentence and the technically
  // FALSE one. A disclosure that overstates is still a disclosure that lies,
  // which is the exact failure this feature exists to prevent.
  testWidgets('the claim does not overstate: end-to-end, never bare "not '
      'encrypted"', (tester) async {
    await tester.pumpWidget(harness(unencrypted));
    final label = tester.widget<Text>(find.byType(Text).first).data!;
    expect(label, contains('end-to-end'));
    // The failure this pins: a label that drops the qualifier and claims more
    // than is true.
    expect(RegExp(r'^Not encrypted\b').hasMatch(label), isFalse);
  });

  test('the island is named by the host, never by the manifest display name',
      () {
    // A disclosure must not let its subject choose the words describing it: an
    // island calling itself "Secure Private Chat" would otherwise print that
    // inside the warning about it. The host is the one identifier in the
    // sentence the user supplied. See the domain header on claude-tasks#3730 —
    // the existing manifest cache is unverified BY DESIGN and must not be the
    // trust root for this.
    const routing = MediaRouting(
      confidentiality: MediaConfidentiality.notEndToEndEncrypted,
      islandHost: 'island.example',
    );
    expect(routing.islandHost, 'island.example');
    expect(routing.isEndToEndEncrypted, isFalse);
  });
}
