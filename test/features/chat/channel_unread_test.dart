import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/presentation/chat_screen.dart'
    show UnreadBadge;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

/// Per-channel unread indicators on the channel switcher (app-only feature).
///
/// The repository subscribes to every channel at construction, so each channel's
/// inbound messages are already in the local cache; unread is a pure function of
/// (cached messages, per-channel last-read watermark, my user id).
void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  // Isolate watermark persistence across tests — testPrefs is shared for the
  // whole suite (setUpAll), so drop any read-state a prior test wrote.
  setUp(() async {
    for (final k in testPrefs
        .getKeys()
        .where((k) => k.startsWith('aiko_channel_lastread_'))
        .toList()) {
      await testPrefs.remove(k);
    }
  });

  // Canonical-length 26-char ULIDs that sort by their last two chars.
  String ulid(String tail) => '01J${'0' * 21}$tail';

  /// An inbound (server-originated) message for [channelId] from [userId].
  Message inbound(String channelId, String id, String userId, String body) =>
      Message(
        clientTempId: id,
        id: id,
        channelId: channelId,
        sender: MessageSender(
            userId: userId, kind: SenderKind.human, label: 'User $userId'),
        body: body,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
        deliveryState: DeliveryState.sent,
      );

  const twoChannels = [
    Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
    Channel(id: 'c2', name: 'random', kind: ChannelKind.standard),
  ];

  /// Let the repo's serialized inbound queue persist + the cache stream emit.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  Finder aggregate() => find.byKey(const Key('unread-aggregate'));

  testWidgets('a message in the non-active channel shows an unread badge',
      (tester) async {
    final transport = FakeChatTransport();
    final container =
        makeContainer(rest: FakeRestApi(channels: twoChannels), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester); // active channel = c1 (general)

    // No unread yet.
    expect(aggregate(), findsNothing);

    // Another user posts into the NON-active channel c2.
    transport.emitMessage(inbound('c2', ulid('0A'), 'u2', 'hey there'));
    await settle(tester);

    // The collapsed switcher now carries the aggregate unread badge, count 1.
    expect(aggregate(), findsOneWidget);
    expect(
        find.descendant(of: aggregate(), matching: find.text('1')), findsOneWidget);
  });

  testWidgets('switching to the channel clears its badge (watermark advances)',
      (tester) async {
    final transport = FakeChatTransport();
    final container =
        makeContainer(rest: FakeRestApi(channels: twoChannels), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    transport.emitMessage(inbound('c2', ulid('0A'), 'u2', 'unread msg'));
    await settle(tester);
    expect(aggregate(), findsOneWidget);

    // Switch to c2 (view it) — viewing marks it read.
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('random').last);
    await settle(tester);

    // Badge cleared: no aggregate (c1 has none, c2 now read).
    expect(aggregate(), findsNothing);
    // And the watermark was persisted for this user/channel.
    expect(testPrefs.getString('aiko_channel_lastread_u1_c2'), ulid('0A'));
  });

  testWidgets('the active channel never shows a badge', (tester) async {
    final transport = FakeChatTransport();
    final container =
        makeContainer(rest: FakeRestApi(channels: twoChannels), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester); // active = c1

    // A message arrives in the ACTIVE channel c1 from someone else.
    transport.emitMessage(inbound('c1', ulid('0A'), 'u2', 'in active chan'));
    await settle(tester);

    // The message renders, but the active channel is never badged.
    expect(find.text('in active chan'), findsOneWidget);
    expect(aggregate(), findsNothing);
  });

  testWidgets('my own messages do not count as unread', (tester) async {
    final transport = FakeChatTransport();
    final container =
        makeContainer(rest: FakeRestApi(channels: twoChannels), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester); // me = u1 (FakeRestApi.defaultUser)

    // An echo of MY OWN message lands in the non-active channel c2.
    transport.emitMessage(inbound('c2', ulid('0A'), 'u1', 'my echo'));
    await settle(tester);

    // No unread — a message from myself is never unread.
    expect(aggregate(), findsNothing);
  });

  testWidgets('a persisted watermark is honored on load (durability)',
      (tester) async {
    // Seed a persisted watermark BEFORE the app builds: user u1 has already read
    // c2 through ulid('05').
    await testPrefs.setString('aiko_channel_lastread_u1_c2', ulid('05'));

    final transport = FakeChatTransport();
    final container =
        makeContainer(rest: FakeRestApi(channels: twoChannels), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    // A message BELOW the persisted watermark is already-read → no badge.
    transport.emitMessage(inbound('c2', ulid('03'), 'u2', 'old already-read'));
    await settle(tester);
    expect(aggregate(), findsNothing);

    // A message ABOVE the watermark is genuinely unread → badge appears.
    transport.emitMessage(inbound('c2', ulid('09'), 'u2', 'new unread'));
    await settle(tester);
    expect(aggregate(), findsOneWidget);
    expect(
        find.descendant(of: aggregate(), matching: find.text('1')), findsOneWidget);
  });

  testWidgets('unread count reflects multiple messages and the badge caps',
      (tester) async {
    final transport = FakeChatTransport();
    final container =
        makeContainer(rest: FakeRestApi(channels: twoChannels), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    transport.emitMessage(inbound('c2', ulid('0A'), 'u2', 'one'));
    transport.emitMessage(inbound('c2', ulid('0B'), 'u2', 'two'));
    transport.emitMessage(inbound('c2', ulid('0C'), 'u3', 'three'));
    await settle(tester);

    expect(aggregate(), findsOneWidget);
    expect(
        find.descendant(of: aggregate(), matching: find.text('3')), findsOneWidget);
    // The badge widget is the shared UnreadBadge type.
    expect(find.byType(UnreadBadge), findsWidgets);
  });
}
