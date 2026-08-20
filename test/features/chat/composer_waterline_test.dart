// The composer's visual contract (S3 "Seal", chosen by Nick from the composer
// study). The look is his call; these lock the parts that are mine — that the
// states are consistent, that the control never leaves the accessibility tree,
// and that the field really has no container.
//
// Three states carry the whole design:
//   rest    — hairline waterline, dim seal, dim lamp
//   focused — the waterline ignites in `colorScheme.primary`
//   armed   — seal AND lamp light together (one fact, two readings)
import 'package:aiko_chat_app/core/widgets/island_mark.dart';
import 'package:aiko_chat_app/features/chat/presentation/chat_screen.dart';
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
    final container = makeContainer(
      rest: FakeRestApi(channels: channels),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    return Theme.of(tester.element(find.byType(TextField).first)).colorScheme;
  }

  /// The island mark's painter. Comparing painters across a rebuild is how we
  /// prove the mark did NOT change: `shouldRepaint` is the widget's own answer
  /// to "is this different from what was there before".
  CustomPainter islandPainter(WidgetTester tester) => tester
      .widget<CustomPaint>(
        find.descendant(
          of: find.byType(IslandMark),
          matching: find.byType(CustomPaint),
        ),
      )
      .painter!;

  Color? lampColour(WidgetTester tester) => tester
      .widget<IconButton>(
        find.descendant(
          of: find.byKey(const Key('composer-send')),
          matching: find.byType(IconButton),
        ),
      )
      .color;

  testWidgets('the lamp arms and disarms with the message', (tester) async {
    final scheme = await pumpComposer(tester);

    // The seal that used to sit beside the lamp is gone — its slot carries the
    // island mark now, which says WHERE YOU ARE rather than restating that a
    // message will be signed. So this pins the lamp alone.
    expect(lampColour(tester), scheme.outlineVariant);

    await tester.enterText(find.byType(TextField).first, 'hello');
    await tester.pumpAndSettle();
    expect(lampColour(tester), scheme.secondary);

    // Whitespace is not a message: `_send` trims, so the lamp must too, or it
    // would invite a tap that does nothing.
    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.pumpAndSettle();
    expect(lampColour(tester), scheme.outlineVariant);
  });

  testWidgets('the island mark does NOT change while you type', (tester) async {
    await pumpComposer(tester);

    // The requirement this pins is Nick's, and it is the reason the seal was
    // replaced rather than merely re-coloured: the old mark animated on the
    // first and last keystroke, so the one thing on screen answering "where am
    // I" flickered every time you started a sentence. An identity mark that
    // moves when you type is not an identity mark.
    final before = islandPainter(tester);

    await tester.enterText(find.byType(TextField).first, 'hello');
    await tester.pumpAndSettle();
    final armed = islandPainter(tester);
    expect(
      armed.shouldRepaint(before),
      isFalse,
      reason: 'the island mark repainted when the composer armed',
    );

    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    expect(
      islandPainter(tester).shouldRepaint(armed),
      isFalse,
      reason: 'the island mark repainted when the composer disarmed',
    );
  });

  testWidgets('arming INCREASES the lamp\'s contrast — in every theme', (
    tester,
  ) async {
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

      expect(
        armedContrast,
        greaterThan(restContrast),
        reason:
            'armed must be MORE present than rest '
            '(rest ${restContrast.toStringAsFixed(2)}:1, '
            'armed ${armedContrast.toStringAsFixed(2)}:1)',
      );
      // The floor belongs on ARMED, not on rest. An earlier version guarded the
      // resting state on the theory that an enabled control must always be
      // visible — but rest is precisely the state where there is nothing to
      // send, and the return key sends anyway. The moment there IS something,
      // the lamp has to be findable, so that is where the bar goes: WCAG 1.4.11
      // for a non-text UI component.
      expect(
        armedContrast,
        greaterThanOrEqualTo(3.0),
        reason:
            'the ARMED lamp is the state that must be found '
            '(${armedContrast.toStringAsFixed(2)}:1)',
      );
    }
  });

  testWidgets('the send control stays ENABLED when empty — colour is a hint, '
      'not a gate', (tester) async {
    await pumpComposer(tester);

    final button = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const Key('composer-send')),
        matching: find.byType(IconButton),
      ),
    );
    // Disabling on empty would drop the control out of the accessibility tree
    // between keystrokes, which is worse than a no-op tap. `_send` already
    // returns early on an empty body.
    expect(button.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the field has NO container — the waterline is the only edge', (
    tester,
  ) async {
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

  testWidgets('the waterline ignites on focus and goes out on blur', (
    tester,
  ) async {
    await pumpComposer(tester);
    double factor() => tester
        .widget<AnimatedFractionallySizedBox>(
          find.byType(AnimatedFractionallySizedBox),
        )
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

  testWidgets('the lit rule occupies actual PIXELS, not just a widthFactor', (
    tester,
  ) async {
    // The test above asserts the widthFactor animates 0 → 1, which was true for
    // three PRs and a cage-match while the lit rule laid out 431px wide and 0px
    // TALL — it had never once been visible, in either theme, since it shipped.
    //
    // The near-miss is worth stating because it was reasoned, not careless: the
    // widthFactor was measured *because* an on-device screenshot could not tell
    // "not lit" from "lit but muted" back when the light theme was an
    // undesigned `ColorScheme.fromSeed`. A workaround for a blind instrument
    // became the thing that kept the defect alive. So this asserts the only
    // fact that actually matters — a human can see it.
    await pumpComposer(tester);

    final box = find.descendant(
      of: find.byType(AnimatedFractionallySizedBox),
      matching: find.byType(ColoredBox),
    );

    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();

    final size = tester.getSize(box);
    expect(
      size.height,
      greaterThan(0.0),
      reason:
          'the lit waterline has zero height — it is laid out but never '
          'painted (got $size)',
    );
    expect(size.width, greaterThan(0.0), reason: 'lit rule width (got $size)');
  });

  testWidgets('the island mark is REACHABLE without having moved anything', (
    tester,
  ) async {
    // Nick, on the phone: the mark was hard to press, then the fix (a 44x44 box)
    // pushed the composer around — "I want the padding back the way it was, but
    // the pressable area should allow for taps right up to the edge".
    //
    // Both halves are asserted here because they pull against each other: a
    // bigger target normally costs layout. The trick is that the target's
    // padding is space the composer was ALREADY drawing, moved inside the
    // gesture — so these numbers are the ORIGINAL geometry, and the tap area is
    // the thing that changed.
    await pumpComposer(tester);

    final target = tester.getRect(find.byType(IslandMark));
    final glyph = tester.getRect(
      find.descendant(
        of: find.byType(IslandMark),
        matching: find.byType(CustomPaint),
      ),
    );
    final field = tester.getRect(find.byType(TextField).first);

    final composer = tester.getRect(find.byType(Composer));

    // UNCHANGED, stated RELATIVELY so the numbers survive a sidebar or a
    // different screen width: the glyph sits in a 12px gutter, is 18px, and the
    // field starts 10px after it.
    expect(glyph.left - composer.left, 12);
    expect(glyph.width, 18);
    expect(field.left - glyph.right, 10);
    // ...and the glyph still rides its 9px above the composer's bottom padding
    // (8), so 17 from the composer's own edge. Measured against the COMPOSER
    // rather than the field: the field is stacked above the waterline, so its
    // bottom is not the row's bottom.
    expect(composer.bottom - glyph.bottom, 17);

    // CHANGED: the target starts at the composer's own edge — a press in the
    // gutter lands — and is far larger than the drawing.
    expect(
      target.left,
      composer.left,
      reason: 'a press in the left gutter must land on the mark',
    );
    expect(target.width, greaterThan(glyph.width * 2));
    expect(target.height, greaterThan(40));
  });
}
