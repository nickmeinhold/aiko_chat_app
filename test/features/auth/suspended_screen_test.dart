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

  testWidgets(
    'a banned account (me → AccountSuspended) lands on /suspended, not /login',
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
    },
  );

  testWidgets('"Try signing in again" dismisses the soft gate → /login', (
    tester,
  ) async {
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

  testWidgets(
    'a logged-in user is ejected off /suspended, never idles on it while live',
    (tester) async {
      // Tesla's dead-node: suspended ⊥ logged-in. If the flag is ever set while a
      // session is live (a deferred-clear race, a stale deep link), the router
      // must bounce to chat, not sit on the ban screen while authenticated.
      final c = makeContainer(
        rest: FakeRestApi(), // me() ok → logged in → chat
        transport: FakeChatTransport(),
        store: InMemoryTokenStore(seededTokens),
      );
      addTearDown(c.dispose);
      await pumpApp(tester, c);
      expect(c.read(authControllerProvider).value, isNotNull); // logged in

      // Force the artificial dead-node state and let the router re-evaluate.
      c.read(suspendedProvider.notifier).flag();
      await tester.pumpAndSettle();

      expect(
        find.text('Account suspended'),
        findsNothing,
        reason: 'the logged-in eject wins over the suspended zone',
      );
    },
  );

  testWidgets(
    'a ceremony ban (sign-in → AccountSuspended) routes through the real router to /suspended',
    (tester) async {
      // The _ingress door through GoRouter (not just the cold-start restore): a
      // fail-closed restore lands on /login with tokens kept, then a passkey
      // sign-in resolves to a ban. Atomic settlement must land /suspended with no
      // lingering login CTA (cage-match Tesla: seal the ceremony ARRIVAL path).
      final rest = FakeRestApi(
        meThrows: Exception('unknown → fail-closed, tokens kept'),
      )..finishAuthThrows = const AccountSuspended();
      final c = makeContainer(
        rest: rest,
        transport: FakeChatTransport(),
        store: InMemoryTokenStore(seededTokens),
        passkey: FakePasskeyAuthClient(assertion: 'assert-json'),
      );
      addTearDown(c.dispose);
      await pumpApp(tester, c); // fail-closed → login screen
      expect(find.text('Already have a passkey? Sign in'), findsOneWidget);

      await tester.tap(find.text('Already have a passkey? Sign in'));
      await tester.pumpAndSettle();

      expect(c.read(suspendedProvider), isTrue);
      expect(find.text('Account suspended'), findsOneWidget);
      expect(
        find.text('Already have a passkey? Sign in'),
        findsNothing,
        reason: 'settled atomically onto /suspended — no lingering login CTA',
      );
    },
  );
}
