// The login wall on an island that isn't creating accounts (#436 part 2).
//
// "Create a passkey" on a closed island is the button that can only fail, and
// each failure leaves a passkey on the phone the island will never accept. So
// an explicit `creates_accounts: false` removes it, sign-in leads, and the copy
// points at "Change island". Anything short of an explicit "no" (an island older
// than the field, no network) must leave the screen exactly as it was.

import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/core/network/network_status.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/presentation/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/fakes.dart';
import '../../support/ui_fakes.dart';

void main() {
  Future<String> pumpLogin(
    WidgetTester tester, {
    required bool? createsAccounts,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final rest = FakeRestApi()..createsAccounts = createsAccounts;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        restApiProvider.overrideWithValue(rest),
        transportProvider.overrideWithValue(FakeChatTransport()),
        passkeyAuthClientProvider.overrideWithValue(FakePasskeyAuthClient()),
        tokenProviderProvider.overrideWithValue(
          DefaultTokenProvider(
            island: 'https://island.test',
            store: InMemoryTokenStore(),
            remoteRefresh: (_) async => 'access2',
            onUnauthenticated: () {},
          ),
        ),
        connectivityServiceProvider.overrideWithValue(
          FakeConnectivityService(),
        ),
        reachabilityProbeProvider.overrideWithValue(FakeReachabilityProbe()),
        islandReachableProvider.overrideWith((ref) => Stream.value(true)),
      ],
    );
    addTearDown(container.dispose);
    expect(await container.read(authControllerProvider.future), isNull);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    // One frame to start the providers fetch, one to render its answer.
    await tester.pump();
    await tester.pump();
    return Uri.parse(container.read(configProvider).httpBaseUrl).host;
  }

  testWidgets('closed island: no Create, sign-in leads, copy says why', (
    tester,
  ) async {
    final host = await pumpLogin(tester, createsAccounts: false);

    expect(find.text('Create a passkey'), findsNothing);
    expect(find.text('Create a new passkey'), findsNothing);
    expect(
      find.widgetWithText(FilledButton, 'Sign in with your passkey'),
      findsOneWidget,
    );
    final copy = tester.widget<Text>(
      find.byKey(const Key('login-registration-closed')),
    );
    expect(copy.data, contains(host));
    expect(copy.data, contains('change island'));
    expect(find.text('Change island'), findsOneWidget);
  });

  testWidgets('island that does not say: the screen is unchanged', (
    tester,
  ) async {
    await pumpLogin(tester, createsAccounts: null);

    expect(
      find.widgetWithText(FilledButton, 'Create a passkey'),
      findsOneWidget,
      reason: 'absence is not a refusal',
    );
    expect(find.byKey(const Key('login-registration-closed')), findsNothing);
  });

  testWidgets('open island: the screen is unchanged', (tester) async {
    await pumpLogin(tester, createsAccounts: true);

    expect(
      find.widgetWithText(FilledButton, 'Create a passkey'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('login-registration-closed')), findsNothing);
  });
}
