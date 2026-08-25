import 'dart:typed_data';

import 'package:aiko_chat_app/features/call/data/ring_allowlist_store.dart';
import 'package:aiko_chat_app/features/chat/domain/origin_envelope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The store that decides who may wake you.
///
/// It had ZERO tests when it was written, and a four-way cage-match found three
/// defects in it — one of which threw on the very first grant anyone would ever
/// make. The domain predicate it feeds had eight tests; the thing feeding it had
/// none. That asymmetry is the lesson these tests exist to close.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final residentKey = Uint8List(32)..[0] = 7;
  final strangerKey = Uint8List(32)..[0] = 9;
  final resident = encodeMultikey(residentKey);
  final stranger = encodeMultikey(strangerKey);

  const alice = 'user-alice';
  const bob = 'user-bob';

  Future<RingAllowlistStore> storeFor(
    String? userId, {
    Map<String, Object> seed = const {},
  }) async {
    SharedPreferences.setMockInitialValues(seed);
    return RingAllowlistStore(await SharedPreferences.getInstance(), userId);
  }

  group('the first grant — the one that threw', () {
    test('granting into an EMPTY store works', () async {
      // THE regression. `read()` returned `const {}` when nothing was stored and
      // `allow()` did `read()..add(k)` — mutating an unmodifiable set. It threw
      // `UnsupportedError` at the exact moment consent is born, and every one of
      // the 1054 passing tests missed it because none of them touched the store.
      final s = await storeFor(alice);
      expect(s.read(), isEmpty);
      expect(await s.allow(resident), isTrue);
      expect(s.read(), {resident});
    });

    test('revoking from an EMPTY store does not throw either', () async {
      final s = await storeFor(alice);
      expect(await s.revoke(resident), isTrue);
      expect(s.read(), isEmpty);
    });

    test('read() is unmodifiable on EVERY path, not just some', () async {
      // The defect was a type that was sometimes mutable. Assert the invariant
      // directly, so a future `read()` that returns a growable set on one branch
      // fails here rather than in production on a branch no test visits.
      final empty = await storeFor(alice);
      expect(() => empty.read().add(resident), throwsUnsupportedError);
      await empty.allow(resident);
      expect(() => empty.read().add(stranger), throwsUnsupportedError);
      final corrupt = await storeFor(
        alice,
        seed: {'flutter.aiko_ring_allowed_keys_$alice': 'not json'},
      );
      expect(() => corrupt.read().add(resident), throwsUnsupportedError);
    });
  });

  group('consent belongs to a USER, not a handset', () {
    test("one user's consent is invisible to the next", () async {
      // Identity-as-mutable-key: the key used to be device-global, so Alice
      // consents, signs out, and Bob is woken at 3am for a covenant he never
      // made. Same prefs instance, two users — the sharing is what is tested.
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final aliceStore = RingAllowlistStore(prefs, alice);
      final bobStore = RingAllowlistStore(prefs, bob);

      expect(await aliceStore.allow(resident), isTrue);
      expect(aliceStore.read(), {resident});
      expect(bobStore.read(), isEmpty, reason: 'Bob inherits nothing');

      expect(await bobStore.allow(stranger), isTrue);
      expect(aliceStore.read(), {resident}, reason: "Bob cannot edit Alice's");
    });

    test('signed out, nobody can read or grant', () async {
      final s = await storeFor(null);
      expect(s.read(), isEmpty);
      expect(await s.allow(resident), isFalse);
      expect(await s.revoke(resident), isFalse);
    });
  });

  group('what is stored must be what is MATCHED', () {
    test('a stored key is byte-identical to what admitRing compares', () async {
      // `_mayRing` compares against `encodeMultikey(origin.rawPublicKey)`. If the
      // store kept the caller's input verbatim, any alternate-but-valid form
      // would be written into a register the ring path never consults — consent
      // that silently does nothing, and a revoke that cannot find it.
      final s = await storeFor(alice);
      await s.allow(resident);
      expect(s.read().single, encodeMultikey(residentKey));
    });

    test('a malformed key is refused at the moment of consent', () async {
      final s = await storeFor(alice);
      for (final bad in ['', 'not-a-key', 'z', 'zzzz', resident.substring(1)]) {
        expect(await s.allow(bad), isFalse, reason: 'allow("$bad")');
      }
      expect(s.read(), isEmpty);
    });

    test('revoke removes exactly one key and leaves the rest', () async {
      final s = await storeFor(alice);
      await s.allow(resident);
      await s.allow(stranger);
      expect(s.read(), {resident, stranger});
      expect(await s.revoke(resident), isTrue);
      expect(s.read(), {stranger});
    });

    test('a corrupt value reads as empty rather than throwing', () async {
      // Losing a ring beats admitting an unintended ringer, and an unpayable
      // store must never brick the ring path.
      final s = await storeFor(
        alice,
        seed: {'flutter.aiko_ring_allowed_keys_$alice': '{"not":"a list"}'},
      );
      expect(s.read(), isEmpty);
    });
  });
}
