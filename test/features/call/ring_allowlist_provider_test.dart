import 'dart:typed_data';

import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/call/application/ring_allowlist_provider.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/domain/origin_envelope.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The seam between the store and the ring's trust decision.
///
/// The first version of this provider was a plain `Provider` that read once and
/// cached forever, while the store's mutators wrote preferences and notified
/// nobody — so a grant was invisible until process death and, far worse, a
/// REVOKE had no effect. "Withdraw consent" was a button that lied. These tests
/// pin that consent MOVES, because a permission you cannot take back is not a
/// permission.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final resident = encodeMultikey(Uint8List(32)..[0] = 7);
  const alice = AppUser(
    userId: 'user-alice',
    username: 'alice',
    displayName: 'Alice',
    aikoUsername: 'alice',
  );

  Future<ProviderContainer> makeContainer({AppUser? user = alice}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentUserProvider.overrideWithValue(user),
      ],
    );
  }

  test('a grant is visible to the ring path IMMEDIATELY, not after a restart', () async {
    final c = await makeContainer();
    addTearDown(c.dispose);
    expect(c.read(ringAllowedKeysProvider), isEmpty);
    expect(await c.read(ringAllowedKeysProvider.notifier).allow(resident), isTrue);
    // Read the PROVIDER, not the store — this is the value `admitRing` is given.
    expect(c.read(ringAllowedKeysProvider), {resident});
  });

  test('a REVOKE takes effect immediately — consent must be withdrawable', () async {
    final c = await makeContainer();
    addTearDown(c.dispose);
    await c.read(ringAllowedKeysProvider.notifier).allow(resident);
    expect(c.read(ringAllowedKeysProvider), {resident});
    expect(await c.read(ringAllowedKeysProvider.notifier).revoke(resident), isTrue);
    expect(c.read(ringAllowedKeysProvider), isEmpty);
  });

  test('a malformed grant does not move the published state', () async {
    // Failure leaves state alone rather than optimistically updating, so what a
    // caller observes is what actually persisted.
    final c = await makeContainer();
    addTearDown(c.dispose);
    expect(await c.read(ringAllowedKeysProvider.notifier).allow('not-a-key'), isFalse);
    expect(c.read(ringAllowedKeysProvider), isEmpty);
  });

  test('signed out, the published set is empty and cannot be granted into', () async {
    final c = await makeContainer(user: null);
    addTearDown(c.dispose);
    expect(c.read(ringAllowedKeysProvider), isEmpty);
    expect(await c.read(ringAllowedKeysProvider.notifier).allow(resident), isFalse);
  });

  test('an UNAVAILABLE store publishes empty rather than throwing', () async {
    // REACH IS NEVER A GATE. Wiring this naively made the ring path hard-depend
    // on SharedPreferences, and an unavailable store stopped EVERY ring —
    // including from a person — for a feature the user may never have used. It
    // broke twelve existing ring tests. `sharedPreferencesProvider` throws when
    // unoverridden, which is exactly that condition.
    final c = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(alice)],
    );
    addTearDown(c.dispose);
    expect(c.read(ringAllowedKeysProvider), isEmpty);
  });
}
