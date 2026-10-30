// A credential is only ever presented to the island that minted it (#436).
//
// Round 1 of the cage-match on #439 found the harm from both ends: a reinstall
// pinned to the wrong island sent that island the other one's refresh token,
// and the 401 it got back read as a revocation and deleted the credential. The
// fix records the minting island with the tokens and checks it at the one door
// every token goes through, so a wrong island is a sign-in screen, never a leak.

import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/services/secure_token_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

const _here = 'https://here.island';
const _there = 'https://there.island';
const _pair = AuthTokens(accessToken: 'a', refreshToken: 'r');

void main() {
  group('DefaultTokenProvider presents only its own island\'s tokens', () {
    DefaultTokenProvider provider(
      InMemoryTokenStore store, {
      void Function()? onUnauthenticated,
      List<String>? refreshedWith,
    }) => DefaultTokenProvider(
      island: _here,
      store: store,
      remoteRefresh: (rt) async {
        refreshedWith?.add(rt);
        return 'a2';
      },
      onUnauthenticated: onUnauthenticated,
    );

    test('tokens minted on another island are not presented', () async {
      final store = InMemoryTokenStore(_pair, _there);
      expect(await provider(store).currentAccessToken(), isNull);
    });

    test('and a refresh neither sends them nor deletes them', () async {
      final store = InMemoryTokenStore(_pair, _there);
      final sent = <String>[];
      var unauthenticated = 0;
      final p = provider(
        store,
        onUnauthenticated: () => unauthenticated++,
        refreshedWith: sent,
      );
      expect(await p.refreshAccessToken(), isNull);
      expect(sent, isEmpty, reason: 'the other island\'s refresh token');
      expect(unauthenticated, 1, reason: 'signed out HERE');
      expect(store.current, _pair, reason: 'still a session THERE');
      expect(store.island, _there);
    });

    test(
      'an older build\'s untagged tokens are presented, as before',
      () async {
        final store = InMemoryTokenStore(_pair);
        expect(await provider(store).currentAccessToken(), 'a');
      },
    );

    test(
      'tokens it stores carry its island, on sign-in and on refresh',
      () async {
        final store = InMemoryTokenStore();
        final p = provider(store);
        await p.setTokens(_pair);
        expect(store.island, _here);

        store.island = null; // as an older build left it
        expect(await p.refreshAccessToken(), 'a2');
        expect(store.island, _here, reason: 'the refresh tags it');
      },
    );

    test('an explicit sign-out clears whatever is stored', () async {
      final store = InMemoryTokenStore(_pair, _there);
      await provider(store).clearTokens();
      expect(store.current, isNull);
      expect(store.island, isNull);
    });
  });

  group('SecureTokenStore keeps the island with the tokens', () {
    test('the island is written first and deleted last', () async {
      final keychain = _RecordingKeychain();
      final store = SecureTokenStore(keychain);

      await store.write(_pair, island: _here);
      expect(keychain.log.first, 'write aiko_tokens_island');
      expect(await store.readIsland(), _here);

      keychain.log.clear();
      await store.clear();
      expect(keychain.log.last, 'delete aiko_tokens_island');
      expect(await store.read(), isNull);
      expect(await store.readIsland(), isNull);
    });
  });
}

class _RecordingKeychain extends FlutterSecureStorage {
  final items = <String, String>{};
  final log = <String>[];

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
    log.add('write $key');
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
  }) async {
    log.add('delete $key');
    items.remove(key);
  }
}
