import 'dart:async';
import 'dart:convert';

import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/gateway_rest_api.dart';
import 'package:aiko_chat_app/services/session_vault.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

/// The island's rotation rule (island #420, live since v0.24.0), modelled so
/// these tests fail the way the real island would rather than the way a stub
/// was told to:
/// - presenting CURRENT rotates it: it becomes PREVIOUS, a new CURRENT is
///   minted;
/// - presenting PREVIOUS is a retry, with no time limit, and PREVIOUS never
///   moves; the retry mints a fresh CURRENT;
/// - presenting anything else means two holders: the session ends, and every
///   token of it is dead from then on.
class _RotatingIsland {
  _RotatingIsland([this._current = 'r0']);
  var _minted = 0;
  String _current;
  String? _previous;
  var ended = false;
  final presented = <String>[];

  Future<RefreshResult> refresh(String rt) async {
    presented.add(rt);
    if (ended) throw const RefreshRejected();
    if (rt == _current) {
      _previous = _current;
    } else if (rt != _previous) {
      ended = true;
      throw const RefreshRejected();
    }
    _current = 'r${++_minted}';
    return RefreshResult('a$_minted', refreshToken: _current);
  }
}

/// The Keychain as `flutter_secure_storage_darwin` 0.3.2 drives it, for items
/// that are WhenUnlocked. While [locked], reads and adds fail, and a write
/// over an EXISTING item fails its update and then deletes the item
/// (`FlutterSecureStorage.swift:560-573`). Whether a delete works while locked
/// isn't something these tests know, so it is a switch: every test that
/// locks runs both ways.
class _Keychain extends InMemorySlots {
  _Keychain(super.initial, {this.deletesWhileLocked = true}) {
    fault = (op, key) {
      if (_crashed) throw const _Crash();
      if (_countdown != null && op != 'read') {
        if (_countdown == 0) {
          _crashed = true;
          throw const _Crash();
        }
        _countdown = _countdown! - 1;
      }
      if (!locked) return;
      if (op == 'write' && data.containsKey(key) && deletesWhileLocked) {
        data.remove(key);
      }
      if (op != 'delete' || !deletesWhileLocked) {
        throw Exception('-25308 errSecInteractionNotAllowed');
      }
    };
  }

  final bool deletesWhileLocked;
  var locked = false;

  int? _countdown;
  var _crashed = false;

  /// The process dies just before its ([n]+1)th write or delete.
  void crashAfter(int n) => _countdown = n;

  /// The next launch: the same Keychain, a new process.
  InMemoryTokenStore relaunch({String? Function()? placeLegacy}) =>
      InMemoryTokenStore.withSlots(
        InMemorySlots(data),
        placeLegacy: placeLegacy,
      );
}

class _Crash implements Exception {
  const _Crash();
}

const _island = kTestIsland;
const _other = 'https://chat.enspyr.co';
const _signedIn = AuthTokens(accessToken: 'a0', refreshToken: 'r0');

String _record(String island, AuthTokens t, {int seq = 1}) => jsonEncode({
  'v': 1,
  'seq': seq,
  'island': island,
  'access': t.accessToken,
  'refresh': t.refreshToken,
});

DefaultTokenProvider _door(
  SessionVault vault,
  Future<RefreshResult> Function(String) remote, {
  String island = _island,
  void Function()? onUnauthenticated,
}) => DefaultTokenProvider(
  vault: vault,
  island: island,
  remoteRefresh: remote,
  onUnauthenticated: onUnauthenticated,
);

