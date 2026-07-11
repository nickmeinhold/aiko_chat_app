import 'package:aiko_chat_app/features/auth/data/cached_user_store.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Exercises the REAL persistence path — `AppUser.toJson` → jsonEncode →
/// SharedPreferences → jsonDecode → `AppUser.fromJson`. The offline-restore
/// tests use an in-memory fake that stores the object directly and so never
/// touch this serialization; a key typo in `toJson` (e.g. `userId` vs
/// `user_id`) would ship green without this. `fromJson` is also the production
/// gateway-wire parser, so a clean round-trip through it proves wire-compat.
void main() {
  const user = AppUser(
    userId: 'uid-1',
    username: 'nick',
    displayName: 'Nick M',
    aikoUsername: 'nick.aiko',
  );

  late SharedPreferences prefs;
  late CachedUserStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = CachedUserStore(prefs);
  });

  test('AppUser.toJson → fromJson round-trips every field', () {
    expect(AppUser.fromJson(user.toJson()), user);
  });

  test('write then read round-trips through real SharedPreferences', () async {
    expect(store.read(), isNull, reason: 'nothing persisted yet');
    await store.write(user);
    expect(store.read(), user, reason: 'the exact user survives serialization');
  });

  test('clear removes the persisted user', () async {
    await store.write(user);
    await store.clear();
    expect(store.read(), isNull);
  });

  test('a corrupt persisted value reads as null (never throws)', () async {
    await prefs.setString('aiko_cached_user', 'not-json{{{');
    expect(store.read(), isNull, reason: 'a bad cache must not brick launch');
  });
}
