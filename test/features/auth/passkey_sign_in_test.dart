import 'dart:async';

import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/data/auth_exceptions.dart';
import 'package:aiko_chat_app/features/auth/data/owed_handle_store.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/auth/domain/identity_models.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show
        AccountSuspended,
        HandleTaken,
        PasskeyAlreadyRegistered,
        RegistrationClosed,
        Unauthorized;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/fakes.dart';
import '../../support/ui_fakes.dart';

/// Passkey (WebAuthn) sign-in: the gateway-challenge → on-device authenticator →
/// finish ingress, verified to route register and authenticate through the SAME
/// outcome handling (single identity door → `_applyOutcome`).
void main() {
  ProviderContainer makeContainer({
    required FakeRestApi rest,
    required FakePasskeyAuthClient passkey,
    InMemoryTokenStore? store,
    SharedPreferences? prefs,
  }) {
    final tokenStore = store ?? InMemoryTokenStore();
    late final ProviderContainer container;
    // NOTE: this container deliberately does NOT override
    // sharedPreferencesProvider, and that omission is now load-bearing COVERAGE
    // rather than an oversight. The passkey-hint write added on the sign-in path
    // makes `passkeyHintStoreProvider` throw here — and in its first cut that
    // exception propagated out of `signInWithPasskey`, turning a SUCCESSFUL
    // sign-in into a failure. A cosmetic button-emphasis hint could break
    // authentication. These tests are what caught it; keep the omission.
    container = ProviderContainer(
      overrides: [
        restApiProvider.overrideWithValue(rest),
        transportProvider.overrideWithValue(FakeChatTransport()),
        passkeyAuthClientProvider.overrideWithValue(passkey),
        // Opt-in only, so the default keeps the prefs-less coverage above.
        if (prefs != null) sharedPreferencesProvider.overrideWithValue(prefs),
        cachedUserStoreProvider.overrideWithValue(InMemoryCachedUserStore()),
        tokenProviderProvider.overrideWithValue(
          DefaultTokenProvider(
            island: 'https://island.test',
            store: tokenStore,
            remoteRefresh: (_) async => 'access2',
            onUnauthenticated: () =>
                container.read(authEventsProvider).add(null),
          ),
        ),
      ],
    );
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
      expect(
        passkey.lastAuthenticateOptions,
        '{"challenge":"auth-chal"}',
        reason: 'the gateway options are passed to the authenticator',
      );
      expect(rest.passkeyAuthFinishCalls, 1, reason: 'redeems the assertion');
      expect(
        rest.lastPasskeyAuthState,
        'auth-state',
        reason: 'the binding state is round-tripped to finish',
      );
      expect(rest.lastPasskeyAuthCredential, 'assert-json');
      expect(
        c.read(authControllerProvider).value,
        isNotNull,
        reason: 'known identity logs straight in',
      );
    });

    test(
      'user dismisses the sheet → no-op, no error, stays logged out',
      () async {
        final rest = FakeRestApi();
        final passkey = FakePasskeyAuthClient(
          authenticateThrows: const AuthCeremonyCancelled(),
        );
        final c = makeContainer(rest: rest, passkey: passkey);
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);

        await c.read(authControllerProvider.notifier).signInWithPasskey();

        final state = c.read(authControllerProvider);
        expect(state.hasError, isFalse, reason: 'cancellation is not an error');
        expect(state.value, isNull);
        expect(
          rest.passkeyAuthFinishCalls,
          0,
          reason: 'no finish when the user backs out',
        );
      },
    );

    test(
      'no passkey on device → surfaces as an error (not swallowed)',
      () async {
        final rest = FakeRestApi();
        final passkey = FakePasskeyAuthClient(
          authenticateThrows: const AuthCeremonyFailed('Passkey: none'),
        );
        final c = makeContainer(rest: rest, passkey: passkey);
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);

        await c.read(authControllerProvider.notifier).signInWithPasskey();

        expect(
          c.read(authControllerProvider).hasError,
          isTrue,
          reason:
              'a real authenticator failure is surfaced so the UI can '
              'nudge toward registration',
        );
        expect(rest.passkeyAuthFinishCalls, 0);
      },
    );

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
      expect(
        passkey.authenticateCalls,
        callsAfterLogin,
        reason: 'no passkey flow is started while a session is live',
      );
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
        final passkey = FakePasskeyAuthClient(
          assertion: 'assert-json',
          gate: gate,
        );
        final c = makeContainer(rest: rest, passkey: passkey);
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);

        // First ingress: not awaited — it parks on the gate inside authenticate().
        final first = c
            .read(authControllerProvider.notifier)
            .signInWithPasskey();
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
        expect(
          rest.passkeyAuthStartCalls,
          1,
          reason: 'no second challenge issued while one is in flight',
        );
        expect(
          passkey.authenticateCalls,
          1,
          reason: 'no second authenticator ceremony started',
        );

        // Release the first and let it complete cleanly.
        gate.complete();
        await first;
        expect(rest.passkeyAuthFinishCalls, 1);
        expect(
          c.read(authControllerProvider).value,
          isNotNull,
          reason: 'the original ceremony still resolves to a login',
        );
      },
    );
  });

  group('register (first passkey creates account)', () {
    Future<void> register(ProviderContainer c) => c
        .read(authControllerProvider.notifier)
        .registerWithPasskey(handle: 'nicka', displayName: 'Nick');

    // THE behaviour #436 is about, against what the island really answers (a
    // live session under an auto-assigned `aiko-…` handle). It went missing
    // twice while the fake answered a PendingHandle the island no longer sends.
    test(
      'a new account ends up with the handle it chose, never on aiko-…',
      () async {
        final rest = FakeRestApi(); // the island's real answer, by default
        final passkey = FakePasskeyAuthClient();
        final c = makeContainer(rest: rest, passkey: passkey);
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);

        await register(c);

        expect(
          rest.lastPasskeyRegisterName,
          'nicka',
          reason: 'the passkey is labelled with the handle',
        );
        expect(rest.updateProfileCalls, 1, reason: 'the handle is applied');
        final user = c.read(authControllerProvider).value;
        expect(user?.username, 'nicka');
        expect(user?.displayName, 'Nick');
        expect(user?.handleAuto, isFalse);
        expect(
          _nothingOwed(c.read(owedHandleProvider)),
          isTrue,
          reason: 'nothing left owed',
        );
      },
    );

    test('the island refuses the handle → signed in, but the handle is still '
        'owed, bound to this account, with the reason', () async {
      final rest = FakeRestApi()..updateProfileThrows = const HandleTaken();
      final passkey = FakePasskeyAuthClient();
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await register(c);

      final user = c.read(authControllerProvider).value;
      expect(user, isNotNull, reason: 'the account exists; never fail sign-in');
      expect(user!.username, startsWith('aiko-'));
      final owed = c.read(owedHandleProvider).forAccount(user.userId);
      expect(
        owed?.userId,
        user.userId,
        reason: 'this is what the router reads',
      );
      expect(owed?.handle, 'nicka');
      expect(owed?.failure, isA<HandleTaken>());

      // Picking again from /choose-handle pays it.
      rest.updateProfileThrows = null;
      await c
          .read(authControllerProvider.notifier)
          .chooseHandle('nicka2', 'Nick');
      expect(c.read(authControllerProvider).value?.username, 'nicka2');
      expect(_nothingOwed(c.read(owedHandleProvider)), isTrue);
    });

    // A TERMINAL answer to the first payment is not a refusal. Shown as one, it
    // left the dead (or banned) session published on /choose-handle until a
    // retry happened to go through `saveProfile`, which settles both.
    test('a dead session on the first payment SIGNS OUT — not a reason on '
        '/choose-handle', () async {
      final rest = FakeRestApi()..updateProfileThrows = const Unauthorized(401);
      final store = InMemoryTokenStore();
      final c = makeContainer(
        rest: rest,
        passkey: FakePasskeyAuthClient(),
        store: store,
      );
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await register(c);
      await pumpEventQueue(); // the teardown is unawaited, as in saveProfile

      expect(c.read(authControllerProvider).value, isNull);
      expect(store.current, isNull, reason: 'the dead tokens are cleared');
      final owed = c
          .read(owedHandleProvider)
          .forAccount(FakeRestApi.newAccountUser.userId);
      expect(owed?.handle, 'nicka', reason: 'still owed by that account');
      expect(owed?.failure, isNull, reason: 'never filed as a refusal');
    });

    test(
      'a ban on the first payment goes through the suspended door',
      () async {
        final rest = FakeRestApi()
          ..updateProfileThrows = const AccountSuspended();
        final store = InMemoryTokenStore();
        final c = makeContainer(
          rest: rest,
          passkey: FakePasskeyAuthClient(),
          store: store,
        );
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);

        await register(c);

        expect(c.read(suspendedProvider), isTrue);
        final auth = c.read(authControllerProvider);
        expect(auth.hasError, isFalse, reason: 'settled, not left as an error');
        expect(auth.value, isNull);
        expect(store.current, isNull);
      },
    );

    test('a reply LOST after the island made the account keeps the chosen '
        'handle, unbound', () async {
      // Indistinguishable from "no account" here, so it must not be treated as
      // one. Unbound, the draft gates nobody; it pre-fills /choose-handle, and
      // the island's handle_auto holds the account that does exist.
      final rest = FakeRestApi()
        ..finishPasskeyRegistrationReplyLost = StateError('connection reset');
      final c = makeContainer(rest: rest, passkey: FakePasskeyAuthClient());
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await register(c);

      expect(c.read(authControllerProvider).value, isNull);
      final owed = c.read(owedHandleProvider).draft;
      expect(owed?.handle, 'nicka', reason: 'the choice survives');
      expect(owed?.userId, isNull, reason: 'unbound: never a gate');
    });

    test(
      'a failed register/start never touches a debt another account owes',
      () async {
        final rest = FakeRestApi()
          ..startPasskeyRegistrationThrows = StateError('offline');
        final c = makeContainer(rest: rest, passkey: FakePasskeyAuthClient());
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);
        await c
            .read(owedHandleProvider.notifier)
            .owe(
              'someone-else',
              const OwedHandle(handle: 'robin', displayName: 'Robin'),
            );

        await register(c);

        final owed = c.read(owedHandleProvider).forAccount('someone-else');
        expect(owed?.userId, 'someone-else');
        expect(owed?.handle, 'robin');
      },
    );

    // ROUND 2's SCENARIO (Noether, Carnot, Tesla): A's PATCH failed, A signed
    // out, and B on the same device started a sign-up and cancelled it. With
    // one slot the cancel erased A's debt, which is A's only gate on an island
    // without handle_auto. The ceremony now touches only the device's draft.
    test('a prefs write that THROWS cannot fail a registration the island '
        'committed', () async {
      // bindDraft runs after register/finish made the account and before the
      // session is adopted, so an escaping exception left the user signed out
      // beside an account and a saved passkey (Carnot, cage-match #440 r3).
      final c = makeContainer(
        rest: FakeRestApi(),
        passkey: FakePasskeyAuthClient(),
        prefs: _ThrowingPrefs(),
      );
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await register(c);

      final user = c.read(authControllerProvider).value;
      expect(user, isNotNull, reason: 'signed in despite the disk');
      expect(user!.username, 'nicka');
      expect(_nothingOwed(c.read(owedHandleProvider)), isTrue);
    });

    test(
      'a CANCELLED sign-up by someone else never erases a debt an account owes',
      () async {
        final rest = FakeRestApi();
        final c = makeContainer(
          rest: rest,
          passkey: FakePasskeyAuthClient(
            registerThrows: const AuthCeremonyCancelled(),
          ),
        );
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);
        await c
            .read(owedHandleProvider.notifier)
            .owe(
              'account-a',
              const OwedHandle(handle: 'robin', displayName: 'Robin'),
            );

        await register(c);

        expect(rest.passkeyRegisterStartCalls, 1, reason: 'start succeeded');
        expect(
          c.read(owedHandleProvider).forAccount('account-a')?.handle,
          'robin',
        );
        expect(c.read(owedHandleProvider).draft, isNull);
      },
    );

    test(
      'a COMPLETED sign-up owes its own debt beside another account\'s',
      () async {
        final rest = FakeRestApi()..updateProfileThrows = const HandleTaken();
        final c = makeContainer(rest: rest, passkey: FakePasskeyAuthClient());
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);
        await c
            .read(owedHandleProvider.notifier)
            .owe(
              'account-a',
              const OwedHandle(handle: 'robin', displayName: 'Robin'),
            );

        await register(c);

        final owed = c.read(owedHandleProvider);
        expect(
          owed.forAccount('account-a')?.handle,
          'robin',
          reason: 'untouched',
        );
        expect(
          owed.forAccount(FakeRestApi.newAccountUser.userId)?.handle,
          'nicka',
          reason: 'the new account owes its own',
        );
        expect(owed.draft, isNull, reason: 'the draft became that debt');
      },
    );

    test('nothing is owed when the island made no account', () async {
      for (final rest in [
        FakeRestApi()..createsAccounts = false, // refused before the ceremony
        FakeRestApi()..startPasskeyRegistrationThrows = StateError('down'),
      ]) {
        final c = makeContainer(rest: rest, passkey: FakePasskeyAuthClient());
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);
        await register(c);
        expect(c.read(authControllerProvider).value, isNull);
        expect(_nothingOwed(c.read(owedHandleProvider)), isTrue);
      }
      final cancelled = makeContainer(
        rest: FakeRestApi(),
        passkey: FakePasskeyAuthClient(
          registerThrows: const AuthCeremonyCancelled(),
        ),
      );
      addTearDown(cancelled.dispose);
      await cancelled.read(authControllerProvider.future);
      await register(cancelled);
      expect(_nothingOwed(cancelled.read(owedHandleProvider)), isTrue);
    });

    test(
      'an island that still asks for the handle itself (PendingHandle) parks '
      'it for the claim screen, and the app owes nothing of its own',
      () async {
        final rest = FakeRestApi()
          ..passkeyRegisterOutcome = const PendingHandle(
            provisioningToken: 'passkey-prov',
            suggestedName: null,
          );
        final passkey = FakePasskeyAuthClient(attestation: 'attest-json');
        final c = makeContainer(rest: rest, passkey: passkey);
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);

        await register(c);

        expect(rest.passkeyRegisterStartCalls, 1);
        expect(passkey.registerCalls, 1);
        expect(rest.lastPasskeyRegisterState, 'reg-state');
        expect(rest.lastPasskeyRegisterCredential, 'attest-json');
        expect(
          c.read(authControllerProvider).value,
          isNull,
          reason: 'a new identity must claim a handle before being logged in',
        );
        expect(
          c.read(pendingHandleProvider)?.provisioningToken,
          'passkey-prov',
          reason: 'pending state drives the router to /claim-handle',
        );
        expect(_nothingOwed(c.read(owedHandleProvider)), isTrue);
      },
    );

    test('gateway logs straight in → authenticated', () async {
      final rest = FakeRestApi()
        ..passkeyRegisterOutcome = Authenticated(
          AuthSession(
            user: FakeRestApi.defaultUser,
            tokens: const AuthTokens(
              accessToken: 'access',
              refreshToken: 'refresh',
            ),
          ),
        );
      final passkey = FakePasskeyAuthClient();
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await register(c);

      expect(c.read(authControllerProvider).value, isNotNull);
    });

    // #436 part 2. The ceremony saves a passkey on the phone before the island
    // can refuse, so the island is asked first and a "no" must stop everything
    // before the platform sheet: no challenge, no ceremony, no orphan.
    test('island says it takes no new accounts → RegistrationClosed, and no '
        'ceremony is started', () async {
      final rest = FakeRestApi()..createsAccounts = false;
      final passkey = FakePasskeyAuthClient();
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await register(c);

      expect(c.read(authControllerProvider).error, isA<RegistrationClosed>());
      expect(c.read(authControllerProvider).value, isNull);
      expect(passkey.registerCalls, 0, reason: 'no passkey is created');
      expect(rest.passkeyRegisterStartCalls, 0, reason: 'no challenge either');
    });

    test(
      'island that does not say (null) → registers exactly as before',
      () async {
        final rest = FakeRestApi(); // createsAccounts null: an older island
        final passkey = FakePasskeyAuthClient();
        final c = makeContainer(rest: rest, passkey: passkey);
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);

        await register(c);

        expect(rest.createsAccountsCalls, 1, reason: 'it did ask');
        expect(passkey.registerCalls, 1, reason: 'absence is not a refusal');
        expect(rest.passkeyRegisterFinishCalls, 1);
        expect(c.read(authControllerProvider).hasError, isFalse);
      },
    );

    test('island says yes → registers', () async {
      final rest = FakeRestApi()..createsAccounts = true;
      final passkey = FakePasskeyAuthClient();
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await register(c);

      expect(passkey.registerCalls, 1);
      expect(rest.passkeyRegisterFinishCalls, 1);
    });

    test('user dismisses the sheet → no-op, finish not called', () async {
      final rest = FakeRestApi();
      final passkey = FakePasskeyAuthClient(
        registerThrows: const AuthCeremonyCancelled(),
      );
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await register(c);

      final state = c.read(authControllerProvider);
      expect(state.hasError, isFalse);
      expect(state.value, isNull);
      expect(rest.passkeyRegisterFinishCalls, 0);
    });

    test('ignored while already authenticated (ingress-only)', () async {
      final rest = FakeRestApi()
        ..passkeyRegisterOutcome = Authenticated(
          AuthSession(
            user: FakeRestApi.defaultUser,
            tokens: const AuthTokens(
              accessToken: 'access',
              refreshToken: 'refresh',
            ),
          ),
        );
      final passkey = FakePasskeyAuthClient();
      final c = makeContainer(rest: rest, passkey: passkey);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await register(c);
      expect(c.read(authControllerProvider).value, isNotNull);
      final callsAfterLogin = passkey.registerCalls;

      await register(c);
      expect(
        passkey.registerCalls,
        callsAfterLogin,
        reason: 'no registration is started while a session is live',
      );
    });
  });

  group('add passkey (link to existing account)', () {
    // Seed tokens so cold-start restore logs the user in — the live-session
    // precondition for linking.
    ProviderContainer signedIn(
      FakeRestApi rest,
      FakePasskeyAuthClient passkey,
    ) => makeContainer(
      rest: rest,
      passkey: passkey,
      store: InMemoryTokenStore(
        const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
      ),
    );

    // The trap the island's cage-match caught: register/start is ALSO
    // add-a-device's start. A closed island refuses new ACCOUNTS, never a
    // second passkey on an existing one, so the #436 gate must not reach here.
    test('a closed island still lets a signed-in user add a passkey', () async {
      final rest = FakeRestApi()..createsAccounts = false;
      final passkey = FakePasskeyAuthClient();
      final c = signedIn(rest, passkey);
      addTearDown(c.dispose);
      expect(await c.read(authControllerProvider.future), isNotNull);

      final added = await c
          .read(authControllerProvider.notifier)
          .addPasskeyToCurrentAccount();

      expect(added, isTrue);
      expect(rest.addPasskeyCalls, 1);
      expect(rest.createsAccountsCalls, 0, reason: 'add never asks');
    });

    test(
      'links via the AUTHED add endpoint without disturbing the session',
      () async {
        final rest = FakeRestApi();
        final passkey = FakePasskeyAuthClient(attestation: 'attest-json');
        final c = signedIn(rest, passkey);
        addTearDown(c.dispose);
        expect(
          await c.read(authControllerProvider.future),
          isNotNull,
          reason: 'precondition: signed in',
        );

        final added = await c
            .read(authControllerProvider.notifier)
            .addPasskeyToCurrentAccount();

        expect(added, isTrue);
        expect(
          rest.passkeyRegisterStartCalls,
          1,
          reason: 'reuses the identity-agnostic register-start challenge',
        );
        expect(passkey.registerCalls, 1);
        expect(
          rest.addPasskeyCalls,
          1,
          reason: 'finishes via the authed add endpoint',
        );
        expect(rest.lastAddPasskeyState, 'reg-state');
        expect(
          rest.lastPasskeyRegisterName,
          FakeRestApi.defaultUser.username,
          reason: 'the new passkey is labelled with the signed-in handle',
        );
        expect(rest.lastAddPasskeyCredential, 'attest-json');
        expect(
          rest.passkeyRegisterFinishCalls,
          0,
          reason: 'must NOT use the account-minting register/finish',
        );
        final st = c.read(authControllerProvider);
        expect(
          st.value,
          isNotNull,
          reason: 'still signed in — no logout/loading bounce',
        );
        expect(
          st.isLoading,
          isFalse,
          reason: 'the global auth state machine is untouched',
        );
      },
    );

    test(
      'user dismisses the sheet → false, credential not sent, still signed in',
      () async {
        final rest = FakeRestApi();
        final passkey = FakePasskeyAuthClient(
          registerThrows: const AuthCeremonyCancelled(),
        );
        final c = signedIn(rest, passkey);
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);

        final added = await c
            .read(authControllerProvider.notifier)
            .addPasskeyToCurrentAccount();

        expect(added, isFalse, reason: 'cancellation is not a successful add');
        expect(rest.addPasskeyCalls, 0);
        expect(c.read(authControllerProvider).value, isNotNull);
      },
    );

    test('throws when no session is live (link requires an account)', () async {
      final rest = FakeRestApi();
      final passkey = FakePasskeyAuthClient();
      final c = makeContainer(rest: rest, passkey: passkey); // no token → out
      addTearDown(c.dispose);
      expect(
        await c.read(authControllerProvider.future),
        isNull,
        reason: 'precondition: logged out',
      );

      await expectLater(
        c.read(authControllerProvider.notifier).addPasskeyToCurrentAccount(),
        throwsA(isA<StateError>()),
      );
      expect(
        passkey.registerCalls,
        0,
        reason: 'no ceremony started without a session',
      );
    });

    test(
      'a second concurrent link is a no-op (controller single-flight)',
      () async {
        // Assert the ORDERING INVARIANT, not just the outcome: while one link
        // ceremony is unresolved (sheet "open"), a second must NOT issue a second
        // gateway challenge — which would trip the authenticator's
        // cancelCurrentAuthenticatorOperation and cancel the first sheet.
        final rest = FakeRestApi();
        final gate = Completer<void>();
        final passkey = FakePasskeyAuthClient(
          attestation: 'attest-json',
          gate: gate,
        );
        final c = signedIn(rest, passkey);
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);

        // First link: not awaited — it parks on the gate inside register().
        final first = c
            .read(authControllerProvider.notifier)
            .addPasskeyToCurrentAccount();
        await pumpEventQueue();
        expect(rest.passkeyRegisterStartCalls, 1);
        expect(passkey.registerCalls, 1);

        // Second link while the first is in flight → short-circuits, no ceremony.
        final second = await c
            .read(authControllerProvider.notifier)
            .addPasskeyToCurrentAccount();
        expect(second, isFalse, reason: 'a concurrent link is a no-op');
        expect(
          rest.passkeyRegisterStartCalls,
          1,
          reason: 'no second challenge issued while one is in flight',
        );
        expect(
          passkey.registerCalls,
          1,
          reason: 'no second authenticator ceremony started',
        );

        // Release the first: it completes as a real add.
        gate.complete();
        expect(await first, isTrue);
        expect(rest.addPasskeyCalls, 1);
      },
    );

    test(
      'a 409 already-registered propagates and leaves the session intact',
      () async {
        final rest = FakeRestApi()
          ..addPasskeyThrows = const PasskeyAlreadyRegistered();
        final passkey = FakePasskeyAuthClient(attestation: 'attest-json');
        final c = signedIn(rest, passkey);
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);

        await expectLater(
          c.read(authControllerProvider.notifier).addPasskeyToCurrentAccount(),
          throwsA(isA<PasskeyAlreadyRegistered>()),
        );
        expect(
          c.read(authControllerProvider).value,
          isNotNull,
          reason: 'a failed link must not log the user out',
        );
        expect(
          c.read(authControllerProvider).hasError,
          isFalse,
          reason: 'the error is surfaced to the caller, not the auth state',
        );
      },
    );
  });
}

bool _nothingOwed(OwedHandles o) => o.draft == null && o.debts.isEmpty;

/// SharedPreferences whose every write throws, as a full or failing disk does.
/// Reads find nothing.
class _ThrowingPrefs implements SharedPreferences {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    if (name.contains('"set') ||
        name.contains('"remove') ||
        name.contains('"clear')) {
      return Future<bool>.error(StateError('disk full'));
    }
    if (name.contains('"getKeys')) return <String>{};
    if (name.contains('"containsKey')) return false;
    return null;
  }
}
