import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/test_helpers.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  // These tests exercise the NARROW (phone) layout — the app-bar dropdown
  // switcher and app-bar settings/logout actions. The flutter_test default
  // viewport is 800x600, which is ABOVE kWideLayoutBreakpoint (720) and would
  // render the wide sidebar instead; pin a phone-width viewport so the mobile UX
  // under test is what's rendered. The wide layout has its own suite
  // (responsive_layout_test.dart).
  Future<void> pumpNarrow(
      WidgetTester tester, ProviderContainer container) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpApp(tester, container);
  }

  testWidgets('passkey sign-in → chat screen shows the channel', (tester) async {
    final rest = FakeRestApi();
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);

    expect(rest.passkeyAuthFinishCalls, 1);
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget); // channel name
    expect(find.text('No messages yet. Say hello!'), findsOneWidget);
  });

  testWidgets('composer send → optimistic bubble + wire send', (tester) async {
    final rest = FakeRestApi();
    final transport = FakeChatTransport();
    final container = makeContainer(rest: rest, transport: transport);
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);

    await tester.enterText(find.byType(TextField).first, 'hello world');
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(transport.sent.map((m) => m.body), contains('hello world'));
    expect(find.text('hello world'), findsOneWidget); // optimistic row rendered
  });

  testWidgets('Enter sends; Shift+Enter does not (newline)', (tester) async {
    final transport = FakeChatTransport();
    final container = makeContainer(rest: FakeRestApi(), transport: transport);
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);

    // Shift+Enter must NOT send AND must actually insert a newline. The prior
    // version of this test only asserted "did not send" — which stayed green even
    // when Shift+Enter was a silent no-op (Flutter has no default Shift+Enter →
    // newline mapping; the composer must insert it explicitly). Assert the newline
    // itself so the behaviour the title claims is real (#113 follow-up).
    await tester.enterText(find.byType(TextField).first, 'stay');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(transport.sent.map((m) => m.body), isNot(contains('stay')));
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller!.text, 'stay\n',
        reason: 'Shift+Enter inserts a newline at the caret, not a no-op');

    // A bare Enter sends (physical-keyboard scoped via Focus.onKeyEvent).
    await tester.enterText(find.byType(TextField).first, 'via-enter');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(transport.sent.map((m) => m.body), contains('via-enter'));
  });

  testWidgets('terminal unauthenticated → logged out to login', (tester) async {
    final transport = FakeChatTransport();
    final container = makeContainer(rest: FakeRestApi(), transport: transport);
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);

    transport.emitConn(ConnectionState.unauthenticated);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Create a passkey'),
        findsOneWidget); // back at login
  });

  testWidgets('transient disconnected does NOT log out', (tester) async {
    final transport = FakeChatTransport();
    final container = makeContainer(rest: FakeRestApi(), transport: transport);
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);

    transport.emitConn(ConnectionState.disconnected);
    await tester.pumpAndSettle();

    // Still on chat — a dropped socket is not a logout (auth_error_boundary).
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);
    // The unified NetworkStatusBanner: device online + socket not connected →
    // "Can't reach the server" (superseded the old "Offline — reconnecting…").
    expect(find.text("Can't reach the server"), findsOneWidget);
  });

  testWidgets('REST-terminal logout tears down the transport', (tester) async {
    final transport = FakeChatTransport();
    final container = makeContainer(rest: FakeRestApi(), transport: transport);
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);

    // Simulate a REST refresh-token rejection (DefaultTokenProvider fires
    // onUnauthenticated → authEvents sink). Terminal logout must be a FULL
    // teardown: the socket is disconnected, not just the router redirected.
    container.read(authEventsProvider).add(null);
    await tester.pumpAndSettle();

    expect(transport.disconnectCalls, greaterThanOrEqualTo(1));
    expect(find.widgetWithText(FilledButton, 'Create a passkey'), findsOneWidget);
  });

  testWidgets('logout → different user → no cross-session messages', (tester) async {
    final rest = FakeRestApi();
    final transport = FakeChatTransport();
    final container = makeContainer(rest: rest, transport: transport);
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);

    // User A sends a message into the (in-memory) cache.
    await tester.enterText(find.byType(TextField).first, 'secret-from-A');
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('secret-from-A'), findsOneWidget);

    // Log out, then a DIFFERENT user logs in on the same app instance.
    await tester.tap(find.byIcon(Icons.logout));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Create a passkey'), findsOneWidget);

    rest.user = const AppUser(
        userId: 'u2', username: 'bob', displayName: 'Bob', aikoUsername: 'bob');
    await signIn(tester);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);
    expect(find.text('secret-from-A'), findsNothing); // cache cleared on logout
  });

  testWidgets(
      'channel switcher swaps the message surface and scopes sends per channel',
      (tester) async {
    final rest = FakeRestApi(channels: const [
      Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
      Channel(id: 'c2', name: 'random', kind: ChannelKind.standard),
    ]);
    final transport = FakeChatTransport();
    final container = makeContainer(rest: rest, transport: transport);
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);

    // The switcher opens on the default (first) channel.
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);

    // A send lands in 'general'.
    await tester.enterText(find.byType(TextField).first, 'in-general');
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('in-general'), findsOneWidget);

    // Switch to 'random' via the dropdown.
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('random').last);
    await tester.pumpAndSettle();

    // Now on 'random': general's message is off-screen, empty-state shows. No
    // re-subscribe was needed — the repo already subscribed to both channels.
    expect(find.text('in-general'), findsNothing);
    expect(find.text('No messages yet. Say hello!'), findsOneWidget);

    // A send now targets 'random' (channelId threaded from the active channel).
    await tester.enterText(find.byType(TextField).first, 'in-random');
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('in-random'), findsOneWidget);
    expect(find.text('in-general'), findsNothing);

    // Wire-level: each send carried the ACTIVE channel's id, not just landed in
    // the right cache slice (pins "scopes sends" at the transport, not by proxy).
    expect(transport.sent.firstWhere((m) => m.body == 'in-general').channelId, 'c1');
    expect(transport.sent.firstWhere((m) => m.body == 'in-random').channelId, 'c2');

    // Switch back to 'general': its message is still cached (round-trip).
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('general').last);
    await tester.pumpAndSettle();
    expect(find.text('in-general'), findsOneWidget);
    expect(find.text('in-random'), findsNothing);
  });

  testWidgets('a picked channel that disappears clears the pick and never snaps back',
      (tester) async {
    final rest = FakeRestApi(channels: const [
      Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
      Channel(id: 'c2', name: 'random', kind: ChannelKind.standard),
    ]);
    final container =
        makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);

    // Pick 'random'.
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('random').last);
    await tester.pumpAndSettle();
    expect(container.read(selectedChannelIdProvider), 'c2');

    // 'random' leaves the roster; the channel list refetches.
    rest.channels = const [
      Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
    ];
    container.refresh(channelsProvider);
    await tester.pumpAndSettle();

    // The stale pick was CLEARED (not merely display-masked by _resolveActive) —
    // this is the ref.listen/clear() write-back under test.
    expect(container.read(selectedChannelIdProvider), isNull);
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);

    // 'random' returns — the user must NOT be yanked back to a pick they never
    // re-made. (Fails if clear() is a no-op: the stale 'c2' would re-resolve.)
    rest.channels = const [
      Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
      Channel(id: 'c2', name: 'random', kind: ChannelKind.standard),
    ];
    container.refresh(channelsProvider);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);
  });

  testWidgets('an unsent draft does not bleed across a channel switch',
      (tester) async {
    final rest = FakeRestApi(channels: const [
      Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
      Channel(id: 'c2', name: 'random', kind: ChannelKind.standard),
    ]);
    final container =
        makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);

    // Type a draft in 'general' but do NOT send it.
    await tester.enterText(find.byType(TextField).first, 'draft-for-general');
    await tester.pump();

    // Switch to 'random'.
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('random').last);
    await tester.pumpAndSettle();

    // The composer is fresh — the general draft did not ride into 'random'
    // (Composer is keyed by channel id). Fails if the draft carries over.
    expect(find.text('draft-for-general'), findsNothing);
  });

  testWidgets('channel pick resets across logout (no cross-session selection leak)',
      (tester) async {
    final rest = FakeRestApi(channels: const [
      Channel(id: 'c1', name: 'general', kind: ChannelKind.standard),
      Channel(id: 'c2', name: 'random', kind: ChannelKind.standard),
    ]);
    final container =
        makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);

    // Pick 'random'.
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('random').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'random'), findsOneWidget);

    // Log out (chat surface unmounts → selectedChannelIdProvider auto-disposes).
    await tester.tap(find.byIcon(Icons.logout));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // Back in: a fresh session lands on the default channel, NOT the prior pick.
    // (Fails if the provider is keep-alive — the 'random' selection would survive.)
    await signIn(tester);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);
  });

  testWidgets('single channel shows a plain title, not a switcher', (tester) async {
    // Default FakeRestApi has one channel → no dropdown affordance.
    final container =
        makeContainer(rest: FakeRestApi(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);

    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing);
  });

  testWidgets('new messages auto-scroll the list to the newest (#42)',
      (tester) async {
    final rest = FakeRestApi();
    final transport = FakeChatTransport();
    final container = makeContainer(rest: rest, transport: transport);
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);

    // Send enough messages through the real composer path to overflow the
    // (600px) test viewport, so the list actually has somewhere to scroll.
    for (var i = 0; i < 20; i++) {
      await tester.enterText(find.byType(TextField).first, 'msg-$i');
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }

    // The list must be sitting at the bottom (newest), not pinned at the top.
    final listFinder = find.descendant(
        of: find.byType(ListView), matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(listFinder).position;
    expect(position.maxScrollExtent, greaterThan(0),
        reason: 'content should overflow the viewport');
    expect(position.pixels, closeTo(position.maxScrollExtent, 1.0),
        reason: 'should be auto-scrolled to the newest message');

    // The newest bubble is rendered (and thus reachable without manual scroll).
    expect(find.text('msg-19'), findsOneWidget);
  });

  testWidgets('scrolled-up reader is NOT yanked to the bottom on new data (#42)',
      (tester) async {
    final rest = FakeRestApi();
    final transport = FakeChatTransport();
    final container = makeContainer(rest: rest, transport: transport);
    addTearDown(container.dispose);

    await pumpNarrow(tester, container);
    await signIn(tester);

    for (var i = 0; i < 20; i++) {
      await tester.enterText(find.byType(TextField).first, 'old-$i');
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }

    // Scroll UP into history (away from the tail).
    final listFinder = find.descendant(
        of: find.byType(ListView), matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(listFinder).position;
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(position.pixels, 0);

    // A new message arrives while the user is reading history.
    await tester.enterText(find.byType(TextField).first, 'fresh');
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();

    // They stay where they were — no yank to the bottom.
    expect(position.pixels, 0,
        reason: 'a reader scrolled up should keep their position');
  });
}
