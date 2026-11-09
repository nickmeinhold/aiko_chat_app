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
import 'package:aiko_chat_app/core/prefs/pref_key_migration.dart';
import 'package:aiko_chat_app/features/auth/data/cached_user_store.dart';
import 'package:aiko_chat_app/features/auth/data/passkey_hint_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  // The same trap from the other side: this build's settle never reached disk,
  // and the person signed in. Their cached user now reads as old-build evidence,
  // so the settle alone would move them; the boot pin answers first, from the
  // island their tokens were minted on.
  test(
    'a fresh install whose save never reached disk is pinned back by its tokens',
    () async {
      final prefs = await freshPrefs();
      await CachedUserStore(prefs).write(FakeRestApi.defaultUser);
      final boot = await pinIslandForSurvivingTokens(
        prefs,
        keychain: () async => (held: true, mintedOn: kDefaultIslandBaseUrl),
      );
      expect(boot, IslandBoot.decided);
      expect(launch(prefs), kDefaultIslandBaseUrl);
    },
  );

  group('pinIslandForSurvivingTokens (boot, before anything resolves)', () {
    // Round 1 of the cage-match: "any token means the old default" pinned
    // every reinstall of an Enspyr account to imagineering, which then
    // received Enspyr's refresh token.
    test(
      'a reinstall holding tokens minted on the new default stays there',
      () async {
        final prefs = await freshPrefs();
        await pinIslandForSurvivingTokens(
          prefs,
          keychain: () async => (held: true, mintedOn: kDefaultIslandBaseUrl),
        );
        expect(launch(prefs), kDefaultIslandBaseUrl);
      },
    );

    test('tokens minted on any other island pin that island', () async {
      final prefs = await freshPrefs();
      await pinIslandForSurvivingTokens(
        prefs,
        keychain: () async => (held: true, mintedOn: 'https://other.island/'),
      );
      expect(launch(prefs), 'https://other.island');
    });

    test(
      'a reinstall holding an older build\'s untagged tokens → old default',
      () async {
        final prefs = await freshPrefs();
        await pinIslandForSurvivingTokens(
          prefs,
          keychain: () async => (held: true, mintedOn: null),
        );
        expect(launch(prefs), kLegacyDefaultIslandBaseUrl);
      },
    );

    test('no tokens → saves nothing, the settle decides', () async {
      final prefs = await freshPrefs();
      final boot = await pinIslandForSurvivingTokens(
        prefs,
        keychain: () async => (held: false, mintedOn: null),
      );
      expect(boot, IslandBoot.decided);
      expect(prefs.getString(islandBaseUrlPrefKey), isNull);
      expect(launch(prefs), kDefaultIslandBaseUrl);
    });

    // Round 1 again: the pin saved nothing here, and the settle that ran next
    // SAVED the new default from empty prefs, so a reinstall's old tokens were
    // presented to the wrong island once the Keychain opened.
    test('a Keychain that refuses (locked phone) decides nothing, even in the '
        'settle, and the next readable launch pins from the tokens', () async {
      final prefs = await freshPrefs();
      final boot = await pinIslandForSurvivingTokens(
        prefs,
        keychain: () async => throw StateError('errSecInteractionNotAllowed'),
      );
      expect(boot, IslandBoot.undecided);

      final locked = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          islandBootProvider.overrideWithValue(boot),
        ],
      );
      addTearDown(locked.dispose);
      locked.read(configProvider); // resolves for this launch only
      expect(prefs.getString(islandBaseUrlPrefKey), isNull);

      await pinIslandForSurvivingTokens(
        prefs,
        keychain: () async => (held: true, mintedOn: null),
      );
      expect(launch(prefs), kLegacyDefaultIslandBaseUrl);
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
          keychain: () async {
            asked = true;
            return (held: true, mintedOn: null);
          },
        );
        expect(asked, isFalse, reason: 'free on every launch after the first');
        expect(launch(prefs), kDefaultIslandBaseUrl);
      },
    );
  });
}
