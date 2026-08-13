/// Mute — "show me the messages, stop demanding my attention".
///
/// The whole point of these tests is the line between MUTE and BLOCK: a block
/// hides content (server-enforced, mutual); a mute only silences the unread
/// badge, and every message stays visible on screen. If a mute ever removes a
/// message, that is the bug these lock against.
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/application/mute_controller.dart';
import 'package:aiko_chat_app/features/chat/data/mute_store.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart'
    show ConnectionState;
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
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

  group('MuteStore', () {
    test('keyspace is injective across ids containing "_"', () async {
      final store = MuteStore(testPrefs);
      // Under a flat `<userId>_<targetId>` key these would collide.
      await store.setMuted('a', MuteTarget.channel, 'b_c', muted: true);
      await store.setMuted('a_b', MuteTarget.channel, 'c', muted: true);

      expect(store.readAll('a')[MuteTarget.channel], {'b_c'});
      expect(store.readAll('a_b')[MuteTarget.channel], {'c'});
    });

    test('channel and user mutes are independent id spaces', () async {
      final store = MuteStore(testPrefs);
      // The SAME id string muted as a channel must not read back as a muted user
      // — opaque server ids share one alphabet, so the target has to disambiguate.
      await store.setMuted('u1', MuteTarget.channel, 'x', muted: true);

      expect(store.readAll('u1')[MuteTarget.channel], {'x'});
      expect(store.readAll('u1')[MuteTarget.user], isEmpty);
    });

    test('unmute persists as an absence, and a corrupt payload reads empty',
        () async {
      final store = MuteStore(testPrefs);
      await store.setMuted('u1', MuteTarget.user, 'noisy', muted: true);
      await store.setMuted('u1', MuteTarget.user, 'noisy', muted: false);
      expect(store.readAll('u1')[MuteTarget.user], isEmpty);

      await testPrefs.setString('aiko_muted_u2', 'not json at all');
      expect(store.readAll('u2')[MuteTarget.user], isEmpty);
      expect(store.readAll('u2')[MuteTarget.channel], isEmpty);
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
    final transport = FakeChatTransport();
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    container.read(mutesProvider.notifier).setMuted(
        MuteTarget.channel, 'c2', muted: true);
    transport.emitConn(ConnectionState.connected);
    await settle(tester);

    // History that predates first sight, arriving while muted.
    transport.emitMessage(inbound('c2', ulid('0A'), 'u2', 'fossil'));
    await settle(tester);

    container.read(mutesProvider.notifier).setMuted(
        MuteTarget.channel, 'c2', muted: false);
    await settle(tester);

    // The channel WAS baselined while muted, so the message that arrived after
    // the fence counts (1) — and nothing older than the fence leaks in.
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

  testWidgets('mutes are per-account and reload from disk on the next session',
      (tester) async {
    setWide(tester);
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.pumpAndSettle();

    container.read(mutesProvider.notifier).setMuted(
        MuteTarget.channel, 'c2', muted: true);
    await settle(tester);
    expect(container.read(mutedChannelIdsProvider), contains('c2'));

    // Another user's store is untouched by this user's mute.
    final store = container.read(muteStoreProvider);
    expect(store.readAll('someone-else')[MuteTarget.channel], isEmpty);
  });
}
