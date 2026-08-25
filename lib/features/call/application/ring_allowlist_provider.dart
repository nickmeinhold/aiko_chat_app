import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../chat/application/chat_providers.dart';
import '../data/ring_allowlist_store.dart';

/// The store, scoped to whoever is signed in. Rebuilds on a session change, so
/// a sign-out cannot leave the previous user's consent readable.
final ringAllowlistStoreProvider = Provider<RingAllowlistStore>(
  (ref) => RingAllowlistStore(
    ref.watch(sharedPreferencesProvider),
    ref.watch(currentUserProvider)?.userId,
  ),
);

/// The consented ringer keys, as `admitRing` and `admitCallEnd` want them.
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
class RingAllowlist extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    try {
      return ref.watch(ringAllowlistStoreProvider).read();
    } catch (_) {
      return const {};
    }
  }

  /// Consent to be rung by [multikey]; republishes so a live ring path sees it
  /// immediately. Returns false if the key is malformed or the write failed —
  /// and on failure the state is left ALONE rather than optimistically updated,
  /// so what callers observe is what actually persisted.
  Future<bool> allow(String multikey) async {
    final store = ref.read(ringAllowlistStoreProvider);
    if (!await store.allow(multikey)) return false;
    state = store.read();
    return true;
  }

  /// Withdraw consent, and republish. Same failure handling as [allow].
  Future<bool> revoke(String multikey) async {
    final store = ref.read(ringAllowlistStoreProvider);
    if (!await store.revoke(multikey)) return false;
    state = store.read();
    return true;
  }
}

final ringAllowedKeysProvider =
    NotifierProvider<RingAllowlist, Set<String>>(RingAllowlist.new);
