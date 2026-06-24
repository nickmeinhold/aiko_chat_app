// Acceptance tests for the B-UI app-shell + chat screen (task #39).
//
// These drive the REAL provider graph (router, auth controller, repository,
// message stream) with the data layer faked at the interface seam — so they
// exercise the wiring, not the fakes. The trust-boundary cases are the point:
//   - a terminal `unauthenticated` logs out;
//   - a transient `disconnected` does NOT (the auth_error_boundary invariant).

import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart';
import 'package:aiko_chat_app/main.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_transport.dart';
import 'support/fakes.dart';
import 'support/ui_fakes.dart';

/// Build a container wiring the real graph to faked seams. The token provider
/// is a real [DefaultTokenProvider] over an in-memory store (so login actually
/// persists tokens), but its refresh never hits the network.
ProviderContainer makeContainer({
  required FakeRestApi rest,
  required FakeChatTransport transport,
  InMemoryTokenStore? store,
}) {
  final tokenStore = store ?? InMemoryTokenStore();
  late final ProviderContainer container;
  container = ProviderContainer(overrides: [
    restApiProvider.overrideWithValue(rest),
    transportProvider.overrideWithValue(transport),
    tokenProviderProvider.overrideWithValue(DefaultTokenProvider(
      store: tokenStore,
      remoteRefresh: (_) async => 'access2',
      onUnauthenticated: () => container.read(authEventsProvider).add(null),
    )),
    // The real cacheProvider is now file-backed via path_provider, which has no
    // platform channel under flutter_test. Widget tests get an in-memory cache —
    // they exercise the UI wiring, not on-disk persistence (that's covered by
    // cache_persistence_test.dart).
    cacheProvider.overrideWith((ref) => DriftCache(NativeDatabase.memory())),
  ]);
  return container;
}

Future<void> pumpApp(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const AikoChatApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// Drive the login form to the chat screen. Assumes a logged-out start.
Future<void> signIn(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).at(0), 'nick');
  await tester.enterText(find.byType(TextField).at(1), 'hunter2');
  await tester.tap(find.byType(FilledButton));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('logged out → login screen', (tester) async {
    final container = makeContainer(rest: FakeRestApi(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);

    expect(find.widgetWithText(AppBar, 'Sign in'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2)); // username + password
  });

  testWidgets('login → chat screen shows the channel', (tester) async {
    final rest = FakeRestApi();
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    expect(rest.loginCalls, 1);
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget); // channel name
    expect(find.text('No messages yet. Say hello!'), findsOneWidget);
  });

  testWidgets('composer send → optimistic bubble + wire send', (tester) async {
    final rest = FakeRestApi();
    final transport = FakeChatTransport();
    final container = makeContainer(rest: rest, transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    // Gestures run in the fake-async test zone; the optimistic send then writes
    // to the real drift cache and re-streams — real async the fake zone won't
    // drive, so let it complete on the real loop before settling the UI.
    await tester.enterText(find.byType(TextField).first, 'hello world');
    await tester.tap(find.byIcon(Icons.send));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(transport.sent.map((m) => m.body), contains('hello world'));
    expect(find.text('hello world'), findsOneWidget); // optimistic row rendered
  });

  testWidgets('terminal unauthenticated → logged out to login', (tester) async {
    final transport = FakeChatTransport();
    final container = makeContainer(rest: FakeRestApi(), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);

    transport.emitConn(ConnectionState.unauthenticated);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Sign in'), findsOneWidget); // back at login
  });

  testWidgets('transient disconnected does NOT log out', (tester) async {
    final transport = FakeChatTransport();
    final container = makeContainer(rest: FakeRestApi(), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    transport.emitConn(ConnectionState.disconnected);
    await tester.pumpAndSettle();

    // Still on chat — a dropped socket is not a logout (auth_error_boundary).
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);
    expect(find.text('Offline — reconnecting…'), findsOneWidget);
  });

  testWidgets('REST-terminal logout tears down the transport', (tester) async {
    final transport = FakeChatTransport();
    final container = makeContainer(rest: FakeRestApi(), transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);

    // Simulate a REST refresh-token rejection (DefaultTokenProvider fires
    // onUnauthenticated → authEvents sink). Terminal logout must be a FULL
    // teardown: the socket is disconnected, not just the router redirected.
    container.read(authEventsProvider).add(null);
    await tester.pumpAndSettle();

    expect(transport.disconnectCalls, greaterThanOrEqualTo(1)); // Carnot C1
    expect(find.widgetWithText(AppBar, 'Sign in'), findsOneWidget);
  });

  testWidgets('logout → different user → no cross-session messages', (tester) async {
    final rest = FakeRestApi();
    final transport = FakeChatTransport();
    final container = makeContainer(rest: rest, transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    // User A sends a message into the (in-memory) cache.
    await tester.enterText(find.byType(TextField).first, 'secret-from-A');
    await tester.tap(find.byIcon(Icons.send));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('secret-from-A'), findsOneWidget);

    // Log out, then a DIFFERENT user logs in on the same app instance.
    await tester.tap(find.byIcon(Icons.logout));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Sign in'), findsOneWidget);

    rest.user = const AppUser(
        userId: 'u2', username: 'bob', displayName: 'Bob', aikoUsername: 'bob');
    await signIn(tester);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);
    expect(find.text('secret-from-A'), findsNothing); // cache cleared on logout (Carnot C3)
  });

  testWidgets('new messages auto-scroll the list to the newest (#42)',
      (tester) async {
    final rest = FakeRestApi();
    final transport = FakeChatTransport();
    final container = makeContainer(rest: rest, transport: transport);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    // Send enough messages through the real composer path to overflow the
    // (600px) test viewport, so the list actually has somewhere to scroll.
    for (var i = 0; i < 20; i++) {
      await tester.enterText(find.byType(TextField).first, 'msg-$i');
      await tester.tap(find.byIcon(Icons.send));
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

    await pumpApp(tester, container);
    await signIn(tester);

    for (var i = 0; i < 20; i++) {
      await tester.enterText(find.byType(TextField).first, 'old-$i');
      await tester.tap(find.byIcon(Icons.send));
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
    await tester.tap(find.byIcon(Icons.send));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();

    // They stay where they were — no yank to the bottom.
    expect(position.pixels, 0,
        reason: 'a reader scrolled up should keep their position');
  });

  testWidgets('cold start with stored session → restores to chat', (tester) async {
    final store = InMemoryTokenStore(
      const AuthTokens(accessToken: 'a', refreshToken: 'r'),
    );
    final container = makeContainer(
      rest: FakeRestApi(),
      transport: FakeChatTransport(),
      store: store,
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);

    // No login form — the stored tokens + me() restored the session.
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);
  });
}
