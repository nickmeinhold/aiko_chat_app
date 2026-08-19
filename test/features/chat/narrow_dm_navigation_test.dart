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
    for (final k in testPrefs
        .getKeys()
        .where((k) =>
            k.startsWith('aiko_channel_lastread_') || k.startsWith('aiko_muted_'))
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
    await tester.tap(find.text('alice'));
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
    await tester.tap(find.text('random'));
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

  // A conversation listed by BOTH island endpoints. The island serves DMs only
  // through GET /v1/dm and excludes them from GET /v1/channels, so this is a
  // contract violation — but it lands in the app bar that IS a phone's whole
  // navigation surface, where a repeat is not a cosmetic duplicate row: two items
  // sharing a `value` trips DropdownButton's exactly-one-match assertion just as
  // surely as zero items do. Deduped once in navigableChannelsProvider, so every
  // consumer gets the same answer (cage-match #136, Kelvin).
  FakeRestApi restWithLeak(ChannelKind leakedKind) {
    final rest = FakeRestApi(channels: [
      const Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
      Channel(id: 'dm1', name: '', kind: leakedKind),
    ]);
    rest.dms = [dm];
    rest.membersByChannel['dm1'] = roster;
    return rest;
  }

  for (final leakedKind in ChannelKind.values) {
    testWidgets(
        'a conversation listed by BOTH sources appears ONCE, whatever kind the '
        'channel list claims (leak kind: ${leakedKind.name})', (tester) async {
      setNarrow(tester);
      final container =
          makeContainer(rest: restWithLeak(leakedKind), transport: FakeChatTransport());
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

      // No assertion, switcher up, and selecting the doubled id resolves cleanly.
      expect(tester.takeException(), isNull);
      expect(find.byType(DropdownButton<String>), findsOneWidget);
      container.read(selectedChannelIdProvider.notifier).select('dm1');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(container.read(selectedChannelIdProvider), 'dm1');
    });
  }

  for (final wrongKind
      in ChannelKind.values.where((k) => k != ChannelKind.dm)) {
    testWidgets(
        'a DM stays in the DM section even when its own kind says otherwise '
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
      final container = makeContainer(rest: rest, transport: FakeChatTransport());
      addTearDown(container.dispose);

      await pumpApp(tester, container);
      await signIn(tester);
      await tester.pumpAndSettle();

      final sections = container.read(conversationSectionsProvider);
      expect(sections.dms.map((c) => c.id), ['dm1']);
      expect(sections.rooms.map((c) => c.id), ['c1', 'c2']);

      // ...and it renders as a DM row: peer-titled, under the header.
      await openMenu(tester);
      expect(find.text('Direct messages'), findsOneWidget);
      expect(find.text('alice'), findsWidgets);
      await tester.tap(find.text('alice'));
      await tester.pumpAndSettle();

      // Once ACTIVE it must stay a DM on every surface. These three used to ask
      // `channel.kind` individually, so a mis-kinded DM was peer-titled in the
      // dropdown and then lost both its title and its peer-aware mute the moment
      // you entered it (cage-match #136, Tesla + Carnot).
      expect(find.text('alice'), findsWidgets); // title, not the empty DM name
      container
          .read(mutesProvider.notifier)
          .setUserMuted('u2', muted: true, expectUserId: null);
      await tester.pumpAndSettle();
      // Peer-aware: only a peer-aware read sees an ACCOUNT mute on this row.
      // The control is the long-press menu now rather than an app-bar button,
      // so the peer-awareness shows up in the menu's own words — which is where
      // it has to be right, since that sentence is what tells you unmuting here
      // would make this person audible everywhere.
      await tester.longPress(find.byKey(const Key('mute-gesture-title')));
      await tester.pumpAndSettle();
      expect(find.textContaining('This person is muted everywhere'),
          findsOneWidget);
      // Close the menu so it cannot leak into a later expectation.
      Navigator.of(tester.element(find.text('Unmute').last)).pop();
      await tester.pumpAndSettle();
    });
  }

  testWidgets('a COLD channel-list failure tells the SAME story at both widths',
      (tester) async {
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
    expect(container.read(conversationSectionsProvider).dms.map((c) => c.id),
        ['dm1']);
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
    await tester.tap(find.text('Already have a passkey? Sign in'));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }

    // DMs are in; channels are not. The repo — which awaits BOTH — is still
    // loading, so nothing conversational may be on screen: no composer to type
    // into, no message list to send from.
    expect(container.read(conversationSectionsProvider).dms.map((c) => c.id),
        ['dm1']);
    expect(container.read(chatRepositoryProvider), isA<AsyncLoading<ChatRepository>>());
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('composer-send')), findsNothing);
    // The BAR is on the same circuit as the pane. Gating only the pane left the
    // app bar titled with the DM and its mute button live over a spinner, so one
    // tap muted a conversation the user had never entered and the default was
    // about to leave (cage-match #136, Tesla).
    expect(find.text('alice'), findsNothing);
    // The conversation control must not exist before the conversation it names
    // is settled. That control is the title's long-press gesture now, so this
    // asks for ITS absence rather than the retired button's.
    expect(find.byKey(const Key('appbar-mute-conversation')), findsNothing);
    expect(
      find.byKey(const Key('mute-gesture-title')),
      findsNothing,
    );

    channelGate.complete();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
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
    await tester.tap(find.text('Already have a passkey? Sign in'));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }

    // DMs are in, channels are not — no row may claim to be the one you are in.
    expect(container.read(conversationSectionsProvider).dms.map((c) => c.id),
        ['dm1']);
    expect(find.byKey(const Key('sidebar-dm-dm1')), findsNothing);

    channelGate.complete();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    // Settled: rows appear, and the default landed on a room and stayed there.
    expect(find.byKey(const Key('sidebar-dm-dm1')), findsOneWidget);
    expect(
      tester.widget<ListTile>(find.byKey(const Key('sidebar-dm-dm1'))).selected,
      isFalse,
    );
  });

  testWidgets('opening the switcher fetches nothing — the DM peer is already '
      'known', (tester) async {
    setNarrow(tester);
    // Written while chasing a reported "the drop-down kind of flickers as it
    // appears", on the theory that the DM row mounts at menu-open, starts its
    // GET /members then, and shows `dmPeerTitle`'s neutral placeholder until it
    // lands. THAT THEORY WAS WRONG, and this test is what disproved it: the
    // roster is already resolved before the menu opens, because the aggregate
    // unread dot reads `channelUnreadCountProvider` for every non-active
    // conversation — including DMs — from the collapsed switcher, which warms the
    // peer-aware mute path and the roster with it. (The real cause was Flutter's
    // DropdownButton staggering its items' fade-in; see task #32.)
    //
    // Kept, because the property is worth holding on its own: no GET /members on
    // the interaction path, so a DM row can never render its placeholder title.
    // A first cut asserted `listMembersCalls > 0` before opening, which passed
    // for the wrong reason — that counter also ticks for the ACTIVE channel.
    final rest = restWithDm();
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    // The discriminating observable is WHEN the roster is fetched, so measure the
    // fetch count across the open. (A first cut asserted `listMembersCalls > 0`
    // before opening and passed against the unfixed code — that counter also
    // ticks for the ACTIVE channel's roster, which the message pane resolves for
    // sender names. It measured something real and irrelevant.)
    final beforeOpen = rest.listMembersCalls;

    await openMenu(tester);

    // Opening the switcher fetched NOTHING: the DM's peer was already known, so
    // the row is peer-titled on the frame it appears instead of relabelling from
    // the placeholder a round-trip later.
    expect(rest.listMembersCalls, beforeOpen,
        reason: 'opening the switcher must not put a GET /members on the '
            'interaction path');
    expect(find.text('alice'), findsWidgets);
    expect(find.text('Direct message'), findsNothing);
  });

  testWidgets('no dropdown-of-one when the duplicate is the ONLY conversation',
      (tester) async {
    setNarrow(tester);
    // The switcher's EXISTENCE gate has to read the same deduped list its ITEMS
    // do. When it read the raw [...channels, ...dms], one conversation listed
    // twice counted as two and drew a switcher over a single item — the chrome
    // this layout explicitly refuses (cage-match #136, Tesla + Carnot).
    final rest = FakeRestApi(channels: const [
      Channel(id: 'dm1', name: '', kind: ChannelKind.dm),
    ]);
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
  });

  testWidgets('a conversation vanishing while the menu is OPEN does not assert',
      (tester) async {
    setNarrow(tester);
    final rest = restWithDm();
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    container.read(selectedChannelIdProvider.notifier).select('dm1');
    await tester.pumpAndSettle();
    await openMenu(tester);

    // The DM disappears from under the user's thumb. `value` and `items` are two
    // currents that must not meet out of phase: they are derived in the SAME
    // build from the SAME list (active comes from navigable, items partition it),
    // so the assertion is unreachable by construction — this pins that rather
    // than leaving it narrated (cage-match #136, Tesla).
    rest.dms = const [];
    container.invalidate(dmsProvider);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The pick self-heals to a real conversation rather than dangling.
    expect(container.read(selectedChannelIdProvider), isNot('dm1'));

    // ...and TAPPING the ghost row must not resurrect it. The overlay is still
    // offering `alice` from the snapshot it took when the menu opened, and
    // `onChanged` runs against the LIVE widget. Writing that dead id back would
    // leave the display healed (resolveActive falls back) while the Notifier
    // stays poisoned — and `ref.listen` would not fire again to clean it, so the
    // user gets yanked into that conversation the moment it is re-minted. Not
    // asserting the tap was the gap: hearing the two currents without throwing
    // the switch (cage-match #136, Tesla).
    final healed = container.read(selectedChannelIdProvider);
    // Assert the ghost is REALLY still on screen before tapping it. Guarding the
    // tap behind an `if` would let this pass vacuously the day the overlay stops
    // retaining the snapshot — a test that skips the branch it exists to exercise.
    expect(find.text('alice'), findsWidgets,
        reason: 'the open overlay should still be offering the retired DM');
    await tester.tap(find.text('alice').last);
    await tester.pumpAndSettle();
    expect(container.read(selectedChannelIdProvider), healed);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapsed, non-active rows are NOT in the tree (so a phone pays '
      'no per-DM roster fetch until the menu opens)', (tester) async {
    setNarrow(tester);
    final container =
        makeContainer(rest: restWithDm(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    // This PR's description originally claimed the opposite — that DropdownButton
    // mounts every item in an IndexedStack, so a collapsed switcher would fetch a
    // roster per DM in the background. All three cage-match reviewers repeated the
    // claim back, which is one instrument's error counted four times rather than
    // corroboration. A throwaway probe refuted it; committing the probe is what
    // stops the folklore reforming the next time someone "remembers" IndexedStack
    // (cage-match #136, Tesla).
    expect(find.text('alice'), findsNothing); // the DM (not active)
    expect(find.text('random'), findsNothing); // the other channel (not active)
    expect(find.text('general'), findsOneWidget); // only the ACTIVE row renders

    await openMenu(tester);
    expect(find.text('alice'), findsWidgets); // opening the menu is what mounts them
  });

  testWidgets('the ACTIVE row carries no mute glyph — the app-bar bell already '
      'states it', (tester) async {
    setNarrow(tester);
    final container =
        makeContainer(rest: restWithDm(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    container.read(selectedChannelIdProvider.notifier).select('dm1');
    container
        .read(mutesProvider.notifier)
        .setConversationMuted('dm1', muted: true, expectUserId: null);
    await tester.pumpAndSettle();

    // The collapsed DropdownButton renders the ACTIVE item inside the app bar,
    // inches from _MuteConversationAction — which shows the same mute AND is the
    // control that changes it. Two glyphs for one fact, one of them a decoy that
    // merely opens a menu.
    expect(find.byKey(const Key('muted-item-dm1')), findsNothing);
    // The app-bar BELL is retired, but the state it carried is not: the title
    // itself now wears the mute glyph, so a silenced conversation still cannot
    // be mistaken for a quiet one on a phone.
    expect(find.byKey(const Key('appbar-mute-conversation')), findsNothing);
    expect(find.byIcon(Icons.notifications_off), findsOneWidget);
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
