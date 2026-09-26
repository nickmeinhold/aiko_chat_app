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

const _legacyKey = 'aiko_sov_private_seed';

Future<String> _pubOf(SovereignKeyStore s) async =>
    base64Encode((await s.loadOrCreate()).rawPublicKey);

void main() {
  late _FakeSecureStorage storage;
  setUp(() => storage = _FakeSecureStorage());

  SovereignKeyStore storeFor(String? userId) =>
      SovereignKeyStore(userId: userId, storage: storage);

  /// Seed the pre-#4831 unscoped slot and return the pubkey it encodes.
  Future<String> seedLegacy() async {
    final pair = await Ed25519().newKeyPair();
    storage.items[_legacyKey] = base64Encode(
      await pair.extractPrivateKeyBytes(),
    );
    return base64Encode((await pair.extractPublicKey()).bytes);
  }

  group('per-account scoping (#4831)', () {
    test('two accounts on one device get DIFFERENT pubkeys', () async {
      expect(
        await _pubOf(storeFor('alice')),
        isNot(await _pubOf(storeFor('bob'))),
      );
    });

    // THE CONTROL, RUN THE OTHER WAY. Without this the test above passes just as
    // well if key derivation were broken and returned something new every call —
    // "different" would be measuring nothing. This row is what makes that one mean
    // what it says.
    test('the SAME account twice gets the SAME pubkey', () async {
      final first = await _pubOf(storeFor('alice'));
      expect(await _pubOf(storeFor('alice')), first);
    });

    test(
      'a scoped key is stamped with its owner, so a foreign key is spottable',
      () async {
        expect((await storeFor('alice').loadOrCreate()).userId, 'alice');
      },
    );
  });

  group('the legacy seed is DISCARDED, never adopted', () {
    // The whole migration design collapsed into these three tests. Adoption was
    // there to preserve authorship continuity; the live island holds 44 signed
    // messages and exactly one shared pubkey, both of whose accounts belong to the
    // same person. So nineteen pubkeys stop matching new signatures, and in
    // exchange every adoption failure mode becomes unreachable rather than fixed.

    test('an account does NOT inherit the unscoped seed', () async {
      final legacyPub = await seedLegacy();
      expect(await _pubOf(storeFor('alice')), isNot(legacyPub));
    });

    test('the unscoped slot is deleted', () async {
      await seedLegacy();
      await storeFor('alice').loadOrCreate();
      // The discard is fire-and-forget, so let its microtask land.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(storage.items.containsKey(_legacyKey), isFalse);
    });

    // POSITIVE CONTROL. If minting were broken and every load returned the same
    // bytes, "does not inherit" could pass while both accounts shared one key —
    // the defect itself. Two accounts must differ from the legacy key AND from
    // each other.
    test(
      'two accounts both decline it and still differ from each other',
      () async {
        final legacyPub = await seedLegacy();
        final alice = await _pubOf(storeFor('alice'));
        final bob = await _pubOf(storeFor('bob'));
        expect(alice, isNot(legacyPub));
        expect(bob, isNot(legacyPub));
        expect(alice, isNot(bob));
      },
    );

    test(
      'a CORRUPT unscoped seed is discarded too — no validation needed',
      () async {
        storage.items[_legacyKey] = 'not base64 at all !!!';
        // It must not throw: we never decode bytes we are not going to use. The
        // version this replaced validated first and could therefore never empty a
        // corrupt slot, which wedged the whole install.
        await expectLater(storeFor('alice').loadOrCreate(), completes);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(storage.items.containsKey(_legacyKey), isFalse);
      },
    );
  });

  group('a corrupt SCOPED seed is named, not silently re-minted', () {
    test('it throws a StateError rather than a bare FormatException', () async {
      storage.items['aiko_sov_private_seed_alice'] = 'nope';
      await expectLater(storeFor('alice').loadOrCreate(), throwsStateError);
    });

    test('a wrong-LENGTH scoped seed is rejected too', () async {
      storage.items['aiko_sov_private_seed_alice'] = base64Encode(
        List<int>.filled(16, 7),
      );
      await expectLater(storeFor('alice').loadOrCreate(), throwsStateError);
    });

    // Control: a VALID scoped seed loads, so the two refusals above are measuring
    // corruption rather than a store that rejects everything.
    test('POSITIVE CONTROL: a valid scoped seed loads', () async {
      final pair = await Ed25519().newKeyPair();
      storage.items['aiko_sov_private_seed_alice'] = base64Encode(
        await pair.extractPrivateKeyBytes(),
      );
      expect(
        await _pubOf(storeFor('alice')),
        base64Encode((await pair.extractPublicKey()).bytes),
      );
    });
  });

  group('an EMPTY user id is the same state as a null one', () {
    test('neither persists anything', () async {
      expect((await storeFor(null).loadOrCreate()).rawPublicKey, hasLength(32));
      expect((await storeFor('').loadOrCreate()).rawPublicKey, hasLength(32));
      expect(storage.items, isEmpty);
    });

    test('two no-session sessions do not share a key', () async {
      expect(await _pubOf(storeFor('')), isNot(await _pubOf(storeFor(''))));
      expect(await _pubOf(storeFor(null)), isNot(await _pubOf(storeFor(null))));
    });

    test('a no-session key is stamped null', () async {
      expect((await storeFor(null).loadOrCreate()).userId, isNull);
      expect((await storeFor('').loadOrCreate()).userId, isNull);
    });

    // Control the other way: a real id DOES persist, so the assertions above are
    // measuring the no-session case rather than a store that never writes at all.
    test('POSITIVE CONTROL: a real id persists', () async {
      await storeFor('alice').loadOrCreate();
      expect(storage.items.containsKey('aiko_sov_private_seed_alice'), isTrue);
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
}
