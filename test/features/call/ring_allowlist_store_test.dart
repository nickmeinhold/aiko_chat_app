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
  // Every case below is about a property OTHER than scoping (canonicalisation,
  // per-user namespacing, unmodifiability, serialisation), so they all run in
  // one conversation. The scoping property itself is exercised in its own group.
  const chan = 'dm:aaa:bbb';

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
      expect(s.read(chan).keys, isEmpty);
      expect(await s.allow(chan, resident), isTrue);
      expect(s.read(chan).keys, {resident});
    });

    test('revoking from an EMPTY store does not throw either', () async {
      final s = await storeFor(alice);
      expect(await s.revoke(chan, resident), isTrue);
      expect(s.read(chan).keys, isEmpty);
    });

    test('read() is unmodifiable on EVERY path, not just some', () async {
      // The defect was a type that was sometimes mutable. Assert the invariant
      // directly, so a future `read()` that returns a growable set on one branch
      // fails here rather than in production on a branch no test visits.
      // ASSERTED ON readAll(), NOT THROUGH read(chan) — a fix-interaction the
      // round-2 ledger caught (Carnot MEDIUM vs Tesla). `RingConsent.inChannel`
      // now freezes its keys at construction, so `read(chan).keys` is
      // unmodifiable NO MATTER WHAT `readAll` returned. Testing through it
      // therefore proves the constructor, not the store — the assertion passes
      // identically whether the store's branches are frozen or growable, which
      // is precisely the void-test shape this group exists to prevent.
      final empty = await storeFor(alice);
      expect(() => empty.readAll()['x'] = {resident}, throwsUnsupportedError);
      await empty.allow(chan, resident);
      expect(
        () => empty.readAll()[chan]!.add(stranger),
        throwsUnsupportedError,
      );
      expect(() => empty.readAll()['y'] = {stranger}, throwsUnsupportedError);
      final corrupt = await storeFor(
        alice,
        // THE CURRENT KEY. This seeded `aiko_ring_allowed_keys_` until round 2
        // (Tesla): after the rename `readAll` looked at `aiko_ring_consent_`,
        // found nothing, and returned via the `raw == null` arm — so this test
        // stopped touching the `catch` branch it exists for. PROVEN void by
        // making the catch return a MODIFIABLE map: every test stayed green.
        seed: {'flutter.aiko_ring_consent_$alice': 'not json'},
      );
      expect(() => corrupt.readAll()['x'] = {resident}, throwsUnsupportedError);
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

      expect(await aliceStore.allow(chan, resident), isTrue);
      expect(aliceStore.read(chan).keys, {resident});
      expect(bobStore.read(chan).keys, isEmpty, reason: 'Bob inherits nothing');

      expect(await bobStore.allow(chan, stranger), isTrue);
      expect(aliceStore.read(chan).keys, {
        resident,
      }, reason: "Bob cannot edit Alice's");
    });

    test('signed out, nobody can read or grant', () async {
      final s = await storeFor(null);
      expect(s.read(chan).keys, isEmpty);
      expect(await s.allow(chan, resident), isFalse);
      expect(await s.revoke(chan, resident), isFalse);
    });
  });

  group('concurrent mutations do not lose each other', () {
    test('two ROOMS mutating concurrently do not erase each other — the dimension '
        'per-conversation storage introduced', () async {
      // Tesla (round 2), and it is a real gap rather than a restatement: the
      // stored shape is now ONE JSON DOCUMENT for every room, so two grants in
      // DIFFERENT conversations are the same read-modify-write on one blob.
      // The existing race test collides two keys inside a single channel, which
      // was the only dimension the global store had — it cannot fail on this
      // one, so it pins nothing about it.
      //
      // The value is forward-looking and named as such: a later "optimisation"
      // to per-channel serialisation would look exactly like the ruling, pass
      // the older test, and let allow(roomA) and allow(roomB) take turns
      // erasing each other.
      //
      // CANNOT GO RED TODAY, stated plainly rather than implied — the same
      // caveat as its sibling below, for the same measured reason: this backing
      // store's cache updates synchronously, so the interleave is not reachable
      // through it. An attempt to force it by removing the serialise chain left
      // this GREEN. So it is a SHAPE PIN for a future async-backed store, not
      // evidence the chain is load-bearing now. Claiming a red arm here would be
      // the void test this file keeps exorcising.
      final s = await storeFor(alice);

      await Future.wait([
        s.allow('room-a', resident),
        s.allow('room-b', stranger),
        s.allow('room-c', resident),
      ]);

      expect(s.readAll().keys, {'room-a', 'room-b', 'room-c'});
      expect(s.read('room-a').keys, {resident});
      expect(s.read('room-b').keys, {stranger});
      expect(s.read('room-c').keys, {resident});
    });

    test('a revoke racing a grant does not resurrect the revoked key', () async {
      // PROPERTY TEST, NOT A REGRESSION TEST — and the distinction is the point.
      //
      // Tesla (cage-match round 2) described a read-modify-write interleave:
      // revoke snapshots {A,B}, allow snapshots {A,B}, revoke persists {B},
      // allow persists {A,B,C}, and A returns from the dead. The reasoning is
      // sound and the `_serialize` chain that answers it is real.
      //
      // But this test does NOT go red without that chain, and pretending
      // otherwise would be exactly the void test this PR keeps exorcising.
      // MEASURED: `SharedPreferences.setString` updates its in-memory cache
      // SYNCHRONOUSLY, before the returned Future completes — a probe reading
      // the key without awaiting the write already sees the new value. So the
      // window Tesla names is not reachable through THIS backing store, and the
      // chain is defence for a future one (or a different prefs impl) rather
      // than a fix for a live defect. Stated so the next reader does not read a
      // green here as proof the chain is load-bearing.
      //
      // (Same caveat applies to `PendingUnregisterStore._writes`, whose comment
      // claims more than its backing store can currently do wrong.)
      final s = await storeFor(alice);
      await s.allow(chan, resident);
      await s.allow(chan, stranger);
      // Fire both WITHOUT awaiting between them — that is the race.
      final revoking = s.revoke(chan, resident);
      final granting = s.allow(chan, encodeMultikey(Uint8List(32)..[0] = 11));
      await Future.wait([revoking, granting]);
      expect(
        s.read(chan).keys,
        isNot(contains(resident)),
        reason: 'the revoked key must not survive a concurrent grant',
      );
      expect(s.read(chan).keys, contains(stranger));
    });
  });

  group('what is stored must be what is MATCHED', () {
    test('a stored key is byte-identical to what admitRing compares', () async {
      // `_mayRing` compares against `encodeMultikey(origin.rawPublicKey)`. If the
      // store kept the caller's input verbatim, any alternate-but-valid form
      // would be written into a register the ring path never consults — consent
      // that silently does nothing, and a revoke that cannot find it.
      final s = await storeFor(alice);
      await s.allow(chan, resident);
      expect(s.read(chan).keys.single, encodeMultikey(residentKey));
    });

    test('a malformed key is refused at the moment of consent', () async {
      final s = await storeFor(alice);
      for (final bad in ['', 'not-a-key', 'z', 'zzzz', resident.substring(1)]) {
        expect(await s.allow(chan, bad), isFalse, reason: 'allow("$bad")');
      }
      expect(s.read(chan).keys, isEmpty);
    });

    test('revoke removes exactly one key and leaves the rest', () async {
      final s = await storeFor(alice);
      await s.allow(chan, resident);
      await s.allow(chan, stranger);
      expect(s.read(chan).keys, {resident, stranger});
      expect(await s.revoke(chan, resident), isTrue);
      expect(s.read(chan).keys, {stranger});
    });

    test('a corrupt value reads as empty rather than throwing', () async {
      // Losing a ring beats admitting an unintended ringer, and an unpayable
      // store must never brick the ring path.
      final s = await storeFor(
        alice,
        // Current key, same reason as above. The payload is a MAP whose values
        // are not lists — the shape that reaches the `as List` cast inside the
        // decode loop, which is where the new format can actually go wrong.
        seed: {'flutter.aiko_ring_consent_$alice': '{"a":"not a list"}'},
      );
      expect(s.read(chan).keys, isEmpty);
    });
  });

  group('per conversation (Nick, 2026-08-26)', () {
    const other = 'dm:aaa:ccc';

    test('a grant in one room does not appear in another', () async {
      final s = await storeFor(alice);
      await s.allow(chan, resident);

      expect(s.read(chan).keys, {resident});
      expect(s.read(other).keys, isEmpty);
    });

    test('the same key can be consented in two rooms independently', () async {
      final s = await storeFor(alice);
      await s.allow(chan, resident);
      await s.allow(other, resident);

      await s.revoke(chan, resident);

      expect(s.read(chan).keys, isEmpty);
      expect(
        s.read(other).keys,
        {resident},
        reason:
            'a covenant made twice must be unmade twice — a scoped revoke that '
            'reached other rooms would make revoke mean something different '
            'from allow',
      );
    });

    test('read() always names the room it was asked about', () async {
      final s = await storeFor(alice);
      // Including when empty. An empty consent FOR this room and a consent for
      // some OTHER room must not be the same value, or the gate's scope check
      // has nothing to compare.
      expect(s.read(other).channelId, other);
      expect(s.read(other).keys, isEmpty);
    });

    test(
      'the last revoke in a room removes the room, not just the key',
      () async {
        final s = await storeFor(alice);
        await s.allow(chan, resident);
        await s.allow(chan, stranger);
        await s.revoke(chan, resident);
        expect(s.readAll().keys, {chan}, reason: 'still one key left');

        await s.revoke(chan, stranger);
        expect(
          s.readAll(),
          isEmpty,
          reason:
              'an empty room left behind is a record of a covenant that no longer '
              'exists, and it keeps the whole map alive on disk',
        );
      },
    );

    test(
      'a stored EMPTY room is dropped on read, not published as a scope',
      () async {
        // The write path prunes; the read path did not, so a hand-edited or
        // partly-written file could publish a room that `permits` admits nobody
        // through — a listing that contradicts the gate (Carnot LOW).
        final s = await storeFor(
          alice,
          seed: {
            'flutter.aiko_ring_consent_$alice':
                '{"$chan":[],"$other":["$resident"]}',
          },
        );

        expect(s.readAll().keys, {other});
        expect(s.read(chan).keys, isEmpty);
      },
    );

    test('readAll is unmodifiable at BOTH levels', () async {
      final s = await storeFor(alice);
      await s.allow(chan, resident);
      expect(() => s.readAll()[other] = {stranger}, throwsUnsupportedError);
      expect(() => s.readAll()[chan]!.add(stranger), throwsUnsupportedError);
    });
  });

  group('the global-scope grant is dropped, not migrated', () {
    // A legacy value says "anywhere", and per-conversation consent has no
    // "anywhere". Promoting it into every channel the user can see is exactly
    // the outcome the ruling rejected, so it fails closed and the user re-grants.
    const legacyKey = 'aiko_ring_allowed_keys_$alice';

    test('a legacy global list grants nothing in any room', () async {
      final s = await storeFor(alice, seed: {legacyKey: '["$resident"]'});

      expect(s.read(chan).keys, isEmpty);
      expect(s.read('dm:aaa:ccc').keys, isEmpty);
      expect(s.readAll(), isEmpty);
    });

    test('and it is REMOVED from disk, not merely ignored', () async {
      SharedPreferences.setMockInitialValues({legacyKey: '["$resident"]'});
      final prefs = await SharedPreferences.getInstance();
      final s = RingAllowlistStore(prefs, alice);
      expect(prefs.containsKey(legacyKey), isTrue, reason: 'precondition');

      await s.dropLegacyGlobalConsent();

      expect(
        prefs.containsKey(legacyKey),
        isFalse,
        reason:
            'a value on disk that nothing reads is a record of consent that no '
            'longer means anything',
      );
    });

    test(
      'dropping is safe when there is nothing to drop, and when signed out',
      () async {
        final s = await storeFor(alice);
        await expectLater(s.dropLegacyGlobalConsent(), completes);

        final out = await storeFor(null);
        await expectLater(out.dropLegacyGlobalConsent(), completes);
      },
    );

    test(
      'the drop CANNOT FAIL — a throwing store must not reject its Future',
      () async {
        // THE RED ARM. `dropLegacyGlobalConsent` is async, so a throw in its body
        // completes the returned Future with an error rather than throwing
        // synchronously — and its only caller invokes it fire-and-forget inside a
        // `try` that can see synchronous throws ONLY. Before the fix, a null
        // preferences store with a signed-in user hit `_prefs!` and the rejection
        // escaped as an UNHANDLED ASYNC ERROR, failing whichever test the
        // microtask happened to drain into.
        //
        // A null store with a non-null user is the reachable throw, so this arm
        // FORCES the bad state rather than asserting the good one — a harness
        // that cannot create the failure cannot clear it.
        final broken = RingAllowlistStore(null, alice);

        await expectLater(broken.dropLegacyGlobalConsent(), completes);
      },
    );

    test('a new-format store is untouched by the drop', () async {
      final s = await storeFor(alice);
      await s.allow(chan, resident);
      await s.dropLegacyGlobalConsent();
      expect(s.read(chan).keys, {resident});
    });
  });
}
