import 'dart:async';

import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/data/social_auth_client.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_provider.dart';
import 'package:aiko_chat_app/features/auth/domain/social_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/fakes.dart';
import '../../support/ui_fakes.dart';

/// Passkey (WebAuthn) sign-in: the gateway-challenge → on-device authenticator →
/// finish ingress, verified to route through the SAME outcome handling as the
/// native and broker paths (single identity door → `_applyOutcome`).
void main() {
  ProviderContainer makeContainer({
    required FakeRestApi rest,
    required FakePasskeyAuthClient passkey,
    InMemoryTokenStore? store,
  }) {
    final tokenStore = store ?? InMemoryTokenStore();
    late final ProviderContainer container;
    container = ProviderContainer(overrides: [
      restApiProvider.overrideWithValue(rest),
      transportProvider.overrideWithValue(FakeChatTransport()),
      passkeyAuthClientProvider.overrideWithValue(passkey),
      tokenProviderProvider.overrideWithValue(DefaultTokenProvider(
        store: tokenStore,
        remoteRefresh: (_) async => 'access2',
        onUnauthenticated: () => container.read(authEventsProvider).add(null),
      )),
    ]);
    return container;
  }

  group('authenticate (existing passkey)', () {
    test('challenge → assertion → finish → logged in', () async {
      final rest = FakeRestApi();
      final passkey = FakePasskeyAuthClient(assertion: 'assert-json');
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);

      expect(await c.read(authControllerProvider.future), isNull);

      await c.read(authControllerProvider.notifier).signInWithPasskey();

      expect(rest.passkeyAuthStartCalls, 1, reason: 'fetches request options');
      expect(passkey.authenticateCalls, 1);
      expect(passkey.lastAuthenticateOptions, '{"challenge":"auth-chal"}',
          reason: 'the gateway options are passed to the authenticator');
      expect(rest.passkeyAuthFinishCalls, 1, reason: 'redeems the assertion');
      expect(rest.lastPasskeyAuthState, 'auth-state',
          reason: 'the binding state is round-tripped to finish');
      expect(rest.lastPasskeyAuthCredential, 'assert-json');
      expect(c.read(authControllerProvider).value, isNotNull,
          reason: 'known identity logs straight in');
    });

    test('user dismisses the sheet → no-op, no error, stays logged out',
        () async {
      final rest = FakeRestApi();
      final passkey = FakePasskeyAuthClient(
          authenticateThrows: const SocialSignInCancelled());
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await c.read(authControllerProvider.notifier).signInWithPasskey();

      final state = c.read(authControllerProvider);
      expect(state.hasError, isFalse, reason: 'cancellation is not an error');
      expect(state.value, isNull);
      expect(rest.passkeyAuthFinishCalls, 0,
          reason: 'no finish when the user backs out');
    });

    test('no passkey on device → surfaces as an error (not swallowed)',
        () async {
      final rest = FakeRestApi();
      final passkey = FakePasskeyAuthClient(
          authenticateThrows: const SocialSignInFailed('Passkey: none'));
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await c.read(authControllerProvider.notifier).signInWithPasskey();

      expect(c.read(authControllerProvider).hasError, isTrue,
          reason: 'a real authenticator failure is surfaced so the UI can '
              'nudge toward registration');
      expect(rest.passkeyAuthFinishCalls, 0);
    });

    test('ignored while already authenticated (ingress-only)', () async {
      final rest = FakeRestApi();
      final passkey = FakePasskeyAuthClient();
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await c.read(authControllerProvider.notifier).signInWithPasskey();
      expect(c.read(authControllerProvider).value, isNotNull);
      final callsAfterLogin = passkey.authenticateCalls;

      await c.read(authControllerProvider.notifier).signInWithPasskey();
      expect(passkey.authenticateCalls, callsAfterLogin,
          reason: 'no passkey flow is started while a session is live');
    });

    test(
        'second ingress while the first is in flight is a no-op (single-flight)',
        () async {
      // Logged out, first ceremony parked inside the authenticator (sheet
      // "open"): the controller is AsyncLoading with value == null. A second
      // ingress here is the dangerous case — the `value != null` guard alone
      // would let it pass, issue a SECOND challenge, and (via the
      // start-of-ceremony cancelCurrentAuthenticatorOperation) silently cancel
      // the first sheet, letting the later challenge win. The guard contract we
      // assert is the ORDERING INVARIANT: while one ceremony is unresolved, no
      // second ceremony may start — not merely the eventual outcome.
      final rest = FakeRestApi();
      final gate = Completer<void>();
      final passkey =
          FakePasskeyAuthClient(assertion: 'assert-json', gate: gate);
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      // First ingress: not awaited — it parks on the gate inside authenticate().
      final first = c.read(authControllerProvider.notifier).signInWithPasskey();
      await pumpEventQueue(); // let it reach the gate
      expect(rest.passkeyAuthStartCalls, 1);
      expect(passkey.authenticateCalls, 1);
      expect(c.read(authControllerProvider).isLoading, isTrue);

      // Second ingress while the first is still in flight: must be a no-op.
      // Fire WITHOUT awaiting — if the guard is missing, this would start a
      // second ceremony that parks on the SAME gate (hang), so we assert on the
      // call counts after pumping rather than on the future completing.
      unawaited(c.read(authControllerProvider.notifier).signInWithPasskey());
      await pumpEventQueue();
      expect(rest.passkeyAuthStartCalls, 1,
          reason: 'no second challenge issued while one is in flight');
      expect(passkey.authenticateCalls, 1,
          reason: 'no second authenticator ceremony started');

      // Release the first and let it complete cleanly.
      gate.complete();
      await first;
      expect(rest.passkeyAuthFinishCalls, 1);
      expect(c.read(authControllerProvider).value, isNotNull,
          reason: 'the original ceremony still resolves to a login');
    });
  });

  group('register (first passkey creates account)', () {
    test('attestation → finish → parks a PendingHandle, stays logged out',
        () async {
      final rest = FakeRestApi(); // default register outcome = PendingHandle
      final passkey = FakePasskeyAuthClient(attestation: 'attest-json');
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await c.read(authControllerProvider.notifier).registerWithPasskey();

      expect(rest.passkeyRegisterStartCalls, 1);
      expect(passkey.registerCalls, 1);
      expect(rest.lastPasskeyRegisterState, 'reg-state');
      expect(rest.lastPasskeyRegisterCredential, 'attest-json');
      expect(c.read(authControllerProvider).value, isNull,
          reason: 'a new identity must claim a handle before being logged in');
      expect(c.read(pendingHandleProvider)?.provisioningToken, 'passkey-prov',
          reason: 'pending state drives the router to /claim-handle');
    });

    test('gateway logs straight in → authenticated', () async {
      final rest = FakeRestApi()
        ..passkeyRegisterOutcome = Authenticated(AuthSession(
          user: FakeRestApi.defaultUser,
          tokens: const AuthTokens(
              accessToken: 'access', refreshToken: 'refresh'),
        ));
      final passkey = FakePasskeyAuthClient();
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await c.read(authControllerProvider.notifier).registerWithPasskey();

      expect(c.read(authControllerProvider).value, isNotNull);
    });

    test('user dismisses the sheet → no-op, finish not called', () async {
      final rest = FakeRestApi();
      final passkey = FakePasskeyAuthClient(
          registerThrows: const SocialSignInCancelled());
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await c.read(authControllerProvider.notifier).registerWithPasskey();

      final state = c.read(authControllerProvider);
      expect(state.hasError, isFalse);
      expect(state.value, isNull);
      expect(rest.passkeyRegisterFinishCalls, 0);
    });

    test('ignored while already authenticated (ingress-only)', () async {
      final rest = FakeRestApi()
        ..passkeyRegisterOutcome = Authenticated(AuthSession(
          user: FakeRestApi.defaultUser,
          tokens: const AuthTokens(
              accessToken: 'access', refreshToken: 'refresh'),
        ));
      final passkey = FakePasskeyAuthClient();
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await c.read(authControllerProvider.notifier).registerWithPasskey();
      expect(c.read(authControllerProvider).value, isNotNull);
      final callsAfterLogin = passkey.registerCalls;

      await c.read(authControllerProvider.notifier).registerWithPasskey();
      expect(passkey.registerCalls, callsAfterLogin,
          reason: 'no registration is started while a session is live');
    });
  });

  group('provider advertisement', () {
    test('a passkey kind is now understood (no longer fail-closed dropped)', () {
      final parsed = AuthProviderInfo.tryParse(const {
        'slug': 'passkey',
        'display_name': 'Passkey',
        'kind': 'passkey',
      });
      expect(parsed, isNotNull);
      expect(parsed!.kind, AuthProviderKind.passkey);
    });
  });
}
