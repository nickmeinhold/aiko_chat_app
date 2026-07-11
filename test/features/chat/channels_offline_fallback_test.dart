import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/core/network/network_status.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show NetworkUnavailable;
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/fakes.dart';
import '../../support/ui_fakes.dart';

/// channelsProvider is offline-first (task #19): a reachable gateway refreshes
/// the cache; an unreachable one falls back to the cached list so a restored
/// user lands in cached chat, not the "Could not load channels" screen.
void main() {
  const c1 = Channel(id: 'c1', name: 'general', kind: ChannelKind.standard);
  const seededTokens = AuthTokens(accessToken: 'a', refreshToken: 'r');

  ProviderContainer makeContainer({
    required FakeRestApi rest,
    required DriftCache cache,
    FakeConnectivityService? connectivity,
  }) {
    late final ProviderContainer container;
    container = ProviderContainer(overrides: [
      restApiProvider.overrideWithValue(rest),
      transportProvider.overrideWithValue(FakeChatTransport()),
      cachedUserStoreProvider.overrideWithValue(InMemoryCachedUserStore()),
      connectivityServiceProvider
          .overrideWithValue(connectivity ?? FakeConnectivityService()),
      reachabilityProbeProvider.overrideWithValue(FakeReachabilityProbe()),
      cacheProvider.overrideWith((ref) => cache),
      tokenProviderProvider.overrideWithValue(DefaultTokenProvider(
        store: InMemoryTokenStore(seededTokens),
        remoteRefresh: (_) async => 'access2',
        onUnauthenticated: () => container.read(authEventsProvider).add(null),
      )),
    ]);
    return container;
  }

  test('online: fetches fresh channels AND refreshes the cache', () async {
    final cache = DriftCache(NativeDatabase.memory());
    addTearDown(cache.close);
    final rest = FakeRestApi(channels: const [c1]);
    final c = makeContainer(rest: rest, cache: cache);
    addTearDown(c.dispose);
    await c.read(authControllerProvider.future); // logged in

    final channels = await c.read(channelsProvider.future);

    expect(channels, [c1]);
    expect(await cache.readChannels(), [c1],
        reason: 'a successful fetch writes through to the offline cache');
  });

  test('offline: falls back to the cached channel list', () async {
    final cache = DriftCache(NativeDatabase.memory());
    addTearDown(cache.close);
    await cache.saveChannels(const [c1]); // a prior online session cached it
    final rest = FakeRestApi()..listChannelsThrows = const NetworkUnavailable();
    final c = makeContainer(rest: rest, cache: cache);
    addTearDown(c.dispose);
    await c.read(authControllerProvider.future);

    final channels = await c.read(channelsProvider.future);

    expect(channels, [c1],
        reason: 'unreachable gateway → cached chat, not an error');
  });

  test('offline with an empty cache: an empty list, never a raw error',
      () async {
    final cache = DriftCache(NativeDatabase.memory());
    addTearDown(cache.close);
    final rest = FakeRestApi()..listChannelsThrows = const NetworkUnavailable();
    final c = makeContainer(rest: rest, cache: cache);
    addTearDown(c.dispose);
    await c.read(authControllerProvider.future);

    expect(await c.read(channelsProvider.future), isEmpty);
  });

  test('the offline fallback is NOT sticky — recovery refetches', () async {
    // First-ever offline launch → []. When connectivity returns, channelsProvider
    // must re-run listChannels() rather than stay stuck on the empty cache
    // (Carnot, PR #72). Keep it alive with a listener so the connectivity edge
    // triggers a rebuild.
    final cache = DriftCache(NativeDatabase.memory());
    addTearDown(cache.close);
    final connectivity = FakeConnectivityService(online: true);
    final rest = FakeRestApi(channels: const [c1])
      ..listChannelsThrows = const NetworkUnavailable(); // offline at first
    final c = makeContainer(rest: rest, cache: cache, connectivity: connectivity);
    addTearDown(c.dispose);
    await c.read(authControllerProvider.future);
    c.listen(channelsProvider, (_, _) {}, fireImmediately: true);

    expect(await c.read(channelsProvider.future), isEmpty,
        reason: 'first-ever offline launch: empty');

    // Network recovers: gateway answers now, and connectivity emits a change.
    rest.listChannelsThrows = null;
    connectivity.emit(false); // a transition so .distinct() passes it through
    connectivity.emit(true); //  → online edge rebuilds channelsProvider
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await c.read(channelsProvider.future), [c1],
        reason: 'recovery refetched — not stuck on the empty offline result');
  });
}
