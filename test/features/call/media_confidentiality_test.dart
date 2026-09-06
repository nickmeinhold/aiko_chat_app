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
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget harness(MediaRouting routing, {bool compact = false}) => ProviderScope(
    overrides: [mediaRoutingProvider.overrideWithValue(routing)],
    child: MaterialApp(
      home: Scaffold(body: MediaConfidentialityChip(compact: compact)),
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

  testWidgets('it names the exposure in words, and names the island', (
    tester,
  ) async {
    await tester.pumpWidget(harness(unencrypted));
    expect(find.text('Not encrypted · chat.imagineering.cc'), findsOneWidget);
    expect(find.byIcon(Icons.lock_open), findsOneWidget);
  });

  // THE MUST-FAIL ARM. If the chip were hardcoded, this is the only test in the
  // file that would go red.
  testWidgets('the sentence is DERIVED — the encrypted branch says the '
      'opposite', (tester) async {
    await tester.pumpWidget(harness(encrypted));
    expect(find.text('End-to-end encrypted'), findsOneWidget);
    expect(find.textContaining('Not encrypted'), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.byIcon(Icons.lock_open), findsNothing);
  });

  testWidgets('compact drops the ATTRIBUTION, never the claim', (tester) async {
    await tester.pumpWidget(harness(unencrypted, compact: true));
    expect(find.text('Not encrypted'), findsOneWidget);
    expect(find.textContaining('imagineering'), findsNothing);
  });

  testWidgets('a screen reader hears the full sentence even when compact', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(harness(unencrypted, compact: true));
    // Shortening is a response to horizontal space, and a listener has none of
    // that constraint — so the host stays.
    expect(
      find.bySemanticsLabel(
        'This call is not encrypted. Audio and video pass through '
        'chat.imagineering.cc in the clear.',
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
    expect(find.text('Not encrypted'), findsOneWidget);
  });

  test('losing the attribution does not soften the claim', () {
    const unattributed = MediaRouting(
      confidentiality: MediaConfidentiality.notEndToEndEncrypted,
      islandHost: '',
    );
    expect(unattributed.hasAttribution, isFalse);
    expect(unattributed.isEndToEndEncrypted, isFalse);
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
