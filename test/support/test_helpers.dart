import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/core/network/network_status.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/legal/application/eula_controller.dart';
import 'package:aiko_chat_app/features/notifications/application/push_providers.dart';
import 'package:aiko_chat_app/features/notifications/domain/push_token_source.dart';
import 'package:aiko_chat_app/features/settings/application/island_directory_provider.dart';
import 'package:aiko_chat_app/main.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart' show rootBundle, MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_chat_transport.dart';
import 'fakes.dart';
import 'ui_fakes.dart';

export 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
export 'package:aiko_chat_app/features/auth/domain/identity_models.dart';
export 'package:aiko_chat_app/features/auth/data/auth_exceptions.dart';
export 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show HandleTaken, SoleAdminDeletionBlocked;
export 'fake_chat_transport.dart';
export 'fakes.dart';
export 'ui_fakes.dart';

/// The real bundled Terms text, loaded once during environment initialization.
String realEula = '';

/// In-memory SharedPreferences for the config layer (the Settings Server tile).
late SharedPreferences testPrefs;

/// Initializes the shared test environment once per test suite execution.
Future<void> initializeTestEnvironment() async {
  realEula = await rootBundle.loadString('assets/legal/eula.md');
  SharedPreferences.setMockInitialValues({});
  testPrefs = await SharedPreferences.getInstance();
  // The sovereign key store (sovereign-message-signing) reads flutter_secure_
  // storage on first message send; mock the platform channel in-memory so widget
  // tests that build chatRepositoryProvider don't fail on the missing channel.
  installSecureStorageMock();
}

/// In-memory mock of the flutter_secure_storage platform channel. Shared by the
/// widget-test environment and the signing unit tests so neither touches a real
/// Keychain/Keystore.
void installSecureStorageMock() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final backing = <String, String>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
        switch (call.method) {
          case 'write':
            backing[args['key'] as String] = args['value'] as String;
            return null;
          case 'read':
            return backing[args['key'] as String];
          case 'delete':
            backing.remove(args['key'] as String);
            return null;
          case 'readAll':
            return backing;
          case 'deleteAll':
            backing.clear();
            return null;
          default:
            return null;
        }
      });
}

