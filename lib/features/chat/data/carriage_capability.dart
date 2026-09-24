import '../domain/gateway_capabilities.dart';

/// Transitional allowlist of hosts known to carry the sovereign `origin`
/// envelope. A FALLBACK ONLY: it is consulted when `GET /capabilities` gives no
/// explicit answer (404, unreachable, thrown, or a malformed 200). An explicit
/// bool from the endpoint is authoritative and this list is not consulted at
/// all — see [CarriageCapability] for the full resolution order.
///
/// ## ITS EXIT CONDITION IS ALREADY MET — this should be DELETED, not extended
///
/// **Measured 2026-09-24:**
///
///     GET https://chat.enspyr.co/capabilities       -> 200 {"carriage":{"origin":true}}
///     GET https://chat.imagineering.cc/capabilities  -> 200 {"carriage":{"origin":true}}
///
/// Both islands answer explicitly, so on both of them this constant is dead
/// code on the live path. Its own stated exit condition — "once `/capabilities`
/// is live on every island this list becomes dead code and should be deleted" —
/// is satisfied. Deleting it is claude-tasks#4753 and is a real change rather
/// than a tidy-up, because of the seed note below.
///
/// **THE "IT STILL 404s" LINE WAS TRUE WHEN IT WAS WRITTEN.** An earlier
/// revision of this correction called it false, which over-corrected in the
/// opposite direction and is worth spelling out because a fixed record gets
/// trusted harder than a fresh one. Dated by the island tab from its own tag
/// trees rather than its log (`git ls-tree -r v0.13.1` → no `capabilities.py`;
/// `v0.14.0` → present):
///
///   * `/capabilities` shipped in island `v0.14.0`, tagged **2026-09-16 15:51
///     +07** and deployed to both islands the same day. Before that the path
///     404'd everywhere, because the route did not exist.
///   * PR #202 was opened **2026-09-16 06:16 UTC**, about two and a half hours
///     BEFORE the endpoint existed. Its claim was accurate at authoring time
///     and went stale within hours.
///
/// So there were genuinely two eras, and both matter when reading anything
/// written about this file:
///
///   | until 2026-09-16 | the allowlist decided, alone — `/capabilities` 404'd |
///   | 2026-09-16 on    | `/capabilities` decides, authoritatively             |
///
/// ## THE SEVEN-WEEK OUTAGE THIS FILE DESCRIBED DOES NOT REPRODUCE
///
/// PR #202 added `chat.enspyr.co` here and recorded that the omission had left
/// every message to that island unsigned since 2026-08-10, so that "NO CALL TO
/// THAT ISLAND COULD BE ANSWERED BY ANYONE" for seven weeks.
///
/// **THE WINDOW WAS REAL; THE MECHANISM WAS NOT.** A period did exist
/// (2026-08-10 → 2026-09-16) in which this allowlist alone decided carriage for
/// enspyr, and enspyr was not on it. That is the half #202 got right and an
/// earlier revision of this correction wrongly denied. But the app signed to
/// enspyr **throughout that window anyway**, which is what refutes the causal
/// story — and it refutes it independently of when the endpoint shipped.
///
/// Measured inside the window, user `nick`, every row `origin` NOT NULL:
///
///     2026-08-19  aiko:call/1 · 📞 started a call
///     2026-08-23  aiko:call/1 · 📞 started a call
///     2026-08-28  aiko:call/1 · 📞 started a call
///     2026-09-09  hello Robin 😄
///     2026-09-09  aiko:call/1 · 📞 started a call
///
/// `CALL_INVITE_BODY` is sent by nothing but the app. So during the exact period
/// when this list was the only decider and enspyr was absent from it, app
/// messages to enspyr carried origin envelopes. Whatever was gating the emit, it
/// was not this constant — **WHICH IS STILL UNEXPLAINED AND IS THE LIVE QUESTION
/// HERE.** Do not read this block as "the gate works"; read it as "the gate did
/// not do what its own docstring says it does, and nobody has found out why."
///
/// **Four further readings of the live island, none supporting the claim:**
///
///  1. **Signed ratio by month on enspyr:** 2026-08 113/189, 2026-09 **57/57**.
///     Not "nothing since 2026-08-10" — everything since.
///  2. **Every unsigned message predates the window and is not the app.** All 76
///     are 2026-08-03..2026-08-10, `sender_kind=unknown`, label `` or
///     `@@armbot`. The last unsigned message on this island is 2026-08-10.
///  3. **App-originated call invites, signed, inside the claimed outage.**
///     2026-09-20, user `nicka`, `sender_kind=human`, bodies
///     `aiko:call/1 · 📞 started a call` — the `CALL_INVITE_BODY` the app sends
///     — all carrying origin. Those are the calls the claim says could not be
///     answered.
///  4. **The cited measurement does not reproduce.** #202 recorded `nick` as
///     "signed 10/22, last signed 2026-08-10". Live: `nick` was **22/22, last
///     signed 2026-09-09**, and is 24/24 after the 2026-09-24 test call below.
///     Messages are immutable, so these cannot both describe this island. The
///     obvious explanation — that the measurement was taken against the other
///     island — was checked and does not hold either: imagineering has no
///     `nick` with 22 messages.
///
/// **Confirmed live 2026-09-24** (and note this proves less than it appears —
/// see the caveat below it): a call placed from the handset produced
/// `2026-09-24 16:28:57 | nick | human | SIGNED=1 | aiko:call/1 · 📞 started a call`
/// and its matching end, on enspyr. Signing to this island works, and
/// `admitRing` would accept the invitation rather than refusing it as
/// `unverifiedOrigin`.
///
/// Read that result precisely, because it is easy to over-claim in the other
/// direction: it shows signing WORKS, not that the entry FIXED it. With
/// `/capabilities` answering explicitly, the allowlist is bypassed on that path
/// entirely — the signature came from the endpoint.
///
/// **What the enspyr entry is genuinely worth**, and the only reason it is kept
/// rather than reverted: [CarriageCapability]'s constructor seeds
/// `_carriesOrigin` from this list BEFORE the first `refresh()` returns. A send
/// that beats the refresh on a host absent from here goes unsigned. That window
/// is narrow and real; it is not seven weeks, and it is the thing to reason
/// about when deleting this constant, because deleting it makes EVERY host seed
/// `false` until its first refresh lands.
///
/// **The one sentence from #202 that was right, and is now more right:** a
/// hand-curated allowlist of production hosts is the defect, not the entry that
/// was missing from it. Until this is deleted, adding a host here is a
/// deploy-time promise nothing verifies, and forgetting is silent.
///
/// The correction is recorded rather than the old text deleted, because a claim
/// this specific gets CITED. It was already load-bearing in a merged commit
/// message and in two ticket comments.
const kKnownCarriageHosts = {'chat.imagineering.cc', 'chat.enspyr.co'};

