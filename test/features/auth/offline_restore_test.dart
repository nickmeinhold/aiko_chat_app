import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show Unauthorized, NetworkUnavailable;
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
    container = ProviderContainer(overrides: [
      restApiProvider.overrideWithValue(rest),
      transportProvider.overrideWithValue(FakeChatTransport()),
      passkeyAuthClientProvider
          .overrideWithValue(passkey ?? FakePasskeyAuthClient()),
      cachedUserStoreProvider
          .overrideWithValue(cached ?? InMemoryCachedUserStore()),
      tokenProviderProvider.overrideWithValue(DefaultTokenProvider(
        store: tokenStore,
        remoteRefresh: (_) async => 'access2',
        onUnauthenticated: () => container.read(authEventsProvider).add(null),
      )),
    ]);
    return container;
  }

  group('cold-start restore', () {
    test('valid tokens + me() ok → authenticated; refreshes the cache',
        () async {
      final rest = FakeRestApi();
      final cache = InMemoryCachedUserStore(); // empty
      final c = makeContainer(
          rest: rest, store: InMemoryTokenStore(seededTokens), cached: cache);
      addTearDown(c.dispose);

      final user = await c.read(authControllerProvider.future);

      expect(user, FakeRestApi.defaultUser);
      expect(rest.meCalls, 1);
      expect(cache.written, FakeRestApi.defaultUser,
          reason: 'a successful me() keeps the offline cache fresh');
    });

    test(
        'valid tokens + NetworkUnavailable + cached user present → OPTIMISTIC restore',
        () async {
      final rest = FakeRestApi(meThrows: const NetworkUnavailable());
      final cache = InMemoryCachedUserStore(cachedUser);
      final store = InMemoryTokenStore(seededTokens);
      final c = makeContainer(rest: rest, store: store, cached: cache);
      addTearDown(c.dispose);

      final user = await c.read(authControllerProvider.future);

      expect(user, cachedUser,
          reason: 'a returning user opens the app offline from the cache');
      expect(rest.meCalls, 1, reason: 'we did try the network first');
      expect(store.current, isNotNull,
          reason: 'tokens kept — transport revalidates on connect');
      expect(cache.cleared, isFalse, reason: 'a network blip is not a logout');
    });

    test('valid tokens + NetworkUnavailable + NO cached user → logged out',
        () async {
      final rest = FakeRestApi(meThrows: const NetworkUnavailable());
      final c = makeContainer(
          rest: rest,
          store: InMemoryTokenStore(seededTokens),
          cached: InMemoryCachedUserStore()); // empty
      addTearDown(c.dispose);

      final user = await c.read(authControllerProvider.future);

      expect(user, isNull,
          reason: 'first-ever launch offline has no identity to show');
    });

    test('valid tokens + NON-network error + cached user → FAIL CLOSED (logged out)',
        () async {
      // The server ANSWERED with something unexpected (not a clean unreachable
      // signal). "Not Unauthorized" must NOT be treated as "transient" — a trust
      // boundary grants an optimistic session only on a recognized network
      // failure, never on an unknown one. (Carnot/Tesla: no trust laundering.)
      final rest = FakeRestApi(meThrows: Exception('surprise 500 / bad shape'));
      final cache = InMemoryCachedUserStore(cachedUser);
      final store = InMemoryTokenStore(seededTokens);
      final c = makeContainer(rest: rest, store: store, cached: cache);
      addTearDown(c.dispose);

      final user = await c.read(authControllerProvider.future);

      expect(user, isNull, reason: 'unknown error → login, not optimistic auth');
      expect(store.current, isNotNull,
          reason: 'tokens kept for a later retry (unknown ≠ terminal)');
    });

    test('commit-time guard: tokens cleared DURING me() → no resurrection',
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

      expect(user, isNull,
          reason: 'tokens gone at commit time → no optimistic resurrection');
    });

    test('valid tokens + me() terminal Unauthorized → logged out; tokens + cache cleared',
        () async {
      final rest = FakeRestApi(meThrows: const Unauthorized(401));
      final cache = InMemoryCachedUserStore(cachedUser);
      final store = InMemoryTokenStore(seededTokens);
      final c = makeContainer(rest: rest, store: store, cached: cache);
      addTearDown(c.dispose);

      final user = await c.read(authControllerProvider.future);

      expect(user, isNull);
      expect(store.current, isNull, reason: 'dead tokens cleared');
      expect(cache.cleared, isTrue,
          reason: 'cache lifecycle is symmetric with the tokens');
    });

    test('no tokens → logged out, me() never called', () async {
      final rest = FakeRestApi();
      final c = makeContainer(rest: rest, cached: InMemoryCachedUserStore());
      addTearDown(c.dispose);

      expect(await c.read(authControllerProvider.future), isNull);
      expect(rest.meCalls, 0);
    });
  });

  group('cache lifecycle symmetry', () {
    test('sign-in writes the cached user', () async {
      final rest = FakeRestApi();
      final cache = InMemoryCachedUserStore();
      final c = makeContainer(
          rest: rest,
          cached: cache,
          passkey: FakePasskeyAuthClient(assertion: 'assert-json'));
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future); // logged out

      await c.read(authControllerProvider.notifier).signInWithPasskey();

      expect(c.read(authControllerProvider).value, isNotNull);
      expect(cache.written, isNotNull,
          reason: 'a fresh login seeds the offline cache');
    });

    test('a FALSE write (persistence failure, no throw) triggers a clear',
        () async {
      // SharedPreferences.setString returns false on failure without throwing.
      // A false write must degrade to a clear so a stale identity can't survive
      // a new login's fresh tokens (Carnot, PR #71).
      final rest = FakeRestApi();
      final cache = InMemoryCachedUserStore()..failWrites = true;
      final c = makeContainer(
          rest: rest,
          cached: cache,
          passkey: FakePasskeyAuthClient(assertion: 'assert-json'));
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);

      await c.read(authControllerProvider.notifier).signInWithPasskey();

      expect(c.read(authControllerProvider).value, isNotNull,
          reason: 'a cache persistence failure must not break login');
      expect(cache.current, isNull,
          reason: 'a failed write leaves NO cached identity, never a stale one');
      expect(cache.cleared, isTrue, reason: 'the clear fallback fired');
    });

    test('logout clears the cached user', () async {
      final rest = FakeRestApi();
      final cache = InMemoryCachedUserStore(cachedUser);
      final c = makeContainer(
          rest: rest, store: InMemoryTokenStore(seededTokens), cached: cache);
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future); // restored (online)

      await c.read(authControllerProvider.notifier).logout();

      expect(c.read(authControllerProvider).value, isNull);
      expect(cache.cleared, isTrue);
    });
  });
}
