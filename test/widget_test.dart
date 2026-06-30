// Acceptance tests for the B-UI app-shell + chat screen (task #39).
//
// These drive the REAL provider graph (router, auth controller, repository,
// message stream) with the data layer faked at the interface seam — so they
// exercise the wiring, not the fakes. The trust-boundary cases are the point:
//   - a terminal `unauthenticated` logs out;
//   - a transient `disconnected` does NOT (the auth_error_boundary invariant).

import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/data/social_auth_client.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/auth/domain/social_models.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show HandleTaken, SoleAdminDeletionBlocked;
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart';
import 'package:aiko_chat_app/features/legal/application/eula_controller.dart';
import 'package:aiko_chat_app/main.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  FakeSocialAuthClient? social,
  FakeBrokerAuthClient? broker,
  FakeEulaStore? eula,
  String? eulaText,
}) {
  final tokenStore = store ?? InMemoryTokenStore();
  late final ProviderContainer container;
  container = ProviderContainer(overrides: [
    // The Settings Server tile + the config layer read SharedPreferences; inject
    // the in-memory instance loaded in setUpAll so configProvider resolves.
    sharedPreferencesProvider.overrideWithValue(_prefs),
    restApiProvider.overrideWithValue(rest),
    transportProvider.overrideWithValue(transport),
    // The real social client hits Apple/Google platform channels — fake it.
    socialAuthClientProvider.overrideWithValue(social ?? FakeSocialAuthClient()),
    // The real broker client opens a system web-auth session — fake it.
    brokerAuthClientProvider.overrideWithValue(broker ?? FakeBrokerAuthClient()),
    // EULA acceptance is faked at its store seam. Default ACCEPTED so existing
    // tests reach login/chat unchanged; gate-specific tests pass accepted:false.
    eulaStoreProvider.overrideWithValue(eula ?? FakeEulaStore(accepted: true)),
    // Inject the (real) Terms text synchronously so no async asset read races
    // pumpAndSettle. Loaded once from the bundled asset in setUpAll; a test can
    // pass a short string to exercise the no-scroll path.
    eulaTextProvider.overrideWith((ref) => eulaText ?? _realEula),
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

/// Drive social sign-in to the chat screen. Assumes a logged-out start.
/// The [FakeRestApi] defaults to returning an [Authenticated] session and
/// [FakeSocialAuthClient] returns a canned credential without hitting a
/// platform channel, so tapping either social button immediately navigates to chat.
Future<void> signIn(WidgetTester tester) async {
  await tester.tap(find.text('Continue with Google'));
  await tester.pumpAndSettle();
}

/// The real bundled Terms text, loaded once so widget tests inject it
/// synchronously (deterministic) while still exercising the actual asset.
String _realEula = '';

/// In-memory SharedPreferences for the config layer (the Settings Server tile).
late SharedPreferences _prefs;

void main() {
  setUpAll(() async {
    _realEula = await rootBundle.loadString('assets/legal/eula.md');
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  test('the bundled EULA asset carries the Apple 1.2 zero-tolerance clause',
      () async {
    final text = await rootBundle.loadString('assets/legal/eula.md');
    expect(text, contains('no tolerance for objectionable content'));
    expect(text, contains('24 hours')); // commitment to act
    expect(text.toLowerCase(), contains('block')); // block mechanism named
    expect(text.toLowerCase(), contains('report')); // report mechanism named
  });

  testWidgets('logged out → login screen shows social sign-in', (tester) async {
    final container = makeContainer(rest: FakeRestApi(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);

    expect(find.widgetWithText(AppBar, 'Sign in'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.byType(TextField), findsNothing); // no password fields
  });

  testWidgets('social sign-in → chat screen shows the channel', (tester) async {
    final rest = FakeRestApi();
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);

    expect(rest.socialCalls, 1);
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

  // --- social sign-in (#5) -------------------------------------------------

  testWidgets('login screen offers the Google social button (social-only)',
      (tester) async {
    final container = makeContainer(
        rest: FakeRestApi(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);

    expect(find.widgetWithText(OutlinedButton, 'Continue with Google'),
        findsOneWidget);
    // No "or" divider — password path removed.
    expect(find.text('or'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('social sign-in with a known identity → straight to chat',
      (tester) async {
    final rest = FakeRestApi(); // default socialOutcome = Authenticated
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Continue with Google'));
    await tester.pumpAndSettle();

    expect(rest.socialCalls, 1);
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);
  });

  testWidgets('social sign-in with a NEW identity → claim-handle → chat',
      (tester) async {
    final rest = FakeRestApi()
      ..socialOutcome = const PendingHandle(
          provisioningToken: 'ptok', suggestedName: 'Robin');
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Continue with Google'));
    await tester.pumpAndSettle();

    // A new identity is routed to the pick-your-handle screen, NOT chat.
    expect(find.widgetWithText(AppBar, 'Pick your handle'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Display name'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'robin');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();

    expect(rest.claimCalls, 1);
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);
  });

  testWidgets('claim-handle surfaces a taken handle inline', (tester) async {
    final rest = FakeRestApi()
      ..socialOutcome = const PendingHandle(provisioningToken: 'ptok')
      ..claimThrows = const HandleTaken();
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Continue with Google'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'taken');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();

    expect(find.text('That handle is taken — try another.'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Pick your handle'), findsOneWidget);
  });

  testWidgets('cancelling social sign-in stays on login with no error',
      (tester) async {
    final social = FakeSocialAuthClient(throws: const SocialSignInCancelled());
    final container = makeContainer(
        rest: FakeRestApi(), transport: FakeChatTransport(), social: social);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Continue with Google'));
    await tester.pumpAndSettle();

    expect(social.signInCalls, 1);
    expect(find.widgetWithText(AppBar, 'Sign in'), findsOneWidget); // still login
    expect(find.textContaining('went wrong'), findsNothing); // no error banner
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

  // --- EULA acceptance gate (Apple 1.2 / Google UGC) ------------------------

  testWidgets('fresh install → EULA gate blocks the login screen',
      (tester) async {
    final container = makeContainer(
      rest: FakeRestApi(),
      transport: FakeChatTransport(),
      eula: FakeEulaStore(accepted: false),
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);

    // The Terms gate is up; login is NOT reachable behind it.
    expect(find.widgetWithText(AppBar, 'Terms of Use'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Sign in'), findsNothing);
    expect(find.text('Accept & Continue'), findsOneWidget);
    // The zero-tolerance clause Apple 1.2 looks for is present in the text.
    expect(find.textContaining('no tolerance for objectionable content'),
        findsOneWidget);
  });

  testWidgets('Accept is disabled until the user scrolls to the bottom',
      (tester) async {
    final container = makeContainer(
      rest: FakeRestApi(),
      transport: FakeChatTransport(),
      eula: FakeEulaStore(accepted: false),
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);

    FilledButton acceptButton() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Accept & Continue'));
    expect(acceptButton().onPressed, isNull); // disabled before scrolling
    expect(find.text('Scroll to the bottom to continue'), findsOneWidget);

    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -5000));
    await tester.pumpAndSettle();

    expect(acceptButton().onPressed, isNotNull); // enabled once read
  });

  testWidgets('accepting the EULA persists and reveals the login screen',
      (tester) async {
    final eula = FakeEulaStore(accepted: false);
    final container = makeContainer(
        rest: FakeRestApi(), transport: FakeChatTransport(), eula: eula);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -5000));
    await tester.pumpAndSettle();
    await tester
        .tap(find.widgetWithText(FilledButton, 'Accept & Continue'));
    await tester.pumpAndSettle();

    expect(eula.accepted, isTrue); // persisted at the store seam
    expect(eula.setCalls, 1);
    // Gate cleared → the guard routes a logged-out device to login.
    expect(find.widgetWithText(AppBar, 'Sign in'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Terms of Use'), findsNothing);
  });

  testWidgets('a failed acceptance re-enables the button (no stuck spinner)',
      (tester) async {
    // Cage-match consensus (Maxwell/Kelvin/Carnot): a persist failure must not
    // strand the user on a dead spinner behind a swallowed back button.
    final eula = FakeEulaStore(accepted: false, throwOnAccept: true);
    final container = makeContainer(
        rest: FakeRestApi(), transport: FakeChatTransport(), eula: eula);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -5000));
    await tester.pumpAndSettle();
    await tester
        .tap(find.widgetWithText(FilledButton, 'Accept & Continue'));
    await tester.pumpAndSettle();

    expect(eula.setCalls, 1); // tried to persist
    expect(eula.accepted, isFalse); // and it failed
    // Still on the gate, error surfaced, button re-enabled for a retry.
    expect(find.widgetWithText(AppBar, 'Terms of Use'), findsOneWidget);
    expect(find.textContaining('Could not save'), findsOneWidget);
    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Accept & Continue'));
    expect(button.onPressed, isNotNull);
  });

  testWidgets('short Terms that fit the screen enable Accept without scrolling',
      (tester) async {
    final container = makeContainer(
      rest: FakeRestApi(),
      transport: FakeChatTransport(),
      eula: FakeEulaStore(accepted: false),
      eulaText: 'Aiko Chat — Terms\n\nBy continuing you accept the Terms.',
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);

    // Nothing to scroll → the gate enables acceptance immediately.
    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Accept & Continue'));
    expect(button.onPressed, isNotNull);
    expect(find.text('Scroll to the bottom to continue'), findsNothing);
  });

  testWidgets('already-accepted device → no gate, straight to login',
      (tester) async {
    final container = makeContainer(
      rest: FakeRestApi(),
      transport: FakeChatTransport(),
      eula: FakeEulaStore(accepted: true),
    );
    addTearDown(container.dispose);

    await pumpApp(tester, container);

    expect(find.widgetWithText(AppBar, 'Terms of Use'), findsNothing);
    expect(find.widgetWithText(AppBar, 'Sign in'), findsOneWidget);
  });

  testWidgets('Settings exposes the Terms for re-reading (read-only)',
      (tester) async {
    final container =
        makeContainer(rest: FakeRestApi(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Terms of Use & Community Guidelines'));
    await tester.pumpAndSettle();

    // The viewer shows the Terms but offers NO acceptance button.
    expect(find.textContaining('no tolerance for objectionable content'),
        findsOneWidget);
    expect(find.text('Accept & Continue'), findsNothing);
  });

  // --- account deletion (Apple 5.1.1(v)) ------------------------------------

  testWidgets('deleting the account tears down the session to the login screen',
      (tester) async {
    final rest = FakeRestApi();
    final container =
        makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);

    // chat → settings → Delete account → confirm.
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(rest.deleteCalls, 1);
    // The auth guard redirected to /login (no chat, no settings).
    expect(find.widgetWithText(AppBar, 'general'), findsNothing);
    expect(find.widgetWithText(AppBar, 'Settings'), findsNothing);
    expect(find.widgetWithText(AppBar, 'Sign in'), findsOneWidget); // login screen is back
  });

  testWidgets('a sole-admin 409 keeps the user logged in with a message',
      (tester) async {
    final rest = FakeRestApi()
      ..deleteThrows = const SoleAdminDeletionBlocked(
          'cannot delete account while sole admin of channel(s) general');
    final container =
        makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    // Rejected → still on settings, still logged in, with the explanation.
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
    expect(find.textContaining('sole admin'), findsOneWidget);
  });

  test('deleteAccount leaves the session logged in when the gateway rejects it',
      () async {
    final rest = FakeRestApi()
      ..deleteThrows = const SoleAdminDeletionBlocked('nope');
    final social = FakeSocialAuthClient();
    final container =
        makeContainer(rest: rest, transport: FakeChatTransport(), social: social);
    addTearDown(container.dispose);
    await container.read(authControllerProvider.future); // settle restore
    await container
        .read(authControllerProvider.notifier)
        .signInWith(SocialProvider.google);
    expect(container.read(authControllerProvider).value, isNotNull);

    await expectLater(
      container.read(authControllerProvider.notifier).deleteAccount(),
      throwsA(isA<SoleAdminDeletionBlocked>()),
    );
    // The load-bearing invariant: a rejected delete must NOT log the user out.
    expect(container.read(authControllerProvider).value, isNotNull);
  });
}
