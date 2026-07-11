// Unit tests for the moderation application layer (#7): the block list controller
// and the derived blocked-id set that drives the client-side message hide.
//
// Uses the proven full-graph container (faked seams + a real auth controller over
// an in-memory token store), mirroring widget_test.dart, then logs in so
// blockedUsersProvider sees an authenticated user.

import 'dart:async';

import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/moderation/application/moderation_controller.dart';
import 'package:aiko_chat_app/features/moderation/domain/moderation_models.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/fakes.dart';
import '../../support/ui_fakes.dart';

ProviderContainer _loggedInContainer(FakeRestApi rest) {
  late final ProviderContainer container;
  container = ProviderContainer(
    overrides: [
      restApiProvider.overrideWithValue(rest),
      transportProvider.overrideWithValue(FakeChatTransport()),
      passkeyAuthClientProvider.overrideWithValue(FakePasskeyAuthClient()),
      cachedUserStoreProvider.overrideWithValue(InMemoryCachedUserStore()),
      tokenProviderProvider.overrideWithValue(
        DefaultTokenProvider(
          store: InMemoryTokenStore(),
          remoteRefresh: (_) async => 'access2',
          onUnauthenticated: () => container.read(authEventsProvider).add(null),
        ),
      ),
      cacheProvider.overrideWith((ref) => DriftCache(NativeDatabase.memory())),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<ProviderContainer> _loggedIn(FakeRestApi rest) async {
  final c = _loggedInContainer(rest);
  await c.read(authControllerProvider.future); // settle cold-start restore
  await c.read(authControllerProvider.notifier).signInWithPasskey();
  return c;
}

void main() {
  test('loads the existing block list on build', () async {
    final rest = FakeRestApi();
    await rest.blockUser('u2');
    final c = await _loggedIn(rest);

    final blocks = await c.read(blockedUsersProvider.future);
    expect(blocks.map((b) => b.userId), ['u2']);
    expect(c.read(blockedUserIdsProvider), {'u2'});
  });

  test('block adds to the id set (drives the client-side hide)', () async {
    final rest = FakeRestApi();
    final c = await _loggedIn(rest);
    await c.read(blockedUsersProvider.future);

    await c.read(blockedUsersProvider.notifier).block('u2', displayName: 'Alice');

    expect(c.read(blockedUserIdsProvider), {'u2'});
    expect(c.read(blockedUsersProvider).value!.single.displayName, 'Alice');
    expect(rest.blocks.map((b) => b.userId), contains('u2'));
  });

  test('unblock removes from the id set', () async {
    final rest = FakeRestApi();
    await rest.blockUser('u2');
    final c = await _loggedIn(rest);
    await c.read(blockedUsersProvider.future);

    await c.read(blockedUsersProvider.notifier).unblock('u2');

    expect(c.read(blockedUserIdsProvider), isEmpty);
    expect(rest.blocks, isEmpty);
  });

  test('block is idempotent in local state (no duplicate row)', () async {
    final rest = FakeRestApi();
    final c = await _loggedIn(rest);
    await c.read(blockedUsersProvider.future);

    await c.read(blockedUsersProvider.notifier).block('u2');
    await c.read(blockedUsersProvider.notifier).block('u2');

    expect(c.read(blockedUsersProvider).value, hasLength(1));
  });

  test('report forwards to the gateway, no local state change', () async {
    final rest = FakeRestApi();
    final c = await _loggedIn(rest);
    await c.read(blockedUsersProvider.future);

    await c
        .read(blockedUsersProvider.notifier)
        .report('m1', ReportReason.harassment);

    expect(rest.reportCalls, [('m1', ReportReason.harassment)]);
    expect(c.read(blockedUserIdsProvider), isEmpty); // reporting never blocks
  });

  test('block WAITS for the in-flight initial load before mutating — the race '
      'guard contract (cage-match Carnot HIGH)', () async {
    // The clobber Carnot flagged (a stale build publishing over the mutation) is a
    // nondeterministic microtask race; rather than assert a flaky OUTCOME, this
    // pins the GUARD that removes the race deterministically: block() must not
    // complete until the initial listBlocks load has settled, so build() can never
    // land after — and thus never clobber — the mutation.
    final rest = FakeRestApi();
    final c = _loggedInContainer(rest);
    await c.read(authControllerProvider.future);
    await c.read(authControllerProvider.notifier).signInWithPasskey();

    // Hold the initial GET in flight, THEN start the build so it parks in loading.
    rest.listBlocksGate = Completer<void>();
    c.read(blockedUsersProvider);

    var blockDone = false;
    final blockFut = c
        .read(blockedUsersProvider.notifier)
        .block('u2', displayName: 'Alice')
        .then((_) => blockDone = true);

    // Let microtasks drain. With the await-future guard, block() is still parked
    // on the gated load → NOT done. Without it, block() races ahead and completes.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(blockDone, isFalse,
        reason: 'block must wait for the initial load to settle before mutating');

    rest.listBlocksGate!.complete();
    await blockFut;
    expect(blockDone, isTrue);
    expect(c.read(blockedUserIdsProvider), {'u2'});
  });

  test('a failing block surfaces the error and leaves state unchanged', () async {
    final rest = FakeRestApi();
    final c = await _loggedIn(rest);
    await c.read(blockedUsersProvider.future);
    rest.moderationThrows = StateError('boom');

    await expectLater(
      c.read(blockedUsersProvider.notifier).block('u2'),
      throwsA(isA<StateError>()),
    );
    expect(c.read(blockedUserIdsProvider), isEmpty);
  });
}
