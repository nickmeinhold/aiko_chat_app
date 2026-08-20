// The WIRING between auth and the push pairing.
//
// `device_registrar_test.dart` proves the registrar's own lifecycle in
// isolation. Nothing there can tell you whether anything ever CALLS it — which
// was true of this codebase for two commits: a complete, correct, fully-tested
// registrar that no code constructed. So every test here drives the REAL
// `AuthController` through sign-in and logout, and asserts what the registrar
// and the token store observed. A test that called `stop()` itself and checked
// the order it had just written would be fiction.
//
// All of these failures are silent in production: no exception, no red screen,
// nothing a user could report. The island simply holds a token the push service
// refuses to deliver to, or keeps one it should have forgotten.
import 'dart:async';

import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show AccountSuspended;
import 'package:aiko_chat_app/features/notifications/application/device_registrar.dart';
import 'package:aiko_chat_app/features/notifications/application/push_providers.dart';
import 'package:aiko_chat_app/features/notifications/domain/device_platform.dart';
import 'package:aiko_chat_app/features/notifications/domain/push_token_source.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

class _FakeSource implements PushTokenSource {
  _FakeSource({this.token = 'tok-1', this.granted = true});

  String? token;
  bool granted;
  final refreshes = StreamController<String>.broadcast();

  @override
  DevicePlatform get platform => DevicePlatform.fcm;
  @override
  Future<bool> requestPermission() async => granted;
  @override
  Future<String?> currentToken() async => token;
  @override
  Stream<String> tokenRefreshes() => refreshes.stream;
}

/// Records WHEN tokens were cleared, relative to the device unregister.
///
/// The ordering IS the invariant, and it cannot be seen from either side alone:
/// the rest api knows it was called, the token store knows it was cleared, and
/// only a shared log knows which happened first.
class _RecordingTokenStore extends InMemoryTokenStore {
  _RecordingTokenStore(this.log);
  final List<String> log;

  @override
  Future<void> clear() async {
    log.add('clearTokens');
    return super.clear();
  }
}

class _RecordingRestApi extends FakeRestApi {
  _RecordingRestApi(this.log);
  final List<String> log;

  @override
  Future<void> unregisterDevice(String token, {String? credential}) async {
    log.add('unregisterDevice($token)');
    return super.unregisterDevice(token, credential: credential);
  }
}

