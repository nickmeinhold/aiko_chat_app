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
///   moves; the retry mints a fresh CURRENT (no clock: the island dropped its
///   30 s re-issue window, because two holders refreshing inside it stayed
///   phase-locked and were never detected);
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
  var refuseClear = false;

  @override
  Future<void> clear() async {
    if (refuseClear) throw Exception('-25308 errSecInteractionNotAllowed');
    await super.clear();
  }

  @override
  Future<void> write(AuthTokens tokens) async {
    if (locked) throw Exception('-25308 errSecInteractionNotAllowed');
    await super.write(tokens);
  }
}

/// Holds one write open until released, so a test can land a sign-in while
/// a refresh's Keychain write is still in progress.
class _GatedStore extends InMemoryTokenStore {
  _GatedStore(super.initial);
  var _armed = false;
  final _release = Completer<void>();
  final _writing = Completer<void>();
  Future<void> get writing => _writing.future;

  void holdNextWrite() => _armed = true;
  void releaseWrite() => _release.complete();

  @override
  Future<void> write(AuthTokens tokens) async {
    if (_armed) {
      _armed = false;
      _writing.complete();
      await _release.future;
    }
    await super.write(tokens);
  }
}

/// [SecureTokenStore.write] is two Keychain writes, so a write can throw with
/// one of them landed. This one lands the REFRESH token and loses the access
/// token: the shape where the disk disagrees with the token the refresh
/// presented, and only a re-read finds out.
class _HalfWriteStore extends InMemoryTokenStore {
  _HalfWriteStore(super.initial);
  var loseAccessHalf = false;

  @override
  Future<void> write(AuthTokens tokens) async {
    if (!loseAccessHalf) return super.write(tokens);
    await super.write(
      AuthTokens(
        accessToken: current!.accessToken,
        refreshToken: tokens.refreshToken,
      ),
    );
    throw Exception('-25308 on the second item');
  }
}

/// Holds the first read open until released, so a logout can land during it.
class _SlowReadStore extends InMemoryTokenStore {
  _SlowReadStore(super.initial);
  final _reading = Completer<void>();
  final _finish = Completer<void>();
  Future<void> get reading => _reading.future;
  void finishRead() => _finish.complete();

