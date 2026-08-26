import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../chat/application/chat_providers.dart';
import '../data/ring_allowlist_store.dart';
import '../domain/ring_consent.dart';

/// The store, scoped to whoever is signed in. Rebuilds on a session change, so
/// a sign-out cannot leave the previous user's consent readable.
final ringAllowlistStoreProvider = Provider<RingAllowlistStore>(
  (ref) => RingAllowlistStore(
    ref.watch(sharedPreferencesProvider),
    ref.watch(currentUserProvider)?.userId,
  ),
);

/// Every conversation's consent, published as a [RingConsentBook] — a surface
/// with no bare key set on it at all.
///
/// It used to publish `Map<String, Set<String>>`, which made [consentIn] a
/// SUPPORTED path rather than a law: a settings screen watching the raw map could
/// pair room A's label with room B's keys by hand and the gate would admit it.
/// See [RingConsentBook] for why the fix is subtractive rather than a fourth
/// guard (cage-match round 2, Tesla).
///
/// A NOTIFIER, NOT A PLAIN PROVIDER (cage-match, Tesla). The first version was a
/// `Provider` that called `read()` once and then cached forever, while `allow()`
/// and `revoke()` wrote preferences and notified nobody — so a grant was
/// invisible and, worse, a WITHDRAWAL had no effect until the process died.
/// Block lives in a notifier that actually moves; consent has to as well, or
/// "revoke" is a button that lies. Mutating through this notifier is the single
/// door: it writes and republishes in one step, so no caller can do one without
/// the other.
///
/// NEVER THROWS on read, and the reason is the doctrine this feature sits
/// inside: REACH IS NEVER A GATE. Reading consent is a preferences lookup, and
/// wiring it naively made the ring path hard-depend on
/// `sharedPreferencesProvider` — a store that is unavailable or still loading
/// stopped EVERY ring, including from a person, for a feature the user may never
/// have touched. It broke twelve existing ring tests the moment it landed. So an
/// unreadable allowlist reads as NO CONSENT RECORDED — exactly the prior
/// behaviour. The widening fails CLOSED while the ring itself fails OPEN.
class RingAllowlist extends Notifier<RingConsentBook> {
  @override
  RingConsentBook build() {
    try {
      final store = ref.watch(ringAllowlistStoreProvider);
      // Fire-and-forget, and SAFE to be: the global-scope grant is already
      // unreadable by every path above, so its removal is hygiene that must
      // never delay or fail a build the ring path depends on. The no-throw
      // guarantee is enforced inside `dropLegacyGlobalConsent` itself — this
      // `try` only ever sees a SYNCHRONOUS throw, so it could not have caught a
      // rejected Future from here (cage-match round 1).
      //
      // THE CALL BELOW WAS DELETED BY ROUND 1'S OWN FIX (round 2, Carnot HIGH).
      // Rewriting the comment above it replaced the comment AND the statement,
      // leaving `dropLegacyGlobalConsent` with ZERO production callers — tested
      // five times, driven by nothing — while 1091 tests stayed green because
      // every one of them calls it directly. A fix that destroys the behaviour it
      // was fixing is why the provider test now drives the drop THROUGH build().
      store.dropLegacyGlobalConsent();
      return RingConsentBook(store.readAll());
    } catch (_) {
      return const RingConsentBook.empty();
    }
  }

  /// The consent in force in [channelId], as the two gates want it.
  RingConsent consentIn(String channelId) => state.consentIn(channelId);

  /// Consent to be rung by [multikey]; republishes so a live ring path sees it
  /// immediately. Returns false if the key is malformed or the write failed —
  /// and on failure the state is left ALONE rather than optimistically updated,
  /// so what callers observe is what actually persisted.
  Future<bool> allow(String channelId, String multikey) async {
    final store = ref.read(ringAllowlistStoreProvider);
    if (!await store.allow(channelId, multikey)) return false;
    return _publish(store);
  }

  /// Withdraw consent, and republish. Same failure handling as [allow].
  Future<bool> revoke(String channelId, String multikey) async {
    final store = ref.read(ringAllowlistStoreProvider);
    if (!await store.revoke(channelId, multikey)) return false;
    return _publish(store);
  }

  /// Republish, but ONLY if [store] is still the one this session is reading.
  ///
  /// The disk was namespaced per user and the in-memory register was not
  /// (cage-match round 2, Tesla). `allow`/`revoke` capture a store, yield on
  /// SharedPreferences, then publish into whichever identity now occupies this
  /// same notifier — so a grant in flight across a logout-then-login lands
  /// Alice's keys in Bob's live set, and `RingController` reads THAT on the next
  /// invite. Bob is woken for a covenant he never made: the identical
  /// identity-as-mutable-key defect as the device-global prefs key, one layer up,
  /// which is the tell that the first fix was an instance and not the class.
  ///
  /// `build()` has already spoken for the new sleeper by then, so the correct
  /// action is to say nothing rather than to correct it.
  bool _publish(RingAllowlistStore store) {
    if (!identical(ref.read(ringAllowlistStoreProvider), store)) return false;
    state = RingConsentBook(store.readAll());
    return true;
  }
}

/// RENAMED from `ringAllowedKeysProvider` when consent became per-conversation.
/// The old name promised a flat set of keys that may ring, which is precisely
/// the thing that no longer exists — a name that survives a scope change is a
/// name that will be read with the old meaning.
final ringConsentByChannelProvider =
    NotifierProvider<RingAllowlist, RingConsentBook>(RingAllowlist.new);
