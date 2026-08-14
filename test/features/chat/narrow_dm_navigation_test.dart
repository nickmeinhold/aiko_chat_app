// Acceptance tests for #2798 task #12 — narrow-layout DM navigation.
//
// The narrow layout has no sidebar, so the app-bar dropdown IS the whole
// navigation surface. Until this slice it listed `channelsProvider` only — and
// the island excludes DMs from `GET /v1/channels` by design — so on a phone a DM
// had no row anywhere: `openDm` could drop you into a conversation you could
// neither return to nor leave. These lock the two halves of that capability:
//
//   ENTRY   — a DM is in the dropdown and picking it makes it active;
//   LEAVE   — with a DM active the switcher is still there, and picking a
//             channel gets you out (the old code gated the switcher off
//             entirely whenever a DM was active, which is what made it a trap);
//
// plus the properties that stop the two surfaces drifting: every id that can be
// ACTIVE has an item (the DropdownButton `value` assertion, which the old gate
// was papering over), the aggregate unread dot counts DMs, and a peer-muted DM
// renders muted in this menu too — the menu is the only mute surface on a phone.
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/application/mute_controller.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart'
    show ConnectionState;
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/channel_member.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/presentation/chat_screen.dart'
    show UnreadBadge;
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  // Shared prefs are suite-wide; clear read marks so unread baselines start clean.
  setUp(() async {
    for (final k in testPrefs
        .getKeys()
        .where((k) => k.startsWith('aiko_channel_lastread_'))
        .toList()) {
      await testPrefs.remove(k);
    }
  });

  const channels = [
    Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
    Channel(id: 'c2', name: 'random', kind: ChannelKind.standard),
  ];
  const dm = Channel(id: 'dm1', name: '', kind: ChannelKind.dm);

  // me (u1, the signed-in default) + the peer Alice (u2).
  const roster = [
    ChannelMember(
        userId: 'u1', role: 'member', canPost: true, handle: 'me', displayName: 'Me'),
    ChannelMember(
        userId: 'u2',
        role: 'member',
        canPost: true,
        handle: 'alice',
        displayName: 'Alice'),
  ];

  FakeRestApi restWithDm({List<Channel> chans = channels}) {
    final rest = FakeRestApi(channels: chans);
    rest.dms = [dm];
    rest.membersByChannel['dm1'] = roster;
    return rest;
  }

  /// Pin a phone-width viewport (< kWideLayoutBreakpoint).
  void setNarrow(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Open the app-bar dropdown menu (taps the collapsed button).
  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
  }

  testWidgets('ENTRY: the DM is listed in the narrow dropdown, under a header',
      (tester) async {
    setNarrow(tester);
    final container =
        makeContainer(rest: restWithDm(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    await openMenu(tester);

    // Both channels, the section boundary, and the DM titled by its peer's
    // CURRENT handle (a DM has no server name — identity=key, ADR-0004).
    expect(find.text('general'), findsWidgets);
    expect(find.text('random'), findsWidgets);
    expect(find.text('Direct messages'), findsOneWidget);
    expect(find.text('alice'), findsWidgets);
  });

  testWidgets('ENTRY: picking the DM selects it and it STAYS selected',
      (tester) async {
    setNarrow(tester);
    final container =
        makeContainer(rest: restWithDm(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    await openMenu(tester);
    await tester.tap(find.text('alice').last);
    await tester.pumpAndSettle();

    // Through the SAME mutator as a channel, and not cleared by the self-heal.
    expect(container.read(selectedChannelIdProvider), 'dm1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('LEAVE: with the DM active the switcher is still shown, and a '
      'channel pick gets you out', (tester) async {
    setNarrow(tester);
    final container =
        makeContainer(rest: restWithDm(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    container.read(selectedChannelIdProvider.notifier).select('dm1');
    await tester.pumpAndSettle();

    // The trap this slice removes: the switcher used to be gated OFF whenever a
    // DM was active, leaving a phone user with no control at all.
    expect(find.byType(DropdownButton<String>), findsOneWidget);

    await openMenu(tester);
    await tester.tap(find.text('random').last);
    await tester.pumpAndSettle();

    expect(container.read(selectedChannelIdProvider), 'c2');
  });

  testWidgets('every id that can be ACTIVE has an item (no DropdownButton '
      'value assertion for any navigable conversation)', (tester) async {
    setNarrow(tester);
    final container =
        makeContainer(rest: restWithDm(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    // Walk EVERY navigable conversation through the active slot. This is the
    // invariant the removed gate was standing in for, stated directly: the
    // switcher's item set must cover the resolver's list, or Flutter asserts.
    for (final c in container.read(navigableChannelsProvider)) {
      container.read(selectedChannelIdProvider.notifier).select(c.id);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'active=${c.id}');
      expect(find.byType(DropdownButton<String>), findsOneWidget,
          reason: 'active=${c.id}');
    }
  });

  testWidgets('the section header is NOT selectable', (tester) async {
    setNarrow(tester);
    final container =
        makeContainer(rest: restWithDm(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    final before = container.read(selectedChannelIdProvider);

    await openMenu(tester);
    await tester.tap(find.text('Direct messages'));
    await tester.pumpAndSettle();

    // A disabled item cannot change the selection. (It also carries a null value,
    // so it can never collide with DropdownButton's one-match-for-`value` rule.)
    expect(container.read(selectedChannelIdProvider), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no header when there is no boundary to mark (DMs, no channels)',
      (tester) async {
    setNarrow(tester);
    // An account with no channels at all, only DMs — the header would sit alone
    // above the whole list, labelling nothing against nothing.
    final rest = restWithDm(chans: const []);
    rest.dms = [dm, const Channel(id: 'dm2', name: '', kind: ChannelKind.dm)];
    rest.membersByChannel['dm2'] = const [
      ChannelMember(
          userId: 'u1', role: 'member', canPost: true, handle: 'me', displayName: 'Me'),
      ChannelMember(
          userId: 'u3', role: 'member', canPost: true, handle: 'bob', displayName: 'Bob'),
    ];
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    await openMenu(tester);

    // Both DMs are pickable; the header is not drawn.
    expect(find.text('alice'), findsWidgets);
    expect(find.text('bob'), findsWidgets);
    expect(find.text('Direct messages'), findsNothing);
  });

  testWidgets('the aggregate unread dot counts DMs — on a phone it is the ONLY '
      'signal a DM is waiting', (tester) async {
    setNarrow(tester);
    final transport = FakeChatTransport();
    final container =
        makeContainer(rest: restWithDm(), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    // Drive `connected` so the history fence settles and first-sight baselining
    // unblocks (mirrors channel_unread_test) — an unread count is meaningless
    // until the client knows what it had already seen.
    await signIn(tester);
    transport.emitConn(ConnectionState.connected);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    // Stand in a channel, then have the DM receive a message from the peer.
    container.read(selectedChannelIdProvider.notifier).select('c1');
    await tester.pumpAndSettle();

    transport.emitMessage(Message(
      clientTempId: 'm1',
      id: '01J${'0' * 21}1',
      channelId: 'dm1',
      sender: const MessageSender(
          userId: 'u2', kind: SenderKind.human, label: 'alice'),
      body: 'hey',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      deliveryState: DeliveryState.sent,
    ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    // The collapsed app bar shows the aggregate dot. Before this slice the
    // aggregate summed channels only, so a waiting DM was invisible on a phone.
    expect(find.byKey(const Key('unread-aggregate')), findsOneWidget);
    expect(
      tester.widget<UnreadBadge>(find.byKey(const Key('unread-aggregate'))).count,
      greaterThan(0),
    );
  });

  testWidgets('a PEER-muted DM renders muted in the menu (peer-aware, like the '
      'sidebar row)', (tester) async {
    setNarrow(tester);
    final container =
        makeContainer(rest: restWithDm(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    // Mute the PERSON, not the conversation — only a peer-aware read sees this.
    container
        .read(mutesProvider.notifier)
        .setUserMuted('u2', muted: true, expectUserId: null);
    await tester.pumpAndSettle();

    await openMenu(tester);

    // `mutedChannelIdsProvider` alone would answer "not muted" here, and the row
    // would render identically to an idle one (cage-match #135 round 7, Tesla).
    expect(find.byKey(const Key('muted-item-dm1')), findsOneWidget);
  });
}