/// Build a container wiring the real graph to faked seams. The token provider
/// is a real [DefaultTokenProvider] over an in-memory store (so login actually
/// persists tokens), but its refresh never hits the network.
ProviderContainer makeContainer({
  required FakeRestApi rest,
  required FakeChatTransport transport,
  InMemoryTokenStore? store,
  FakePasskeyAuthClient? passkey,
  FakeEulaStore? eula,
  String? eulaText,
  DriftCache? cache,

  /// The push token source, ALWAYS overridden — null by default.
  ///
  /// Defaulting to null rather than leaving the real provider in place keeps
  /// every existing test deterministic: the real one keys off
  /// `defaultTargetPlatform`, so an un-overridden container would construct a
  /// real [FcmTokenSource] on whichever platform the suite reports, and reach
  /// for Firebase from a unit test. Null means "no registrar", which is what
  /// every test that does not care about push wants.
  PushTokenSource? pushSource,
}) {
  final tokenStore = store ?? InMemoryTokenStore();
  late final ProviderContainer container;
  container = ProviderContainer(
    overrides: [
      // The Settings Server tile + the config layer read SharedPreferences; inject
      // the in-memory instance loaded in setUpAll so configProvider resolves.
      sharedPreferencesProvider.overrideWithValue(testPrefs),
      restApiProvider.overrideWithValue(rest),
      transportProvider.overrideWithValue(transport),
      // The real passkey client hits the platform authenticator — a
      // FakePasskeyAuthClient drives the ceremony without a platform channel.
      // Tests inject a throwing/gated one to exercise cancel/failure paths.
      passkeyAuthClientProvider.overrideWithValue(
        passkey ?? FakePasskeyAuthClient(),
      ),
      // EULA acceptance is faked at its store seam. Default ACCEPTED so existing
      // tests reach login/chat unchanged; gate-specific tests pass accepted:false.
      eulaStoreProvider.overrideWithValue(
        eula ?? FakeEulaStore(accepted: true),
      ),
      // Inject the (real) Terms text synchronously so no async asset read races
      // pumpAndSettle. Loaded once from the bundled asset in setUpAll; a test can
      // pass a short string to exercise the no-scroll path.
      eulaTextProvider.overrideWith((ref) => eulaText ?? realEula),
      tokenProviderProvider.overrideWithValue(
        DefaultTokenProvider(
          store: tokenStore,
          remoteRefresh: (_) async => 'access2',
          onUnauthenticated: () => container.read(authEventsProvider).add(null),
        ),
      ),
      // Offline-first restore reads/writes the cached user; use an in-memory store
      // so tests neither touch a platform channel nor leak the cached user across
      // tests via the shared testPrefs.
      cachedUserStoreProvider.overrideWithValue(InMemoryCachedUserStore()),
      // The NetworkStatusBanner (login + chat) reads connectivity + reachability;
      // fake both so widget tests never touch the connectivity_plus platform
      // channel or the network. Default online + reachable → no banner, behaviour
      // unchanged for existing tests.
      connectivityServiceProvider.overrideWithValue(FakeConnectivityService()),
      reachabilityProbeProvider.overrideWithValue(FakeReachabilityProbe()),
      // The real islandReachableProvider polls on a 5s Timer loop; stub it with a
      // one-shot reachable stream so widget tests don't trip "pending timer" at
      // teardown. (Its derived logic is covered in network_status_test.)
      islandReachableProvider.overrideWith((ref) => Stream.value(true)),
      // The real cacheProvider is now file-backed via path_provider, which has no
      // platform channel under flutter_test. Widget tests get an in-memory cache
      // that, like the real provider, is disposed and recreated across auth
      // sessions — ensuring no state leaks between tests.
      // A test may inject a PRE-SEEDED cache (e.g. to stage channel history that
      // exists before the app first observes it, for first-sight/unread tests); the
      // test owns its lifecycle. Otherwise a fresh in-memory cache per session.
      cacheProvider.overrideWith((ref) {
        if (cache != null) return cache;
        final db = DriftCache(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
      // The gateway picker discovers from the live gateway (#36). App-shell tests
      // exercise navigation/UI, not discovery — stub it empty so no real network
      // fires (which would leak a pending timer past widget disposal). The picker
      // then renders the bundled seed set.
      islandDirectoryProvider.overrideWith((ref) async => const []),
      pushTokenSourceProvider.overrideWithValue(pushSource),
    ],
  );
  return container;
}

Future<void> pumpApp(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const AikoChatApp()),
  );
  await tester.pumpAndSettle();
}

/// Drive passkey sign-in to the chat screen. Assumes a logged-out start.
/// [FakeRestApi.finishPasskeyAuthentication] defaults to an [Authenticated]
/// session and the injected [FakePasskeyAuthClient] returns a canned assertion
/// without hitting a platform channel, so tapping "Already have a passkey?"
/// immediately navigates to chat (the register button would instead land on the
/// claim-handle screen — first-passkey-creates-account).
Future<void> signIn(WidgetTester tester) async {
  // Tap the sign-in ingress WHATEVER IT IS CALLED. The login screen now swaps
  // which action is primary based on whether a passkey ceremony has already
  // succeeded on this device, so its label is 'Already have a passkey? Sign in'
  // on a fresh one and 'Sign in with your passkey' on a returning one.
  //
  // This helper used to tap the first string literally, which coupled every
  // caller to a label rather than to an INTENT: the moment a test signed in
  // once, `testPrefs` carried the hint forward and every later signIn() in that
  // file tapped a widget that no longer existed. One string, 15 files.
  await tapSignIn(tester);
  await tester.pumpAndSettle();
}

/// Tap the sign-in ingress WITHOUT settling.
///
/// Split out because some tests assert on the UNSETTLED window — a pane showing a
/// CircularProgressIndicator never settles, and that is the assertion. Those sites
/// drive fixed frames themselves, so a helper that calls `pumpAndSettle` hangs
/// them. Same label-agnostic lookup as [signIn].
Future<void> tapSignIn(WidgetTester tester) async {
  final returning = find.text('Sign in with your passkey');
  await tester.tap(
    returning.evaluate().isNotEmpty
        ? returning
        : find.text('Already have a passkey? Sign in'),
  );
}
