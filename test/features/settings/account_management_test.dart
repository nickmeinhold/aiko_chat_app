import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/chat/presentation/chat_message_pane.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show SoleAdminDeletionBlocked;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  testWidgets('Settings exposes the Terms for re-reading (read-only)', (
    tester,
  ) async {
    final container = makeContainer(
      rest: FakeRestApi(),
      transport: FakeChatTransport(),
    );
    addTearDown(container.dispose);

    // The settings list has grown (Identity, Safety, Sign-in, Account, Legal
    // sections); its Terms tile sits below the default 800x600 test viewport, so
    // give this test a taller viewport so the whole list lays out on-screen and
    // the Terms tile is reachable without scroll gymnastics.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpApp(tester, container);
    await signIn(tester);
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Terms of Use & Community Guidelines'));
    await tester.pumpAndSettle();

    // The viewer shows the Terms but offers NO acceptance button.
    expect(
      find.textContaining('no tolerance for objectionable content'),
      findsOneWidget,
    );
    expect(find.text('Accept & Continue'), findsNothing);
  });

  // --- account deletion (Apple 5.1.1(v)) ------------------------------------

  testWidgets(
    'deleting the account tears down the session to the login screen',
    (tester) async {
      final rest = FakeRestApi();
      final container = makeContainer(
        rest: rest,
        transport: FakeChatTransport(),
      );
      addTearDown(container.dispose);
      await pumpApp(tester, container);
      await signIn(tester);
      expect(
        find.byType(ChatMessagePane),
        findsOneWidget,
      ); // reached chat (layout-agnostic)

      // chat → settings → Delete account → confirm.
      await tester.tap(find.byIcon(Icons.settings));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Delete account'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(rest.deleteCalls, 1);
      // The auth guard redirected to /login (no chat, no settings).
      expect(find.widgetWithText(AppBar, 'general'), findsNothing);
      expect(find.widgetWithText(AppBar, 'Settings'), findsNothing);
      expect(
        find.widgetWithText(FilledButton, 'Create a passkey'),
        findsOneWidget,
      ); // login screen is back
    },
  );

  testWidgets('a sole-admin 409 keeps the user logged in with a message', (
    tester,
  ) async {
    final rest = FakeRestApi()
      ..deleteThrows = const SoleAdminDeletionBlocked(
        'cannot delete account while sole admin of channel(s) general',
      );
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await signIn(tester);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Delete account'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    // Rejected → still on settings, still logged in, with the explanation.
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
    expect(find.textContaining('sole admin'), findsOneWidget);
  });

  test(
    'deleteAccount leaves the session logged in when the gateway rejects it',
    () async {
      final rest = FakeRestApi()
        ..deleteThrows = const SoleAdminDeletionBlocked('nope');
      final container = makeContainer(
        rest: rest,
        transport: FakeChatTransport(),
      );
      addTearDown(container.dispose);
      await container.read(authControllerProvider.future); // settle restore
      await container.read(authControllerProvider.notifier).signInWithPasskey();
      expect(container.read(authControllerProvider).value, isNotNull);

      await expectLater(
        container.read(authControllerProvider.notifier).deleteAccount(),
        throwsA(isA<SoleAdminDeletionBlocked>()),
      );
      // The load-bearing invariant: a rejected delete must NOT log the user out.
      expect(container.read(authControllerProvider).value, isNotNull);
    },
  );
}
