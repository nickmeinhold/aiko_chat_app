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
  Future<void> unregisterDevice(String token) async {
    log.add('unregisterDevice($token)');
    return super.unregisterDevice(token);
  }
}

void main() {
  // These are plain `test`s, not `testWidgets`, so nothing has initialised the
  // binding — and `initializeTestEnvironment` reads a bundled asset.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeTestEnvironment();
  });

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

  group('signing out unpairs it, in the only order that works', () {
    test('unregisterDevice completes BEFORE clearTokens', () async {
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
        ['unregisterDevice(tok-1)', 'clearTokens'],
        reason:
            'DELETE /v1/devices is AUTHENTICATED. Run after the token '
            'clear it 401s, the island row survives, and this handset keeps '
            'receiving the previous account pushes — silently, which on a '
            'shared phone is the privacy-relevant residual',
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
          ['unregisterDevice(tok-1)', 'clearTokens'],
          reason:
              'switchGateway tears down BY HAND rather than through '
              '_teardownResources, so it needs its own unpair. Without it the '
              'island you just left keeps a live routable token forever — the '
              'credential that could delete it is destroyed on the next line',
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
          log.indexOf('unregisterDevice(tok-1)') < log.indexOf('clearTokens'),
          isTrue,
          reason: 'still before the credential dies',
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

  group('the cage-match round-1 findings', () {
    test(
      'a registration in flight when the session ends does NOT survive it',
      () async {
        // Carnot + Tesla + Maxwell converged here. start() is deliberately
        // unawaited, so a sign-out can land between "POST issued" and "POST
        // returned": stop() sees _registered == null, unregisters nothing, and
        // the registration then completes on a dead session — the island keeps a
        // row written AFTER the unregister.
        final rest = FakeRestApi();
        final gate = Completer<void>();
        rest.registerDeviceGate = gate.future;
        final source = _FakeSource(token: 'tok-1');
        addTearDown(source.refreshes.close);
        final registrar = DeviceRegistrar(source: source, api: rest);

        final starting = registrar.start(); // will block inside registerDevice
        await pumpEventQueue();
        await registrar.stop(); // session ends mid-flight
        gate.complete(); // the POST now lands
        await starting;
        await pumpEventQueue();

        expect(rest.registeredDevices.map((d) => d.token), [
          'tok-1',
        ], reason: 'the POST did land — that is the premise, not the bug');
        expect(
          rest.unregisteredDevices,
          ['tok-1'],
          reason:
              'the late registration must be undone; without the generation '
              'guard the island keeps a routable row for an ended session',
        );
        expect(
          registrar.registeredToken,
          isNull,
          reason: 'and it must not be recorded as live',
        );
      },
    );

    test(
      'a re-login during the teardown await is NOT stomped (Carnot R3-B)',
      () async {
        // The unpair is a network round-trip placed ahead of clearTokens, and
        // logout publishes logged-out BEFORE awaiting it — so the router is on
        // /login and a re-sign-in can land inside the window. Without the fence
        // the trailing clearTokens() erases the NEW session's credential and the
        // app is logged-in-but-tokenless.
        final rest = FakeRestApi();
        final gate = Completer<void>();
        rest.unregisterDeviceGate = gate.future;
        final source = _FakeSource(token: 'tok-1');
        addTearDown(source.refreshes.close);
        final store = InMemoryTokenStore();
        final container = await harness(
          rest: rest,
          source: source,
          store: store,
        );

        final auth = container.read(authControllerProvider.notifier);
        await auth.signInWithPasskey();
        await pumpEventQueue();

        final loggingOut = auth.logout(); // blocks inside the unpair
        await pumpEventQueue();

        // The user signs in again while the teardown is still awaiting.
        await container
            .read(tokenProviderProvider)
            .setTokens(
              const AuthTokens(accessToken: 'new', refreshToken: 'r2'),
            );
        gate.complete();
        await loggingOut;
        await pumpEventQueue();

        expect(
          await container.read(tokenProviderProvider).currentAccessToken(),
          'new',
          reason:
              "the reborn session's credential must survive the teardown "
              'that was already in flight — stomping it leaves the app '
              'logged-in-but-tokenless and every later call 401s',
        );
      },
    );
  });
}
