import 'dart:async';

import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

/// The island's rotation rule (island #420, `rotate_refresh` on its branch
/// feat/420-rotate-refresh-token), modelled so these tests fail the way the
/// real island would rather than the way a stub was told to:
/// - presenting CURRENT rotates it: it becomes PREVIOUS, a new CURRENT is
///   minted;
/// - presenting PREVIOUS is a retry, with no time limit, and PREVIOUS never
///   moves. Outside a 30 s window the retry mints a fresh CURRENT (inside it,
///   re-issues the same one). Modelled as always outside: locked refreshes are
///   an access-TTL apart, and minting is the harder case for the client;
/// - presenting anything else means two holders: the session ends, and every
///   token of it is dead from then on.
class _RotatingIsland {
  var _minted = 0;
  String _current = 'r0';
  String? _previous;
  var _ended = false;
  final presented = <String>[];

  Future<RefreshResult> refresh(String rt) async {
    presented.add(rt);
    if (_ended) throw const RefreshRejected();
    if (rt == _current) {
      _previous = _current;
    } else if (rt != _previous) {
      _ended = true;
      throw const RefreshRejected();
    }
    _current = 'r${++_minted}';
    return RefreshResult('a$_minted', refreshToken: _current);
  }
}

/// A Keychain whose items are WhenUnlocked: every write throws while locked
/// (errSecInteractionNotAllowed, -25308); reads of what's already there work.
class _LockableStore extends InMemoryTokenStore {
  _LockableStore(super.initial);
  var locked = false;

  @override
  Future<void> write(AuthTokens tokens) async {
    if (locked) throw Exception('-25308 errSecInteractionNotAllowed');
    await super.write(tokens);
  }
}

const _signedIn = AuthTokens(accessToken: 'a0', refreshToken: 'r0');

