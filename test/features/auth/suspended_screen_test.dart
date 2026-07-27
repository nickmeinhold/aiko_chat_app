// End-to-end wiring for the account-suspended zone (#29): a banned account must
// land on the dedicated /suspended screen (NOT /login, which loops on re-auth),
// and the "try again" soft-gate dismissal must return to /login. This exercises
// the REAL router redirect + screen through pumpApp, so a regression in the
// controller flag, the router zone, or the route wiring fails HERE.

import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show AccountSuspended;
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart'; // exports AuthTokens + the fakes

void main() {
  setUpAll(initializeTestEnvironment);

  const seededTokens = AuthTokens(accessToken: 'a', refreshToken: 'r');

  testWidgets('a banned account (me → AccountSuspended) lands on /suspended, not /login',
      (tester) async {
    final c = makeContainer(
      rest: FakeRestApi(meThrows: const AccountSuspended()),
      transport: FakeChatTransport(),
      store: InMemoryTokenStore(seededTokens),
    );
    addTearDown(c.dispose);

    await pumpApp(tester, c);

    expect(c.read(suspendedProvider), isTrue);
    expect(find.text('Account suspended'), findsOneWidget);
    expect(find.text('Try signing in again'), findsOneWidget);
    // The login CTA must NOT be what a banned user sees.
    expect(find.text('Already have a passkey? Sign in'), findsNothing);
  });

  testWidgets('"Try signing in again" dismisses the soft gate → /login',
      (tester) async {
    final c = makeContainer(
      rest: FakeRestApi(meThrows: const AccountSuspended()),
      transport: FakeChatTransport(),
      store: InMemoryTokenStore(seededTokens),
    );
    addTearDown(c.dispose);
    await pumpApp(tester, c);
    expect(find.text('Account suspended'), findsOneWidget);

    await tester.tap(find.text('Try signing in again'));
    await tester.pumpAndSettle();

    // Left /suspended for the login screen (a re-auth attempt would re-flag).
    expect(c.read(suspendedProvider), isFalse);
    expect(find.text('Account suspended'), findsNothing);
    expect(find.text('Already have a passkey? Sign in'), findsOneWidget);
  });
}
