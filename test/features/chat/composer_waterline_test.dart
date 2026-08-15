// The composer's visual contract (S3 "Seal", chosen by Nick from the composer
// study). The look is his call; these lock the parts that are mine — that the
// states are consistent, that the control never leaves the accessibility tree,
// and that the field really has no container.
//
// Three states carry the whole design:
//   rest    — hairline waterline, dim seal, dim lamp
//   focused — the waterline ignites in `colorScheme.primary`
//   armed   — seal AND lamp light together (one fact, two readings)
import 'package:aiko_chat_app/app/theme/maritime_theme.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

/// Composite [fg] (which may be translucent) over an opaque [bg].
Color _over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

/// WCAG relative-luminance contrast ratio between two OPAQUE colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  const channels = [
    Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
  ];

  Future<ColorScheme> pumpComposer(WidgetTester tester) async {
    final container =
        makeContainer(rest: FakeRestApi(channels: channels), transport: FakeChatTransport());
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    return Theme.of(tester.element(find.byType(TextField).first)).colorScheme;
  }

  Color? sealColour(WidgetTester tester) =>
      tester.widget<Icon>(find.byIcon(Icons.verified_outlined)).color;

  Color? lampColour(WidgetTester tester) => tester
      .widget<IconButton>(find.descendant(
        of: find.byKey(const Key('composer-send')),
        matching: find.byType(IconButton),
      ))
      .color;

  testWidgets('the seal and the lamp arm TOGETHER, and disarm together',
      (tester) async {
    final scheme = await pumpComposer(tester);

    // At rest both are dim, and they agree — literally the same ink, so the two
    // marks bracketing the line read as one resting state rather than two greys.
    expect(sealColour(tester), scheme.outlineVariant);
    expect(lampColour(tester), scheme.outlineVariant);

    await tester.enterText(find.byType(TextField).first, 'hello');
    await tester.pumpAndSettle();

    // Armed: the seal takes `primary` (the app's existing "verified signature"
    // colour) and the lamp takes `secondary` (beacon amber). Two readings of one
    // fact — "there is a message here to sign and send".
    expect(sealColour(tester), scheme.primary);
    expect(lampColour(tester), scheme.secondary);

    // Whitespace is not a message: `_send` trims, so the lights must too, or the
    // lamp would invite a tap that does nothing.
    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.pumpAndSettle();
    expect(sealColour(tester), scheme.outlineVariant);
    expect(lampColour(tester), scheme.outlineVariant);
  });

  testWidgets('arming INCREASES the lamp\'s contrast — in every theme',
      (tester) async {
    // The invariant, stated so it cannot silently invert again. The first cut
    // read `onSurfaceVariant` → `secondary`, which is dim → amber in maritime
    // but dark-charcoal → LIGHTER-purple in the light theme: the lamp went out
    // when armed. Asserting exact colours would not have caught that, because
    // both were "the right token" — what was wrong was the RELATIONSHIP.
    //
    // So: composite each state over the surface it is drawn on and require the
    // armed state to stand out more. True regardless of which way round the
    // theme's luminance runs.
    for (final theme in [lightTheme(), maritimeTheme()]) {
      final scheme = theme.colorScheme;
      final rest = _over(scheme.outlineVariant, scheme.surface);
      final armed = _over(scheme.secondary, scheme.surface);

      final restContrast = _contrast(rest, scheme.surface);
      final armedContrast = _contrast(armed, scheme.surface);

      expect(armedContrast, greaterThan(restContrast),
          reason: 'armed must be MORE present than rest '
              '(rest ${restContrast.toStringAsFixed(2)}:1, '
              'armed ${armedContrast.toStringAsFixed(2)}:1)');
      // The floor belongs on ARMED, not on rest. An earlier version guarded the
      // resting state on the theory that an enabled control must always be
      // visible — but rest is precisely the state where there is nothing to
      // send, and the return key sends anyway. The moment there IS something,
      // the lamp has to be findable, so that is where the bar goes: WCAG 1.4.11
      // for a non-text UI component.
      expect(armedContrast, greaterThanOrEqualTo(3.0),
          reason: 'the ARMED lamp is the state that must be found '
              '(${armedContrast.toStringAsFixed(2)}:1)');
    }
  });

  testWidgets('the send control stays ENABLED when empty — colour is a hint, '
      'not a gate', (tester) async {
    await pumpComposer(tester);

    final button = tester.widget<IconButton>(find.descendant(
      of: find.byKey(const Key('composer-send')),
      matching: find.byType(IconButton),
    ));
    // Disabling on empty would drop the control out of the accessibility tree
    // between keystrokes, which is worse than a no-op tap. `_send` already
    // returns early on an empty body.
    expect(button.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the field has NO container — the waterline is the only edge',
      (tester) async {
    await pumpComposer(tester);

    final field = tester.widget<TextField>(find.byType(TextField).first);
    final d = field.decoration!;
    // The theme supplies a filled, outlined input by default; the composer opts
    // out of all of it. This is the theme's own stated law ("separation is by
    // hairline, no elevation") applied to the last component that ignored it —
    // so if someone reinstates a border here, that is the regression.
    expect(d.border, InputBorder.none);
    expect(d.enabledBorder, InputBorder.none);
    expect(d.focusedBorder, InputBorder.none);
    expect(d.filled, isFalse);
    expect(d.hintText, 'Write a message…');
  });

  testWidgets('the waterline ignites on focus and goes out on blur',
      (tester) async {
    await pumpComposer(tester);
    double factor() => tester
        .widget<AnimatedFractionallySizedBox>(
            find.byType(AnimatedFractionallySizedBox))
        .widthFactor!;

    // The lit rule grows over the base hairline from the left. Written as a
    // test because the on-device read was ambiguous: in LIGHT mode
    // `colorScheme.primary` is the undesigned deepPurple, which at 1.5px reads
    // as grey, so a screenshot could not tell "not lit" from "lit, but muted".
    // The widthFactor can.
    expect(factor(), 0.0);

    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(factor(), 1.0);

    // And it must go out — a rule that stays lit after blur is just a border,
    // which is the thing this design removed.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(factor(), 0.0);
  });
}
