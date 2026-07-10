import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/legal/application/eula_controller.dart';
import 'package:aiko_chat_app/features/settings/application/gateway_directory_provider.dart';
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
export 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart' show HandleTaken, SoleAdminDeletionBlocked;
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
}) {
  final tokenStore = store ?? InMemoryTokenStore();
  late final ProviderContainer container;
  container = ProviderContainer(overrides: [
    // The Settings Server tile + the config layer read SharedPreferences; inject
    // the in-memory instance loaded in setUpAll so configProvider resolves.
    sharedPreferencesProvider.overrideWithValue(testPrefs),
    restApiProvider.overrideWithValue(rest),
    transportProvider.overrideWithValue(transport),
    // The real passkey client hits the platform authenticator — a
    // FakePasskeyAuthClient drives the ceremony without a platform channel.
    // Tests inject a throwing/gated one to exercise cancel/failure paths.
    passkeyAuthClientProvider.overrideWithValue(passkey ?? FakePasskeyAuthClient()),
    // EULA acceptance is faked at its store seam. Default ACCEPTED so existing
    // tests reach login/chat unchanged; gate-specific tests pass accepted:false.
    eulaStoreProvider.overrideWithValue(eula ?? FakeEulaStore(accepted: true)),
    // Inject the (real) Terms text synchronously so no async asset read races
    // pumpAndSettle. Loaded once from the bundled asset in setUpAll; a test can
    // pass a short string to exercise the no-scroll path.
    eulaTextProvider.overrideWith((ref) => eulaText ?? realEula),
    tokenProviderProvider.overrideWithValue(DefaultTokenProvider(
      store: tokenStore,
      remoteRefresh: (_) async => 'access2',
      onUnauthenticated: () => container.read(authEventsProvider).add(null),
    )),
    // The real cacheProvider is now file-backed via path_provider, which has no
    // platform channel under flutter_test. Widget tests get an in-memory cache
    // that, like the real provider, is disposed and recreated across auth
    // sessions — ensuring no state leaks between tests.
    cacheProvider.overrideWith((ref) {
      final db = DriftCache(NativeDatabase.memory());
      ref.onDispose(db.close);
      return db;
    }),
    // The gateway picker discovers from the live gateway (#36). App-shell tests
    // exercise navigation/UI, not discovery — stub it empty so no real network
    // fires (which would leak a pending timer past widget disposal). The picker
    // then renders the bundled seed set.
    gatewayDirectoryProvider.overrideWith((ref) async => const []),
  ]);
  return container;
}

Future<void> pumpApp(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const AikoChatApp(),
    ),
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
  await tester.tap(find.text('Already have a passkey? Sign in'));
  await tester.pumpAndSettle();
}
