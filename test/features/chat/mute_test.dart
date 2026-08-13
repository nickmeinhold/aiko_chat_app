// Mute — "show me the messages, stop demanding my attention".
//
// The whole point of these tests is the line between MUTE and BLOCK: a block
// hides content (server-enforced, mutual); a mute only silences the unread
// badge, and every message stays visible on screen. If a mute ever removes a
// message, that is the bug these lock against.
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/application/mute_controller.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/mute_store.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart'
    show ConnectionState;
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/channel_member.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  // testPrefs is shared for the whole suite — drop any mute/read state a prior
  // test wrote so each case starts from a clean slate.
  setUp(() async {
    for (final k in testPrefs
        .getKeys()
        .where((k) =>
            k.startsWith('aiko_muted_') ||
            k.startsWith('aiko_channel_lastread_'))
        .toList()) {
      await testPrefs.remove(k);
    }
  });

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

  const twoChannels = [
    Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
    Channel(id: 'c2', name: 'random', kind: ChannelKind.standard),
  ];

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  void setWide(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  // ── The store: per-user, injective, order-preserving ────────────────────────

  Map<MuteTarget, Set<String>> snapshot({
    Set<String> channels = const {},
    Set<String> users = const {},
  }) =>
      {MuteTarget.channel: channels, MuteTarget.user: users};

  group('MuteStore', () {
    test('keyspace is injective across ids containing "_"', () async {
      final store = MuteStore(testPrefs);
      // Under a flat `<userId>_<targetId>` key these would collide.
      await store.replaceAll('a', snapshot(channels: {'b_c'}));
      await store.replaceAll('a_b', snapshot(channels: {'c'}));

      expect(store.readAll('a')[MuteTarget.channel], {'b_c'});
      expect(store.readAll('a_b')[MuteTarget.channel], {'c'});
    });

    test('channel and user mutes are independent id spaces', () async {
      final store = MuteStore(testPrefs);
      // The SAME id string muted as a channel must not read back as a muted user
      // — opaque server ids share one alphabet, so the target has to disambiguate.
      await store.replaceAll('u1', snapshot(channels: {'x'}));

      expect(store.readAll('u1')[MuteTarget.channel], {'x'});
      expect(store.readAll('u1')[MuteTarget.user], isEmpty);
    });

    test('unmute persists as an absence, and a corrupt payload reads empty',
        () async {
      final store = MuteStore(testPrefs);
      await store.replaceAll('u1', snapshot(users: {'noisy'}));
      await store.replaceAll('u1', snapshot());
      expect(store.readAll('u1')[MuteTarget.user], isEmpty);

      await testPrefs.setString('aiko_muted_u2', 'not json at all');
      expect(store.readAll('u2')[MuteTarget.user], isEmpty);
      expect(store.readAll('u2')[MuteTarget.channel], isEmpty);
    });

    test('a write persists the FULL snapshot, so a failed write self-heals',
        () async {
      // The regression this locks: a read-modify-write would rebuild the payload
      // from DISK, so if mute A never landed, a later mute B would persist a
      // world in which A does not exist — A silently evaporating at next login
      // even though the session showed it. Writing the caller's whole map means
      // the next write always carries the complete truth.
      final store = MuteStore(testPrefs);
      // Simulate "A never reached disk": memory holds A + B, disk holds nothing.
      expect(store.readAll('u1')[MuteTarget.channel], isEmpty);
      await store.replaceAll('u1', snapshot(channels: {'A', 'B'}));

      final onDisk = store.readAll('u1');
      expect(onDisk[MuteTarget.channel], {'A', 'B'},
          reason: 'the later write must carry A, not just the delta B');
    });
  });

  // ── The effect: the badge goes quiet, the messages do NOT ───────────────────

  testWidgets('muting a channel silences its badge; unmuting restores the count',
      (tester) async {
    setWide(tester);
    final transport = FakeChatTransport();
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    transport.emitConn(ConnectionState.connected);
    await settle(tester);

    transport.emitMessage(inbound('c2', ulid('0A'), 'u2', 'noise'));
    await settle(tester);
    expect(container.read(channelUnreadCountProvider('c2')), 1);
    expect(find.byKey(const Key('sidebar-unread-c2')), findsOneWidget);

    container.read(mutesProvider.notifier).setMuted(
        MuteTarget.channel, 'c2', muted: true);
    await settle(tester);

    expect(container.read(channelUnreadCountProvider('c2')), 0);
    expect(find.byKey(const Key('sidebar-unread-c2')), findsNothing);

    // Unmuting does NOT lose the history — the count returns, it was never
    // "marked read" behind the user's back.
    container.read(mutesProvider.notifier).setMuted(
        MuteTarget.channel, 'c2', muted: false);
    await settle(tester);
    expect(container.read(channelUnreadCountProvider('c2')), 1);
  });

  testWidgets('a channel muted BEFORE first sight does not flood on unmute',
      (tester) async {
    // The trap: returning 0 early for a muted channel would skip first-sight
    // baselining, leaving no watermark — so unmuting later would count every
    // fossil in the cache as unread.
    setWide(tester);
    // PLANT REAL HISTORY BELOW THE FENCE, before the channel is ever observed.
    // An earlier version of this test emitted a single LIVE message and called it
    // a flood — which would have passed even if baselining were skipped entirely,
    // because with no fossils present "count everything" and "count what arrived
    // since" give the same answer (cage-match #135 round 2, Tesla).
    final cache = DriftCache(NativeDatabase.memory());
    addTearDown(cache.close);
    await cache.upsertInbound(inbound('c2', ulid('01'), 'u2', 'fossil-1'));
    await cache.upsertInbound(inbound('c2', ulid('03'), 'u2', 'fossil-2'));
    await cache.upsertInbound(inbound('c2', ulid('05'), 'u2', 'fossil-3'));
    await cache.advanceHistoryContiguous('c2', ulid('05'));

    final transport = FakeChatTransport();
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels),
        transport: transport,
        cache: cache);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    container.read(mutesProvider.notifier).setMuted(
        MuteTarget.channel, 'c2', muted: true);
    transport.emitConn(ConnectionState.connected);
    await settle(tester);

    // One genuinely NEW message, above the fence.
    await cache.upsertInbound(inbound('c2', ulid('09'), 'u2', 'live'));
    await settle(tester);

    container.read(mutesProvider.notifier).setMuted(
        MuteTarget.channel, 'c2', muted: false);
    await settle(tester);

    // EXACTLY the live one. If muting had short-circuited before the baseline,
    // c2 would have no watermark and all four (3 fossils + 1 live) would count.
    expect(container.read(channelUnreadCountProvider('c2')), 1);
  });

  testWidgets('muting an account silences it EVERYWHERE, messages still render',
      (tester) async {
    setWide(tester);
    final transport = FakeChatTransport();
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    transport.emitConn(ConnectionState.connected);
    await settle(tester);

    container.read(mutesProvider.notifier).setMuted(
        MuteTarget.user, 'u2', muted: true);

    // The muted account posts in the ACTIVE channel and a non-active one; a
    // different account posts too.
    transport.emitMessage(inbound('c1', ulid('0A'), 'u2', 'muted-here'));
    transport.emitMessage(inbound('c2', ulid('0B'), 'u2', 'muted-there'));
    transport.emitMessage(inbound('c2', ulid('0C'), 'u3', 'someone else'));
    await settle(tester);

    // Only the unmuted sender's message counts — one mute, every channel.
    expect(container.read(channelUnreadCountProvider('c2')), 1);

    // THE line between mute and block: the muted user's message is still on
    // screen in the channel we're reading.
    expect(find.text('muted-here'), findsOneWidget);
  });

  testWidgets('a sidebar row offers Mute on long-press and shows a muted glyph',
      (tester) async {
    setWide(tester);
    final transport = FakeChatTransport();
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    transport.emitConn(ConnectionState.connected);
    await settle(tester);

    // Unread on the non-active channel, badged.
    transport.emitMessage(inbound('c2', ulid('0A'), 'u2', 'noise'));
    await settle(tester);
    expect(find.byKey(const Key('sidebar-unread-c2')), findsOneWidget);
    expect(find.byKey(const Key('sidebar-muted-c2')), findsNothing);

    await tester.longPress(find.byKey(const Key('sidebar-channel-c2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mute'));
    await settle(tester);

    // The badge is gone and the row says WHY it is quiet — muted, not idle.
    expect(container.read(mutedChannelIdsProvider), contains('c2'));
    expect(find.byKey(const Key('sidebar-unread-c2')), findsNothing);
    expect(find.byKey(const Key('sidebar-muted-c2')), findsOneWidget);

    // ...and the same gesture unmutes.
    await tester.longPress(find.byKey(const Key('sidebar-channel-c2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unmute'));
    await settle(tester);
    expect(container.read(mutedChannelIdsProvider), isEmpty);
    expect(find.byKey(const Key('sidebar-unread-c2')), findsOneWidget);
  });

  testWidgets('NARROW: the app bar can mute the conversation being read',
      (tester) async {
    // Narrow has no sidebar, so without this the capability would be wide-only —
    // mutable on the desktop, unreachable on the phone, which is where a noisy
    // channel is actually felt.
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    final action = find.byKey(const Key('appbar-mute-conversation'));
    expect(action, findsOneWidget);
    expect(container.read(mutedChannelIdsProvider), isEmpty);

    await tester.tap(action);
    await settle(tester);
    // c1 is the active conversation (nothing picked → first channel resolves).
    expect(container.read(mutedChannelIdsProvider), contains('c1'));

    // The same control unmutes — the icon carries the state, so it is never a
    // one-way door.
    await tester.tap(action);
    await settle(tester);
    expect(container.read(mutedChannelIdsProvider), isEmpty);
  });

  testWidgets('BOTH mute targets reach disk, per-account, and survive a reload',
      (tester) async {
    setWide(tester);
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    final me = container.read(currentUserProvider)!.userId;
    container.read(mutesProvider.notifier)
      ..setMuted(MuteTarget.channel, 'c2', muted: true)
      ..setMuted(MuteTarget.user, 'u2', muted: true);
    await settle(tester);
    expect(container.read(mutedChannelIdsProvider), contains('c2'));
    expect(container.read(mutedUserIdsProvider), contains('u2'));

    // Actually READ IT BACK OFF DISK rather than trusting the in-memory notifier
    // — the earlier version of this test asserted only the live provider, so its
    // name ("reload from disk") promised a durability guarantee the body never
    // exercised (cage-match #135, Tesla). BOTH targets, since only `channel` was
    // covered before.
    final store = container.read(muteStoreProvider);
    final onDisk = store.readAll(me);
    expect(onDisk[MuteTarget.channel], contains('c2'));
    expect(onDisk[MuteTarget.user], contains('u2'));

    // Another account's store is untouched by this user's mutes.
    expect(store.readAll('someone-else')[MuteTarget.channel], isEmpty);
    expect(store.readAll('someone-else')[MuteTarget.user], isEmpty);
  });

  testWidgets('a DM whose PEER is account-muted shows the muted glyph, not idle',
      (tester) async {
    setWide(tester);
    const dm = Channel(id: 'dm1', name: '', kind: ChannelKind.dm);
    final rest = FakeRestApi(channels: twoChannels);
    rest.dms = [dm];
    rest.membersByChannel['dm1'] = const [
      ChannelMember(
          userId: 'u1', role: 'member', canPost: true, handle: 'me', displayName: 'Me'),
      ChannelMember(
          userId: 'u2', role: 'member', canPost: true, handle: 'alice', displayName: 'Alice'),
    ];
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sidebar-muted-dm1')), findsNothing);

    // Mute the PERSON, not the conversation. A 1:1 DM has exactly one other
    // party, so this silences the row completely — and it must SAY so rather
    // than looking like a conversation where nothing is happening.
    container
        .read(mutesProvider.notifier)
        .setMuted(MuteTarget.user, 'u2', muted: true);
    await settle(tester);

    expect(find.byKey(const Key('sidebar-muted-dm1')), findsOneWidget);
  });

  testWidgets('a peer-muted DM offers UNMUTE, and unmuting clears the real cause',
      (tester) async {
    // The row's glyph is (conversation OR peer), but the menu used to toggle the
    // conversation only — so a peer-muted DM showed the bell AND offered "Mute",
    // stacking a second mute that did nothing visible, while "unmute" left the
    // bell ringing. Row and control disagreeing about the same conversation
    // (cage-match #135 round 3, Tesla).
    setWide(tester);
    const dm = Channel(id: 'dm1', name: '', kind: ChannelKind.dm);
    final rest = FakeRestApi(channels: twoChannels);
    rest.dms = [dm];
    rest.membersByChannel['dm1'] = const [
      ChannelMember(
          userId: 'u1', role: 'member', canPost: true, handle: 'me', displayName: 'Me'),
      ChannelMember(
          userId: 'u2', role: 'member', canPost: true, handle: 'alice', displayName: 'Alice'),
    ];
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    container
        .read(mutesProvider.notifier)
        .setMuted(MuteTarget.user, 'u2', muted: true);
    await settle(tester);
    expect(find.byKey(const Key('sidebar-muted-dm1')), findsOneWidget);

    // The menu must offer to UNDO the silence, not to add to it.
    await tester.longPress(find.byKey(const Key('sidebar-dm-dm1')));
    await tester.pumpAndSettle();
    expect(find.text('Mute'), findsNothing);
    await tester.tap(find.text('Unmute'));
    await settle(tester);

    // ...and it cleared the ACCOUNT mute — the actual cause — so the row is
    // audible again rather than still bearing a glyph it cannot shed.
    expect(container.read(mutedUserIdsProvider), isNot(contains('u2')));
    expect(find.byKey(const Key('sidebar-muted-dm1')), findsNothing);
  });

  testWidgets('a write bound to one account is DROPPED if the session changed',
      (tester) async {
    // Undo lives on a SnackBar owned above the chat surface, so it can be tapped
    // after a logout/user switch. `setMuted` resolves the principal from LIVE
    // auth, so without a binding that late write lands in whoever is signed in
    // now (cage-match #135 round 3, Tesla). Fail closed: a dropped unmute is a
    // badge the user can see; a write into another account is invisible.
    setWide(tester);
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    container.read(mutesProvider.notifier).setMuted(
        MuteTarget.channel, 'c2',
        muted: true, expectUserId: 'somebody-else');
    await settle(tester);
    expect(container.read(mutedChannelIdsProvider), isEmpty,
        reason: 'a write bound to a different principal must not apply');

    // The same call bound to the ACTUAL signed-in user does apply.
    final me = container.read(currentUserProvider)!.userId;
    container.read(mutesProvider.notifier).setMuted(
        MuteTarget.channel, 'c2',
        muted: true, expectUserId: me);
    await settle(tester);
    expect(container.read(mutedChannelIdsProvider), contains('c2'));
  });

  testWidgets('NARROW: unmuting a PERSON from the conversation control discloses '
      'its real scope instead of doing it silently', (tester) async {
    // A one-tap control captioned "this conversation" must not quietly make an
    // account audible in every room (cage-match #135 round 4, Carnot + Tesla).
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const dm = Channel(id: 'dm1', name: '', kind: ChannelKind.dm);
    final rest = FakeRestApi(channels: twoChannels);
    rest.dms = [dm];
    rest.membersByChannel['dm1'] = const [
      ChannelMember(
          userId: 'u1', role: 'member', canPost: true, handle: 'me', displayName: 'Me'),
      ChannelMember(
          userId: 'u2', role: 'member', canPost: true, handle: 'alice', displayName: 'Alice'),
    ];
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    container.read(selectedChannelIdProvider.notifier).select('dm1');
    container
        .read(mutesProvider.notifier)
        .setMuted(MuteTarget.user, 'u2', muted: true);
    await settle(tester);

    await tester.tap(find.byKey(const Key('appbar-mute-conversation')));
    await tester.pumpAndSettle();

    // The tap DISCLOSES rather than acts: the account mute is still in place...
    expect(container.read(mutedUserIdsProvider), contains('u2'));
    expect(find.textContaining('This person is muted in every conversation'), findsOneWidget);

    // ...and only the explicit choice clears it.
    await tester.tap(find.text('Unmute').last);
    await settle(tester);
    expect(container.read(mutedUserIdsProvider), isNot(contains('u2')));
  });

  testWidgets('the disclosure fires when BOTH causes are muted, not just peer-only',
      (tester) async {
    // Gating the confession on "peer AND NOT conversation" left the both-muted
    // case saying "unmute this conversation" while also restoring that account
    // everywhere — the silent global act the disclosure exists to prevent, hiding
    // one flag away (cage-match #135 round 5, Tesla).
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const dm = Channel(id: 'dm1', name: '', kind: ChannelKind.dm);
    final rest = FakeRestApi(channels: twoChannels);
    rest.dms = [dm];
    rest.membersByChannel['dm1'] = const [
      ChannelMember(
          userId: 'u1', role: 'member', canPost: true, handle: 'me', displayName: 'Me'),
      ChannelMember(
          userId: 'u2', role: 'member', canPost: true, handle: 'alice', displayName: 'Alice'),
    ];
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();
    container.read(selectedChannelIdProvider.notifier).select('dm1');
    container.read(mutesProvider.notifier)
      ..setMuted(MuteTarget.user, 'u2', muted: true)
      ..setMuted(MuteTarget.channel, 'dm1', muted: true);
    await settle(tester);

    await tester.tap(find.byKey(const Key('appbar-mute-conversation')));
    await tester.pumpAndSettle();

    expect(find.textContaining('This person is muted in every conversation'), findsOneWidget,
        reason: 'both causes muted must still disclose the account-wide effect');
    expect(container.read(mutedUserIdsProvider), contains('u2'));
  });

  testWidgets('published mute sets are unmodifiable (no back door past the store)',
      (tester) async {
    // The provider type is `Set<String>`, which invites direct mutation — that
    // would update the UI while never reaching disk and never notifying
    // Riverpod (cage-match #135, Carnot). Freezing makes it throw instead.
    setWide(tester);
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    expect(() => container.read(mutedChannelIdsProvider).add('c2'),
        throwsUnsupportedError);
    expect(() => container.read(mutedUserIdsProvider).add('u2'),
        throwsUnsupportedError);
  });
}
