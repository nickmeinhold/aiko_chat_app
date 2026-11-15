import 'dart:convert';

import 'package:aiko_chat_app/app/config.dart';
import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/prefs/pref_key_migration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/ui_fakes.dart';

/// Placement rules 2-4 (design 26 §2b) for a token pair an older build stored
/// without its island. These tests run as a store build: no `--dart-define`,
/// so the compiled default is the island older store builds started on.
void main() {
  Future<SharedPreferences> prefs(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test(
    'the saved island, which an older build presented its tokens to',
    () async {
      expect(
        legacySessionIsland(
          await prefs({islandBaseUrlPrefKey: 'https://chat.enspyr.co/'}),
        ),
        'https://chat.enspyr.co',
      );
    },
  );

  test('the saved island under its pre-rename key', () async {
    expect(
      legacySessionIsland(
        await prefs({kLegacyIslandBaseUrlPrefKey: 'https://chat.enspyr.co'}),
      ),
      'https://chat.enspyr.co',
    );
  });

  test('no saved island, but a cached user: a session ran on the compiled '
      'default', () async {
    expect(
      legacySessionIsland(
        await prefs({
          'aiko_cached_user': jsonEncode(FakeRestApi.defaultUser.toJson()),
        }),
      ),
      kDefaultIslandBaseUrl,
    );
  });

  test('nothing in prefs (a reinstall wiped them): nothing can say', () async {
    expect(legacySessionIsland(await prefs({})), isNull);
  });
}
