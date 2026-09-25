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
}
