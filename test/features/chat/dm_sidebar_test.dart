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
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/channel_member.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
