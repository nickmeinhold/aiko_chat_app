import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/network/network_status_banner.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/fakes.dart';
import '../../support/test_helpers.dart';
import '../../support/ui_fakes.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  test('the bundled EULA asset carries the Apple 1.2 zero-tolerance clause',
      () async {
    final text = await rootBundle.loadString('assets/legal/eula.md');
    expect(text, contains('no tolerance for objectionable content'));
    expect(text, contains('24 hours')); // commitment to act
    expect(text.toLowerCase(), contains('block')); // block mechanism named
    expect(text.toLowerCase(), contains('report')); // report mechanism named
  });

  testWidgets('logged out → login screen shows passkey sign-in', (tester) async {
    final container = makeContainer(rest: FakeRestApi(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);

    // Passkey-first ingress: no Material title bar (the content stands alone).
    expect(find.byType(AppBar), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Create a passkey'), findsOneWidget);
    expect(find.text('Already have a passkey? Sign in'), findsOneWidget);
    // Social sign-in is fully removed — no provider buttons, no password fields.
    expect(find.text('Continue with Google'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('login content clears the status-bar inset (SafeArea, no AppBar)',
      (tester) async {
    // With the AppBar gone, SafeArea is the ONLY thing keeping content clear of
    // the status bar / notch. A plain widget test renders with zero insets and
    // is blind to this, so simulate a 44px top inset and assert the flush-to-top
    // child (the network banner) starts BELOW it. Delete SafeArea → this fails.
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 44);
    addTearDown(tester.view.reset);

    final container =
        makeContainer(rest: FakeRestApi(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);

    expect(find.byType(NetworkStatusBanner), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(NetworkStatusBanner)).dy,
      greaterThanOrEqualTo(44.0),
    );
  });

  // --- #35: the gateway picker is a PRE-LOGIN act -------------------------

  testWidgets('login screen surfaces the active server + a Change affordance',
      (tester) async {
    final container =
        makeContainer(rest: FakeRestApi(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);

    // The footer names the host (not the full URL) of the active gateway.
    final host = Uri.parse(container.read(configProvider).httpBaseUrl).host;
    expect(find.text('Server: $host'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Change server'), findsOneWidget);
  });

  testWidgets('a LOGGED-OUT user can reach the gateway picker (no /login bounce)',
      (tester) async {
    final container =
        makeContainer(rest: FakeRestApi(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    expect(find.widgetWithText(FilledButton, 'Create a passkey'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Change server'));
    await tester.pumpAndSettle();

    // Reached the picker (its AppBar title is "Server"), not bounced to login.
    expect(find.widgetWithText(AppBar, 'Server'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Create a passkey'), findsNothing);
    // And the picker's presets render (it functions while logged out).
    expect(find.text('Production'), findsOneWidget);
  });

  testWidgets('a LOGGED-OUT switch re-points config and lands on the new '
      "gateway's login (cage-match #53 consensus: switch-from-logged-out)",
      (tester) async {
    final container =
        makeContainer(rest: FakeRestApi(), transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await tester.tap(find.widgetWithText(TextButton, 'Change server'));
    await tester.pumpAndSettle();

    // Pick a different preset and confirm the switch.
    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();
    expect(find.text('Switch server?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Switch'));
    await tester.pumpAndSettle();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // Config re-pointed; still logged out; landed on the NEW gateway's login
    expect(container.read(configProvider).httpBaseUrl, 'http://localhost:8095');
    expect(container.read(authControllerProvider).value, isNull);
    expect(find.widgetWithText(FilledButton, 'Create a passkey'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Server'), findsNothing); // left the picker
    expect(find.text('Server: localhost:8095'), findsOneWidget);
  });

  // --- passkey sign-in (first-passkey-creates-account) ---------------------

  testWidgets('passkey sign-in with an existing credential → straight to chat',
      (tester) async {
    // Default finishPasskeyAuthentication outcome = Authenticated.
    final rest = FakeRestApi();
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await tester.tap(find.text('Already have a passkey? Sign in'));
    await tester.pumpAndSettle();

    expect(rest.passkeyAuthFinishCalls, 1);
    expect(find.widgetWithText(AppBar, 'general'), findsOneWidget);
  });

  testWidgets('a NEW passkey account → claim-handle → chat', (tester) async {
    // Default finishPasskeyRegistration outcome = PendingHandle, so creating a
    // passkey mints the account then routes to the handle claim.
    final rest = FakeRestApi();
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await tester.tap(find.widgetWithText(FilledButton, 'Create a passkey'));
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
    final rest = FakeRestApi() // default register outcome = PendingHandle
      ..claimThrows = const HandleTaken();
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await tester.tap(find.widgetWithText(FilledButton, 'Create a passkey'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'taken');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();

    expect(find.textContaining('That handle is taken — try another.'),
        findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Pick your handle'), findsOneWidget);
  });

  testWidgets('cancelling passkey sign-in stays on login with no error',
      (tester) async {
    final passkey = FakePasskeyAuthClient(
        authenticateThrows: const AuthCeremonyCancelled());
    final container = makeContainer(
        rest: FakeRestApi(), transport: FakeChatTransport(), passkey: passkey);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    await tester.tap(find.text('Already have a passkey? Sign in'));
    await tester.pumpAndSettle();

    expect(passkey.authenticateCalls, 1);
    expect(find.widgetWithText(FilledButton, 'Create a passkey'),
        findsOneWidget); // still login
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
    expect(find.widgetWithText(FilledButton, 'Create a passkey'), findsNothing);
    expect(find.text('Accept & Continue'), findsOneWidget);
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
    expect(find.widgetWithText(FilledButton, 'Create a passkey'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Terms of Use'), findsNothing);
  });

  testWidgets('a failed acceptance re-enables the button (no stuck spinner)',
      (tester) async {
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
    expect(find.widgetWithText(FilledButton, 'Create a passkey'), findsOneWidget);
  });
}
