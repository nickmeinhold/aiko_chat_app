import 'dart:typed_data';

import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/call/application/ring_allowlist_provider.dart';
import 'package:aiko_chat_app/features/call/domain/ring_consent.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:aiko_chat_app/features/chat/domain/origin_envelope.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The seam between the store and the ring's trust decision.
///
/// The first version of this provider was a plain `Provider` that read once and
/// cached forever, while the store's mutators wrote preferences and notified
/// nobody — so a grant was invisible until process death and, far worse, a
/// REVOKE had no effect. "Withdraw consent" was a button that lied. These tests
/// pin that consent MOVES, because a permission you cannot take back is not a
/// permission.
void main() {
  const chan = 'dm:aaa:bbb';

  TestWidgetsFlutterBinding.ensureInitialized();

  final resident = encodeMultikey(Uint8List(32)..[0] = 7);
  const alice = AppUser(
    userId: 'user-alice',
    username: 'alice',
    displayName: 'Alice',
    aikoUsername: 'alice',
  );

  const bob = AppUser(
    userId: 'user-bob',
    username: 'bob',
    displayName: 'Bob',
    aikoUsername: 'bob',
  );

  Future<ProviderContainer> makeContainer({AppUser? user = alice}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentUserProvider.overrideWithValue(user),
      ],
    );
  }

  test(
    'a grant is visible to the ring path IMMEDIATELY, not after a restart',
    () async {
      final c = await makeContainer();
      addTearDown(c.dispose);
      expect(
        c.read(ringConsentByChannelProvider.notifier).consentIn(chan).keys,
        isEmpty,
      );
      expect(
        await c
            .read(ringConsentByChannelProvider.notifier)
            .allow(chan, resident),
        isTrue,
      );
      // Read the PROVIDER, not the store — this is the value `admitRing` is given.
      expect(
        c.read(ringConsentByChannelProvider.notifier).consentIn(chan).keys,
        {resident},
      );
    },
  );

  test(
    'a REVOKE takes effect immediately — consent must be withdrawable',
    () async {
      final c = await makeContainer();
      addTearDown(c.dispose);
      await c.read(ringConsentByChannelProvider.notifier).allow(chan, resident);
      expect(
        c.read(ringConsentByChannelProvider.notifier).consentIn(chan).keys,
        {resident},
      );
      expect(
        await c
            .read(ringConsentByChannelProvider.notifier)
            .revoke(chan, resident),
        isTrue,
      );
      expect(
        c.read(ringConsentByChannelProvider.notifier).consentIn(chan).keys,
        isEmpty,
      );
    },
  );

  test(
    'a grant landing AFTER the user changed does not publish into the new session',
    () async {
      // The disk was namespaced per user; the in-memory register was not. `allow`
      // captures a store, yields on SharedPreferences, then publishes into
      // whichever identity now holds this notifier — so Alice's in-flight grant
      // lands in Bob's live set and Bob is woken for a covenant he never made.
      // Identity-as-mutable-key, one layer up from the prefs key fixed in round 1,
      // which is the tell that the first fix was an instance and not the class
      // (cage-match round 2, Tesla).
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          currentUserProvider.overrideWithValue(alice),
        ],
      );
      addTearDown(c.dispose);
      c
          .read(ringConsentByChannelProvider.notifier)
          .consentIn(chan)
          .keys; // materialise for alice

      final granting = c
          .read(ringConsentByChannelProvider.notifier)
          .allow(chan, resident);
      // The session turns over while the write is in flight.
      c.updateOverrides([
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentUserProvider.overrideWithValue(bob),
      ]);
      c.read(
        ringConsentByChannelProvider,
      ); // bob's build() speaks for the new sleeper
      await granting;

      expect(
        c.read(ringConsentByChannelProvider.notifier).consentIn(chan).keys,
        isEmpty,
        reason: "Alice's grant must not become Bob's consent",
      );
    },
  );

  test('a malformed grant does not move the published state', () async {
    // Failure leaves state alone rather than optimistically updating, so what a
    // caller observes is what actually persisted.
    final c = await makeContainer();
    addTearDown(c.dispose);
    expect(
      await c
          .read(ringConsentByChannelProvider.notifier)
          .allow(chan, 'not-a-key'),
      isFalse,
    );
    expect(
      c.read(ringConsentByChannelProvider.notifier).consentIn(chan).keys,
      isEmpty,
    );
  });

  test(
    'signed out, the published set is empty and cannot be granted into',
    () async {
      final c = await makeContainer(user: null);
      addTearDown(c.dispose);
      expect(
        c.read(ringConsentByChannelProvider.notifier).consentIn(chan).keys,
        isEmpty,
      );
      expect(
        await c
            .read(ringConsentByChannelProvider.notifier)
            .allow(chan, resident),
        isFalse,
      );
    },
  );

  test('an UNAVAILABLE store publishes empty rather than throwing', () async {
    // REACH IS NEVER A GATE. Wiring this naively made the ring path hard-depend
    // on SharedPreferences, and an unavailable store stopped EVERY ring —
    // including from a person — for a feature the user may never have used. It
    // broke twelve existing ring tests. `sharedPreferencesProvider` throws when
    // unoverridden, which is exactly that condition.
    final c = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(alice)],
    );
    addTearDown(c.dispose);
    expect(
      c.read(ringConsentByChannelProvider.notifier).consentIn(chan).keys,
      isEmpty,
    );
  });

  group('the legacy drop runs THROUGH build(), not just as a method', () {
    // THE TEST THAT WOULD HAVE CAUGHT ROUND 1'S OWN FIX BREAKING ITSELF.
    //
    // Round 1 rewrote the comment above `store.dropLegacyGlobalConsent()` and,
    // in doing so, replaced the comment AND the call. The method was left with
    // ZERO production callers — a dark capability, five tests deep, driven by
    // nothing — and 1091 tests stayed green because every existing test invoked
    // it directly. Only a cross-family adversary reading the provider noticed
    // (round 2, Carnot HIGH).
    //
    // So the pin has to drive the BEHAVIOUR through the real build path. A test
    // that calls the method proves the method; only this proves the wiring.
    test('materialising the provider REMOVES the global-scope key', () async {
      SharedPreferences.setMockInitialValues({
        'flutter.aiko_ring_allowed_keys_${alice.userId}': '["$resident"]',
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          currentUserProvider.overrideWithValue(alice),
        ],
      );
      addTearDown(c.dispose);
      expect(
        prefs.containsKey('aiko_ring_allowed_keys_${alice.userId}'),
        isTrue,
        reason: 'precondition: the legacy grant is on disk',
      );

      // Materialise the notifier — nothing else. This is what the ring path does.
      c.read(ringConsentByChannelProvider);
      await pumpEventQueue();

      expect(
        prefs.containsKey('aiko_ring_allowed_keys_${alice.userId}'),
        isFalse,
        reason:
            'build() must actually CALL the drop — the PR promises the key is '
            'removed from disk, and a method nobody invokes promises nothing',
      );
    });

    test('and the legacy grant confers no consent in any room', () async {
      SharedPreferences.setMockInitialValues({
        'flutter.aiko_ring_allowed_keys_${alice.userId}': '["$resident"]',
      });
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          currentUserProvider.overrideWithValue(alice),
        ],
      );
      addTearDown(c.dispose);

      final book = c.read(ringConsentByChannelProvider);

      expect(book.isEmpty, isTrue);
      expect(
        c.read(ringConsentByChannelProvider.notifier).consentIn(chan).keys,
        isEmpty,
      );
    });
  });

  group('the consent types freeze their input — BOTH of them', () {
    // A CLASS PIN, NOT TWO INSTANCE PINS, and the grouping is the point.
    //
    // Carnot flagged the leak on `RingConsent.inChannel` in round 2. I froze that
    // one and did not sweep the class — so `RingConsentBook`, created in the very
    // commit that applied the fix, shipped with the identical defect and Carnot
    // found it again in round 3 (HIGH). One instance patched, the class left open,
    // and the second instance authored by the first instance's fix.
    //
    // The diff holds exactly two collection-carrying types; both are asserted
    // here, together, so a third one is added under a FAILING test rather than a
    // green one.
    test(
      'RingConsent.inChannel cannot be mutated through the set it was given',
      () async {
        final live = <String>{resident};
        final consent = RingConsent.inChannel(channelId: chan, keys: live);

        live.add('z6MkSomeOtherKeyEntirely');

        expect(consent.keys, {
          resident,
        }, reason: 'the authority must not follow');
        expect(() => consent.keys.add(resident), throwsUnsupportedError);
      },
    );

    test(
      'RingConsentBook cannot be mutated through the map it was given',
      () async {
        final live = <String, Set<String>>{
          chan: {resident},
        };
        final book = RingConsentBook(live);

        // Both levels: a new room, and a new key in an existing room.
        live['dm:aaa:ccc'] = {resident};
        live[chan]!.add('z6MkSomeOtherKeyEntirely');

        expect(book.channels, [chan], reason: 'a room added after the fact');
        expect(book.consentIn(chan).keys, {
          resident,
        }, reason: 'a key added after the fact — this is who may wake you');
        expect(book.consentIn('dm:aaa:ccc').keys, isEmpty);
      },
    );
  });
}