Future<Credential?> _refreshCurrent(DefaultTokenProvider door) async =>
    door.refresh((await door.current())!);

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

  test('RefreshResult.fromJson reads the rotated token, or its absence', () {
    final rotated = RefreshResult.fromJson({
      'access_token': 'a1',
      'refresh_token': 'r1',
    });
    expect((rotated.accessToken, rotated.refreshToken), ('a1', 'r1'));
    final legacy = RefreshResult.fromJson({'access_token': 'a1'});
    expect(legacy.refreshToken, isNull);
  });

  group('rotation', () {
    test('a rotated refresh token is stored, and the next refresh presents '
        'it, across a relaunch', () async {
      final island = _RotatingIsland();
      final keychain = _Keychain({
        'aiko_session.0': _record(_island, _signedIn),
      });
      final door = _door(
        InMemoryTokenStore.withSlots(keychain),
        island.refresh,
      );
      await _refreshCurrent(door);
      expect(storedOnDisk(keychain)?.tokens.refreshToken, 'r1');

      final next = _door(keychain.relaunch(), island.refresh);
      expect((await _refreshCurrent(next))?.accessToken, 'a2');
      expect(island.presented, ['r0', 'r1']);
      expect(island.ended, isFalse);
    });

    test('an island that predates rotation omits refresh_token: keep '
        'ours', () async {
      final vault = InMemoryTokenStore(_signedIn);
      final door = _door(vault, (_) async => const RefreshResult('a1'));
      await _refreshCurrent(door);
      expect(
        vault.current,
        const AuthTokens(accessToken: 'a1', refreshToken: 'r0'),
      );
    });

    for (final deletes in [true, false]) {
      test(
        'a phone locked through two refreshes, then a relaunch: still signed '
        'in (deletes while locked: $deletes)',
        () async {
          final island = _RotatingIsland();
          final keychain = _Keychain({
            'aiko_session.0': _record(_island, _signedIn),
          }, deletesWhileLocked: deletes);
          final door = _door(
            InMemoryTokenStore.withSlots(keychain),
            island.refresh,
          );
          await door.current();
          keychain.locked = true;

          // Neither rotation reaches the disk. Each presents what the disk
          // holds, which the island takes as PREVIOUS: a retry.
          expect((await _refreshCurrent(door))?.accessToken, 'a1');
          expect((await _refreshCurrent(door))?.accessToken, 'a2');

          keychain.locked = false;
          final next = _door(keychain.relaunch(), island.refresh);
          expect(
            await next.current(),
            isNotNull,
            reason: 'a failed write must never erase the live record',
          );
          await _refreshCurrent(next);
          expect(
            island.ended,
            isFalse,
            reason: 'presented: ${island.presented}',
          );
        },
      );
    }

    test('a crash at every step of a rotation leaves a token the island '
        'accepts', () async {
      for (var step = 0; step < 6; step++) {
        final island = _RotatingIsland();
        final keychain = _Keychain({
          'aiko_session.0': _record(_island, _signedIn),
        });
        final door = _door(
          InMemoryTokenStore.withSlots(keychain),
          island.refresh,
        );
        await door.current();
        keychain.crashAfter(step);
        try {
          await _refreshCurrent(door);
        } catch (_) {}

        final next = _door(keychain.relaunch(), island.refresh);
        expect(await next.current(), isNotNull, reason: 'crash after $step');
        await _refreshCurrent(next);
        expect(
          island.ended,
          isFalse,
          reason: 'crash after $step presented ${island.presented}',
        );
      }
    });
  });

  group('the lease: work for one session never touches another', () {
    test('a refresh superseded by a sign-in fails for its callers: it never '
        'hands them the new account\'s token (PR #452, round 3)', () async {
      final answer = Completer<RefreshResult>();
      final vault = InMemoryTokenStore(_signedIn);
      final door = _door(vault, (_) => answer.future);
      final a = (await door.current())!;
      final aWork = door.refresh(a);
      final aWorkToo = door.refresh(a);

      await door.setTokens(
        const AuthTokens(accessToken: 'b0', refreshToken: 's0'),
      );
      answer.complete(const RefreshResult('a1', refreshToken: 'r1'));

      await expectLater(aWork, throwsA(isA<SessionSuperseded>()));
      await expectLater(aWorkToo, throwsA(isA<SessionSuperseded>()));
      // A's refresh, asked for after B signed in, is refused at once.
      await expectLater(door.refresh(a), throwsA(isA<SessionSuperseded>()));
      expect(vault.current?.accessToken, 'b0', reason: 'B is not reverted');
    });

    test('a request made under A, refused with 401, is not retried as B when '
        'B signs in during its refresh', () async {
      final answer = Completer<RefreshResult>();
      final vault = InMemoryTokenStore(_signedIn);
      final door = _door(vault, (_) => answer.future);
      final dio = Dio(BaseOptions(baseUrl: 'http://x'));
      dio.interceptors.add(AuthInterceptor(door, dio));
      final seen = <String?>[];
      dio.httpClientAdapter = FakeHttpAdapter((opts) {
        seen.add(opts.headers['Authorization'] as String?);
        return seen.length == 1
            ? jsonBody(401, '{"detail":"expired"}')
            : jsonBody(200, '{"ok":true}');
      });

      final request = dio.post('/v1/messages');
      await pumpEventQueue();
      await door.setTokens(
        const AuthTokens(accessToken: 'b0', refreshToken: 's0'),
      );
      answer.complete(const RefreshResult('a1', refreshToken: 'r1'));

      await expectLater(request, throwsA(isA<DioException>()));
      expect(seen, ['Bearer a0'], reason: 'nothing was sent as B');
    });

    test('a retry carries its refreshed token, not whoever signed in between '
        'the refresh and the retry', () async {
      final vault = InMemoryTokenStore(_signedIn);
      final door = _SignInAfterRefresh(
        _door(
          vault,
          (_) async => const RefreshResult('a1', refreshToken: 'r1'),
        ),
      );
      final dio = Dio(BaseOptions(baseUrl: 'http://x'));
      dio.interceptors.add(AuthInterceptor(door, dio));
      final seen = <String?>[];
      dio.httpClientAdapter = FakeHttpAdapter((opts) {
        seen.add(opts.headers['Authorization'] as String?);
        return seen.length == 1
            ? jsonBody(401, '{}')
            : jsonBody(200, '{"ok":true}');
      });
      await dio.post('/v1/messages');
      expect(seen, ['Bearer a0', 'Bearer a1']);
    });

    test('two consumers refreshing one stale credential, one after the '
        'other, rotate once: the second gets the first\'s result', () async {
      final island = _RotatingIsland();
      final door = _door(InMemoryTokenStore(_signedIn), island.refresh);
      final a = (await door.current())!;
      final rest = await door.refresh(a); // the REST interceptor
      final wss = await door.refresh(a); // the socket, a moment later
      expect(wss?.accessToken, rest?.accessToken);
      expect(island.presented, ['r0']);
    });

    test('a sign-in landing while a refresh is WRITING is not overwritten by '
        'it', () async {
      final keychain = _HeldWrites({
        'aiko_session.0': _record(_island, _signedIn),
      });
      final vault = InMemoryTokenStore.withSlots(keychain);
      final door = _door(
        vault,
        (_) async => const RefreshResult('a1', refreshToken: 'r1'),
      );
      await door.current();
      keychain.holdNextWrite();
      final refresh = _refreshCurrent(door);
      await keychain.writing;
      final signIn = door.setTokens(
        const AuthTokens(accessToken: 'b0', refreshToken: 's0'),
      );
      keychain.releaseWrite();
      await refresh;
      await signIn;
      expect(vault.current?.accessToken, 'b0');
      expect((await door.current())?.accessToken, 'b0');
    });

    test('a sign-out landing mid-refresh stays signed out', () async {
      final answer = Completer<RefreshResult>();
      final vault = InMemoryTokenStore(_signedIn);
      final door = _door(vault, (_) => answer.future);
      final refresh = _refreshCurrent(door);
      await pumpEventQueue();
      await door.clearTokens();
      answer.complete(const RefreshResult('a1', refreshToken: 'r1'));
      await expectLater(refresh, throwsA(isA<SessionSuperseded>()));
      expect(await door.current(), isNull);
      expect(vault.current, isNull);
    });

    test('a rejection of the OLD session after a fresh sign-in does not end '
        'the new one', () async {
      final answer = Completer<RefreshResult>();
      var unauth = 0;
      final vault = InMemoryTokenStore(_signedIn);
      final door = _door(
        vault,
        (_) => answer.future,
        onUnauthenticated: () => unauth++,
      );
      final refresh = _refreshCurrent(door);
      await pumpEventQueue();
      await door.setTokens(
        const AuthTokens(accessToken: 'b0', refreshToken: 's0'),
      );
      answer.completeError(const RefreshRejected());
      await expectLater(refresh, throwsA(isA<SessionSuperseded>()));
      expect(unauth, 0);
      expect(vault.current?.accessToken, 'b0');
    });

    test('a sign-out landing during the first Keychain read stays signed '
        'out', () async {
      final keychain = _HeldReads({
        'aiko_session.0': _record(_island, _signedIn),
      });
      final door = _door(
        InMemoryTokenStore.withSlots(keychain),
        (_) async => const RefreshResult('a1'),
      );
      final read = door.current();
      await keychain.reading;
      final out = door.clearTokens();
      keychain.finishRead();
      await read;
      await out;
      expect(await door.current(), isNull);
    });

    test('a cold read that a sign-out overtakes presents nothing, not the '
        'ended session under the sign-out\'s lease', () async {
      final vault = InMemoryTokenStore(_signedIn);
      final read = vault.present(_island);
      final out = vault.signOut();
      expect(await read, isNull);
      await out;
    });

    test('a Keychain that refuses the first read fails the request: it does '
        'not leave it pending, and does not call it a logout', () async {
      final keychain = InMemorySlots({
        'aiko_session.0': _record(_island, _signedIn),
      })..fault = (op, _) => throw Exception('-25308');
      final door = _door(
        InMemoryTokenStore.withSlots(keychain),
        (_) async => const RefreshResult('a1'),
      );
      final dio = Dio(BaseOptions(baseUrl: 'http://x'));
      dio.interceptors.add(AuthInterceptor(door, dio));
      dio.httpClientAdapter = FakeHttpAdapter((_) => jsonBody(200, '{}'));
      final failed = await dio
          .get('/v1/channels')
          .then<DioException?>(
            (_) => null,
            onError: (Object e) => e as DioException,
          )
          .timeout(const Duration(seconds: 5));
      expect(failed, isNotNull);
      expect(failed!.requestOptions.extra['auth_transient'], isTrue);
    });

    test('a hung refresh does not hold the next session hostage', () async {
      final hung = Completer<RefreshResult>();
      var calls = 0;
      final door = _door(InMemoryTokenStore(_signedIn), (_) {
        calls++;
        return calls == 1
            ? hung.future
            : Future.value(const RefreshResult('b1', refreshToken: 's1'));
      });
      unawaited(_refreshCurrent(door).then((_) {}, onError: (_) {}));
      await pumpEventQueue();
      await door.setTokens(
        const AuthTokens(accessToken: 'b0', refreshToken: 's0'),
      );
      expect((await _refreshCurrent(door))?.accessToken, 'b1');
      expect(calls, 2);
    });

    test('a door rebuilt for the same island joins the refresh already in '
        'flight: one chain, one presentation', () async {
      final island = _RotatingIsland();
      final gate = Completer<void>();
      Future<RefreshResult> slow(String rt) async {
        await gate.future;
        return island.refresh(rt);
      }

      final vault = InMemoryTokenStore(_signedIn);
      final first = _door(vault, slow);
      final second = _door(vault, slow); // backendProvider rebuilt it
      final a = (await first.current())!;
      final f1 = first.refresh(a);
      final f2 = second.refresh(a);
      gate.complete();
      expect([(await f1)?.accessToken, (await f2)?.accessToken], ['a1', 'a1']);
      expect(island.presented, ['r0']);

      await _refreshCurrent(second);
      expect(island.presented, ['r0', 'r1']);
      expect(island.ended, isFalse);
    });
  });

  group('rejection ends the session', () {
    test(
      'a rejected refresh ends it on disk and fires once per caller',
      () async {
        var unauth = 0;
        final vault = InMemoryTokenStore(_signedIn);
        final door = _door(
          vault,
          (_) async => throw const RefreshRejected(),
          onUnauthenticated: () => unauth++,
        );
        expect(await _refreshCurrent(door), isNull);
        expect(unauth, 1);
        expect(await door.current(), isNull);
        expect(vault.current, isNull);
      },
    );

    for (final deletes in [true, false]) {
      test('a rejected session ends in this process even when the Keychain '
          'refuses to record it (deletes while locked: $deletes)', () async {
        final keychain = _Keychain({
          'aiko_session.0': _record(_island, _signedIn),
        }, deletesWhileLocked: deletes);
        var unauth = 0;
        final door = _door(
          InMemoryTokenStore.withSlots(keychain),
          (_) async => throw const RefreshRejected(),
          onUnauthenticated: () => unauth++,
        );
        await door.current();
        keychain.locked = true;
        expect(await _refreshCurrent(door), isNull, reason: 'not a throw');
        expect(unauth, 1);
        expect(await door.current(), isNull);
      });
    }
  });

  group('the door', () {
    test('presents a session only to the island that issued it', () async {
      final vault = InMemoryTokenStore(_signedIn, _other);
      final here = _door(vault, (_) async => const RefreshResult('x'));
      final there = _door(
        vault,
        (_) async => const RefreshResult('a1'),
        island: _other,
      );
      expect(await here.current(), isNull);
      expect((await there.current())?.accessToken, 'a0');
    });

    test('a sign-in for one island does not replace another island\'s live '
        'session', () async {
      final vault = InMemoryTokenStore(_signedIn, _other);
      final here = _door(vault, (_) async => const RefreshResult('x'));
      await expectLater(
        here.setTokens(const AuthTokens(accessToken: 'b0', refreshToken: 's0')),
        throwsA(isA<SessionHeldElsewhere>()),
      );
      expect(vault.current, _signedIn);
    });
  });

  group('the legacy pair: read once, placed, retired', () {
    Map<String, String> legacy() => {
      SessionVault.legacyAccessKey: 'a0',
      SessionVault.legacyRefreshKey: 'r0',
    };

    test('placed on the island placement names, written as a slot, and never '
        'read again', () async {
      final keychain = _Keychain(legacy());
      final vault = InMemoryTokenStore.withSlots(
        keychain,
        placeLegacy: () => _island,
      );
      expect((await vault.present(_island))?.accessToken, 'a0');
      expect(storedOnDisk(keychain)?.island, _island);
      expect(keychain.data.keys, isNot(contains(SessionVault.legacyAccessKey)));

      final next = keychain.relaunch(
        placeLegacy: () => fail('placement asked again'),
      );
      expect((await next.present(_island))?.accessToken, 'a0');
    });

    test('a pair nothing can place is owner-unknown: never presented, and a '
        'later launch does not place it on the island settled since (v2\'s '
        'leak)', () async {
      final keychain = _Keychain(legacy());
      final first = InMemoryTokenStore.withSlots(
        keychain,
        placeLegacy: () => null,
      );
      expect(await first.present(_island), isNull);

      // The next launch's placement would now say _island: too late.
      final next = keychain.relaunch(placeLegacy: () => _island);
      expect(await next.present(_island), isNull);
      expect(await next.present(_other), isNull);
    });

    test('owner-unknown is discardable: a sign-in replaces it', () async {
      final keychain = _Keychain(legacy());
      final vault = InMemoryTokenStore.withSlots(
        keychain,
        placeLegacy: () => null,
      );
      final door = _door(vault, (_) async => const RefreshResult('x'));
      await door.setTokens(
        const AuthTokens(accessToken: 'b0', refreshToken: 's0'),
      );
      expect((await door.current())?.accessToken, 'b0');
    });

    test('a placement write that fails places nothing, and the next launch '
        'places it from the same inputs (v3.1 requirement 2)', () async {
      final keychain = _Keychain(legacy())..locked = true;
      keychain.fault = (op, key) {
        if (op == 'write') throw Exception('-25308');
      };
      final vault = InMemoryTokenStore.withSlots(
        keychain,
        placeLegacy: () => _island,
      );
      await expectLater(vault.present(_island), throwsA(isA<Exception>()));

      final next = _Keychain(
        keychain.data,
      ).relaunch(placeLegacy: () => _island);
      expect((await next.present(_island))?.accessToken, 'a0');
    });

    test('the island #439\'s branch stored with the pair wins over '
        'placement (rule 1)', () async {
      final keychain = _Keychain({
        ...legacy(),
        SessionVault.legacyIslandKey: _other,
      });
      final vault = InMemoryTokenStore.withSlots(
        keychain,
        placeLegacy: () => _island,
      );
      expect(await vault.present(_island), isNull);
      expect((await vault.present(_other))?.accessToken, 'a0');
    });
  });

  group('unreadable data', () {
    test('garbage is never presented, and a sign-in replaces it', () async {
      final keychain = _Keychain({'aiko_session.0': 'not json'});
      final reports = <String>[];
      final vault = SessionVault(
        keychain,
        placeLegacy: () => null,
        report: reports.add,
      );
      final door = _door(vault, (_) async => const RefreshResult('x'));
      expect(await door.current(), isNull);
      await door.setTokens(
        const AuthTokens(accessToken: 'b0', refreshToken: 's0'),
      );
      expect((await door.current())?.accessToken, 'b0');
      expect(reports, contains('vault.unreadable_replaced'));
    });

    test('a newer build\'s record wins by its sequence: a rollback does not '
        'fall back to the older record it replaced', () async {
      final keychain = _Keychain({
        'aiko_session.0': _record(_island, _signedIn, seq: 4),
        'aiko_session.1': jsonEncode({'v': 2, 'seq': 5, 'whatever': true}),
      });
      final vault = InMemoryTokenStore.withSlots(keychain);
      expect(await vault.present(_island), isNull);
    });

    test('of two readable slots, the higher sequence is the session', () async {
      final keychain = _Keychain({
        'aiko_session.0': _record(
          _island,
          const AuthTokens(accessToken: 'new', refreshToken: 'r9'),
          seq: 9,
        ),
        'aiko_session.1': _record(_island, _signedIn, seq: 8),
      });
      final vault = InMemoryTokenStore.withSlots(keychain);
      expect((await vault.present(_island))?.accessToken, 'new');
    });
  });

  group('sign-out', () {
    test('a crash at any step of a sign-out leaves nothing, or the session '
        'being signed out: never an older record or the legacy pair', () async {
      for (var step = 0; step < 12; step++) {
        for (final tombstoneFails in [false, true]) {
          // The worst disk this build can leave: a newer record live, an
          // older one whose retirement failed, and a legacy pair whose
          // retirement failed too.
          final keychain = _Keychain({
            'aiko_session.0': _record(
              _island,
              const AuthTokens(accessToken: 'old', refreshToken: 'r-old'),
              seq: 1,
            ),
            'aiko_session.1': _record(_island, _signedIn, seq: 2),
            SessionVault.legacyAccessKey: 'legacy',
            SessionVault.legacyRefreshKey: 'r-legacy',
          });
          final vault = InMemoryTokenStore.withSlots(
            keychain,
            placeLegacy: () => _island,
          );
          await vault.present(_island);
          if (tombstoneFails) {
            final crash = keychain.fault!;
            keychain.fault = (op, key) {
              crash(op, key);
              if (op == 'write') throw Exception('tombstone refused');
            };
          }
          keychain.crashAfter(step);
          try {
            await vault.signOut();
          } catch (_) {}

          final after = await keychain
              .relaunch(placeLegacy: () => _island)
              .present(_island);
          expect(
            after?.accessToken,
            anyOf(isNull, 'a0'),
            reason: 'crash after $step, tombstone fails: $tombstoneFails',
          );
        }
      }
    });

    test('a sign-out the Keychain refuses entirely is rethrown, and still '
        'ends the session in this process', () async {
      final keychain = _Keychain({
        'aiko_session.0': _record(_island, _signedIn),
      });
      final vault = InMemoryTokenStore.withSlots(keychain);
      await vault.present(_island);
      keychain.fault = (op, key) {
        if (op != 'read') throw Exception('refused');
      };
      await expectLater(vault.signOut(), throwsA(isA<Exception>()));
      expect(await vault.present(_island), isNull);
    });

    test('a sign-out before anything read the vault does not write under the '
        'live record\'s sequence', () async {
      final keychain = _Keychain({
        'aiko_session.1': _record(_island, _signedIn, seq: 7),
      });
      await InMemoryTokenStore.withSlots(keychain).signOut();
      expect(await keychain.relaunch().present(_island), isNull);
    });

    // The sign-out above, refused: memory ends the session without having
    // read where it lives on disk. The next write must still find out.
    for (final live in ['aiko_session.0', 'aiko_session.1']) {
      test('a sign-out the Keychain refused before anything read it, then a '
          'sign-in: the next launch has the sign-in ($live live)', () async {
        // Nothing works while locked, deletes included: the sign-out leaves
        // the old record exactly where it was.
        final keychain = _Keychain({
          live: _record(_island, _signedIn, seq: 7),
        }, deletesWhileLocked: false);
        final vault = InMemoryTokenStore.withSlots(keychain);
        keychain.locked = true;
        await expectLater(vault.signOut(), throwsA(anything));
        keychain.locked = false;
        await vault.adopt(
          _island,
          const AuthTokens(accessToken: 'b0', refreshToken: 's0'),
        );
        expect(
          (await keychain.relaunch().present(_island))?.accessToken,
          'b0',
          reason: 'the account signed out of must not come back',
        );
      });
    }

    test('a sign-out that can\'t read the slots deletes neither: a crash '
        'between two blind deletes could leave the older record', () async {
      final keychain = _Keychain({
        'aiko_session.0': _record(_island, _signedIn, seq: 2),
        'aiko_session.1': _record(
          _island,
          const AuthTokens(accessToken: 'old', refreshToken: 'r-old'),
        ),
      });
      final vault = InMemoryTokenStore.withSlots(keychain);
      keychain.locked = true; // reads fail; deletes still work
      // Dies after the legacy pair's three deletes: a blind [0, 1] sweep
      // would have removed the newer slot and not yet the older.
      keychain.crashAfter(4);
      await expectLater(vault.signOut(), throwsA(anything));
      expect(
        (await keychain.relaunch().present(_island))?.accessToken,
        'a0',
        reason: 'still signed in is allowed; an older session is not',
      );
    });
  });
}

