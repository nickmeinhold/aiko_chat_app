// Acceptance tests for #2798 task #12 — narrow-layout DM navigation.
//
// The narrow layout reaches the shared conversation rail through the app-bar
// drawer. Before the rail covered phones, `openDm` could drop you into a
// conversation you could neither return to nor leave. These lock the two halves
// of that capability:
//
//   ENTRY   — a DM is in the drawer and picking it makes it active;
//   LEAVE   — with a DM active the drawer is still reachable, and picking a
//             channel gets you out;
//
// plus the properties that stop the two surfaces drifting: every id that can be
// ACTIVE has a drawer row, unread row badges count DMs, and a peer-muted DM
// renders muted in the drawer too.
import 'dart:async';

import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/application/mute_controller.dart';
import 'package:aiko_chat_app/features/chat/data/chat_repository.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart'
    show ConnectionState;
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/channel_member.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/presentation/chat_screen.dart'
    show UnreadBadge;
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  // Shared prefs are suite-wide, so state written by one test is visible to the
  // next. Clear read marks (unread baselines) AND mutes — a mute leaking forward
  // is silent rather than loud: `channelUnreadCountProvider` reports 0 for a muted
  // conversation, so a stale mute makes an unread assertion fail as "no badge"
  // with nothing pointing at the previous test. Found exactly that way.
  setUp(() async {
    for (final k
        in testPrefs
            .getKeys()
            .where(
              (k) =>
                  k.startsWith('aiko_channel_lastread_') ||
                  k.startsWith('aiko_muted_'),
            )
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
      userId: 'u1',
      role: 'member',
      canPost: true,
      handle: 'me',
      displayName: 'Me',
    ),
    ChannelMember(
      userId: 'u2',
      role: 'member',
      canPost: true,
      handle: 'alice',
      displayName: 'Alice',
    ),
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

  Future<void> openConversationDrawer(WidgetTester tester) async {
    await openChatDrawer(tester);
  }

  testWidgets(
    'ENTRY: the DM is listed in the narrow drawer, under a header',
    (tester) async {
      setNarrow(tester);
      final container = makeContainer(
        rest: restWithDm(),
        transport: FakeChatTransport(),
      );
      addTearDown(container.dispose);

      await pumpApp(tester, container);
      await signIn(tester);
      await tester.pumpAndSettle();

      await openConversationDrawer(tester);

      // Both channels, the section boundary, and the DM titled by its peer's
      // CURRENT handle (a DM has no server name — identity=key, ADR-0004).
      expect(find.text('general'), findsWidgets);
      expect(find.text('random'), findsWidgets);
      expect(find.text('Direct messages'), findsOneWidget);
      expect(find.text('alice'), findsWidgets);
    },
  );

  testWidgets('ENTRY: picking the DM selects it and it STAYS selected', (
    tester,
  ) async {
    setNarrow(tester);
    final container = makeContainer(
      rest: restWithDm(),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    await selectDmFromDrawer(tester, 'dm1');

    // Through the SAME mutator as a channel, and not cleared by the self-heal.
    expect(container.read(selectedChannelIdProvider), 'dm1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('LEAVE: with the DM active the drawer is still reachable, and a '
      'channel pick gets you out', (tester) async {
    setNarrow(tester);
    final container = makeContainer(
      rest: restWithDm(),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    container.read(selectedChannelIdProvider.notifier).select('dm1');
    await tester.pumpAndSettle();

    // The trap this slice removes: a DM active on a phone must still leave a
    // visible way back to the conversation list.
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);

    await selectChannelFromDrawer(tester, 'c2');

    expect(container.read(selectedChannelIdProvider), 'c2');
  });

  testWidgets('every id that can be ACTIVE has a drawer row', (tester) async {
    setNarrow(tester);
    final container = makeContainer(
      rest: restWithDm(),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    // Walk EVERY navigable conversation through the active slot. This is the
    // invariant the removed gate was standing in for, stated directly: the
    // drawer row set must cover the resolver's list.
    for (final c in container.read(navigableChannelsProvider)) {
      container.read(selectedChannelIdProvider.notifier).select(c.id);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'active=${c.id}');
      await openConversationDrawer(tester);
      expect(
        find.byKey(
          Key(
            c.id == 'dm1' ? 'sidebar-dm-${c.id}' : 'sidebar-channel-${c.id}',
          ),
        ),
        findsOneWidget,
        reason: 'active=${c.id}',
      );
      await closeChatDrawer(tester);
    }
  });

  // A conversation listed by BOTH island endpoints. The island serves DMs only
  // through GET /v1/dm and excludes them from GET /v1/channels, so this is a
  // contract violation — but it lands in the conversation list where a repeat is
  // not cosmetic: one id would produce two rows with two possible visual states.
  // Deduped once in navigableChannelsProvider, so every consumer gets the same
  // answer (cage-match #136, Kelvin).
  FakeRestApi restWithLeak(ChannelKind leakedKind) {
    final rest = FakeRestApi(
      channels: [
        const Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
        Channel(id: 'dm1', name: '', kind: leakedKind),
      ],
    );
    rest.dms = [dm];
    rest.membersByChannel['dm1'] = roster;
    return rest;
  }

  for (final leakedKind in ChannelKind.values) {
    testWidgets(
      'a conversation listed by BOTH sources appears ONCE, whatever kind the '
      'channel list claims (leak kind: ${leakedKind.name})',
      (tester) async {
        setNarrow(tester);
        final container = makeContainer(
          rest: restWithLeak(leakedKind),
          transport: FakeChatTransport(),
        );
        addTearDown(container.dispose);

        await pumpApp(tester, container);
        await signIn(tester);
        await tester.pumpAndSettle();

        // Deduped, and the DM entry WINS: GET /v1/dm is the authority on what a DM
        // is. Letting the channel copy's kind survive would route a DM to a room
        // row, which paints its (empty) `name` and reads its mute with no peer —
        // the exact seat _DmMenuItem exists to fill (cage-match #136, Tesla).
        final navigable = container.read(navigableChannelsProvider);
        expect(navigable.where((c) => c.id == 'dm1').length, 1);
        expect(navigable.firstWhere((c) => c.id == 'dm1').kind, ChannelKind.dm);

        // No assertion, one drawer row, and selecting the doubled id resolves
        // cleanly.
        expect(tester.takeException(), isNull);
        await openConversationDrawer(tester);
        expect(find.byKey(const Key('sidebar-dm-dm1')), findsOneWidget);
        expect(find.byKey(const Key('sidebar-channel-dm1')), findsNothing);
        await closeChatDrawer(tester);
        await selectDmFromDrawer(tester, 'dm1');
        expect(tester.takeException(), isNull);
        expect(container.read(selectedChannelIdProvider), 'dm1');
      },
    );
  }

  for (final wrongKind in ChannelKind.values.where(
    (k) => k != ChannelKind.dm,
  )) {
    testWidgets('a DM stays in the DM section even when its own kind says otherwise '
        '(kind: ${wrongKind.name})', (tester) async {
      setNarrow(tester);
      // Sectioning is by SOURCE — which endpoint listed it — not by `Channel.kind`.
      // GET /v1/dm IS the island's answer to "is this a DM", so a row arriving
      // there with an unexpected kind (a decode default, a new island variant, a
      // group-shaped row) must still be a DM here. Splitting on `kind` instead
      // would paint it as a room: empty name, mute read with no peer, and no
      // "Direct messages" header above it (cage-match #136, Tesla).
      final rest = FakeRestApi(channels: channels);
      rest.dms = [Channel(id: 'dm1', name: '', kind: wrongKind)];
      rest.membersByChannel['dm1'] = roster;
      final container = makeContainer(
        rest: rest,
        transport: FakeChatTransport(),
      );
      addTearDown(container.dispose);

      await pumpApp(tester, container);
      await signIn(tester);
      await tester.pumpAndSettle();

      final sections = container.read(conversationSectionsProvider);
      expect(sections.dms.map((c) => c.id), ['dm1']);
      expect(sections.rooms.map((c) => c.id), ['c1', 'c2']);

      // ...and it renders as a DM row: peer-titled, under the header.
      await openConversationDrawer(tester);
      expect(find.text('Direct messages'), findsOneWidget);
      expect(find.text('alice'), findsWidgets);
      await closeChatDrawer(tester);
      await selectDmFromDrawer(tester, 'dm1');

      // Once ACTIVE it must stay a DM on every surface. These three used to ask
      // `channel.kind` individually, so a mis-kinded DM was peer-titled in the
      // list and then lost both its title and its peer-aware mute the moment
      // you entered it (cage-match #136, Tesla + Carnot).
      expect(find.text('alice'), findsWidgets); // title, not the empty DM name
      container
          .read(mutesProvider.notifier)
          .setUserMuted('u2', muted: true, expectUserId: null);
      await tester.pumpAndSettle();
      // Peer-aware: only a peer-aware read sees an ACCOUNT mute on this row.
      // The phone control is the details screen now, so the peer-awareness shows
      // up in that screen's own words — which is where it has to be right, since
      // that sentence is what tells you unmuting here would make this person
      // audible everywhere.
      await tester.tap(find.text('alice').first);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('This person is muted everywhere'),
        findsOneWidget,
      );
    });
  }

  testWidgets('a COLD channel-list failure tells the SAME story at both widths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // THE DESIGN CALL, made explicit because two cage-match rounds pulled in
    // opposite directions and both were right (#136, Tesla r6 vs r9):
    //   r6 — "a channel failure must not blank the DM rows"  (content-first)
    //   r9 — "no row may claim to be selected before both lists settle"
    //        (readiness-first)
    // They only conflict because `channelsProvider` fails HARD while
    // `dmsProvider` fails SOFT, so "DMs are here, channels are not" is a state
    // that persists instead of passing. Both findings are that one asymmetry seen
    // from two sides — task #33.
    //
    // Until #33 lands, readiness-first wins: the repository backs reading AND
    // sending, so listing a DM it cannot serve is a door into a room with no
    // floor (which Tesla filed against the content-first version in r8). Every
    // surface now tells one story. What this costs is exactly what #33 buys back.
    final rest = restWithDm()..listChannelsThrows = StateError('boom');
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    // The DMs are known — this is not a data loss, it is a serving decision.
    expect(container.read(conversationSectionsProvider).dms.map((c) => c.id), [
      'dm1',
    ]);
    // ...and no surface offers one it cannot serve: the rail says what the pane
    // says, rather than offering a row that lands on an error.
    expect(find.byKey(const Key('sidebar-dm-dm1')), findsNothing);
    expect(find.textContaining('Could not load conversations'), findsWidgets);
  });

  testWidgets('DMs arriving BEFORE channels never paint a conversation the '
      'default is about to move off', (tester) async {
    setNarrow(tester);
    // The first-arrival snap. With no pick yet, `resolveActive` returns the first
    // navigable conversation, and the sections list rooms FIRST — so while
    // GET /v1/channels is still in flight the only candidate is a DM. Render it
    // and the user gets Alice's thread with a LIVE composer; when the channels
    // land, the (still null) default moves to the first room, the keyed Composer
    // is disposed with the draft inside it, and anything already sent went to
    // Alice. The pane gates on the REPOSITORY, which awaits both lists, so this
    // window cannot paint at all (cage-match #136, Tesla HIGH).
    final rest = restWithDm();
    final channelGate = Completer<void>();
    rest.listChannelsGate = channelGate;
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    // NOT pumpAndSettle here: the pane is showing a CircularProgressIndicator,
    // whose animation never settles — which is itself the assertion. Drive fixed
    // frames instead.
    // tapSignIn, NOT signIn: the label is looked up either way (the login screen
    // swaps which ingress is primary once a ceremony has succeeded on this device
    // and testPrefs carries that across tests), but signIn() settles — and the
    // whole point here is the UNSETTLED frame above.
    await tapSignIn(tester);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    // DMs are in; channels are not. The repo — which awaits BOTH — is still
    // loading, so nothing conversational may be on screen: no composer to type
    // into, no message list to send from.
    expect(container.read(conversationSectionsProvider).dms.map((c) => c.id), [
      'dm1',
    ]);
    expect(
      container.read(chatRepositoryProvider),
      isA<AsyncLoading<ChatRepository>>(),
    );
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('composer-send')), findsNothing);
    // The BAR is on the same circuit as the pane. Gating only the pane left the
    // app bar titled with the DM and its mute button live over a spinner, so one
    // tap muted a conversation the user had never entered and the default was
    // about to leave (cage-match #136, Tesla).
    expect(find.text('alice'), findsNothing);
    // The conversation control must not exist before the conversation it names
    // is settled. That control lives on the details screen now, and the title is
    // not tappable until the same readiness gate opens.
    expect(find.text('Mute this conversation'), findsNothing);

    channelGate.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    // Now both are in, the default resolves ONCE, and it is stable.
    expect(find.byType(TextField), findsOneWidget);
    expect(container.read(navigableChannelsProvider).first.id, 'c1');
  });

  testWidgets('WIDE: the rail shows no conversation as SELECTED until both '
      'lists have settled', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // First-arrival is not a phone-only vibration. With DMs in and channels still
    // in flight, `resolveActive` on a null pick returned the DM, and the rail
    // painted Alice's row `selected: true` — then the channels landed, the
    // implicit default walked to the first room, and the highlight jumped. The
    // rail now rides the same readiness predicate as the bar and the pane
    // (cage-match #136, Tesla).
    final rest = restWithDm();
    final channelGate = Completer<void>();
    rest.listChannelsGate = channelGate;
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    // tapSignIn, NOT signIn: the label is looked up either way (the login screen
    // swaps which ingress is primary once a ceremony has succeeded on this device
    // and testPrefs carries that across tests), but signIn() settles — and the
    // whole point here is the UNSETTLED frame above.
    await tapSignIn(tester);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    // DMs are in, channels are not — no row may claim to be the one you are in.
    expect(container.read(conversationSectionsProvider).dms.map((c) => c.id), [
      'dm1',
    ]);
    expect(find.byKey(const Key('sidebar-dm-dm1')), findsNothing);

    channelGate.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    // Settled: rows appear, and the default landed on a room and stayed there.
    expect(find.byKey(const Key('sidebar-dm-dm1')), findsOneWidget);
    expect(
      tester.widget<ListTile>(find.byKey(const Key('sidebar-dm-dm1'))).selected,
      isFalse,
    );
  });

  testWidgets('opening the drawer shows the DM peer title', (tester) async {
    setNarrow(tester);
    // The drawer is lazy on a phone, so opening it may be the first time a
    // non-active DM row asks for its roster. What matters to the user is the
    // settled frame: the row is titled by the peer, not by a placeholder or the
    // empty DM channel name.
    final rest = restWithDm();
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    await openConversationDrawer(tester);

    expect(find.text('alice'), findsWidgets);
    expect(find.text('Direct message'), findsNothing);
  });

  testWidgets('a duplicate-only conversation appears once in the drawer', (
    tester,
  ) async {
    setNarrow(tester);
    // The drawer reads the same deduped list as every active-conversation
    // resolver. When the raw [...channels, ...dms] list leaked through, a single
    // DM could draw two rows with one id.
    final rest = FakeRestApi(
      channels: const [Channel(id: 'dm1', name: '', kind: ChannelKind.dm)],
    );
    rest.dms = [dm];
    rest.membersByChannel['dm1'] = roster;
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    expect(container.read(navigableChannelsProvider).length, 1);
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.text('alice'), findsOneWidget); // a plain title instead
    await openConversationDrawer(tester);
    expect(find.byKey(const Key('sidebar-dm-dm1')), findsOneWidget);
    expect(find.byKey(const Key('sidebar-channel-dm1')), findsNothing);
  });

  testWidgets('a conversation vanishing while the drawer is open does not assert', (
    tester,
  ) async {
    setNarrow(tester);
    final rest = restWithDm();
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    container.read(selectedChannelIdProvider.notifier).select('dm1');
    await tester.pumpAndSettle();
    await openConversationDrawer(tester);

    // The DM disappears from under the user's thumb. The drawer is live, not a
    // retained overlay snapshot, so the row should vanish and the pick should
    // self-heal rather than preserving a ghost selection.
    rest.dms = const [];
    container.invalidate(dmsProvider);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The pick self-heals to a real conversation rather than dangling.
    expect(container.read(selectedChannelIdProvider), isNot('dm1'));

    expect(find.text('alice'), findsNothing);
    expect(find.byKey(const Key('sidebar-dm-dm1')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the drawer button opens the conversation list and is full-size', (
    tester,
  ) async {
    setNarrow(tester);
    final container = makeContainer(
      rest: restWithDm(),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    final button = find.byType(DrawerButton);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
      find.text('alice'),
      findsWidgets,
      reason: 'tapping the drawer button must open the conversation list',
    );
  });

  testWidgets('closed drawer rows are NOT in the tree', (tester) async {
    setNarrow(tester);
    final container = makeContainer(
      rest: restWithDm(),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    // The drawer is lazy: non-active rows are not part of the closed phone
    // surface. Opening the drawer is what mounts them.
    expect(find.text('alice'), findsNothing); // the DM (not active)
    expect(find.text('random'), findsNothing); // the other channel (not active)
    expect(find.text('general'), findsOneWidget); // only the ACTIVE row renders

    await openConversationDrawer(tester);
    expect(
      find.text('alice'),
      findsWidgets,
    ); // opening the drawer is what mounts them
  });

  testWidgets('the active muted row carries the mute glyph in the drawer', (
    tester,
  ) async {
    setNarrow(tester);
    final container = makeContainer(
      rest: restWithDm(),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    container.read(selectedChannelIdProvider.notifier).select('dm1');
    container
        .read(mutesProvider.notifier)
        .setConversationMuted('dm1', muted: true, expectUserId: null);
    await tester.pumpAndSettle();

    // The app-bar bell is retired, but the drawer row still names the state
    // wherever the conversation list is visible.
    expect(find.byKey(const Key('appbar-mute-conversation')), findsNothing);
    await openConversationDrawer(tester);
    expect(find.byKey(const Key('sidebar-muted-dm1')), findsOneWidget);
  });

  testWidgets('the section header is NOT selectable', (tester) async {
    setNarrow(tester);
    final container = makeContainer(
      rest: restWithDm(),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    final before = container.read(selectedChannelIdProvider);

    await openConversationDrawer(tester);
    await tester.tap(find.text('Direct messages'));
    await tester.pumpAndSettle();

    // The section label cannot change the selection.
    expect(container.read(selectedChannelIdProvider), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no header when there is no boundary to mark (DMs, no channels)', (
    tester,
  ) async {
    setNarrow(tester);
    // An account with no channels at all, only DMs — the header would sit alone
    // above the whole list, labelling nothing against nothing.
    final rest = restWithDm(chans: const []);
    rest.dms = [dm, const Channel(id: 'dm2', name: '', kind: ChannelKind.dm)];
    rest.membersByChannel['dm2'] = const [
      ChannelMember(
        userId: 'u1',
        role: 'member',
        canPost: true,
        handle: 'me',
        displayName: 'Me',
      ),
      ChannelMember(
        userId: 'u3',
        role: 'member',
        canPost: true,
        handle: 'bob',
        displayName: 'Bob',
      ),
    ];
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    await openConversationDrawer(tester);

    // Both DMs are pickable; the header is not drawn.
    expect(find.text('alice'), findsWidgets);
    expect(find.text('bob'), findsWidgets);
    expect(find.text('Direct messages'), findsNothing);
  });

  testWidgets('the DM drawer row shows unread from a waiting DM', (
    tester,
  ) async {
    setNarrow(tester);
    final transport = FakeChatTransport();
    final container = makeContainer(rest: restWithDm(), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    // Drive `connected` so the history fence settles and first-sight baselining
    // unblocks (mirrors channel_unread_test) — an unread count is meaningless
    // until the client knows what it had already seen.
    await signIn(tester);
    transport.emitConn(ConnectionState.connected);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    // Stand in a channel, then have the DM receive a message from the peer.
    container.read(selectedChannelIdProvider.notifier).select('c1');
    await tester.pumpAndSettle();

    transport.emitMessage(
      Message(
        clientTempId: 'm1',
        id: '01J${'0' * 21}1',
        channelId: 'dm1',
        sender: const MessageSender(
          userId: 'u2',
          kind: SenderKind.human,
          label: 'alice',
        ),
        body: 'hey',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
        deliveryState: DeliveryState.sent,
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    await openConversationDrawer(tester);
    final badge = find.byKey(const Key('sidebar-unread-dm1'));
    expect(badge, findsOneWidget);
    expect(
      tester.widget<UnreadBadge>(badge).count,
      greaterThan(0),
    );
  });

  testWidgets('tapping a badged DM row opens that conversation', (
    tester,
  ) async {
    setNarrow(tester);
    final transport = FakeChatTransport();
    final container = makeContainer(rest: restWithDm(), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    transport.emitConn(ConnectionState.connected);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    container.read(selectedChannelIdProvider.notifier).select('c1');
    await tester.pumpAndSettle();

    transport.emitMessage(
      Message(
        clientTempId: 'm1',
        id: '01J${'0' * 21}1',
        channelId: 'dm1',
        sender: const MessageSender(
          userId: 'u2',
          kind: SenderKind.human,
          label: 'alice',
        ),
        body: 'hey',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
        deliveryState: DeliveryState.sent,
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    await openConversationDrawer(tester);
    expect(find.byKey(const Key('sidebar-unread-dm1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('sidebar-dm-dm1')));
    await tester.pumpAndSettle();

    expect(container.read(selectedChannelIdProvider), 'dm1');
    expect(find.text('hey'), findsOneWidget);
  });

  testWidgets('a PEER-muted DM renders muted in the drawer (peer-aware, like the '
      'sidebar row)', (tester) async {
    setNarrow(tester);
    final container = makeContainer(
      rest: restWithDm(),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    // Mute the PERSON, not the conversation — only a peer-aware read sees this.
    container
        .read(mutesProvider.notifier)
        .setUserMuted('u2', muted: true, expectUserId: null);
    await tester.pumpAndSettle();

    await openConversationDrawer(tester);

    // `mutedChannelIdsProvider` alone would answer "not muted" here, and the row
    // would render identically to an idle one (cage-match #135 round 7, Tesla).
    expect(find.byKey(const Key('sidebar-muted-dm1')), findsOneWidget);
  });
}
