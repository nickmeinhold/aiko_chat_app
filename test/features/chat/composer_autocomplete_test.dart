import 'package:aiko_chat_app/features/chat/presentation/chat_screen.dart';
import 'package:aiko_chat_app/features/chat/presentation/emoji_shortcodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget-interaction coverage for the inline `:shortcode` emoji autocomplete
/// (#12). The matching logic itself is unit-tested in emoji_shortcodes_test.dart;
/// these tests exercise the wired behaviour in the [Composer] widget: the panel
/// appearing, a tap replacing the token, Enter committing (not sending) while the
/// panel is open, and the picker correctly staying closed on non-matches / URLs.
///
/// The harness pumps ONLY the [Composer] — no provider overrides. `Composer`
/// reads `chatRepositoryProvider` solely inside `_send()`, so as long as no test
/// triggers an actual send the un-overridden provider is never touched; a wrongful
/// send would throw (unhandled provider), which the Enter test relies on to prove
/// Enter did NOT send.
Widget _harness() => const ProviderScope(
  child: MaterialApp(
    home: Scaffold(body: Composer(channelId: 'c1')),
  ),
);

void main() {
  testWidgets('typing ":smi" opens the suggestion panel', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.enterText(find.byType(TextField), ':smi');
    await tester.pumpAndSettle();

    // The :smile: row is present in the panel.
    expect(find.text(':smile:'), findsOneWidget);
  });

  testWidgets('tapping a suggestion inserts the emoji and removes the token', (
    tester,
  ) async {
    await tester.pumpWidget(_harness());
    await tester.enterText(find.byType(TextField), ':smi');
    await tester.pumpAndSettle();

    await tester.tap(find.text(':smile:'));
    await tester.pumpAndSettle();

    final smile = kEmojiShortcodes['smile']!;
    final field = tester.widget<TextField>(find.byType(TextField));
    final text = field.controller!.text;
    expect(text, contains(smile));
    expect(text, isNot(contains(':smi')));
  });

  testWidgets('Enter while the panel is open commits the suggestion, not a send', (
    tester,
  ) async {
    await tester.pumpWidget(_harness());
    // enterText focuses the field and puts the caret at the end.
    await tester.enterText(find.byType(TextField), ':smi');
    await tester.pumpAndSettle();
    expect(find.text(':smile:'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // The highlighted (first) suggestion was committed: an emoji is now in the
    // field and the token is gone. Crucially NO exception was thrown — a wrongful
    // send would have hit the un-overridden chatRepositoryProvider and failed the
    // test.
    final firstMatch = filterEmojiShortcodes('smi').first.value;
    final field = tester.widget<TextField>(find.byType(TextField));
    final text = field.controller!.text;
    expect(text, contains(firstMatch));
    expect(text, isNot(contains(':smi')));
    // Panel closed after commit.
    expect(find.text(':smile:'), findsNothing);
  });

  testWidgets('a non-matching ":zzzzq" shows no panel', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.enterText(find.byType(TextField), ':zzzzq');
    await tester.pumpAndSettle();

    // No suggestion row of the `:...:` shape is rendered.
    expect(find.byWidgetPredicate(_isShortcodeRow), findsNothing);
  });

  testWidgets('a URL like "http://x" shows no panel', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.enterText(find.byType(TextField), 'see http://x');
    await tester.pumpAndSettle();

    expect(find.byWidgetPredicate(_isShortcodeRow), findsNothing);
  });
}

/// Matches a rendered suggestion-row label of the `:shortcode:` shape (a Text
/// whose data is a colon-wrapped shortcode), used to assert the panel is absent
/// without depending on any one shortcode's presence.
bool _isShortcodeRow(Widget w) {
  if (w is! Text) return false;
  final data = w.data;
  return data != null &&
      data.length > 2 &&
      data.startsWith(':') &&
      data.endsWith(':');
}
