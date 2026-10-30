import 'dart:convert';

import 'package:aiko_chat_app/services/sovereign_key_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// A keychain that matches the way flutter_secure_storage_darwin 0.3.2 does,
/// which is the whole reason the seed needed a new slot name:
///
/// - a READ carries `kSecAttrAccessible`, so it only finds an item of the same
///   class (`FlutterSecureStorage.swift:218-220`);
/// - a WRITE checks `containsKey` under its own class, then `SecItemAdd`s; an item
///   of ANOTHER class under the same name collides on the item's identity (account
///   + service exclude the class), and the plugin throws (`:557-572`,
///   `FlutterSecureStorageDarwinPlugin.swift:206-219`);
/// - a DELETE strips the class and removes whatever is there (`:705`).
///
/// The package default class, which every pre-pin item was written under, is
/// `unlocked` (`apple_options.dart:72`).
class _ClassAwareKeychain extends FlutterSecureStorage {
  final Map<String, ({String value, KeychainAccessibility cls})> items = {};

  /// Keys whose next write throws, to model the Keychain refusing a write.
  final Set<String> failWritesTo = {};

  /// Classes requested on writes, per key, so a test can see what was pinned.
  final Map<String, List<KeychainAccessibility?>> macWriteClasses = {};

  KeychainAccessibility _cls(AppleOptions? o) =>
      o?.accessibility ?? KeychainAccessibility.unlocked;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final item = items[key];
    return item != null && item.cls == _cls(iOptions) ? item.value : null;
  }

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
    (macWriteClasses[key] ??= []).add(mOptions?.accessibility);
    if (failWritesTo.contains(key)) {
      throw PlatformException(code: 'Unexpected security result code');
    }
    final existing = items[key];
    final cls = _cls(iOptions);
    if (existing != null && existing.cls != cls) {
      // errSecDuplicateItem: same account + service, different class.
      throw PlatformException(
        code: 'Unexpected security result code',
        details: -25299,
      );
    }
    items[key] = (value: value!, cls: cls);
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

const _v1 = 'aiko_sov_private_seed_alice';
const _v2 = 'aiko_sov_seed_v2_island_account_alice';
const _pinned = KeychainAccessibility.unlocked_this_device;

void main() {
  late _ClassAwareKeychain keychain;
  setUp(() => keychain = _ClassAwareKeychain());

  SovereignKeyStore alice() =>
      SovereignKeyStore(userId: 'alice', storage: keychain);

  /// A v1 seed exactly as 0.0.8 wrote it: the v1 name, the package default class.
  Future<String> seedV1() async {
    final pair = await Ed25519().newKeyPair();
    keychain.items[_v1] = (
      value: base64Encode(await pair.extractPrivateKeyBytes()),
      cls: KeychainAccessibility.unlocked,
    );
    return base64Encode((await pair.extractPublicKey()).bytes);
  }

  Future<String> pubOf(SovereignKeyStore s) async =>
      base64Encode((await s.loadOrCreate()).rawPublicKey);

  group('pinning the class never re-mints an existing account', () {
    test('a v1 seed under the default class keeps its pubkey', () async {
      final before = await seedV1();
      expect(await pubOf(alice()), before);
    });

    test(
      'it moves to the pinned class under the v2 name, and v1 is gone',
      () async {
        final before = await seedV1();
        await pubOf(alice());
        expect(keychain.items[_v2]?.cls, _pinned);
        expect(keychain.items.containsKey(_v1), isFalse);
        // A cold start reads the pinned item, not a fresh mint.
        expect(await pubOf(alice()), before);
      },
    );

    test('macOS gets the pinned class too, not just iOS', () async {
      await seedV1();
      await pubOf(alice());
      expect(keychain.macWriteClasses[_v2], everyElement(_pinned));
    });

    test('a fresh account mints straight into the pinned class', () async {
      await pubOf(alice());
      expect(keychain.items[_v2]?.cls, _pinned);
      expect(keychain.macWriteClasses[_v2], everyElement(_pinned));
      expect(keychain.items.containsKey(_v1), isFalse);
    });
  });

  group('no mint while a v1 seed exists', () {
    test('a refused migration write keeps v1 and signs with it', () async {
      final before = await seedV1();
      keychain.failWritesTo.add(_v2);
      expect(await pubOf(alice()), before);
      expect(keychain.items[_v1]?.cls, KeychainAccessibility.unlocked);
      expect(keychain.items.containsKey(_v2), isFalse);
    });

    test('the next load retries the move and completes it', () async {
      final before = await seedV1();
      keychain.failWritesTo.add(_v2);
      await pubOf(alice());
      keychain.failWritesTo.clear();
      expect(await pubOf(alice()), before);
      expect(keychain.items[_v2]?.cls, _pinned);
      expect(keychain.items.containsKey(_v1), isFalse);
    });

    test('a v1 read error throws instead of reading as absent', () async {
      await seedV1();
      final failing = _ThrowingReadKeychain(keychain, _v1);
      final store = SovereignKeyStore(userId: 'alice', storage: failing);
      await expectLater(
        store.loadOrCreate(),
        throwsA(isA<PlatformException>()),
      );
      expect(
        keychain.items.containsKey(_v2),
        isFalse,
        reason: 'nothing minted',
      );
    });

    test('a corrupt v1 seed is named, and nothing is written', () async {
      keychain.items[_v1] = (
        value: 'not base64 at all !!!',
        cls: KeychainAccessibility.unlocked,
      );
      await expectLater(alice().loadOrCreate(), throwsA(isA<StateError>()));
      expect(keychain.items.containsKey(_v2), isFalse);
    });
  });

  group('interrupted and repeated', () {
    test(
      'both slots present (a crash after the write): pinned wins, v1 retired',
      () async {
        final before = await seedV1();
        keychain.items[_v2] = (value: keychain.items[_v1]!.value, cls: _pinned);
        expect(await pubOf(alice()), before);
        await Future<void>.delayed(Duration.zero); // the retire is unawaited
        expect(keychain.items.containsKey(_v1), isFalse);
      },
    );

    test(
      'clear wipes BOTH slots, so the wiped key cannot migrate back',
      () async {
        final before = await seedV1();
        final store = alice();
        keychain.failWritesTo.add(_v2); // leave v1 in place
        await pubOf(store);
        keychain.failWritesTo.clear();
        await store.clear();
        expect(keychain.items, isEmpty);
        expect(await pubOf(alice()), isNot(before));
      },
    );
  });
}

/// Wraps a keychain so one key's read throws, as a locked Keychain does.
class _ThrowingReadKeychain extends FlutterSecureStorage {
  _ThrowingReadKeychain(this.inner, this.failKey);
  final _ClassAwareKeychain inner;
  final String failKey;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == failKey) {
      throw PlatformException(code: 'Unexpected security result code');
    }
    return inner.read(key: key, iOptions: iOptions, mOptions: mOptions);
  }

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
  }) => inner.write(
    key: key,
    value: value,
    iOptions: iOptions,
    mOptions: mOptions,
  );

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => inner.delete(key: key);
}
