import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  // signIn → open Settings → Edit profile. Returns the fake so a test can assert
  // the call / stage an error via `updateProfileThrows`.
  Future<FakeRestApi> openEditProfile(
    WidgetTester tester, {
    Object? updateThrows,
  }) async {
    final rest = FakeRestApi()..updateProfileThrows = updateThrows;
    final container = makeContainer(rest: rest, transport: FakeChatTransport());
    addTearDown(container.dispose);

    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpApp(tester, container);
    await signIn(tester);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit profile'));
    await tester.pumpAndSettle();
    return rest;
  }

  testWidgets('editing display name saves and updates the user', (
    tester,
  ) async {
    final rest = await openEditProfile(tester);

    await tester.enterText(find.byType(TextField).at(1), 'Nicholas'); // display
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(rest.updateProfileCalls, 1);
    expect(rest.user.displayName, 'Nicholas');
    // Popped back to the Settings screen.
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
  });

  testWidgets('a taken handle shows an inline error and stays put', (
    tester,
  ) async {
    await openEditProfile(tester, updateThrows: const HandleTaken());

    await tester.enterText(
      find.byType(TextField).at(0),
      'taken_name',
    ); // handle
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('That handle is already taken'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Edit profile'), findsOneWidget);
  });

  testWidgets('a handle-change cooldown shows the days remaining', (
    tester,
  ) async {
    await openEditProfile(
      tester,
      updateThrows: const HandleChangeOnCooldown(3 * 86400),
    );

    await tester.enterText(find.byType(TextField).at(0), 'too_soon');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('You can change your handle again in 3 days'),
      findsOneWidget,
    );
  });

  testWidgets('a cleared display name is guarded client-side, never sent', (
    tester,
  ) async {
    final rest = await openEditProfile(tester);

    // Blank the display name (the island 422s a provided-but-blank display_name;
    // the client must guard it symmetrically with the handle — cage-match #114).
    await tester.enterText(find.byType(TextField).at(1), '');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Display name cannot be empty'), findsOneWidget);
    expect(
      rest.updateProfileCalls,
      0,
      reason: 'blank field never hits the wire',
    );
    expect(find.widgetWithText(AppBar, 'Edit profile'), findsOneWidget);
  });

  testWidgets('a ban landing mid-edit routes to the suspended screen', (
    tester,
  ) async {
    // AccountSuspended from PATCH /v1/me must reach the single suspended door
    // (settleBan → /suspended), not be swallowed by the generic snackbar
    // (cage-match #114, Carnot+Tesla+Wu).
    await openEditProfile(tester, updateThrows: const AccountSuspended());

    await tester.enterText(find.byType(TextField).at(0), 'new_handle');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account suspended'), findsOneWidget);
  });
}
