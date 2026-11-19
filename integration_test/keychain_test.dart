import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/services/session_vault.dart';

const _island = 'https://keychain-probe.invalid';

// A fresh vault reads the Keychain again, as the next launch would.
SessionVault _launch() => SessionVault(KeychainSlots(), placeLegacy: () => null);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('SessionVault data-protection keychain (#44)', () {
    setUp(() async => _launch().signOut());
    tearDown(() async => _launch().signOut());

    testWidgets('a sign-in round-trips across a relaunch without -34018', (
      tester,
    ) async {
      const tokens = AuthTokens(
        accessToken: 'access-keychain-probe',
        refreshToken: 'refresh-keychain-probe',
      );

      // The write is where -34018 fired before the signing/entitlement fix.
      final writer = _launch();
      await writer.adopt(_island, tokens, since: writer.lease);

      final read = await _launch().present(_island);
      expect(read, isNotNull);
      expect(read!.accessToken, tokens.accessToken);
    });

    testWidgets('a sign-out survives a relaunch', (tester) async {
      final vault = _launch();
      await vault.adopt(
        _island,
        const AuthTokens(accessToken: 'a', refreshToken: 'r'),
        since: vault.lease,
      );
      await vault.signOut();
      expect(await _launch().present(_island), isNull);
    });
  });
}
