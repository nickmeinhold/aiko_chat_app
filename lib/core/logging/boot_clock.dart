/// When this process entered `main()`.
///
/// A VoIP wake is a race the app usually loses silently: the island signs an
/// invitation, APNs delivers it, iOS bootstraps the app from dead, and only
/// once the websocket is up can the ring gate judge the invitation — which is
/// measured by [kCallInviteFreshness] against the signing time. Every second of
/// that journey is charged to the INVITATION, so a slow wake reads as a stale
/// call.
///
/// Measured 2026-09-20 on one handset, two wakes, same build and same island:
///
///     02:24  push → first REST call   1.4s   → admitted, ageMs=4913
///     03:34  push → first REST call   9.6s   → REFUSED, ageMs=12725
///
/// Nothing in the app's own startup explains a 7x spread — the two REST fetches
/// are already `Future.wait`-ed, and Firebase init is a no-op on Apple
/// platforms — so the time is going somewhere no log could see: engine boot,
/// plugin registration, keychain, radio wake, or OS throttling of a background
/// launch. Those need different fixes and were indistinguishable.
///
/// This is deliberately a plain top-level field rather than a provider: it has
/// to be written on the first line of `main()`, before a [ProviderScope]
/// exists. Reading it later costs nothing and tells the boot telemetry how long
/// the app took to get to its own first instruction.
library;

/// Set by `main()` as its first statement. Null only in a test that never ran
/// `main()` — which is every widget test, so readers must handle it.
DateTime? appMainEnteredAt;
