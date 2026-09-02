// Renaming a SharedPreferences key is a data migration. These tests are the
// difference between "the constant reads nicely" and "the person who upgrades
// still lands on their own island".
import 'package:aiko_chat_app/core/prefs/pref_key_migration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

const _new = 'aiko_island_base_url';
const _old = 'aiko_gateway_base_url';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an install that predates the rename keeps its island', () async {
    final prefs = await prefsWith({_old: 'https://chat.example.com'});
    expect(
      readAndAdopt(prefs, key: _new, legacyKey: _old),
      'https://chat.example.com',
      reason:
          'without the fallback this returns null and the app silently '
          'moves the user to the compiled-in default island',
    );
  });

  test('reading ADOPTS the legacy value forward — this is what lets the '
      'fallback ever be deleted', () async {
    final prefs = await prefsWith({_old: 'https://chat.example.com'});
    readAndAdopt(prefs, key: _new, legacyKey: _old);
    await Future<void>.delayed(Duration.zero); // the write is fire-and-forget

    expect(prefs.getString(_new), 'https://chat.example.com');
    // The base-url key is written ONLY when someone switches island, which most
    // people never do. Read-legacy-without-adopting would leave those installs
    // on the old key forever, so removing the fallback would reset them — the
    // migration would look finished while never completing for anyone who
    // simply uses the app.
  });

  test(
    'the legacy key survives adoption, so a downgrade is not destructive',
    () async {
      final prefs = await prefsWith({_old: 'https://chat.example.com'});
      readAndAdopt(prefs, key: _new, legacyKey: _old);
      await Future<void>.delayed(Duration.zero);
      expect(prefs.getString(_old), 'https://chat.example.com');
    },
  );

  test(
    'the new key wins when both exist, and nothing is overwritten',
    () async {
      final prefs = await prefsWith({
        _old: 'https://old.example.com',
        _new: 'https://new.example.com',
      });
      expect(
        readAndAdopt(prefs, key: _new, legacyKey: _old),
        'https://new.example.com',
      );
      await Future<void>.delayed(Duration.zero);
      expect(prefs.getString(_new), 'https://new.example.com');
    },
  );

  test('a fresh install reads null and writes nothing', () async {
    final prefs = await prefsWith({});
    expect(readAndAdopt(prefs, key: _new, legacyKey: _old), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(prefs.getString(_new), isNull);
    expect(prefs.getString(_old), isNull);
  });

  test(
    'an empty legacy value is adopted verbatim, not treated as absent',
    () async {
      // The CALLER decides what an empty string means (config treats blank as
      // unset). Deciding it here would put that policy in two places.
      final prefs = await prefsWith({_old: ''});
      expect(readAndAdopt(prefs, key: _new, legacyKey: _old), '');
    },
  );
}