  @override
  Future<AuthTokens?> read() async {
    final snapshot = current;
    if (!_reading.isCompleted) {
      _reading.complete();
      await _finish.future;
    }
    return snapshot;
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

    // Killed before unlock; relaunched after it, with only the Keychain. A
    // new store object: the session is keyed on the store, so reusing this one
    // would carry the in-memory session across the "restart" and test nothing.
    final relaunched = _LockableStore(store.current);
    final restarted = DefaultTokenProvider(
      store: relaunched,
      remoteRefresh: island.refresh,
      onUnauthenticated: () => signedOut = true,
    );
    expect(await restarted.refreshAccessToken(), 'a3');
    expect(
      relaunched.current?.refreshToken,
      'r3',
      reason: 'unlocked: it sticks',
    );
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

  test('a rebuilt provider joins the old instance\'s refresh instead of '
      'sending its own', () async {
    final store = InMemoryTokenStore(_signedIn);
    final gate = Completer<RefreshResult>();
    var calls = 0;
    Future<RefreshResult> remote(String _) {
      calls++;
      return gate.future;
    }

    final old = DefaultTokenProvider(store: store, remoteRefresh: remote);
    final rebuilt = DefaultTokenProvider(store: store, remoteRefresh: remote);
    final a = old.refreshAccessToken();
    final b = rebuilt.refreshAccessToken();
    gate.complete(const RefreshResult('a1', refreshToken: 'r1'));

    expect(await Future.wait([a, b]), ['a1', 'a1']);
    expect(calls, 1, reason: 'one session, one refresh on the wire');
  });

  test('two instances refreshing one after the other present one chain, so '
      'neither ends the session', () async {
    // Carnot, PR #452 round 1: with a cache per instance, B rotates P->C1,
    // then A presents its cached P (a retry that mints C2), and B's C1 is
    // dead on B's next refresh.
    final island = _RotatingIsland();
    final store = InMemoryTokenStore(_signedIn);
    var signedOut = false;
    DefaultTokenProvider provider() => DefaultTokenProvider(
      store: store,
      remoteRefresh: island.refresh,
      onUnauthenticated: () => signedOut = true,
    );
    final a = provider();
    final b = provider();
    await a.currentAccessToken();
    await b.currentAccessToken();

    await b.refreshAccessToken();
    await a.refreshAccessToken();
    await b.refreshAccessToken();
    expect(island.presented, ['r0', 'r1', 'r2']);
    expect(signedOut, isFalse);
  });

  test('a sign-in landing while a refresh is WRITING is not overwritten by '
      'it', () async {
    final store = _GatedStore(_signedIn);
    final tp = DefaultTokenProvider(
      store: store,
      remoteRefresh: (_) async => const RefreshResult('a1', refreshToken: 'r1'),
    );
    await tp.currentAccessToken();

    store.holdNextWrite();
    final refreshing = tp.refreshAccessToken();
    await store.writing; // the refresh's write is now in progress
    const fresh = AuthTokens(accessToken: 'b0', refreshToken: 's0');
    final signingIn = tp.setTokens(fresh);
    store.releaseWrite();
    await Future.wait([refreshing, signingIn]);

    expect(store.current, fresh);
    expect(await tp.currentAccessToken(), 'b0');
  });

  test('a write that dies halfway: the next refresh presents what is on '
      'disk, not what it presented last', () async {
    final island = _RotatingIsland();
    final store = _HalfWriteStore(_signedIn);
    var signedOut = false;
    final tp = DefaultTokenProvider(
      store: store,
      remoteRefresh: island.refresh,
      onUnauthenticated: () => signedOut = true,
    );

    store.loseAccessHalf = true; // r1 reaches the disk; the write throws
    await tp.refreshAccessToken();
    store.loseAccessHalf = false;
    await tp.refreshAccessToken();

    // Presenting r0 again would be a retry that mints r2 and discards r1,
    // leaving the disk holding a token the island no longer pairs: the next
    // restart would end the session.
    expect(island.presented, ['r0', 'r1']);
    expect(store.current?.refreshToken, 'r2');
    expect(signedOut, isFalse);
  });

  test('a logout landing during the first Keychain read stays logged '
      'out', () async {
    // Carnot, PR #452 round 2: a read that captured the old tokens, finishing
    // after the logout, reinstalled them.
    final store = _SlowReadStore(_signedIn);
    final tp = DefaultTokenProvider(
      store: store,
      remoteRefresh: (_) async => const RefreshResult('a1'),
    );
    final reading = tp.currentAccessToken();
    await store.reading;
    final loggingOut = tp.clearTokens();
    store.finishRead();
    await Future.wait([reading, loggingOut]);

    expect(await tp.currentAccessToken(), isNull);
    expect(store.current, isNull);
  });

  test('a rejected token ends the session even when the Keychain refuses '
      'the delete', () async {
    final store = _LockableStore(_signedIn)..refuseClear = true;
    var signedOut = false;
    final tp = DefaultTokenProvider(
      store: store,
      remoteRefresh: (_) async => throw const RefreshRejected(),
      onUnauthenticated: () => signedOut = true,
    );

    expect(await tp.refreshAccessToken(), isNull, reason: 'not a throw');
    expect(signedOut, isTrue);
    expect(await tp.currentAccessToken(), isNull);
  });

  test('a refresh with no session, landing while a sign-in writes, does not '
      'sign the new session out', () async {
    // Noether + Carnot, PR #452 round 3.
    final store = _GatedStore(null);
    var signedOut = false;
    final tp = DefaultTokenProvider(
      store: store,
      remoteRefresh: (_) async => const RefreshResult('a1'),
      onUnauthenticated: () => signedOut = true,
    );
    await tp.currentAccessToken(); // loaded: logged out

    store.holdNextWrite();
    const fresh = AuthTokens(accessToken: 'b0', refreshToken: 's0');
    final signingIn = tp.setTokens(fresh);
    await store.writing;
    final refreshing = tp.refreshAccessToken(); // e.g. a 401 from before
    store.releaseWrite();
    await signingIn;

    expect(await refreshing, 'b0');
    expect(signedOut, isFalse);
    expect(store.current, fresh);
  });

  for (final viaLogout in [true, false]) {
    test(
      'a hung refresh does not hold the next session hostage '
      '(${viaLogout ? 'logout, then sign-in' : 'sign-in over it'})',
      () async {
        final hung = Completer<RefreshResult>();
        var calls = 0;
        final tp = DefaultTokenProvider(
          store: InMemoryTokenStore(_signedIn),
          remoteRefresh: (_) {
            calls++;
            return calls == 1
                ? hung.future
                : Future.value(const RefreshResult('b1', refreshToken: 's1'));
          },
        );
        unawaited(tp.refreshAccessToken()); // never answers
        await Future<void>.delayed(Duration.zero);
        if (viaLogout) {
          await tp.clearTokens();
          // Logged out: a refresh answers null at once, not the hung future.
          expect(
            await tp.refreshAccessToken().timeout(const Duration(seconds: 1)),
            isNull,
          );
        }
        await tp.setTokens(
          const AuthTokens(accessToken: 'b0', refreshToken: 's0'),
        );

        expect(await tp.refreshAccessToken(), 'b1');
        expect(calls, 2);
      },
    );
  }

  test(
    'the old flight finishing does not empty the new flight\'s slot',
    () async {
      final old = Completer<RefreshResult>();
      final next = Completer<RefreshResult>();
      var calls = 0;
      final tp = DefaultTokenProvider(
        store: InMemoryTokenStore(_signedIn),
        remoteRefresh: (_) {
          calls++;
          return calls == 1 ? old.future : next.future;
        },
      );
      final first = tp.refreshAccessToken();
      await Future<void>.delayed(Duration.zero);
      await tp.setTokens(
        const AuthTokens(accessToken: 'b0', refreshToken: 's0'),
      );
      final second = tp.refreshAccessToken();
      await Future<void>.delayed(Duration.zero);

      old.complete(const RefreshResult('a1', refreshToken: 'r1'));
      await first;
      final third = tp.refreshAccessToken(); // must JOIN the second flight
      next.complete(const RefreshResult('b1', refreshToken: 's1'));

      expect(await Future.wait([second, third]), ['b1', 'b1']);
      expect(calls, 2);
    },
  );

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
