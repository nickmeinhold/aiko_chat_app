import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart'
    show ConnectionState;
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/presentation/channel_sidebar.dart';
import 'package:aiko_chat_app/features/chat/presentation/chat_message_pane.dart';
import 'package:aiko_chat_app/features/chat/presentation/chat_screen.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

/// The responsive chat shell: a Slack/Element-style left rail on WIDE screens,
/// collapsing to the shipped phone app-bar-dropdown layout on NARROW screens.
///
/// The load-bearing property under test is Option A — the body is ALWAYS a Row
/// whose LAST child is the shared [ChatMessagePane], so resizing across the
/// breakpoint reuses the pane's Element + State (scroll position + composer
/// draft survive the resize) rather than remounting it.
void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  // testPrefs is shared for the whole suite; drop any read-state a prior test
  // wrote so unread baselines start clean.
  setUp(() async {
    for (final k in testPrefs
        .getKeys()
        .where((k) => k.startsWith('aiko_channel_lastread_'))
        .toList()) {
      await testPrefs.remove(k);
    }
  });

  const twoChannels = [
    Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
    Channel(id: 'c2', name: 'random', kind: ChannelKind.standard),
  ];

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

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  /// Pin a viewport width and reset it at teardown.
  void setWidth(WidgetTester tester, double width) {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  const wide = 1000.0; // ≥ kWideLayoutBreakpoint (720)
  const narrow = 400.0; // < kWideLayoutBreakpoint

  testWidgets('narrow: app-bar dropdown switcher, no sidebar', (tester) async {
    setWidth(tester, narrow);
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels),
        transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    expect(find.byType(ChatSidebar), findsNothing);
    // The phone layout keeps the app-bar dropdown when >1 channel.
    expect(find.byType(DropdownButton<String>), findsOneWidget);
    expect(find.byType(ChatMessagePane), findsOneWidget);
    // Settings/logout stay in the app bar on narrow.
    expect(find.byIcon(Icons.logout), findsOneWidget);
    // Search is reachable on narrow (app-bar icon).
    expect(find.byIcon(Icons.search), findsOneWidget);
  });

  testWidgets('wide: sidebar with channel rows, no app-bar dropdown',
      (tester) async {
    setWidth(tester, wide);
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels),
        transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    expect(find.byType(ChatSidebar), findsOneWidget);
    expect(find.byType(ChatMessagePane), findsOneWidget);
    // The app-bar dropdown is GONE on wide — channels live in the rail.
    expect(find.byType(DropdownButton<String>), findsNothing);
    // Channel rows rendered in the sidebar.
    expect(find.byKey(const Key('sidebar-channel-c1')), findsOneWidget);
    expect(find.byKey(const Key('sidebar-channel-c2')), findsOneWidget);
    // Wide has NO app bar and NO channel header — the open channel is shown
    // solely by the highlighted rail tile (the default/first channel selected).
    expect(find.byType(AppBar), findsNothing);
    expect(
      tester.widget<ListTile>(find.byKey(const Key('sidebar-channel-c1'))).selected,
      isTrue,
    );
    expect(
      tester.widget<ListTile>(find.byKey(const Key('sidebar-channel-c2'))).selected,
      isFalse,
    );
    // Search must be reachable on wide too — it lives in the sidebar footer,
    // since the wide layout drops the app bar (regression guard: #118 shipped the
    // icon only in the app bar, which is absent here — caught by live-running).
    expect(find.byIcon(Icons.search), findsOneWidget);
  });

  testWidgets('wide: tapping a sidebar tile swaps the pane (re-keys MessageList)',
      (tester) async {
    setWidth(tester, wide);
    final rest = FakeRestApi(channels: twoChannels);
    final transport = FakeChatTransport();
    final container = makeContainer(rest: rest, transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    // A message lands in the default channel c1.
    await tester.enterText(find.byType(TextField).first, 'in-general');
    await tester.tap(find.byIcon(Icons.send));
    await settle(tester);
    expect(find.text('in-general'), findsOneWidget);
    expect(find.byKey(const ValueKey('c1')), findsOneWidget); // MessageList key

    // Tap the c2 tile in the sidebar (same mutator as the dropdown).
    await tester.tap(find.byKey(const Key('sidebar-channel-c2')));
    await tester.pumpAndSettle();

    // The pane swapped: c1's message is gone, MessageList re-keyed to c2.
    expect(find.text('in-general'), findsNothing);
    expect(find.byKey(const ValueKey('c2')), findsOneWidget);
    expect(container.read(selectedChannelIdProvider), 'c2');
    expect(find.text('No messages yet. Say hello!'), findsOneWidget);
  });

  testWidgets('wide: sidebar unread badge reflects channelUnreadCountProvider',
      (tester) async {
    setWidth(tester, wide);
    final transport = FakeChatTransport();
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    // Sign in AND drive `connected` so the history fence settles and first-sight
    // baselining unblocks (mirrors channel_unread_test).
    await signIn(tester);
    transport.emitConn(ConnectionState.connected);
    await settle(tester);

    // No unread yet on the non-active channel row.
    expect(find.byKey(const Key('sidebar-unread-c2')), findsNothing);

    // Another user posts into the NON-active channel c2.
    transport.emitMessage(inbound('c2', ulid('0A'), 'u2', 'hey there'));
    await settle(tester);

    // The c2 sidebar row now carries an unread badge with count 1; the badge is
    // the shared UnreadBadge, and the count matches the provider directly.
    final badge = find.byKey(const Key('sidebar-unread-c2'));
    expect(badge, findsOneWidget);
    expect(find.descendant(of: badge, matching: find.text('1')), findsOneWidget);
    expect(container.read(channelUnreadCountProvider('c2')), 1);
  });

  testWidgets(
      'Option A: resizing across the breakpoint preserves scroll + draft',
      (tester) async {
    setWidth(tester, wide);
    final rest = FakeRestApi(channels: twoChannels);
    final transport = FakeChatTransport();
    final container = makeContainer(rest: rest, transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    // Overflow the viewport so the list has somewhere to scroll.
    for (var i = 0; i < 25; i++) {
      await tester.enterText(find.byType(TextField).first, 'msg-$i');
      await tester.tap(find.byIcon(Icons.send));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pumpAndSettle();
    }

    final listFinder = find.descendant(
        of: find.byType(MessageList), matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(listFinder).position;
    expect(position.maxScrollExtent, greaterThan(0));

    // Scroll UP to a mid offset — clearly NOT the bottom. A remount would
    // recreate _MessageListState and auto-scroll back to maxScrollExtent, so a
    // preserved mid offset is proof the Element/State survived.
    final target = position.maxScrollExtent / 2;
    position.jumpTo(target);
    await tester.pumpAndSettle();

    // Type a draft but do NOT send — a remount recreates _ComposerState with an
    // empty controller, so a surviving draft is the second proof.
    await tester.enterText(find.byType(TextField).first, 'crossing-draft');
    await tester.pump();

    // Cross DOWN below the breakpoint (macOS window shrink).
    tester.view.physicalSize = const Size(narrow, 900);
    await tester.pumpAndSettle();
    expect(find.byType(ChatSidebar), findsNothing); // collapsed to phone layout

    // State survived the crossing.
    final afterDown = tester
        .state<ScrollableState>(find.descendant(
            of: find.byType(MessageList), matching: find.byType(Scrollable)))
        .position;
    expect(afterDown.pixels, closeTo(target, 1.0),
        reason: 'scroll offset must survive the resize (Option A)');
    expect(find.text('crossing-draft'), findsOneWidget,
        reason: 'composer draft must survive the resize (Option A)');

    // Cross BACK UP above the breakpoint — re-assert.
    tester.view.physicalSize = const Size(wide, 900);
    await tester.pumpAndSettle();
    expect(find.byType(ChatSidebar), findsOneWidget);

    final afterUp = tester
        .state<ScrollableState>(find.descendant(
            of: find.byType(MessageList), matching: find.byType(Scrollable)))
        .position;
    expect(afterUp.pixels, closeTo(target, 1.0));
    expect(find.text('crossing-draft'), findsOneWidget);
  });

  testWidgets('wide: server switcher shows the current server', (tester) async {
    setWidth(tester, wide);
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels),
        transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    // Default gateway is Production (kDefaultGatewayBaseUrl) → its preset label
    // shows in the switcher header.
    expect(find.text('Production'), findsOneWidget);
  });

  testWidgets('wide: server switcher no-op guard on the current server',
      (tester) async {
    setWidth(tester, wide);
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels),
        transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    // Open the switcher menu and pick the ALREADY-current server.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    // 'Production' now appears in both the header and the menu item; tap the
    // menu entry itself (its checkmark padding offsets the label from center).
    await tester.tap(find.ancestor(
        of: find.text('Production'),
        matching: find.byType(CheckedPopupMenuItem<String>)));
    await tester.pumpAndSettle();

    // No confirm dialog — the no-op guard fired with a snackbar instead.
    expect(find.text('Switch server?'), findsNothing);
    expect(find.text('Already connected to this server.'), findsOneWidget);
    // Still logged in on the same gateway.
    expect(container.read(configProvider).httpBaseUrl,
        'https://chat.imagineering.cc');
  });

  testWidgets(
      'wide: server switcher confirm → switchGateway (logs out, flips config)',
      (tester) async {
    setWidth(tester, wide);
    final transport = FakeChatTransport();
    final container = makeContainer(
        rest: FakeRestApi(channels: twoChannels), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    expect(container.read(configProvider).httpBaseUrl,
        'https://chat.imagineering.cc');

    // Open the switcher and pick a DIFFERENT preset (Enspyr).
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.ancestor(
        of: find.text('Enspyr'),
        matching: find.byType(CheckedPopupMenuItem<String>)));
    await tester.pumpAndSettle();

    // The shared confirm dialog appears — confirm the switch.
    expect(find.text('Switch server?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Switch'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // switchGateway ran: the live config flipped to Enspyr and the user is logged
    // out (back at the login screen on the new gateway).
    expect(
        container.read(configProvider).httpBaseUrl, 'https://chat.enspyr.co');
    expect(find.widgetWithText(FilledButton, 'Create a passkey'), findsOneWidget);
  });
}
