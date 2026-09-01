// The world the walker walks.
//
// The first sweep of 50 walks found nothing, and the coverage probe showed why:
// with the default fakes there are no DM channels and no message bubbles, so the
// largest features in the 0.0.4 release — navigable DMs (#2798) and everything
// hanging off a message long-press (Message, Mute, Report, Block) — rendered
// nothing for the walker to find. It was walking an empty app and reporting the
// empty app was fine.
//
// So the walker gets a populated one: more than one channel, a DM that already
// exists, and messages from ANOTHER human. That last detail is load-bearing —
// the moderation sheet is gated on `!isMine && sender.userId != null`
// (chat_screen.dart), so a walk through a channel containing only your own
// messages still cannot reach it.
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

/// A phone-width viewport: the narrow information architecture (app-bar
/// dropdown switcher), which is what nearly every user has.
const walkPhone = Size(400, 900);

/// Wide enough for the sidebar layout — a genuinely different IA above the
/// 720px breakpoint, so a walk on one says nothing about the other.
const walkDesktop = Size(1400, 900);

const _general = Channel(id: 'c1', name: 'general', kind: ChannelKind.standard);
const _random = Channel(id: 'c2', name: 'random', kind: ChannelKind.standard);
const _dmWithAlice = Channel(
  id: 'dm:u1:alice-key',
  name: '',
  kind: ChannelKind.dm,
);

/// Messages from someone who is NOT the signed-in user, each with a real
/// `userId` — the two conditions the long-press moderation affordance is gated
/// on. Without both, the sheet is unreachable and the walker is blind to it.
List<Message> _seedMessages() => [
  for (var i = 0; i < 3; i++)
    Message(
      clientTempId: 'seed-$i',
      id: 'seed-$i',
      channelId: _general.id,
      sender: const MessageSender(
        userId: 'alice-key',
        kind: SenderKind.human,
        label: 'Alice',
      ),
      body: 'seeded message $i',
      createdAt: DateTime.utc(2026, 9, 1, 12, i),
      deliveryState: DeliveryState.sent,
    ),
];

/// Mount the real app, signed in, with a populated world, at [size].
Future<void> pumpWalkableApp(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final rest = FakeRestApi(channels: const [_general, _random])
    ..dms = const [_dmWithAlice];
  final transport = FakeChatTransport();

  final container = makeContainer(rest: rest, transport: transport);
  addTearDown(container.dispose);

  await pumpApp(tester, container);
  await signIn(tester);

  // Emitted AFTER sign-in: the repository subscribes on session start, so a
  // message pushed before that has nobody listening for it.
  for (final m in _seedMessages()) {
    transport.emitMessage(m);
  }
  await tester.pumpAndSettle();
}
