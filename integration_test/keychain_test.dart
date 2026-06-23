// Runtime proof for task #44: the macOS data-protection keychain.
//
// flutter_secure_storage defaults to the data-protection keychain on macOS, which
// requires the app to be signed with a real development team and carry a
// keychain-access-groups entitlement. Without that, a write throws PlatformException
// -34018 (errSecMissingEntitlement) — the bug that blocked login during the live e2e.
//
// This test exercises the SAME SecureTokenStore (default FlutterSecureStorage, i.e.
// usesDataProtectionKeychain=true) on the signed Runner build. A green run on macOS
// is the boundary-crossing instrument the unit-test pyramid can't be: it proves the
// keychain WRITE actually succeeds at runtime, not merely that the entitlement is in
// the signature.
//
// Run: flutter test integration_test/keychain_test.dart -d macos
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/services/secure_token_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('SecureTokenStore data-protection keychain (#44)', () {
    final store = SecureTokenStore();

    setUp(() async => store.clear());
    tearDown(() async => store.clear());

    testWidgets('write then read round-trips without -34018', (tester) async {
      const tokens = AuthTokens(
        accessToken: 'access-keychain-probe',
        refreshToken: 'refresh-keychain-probe',
      );

      // The write is where -34018 fired before the signing/entitlement fix.
      await store.write(tokens);

      final read = await store.read();
      expect(read, isNotNull);
      expect(read!.accessToken, tokens.accessToken);
      expect(read.refreshToken, tokens.refreshToken);
    });

    testWidgets('clear removes the persisted pair', (tester) async {
      await store.write(const AuthTokens(
        accessToken: 'a',
        refreshToken: 'r',
      ));
      await store.clear();
      expect(await store.read(), isNull);
    });
  });
}
