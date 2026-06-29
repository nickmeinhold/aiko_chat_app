import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/data/social_auth_client.dart';
import 'package:aiko_chat_app/features/auth/domain/social_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/fakes.dart';
import '../../support/ui_fakes.dart';

/// Broker (GitHub) sign-in: the web-auth → /exchange ingress, verified to route
/// through the SAME outcome handling as native social sign-in.
void main() {
  ProviderContainer makeContainer({
    required FakeRestApi rest,
    required FakeBrokerAuthClient broker,
    InMemoryTokenStore? store,
  }) {
    final tokenStore = store ?? InMemoryTokenStore();
    late final ProviderContainer container;
    container = ProviderContainer(overrides: [
      restApiProvider.overrideWithValue(rest),
      transportProvider.overrideWithValue(FakeChatTransport()),
      brokerAuthClientProvider.overrideWithValue(broker),
      tokenProviderProvider.overrideWithValue(DefaultTokenProvider(
        store: tokenStore,
        remoteRefresh: (_) async => 'access2',
        onUnauthenticated: () => container.read(authEventsProvider).add(null),
      )),
    ]);
    return container;
  }

  test('known identity → exchange handoff → logged in', () async {
    final rest = FakeRestApi();
    final broker = FakeBrokerAuthClient(code: 'handoff-123');
    final c = makeContainer(rest: rest, broker: broker);
    addTearDown(c.dispose);

    // Cold start: no tokens → logged out.
    expect(await c.read(authControllerProvider.future), isNull);

    await c.read(authControllerProvider.notifier).signInWithBroker('github');

    expect(broker.lastSlug, 'github', reason: 'drives the slug-specific flow');
    expect(broker.code, 'handoff-123');
    expect(rest.exchangeCalls, 1, reason: 'redeems the handoff at /exchange');
    expect(c.read(authControllerProvider).value, isNotNull,
        reason: 'known identity logs straight in');
  });

  test('new identity → parks a PendingHandle, stays logged out', () async {
    final rest = FakeRestApi()
      ..brokerOutcome = const PendingHandle(
        provisioningToken: 'prov-tok',
        suggestedName: 'octocat',
      );
    final broker = FakeBrokerAuthClient();
    final c = makeContainer(rest: rest, broker: broker);
    addTearDown(c.dispose);
    await c.read(authControllerProvider.future);

    await c.read(authControllerProvider.notifier).signInWithBroker('github');

    expect(c.read(authControllerProvider).value, isNull,
        reason: 'a new identity must claim a handle before being logged in');
    final pending = c.read(pendingHandleProvider);
    expect(pending?.provisioningToken, 'prov-tok',
        reason: 'pending state drives the router to /claim-handle');
  });

  test('user cancels the browser → no-op, no error, stays logged out',
      () async {
    final rest = FakeRestApi();
    final broker = FakeBrokerAuthClient(throws: const SocialSignInCancelled());
    final c = makeContainer(rest: rest, broker: broker);
    addTearDown(c.dispose);
    await c.read(authControllerProvider.future);

    await c.read(authControllerProvider.notifier).signInWithBroker('github');

    final state = c.read(authControllerProvider);
    expect(state.hasError, isFalse, reason: 'cancellation is not an error');
    expect(state.value, isNull);
    expect(rest.exchangeCalls, 0, reason: 'no exchange when the user backs out');
  });

  test('ignored while already authenticated (ingress-only)', () async {
    final rest = FakeRestApi();
    final broker = FakeBrokerAuthClient();
    final c = makeContainer(rest: rest, broker: broker);
    addTearDown(c.dispose);
    await c.read(authControllerProvider.future);

    // Log in first via the broker.
    await c.read(authControllerProvider.notifier).signInWithBroker('github');
    expect(c.read(authControllerProvider).value, isNotNull);
    final callsAfterLogin = broker.authCalls;

    // A second call while authenticated must be a no-op.
    await c.read(authControllerProvider.notifier).signInWithBroker('github');
    expect(broker.authCalls, callsAfterLogin,
        reason: 'no broker flow is started while a session is live');
  });
}