/// Holds the "does the CURRENT gateway carry `origin`?" decision that the
/// transport's emit gate reads synchronously on every send.
///
/// **Two inputs, three outcomes.** The endpoint is authoritative when it gives
/// an explicit answer; the allowlist is the fallback for every "unknown":
///  1. `GET /capabilities` returns an explicit bool (`GatewayCapabilities.parse`
///     → non-null) → use it (it can turn a known host OFF, or a stranger ON).
///  2. Anything else — 404, unreachable, a thrown error, or a stub/partial/
///     malformed 200 (parse → null) → **fall back to the allowlist seed for
///     this host.** Unknown always resolves to the seed, never to a sticky prior
///     value.
///
/// The allowlist is a live fallback, not merely a construction-time seed
/// (cage-match Tesla + Carnot). That matters two ways: an allowlisted host that
/// briefly emits an explicit `false` (canary/misdeploy) and then goes back to
/// 404 re-resolves to ON — no permanent sovereignty-off; and a stranger that
/// proved carriage and then loses its endpoint re-resolves to OFF — fail-closed,
/// never a lingering emit that an island would `bad_origin`-drop. A malformed
/// 200 is treated as unknown (not an authoritative false) on purpose: reading it
/// as false would flip an allowlisted, already-carrying host off during the
/// island's `/capabilities` rollout — the exact no-regression break this design
/// exists to prevent. Fail-closed lives in the DECODE (only `== true` enables)
/// and in the stranger SEED (unknown → false for a non-allowlisted host).
class CarriageCapability {
  final Future<GatewayCapabilities?> Function() _fetch;
  final void Function(String message)? _log;

  /// The allowlist answer for this host — the value every "unknown" resolves to.
  final bool _seed;
  bool _carriesOrigin;

  CarriageCapability({
    required String host,
    required Future<GatewayCapabilities?> Function() fetch,
    Set<String> knownCarriageHosts = kKnownCarriageHosts,
    void Function(String message)? log,
  }) : _fetch = fetch,
       _log = log,
       // Normalize BOTH sides of the match (cage-match Carnot): the input host
       // and every allowlist entry, so a case/trailing-dot variant on either
       // side can't silently seed false against the one island that 404s.
       _seed = knownCarriageHosts
           .map(_normalizeHost)
           .contains(_normalizeHost(host)),
       _carriesOrigin = knownCarriageHosts
           .map(_normalizeHost)
           .contains(_normalizeHost(host));

  static String _normalizeHost(String host) {
    var h = host.trim().toLowerCase();
    while (h.endsWith('.')) {
      h = h.substring(0, h.length - 1); // strip any trailing FQDN root dot(s)
    }
    return h;
  }

  /// The synchronous gate the transport reads per-send.
  bool get carriesOrigin => _carriesOrigin;

  /// Re-resolve from the live endpoint; called on every (re)connect.
  ///
  /// An EXPLICIT bool from the endpoint (`parse` → non-null) is authoritative.
  /// Every "unknown" answer — 404, unreachable, a thrown error, or a
  /// stub/partial/malformed 200 (parse → null) — re-resolves to the allowlist
  /// [_seed], so the allowlist is a live fallback rather than a one-shot seed
  /// (cage-match Tesla + Carnot: no sticky OFF after a transient explicit false,
  /// no sticky ON for a stranger whose endpoint went dark).
  Future<void> refresh() async {
    try {
      final caps = await _fetch();
      _carriesOrigin = caps?.carriesOrigin ?? _seed;
      _log?.call(
        caps != null
            ? 'carriage=${caps.carriesOrigin} (endpoint authoritative)'
            : 'carriage=$_seed (unknown → allowlist seed)',
      );
    } catch (e) {
      // Belt-and-braces: the production fetch (GatewayRestApi.getCapabilities)
      // catches all transport errors and returns null, so a transient DNS/
      // timeout arrives at the null branch above, NOT here — this catch only
      // fires for an injected/future fetch that itself throws. Either way the
      // resolution is the same: unknown → seed. That is deliberately fail-closed
      // over keep-prior, because if the gateway has silently stopped carrying,
      // keeping emit ON causes a `bad_origin` DROP (data loss), which is strictly
      // worse than the unsigned-but-delivered message a re-seed-to-false yields.
      _carriesOrigin = _seed;
      _log?.call('carriage refresh failed, resolved to seed=$_seed: $e');
    }
  }
}
