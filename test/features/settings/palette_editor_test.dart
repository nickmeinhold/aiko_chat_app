// The editor's central claim: it does not let you make the app unreadable.
//
// Everything else about custom colour is a preference surface. THIS is the part
// that has to hold, because it is the first time someone other than us authors
// a palette — and the guarantee "the builder owns relationships" only survives
// contact with a real person if the control they are handed cannot reach an
// illegal state in the first place.
//
// RED-PROVE: delete the `blockedBy` computation in `_SwatchGrid` (so every
// swatch becomes tappable) and "an illegal colour cannot be committed" goes
// green-to-red.
import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/app/theme/theme_laws.dart';
import 'package:aiko_chat_app/features/settings/application/theme_preset_controller.dart';
import 'package:aiko_chat_app/features/settings/presentation/palette_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _pumpEditor(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: PaletteEditorScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  // A tap that MISSES its target normally prints a warning and lets the test
  // carry on — which is how the smoke test below first "passed": its swatch sat
  // at y=670 in a 600px viewport, the tap hit nothing, and the assertion that
  // the palette was still lawful was true of a palette nobody had changed. A
  // vacuous green is worse than a red. Make the miss fatal.
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('the constraint is VISIBLE — some colours are offered and some '
      'are refused, with a reason', (tester) async {
    await _pumpEditor(tester);

    expect(find.bySemanticsLabel(RegExp('^Use this colour')), findsWidgets,
        reason: 'an editor that offers nothing is not an editor');
    expect(find.bySemanticsLabel(RegExp('^Unavailable')), findsWidgets,
        reason: 'the default role is the signal colour on a light ground — '
            'pale swatches MUST be refused, or the law is not being consulted');
  });

  testWidgets('an illegal colour cannot be committed', (tester) async {
    final container = await _pumpEditor(tester);
    final before = container.read(skinSelectionProvider);

    // Scroll it into view FIRST. Without this the swatch can sit below the
    // viewport, the tap misses for a boring reason, and "nothing was committed"
    // becomes true of a button nobody could have pressed — the test would pass
    // even if the swatch were fully enabled.
    final refused = find.bySemanticsLabel(RegExp('^Unavailable')).first;
    await tester.ensureVisible(refused);
    await tester.pumpAndSettle();

    await tester.tap(
      refused,
      // A refused swatch is deliberately not hit-testable; that IS the claim,
      // so the miss here is the pass condition rather than a defect.
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(container.read(skinSelectionProvider).isCustomised, isFalse,
        reason: 'tapping a refused swatch must not record an override');
    expect(container.read(skinSelectionProvider).lightOverrides,
        before.lightOverrides);
  });

  testWidgets('a legal colour CAN be committed, and lands in the live theme',
      (tester) async {
    final container = await _pumpEditor(tester);

    await tester.tap(find.bySemanticsLabel(RegExp('^Use this colour')).first);
    await tester.pumpAndSettle();

    final selection = container.read(skinSelectionProvider);
    expect(selection.isCustomised, isTrue);

    // And the committed palette is still lawful — the property the whole
    // feature rests on, asserted on the RESOLVED theme rather than on the
    // swatch that was tapped.
    expect(checkPalette(container.read(themePresetProvider).light), isEmpty);
    expect(checkPalette(container.read(themePresetProvider).dark), isEmpty);
  });

  testWidgets('whatever you do to it, the resulting theme stays lawful — '
      'a smoke test over MANY commits, not one', (tester) async {
    final container = await _pumpEditor(tester);

    // Commit a legal colour for several different roles in turn, re-reading
    // the offered set each time (the offers change as the palette changes).
    // The role strip is a horizontal list inside a 560px reading column, so
    // only the leading roles are built. Those are the ground and the panels —
    // which happen to be the roles that constrain the MOST other rules, so they
    // are the right ones to hammer anyway: changing the ground can invalidate
    // the ink, the hairline and every accent at once.
    for (final role in [
      PaletteRole.ground,
      PaletteRole.panel,
      PaletteRole.panelHigh,
    ]) {
      // Committing a colour scrolls the page down to the swatch that was
      // tapped, carrying the role strip off the top. Return the page to the TOP
      // rather than scrolling the chip just barely into view: stopping at the
      // first visible pixel parks it under the app bar, where it is findable but
      // cannot receive a tap — a failure that reads as "missing widget".
      await tester.drag(
        find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .first,
        const Offset(0, 3000),
      );
      await tester.pumpAndSettle();

      final chip = find.bySemanticsLabel(RegExp('^${role.label},'));
      expect(chip, findsWidgets, reason: '${role.label} chip not on screen');
      await tester.tap(chip.first);
      await tester.pumpAndSettle();

      final offers = find.bySemanticsLabel(RegExp('^Use this colour'));
      if (offers.evaluate().isEmpty) continue;
      await tester.ensureVisible(offers.first);
      await tester.pumpAndSettle();
      await tester.tap(offers.first);
      await tester.pumpAndSettle();

      // Prove the commit ACTUALLY happened before asserting anything about the
      // result — otherwise a tap that lands on nothing makes every assertion
      // below true of a palette that was never edited.
      expect(container.read(skinSelectionProvider).lightOverrides,
          contains(role),
          reason: 'the tap on a ${role.label} swatch did not commit');

      expect(checkPalette(container.read(themePresetProvider).light), isEmpty,
          reason: 'after editing ${role.name} the light palette broke');
      expect(checkPalette(container.read(themePresetProvider).dark), isEmpty,
          reason: 'editing the light half must not disturb the dark one');
    }
  });

  testWidgets('Reset appears only once something is customised, and clears it',
      (tester) async {
    final container = await _pumpEditor(tester);
    expect(find.text('Reset'), findsNothing,
        reason: 'nothing to reset yet — an always-present Reset is noise');

    await tester.tap(find.bySemanticsLabel(RegExp('^Use this colour')).first);
    await tester.pumpAndSettle();
    expect(find.text('Reset'), findsOneWidget);

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();

    final s = container.read(skinSelectionProvider);
    expect(s.isCustomised, isFalse,
        reason: 'a reset that leaves a stale override behind is the classic '
            'half-reset bug');
    expect(s.lightOverrides, isEmpty);
    expect(s.darkOverrides, isEmpty);
  });
}
