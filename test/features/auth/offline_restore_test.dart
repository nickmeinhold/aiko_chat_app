import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/notifications/application/push_providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/auth/domain/identity_models.dart'
    show PendingHandle;
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show AccountSuspended, Unauthorized, NetworkUnavailable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/fakes.dart';
import '../../support/ui_fakes.dart';

/// Offline-first session restore: a returning user with valid tokens lands in
/// their (cached) session even when the network is down, and only a *terminal*
/// 401 logs them out. The cached-user store's lifecycle stays symmetric with the
/// tokens'. (Plan: merry-inventing-quilt, PR1.)
void main() {
  // A cached identity distinct from FakeRestApi.defaultUser, so a passing test
  // can only be returning the CACHE, not coincidentally the fake's live user.
  const cachedUser = AppUser(
    userId: 'cached-uid',
    username: 'cached',
    displayName: 'Cached User',
    aikoUsername: 'cached.aiko',
  );

  const seededTokens = AuthTokens(accessToken: 'a', refreshToken: 'r');

  ProviderContainer makeContainer({
    required FakeRestApi rest,
    InMemoryTokenStore? store,
    InMemoryCachedUserStore? cached,
    FakePasskeyAuthClient? passkey,
  }) {
    final tokenStore = store ?? InMemoryTokenStore();
    late final ProviderContainer container;
    container = ProviderContainer(
      overrides: [
        restApiProvider.overrideWithValue(rest),
        // No push source, so no registrar. Without this the REAL provider
        // runs, and `flutter_test` reports the target platform as android —
        // so these auth-lifecycle tests would construct a live FcmTokenSource
        // and reach for Firebase. `test_helpers.makeContainer` overrides it to
        // null for the same reason; this fixture predates that.
        pushTokenSourceProvider.overrideWithValue(null),
        transportProvider.overrideWithValue(FakeChatTransport()),
        passkeyAuthClientProvider.overrideWithValue(
          passkey ?? FakePasskeyAuthClient(),
        ),
        cachedUserStoreProvider.overrideWithValue(
          cached ?? InMemoryCachedUserStore(),
        ),
        tokenProviderProvider.overrideWithValue(
          DefaultTokenProvider(
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

  group('cold-start restore', () {
    test(
      'valid tokens + me() ok → authenticated; refreshes the cache',
      () async {
        final rest = FakeRestApi();
        final cache = InMemoryCachedUserStore(); // empty
        final c = makeContainer(
          rest: rest,
          store: InMemoryTokenStore(seededTokens),
          cached: cache,
        );
        addTearDown(c.dispose);

        final user = await c.read(authControllerProvider.future);

        expect(user, FakeRestApi.defaultUser);
        expect(rest.meCalls, 1);
        expect(
          cache.written,
          FakeRestApi.defaultUser,
          reason: 'a successful me() keeps the offline cache fresh',
        );
      },
    );

    test(
      'valid tokens + NetworkUnavailable + cached user present → OPTIMISTIC restore',
      () async {
        final rest = FakeRestApi(meThrows: const NetworkUnavailable());
        final cache = InMemoryCachedUserStore(cachedUser);
        final store = InMemoryTokenStore(seededTokens);
        final c = makeContainer(rest: rest, store: store, cached: cache);
        addTearDown(c.dispose);

        final user = await c.read(authControllerProvider.future);

        expect(
          user,
          cachedUser,
          reason: 'a returning user opens the app offline from the cache',
        );
        expect(rest.meCalls, 1, reason: 'we did try the network first');
        expect(
          store.current,
          isNotNull,
          reason: 'tokens kept — transport revalidates on connect',
        );
        expect(
          cache.cleared,
          isFalse,
          reason: 'a network blip is not a logout',
        );
      },
    );

    test(
      'valid tokens + NetworkUnavailable + NO cached user → logged out',
      () async {
        final rest = FakeRestApi(meThrows: const NetworkUnavailable());
        final c = makeContainer(
          rest: rest,
          store: InMemoryTokenStore(seededTokens),
          cached: InMemoryCachedUserStore(),
        ); // empty
        addTearDown(c.dispose);

        final user = await c.read(authControllerProvider.future);

        expect(
          user,
          isNull,
          reason: 'first-ever launch offline has no identity to show',
        );
      },
    );

    test(
      'valid tokens + NON-network error + cached user → FAIL CLOSED (logged out)',
      () async {
        // The server ANSWERED with something unexpected (not a clean unreachable
        // signal). "Not Unauthorized" must NOT be treated as "transient" — a trust
        // boundary grants an optimistic session only on a recognized network
        // failure, never on an unknown one. (Carnot/Tesla: no trust laundering.)
        final rest = FakeRestApi(
          meThrows: Exception('surprise 500 / bad shape'),
        );
        final cache = InMemoryCachedUserStore(cachedUser);
        final store = InMemoryTokenStore(seededTokens);
        final c = makeContainer(rest: rest, store: store, cached: cache);
        addTearDown(c.dispose);

        final user = await c.read(authControllerProvider.future);

        expect(
          user,
          isNull,
          reason: 'unknown error → login, not optimistic auth',
        );
        expect(
          store.current,
          isNotNull,
          reason: 'tokens kept for a later retry (unknown ≠ terminal)',
        );
      },
    );

    test(
      'commit-time guard: tokens cleared DURING me() → no resurrection',
      () async {
        // The cold-start race (Tesla): a terminal `unauthenticated` signal fires
        // while me() is in flight, clearing the tokens + flipping to logged-out.
        // The optimistic branch must NOT then return the cached user and clobber
        // that logout — the commit-time token re-check catches it.
        final store = InMemoryTokenStore(seededTokens);
        final cache = InMemoryCachedUserStore(cachedUser);
        late final ProviderContainer c;
        final rest = FakeRestApi(meThrows: const NetworkUnavailable())
          ..onMe = () {
            // Simulate the concurrent teardown clearing the credential.
            c.read(tokenProviderProvider).clearTokens();
          };
        c = makeContainer(rest: rest, store: store, cached: cache);
        addTearDown(c.dispose);

        final user = await c.read(authControllerProvider.future);

        expect(
          user,
          isNull,
          reason: 'tokens gone at commit time → no optimistic resurrection',
        );
      },
    );

    test(
      'valid tokens + me() terminal Unauthorized → logged out; tokens + cache cleared',
      () async {
        final rest = FakeRestApi(meThrows: const Unauthorized(401));
        final cache = InMemoryCachedUserStore(cachedUser);
        final store = InMemoryTokenStore(seededTokens);
        final c = makeContainer(rest: rest, store: store, cached: cache);
        addTearDown(c.dispose);

        final user = await c.read(authControllerProvider.future);

        expect(user, isNull);
        expect(store.current, isNull, reason: 'dead tokens cleared');
        expect(
          cache.cleared,
          isTrue,
          reason: 'cache lifecycle is symmetric with the tokens',
        );
      },
    );

    test('no tokens → logged out, me() never called', () async {
      final rest = FakeRestApi();
      final c = makeContainer(rest: rest, cached: InMemoryCachedUserStore());
      addTearDown(c.dispose);

      expect(await c.read(authControllerProvider.future), isNull);
      expect(rest.meCalls, 0);
    });
  });

  group('account suspended (ban) drives the /suspended zone', () {
    test(
      'me() → AccountSuspended: flags suspended, clears dead tokens, logged out',
      () async {
        // A ban (403 account suspended) is terminal-for-this-island — the router
        // must send it to /suspended, NOT /login (which loops on re-auth). Tokens
        // are cleared like any terminal auth; the flag is what distinguishes it.
        final rest = FakeRestApi(meThrows: const AccountSuspended());
        final cache = InMemoryCachedUserStore(cachedUser);
        final store = InMemoryTokenStore(seededTokens);
        final c = makeContainer(rest: rest, store: store, cached: cache);
        addTearDown(c.dispose);

        final user = await c.read(authControllerProvider.future);

        expect(user, isNull);
        expect(
          c.read(suspendedProvider),
          isTrue,
          reason: 'ban → /suspended zone, not /login',
        );
        expect(
          store.current,
          isNull,
          reason: 'dead tokens cleared like any terminal auth',
        );
        expect(cache.cleared, isTrue);
      },
    );

    test(
      'a later successful me() (ban lifted) clears the suspended flag',
      () async {
        final rest = FakeRestApi(); // me() ok — the ban has lifted
        final c = makeContainer(
          rest: rest,
          store: InMemoryTokenStore(seededTokens),
          cached: InMemoryCachedUserStore(),
        );
        addTearDown(c.dispose);
        c.read(suspendedProvider.notifier).flag(); // pretend a prior ban

        final user = await c.read(authControllerProvider.future);

        expect(user, FakeRestApi.defaultUser);
        expect(
          c.read(suspendedProvider),
          isFalse,
          reason: 'a successful me() means the ban lifted → leave /suspended',
        );
      },
    );

    test(
      'ingress ceremony ban → flags suspended, clears the stale credential, clean state',
      () async {
        // Fail-closed restore keeps tokens while logged-out; a passkey sign-in
        // then resolves to a banned account. The ban must clear the lingering
        // credential (cage-match Carnot: a flag without a clear left a stale
        // token in the reservoir) AND reset the machine to a clean AsyncData(null)
        // — so a soft-gate dismiss lands on a clean /login, not the ban re-painted
        // as the login screen's inline error (cage-match Tesla: flag-only gate).
        final rest = FakeRestApi(
          meThrows: Exception('unknown → fail-closed, tokens kept'),
        )..finishAuthThrows = const AccountSuspended();
        final cache = InMemoryCachedUserStore(cachedUser);
        final store = InMemoryTokenStore(seededTokens);
        final c = makeContainer(
          rest: rest,
          store: store,
          cached: cache,
          passkey: FakePasskeyAuthClient(assertion: 'assert-json'),
        );
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future); // logged out, tokens KEPT
        expect(
          store.current,
          isNotNull,
          reason: 'precondition: fail-closed restore kept the tokens',
        );

        await c.read(authControllerProvider.notifier).signInWithPasskey();

        expect(
          c.read(suspendedProvider),
          isTrue,
          reason: 'a ceremony ban routes to /suspended',
        );
        expect(
          store.current,
          isNull,
          reason: 'the stale/dead credential is cleared (Carnot)',
        );
        expect(cache.cleared, isTrue);
        final auth = c.read(authControllerProvider);
        expect(
          auth.hasError,
          isFalse,
          reason:
              'machine reset to clean logged-out, not AsyncError(ban) (Tesla)',
        );
        expect(auth.value, isNull);
      },
    );

    test(
      'claimHandle ban → flags suspended (third door sealed, Tesla)',
      () async {
        final rest = FakeRestApi()..claimThrows = const AccountSuspended();
        final c = makeContainer(rest: rest, cached: InMemoryCachedUserStore());
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future); // logged out
        c
            .read(pendingHandleProvider.notifier)
            .set(const PendingHandle(provisioningToken: 'p'));

        await c
            .read(authControllerProvider.notifier)
            .claimHandle('robin', 'Robin');

        expect(
          c.read(suspendedProvider),
          isTrue,
          reason:
              'a banned claim routes to /suspended, not a claim-screen error',
        );
        expect(
          c.read(authControllerProvider).hasError,
          isFalse,
          reason: 'clean logged-out, not AsyncError(ban)',
        );
        expect(
          c.read(pendingHandleProvider),
          isNull,
          reason:
              'a terminal ban clears the provisioning path too — so a '
              'soft-gate dismiss lands on /login, NOT /claim-handle (cage-match '
              'Carnot + Tesla: the reservoir must be fully empty)',
        );
      },
    );

    test(
      'a plain terminal Unauthorized does NOT flag suspended (revoked ≠ ban)',
      () async {
        // The subtype must not smear: a 401 revoked session is logged-out, not
        // suspended. Only AccountSuspended flags the zone.
        final rest = FakeRestApi(meThrows: const Unauthorized(401));
        final c = makeContainer(
          rest: rest,
          store: InMemoryTokenStore(seededTokens),
          cached: InMemoryCachedUserStore(cachedUser),
        );
        addTearDown(c.dispose);

        await c.read(authControllerProvider.future);

        expect(
          c.read(suspendedProvider),
          isFalse,
          reason: 'a revoked 401 is logged-out, not suspended',
        );
      },
    );
  });

  group('cache lifecycle symmetry', () {
    test('sign-in writes the cached user', () async {
      final rest = FakeRestApi();
      final cache = InMemoryCachedUserStore();
      final c = makeContainer(
        rest: rest,
        cached: cache,
        passkey: FakePasskeyAuthClient(assertion: 'assert-json'),
      );
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future); // logged out

      await c.read(authControllerProvider.notifier).signInWithPasskey();

      expect(c.read(authControllerProvider).value, isNotNull);
      expect(
        cache.written,
        isNotNull,
        reason: 'a fresh login seeds the offline cache',
      );
    });

    test(
      'a FALSE write (persistence failure, no throw) triggers a clear',
      () async {
        // SharedPreferences.setString returns false on failure without throwing.
        // A false write must degrade to a clear so a stale identity can't survive
        // a new login's fresh tokens (Carnot, PR #71).
        final rest = FakeRestApi();
        final cache = InMemoryCachedUserStore()..failWrites = true;
        final c = makeContainer(
          rest: rest,
          cached: cache,
          passkey: FakePasskeyAuthClient(assertion: 'assert-json'),
        );
        addTearDown(c.dispose);
        await c.read(authControllerProvider.future);

        await c.read(authControllerProvider.notifier).signInWithPasskey();

        expect(
          c.read(authControllerProvider).value,
          isNotNull,
          reason: 'a cache persistence failure must not break login',
        );
        expect(
          cache.current,
          isNull,
          reason: 'a failed write leaves NO cached identity, never a stale one',
        );
        expect(cache.cleared, isTrue, reason: 'the clear fallback fired');
      },
    );

    test('logout clears the cached user', () async {
      final rest = FakeRestApi();
      final cache = InMemoryCachedUserStore(cachedUser);
      final c = makeContainer(
        rest: rest,
        store: InMemoryTokenStore(seededTokens),
        cached: cache,
      );
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future); // restored (online)

      await c.read(authControllerProvider.notifier).logout();

      expect(c.read(authControllerProvider).value, isNull);
      expect(cache.cleared, isTrue);
    });
  });
}
