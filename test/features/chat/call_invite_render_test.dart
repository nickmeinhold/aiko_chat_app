// A call invitation is an EVENT, not a remark.
//
// The wire body is a signed, permanent row worded so a client predating the
// feature degrades to a readable line rather than breaking. That graceful
// degradation is for OLD clients — this one is supposed to render it properly,
// and for a while it did not: the machine anchor `aiko:call/1` showed verbatim
// inside a normal speech bubble, with the caller's name on a separate line above
// the avatar.
//
// Reported as: "the sender and 'started a call' being on separate lines with
// something in between is confusing."
import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  const channels = [
    Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
  ];

  testWidgets('the raw sentinel is NEVER shown to a reader', (tester) async {
    final container = makeContainer(
        rest: FakeRestApi(channels: channels), transport: FakeChatTransport());
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);

    await tester.enterText(find.byType(TextField).first, kCallInviteBody);
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(find.textContaining('aiko:call/1'), findsNothing,
        reason: 'the wire anchor leaked into the UI — it is for OLD clients, '
            'not for this one');
  });

  testWidgets('it reads as ONE sentence: who did what', (tester) async {
    final container = makeContainer(
        rest: FakeRestApi(channels: channels), transport: FakeChatTransport());
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);

    await tester.enterText(find.byType(TextField).first, kCallInviteBody);
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    // Mine, so it speaks in the second person rather than repeating my handle
    // back at me.
    expect(find.text('You started a call'), findsOneWidget,
        reason: 'the actor and the act must be one line — splitting them across '
            'a name row and a body, with an avatar between, is what made this '
            'confusing in the first place');
  });

  testWidgets('an ordinary message that merely MENTIONS the sentinel is not '
      'turned into a call line — the match is exact, deliberately',
      (tester) async {
    final container = makeContainer(
        rest: FakeRestApi(channels: channels), transport: FakeChatTransport());
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);

    // Same reasoning as `isCallInviteBody`'s exact match: a startsWith/contains
    // test would let anyone fake a call line by typing the sentinel with a word
    // after it.
    await tester.enterText(
        find.byType(TextField).first, '$kCallInviteBody but not really');
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(find.text('You started a call'), findsNothing);
    expect(find.textContaining('but not really'), findsOneWidget,
        reason: 'a near-miss must render as the ordinary message it is');
  });
}