/// A door whose refresh lets account B sign in after A's refresh returned and
/// before its caller acts on the result: the window between an interceptor's
/// refresh and its retry.
class _SignInAfterRefresh implements TokenProvider {
  _SignInAfterRefresh(this._door);
  final DefaultTokenProvider _door;

  @override
  Future<Credential?> current() => _door.current();

  @override
  Future<Credential?> refresh(Credential stale) async {
    final fresh = await _door.refresh(stale);
    await _door.setTokens(
      const AuthTokens(accessToken: 'b0', refreshToken: 's0'),
    );
    return fresh;
  }
}

/// Holds one write open until released, so a test can land a sign-in while
/// a refresh's Keychain write is in progress.
class _HeldWrites extends InMemorySlots {
  _HeldWrites(super.initial);
  var _armed = false;
  final _release = Completer<void>();
  final _writing = Completer<void>();
  Future<void> get writing => _writing.future;

  void holdNextWrite() => _armed = true;
  void releaseWrite() => _release.complete();

  @override
  Future<void> write(String key, String value) async {
    if (_armed) {
      _armed = false;
      _writing.complete();
      await _release.future;
    }
    await super.write(key, value);
  }
}

/// Holds the first read open until released, so a sign-out can land during it.
class _HeldReads extends InMemorySlots {
  _HeldReads(super.initial);
  final _reading = Completer<void>();
  final _finish = Completer<void>();
  Future<void> get reading => _reading.future;
  void finishRead() => _finish.complete();

  @override
  Future<String?> read(String key) async {
    final snapshot = data[key];
    if (!_reading.isCompleted) {
      _reading.complete();
      await _finish.future;
    }
    return snapshot;
  }
}