void main() {
  test('the island model has teeth: a token two generations back ends the '
      'session', () async {
    final island = _RotatingIsland();
    await island.refresh('r0');
    await island.refresh('r0'); // a retry of PREVIOUS, hours later: fine
    await island.refresh('r2'); // CURRENT rotates; r0 is now two back
    await expectLater(island.refresh('r0'), throwsA(isA<RefreshRejected>()));
    await expectLater(island.refresh('r3'), throwsA(isA<RefreshRejected>()));
  });

  test('a rotated refresh token is stored, and the next refresh presents '
      'it', () async {
    final island = _RotatingIsland();
    final store = _LockableStore(_signedIn);
    final tp = DefaultTokenProvider(
      store: store,
      remoteRefresh: island.refresh,
    );

    expect(await tp.refreshAccessToken(), 'a1');
    expect(
      store.current,
      const AuthTokens(accessToken: 'a1', refreshToken: 'r1'),
    );
    expect(await tp.refreshAccessToken(), 'a2');
    expect(island.presented, ['r0', 'r1']);
  });

  test('an island that predates rotation omits refresh_token: keep '
      'ours', () async {
    final store = InMemoryTokenStore(_signedIn);
    final tp = DefaultTokenProvider(
      store: store,
      remoteRefresh: (_) async => const RefreshResult('a1'),
    );
    await tp.refreshAccessToken();
    expect(
      store.current,
      const AuthTokens(accessToken: 'a1', refreshToken: 'r0'),
    );
  });

  test('locked store across two refreshes, then a restart: still signed '
      'in', () async {
    final island = _RotatingIsland();
    final store = _LockableStore(_signedIn)..locked = true;
    var signedOut = false;
    final tp = DefaultTokenProvider(
      store: store,
      remoteRefresh: island.refresh,
      onUnauthenticated: () => signedOut = true,
    );

    // Two refreshes while locked (a VoIP wake, then another an access-TTL
    // later). Neither rotated token can be written, so both refreshes must
    // present the STORED token: the second is a retry of PREVIOUS.
    expect(await tp.refreshAccessToken(), 'a1');
    expect(await tp.refreshAccessToken(), 'a2');
    expect(island.presented, ['r0', 'r0']);
    expect(store.current, _signedIn, reason: 'nothing could be written');

    // Killed before unlock; relaunched after it, with only the Keychain.
    store.locked = false;
    final restarted = DefaultTokenProvider(
      store: store,
      remoteRefresh: island.refresh,
      onUnauthenticated: () => signedOut = true,
    );
    expect(await restarted.refreshAccessToken(), 'a3');
    expect(store.current?.refreshToken, 'r3', reason: 'unlocked: it sticks');
    expect(await restarted.refreshAccessToken(), 'a4');
    expect(island.presented, ['r0', 'r0', 'r0', 'r3']);
    expect(signedOut, isFalse);
  });

  test('a sign-in landing mid-refresh is not reverted by the old session\'s '
      'result', () async {
    final gate = Completer<RefreshResult>();
    final sent = Completer<String>();
    final store = InMemoryTokenStore(_signedIn);
    final tp = DefaultTokenProvider(
      store: store,
      remoteRefresh: (rt) {
        sent.complete(rt);
        return gate.future;
      },
    );

    final refreshing = tp.refreshAccessToken();
    expect(await sent.future, 'r0', reason: 'the old session is on the wire');
    const fresh = AuthTokens(accessToken: 'b0', refreshToken: 's0');
    await tp.setTokens(fresh);
    gate.complete(const RefreshResult('a1', refreshToken: 'r1'));

    expect(await refreshing, 'b0');
    expect(store.current, fresh);
    expect(await tp.currentAccessToken(), 'b0');
  });

  test('a logout landing mid-refresh stays logged out', () async {
    final gate = Completer<RefreshResult>();
    final sent = Completer<String>();
    final store = InMemoryTokenStore(_signedIn);
    final tp = DefaultTokenProvider(
      store: store,
      remoteRefresh: (rt) {
        sent.complete(rt);
        return gate.future;
      },
    );

    final refreshing = tp.refreshAccessToken();
    expect(await sent.future, 'r0', reason: 'the old session is on the wire');
    await tp.clearTokens();
    gate.complete(const RefreshResult('a1', refreshToken: 'r1'));

    expect(await refreshing, isNull);
    expect(store.current, isNull);
  });

  test('a rejection of the OLD session after a fresh sign-in does not sign the '
      'new one out', () async {
    final gate = Completer<RefreshResult>();
    final sent = Completer<String>();
    final store = InMemoryTokenStore(_signedIn);
    var signedOut = false;
    final tp = DefaultTokenProvider(
      store: store,
      remoteRefresh: (rt) {
        sent.complete(rt);
        return gate.future;
      },
      onUnauthenticated: () => signedOut = true,
    );

    final refreshing = tp.refreshAccessToken();
    expect(await sent.future, 'r0', reason: 'the old session is on the wire');
    const fresh = AuthTokens(accessToken: 'b0', refreshToken: 's0');
    await tp.setTokens(fresh);
    gate.completeError(const RefreshRejected());

    expect(await refreshing, 'b0');
    expect(signedOut, isFalse);
    expect(store.current, fresh);
  });

  test('a rebuilt provider\'s refresh answers first; the old instance\'s '
      'older response, landing last, is dropped', () async {
    final store = InMemoryTokenStore(
      const AuthTokens(accessToken: 'a0', refreshToken: 'P'),
    );
    final r1 = Completer<RefreshResult>();
    final r1Sent = Completer<void>();
    final old = DefaultTokenProvider(
      store: store,
      remoteRefresh: (_) {
        r1Sent.complete();
        return r1.future;
      },
    );
    final rebuilt = DefaultTokenProvider(
      store: store,
      remoteRefresh: (_) async => const RefreshResult('a2', refreshToken: 'C2'),
    );

    // R1 goes out from the old instance and stalls; 40 s later the rebuilt
    // instance sends R2. Both present P, so the island mints C1 then C2.
    final stale = old.refreshAccessToken();
    await r1Sent.future;
    expect(await rebuilt.refreshAccessToken(), 'a2');
    r1.complete(const RefreshResult('a1', refreshToken: 'C1'));

    expect(await stale, 'a2', reason: 'adopts what the newer refresh stored');
    expect(store.current?.refreshToken, 'C2');
    expect(await old.currentAccessToken(), 'a2');
  });

  test('RefreshResult.fromJson reads the rotated token, or its absence', () {
    final rotated = RefreshResult.fromJson({
      'access_token': 'a1',
      'refresh_token': 'r1',
    });
    expect((rotated.accessToken, rotated.refreshToken), ('a1', 'r1'));
    final legacy = RefreshResult.fromJson({'access_token': 'a1'});
    expect(legacy.refreshToken, isNull);
  });
}
