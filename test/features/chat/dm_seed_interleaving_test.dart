// Probes for Tesla's cage-match #133 round-2 claims. Both are about the window
// between "the island authoritatively minted this DM" and "the DM list agrees",
// which the Message entry point walks through every time (Call hid it by routing
// instead of selecting).
import 'dart:async';

import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show NetworkUnavailable;
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/channel_member.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/presentation/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  const generalChannel = Channel(
    id: 'general',
    name: 'general',
    kind: ChannelKind.standard,
  );
  const dm = Channel(id: 'dm:me:alice', name: '', kind: ChannelKind.dm);
  const roster = [
    ChannelMember(
      userId: 'u1',
      role: 'member',
      canPost: true,
      handle: 'me',
      displayName: 'Me',
    ),
    ChannelMember(
      userId: 'alice-key-opaque',
      role: 'member',
      canPost: true,
      handle: 'alice',
      displayName: 'Alice',
    ),
  ];

  final aliceMsg = Message(
    clientTempId: 'm1',
    id: 'm1',
    channelId: 'general',
    sender: const MessageSender(
      userId: 'alice-key-opaque',
      kind: SenderKind.human,
      label: 'Alice',
    ),
    body: 'hey',
    createdAt: DateTime.utc(2026, 8, 12, 13),
    deliveryState: DeliveryState.sent,
  );

  void setWide(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'the conversation you SELECT is the conversation you are IN, even before '
    'the DM list confirms it',
    (tester) async {
      // Tesla round-2 MEDIUM: `seedOpenedDm` writes last-known and invalidates,
      // but `navigableChannelsProvider` reads dmsProvider's LIVE value — which
      // does not contain the new DM until the refetch settles. If `resolveActive`
      // falls back to the first channel across that window, the composer targets
      // `general` while the user believes they are in the DM. That is a
      // wrong-conversation SEND, not a cosmetic flash — so it is worth wedging the
      // fetch open and looking directly at the active conversation.
      setWide(tester);
      final rest = FakeRestApi(channels: const [generalChannel])
        ..openDmReturns = dm;
      rest.membersByChannel['dm:me:alice'] = roster;
      final transport = FakeChatTransport();
      final container = makeContainer(rest: rest, transport: transport);
      addTearDown(container.dispose);

      await pumpApp(tester, container);
      await signIn(tester);
      await tester.pumpAndSettle();
      transport.emitMessage(aliceMsg);
      await tester.pumpAndSettle();

      // Wedge every SUBSEQUENT listDms open, so the post-seed refetch never
      // settles and we can inspect the window itself.
      final gate = Completer<void>();
      rest.listDmsGate = gate;

      await tester.longPress(find.text('hey'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Message Alice'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      final selected = container.read(selectedChannelIdProvider);
      final active = ChatScreen.resolveActive(
        container.read(navigableChannelsProvider),
        selected,
      );

      gate.complete();
      await tester.pumpAndSettle();

      expect(selected, 'dm:me:alice');
      expect(
        active?.id,
        'dm:me:alice',
        reason:
            'while the refetch is in flight the active conversation must be '
            'the DM we opened, not a fallback channel the composer would send to',
      );
    },
  );

  testWidgets('a SUPERSEDED in-flight DM fetch cannot publish its stale list', (
    tester,
  ) async {
    // Tesla round-2 HIGH. `dmsProvider` awaits `listDms()` and then
    // unconditionally `remember(userId, dms)`. Riverpod discards a superseded
    // run's RETURN value, but a Dart Future cannot be cancelled — so the older
    // run still arrives here and, unguarded, writes its pre-mint list over
    // last-known. The DM vanishes, and the self-heal (nothing loading by then)
    // ejects the selection standing in it.
    //
    // Driven at the provider layer on purpose: wedging the DM fetch stalls the
    // repository, which unmounts the message surface, so a UI-driven version
    // would trip the liveness guard before it could reach the race.
    setWide(tester);
    final rest = FakeRestApi(channels: const [generalChannel]);
    rest.membersByChannel['dm:me:alice'] = roster;
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    // Run A is issued while the island still reports no DMs, and wedges.
    final gate = Completer<void>();
    rest.listDmsGate = gate;
    container.invalidate(dmsProvider);
    await tester.pump();

    // The DM now exists island-side, and a NEWER fetch (run B) is issued — the
    // shape `seedOpenedDm`'s invalidate produces.
    rest.dms = const [dm];
    container.invalidate(dmsProvider);
    await tester.pump();

    // Release both. Run A resolves first, carrying its stale empty snapshot.
    gate.complete();
    await tester.pumpAndSettle();

    expect(
      container.read(dmsProvider).value,
      contains(dm),
      reason: 'the superseded run must not publish a list predating the DM',
    );
    expect(find.byKey(const Key('sidebar-dm-dm:me:alice')), findsOneWidget);

    // And it must not have poisoned last-known either: a LATER failure has to
    // degrade to the list that includes the DM, not to run A's empty one.
    rest.listDmsGate = null;
    rest.listDmsThrows = const NetworkUnavailable();
    container.invalidate(dmsProvider);
    await tester.pumpAndSettle();

    expect(
      container.read(dmsProvider).value,
      contains(dm),
      reason: 'a stale run must not have overwritten the fail-soft fallback',
    );
  });

  testWidgets('a FLAPPING source defers healing but does not starve it — the departed '
      'selection clears on the first settle', (tester) async {
    // The question Carnot asked in every round, answered by running it rather
    // than by argument: with the heal skipping whenever either source is
    // loading, can repeated invalidation before settle keep a genuinely departed
    // selection alive forever?
    //
    // The honest answer this pins: while the flap continues the pick is DEFERRED
    // (and `resolveActive` heals the display meanwhile, so the UI is never wrong
    // — only the notifier lags), and the moment the sources settle it clears.
    // Deferring a bookkeeping fix beats ejecting a selection the user made one
    // frame ago, which is the alternative the guard exists to prevent.
    setWide(tester);
    final rest = FakeRestApi(channels: const [generalChannel]);
    rest.dms = const [dm];
    rest.membersByChannel['dm:me:alice'] = roster;
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sidebar-dm-dm:me:alice')));
    await tester.pumpAndSettle();
    expect(container.read(selectedChannelIdProvider), 'dm:me:alice');

    // The DM departs, and the DM list is now kept permanently mid-flight — the
    // flapping-connectivity shape, where a refresh never gets to settle.
    rest.dms = const [];
    final flap = Completer<void>();
    rest.listDmsGate = flap;
    for (var i = 0; i < 3; i++) {
      container.invalidate(dmsProvider);
      await tester.pump();
    }

    // Deferred, exactly as designed — and the DISPLAY is already healed even
    // though the notifier still holds the pick.
    expect(
      container.read(selectedChannelIdProvider),
      'dm:me:alice',
      reason: 'the guard defers while a source is in flight',
    );

    // The ether quiets: the flap ends and the sources settle.
    flap.complete();
    rest.listDmsGate = null;
    container.invalidate(dmsProvider);
    await tester.pumpAndSettle();

    expect(
      container.read(selectedChannelIdProvider),
      isNull,
      reason: 'healing resumes on the first settle — deferred, never starved',
    );
  });

  testWidgets('DMs-settle-first ordering still heals a departed selection (Tesla r3)', (
    tester,
  ) async {
    // Tesla's round-3 HIGH names completion ORDER as the decider: DM list
    // settles WITHOUT the selected DM while channels is still mid-refresh, the
    // heal skips, then channels settles to an element-equal roster — and if the
    // combined list does not re-notify, the notifier keeps the dead id forever.
    // The stated mechanism ("List.== is deep") does not hold in Dart, but the
    // ORDERING is a real variable my earlier test left to chance, so it gets
    // driven explicitly rather than argued about.
    setWide(tester);
    final rest = FakeRestApi(channels: const [generalChannel]);
    rest.dms = const [dm];
    rest.membersByChannel['dm:me:alice'] = roster;
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sidebar-dm-dm:me:alice')));
    await tester.pumpAndSettle();
    expect(container.read(selectedChannelIdProvider), 'dm:me:alice');

    // Both sources refresh. The DM departs; the channel roster is unchanged, so
    // its settle carries element-equal data — the case Tesla says is silent.
    rest.dms = const [];
    final channelsGate = Completer<void>();
    rest.listChannelsGate = channelsGate;
    container.invalidate(channelsProvider);
    container.invalidate(dmsProvider);
    await tester.pump();

    // DMs settle FIRST, while channels is still in flight → the heal must skip.
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      container.read(selectedChannelIdProvider),
      'dm:me:alice',
      reason: 'skipped while channels is mid-refresh, as designed',
    );

    // Now channels settles to the SAME roster — the claimed-silent transition.
    channelsGate.complete();
    await tester.pumpAndSettle();

    expect(
      container.read(selectedChannelIdProvider),
      isNull,
      reason:
          'an element-equal channels settle must still re-notify, so the '
          'departed DM pick clears rather than becoming a ghost',
    );
  });

  testWidgets('a post-mint fetch that OMITS the DM does not retire the seed (r4)', (
    tester,
  ) async {
    // Carnot round-4 HIGH. Retiring a seed because a fetch merely STARTED after
    // the mint assumes the island lists a DM the instant `POST /v1/dm` returns —
    // an assumption this PR has never verified (#2947 owns the island half). If
    // it lags by one request, the retiring fetch omits the DM and the user is
    // ejected from the conversation they just opened, through eventual
    // consistency rather than a stale refresh. So the seed waits to be NAMED.
    setWide(tester);
    final rest = FakeRestApi(channels: const [generalChannel])
      ..openDmReturns = dm;
    rest.membersByChannel['dm:me:alice'] = roster;
    final transport = FakeChatTransport();
    final container = makeContainer(rest: rest, transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    transport.emitMessage(aliceMsg);
    await tester.pumpAndSettle();

    // The island mints the DM but its list has NOT caught up — `rest.dms` stays
    // empty, so every post-mint fetch succeeds while omitting the new DM.
    await tester.longPress(find.text('hey'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message Alice'));
    await tester.pumpAndSettle();

    expect(
      container.read(selectedChannelIdProvider),
      'dm:me:alice',
      reason: 'a lagging list must not evict the conversation just opened',
    );
    expect(find.byKey(const Key('sidebar-dm-dm:me:alice')), findsOneWidget);

    // Several more successful, still-lagging fetches change nothing.
    for (var i = 0; i < 3; i++) {
      container.invalidate(dmsProvider);
      await tester.pumpAndSettle();
    }
    expect(container.read(selectedChannelIdProvider), 'dm:me:alice');

    // The island catches up: the seed is now redundant and retires, leaving the
    // DM present exactly once (server truth), not duplicated.
    rest.dms = const [dm];
    container.invalidate(dmsProvider);
    await tester.pumpAndSettle();

    expect(
      container
          .read(navigableChannelsProvider)
          .where((c) => c.id == 'dm:me:alice')
          .length,
      1,
      reason: 'a confirmed seed retires rather than double-listing the DM',
    );
    expect(container.read(selectedChannelIdProvider), 'dm:me:alice');
  });

  testWidgets('the sidebar and the message pane agree on which DMs exist', (
    tester,
  ) async {
    // Not a reviewer finding — found while checking one. The sidebar read
    // `dmsProvider` directly while the active-conversation resolver went through
    // `navigableChannelsProvider`, so across the post-mint refresh window the
    // pane showed a DM the sidebar had no row for. Both now read
    // [visibleDmsProvider], so the two cannot disagree.
    setWide(tester);
    final rest = FakeRestApi(channels: const [generalChannel])
      ..openDmReturns = dm;
    rest.membersByChannel['dm:me:alice'] = roster;
    final transport = FakeChatTransport();
    final container = makeContainer(rest: rest, transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    transport.emitMessage(aliceMsg);
    await tester.pumpAndSettle();

    // Wedge the post-mint refetch open and inspect the window itself.
    final gate = Completer<void>();
    rest.listDmsGate = gate;
    await tester.longPress(find.text('hey'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message Alice'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    final active = ChatScreen.resolveActive(
      container.read(navigableChannelsProvider),
      container.read(selectedChannelIdProvider),
    );
    expect(active?.id, 'dm:me:alice');
    expect(
      find.byKey(const Key('sidebar-dm-dm:me:alice')),
      findsOneWidget,
      reason: 'the sidebar must list the DM the pane is already showing',
    );

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a superseded run completing LAST still cannot publish (r5)', (
    tester,
  ) async {
    // Carnot round-5 HIGH: the earlier stale-run test let run A finish FIRST.
    // The untested axis is the reverse — run A (stale) resolving AFTER run B has
    // already published and retired the seed. If Riverpod's discard of a
    // superseded result is anything less than total, A's pre-mint list lands
    // last, `visibleDmsProvider` drops the DM, and the heal clears the
    // selection. Same probe shape, opposite ordering: repeating the first test
    // would prove nothing about this.
    setWide(tester);
    final rest = FakeRestApi(channels: const [generalChannel]);
    rest.membersByChannel['dm:me:alice'] = roster;
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    // Run A: issued while the island reports no DMs, held open.
    final gateA = Completer<void>();
    rest.listDmsGate = gateA;
    container.invalidate(dmsProvider);
    await tester.pump();

    // Run B: issued after the DM exists, held on its OWN gate.
    rest.dms = const [dm];
    final gateB = Completer<void>();
    rest.listDmsGate = gateB;
    container.invalidate(dmsProvider);
    await tester.pump();

    // B lands first and publishes the DM; A lands afterwards with its stale list.
    gateB.complete();
    await tester.pumpAndSettle();
    expect(container.read(visibleDmsProvider), contains(dm));

    gateA.complete();
    await tester.pumpAndSettle();

    expect(
      container.read(visibleDmsProvider),
      contains(dm),
      reason: 'a superseded run must not publish even when it finishes last',
    );
    expect(find.byKey(const Key('sidebar-dm-dm:me:alice')), findsOneWidget);
  });
}
