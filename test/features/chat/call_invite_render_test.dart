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
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
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
      rest: FakeRestApi(channels: channels),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);

    await tester.enterText(find.byType(TextField).first, kCallInviteBody);
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('aiko:call/1'),
      findsNothing,
      reason:
          'the wire anchor leaked into the UI — it is for OLD clients, '
          'not for this one',
    );
  });

  testWidgets('it reads as ONE sentence: who did what', (tester) async {
    final container = makeContainer(
      rest: FakeRestApi(channels: channels),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);

    await tester.enterText(find.byType(TextField).first, kCallInviteBody);
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    // Mine, so it speaks in the second person rather than repeating my handle
    // back at me.
    expect(
      find.text('You started a call'),
      findsOneWidget,
      reason:
          'the actor and the act must be one line — splitting them across '
          'a name row and a body, with an avatar between, is what made this '
          'confusing in the first place',
    );
  });

  testWidgets('an ordinary message that merely MENTIONS the sentinel is not '
      'turned into a call line — the match is exact, deliberately', (
    tester,
  ) async {
    final container = makeContainer(
      rest: FakeRestApi(channels: channels),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);

    // Same reasoning as `isCallInviteBody`'s exact match: a startsWith/contains
    // test would let anyone fake a call line by typing the sentinel with a word
    // after it.
    await tester.enterText(
      find.byType(TextField).first,
      '$kCallInviteBody but not really',
    );
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('You started a call'), findsNothing);
    expect(
      find.textContaining('but not really'),
      findsOneWidget,
      reason: 'a near-miss must render as the ordinary message it is',
    );
  });

  testWidgets('the HANGUP is an event too — its anchor never reaches the '
      'screen either', (tester) async {
    // The half that would have silently regressed. `kCallEndBody` is worded like
    // the invite — machine anchor first, so an old client degrades to a readable
    // line — so shipping the wire half alone would have put
    // `aiko:call/1 · 📞 ended the call` back into a speech bubble, undoing the
    // exact thing the invite's render arm exists to do.
    final container = makeContainer(
      rest: FakeRestApi(channels: channels),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);

    // A REAL hangup names the call it ends. `admitCallEnd` refuses a stop with
    // no `replyTo` — "about everything or nothing" — and the render arm now
    // applies the same clause, so this must send one that is actually bound.
    //
    // Sent through the REPOSITORY rather than the composer, because that is the
    // path a hangup actually takes: `CallEndAnnouncer` calls `sendMessage` with
    // the invitation's server id. The composer has no way to aim a `reply_to`,
    // which is precisely the property the gate below relies on.
    await tester.runAsync(() async {
      final repo = await container.read(chatRepositoryProvider.future);
      await repo.sendMessage(
        'c1',
        kCallEndBody,
        replyToId: '01M0GS7FDWBVQ31950B1PTV2DW',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(
      find.textContaining('aiko:call/1'),
      findsNothing,
      reason: 'the wire anchor leaked into the UI on the hangup path',
    );
    expect(find.text('You ended the call'), findsOneWidget);
  });

  testWidgets('an UNVERIFIED sentinel is not elevated into system narration', (
    tester,
  ) async {
    // Cage-match round 7, Carnot. Adding the reply clause alone left a second
    // gate with fewer clauses than the domain's: `admitCallEnd` also demands a
    // verified origin and a human author, so an unsigned or imported row
    // carrying the sentinel and a `reply_to` could still be drawn as a system
    // event. Both arms now call the SAME predicates, beside `admitCallEnd`.
    final transport = FakeChatTransport();
    final container = makeContainer(
      rest: FakeRestApi(channels: channels),
      transport: transport,
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);

    // Arrives from someone else, carrying the exact sentinel AND a reply
    // binding — but unsigned, so nothing vouches for who wrote it.
    transport.emitMessage(
      Message(
        clientTempId: '01M0GS7FDWBVQ31950B1PTV2E1',
        id: '01M0GS7FDWBVQ31950B1PTV2E1',
        channelId: 'c1',
        sender: const MessageSender(
          userId: 'mallory-key',
          kind: SenderKind.human,
          label: 'Mallory',
        ),
        body: kCallEndBody,
        replyToId: '01M0GS7FDWBVQ31950B1PTV2DW',
        createdAt: DateTime.now().toUtc(),
        deliveryState: DeliveryState.sent,
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();

    // ASSERT ON THE EVENT FORM, not on the words. The sentinel body literally
    // contains "ended the call", so `textContaining` matches the raw text too
    // and cannot tell a system line from a degraded one — an instrument blind to
    // the difference it exists to measure. The event line is the composed
    // sentence; the ordinary rendering still carries the machine anchor.
    expect(
      find.text('Mallory ended the call'),
      findsNothing,
      reason:
          'the ring would refuse this message outright — the screen must not '
          'be more generous than the gate it reports on',
    );
    expect(
      find.textContaining('aiko:call/1'),
      findsOneWidget,
      reason:
          'and it degrades to the literal text it is, with no system authority '
          'borrowed from a signature nobody checked',
    );
  });

  testWidgets('a hangup that names NO call is not drawn as a call event', (
    tester,
  ) async {
    // Cage-match round 6, Carnot. The arm matched the body alone, so anyone who
    // typed the sentinel got a centred, unbubbled system line announcing the end
    // of a call that never happened — the ring's admission gate was strictly
    // tighter than the presentation gate that reports on it.
    //
    // Signing is no defence and it matters to say why: this app signs at BIRTH,
    // so a sentinel someone types is signed exactly like one the call screen
    // generates. A signature proves who authored the bytes, never that a machine
    // did. The reply binding is the discriminator, because a composer cannot aim
    // one at a message without actually replying to it.
    final container = makeContainer(
      rest: FakeRestApi(channels: channels),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);

    await tester.enterText(find.byType(TextField).first, kCallEndBody);
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('You ended the call'),
      findsNothing,
      reason:
          'an unbound sentinel is a message someone typed, not a call event — '
          'rendering it as one lets any reader be told a call ended',
    );
    expect(
      find.textContaining('aiko:call/1'),
      findsOneWidget,
      reason:
          'and it degrades to exactly what it is: the literal text, in an '
          'ordinary bubble, with no system authority borrowed',
    );
  });
}
