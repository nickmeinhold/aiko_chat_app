// Design 27 (one session authority): every change to what the app shows about
// the session runs as one lease-checked transition. Each test here drives the
// real controller through an ordering the design names, and awaits the whole
// door, never a helper on its own. Numbers are the design's §5/§6 tests.

import 'dart:async';
import 'dart:typed_data';

import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/data/auth_exceptions.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/auth/domain/identity_models.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:aiko_chat_app/features/chat/data/gateway_rest_api.dart';
import 'package:aiko_chat_app/features/notifications/application/push_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/fakes.dart';
import '../../support/ui_fakes.dart';

void main() {
  const signedInTokens = AuthTokens(accessToken: 'a0', refreshToken: 'r0');

  ({ProviderContainer c, InMemoryTokenStore vault, FakeChatTransport socket})
  setUpApp({
    required FakeRestApi rest,
    AuthTokens? stored,
    FakePasskeyAuthClient? passkey,
    InMemoryCachedUserStore? cache,
    Future<RefreshResult> Function(String)? remoteRefresh,
  }) {
    final vault = InMemoryTokenStore(stored);
    final socket = FakeChatTransport();
    final c = ProviderContainer(
      overrides: [
        restApiProvider.overrideWithValue(rest),
        pushTokenSourceProvider.overrideWithValue(null),
        transportProvider.overrideWithValue(socket),
        passkeyAuthClientProvider.overrideWithValue(
          passkey ?? FakePasskeyAuthClient(),
        ),
        cachedUserStoreProvider.overrideWithValue(
          cache ?? InMemoryCachedUserStore(),
        ),
        tokenProviderProvider.overrideWithValue(
          DefaultTokenProvider(
            island: kTestIsland,
            vault: vault,
            remoteRefresh:
                remoteRefresh ?? (_) async => const RefreshResult('a1'),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    rest.presentedSession = () => vault.present(kTestIsland);
    return (c: c, vault: vault, socket: socket);
  }

  AuthController auth(ProviderContainer c) =>
      c.read(authControllerProvider.notifier);

  group('sign-in attempts (§2c, R3)', () {
    test('2 + 23: a sign-out during a first sign-in, on an empty vault, '
        'commits nothing and lands on /login, not stuck loading', () async {
      final gate = Completer<void>();
      final app = setUpApp(
        rest: FakeRestApi(),
        passkey: FakePasskeyAuthClient(gate: gate),
      );
      await app.c.read(authControllerProvider.future);

      final signingIn = auth(app.c).signInWithPasskey();
      await pumpEventQueue();
      await auth(app.c).logout();
      gate.complete();
      await signingIn;

      expect(app.vault.current, isNull, reason: 'the late sign-in adopted');
      final now = app.c.read(sessionPictureProvider);
      expect(now.auth.isLoading, isFalse, reason: 'stuck on /splash');
      expect(now.auth.value, isNull);
    });

    test('3: a sign-out queued while a sign-in writes its cached user ends '
        'it: no user shown, no cached user left', () async {
      final cache = _HeldCache();
      final app = setUpApp(rest: FakeRestApi(), cache: cache);
      await app.c.read(authControllerProvider.future);

      final signingIn = auth(app.c).signInWithPasskey();
      await cache.writing;
      final out = auth(app.c).logout();
      cache.release();
      await signingIn;
      await out;

      expect(app.c.read(authControllerProvider).value, isNull);
      expect(app.vault.current, isNull);
      expect(cache.current, isNull, reason: "A's face outlived A");
    });

    test('21: a cancelled sheet, then an error, each leave the door open for '
        'the next try', () async {
      final passkey = FakePasskeyAuthClient(
        authenticateThrows: const AuthCeremonyCancelled(),
      );
      final app = setUpApp(rest: FakeRestApi(), passkey: passkey);
      await app.c.read(authControllerProvider.future);

      await auth(app.c).signInWithPasskey();
      passkey.authenticateThrows = const AuthCeremonyFailed('Passkey: boom');
      await auth(app.c).signInWithPasskey();
      expect(app.c.read(authControllerProvider).hasError, isTrue);
      passkey.authenticateThrows = null;
      await auth(app.c).signInWithPasskey();

      expect(app.c.read(authControllerProvider).value, isNotNull);
      expect(passkey.authenticateCalls, 3, reason: 'a try was refused');
    });

    test('22: a pending handle, then its claim, signs in', () async {
      final rest = FakeRestApi()
        ..passkeyRegisterOutcome = const PendingHandle(provisioningToken: 'p');
      final app = setUpApp(rest: rest);
      await app.c.read(authControllerProvider.future);

      await auth(app.c).registerWithPasskey(handle: 'robin', displayName: 'R');
      expect(app.c.read(pendingHandleProvider), isNotNull);
      await auth(app.c).claimHandle('robin', 'Robin');

      expect(app.c.read(authControllerProvider).value, isNotNull);
      expect(app.c.read(pendingHandleProvider), isNull);
      expect(app.vault.current, isNotNull);
    });

    test('27: a sign-out during the owed-handle payment leaves the app '
        'signed out', () async {
      final rest = _HeldProfileRest();
      final app = setUpApp(rest: rest);
      await app.c.read(authControllerProvider.future);

      final signingUp = auth(
        app.c,
      ).registerWithPasskey(handle: 'robin', displayName: 'Robin');
      await rest.paying;
      await auth(app.c).logout();
      rest.release();
      await signingUp;

      expect(app.c.read(authControllerProvider).value, isNull);
      expect(app.vault.current, isNull);
    });
  });

  group('ends name their session (§2d, §2e, R1)', () {
    Future<Credential> signedInAs(({
      ProviderContainer c,
      InMemoryTokenStore vault,
      FakeChatTransport socket,
    }) app) async {
      await app.c.read(authControllerProvider.future);
      return (await app.vault.present(kTestIsland))!;
    }

    test('7 + R1: a 401 ends its session once; the second for the same '
        'credential tears nothing down', () async {
      final rest = FakeRestApi();
      final app = setUpApp(rest: rest, stored: signedInTokens);
      final a = await signedInAs(app);
      rest.meThrows = SessionUnauthorized(a);

      await Future.wait([auth(app.c).refreshUser(), auth(app.c).refreshUser()]);
      await pumpEventQueue();

      expect(app.c.read(authControllerProvider).value, isNull);
      expect(app.socket.disconnectCalls, 1);
    });

    test("8: a 401 for A's credential after B signed in leaves B", () async {
      final rest = FakeRestApi();
      final app = setUpApp(rest: rest, stored: signedInTokens);
      final a = await signedInAs(app);
      await auth(app.c).logout();
      await auth(app.c).signInWithPasskey();
      rest.meThrows = SessionUnauthorized(a);

      await auth(app.c).refreshUser();

      expect(app.c.read(authControllerProvider).value, isNotNull);
      expect(app.vault.current, isNotNull);
    });

    test('9: a 401 for the pre-rotation token, after a refresh, leaves the '
        'session that refreshed', () async {
      final rest = FakeRestApi();
      final app = setUpApp(rest: rest, stored: signedInTokens);
      final a = await signedInAs(app);
      await app.c.read(tokenProviderProvider).refresh(a);
      rest.meThrows = SessionUnauthorized(a);

      await auth(app.c).refreshUser();

      expect(app.c.read(authControllerProvider).value, isNotNull);
      expect(app.vault.current?.accessToken, 'a1');
    });

    test('10 + 12 + R1: a ban on the pre-rotation token, same lease, settles, '
        'and stays settled once the event loop drains', () async {
      final rest = FakeRestApi();
      final app = setUpApp(rest: rest, stored: signedInTokens);
      final a = await signedInAs(app);
      await app.c.read(tokenProviderProvider).refresh(a);
      rest.meThrows = SessionSuspended(a);

      await auth(app.c).refreshUser();
      await pumpEventQueue();

      expect(app.c.read(authControllerProvider).value, isNull);
      expect(app.c.read(suspendedProvider), isTrue);
      expect(app.vault.current, isNull);
    });

    test("11: a ban for A's session after B signed in neither suspends nor "
        'ends B', () async {
      final rest = FakeRestApi();
      final app = setUpApp(rest: rest, stored: signedInTokens);
      final a = await signedInAs(app);
      await auth(app.c).logout();
      await auth(app.c).signInWithPasskey();

      await auth(app.c).settleBan(SessionSuspended(a));

      expect(app.c.read(authControllerProvider).value, isNotNull);
      expect(app.c.read(suspendedProvider), isFalse);
    });

    test('14: a deletion whose success lands after B signed in leaves B',
        () async {
      final rest = _HeldDeleteRest();
      final app = setUpApp(rest: rest, stored: signedInTokens);
      await signedInAs(app);

      final deleting = auth(app.c).deleteAccount();
      await rest.deleting;
      await auth(app.c).logout();
      await auth(app.c).signInWithPasskey();
      rest.release();
      await deleting;

      expect(app.c.read(authControllerProvider).value, isNotNull);
      expect(app.vault.current, isNotNull);
    });

    test('25 + R4: a ban picture is never seen as (logged out, not '
        'suspended)', () async {
      final rest = FakeRestApi();
      final app = setUpApp(rest: rest, stored: signedInTokens);
      final a = await signedInAs(app);
      final seen = <SessionPicture>[];
      app.c.listen(sessionPictureProvider, (_, next) => seen.add(next));
      rest.meThrows = SessionSuspended(a);

      await auth(app.c).refreshUser();
      await pumpEventQueue();

      expect(seen, isNotEmpty);
      for (final p in seen) {
        if (p.auth.value == null) expect(p.suspended, isTrue);
      }
    });

    test('26 + R5: a refresh rejected during the boot me() wins: the restored '
        'user is not published', () async {
      final rest = FakeRestApi(meThrows: const NetworkUnavailable());
      final app = setUpApp(
        rest: rest,
        stored: signedInTokens,
        cache: InMemoryCachedUserStore(FakeRestApi.defaultUser),
        remoteRefresh: (_) async => throw const RefreshRejected(),
      );
      rest.onMe = () {
        unawaited(
          app.vault
              .present(kTestIsland)
              .then((a) => app.c.read(tokenProviderProvider).refresh(a!)),
        );
      };

      final user = await app.c.read(authControllerProvider.future);
      await pumpEventQueue();

      expect(user, isNull);
      expect(app.c.read(authControllerProvider).value, isNull);
      expect(app.c.read(sessionPictureProvider).auth.isLoading, isFalse);
    });

    test('17: a sign-out that misses the disk says so, and leaves no user '
        'readable anywhere', () async {
      final vault = _UnsavedSignOutVault(signedInTokens);
      final rest = FakeRestApi(
        user: const AppUser(
          userId: 'u1',
          username: 'mod',
          displayName: 'Mod',
          aikoUsername: 'mod',
          isModerator: true,
        ),
      );
      final c = ProviderContainer(
        overrides: [
          restApiProvider.overrideWithValue(rest),
          pushTokenSourceProvider.overrideWithValue(null),
          transportProvider.overrideWithValue(FakeChatTransport()),
          cachedUserStoreProvider.overrideWithValue(InMemoryCachedUserStore()),
          tokenProviderProvider.overrideWithValue(
            DefaultTokenProvider(
              island: kTestIsland,
              vault: vault,
              remoteRefresh: (_) async => const RefreshResult('a1'),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(authControllerProvider.future);
      expect(c.read(isModeratorProvider), isTrue, reason: 'precondition');

      await auth(c).logout();

      final now = c.read(authControllerProvider);
      expect(now.error, isA<SignOutUnsaved>());
      expect(now.value, isNull, reason: 'the old user is still readable');
      expect(c.read(isModeratorProvider), isFalse);
    });
  });

  group('the refresh bound (§2g, task 79)', () {
    test('18: a hung refresh ends at its deadline as transient, and the next '
        'refresh starts a new request', () async {
      const island = 'http://island.test';
      final network = _HungNetwork();
      final vault = InMemoryTokenStore();
      final backend = buildGatewayBackend(
        baseUrl: island,
        vault: vault,
        refreshDeadline: const Duration(milliseconds: 100),
        network: network,
      );
      await vault.adopt(island, signedInTokens, since: vault.lease);
      final a = (await backend.tokens.current())!;

      await expectLater(
        backend.tokens.refresh(a),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(
        backend.tokens.refresh(a),
        throwsA(isA<TimeoutException>()),
      );

      expect(network.sent, 2, reason: 'the first flight still held the slot');
      expect(vault.current, isNotNull, reason: 'a timeout is not a logout');
    });
  });
}

/// A cached-user store whose first write is held until released.
class _HeldCache extends InMemoryCachedUserStore {
  final _writing = Completer<void>();
  final _release = Completer<void>();
  Future<void> get writing => _writing.future;
  void release() => _release.complete();

  @override
  Future<bool> write(AppUser user) async {
    if (!_writing.isCompleted) {
      _writing.complete();
      await _release.future;
    }
    return super.write(user);
  }
}

/// The owed-handle payment (`PATCH /v1/me`) is held until released.
class _HeldProfileRest extends FakeRestApi {
  final _paying = Completer<void>();
  final _release = Completer<void>();
  Future<void> get paying => _paying.future;
  void release() => _release.complete();

  @override
  Future<AppUser> updateProfile({String? handle, String? displayName}) async {
    if (!_paying.isCompleted) {
      _paying.complete();
      await _release.future;
    }
    return super.updateProfile(handle: handle, displayName: displayName);
  }
}

/// `DELETE /v1/account` is held until released, then succeeds.
class _HeldDeleteRest extends FakeRestApi {
  final _deleting = Completer<void>();
  final _release = Completer<void>();
  Future<void> get deleting => _deleting.future;
  void release() => _release.complete();

  @override
  Future<void> deleteAccount() async {
    _deleting.complete();
    await _release.future;
    return super.deleteAccount();
  }
}

/// A network where every request is sent and never answered.
class _HungNetwork implements HttpClientAdapter {
  int sent = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    sent++;
    return Completer<ResponseBody>().future;
  }

  @override
  void close({bool force = false}) {}
}

/// A vault whose sign-out ends the session in memory but misses the disk.
class _UnsavedSignOutVault extends InMemoryTokenStore {
  _UnsavedSignOutVault(super.initial);

  @override
  Future<({Credential? ended, bool saved})> signOut() async {
    final out = await super.signOut();
    return (ended: out.ended, saved: false);
  }
}