void main() {
  // These are plain `test`s, not `testWidgets`, so nothing has initialised the
  // binding — and `initializeTestEnvironment` reads a bundled asset.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeTestEnvironment();
  });

  // `testPrefs` is one instance shared by the whole suite, so a debt written by
  // one test would be inherited by the next and drained at its sign-in — a
  // cross-test leak that reads as a mysterious extra unregister.
  setUp(() => testPrefs.remove('aiko_pending_device_unregisters'));

  /// A container whose registrar is driven by [source], regardless of which
  /// host platform the suite happens to be running on.
  Future<ProviderContainer> harness({
    required FakeRestApi rest,
    required _FakeSource source,
    InMemoryTokenStore? store,
  }) async {
    final container = makeContainer(
      rest: rest,
      transport: FakeChatTransport(),
      store: store,
      pushSource: source,
    );
    addTearDown(container.dispose);
    // Alive before sign-in, exactly as main() keeps it alive before restore.
    //
    // A `read` is NOT enough: providers auto-dispose by default in Riverpod 3,
    // so reading once creates the listener and then immediately throws it away.
    // Production holds it via `ref.watch` in the root widget, which stays
    // mounted for the life of the app; a subscription is the container-level
    // equivalent.
    final sub = container.listen(pushPairingProvider, (_, _) {});
    addTearDown(sub.close);
    // Let the controller's initial build (session restore) SETTLE before the
    // test signs in. Without this the sign-in races the restore, the restore's
    // AsyncData(null) lands last, and the listener never sees the edge into a
    // session — the failure looks exactly like "the wiring is broken".
    await container.read(authControllerProvider.future);
    return container;
  }

  group('the registrar is reachable from the app at all', () {
    test('no token source yields no registrar', () {
      final container = makeContainer(
        rest: FakeRestApi(),
        transport: FakeChatTransport(),
        pushSource: null,
      );
      addTearDown(container.dispose);

      expect(
        container.read(deviceRegistrarProvider),
        isNull,
        reason:
            'null is the honest answer on desktop/web, and on Apple until '
            'the native APNs source lands — not a reason to substitute FCM',
      );
    });

    test('a token source yields a registrar', () async {
      final container = await harness(
        rest: FakeRestApi(),
        source: _FakeSource(),
      );
      expect(container.read(deviceRegistrarProvider), isA<DeviceRegistrar>());
    });
  });

  group('signing in pairs the device', () {
    test('a real sign-in registers the current token', () async {
      final rest = FakeRestApi();
      final source = _FakeSource(token: 'tok-abc');
      final container = await harness(rest: rest, source: source);
      addTearDown(source.refreshes.close);

      await container.read(authControllerProvider.notifier).signInWithPasskey();
      await pumpEventQueue();

      expect(
        rest.registeredDevices.map((d) => d.token),
        ['tok-abc'],
        reason:
            'sign-in is the edge that pairs this handset; if this is empty '
            'the registrar exists but nothing drives it',
      );
      expect(rest.registeredDevices.single.platform, DevicePlatform.fcm);
    });

    test(
      'a refused permission registers nothing, and sign-in still works',
      () async {
        final rest = FakeRestApi();
        final source = _FakeSource(granted: false);
        final container = await harness(rest: rest, source: source);
        addTearDown(source.refreshes.close);

        await container
            .read(authControllerProvider.notifier)
            .signInWithPasskey();
        await pumpEventQueue();

        expect(rest.registeredDevices, isEmpty);
        expect(
          container.read(authControllerProvider).value,
          isNotNull,
          reason:
              'declining notifications is an ordinary answer, never a gate '
              'on signing in',
        );
      },
    );

    test('a token rotation after sign-in re-registers', () async {
      final rest = FakeRestApi();
      final source = _FakeSource(token: 'tok-1');
      final container = await harness(rest: rest, source: source);
      addTearDown(source.refreshes.close);

      await container.read(authControllerProvider.notifier).signInWithPasskey();
      await pumpEventQueue();
      source.refreshes.add('tok-2');
      await pumpEventQueue();

      expect(
        rest.registeredDevices.map((d) => d.token),
        ['tok-1', 'tok-2'],
        reason:
            'tokens rotate on reinstall and restore-from-backup; missing '
            'the refresh leaves the island holding an undeliverable token',
      );
    });
  });

  group('signing out unpairs it, and the credential dies FIRST', () {
    test('clearTokens runs BEFORE the unregister — the inversion is the '
        'deliverable', () async {
      final log = <String>[];
      final rest = _RecordingRestApi(log);
      final source = _FakeSource(token: 'tok-1');
      final container = await harness(
        rest: rest,
        source: source,
        store: _RecordingTokenStore(log),
      );
      addTearDown(source.refreshes.close);

      final auth = container.read(authControllerProvider.notifier);
      await auth.signInWithPasskey();
      await pumpEventQueue();
      expect(rest.registeredDevices, isNotEmpty, reason: 'precondition');

      await auth.logout();
      await pumpEventQueue();

      expect(
        log,
        ['clearTokens', 'unregisterDevice(tok-1)'],
        reason:
            'the DELETE is authenticated, which is why it USED to sit ahead of '
            'the clear — but nothing slow may sit there, and every guard for '
            'that just moved the contradiction. The credential now dies '
            'unconditionally and first, and the unregister carries a copy of it '
            'by value afterwards. Both still happen; neither waits for the '
            'other',
      );
      expect(
        rest.unregisterCredentials,
        [isNotNull],
        reason:
            'and it must be the credential that was just destroyed, carried by '
            'value — resolving one from the (now empty) store would 401',
      );
    });

    test(
      'the token unregistered is the CURRENT one after a rotation',
      () async {
        final rest = FakeRestApi();
        final source = _FakeSource(token: 'tok-1');
        final container = await harness(rest: rest, source: source);
        addTearDown(source.refreshes.close);

        final auth = container.read(authControllerProvider.notifier);
        await auth.signInWithPasskey();
        await pumpEventQueue();
        source.refreshes.add('tok-2');
        await pumpEventQueue();

        await auth.logout();
        await pumpEventQueue();

        expect(
          rest.unregisteredDevices,
          ['tok-2'],
          reason:
              'unregistering the token we first saw would leave the LIVE one '
              'routing to a signed-out account',
        );
      },
    );
  });

  group(
    'the OTHER session-ending paths — found by self-review, not by tests',
    () {
      test('switching island unpairs from the island being LEFT', () async {
        final log = <String>[];
        final rest = _RecordingRestApi(log);
        final source = _FakeSource(token: 'tok-1');
        final container = await harness(
          rest: rest,
          source: source,
          store: _RecordingTokenStore(log),
        );
        addTearDown(source.refreshes.close);

        final auth = container.read(authControllerProvider.notifier);
        await auth.signInWithPasskey();
        await pumpEventQueue();
        expect(rest.registeredDevices, isNotEmpty, reason: 'precondition');

        await auth.switchGateway('https://other.example');
        await pumpEventQueue();

        expect(
          log,
          ['clearTokens', 'unregisterDevice(tok-1)'],
          reason:
              'switchGateway tears down BY HAND rather than through '
              '_teardownResources, so it needs its own unpair. Without it the '
              'island you just left keeps a live routable token forever',
        );
        expect(
          testPrefs.getString('aiko_pending_device_unregisters'),
          isNot(contains('other.example')),
          reason:
              'any debt recorded here belongs to the island being LEFT. The '
              'unpair must therefore precede the invalidate(configProvider) in '
              "switchGateway's finally — after it, both the REST client and the "
              'registrar have been rebuilt against the NEW island, so the debt '
              'would be keyed there and its DELETE addressed to the wrong one',
        );
      });

      test('a ban unpairs the device too', () async {
        final log = <String>[];
        final rest = _RecordingRestApi(log);
        final source = _FakeSource(token: 'tok-1');
        final container = await harness(
          rest: rest,
          source: source,
          store: _RecordingTokenStore(log),
        );
        addTearDown(source.refreshes.close);

        final auth = container.read(authControllerProvider.notifier);
        await auth.signInWithPasskey();
        await pumpEventQueue();

        rest.meThrows = const AccountSuspended();
        await auth.refreshUser();
        await pumpEventQueue();

        expect(
          log.contains('unregisterDevice(tok-1)'),
          isTrue,
          reason:
              'a ban ends the session like any other terminal state; the row '
              'it leaves behind can never be cleared afterwards',
        );
        expect(
          log.indexOf('clearTokens') < log.indexOf('unregisterDevice(tok-1)'),
          isTrue,
          reason:
              'the credential still dies first — and it matters more here than '
              'anywhere: /suspended is a SOFT gate, so "try again" can reach '
              '/login and sign in at any instant. A path that held a window '
              'open would be holding it open against a live login screen',
        );
      });

      test('signing in again after a logout re-pairs the handset', () async {
        final rest = FakeRestApi();
        final source = _FakeSource(token: 'tok-1');
        final container = await harness(rest: rest, source: source);
        addTearDown(source.refreshes.close);

        final auth = container.read(authControllerProvider.notifier);
        await auth.signInWithPasskey();
        await pumpEventQueue();
        await auth.logout();
        await pumpEventQueue();
        await auth.signInWithPasskey();
        await pumpEventQueue();

        expect(
          rest.registeredDevices.map((d) => d.token),
          ['tok-1', 'tok-1'],
          reason:
              'the second session must re-register: stop() cleared the '
              'registrar memo, so this is not a no-op de-dupe',
        );
        expect(rest.unregisteredDevices, ['tok-1']);
      });
    },
  );

  group('there is no window left to guard', () {
    test('an unregister that NEVER completes does not delay the teardown by '
        'one microsecond', () async {
      // The load-bearing one. Under every previous design the DELETE sat inside
      // the teardown, so this container would hang here forever — and that hang
      // is precisely the window a re-login could land in. If a future change
      // reintroduces an awaited round trip on this path, this test stops
      // completing rather than starting to fail, which is the honest signal.
      final rest = FakeRestApi();
      rest.unregisterDeviceGate = Completer<void>().future; // never completes
      final source = _FakeSource(token: 'tok-1');
      addTearDown(source.refreshes.close);
      final transport = FakeChatTransport();
      final store = InMemoryTokenStore();
      final container = makeContainer(
        rest: rest,
        transport: transport,
        store: store,
        pushSource: source,
      );
      addTearDown(container.dispose);
      final sub = container.listen(pushPairingProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(authControllerProvider.future);

      final auth = container.read(authControllerProvider.notifier);
      await auth.signInWithPasskey();
      await pumpEventQueue();

      await auth.logout().timeout(const Duration(seconds: 2));

      expect(store.current, isNull, reason: 'the credential is gone');
      expect(
        transport.disconnectCalls,
        greaterThan(0),
        reason:
            'and so is the socket — the round-2 finding was that a guard on '
            'this path could abort the whole teardown, leaving the user on '
            '/login holding a live credential the next cold start restored',
      );
    });

    test('a re-login during the teardown is NOT stomped (Carnot R3-B)', () async {
      final rest = FakeRestApi();
      rest.unregisterDeviceGate = Completer<void>().future; // never completes
      final source = _FakeSource(token: 'tok-1');
      addTearDown(source.refreshes.close);
      final container = await harness(rest: rest, source: source);

      final auth = container.read(authControllerProvider.notifier);
      await auth.signInWithPasskey();
      await pumpEventQueue();

      await auth.logout();
      // The user signs in again. Under the old design this could interleave with
      // an in-flight teardown; there is now nothing left in flight to interleave
      // WITH, so the property holds by construction rather than by comparison.
      await container
          .read(tokenProviderProvider)
          .setTokens(const AuthTokens(accessToken: 'new', refreshToken: 'r2'));
      await pumpEventQueue();

      expect(
        await container.read(tokenProviderProvider).currentAccessToken(),
        'new',
        reason:
            "the reborn session's credential must survive — stomping it leaves "
            'the app logged-in-but-tokenless and every later call 401s',
      );
    });

    test(
      'an offline sign-out leaves a DEBT, not a silently-lost unregister',
      () async {
        final rest = FakeRestApi();
        rest.unregisterDeviceThrows = Exception('offline');
        final source = _FakeSource(token: 'tok-1');
        final container = await harness(rest: rest, source: source);
        addTearDown(source.refreshes.close);

        final auth = container.read(authControllerProvider.notifier);
        await auth.signInWithPasskey();
        await pumpEventQueue();
        await auth.logout();
        await pumpEventQueue();

        expect(
          testPrefs.getString('aiko_pending_device_unregisters'),
          contains('tok-1'),
          reason:
              'the residual the previous increment named as an accepted tradeoff. '
              'A sign-out with no network used to lose the unregister forever; it '
              'is now an obligation that outlives the session',
        );
      },
    );

    test('the next sign-in DRAINS the debt before registering — the ordering '
        'that makes a cross-user drain safe', () async {
      final rest = FakeRestApi();
      final source = _FakeSource(token: 'tok-1');
      final container = await harness(rest: rest, source: source);
      addTearDown(source.refreshes.close);
      final island = container.read(configProvider).httpBaseUrl;
      await container
          .read(pendingUnregisterStoreProvider)
          .remember(island, 'tok-owed');

      await container.read(authControllerProvider.notifier).signInWithPasskey();
      await pumpEventQueue();

      expect(rest.unregisteredDevices, [
        'tok-owed',
      ], reason: 'a debt outstanding at sign-in is paid off');
      expect(
        rest.registeredDevices,
        isNotEmpty,
        reason: 'and the new session still pairs',
      );
      // Reversed, the debt's token would have just been re-registered to the
      // CURRENT user — so the island's (user_id, token)-scoped delete would
      // match, and the drain would destroy the live pairing it just created.
      expect(
        container.read(pendingUnregisterStoreProvider).read(island),
        isNull,
      );
    });
  });
}
