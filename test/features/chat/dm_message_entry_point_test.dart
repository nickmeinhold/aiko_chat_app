// Acceptance tests for the DM *Message* entry point (#2798).
//
// Before this slice `openDm` had exactly ONE caller — the Call action — so a DM
// could only come into existence as a side effect of placing a video call, and
// Inc 1's whole "Direct messages" section was unreachable for anyone who had
// never called. These tests pin the entry point that fixes that, and the seam it
// is cut along:
//
//   - the long-press sheet offers "Message {name}" on another human's CHANNEL
//     message, and it is HIDDEN inside a DM (where it would be a no-op);
//   - tapping it threads the sender's opaque `userId` (identity=key, ADR-0004 —
//     never a display label) to `openDm`, and SELECTS the returned DM rather
//     than pushing the call route;
//   - a newly-opened DM is SEEDED, so it is navigable + subscribed immediately
//     rather than waiting on (and riding the failure of) the `GET /v1/dm`
//     refetch — the same last-known guarantee the call path already has;
//   - it fails CLOSED on a blocked target and NEVER navigates on an error.
import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/channel_member.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/moderation/application/moderation_controller.dart';
import 'package:aiko_chat_app/features/moderation/presentation/message_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/test_helpers.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  const me = AppUser(
    userId: 'u1',
    username: 'nick',
    displayName: 'Nick',
    aikoUsername: 'nick',
  );

  const generalChannel = Channel(
    id: 'general',
    name: 'general',
    kind: ChannelKind.standard,
  );
  const existingDm = Channel(id: 'dm:me:alice', name: '', kind: ChannelKind.dm);

  Message from(String channelId) => Message(
    clientTempId: 'm1',
    id: 'm1',
    channelId: channelId,
    sender: const MessageSender(
      userId: 'alice-key-opaque',
      kind: SenderKind.human,
      label: 'Alice',
    ),
    body: 'hey',
    createdAt: DateTime.utc(2026, 8, 12, 13),
    deliveryState: DeliveryState.sent,
  );

  /// A minimal surface that opens the long-press sheet for [message]. The
  /// container is returned so a test can read the resulting SELECTION — the
  /// observable this entry point exists to move.
  ({Widget widget, ProviderContainer container}) harness(
    FakeRestApi fake,
    Message message, {
    Set<String> blocked = const {},
    List<Channel> dms = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        restApiProvider.overrideWithValue(fake),
        blockedUserIdsProvider.overrideWithValue(blocked),
        currentUserProvider.overrideWithValue(me),
        channelsProvider.overrideWith((ref) async => const [generalChannel]),
        dmsProvider.overrideWith((ref) async => dms),
      ],
    );
    // Both providers are autoDispose and, in the real app, are kept alive by
    // ChatScreen watching them. This bare harness has no such watcher, so hold
    // subscriptions ourselves — otherwise `select()` writes into a provider that
    // is disposed on the same turn and the assertion reads a fresh `null`.
    container.listen(selectedChannelIdProvider, (_, _) {});
    container.listen(navigableChannelsProvider, (_, _) {});

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showMessageActions(context, ref, message),
                child: const Text('open-actions'),
              ),
            ),
          ),
        ),
        // Stub call route — a marker proving Message did NOT take the call path.
        GoRoute(
          path: '/call/:channelId',
          builder: (context, state) =>
              Scaffold(body: Text('CALL:${state.pathParameters['channelId']}')),
        ),
      ],
    );
    return (
      widget: UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
      container: container,
    );
  }

  testWidgets('Message opens the DM with the sender key and selects it', (
    tester,
  ) async {
    final fake = FakeRestApi()..openDmReturns = existingDm;
    final h = harness(fake, from('general'));
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.widget);

    await tester.tap(find.text('open-actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message Alice'));
    await tester.pumpAndSettle();

    expect(fake.openDmCalls, 1);
    // The opaque key, never the 'Alice' label (identity=key, ADR-0004).
    expect(fake.lastOpenDmTarget, 'alice-key-opaque');
    // The DM is now the active conversation...
    expect(h.container.read(selectedChannelIdProvider), 'dm:me:alice');
    // ...and we did NOT wander into a call.
    expect(find.textContaining('CALL:'), findsNothing);
  });

  // Also the regression anchor for the self-heal window: this test FAILED
  // (selection went null → dm → null) before `ChatScreen`'s heal learned to skip
  // a source that is mid-refresh. Deleting that `isLoading` guard turns this red
  // again, which is the point — the seed's own invalidate is what opens the
  // window, so any DM entry point that seeds walks straight into it.
  testWidgets('end-to-end: long-press → Message seeds the DM, opens it, and the '
      'self-heal does NOT eject it mid-refresh', (tester) async {
    // The real app, the real long-press, and a `GET /v1/dm` that still reports
    // NOTHING — so the DM can only reach the sidebar via the seed. This is the
    // same last-known guarantee the call path has: `openDm`'s answer is
    // authoritative and must not ride on a refetch that may lag or fail soft.
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // `GET /v1/dm` FAILS (soft) throughout, so the DM can reach the sidebar only
    // via the seed — which is exactly the guarantee: `openDm`'s answer is
    // authoritative for that conversation and must not ride on a refetch.
    final rest = FakeRestApi(channels: const [generalChannel])
      ..openDmReturns = existingDm
      ..listDmsThrows = const NetworkUnavailable();
    rest.membersByChannel['dm:me:alice'] = const [
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
    final transport = FakeChatTransport();
    final container = makeContainer(rest: rest, transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    transport.emitMessage(from('general'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('hey'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message Alice'));
    await tester.pumpAndSettle();

    // The DM is in the sidebar (seeded, not fetched) and is the active pick.
    expect(find.byKey(const Key('sidebar-dm-dm:me:alice')), findsOneWidget);
    expect(container.read(selectedChannelIdProvider), 'dm:me:alice');
  });

  testWidgets(
    'messaging someone you ALREADY DM with selects it WITHOUT re-seeding',
    (tester) async {
      // The common path once a conversation exists. `openDm` is idempotent, so
      // this must NOT seed: seeding invalidates dmsProvider, which rebuilds the
      // repository (dispose → reconnect → resubscribe-all). Re-opening a
      // conversation you already have should cost a selection change, nothing more
      // (cage-match #132 Tesla — the same churn argument as the call path).
      final fake = FakeRestApi()..openDmReturns = existingDm;
      final h = harness(fake, from('general'), dms: const [existingDm]);
      addTearDown(h.container.dispose);
      await tester.pumpWidget(h.widget);
      // Let the (overridden) DM list resolve, so `openDm`'s answer is recognised
      // as already-known rather than new.
      await tester.pumpAndSettle();

      await tester.tap(find.text('open-actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Message Alice'));
      await tester.pumpAndSettle();

      expect(h.container.read(selectedChannelIdProvider), 'dm:me:alice');
      // Still exactly one list entry — no duplicate row from a redundant seed.
      expect(
        h.container
            .read(navigableChannelsProvider)
            .where((c) => c.kind == ChannelKind.dm)
            .length,
        1,
      );
    },
  );

  testWidgets('the self-heal still clears a DEPARTED selection — the isLoading guard '
      'defers healing, it does not cancel it', (tester) async {
    // Tesla's cage-match #133 harmonic, run rather than argued: with the heal now
    // skipping a mid-refresh source, does a selection whose DM genuinely departed
    // still get cleared once both sources settle — or does it strand because the
    // sibling source was loading at the one moment the list changed?
    //
    // This is the other half of the guard's contract. The e2e test above proves it
    // does not eject TOO EAGERLY; this proves it still ejects AT ALL.
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final rest = FakeRestApi(channels: const [generalChannel]);
    rest.dms = const [existingDm];
    rest.membersByChannel['dm:me:alice'] = const [
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
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sidebar-dm-dm:me:alice')));
    await tester.pumpAndSettle();
    expect(container.read(selectedChannelIdProvider), 'dm:me:alice');

    // The DM departs server-side (left / blocked / retracted), and BOTH sources
    // refresh together — so each spends time loading while the other changes.
    rest.dms = const [];
    container.invalidate(channelsProvider);
    container.invalidate(dmsProvider);
    await tester.pumpAndSettle();

    expect(
      container.read(selectedChannelIdProvider),
      isNull,
      reason: 'a departed selection must still clear once both sources settle',
    );
    expect(find.byKey(const Key('sidebar-dm-dm:me:alice')), findsNothing);
  });

  testWidgets('a seed that changes nothing does NOT refetch the DM list', (
    tester,
  ) async {
    // Two racing taps (or one tap during a refresh) both read dmsProvider as
    // "not listed" — its value is null → [] mid-refresh — so both call
    // seedOpenedDm. The union is idempotent by id, but the INVALIDATE was not,
    // and each one rebuilds the repository (cage-match #133, Carnot + Tesla).
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final rest = FakeRestApi(channels: const [generalChannel])
      ..openDmReturns = existingDm
      ..listDmsThrows = const NetworkUnavailable();
    rest.membersByChannel['dm:me:alice'] = const [
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
    final transport = FakeChatTransport();
    final container = makeContainer(rest: rest, transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    transport.emitMessage(from('general'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('hey'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message Alice'));
    await tester.pumpAndSettle();
    final listDmsAfterFirst = rest.listDmsCalls;

    // Message the same person again — the DM is already in last-known, so the
    // seed changes nothing and must not trigger another list refetch. (Step back
    // to the channel first: the first Message navigated us INTO the DM, where
    // Alice's channel message is no longer on screen.)
    await tester.tap(find.byKey(const Key('sidebar-channel-general')));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('hey'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message Alice'));
    await tester.pumpAndSettle();

    expect(
      rest.listDmsCalls,
      listDmsAfterFirst,
      reason: 'a no-op seed must not invalidate dmsProvider',
    );
    expect(container.read(selectedChannelIdProvider), 'dm:me:alice');
  });

  testWidgets('Message is HIDDEN inside a DM (it would be a no-op there)', (
    tester,
  ) async {
    final fake = FakeRestApi();
    final h = harness(fake, from('dm:me:alice'), dms: const [existingDm]);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.widget);

    await tester.tap(find.text('open-actions'));
    await tester.pumpAndSettle();

    expect(find.text('Message Alice'), findsNothing);
    // The rest of the sheet is unaffected — you can still call/report/block here.
    expect(find.text('Call Alice'), findsOneWidget);
    expect(find.text('Report message'), findsOneWidget);
  });

  testWidgets('a failed open shows a SnackBar and changes no selection', (
    tester,
  ) async {
    final fake = FakeRestApi()..openDmThrows = const DmTargetNotFound();
    final h = harness(fake, from('general'));
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.widget);

    await tester.tap(find.text('open-actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message Alice'));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't message Alice"), findsOneWidget);
    expect(h.container.read(selectedChannelIdProvider), isNull);
  });

  testWidgets('offline gets its own copy, not a generic retry message', (
    tester,
  ) async {
    final fake = FakeRestApi()..openDmThrows = const NetworkUnavailable();
    final h = harness(fake, from('general'));
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.widget);

    await tester.tap(find.text('open-actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message Alice'));
    await tester.pumpAndSettle();

    expect(find.textContaining("You're offline"), findsOneWidget);
    expect(h.container.read(selectedChannelIdProvider), isNull);
  });

  testWidgets(
    'Message fails closed on a blocked target — no openDm, no select',
    (tester) async {
      final fake = FakeRestApi();
      final h = harness(fake, from('general'), blocked: {'alice-key-opaque'});
      addTearDown(h.container.dispose);
      await tester.pumpWidget(h.widget);

      await tester.tap(find.text('open-actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Message Alice'));
      await tester.pumpAndSettle();

      // Never even asked the island for a room (defence-in-depth on the UGC
      // boundary — the same fail-closed stance the Call path takes).
      expect(fake.openDmCalls, 0);
      expect(find.textContaining("You've blocked Alice"), findsOneWidget);
      expect(h.container.read(selectedChannelIdProvider), isNull);
    },
  );
}
