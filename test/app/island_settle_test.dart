// Moving the default island must move nobody (#436).
//
// Until 2026-10-28 an install that never opened the picker saved no island and
// re-read the compiled default on every launch. The default is now Enspyr, so
// an install that ran an older build has to stay on imagineering (with the
// tokens and push registration it holds there), a fresh one starts on Enspyr,
// and either answer is saved so the next default change reaches fresh installs
// only. See settleUnsavedIsland / pinIslandForSurvivingTokens.

import 'package:aiko_chat_app/app/config.dart';
import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/core/prefs/pref_key_migration.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/data/cached_user_store.dart';
import 'package:aiko_chat_app/features/auth/data/passkey_hint_store.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_chat_transport.dart';
import '../support/fakes.dart';
import '../support/ui_fakes.dart';

void main() {
  Future<SharedPreferences> freshPrefs([Map<String, Object> seed = const {}]) {
    SharedPreferences.setMockInitialValues(seed);
    return SharedPreferences.getInstance();
  }

  /// One launch: a new container over the SAME prefs, like a cold start.
  String launch(SharedPreferences prefs) {
    final c = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(c.dispose);
    return c.read(configProvider).httpBaseUrl;
  }

  group('settleUnsavedIsland (first build of configProvider)', () {
    test('a fresh install starts on the new default, and saves it', () async {
      final prefs = await freshPrefs();
      expect(launch(prefs), kDefaultIslandBaseUrl);
      expect(prefs.getString(islandBaseUrlPrefKey), kDefaultIslandBaseUrl);
    });

    test('an older build that was signed in stays where it was', () async {
      final prefs = await freshPrefs();
      await CachedUserStore(prefs).write(FakeRestApi.defaultUser);
      expect(launch(prefs), kLegacyDefaultIslandBaseUrl);
      expect(
        prefs.getString(islandBaseUrlPrefKey),
        kLegacyDefaultIslandBaseUrl,
      );
    });

    test('an older build signed out, holding a passkey for the old default, '
        'stays too', () async {
      final prefs = await freshPrefs();
      await PasskeyHintStore(prefs).markSeen(kLegacyDefaultIslandBaseUrl);
      expect(launch(prefs), kLegacyDefaultIslandBaseUrl);
    });

    test('a passkey for some OTHER island is not evidence', () async {
      final prefs = await freshPrefs();
      await PasskeyHintStore(prefs).markSeen('https://elsewhere.example');
      expect(launch(prefs), kDefaultIslandBaseUrl);
    });

    test('a saved choice always wins over evidence', () async {
      final prefs = await freshPrefs({
        islandBaseUrlPrefKey: kDefaultIslandBaseUrl,
      });
      await CachedUserStore(prefs).write(FakeRestApi.defaultUser);
      expect(launch(prefs), kDefaultIslandBaseUrl);
    });

    test(
      'a choice saved under the legacy key is adopted, not pinned over',
      () async {
        final prefs = await freshPrefs({
          kLegacyIslandBaseUrlPrefKey: kDefaultIslandBaseUrl,
        });
        await CachedUserStore(prefs).write(FakeRestApi.defaultUser);
        expect(launch(prefs), kDefaultIslandBaseUrl);
      },
    );

    // THE trap. Re-reading evidence on every launch would be wrong: a fresh
    // install's own first sign-in writes a cached user, which would then read
    // as "an older build was here" and move a new Enspyr user to imagineering.
    test(
      'a fresh install that signs in is still on the new default next launch',
      () async {
        final prefs = await freshPrefs();
        expect(launch(prefs), kDefaultIslandBaseUrl);
        await CachedUserStore(prefs).write(FakeRestApi.defaultUser);
        expect(launch(prefs), kDefaultIslandBaseUrl);
      },
    );
  });

  // The same trap from the other side: a session recorded before anything had
  // resolved the island. Recording a session resolves (and saves) the island
  // FIRST, so this build never leaves a cached user beside an unsaved island.
  test(
    'recording a session binds the island before the cached user lands',
    () async {
      final prefs = await freshPrefs();
      final store = InMemoryTokenStore(
        const AuthTokens(accessToken: 'a', refreshToken: 'r'),
      );
      late final ProviderContainer c;
      c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          secureTokenStoreProvider.overrideWithValue(store),
          restApiProvider.overrideWithValue(FakeRestApi()),
          transportProvider.overrideWithValue(FakeChatTransport()),
          tokenProviderProvider.overrideWithValue(
            DefaultTokenProvider(
              store: store,
              remoteRefresh: (_) async => 'a2',
              onUnauthenticated: () => c.read(authEventsProvider).add(null),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);

      // Restore runs me() and writes the cached user; nothing has read
      // configProvider before it.
      expect(await c.read(authControllerProvider.future), isNotNull);
      expect(CachedUserStore(prefs).read(), isNotNull);

      expect(prefs.getString(islandBaseUrlPrefKey), kDefaultIslandBaseUrl);
      expect(launch(prefs), kDefaultIslandBaseUrl);
    },
  );

  group('pinIslandForSurvivingTokens (boot, before anything resolves)', () {
    test(
      'a reinstall holding Keychain tokens, prefs empty → old default',
      () async {
        final prefs = await freshPrefs();
        await pinIslandForSurvivingTokens(prefs, hasTokens: () async => true);
        expect(launch(prefs), kLegacyDefaultIslandBaseUrl);
      },
    );

    test('no tokens → saves nothing, the settle decides', () async {
      final prefs = await freshPrefs();
      await pinIslandForSurvivingTokens(prefs, hasTokens: () async => false);
      expect(prefs.getString(islandBaseUrlPrefKey), isNull);
      expect(launch(prefs), kDefaultIslandBaseUrl);
    });

    test('a Keychain that refuses (locked phone) → saves nothing', () async {
      final prefs = await freshPrefs();
      await pinIslandForSurvivingTokens(
        prefs,
        hasTokens: () async => throw StateError('errSecInteractionNotAllowed'),
      );
      expect(prefs.getString(islandBaseUrlPrefKey), isNull);
    });

    test(
      'a saved choice is left alone and the Keychain is not asked',
      () async {
        final prefs = await freshPrefs({
          islandBaseUrlPrefKey: kDefaultIslandBaseUrl,
        });
        var asked = false;
        await pinIslandForSurvivingTokens(
          prefs,
          hasTokens: () async => asked = true,
        );
        expect(asked, isFalse, reason: 'free on every launch after the first');
        expect(launch(prefs), kDefaultIslandBaseUrl);
      },
    );
  });
}
