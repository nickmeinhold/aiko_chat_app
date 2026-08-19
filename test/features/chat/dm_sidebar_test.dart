// Acceptance tests for #2798 Inc 1 — navigable DMs.
//
// Locks the non-obvious behaviours of the DM slice:
//   - the sidebar renders a Direct-messages section whose row label is the peer's
//     CURRENT handle, resolved from the roster (identity=key: a DM has no name);
//   - tapping a DM row selects it through the SAME mutator as channels AND it
//     STAYS selected — the self-heal (which clears a pick absent from the channel
//     list) must recognise DMs, else selecting a DM would instantly clear it;
//   - dmsProvider fails SOFT: a DM-list fetch failure degrades to no DMs rather
//     than taking the whole chat surface down with it;
//   - navigableChannelsProvider is channels ∪ DMs (the resolver's combined view).
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show NetworkUnavailable;
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart'
    show ConnectionState;
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/channel_member.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/presentation/chat_screen.dart'
    show UnreadBadge;
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import '../../support/pixels.dart';
import '../../support/test_helpers.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  const channels = [Channel(id: 'c1', name: 'general', kind: ChannelKind.standard)];
  const dm = Channel(id: 'dm1', name: '', kind: ChannelKind.dm);

  // The DM's roster: me (u1, the default signed-in user) + the peer Alice (u2).
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

  FakeRestApi restWithDm() {
    final rest = FakeRestApi(channels: channels);
    rest.dms = [dm];
    rest.membersByChannel['dm1'] = roster;
    return rest;
  }

  void setWide(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('wide sidebar shows a DM section labelled with the peer handle',
      (tester) async {
    setWide(tester);
    final container =
        makeContainer(rest: restWithDm(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    expect(find.text('Direct messages'), findsOneWidget);
    expect(find.byKey(const Key('sidebar-dm-dm1')), findsOneWidget);
    // The row is titled by the peer's current handle, not the empty channel name.
    expect(find.text('alice'), findsOneWidget);
  });

  testWidgets('tapping a DM selects it AND it stays selected (self-heal knows DMs)',
      (tester) async {
    setWide(tester);
    final container =
        makeContainer(rest: restWithDm(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sidebar-dm-dm1')));
    await tester.pumpAndSettle();

    // Selected through the same mutator as a channel tile...
    expect(container.read(selectedChannelIdProvider), 'dm1');
    // ...and NOT cleared by the self-heal (a DM id is absent from channelsProvider;
    // healing against channels alone — the pre-#2798 bug — would clear it here).
    expect(
      tester.widget<ListTile>(find.byKey(const Key('sidebar-dm-dm1'))).selected,
      isTrue,
    );
  });

  testWidgets('dmsProvider fails SOFT — a DM-list failure degrades to [], not an '
      'error that takes the chat surface down', (tester) async {
    setWide(tester);
    final rest = FakeRestApi(channels: channels)
      ..listDmsThrows = const NetworkUnavailable();
    final container =
        makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester); // authed user gate passes
    await tester.pumpAndSettle();

    // Degraded to "no DMs" (no section, no error), and the channel chat is intact.
    expect(await container.read(dmsProvider.future), isEmpty);
    expect(find.text('Direct messages'), findsNothing);
    expect(find.byKey(const Key('sidebar-channel-c1')), findsOneWidget);
  });

  testWidgets('navigableChannelsProvider is channels ∪ DMs', (tester) async {
    setWide(tester);
    final container =
        makeContainer(rest: restWithDm(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    final ids =
        container.read(navigableChannelsProvider).map((c) => c.id).toSet();
    expect(ids, containsAll(<String>{'c1', 'dm1'}));
  });

  testWidgets('a DM selected on wide survives the resize to narrow — switcher '
      'included, not gated away', (tester) async {
    // ≥2 channels so the narrow layout builds the dropdown. This used to be the
    // exact condition under which a DM activeId fed to DropdownButton.value
    // asserted, and the fix was a gate that hid the switcher entirely. The gate
    // is gone (#2798 task #12): the DM is now IN the item list, so `value` has its
    // match and the user keeps a way out of the conversation.
    final rest = FakeRestApi(channels: const [
      Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
      Channel(id: 'c2', name: 'random', kind: ChannelKind.standard),
    ]);
    rest.dms = [dm];
    rest.membersByChannel['dm1'] = roster;
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    // Wide: select the DM through the sidebar.
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sidebar-dm-dm1')));
    await tester.pumpAndSettle();
    expect(container.read(selectedChannelIdProvider), 'dm1');

    // Resize across the breakpoint — the AppBar rebuilds with a DM active.
    tester.view.physicalSize = const Size(400, 900);
    await tester.pumpAndSettle();

    // No DropdownButton value/items assertion — because the DM is now one of the
    // items, so the switcher stays up and the collapsed button renders the DM's
    // own row, titled by its peer.
    expect(tester.takeException(), isNull);
    expect(find.byType(DropdownButton<String>), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
  });

  testWidgets(
      'first-load DM failure (no last-known) degrades to [] — repo survives',
      (tester) async {
    setWide(tester);
    final rest = FakeRestApi(channels: channels)
      ..listDmsThrows = StateError('boom'); // a 5xx / poisoned-row class, not offline
    final container =
        makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    // Nothing was ever fetched, so there is no last-known list → []. Crucially the
    // channel chat is fully intact (the repo, which awaits dmsProvider.future, did
    // not die on the non-network throw).
    expect(await container.read(dmsProvider.future), isEmpty);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('sidebar-channel-c1')), findsOneWidget);
    expect(find.text('Direct messages'), findsNothing);
  });

  testWidgets(
      'a transient failure AFTER a good fetch keeps the selected DM (last-known)',
      (tester) async {
    setWide(tester);
    final rest = restWithDm(); // listDms succeeds → [dm1]
    final container =
        makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sidebar-dm-dm1')));
    await tester.pumpAndSettle();
    expect(container.read(selectedChannelIdProvider), 'dm1');

    // A transient DM-list failure now hits a refetch.
    rest.listDmsThrows = StateError('boom');
    container.invalidate(dmsProvider);
    await tester.pumpAndSettle();

    // Degrades to STALE (last-known [dm1]), NOT [] — so the DM stays present and
    // the self-heal does NOT eject the selection (the degraded-empty resonance the
    // cage-match flagged: soft-empty must not read as "conversation deleted").
    expect(await container.read(dmsProvider.future), isNotEmpty);
    expect(container.read(selectedChannelIdProvider), 'dm1');
    expect(find.byKey(const Key('sidebar-dm-dm1')), findsOneWidget);
  });

  // ── Inc 2: unread badges on DM rows + a VISIBLE selection highlight ─────────

  /// Let the repo's serialized inbound queue persist, the cache streams emit, and
  /// the deferred first-sight baseline flush (mirrors channel_unread_test).
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  String ulid(String tail) => '01J${'0' * 21}$tail';

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

  /// Sign in AND drive the `connected` choreography so history sync runs and each
  /// conversation's fence settles — that fence is what unblocks first-sight
  /// baselining, without which unread stays 0 (never floods) by design.
  Future<void> signInConnected(
      WidgetTester tester, FakeChatTransport transport) async {
    await signIn(tester);
    transport.emitConn(ConnectionState.connected);
    await settle(tester);
  }

  testWidgets('a DM row badges unread from the peer while a channel is active',
      (tester) async {
    setWide(tester);
    final transport = FakeChatTransport();
    final container = makeContainer(rest: restWithDm(), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signInConnected(tester, transport);

    // The DM is NOT the active conversation (nothing is picked, so `resolveActive`
    // lands on the first channel), and nothing is unread yet.
    expect(
      tester.widget<ListTile>(find.byKey(const Key('sidebar-dm-dm1'))).selected,
      isFalse,
    );
    expect(find.byKey(const Key('sidebar-unread-dm1')), findsNothing);

    // The peer posts into the DM. DMs are in the repo's subscription set (#132),
    // so their messages land in the same cache the unread accounting reads.
    transport.emitMessage(inbound('dm1', ulid('0A'), 'u2', 'hey'));
    await settle(tester);

    expect(container.read(channelUnreadCountProvider('dm1')), 1);
    final badge = find.byKey(const Key('sidebar-unread-dm1'));
    expect(badge, findsOneWidget);
    expect(tester.widget<UnreadBadge>(badge).count, 1);
  });

  testWidgets('my own DM message is never unread, and opening the DM clears it',
      (tester) async {
    setWide(tester);
    final transport = FakeChatTransport();
    final container = makeContainer(rest: restWithDm(), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signInConnected(tester, transport);

    // My own echo into the DM: never unread (u1 is the signed-in test user).
    transport.emitMessage(inbound('dm1', ulid('0A'), 'u1', 'my echo'));
    await settle(tester);
    expect(find.byKey(const Key('sidebar-unread-dm1')), findsNothing);

    // The peer replies → badged...
    transport.emitMessage(inbound('dm1', ulid('0B'), 'u2', 'reply'));
    await settle(tester);
    expect(find.byKey(const Key('sidebar-unread-dm1')), findsOneWidget);

    // ...and opening the DM marks it read (the active row is never badged, and
    // MessageList advances the watermark on view — same contract as a channel).
    await tester.tap(find.byKey(const Key('sidebar-dm-dm1')));
    await settle(tester);
    expect(find.byKey(const Key('sidebar-unread-dm1')), findsNothing);
    expect(container.read(channelUnreadCountProvider('dm1')), 0);
  });

  testWidgets('the selected row is VISIBLY distinct from the rows around it',
      (tester) async {
    // The regression this locks: the theme's selectedTileColor was the same
    // colour as the rail's own surface, so `selected: true` changed the label
    // colour but left the row indistinguishable from its background.
    setWide(tester);
    // A SECOND channel, because a selection is only visible relative to
    // something unselected beside it — with one row there is nothing to be
    // distinct from.
    final rest = FakeRestApi(channels: const [
      Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
      Channel(id: 'c2', name: 'random', kind: ChannelKind.standard),
    ]);
    rest.dms = [dm];
    rest.membersByChannel['dm1'] = roster;
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    // MEASURED, not declared. This used to read `selectedTileColor` off the
    // ListTile and assert it was non-null and `!=` the rail's Material colour.
    // Both hold while the row is invisible: `!=` is satisfied by two colours
    // one bit apart, and neither read proves the tile is selected or that
    // anything was painted at all.
    //
    // Compared against ANOTHER CHANNEL ROW, which is the comparison a reader
    // makes — "which of these am I in" is answered against the sibling rows,
    // not against the background. The first cut of this compared the selected
    // channel to the DM row and passed with `selectedTileColor` forced to
    // transparent: those two live in different sidebar sections, so it was
    // measuring section chrome and would have reported green forever.
    final frame = await capturePainted(tester);
    Color fillOf(String key) {
      final r = tester.getRect(find.byKey(Key(key)));
      return frame.at(Offset(r.left + 4, r.center.dy));
    }

    expect(tester.widget<ListTile>(find.byKey(const Key('sidebar-channel-c1'))).selected,
        isTrue,
        reason: 'the fixture must have c1 selected for this to measure anything');
    final mine = fillOf('sidebar-channel-c1');
    final theirs = fillOf('sidebar-channel-c2');
    expect(paintedContrast(mine, theirs), greaterThan(1.05),
        reason: 'the selected channel paints $mine and its unselected sibling '
            'paints $theirs — a reader cannot see which row they are in');
  });
}
