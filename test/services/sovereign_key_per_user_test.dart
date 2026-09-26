import 'dart:async';
import 'dart:convert';

import 'package:aiko_chat_app/services/sovereign_key_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// One in-memory keychain shared across stores — the whole point is that two
/// accounts sit on ONE device, so the storage must be the same object.
class _FakeSecureStorage extends FlutterSecureStorage {
  _FakeSecureStorage();
  final Map<String, String> items = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => items[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      items.remove(key);
    } else {
      items[key] = value;
    }
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map<String, String>.from(items);

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => items.remove(key);
}

/// A storage whose first read NEVER completes — the dead holder that wedged
/// round 2's process-wide gate. Reads after the first behave normally, so the
/// test can tell "blocked behind a corpse" from "storage is simply broken".
class _HangingSecureStorage extends _FakeSecureStorage {
  int reads = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    reads++;
    if (reads == 1) return Completer<String?>().future; // never completes
    return super.read(key: key);
  }
}

const _legacyKey = 'aiko_sov_private_seed';

Future<String> _pubOf(SovereignKeyStore s) async =>
    base64Encode((await s.loadOrCreate()).rawPublicKey);

void main() {
  late _FakeSecureStorage storage;
  setUp(() => storage = _FakeSecureStorage());

  SovereignKeyStore storeFor(String? userId) =>
      SovereignKeyStore(userId: userId, storage: storage);

  group('per-account scoping (#4831)', () {
    test('two accounts on one device get DIFFERENT pubkeys', () async {
      final a = await _pubOf(storeFor('alice'));
      final b = await _pubOf(storeFor('bob'));
      expect(a, isNot(b));
    });

    // THE CONTROL, RUN THE OTHER WAY. Without this the test above passes just
    // as well if key derivation were broken and returned something new every
    // call — "different" would be measuring nothing. This is the row that makes
    // the row above mean what it says.
    test('the SAME account twice gets the SAME pubkey', () async {
      final first = await _pubOf(storeFor('alice'));
      final second = await _pubOf(storeFor('alice'));
      expect(second, first);
    });

    test('a null user mints a key and writes NOTHING', () async {
      final key = await storeFor(null).loadOrCreate();
      expect(key.rawPublicKey, hasLength(32));
      expect(storage.items, isEmpty);
    });

    test('two null-user stores do not share a key', () async {
      expect(await _pubOf(storeFor(null)), isNot(await _pubOf(storeFor(null))));
    });
  });

  group('legacy seed adoption', () {
    /// The pubkey the pre-#4831 unscoped seed would have produced.
    Future<String> seedLegacy() async {
      final pair = await Ed25519().newKeyPair();
      final seed = await pair.extractPrivateKeyBytes();
      storage.items[_legacyKey] = base64Encode(seed);
      return base64Encode((await pair.extractPublicKey()).bytes);
    }

    test('the first account to ask ADOPTS it — authorship survives', () async {
      final legacyPub = await seedLegacy();
      expect(await _pubOf(storeFor('alice')), legacyPub);
    });

    test('adoption consumes it: the second account gets a fresh key', () async {
      final legacyPub = await seedLegacy();
      final alice = await _pubOf(storeFor('alice'));
      final bob = await _pubOf(storeFor('bob'));

      expect(alice, legacyPub, reason: 'first asker adopts');
      expect(bob, isNot(legacyPub), reason: 'adoption is one-shot');
      expect(bob, isNot(alice), reason: 'the whole defect, restated');
      expect(
        storage.items.containsKey(_legacyKey),
        isFalse,
        reason: 'the unscoped name must not survive adoption',
      );
    });

    test('adoption is idempotent across reloads', () async {
      final legacyPub = await seedLegacy();
      expect(await _pubOf(storeFor('alice')), legacyPub);
      expect(await _pubOf(storeFor('alice')), legacyPub);
    });

    test('a legacy seed surviving a crash mid-adoption is swept', () async {
      // Exactly the window _adoptLegacySeed documents: the scoped write landed,
      // the delete did not. Alice's next load must remove it, or Bob adopts
      // Alice's key and the defect is back.
      final legacyPub = await seedLegacy();
      storage.items['aiko_sov_private_seed_alice'] = storage.items[_legacyKey]!;

      expect(await _pubOf(storeFor('alice')), legacyPub);
      expect(storage.items.containsKey(_legacyKey), isFalse);
      expect(await _pubOf(storeFor('bob')), isNot(legacyPub));
    });

    test('no legacy seed: each account simply mints its own', () async {
      final alice = await _pubOf(storeFor('alice'));
      expect(storage.items.containsKey(_legacyKey), isFalse);
      expect(await _pubOf(storeFor('bob')), isNot(alice));
    });
  });

  group('clear', () {
    test('clears only the calling account', () async {
      final alice = await _pubOf(storeFor('alice'));
      final bob = await _pubOf(storeFor('bob'));

      await storeFor('alice').clear();

      expect(await _pubOf(storeFor('alice')), isNot(alice), reason: 're-mints');
      expect(await _pubOf(storeFor('bob')), bob, reason: 'bob is untouched');
    });
  });

  group('adoption EXCLUSIVITY — the order round 1 could not fail on', () {
    /// Seed the legacy slot and return the pubkey it encodes.
    Future<String> seedLegacy() async {
      final pair = await Ed25519().newKeyPair();
      final seed = await pair.extractPrivateKeyBytes();
      storage.items[_legacyKey] = base64Encode(seed);
      return base64Encode((await pair.extractPublicKey()).bytes);
    }

    // THE DEFECT TESLA AND CARNOT FOUND. Alice adopted; her scoped write landed
    // and the legacy delete did NOT (throw, or process death between the two).
    // Bob signs in next. He has no scoped seed, so he takes the ADOPT branch —
    // not the sweep branch — and round 1 copied the same bytes under his name.
    // Two accounts, one pubkey, durable and on the wire: #4831 re-created by
    // #4831's own migration. Round 1's suite only ever drove Alice-then-Bob
    // WITHOUT the surviving legacy, the one order in which the sweep appears to
    // work, so it could not go red here.
    test(
      'Bob-first after a failed delete MINTS — he must not copy Alice\'s key',
      () async {
        final legacyPub = await seedLegacy();
        final legacyValue = storage.items[_legacyKey]!;
        // Alice's adoption, with the delete lost:
        storage.items['aiko_sov_private_seed_alice'] = legacyValue;

        final bob = await _pubOf(storeFor('bob'));

        expect(
          bob,
          isNot(legacyPub),
          reason: 'Bob must NOT inherit the claimed identity',
        );
        expect(
          await _pubOf(storeFor('alice')),
          legacyPub,
          reason: "Alice keeps the history that is hers",
        );
        expect(storage.items.containsKey(_legacyKey), isFalse);
      },
    );

    test(
      'a legacy value already claimed is refused even with no crash at all',
      () async {
        final legacyPub = await seedLegacy();
        final alice = await _pubOf(storeFor('alice'));
        expect(alice, legacyPub, reason: 'first asker adopts');

        // Put the legacy name back — a restored backup, a partial write, anything.
        storage.items[_legacyKey] = base64Encode(
          await (await Ed25519().newKeyPairFromSeed(
            base64Decode(storage.items['aiko_sov_private_seed_alice']!),
          )).extractPrivateKeyBytes(),
        );

        expect(await _pubOf(storeFor('bob')), isNot(legacyPub));
      },
    );

    // Tesla's interleaving (2): two stores in flight, both see legacy != null
    // before either deletes. `_serialised` is what makes this impossible; without
    // it both would copy.
    test(
      'two accounts adopting CONCURRENTLY: exactly one gets the identity',
      () async {
        final legacyPub = await seedLegacy();
        final results = await Future.wait([
          _pubOf(storeFor('alice')),
          _pubOf(storeFor('bob')),
        ]);
        expect(
          results.where((k) => k == legacyPub).length,
          1,
          reason: 'exactly one adopter, never two, never zero',
        );
        expect(results[0], isNot(results[1]));
      },
    );

    // POSITIVE CONTROL for this whole group. If adoption were refused ALWAYS,
    // every test above would pass while the migration silently orphaned every
    // existing user. This is the row that makes the refusals mean something.
    test(
      'POSITIVE CONTROL: an UNCLAIMED legacy seed IS still adopted',
      () async {
        final legacyPub = await seedLegacy();
        expect(await _pubOf(storeFor('alice')), legacyPub);
      },
    );
  });

  group('validate before committing', () {
    test('a corrupt legacy seed is NOT consumed — both slots survive', () async {
      storage.items[_legacyKey] = 'this is not base64 !!!';
      await expectLater(storeFor('alice').loadOrCreate(), throwsStateError);
      expect(
        storage.items[_legacyKey],
        'this is not base64 !!!',
        reason:
            'left on disk for repair, never deleted by a migration that could not use it',
      );
      expect(
        storage.items.containsKey('aiko_sov_private_seed_alice'),
        isFalse,
        reason: 'and never copied into the scoped slot',
      );
    });

    test('a wrong-LENGTH legacy seed is rejected too', () async {
      storage.items[_legacyKey] = base64Encode(List<int>.filled(16, 7));
      await expectLater(storeFor('alice').loadOrCreate(), throwsStateError);
      expect(storage.items.containsKey(_legacyKey), isTrue);
      expect(storage.items.containsKey('aiko_sov_private_seed_alice'), isFalse);
    });

    test(
      'a corrupt SCOPED seed throws a named error, not a bare format error',
      () async {
        storage.items['aiko_sov_private_seed_alice'] = 'nope';
        await expectLater(storeFor('alice').loadOrCreate(), throwsStateError);
      },
    );
  });

  group('an EMPTY user id is the same state as a null one', () {
    test('it writes nothing', () async {
      final key = await storeFor('').loadOrCreate();
      expect(key.rawPublicKey, hasLength(32));
      expect(storage.items, isEmpty);
    });

    test('two empty-id sessions do NOT share a key', () async {
      expect(await _pubOf(storeFor('')), isNot(await _pubOf(storeFor(''))));
    });

    // The control the other way: a real id DOES persist, so the assertions above
    // are measuring the empty case rather than a store that never writes at all.
    test('POSITIVE CONTROL: a real id does persist', () async {
      await storeFor('alice').loadOrCreate();
      expect(storage.items.containsKey('aiko_sov_private_seed_alice'), isTrue);
    });
  });

  group('the key carries its owner, so a foreign key is detectable', () {
    test('a scoped key is stamped with the account', () async {
      expect((await storeFor('alice').loadOrCreate()).userId, 'alice');
    });

    test('a no-session key is stamped null', () async {
      expect((await storeFor(null).loadOrCreate()).userId, isNull);
      expect((await storeFor('').loadOrCreate()).userId, isNull);
    });
  });

  group('a dead holder must not wedge signing', () {
    // THE REGRESSION ROUND 2 SHIPPED AND THIS SUITE COULD NOT SEE. The gate was
    // one `static Future<void>` for the whole process, so a caller that never
    // completed blocked EVERY later load on EVERY account, permanently. It
    // surfaced only as four unrelated widget tests timing out in `pumpAndSettle`
    // — a symptom with no obvious path back to a lock in the key store.

    test('one storage hanging does not block a DIFFERENT storage', () async {
      final wedged = _HangingSecureStorage();
      // Fire and deliberately do not await: this load never returns.
      unawaited(
        SovereignKeyStore(
          userId: 'alice',
          storage: wedged,
        ).loadOrCreate().then((_) {}, onError: (_) {}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // A different storage must be completely unaffected — no shared lock.
      final other = _FakeSecureStorage();
      await expectLater(
        SovereignKeyStore(
          userId: 'bob',
          storage: other,
        ).loadOrCreate().timeout(const Duration(seconds: 1)),
        completes,
      );
    });

    test(
      'a later load on the SAME storage proceeds after the gate times out',
      () async {
        final wedged = _HangingSecureStorage();
        unawaited(
          SovereignKeyStore(
            userId: 'alice',
            storage: wedged,
          ).loadOrCreate().then((_) {}, onError: (_) {}),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Bounded wait: the corpse is stepped over, not queued behind forever.
        // The tradeoff is documented on _gateTimeout — unserialised in this one
        // pathological case, which beats signing being broken for everyone.
        final key = await SovereignKeyStore(
          userId: 'bob',
          storage: wedged,
        ).loadOrCreate().timeout(const Duration(seconds: 15));
        expect(key.userId, 'bob');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
