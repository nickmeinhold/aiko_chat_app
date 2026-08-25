import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../data/ring_allowlist_store.dart';

final ringAllowlistStoreProvider = Provider<RingAllowlistStore>(
  (ref) => RingAllowlistStore(ref.watch(sharedPreferencesProvider)),
);

/// The consented ringer keys, as `admitRing` wants them.
///
/// Mirrors [blockedUserIdsProvider]'s shape deliberately: the ring's trust
/// decision reads plain sets, so every input to it can be substituted in a test
/// without a store, a socket or a clock.
///
/// NEVER THROWS, and the reason is the doctrine this whole feature is built on:
/// REACH IS NEVER A GATE. Reading consent is a preferences lookup, and wiring it
/// naively made the ring path hard-depend on `sharedPreferencesProvider` — so a
/// store that is unavailable, still loading, or in an error state stopped
/// EVERY ring, including a call from a person, for a feature the user may never
/// have used. That is the wrong failure by a wide margin, and it was not
/// theoretical: it broke twelve existing ring tests the moment the wire landed.
///
/// So an unreadable allowlist reads as NO CONSENT RECORDED, which is exactly the
/// prior behaviour — humans ring, nobody else does. The widening fails CLOSED
/// while the underlying capability fails OPEN, which is the correct direction
/// for each half.
final ringAllowedKeysProvider = Provider<Set<String>>((ref) {
  try {
    return ref.watch(ringAllowlistStoreProvider).read();
  } catch (_) {
    return const {};
  }
});
