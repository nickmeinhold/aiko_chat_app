// Gateway picker (#4): the persisted config resolution + the security-critical
// switchGateway contract.
//
// switchGateway is the load-bearing correctness point: JWTs are minted by and
// valid only at the issuing gateway, so re-pointing the app is a SESSION
// boundary. The contract these tests pin (and RED-prove):
//   - a switch to a DIFFERENT gateway tears the session down — tokens cleared,
//     socket disconnected, state logged-out — and flips + persists the config;
//   - re-selecting the CURRENT gateway is a strict no-op — it must NEVER nuke a
//     live session (guarded on the normalized base URL).
// RED-prove: delete `await logout()` → the teardown test goes green-to-red;
// delete the `next == current` guard → the no-op test goes green-to-red.

import 'package:aiko_chat_app/app/config.dart';
import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/settings/application/gateway_directory_provider.dart';
import 'package:aiko_chat_app/features/settings/presentation/gateway_picker_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/fakes.dart';
import '../../support/ui_fakes.dart';

const _kKey = 'aiko_gateway_base_url';

void main() {
  group('GatewayConfigController resolution order', () {
    test('with nothing persisted, resolves the prod default', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);

      expect(c.read(configProvider).httpBaseUrl, kDefaultGatewayBaseUrl);
    });

    test('a persisted choice WINS over the default', () async {
      SharedPreferences.setMockInitialValues({_kKey: 'http://localhost:8095/'});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);

      // Resolved AND normalized (trailing slash stripped).
      expect(c.read(configProvider).httpBaseUrl, 'http://localhost:8095');
    });
  });

  group('AuthController.switchGateway', () {
    /// A logged-in container: real config + real auth controller, leaf seams
    /// faked. Seeded tokens + FakeRestApi.me() restore the session to logged-in.
    Future<({ProviderContainer container, InMemoryTokenStore store, FakeChatTransport transport, SharedPreferences prefs})>
        loggedInContainer() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = InMemoryTokenStore(
          const AuthTokens(accessToken: 'a', refreshToken: 'r'));
      final transport = FakeChatTransport();
      late final ProviderContainer container;
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        secureTokenStoreProvider.overrideWithValue(store),
        restApiProvider.overrideWithValue(FakeRestApi()),
        transportProvider.overrideWithValue(transport),
        tokenProviderProvider.overrideWithValue(DefaultTokenProvider(
          store: store,
          remoteRefresh: (_) async => 'a2',
          onUnauthenticated: () => container.read(authEventsProvider).add(null),
        )),
      ]);
      // Drive the cold-start restore to a logged-in session.
      await container.read(authControllerProvider.future);
      expect(container.read(authControllerProvider).value, isNotNull,
          reason: 'precondition: session restored to logged-in');
      // Initial gateway is the prod default (nothing persisted).
      expect(
          container.read(configProvider).httpBaseUrl, kDefaultGatewayBaseUrl);
      return (container: container, store: store, transport: transport, prefs: prefs);
    }

    test('switching to a DIFFERENT gateway tears down the session AND switches',
        () async {
      final h = await loggedInContainer();
      addTearDown(h.container.dispose);

      await h.container
          .read(authControllerProvider.notifier)
          .switchGateway('http://localhost:8095');

      // Session torn down — the JWT for the old gateway is gone before any call
      // could fire it at the new host.
      expect(await h.store.read(), isNull, reason: 'tokens cleared on switch');
      expect(h.transport.disconnectCalls, greaterThanOrEqualTo(1),
          reason: 'old socket disconnected');
      expect(h.container.read(authControllerProvider).value, isNull,
          reason: 'logged out → router lands on /login for the new gateway');
      // Config flipped + persisted.
      expect(h.container.read(configProvider).httpBaseUrl,
          'http://localhost:8095');
      expect(h.prefs.getString(_kKey), 'http://localhost:8095');
    });

    test('publishes loading BEFORE logged-out, so login is blocked mid-switch',
        () async {
      // Carnot F1: a plain logout() publishes data(null) before teardown +
      // config-flip, exposing a window where the router lands on /login against
      // the OLD gateway. The switch must instead pass through `loading` (router
      // → /splash) until the config has flipped. RED-prove: revert switchGateway
      // to `await logout()` and the loading state never appears → this fails.
      final h = await loggedInContainer();
      addTearDown(h.container.dispose);

      final sawLoading = <bool>[];
      h.container.listen(authControllerProvider,
          (_, next) => sawLoading.add(next.isLoading), fireImmediately: false);

      await h.container
          .read(authControllerProvider.notifier)
          .switchGateway('http://localhost:8095');

      expect(sawLoading.contains(true), isTrue,
          reason: 'switch parked auth in loading → router /splash, login blocked');
      expect(sawLoading.last, isFalse,
          reason: 'settles at a concrete logged-out state, not stuck loading');
      expect(h.container.read(authControllerProvider).value, isNull);
    });

    test('a teardown failure still flips config to the new gateway (no '
        'old-gateway login window on the error path)', () async {
      // Carnot re-review: if _teardownResources throws (e.g. transport.disconnect
      // after tokens are cleared), the config flip must STILL happen — otherwise
      // the app lands on /login against the OLD cached gateway while the new one
      // is already persisted. RED-prove: move `ref.invalidate` out of the finally
      // (into the try, before teardown can throw) → this fails.
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = InMemoryTokenStore(
          const AuthTokens(accessToken: 'a', refreshToken: 'r'));
      final transport = _ThrowingDisconnectTransport();
      late final ProviderContainer container;
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        secureTokenStoreProvider.overrideWithValue(store),
        restApiProvider.overrideWithValue(FakeRestApi()),
        transportProvider.overrideWithValue(transport),
        tokenProviderProvider.overrideWithValue(DefaultTokenProvider(
          store: store,
          remoteRefresh: (_) async => 'a2',
          onUnauthenticated: () => container.read(authEventsProvider).add(null),
        )),
      ]);
      addTearDown(container.dispose);
      await container.read(authControllerProvider.future);

      // Does not throw (teardown error swallowed — the switch still completed).
      await container
          .read(authControllerProvider.notifier)
          .switchGateway('http://localhost:8095');

      expect(transport.disconnectCalls, greaterThanOrEqualTo(1),
          reason: 'teardown was attempted');
      expect(container.read(configProvider).httpBaseUrl, 'http://localhost:8095',
          reason: 'config flipped to the new gateway despite teardown error');
      expect(container.read(authControllerProvider).value, isNull);
    });

    test('a token-CLEAR failure is NOT silently swallowed (it propagates)',
        () async {
      // Carnot final re-review: the narrow swallow covers only the best-effort
      // disconnect. A failure to clear the OLD credential is security-critical
      // and must surface (→ picker error UI), not vanish. The config still flips
      // in the finally so the app can't brick on /splash. RED-prove: widen the
      // catch back to the whole teardown → this stops throwing.
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = _ThrowingClearStore(
          const AuthTokens(accessToken: 'a', refreshToken: 'r'));
      late final ProviderContainer container;
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        secureTokenStoreProvider.overrideWithValue(store),
        restApiProvider.overrideWithValue(FakeRestApi()),
        transportProvider.overrideWithValue(FakeChatTransport()),
        tokenProviderProvider.overrideWithValue(DefaultTokenProvider(
          store: store,
          remoteRefresh: (_) async => 'a2',
          onUnauthenticated: () => container.read(authEventsProvider).add(null),
        )),
      ]);
      addTearDown(container.dispose);
      await container.read(authControllerProvider.future);

      await expectLater(
        container
            .read(authControllerProvider.notifier)
            .switchGateway('http://localhost:8095'),
        throwsA(isA<Exception>()),
        reason: 'a token-clear failure surfaces instead of being swallowed',
      );
      // Even so, the config flipped (finally) and the app is logged out — no
      // stuck-loading brick on /splash.
      expect(container.read(configProvider).httpBaseUrl, 'http://localhost:8095');
      expect(container.read(authControllerProvider).value, isNull);
    });

    test('re-selecting the CURRENT gateway is a no-op (keeps the session)',
        () async {
      final h = await loggedInContainer();
      addTearDown(h.container.dispose);

      // Same gateway, with a trailing slash — normalization must treat it as a
      // no-op and NOT log the user out.
      await h.container
          .read(authControllerProvider.notifier)
          .switchGateway('$kDefaultGatewayBaseUrl/');

      expect(await h.store.read(), isNotNull, reason: 'tokens kept — no logout');
      expect(h.transport.disconnectCalls, 0, reason: 'no teardown on no-op');
      expect(h.container.read(authControllerProvider).value, isNotNull,
          reason: 'still logged in');
      // Persistence untouched (no write on a no-op).
      expect(h.prefs.getString(_kKey), isNull);
    });
  });

  group('GatewayPickerScreen', () {
    Future<ProviderContainer> pumpPicker(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = InMemoryTokenStore(
          const AuthTokens(accessToken: 'a', refreshToken: 'r'));
      final transport = FakeChatTransport();
      late final ProviderContainer container;
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        secureTokenStoreProvider.overrideWithValue(store),
        restApiProvider.overrideWithValue(FakeRestApi()),
        transportProvider.overrideWithValue(transport),
        tokenProviderProvider.overrideWithValue(DefaultTokenProvider(
          store: store,
          remoteRefresh: (_) async => 'a2',
          onUnauthenticated: () => container.read(authEventsProvider).add(null),
        )),
        // No live directory here — these tests exercise the picker/switch flow,
        // not discovery. An empty result makes the screen render the known seed
        // set and fires no real network (which would leak a pending timer).
        gatewayDirectoryProvider.overrideWith((ref) async => const []),
      ]);
      await container.read(authControllerProvider.future);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: GatewayPickerScreen()),
      ));
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('renders the presets and marks the active gateway',
        (tester) async {
      final container = await pumpPicker(tester);
      addTearDown(container.dispose);

      expect(find.text('Production'), findsOneWidget);
      expect(find.text('Local'), findsOneWidget);
      expect(find.text('Android emulator'), findsOneWidget);
      // Initial gateway is prod → its tile shows "Connected".
      expect(find.text('Connected'), findsOneWidget);
    });

    testWidgets('confirming a different preset switches the gateway',
        (tester) async {
      final container = await pumpPicker(tester);
      addTearDown(container.dispose);

      await tester.tap(find.text('Local'));
      await tester.pumpAndSettle();
      // The confirm dialog warns about sign-out before committing.
      expect(find.text('Switch server?'), findsOneWidget);

      await tester.tap(find.text('Switch'));
      await tester.pumpAndSettle();

      expect(container.read(configProvider).httpBaseUrl,
          'http://localhost:8095');
    });

    testWidgets('an invalid custom URL is rejected (no switch)', (tester) async {
      final container = await pumpPicker(tester);
      addTearDown(container.dispose);

      await tester.enterText(find.byType(TextField), 'not a url');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      // No confirm dialog, gateway unchanged.
      expect(find.text('Switch server?'), findsNothing);
      expect(
          container.read(configProvider).httpBaseUrl, kDefaultGatewayBaseUrl);
    });
  });
}

/// A transport whose `disconnect` throws AFTER recording the attempt — to drive
/// the teardown-error path of `switchGateway` (Carnot re-review).
class _ThrowingDisconnectTransport extends FakeChatTransport {
  @override
  Future<void> disconnect() async {
    await super.disconnect(); // increments disconnectCalls
    throw Exception('disconnect boom');
  }
}

/// A token store whose `clear` throws — to drive the security-critical
/// token-clear failure path of `switchGateway` (Carnot final re-review).
class _ThrowingClearStore extends InMemoryTokenStore {
  _ThrowingClearStore(AuthTokens initial) : super(initial);
  @override
  Future<void> clear() async => throw Exception('keychain delete boom');
}
