# TEMPER — group-E2EE key management (round 1)

> Movement 4 (Temper) artifact. Real cross-family adversarial strike on CRUCIBLE + RESEARCH + DESIGN, 2026-07-14. Cast: Carnot (Codex/GPT), Kelvin (Gemini), Tesla (Grok). Maxwell (Claude) is the author-instance and does NOT grade its own homework — the three cross-family verdicts are the temper.

## Verdicts

| Adversary | Family | Verdict |
|---|---|---|
| Carnot | Codex/GPT | **DISSOLVED** |
| Kelvin | Gemini | **DISSOLVED** |
| Tesla | Grok | **SURVIVES_WITH_CHANGES** (change-list as deep as a dissolve) |

**Consensus: do NOT pour this cast as-is.** The *ore* survives (all three agree group-E2EE for aiko is real and worth building, and NOT blocked on #27 for a device-leaf MVP). The *casting* — sender-keys-first + roster-hash beacon + clean-room-Double-Ratchet-as-a-build-step — is refuted. This is a **return to Cast**, not a candidate invalidation.

## Unanimous fatal findings (all three families)

1. **Clean-room Double Ratchet is irresponsible, not a chore** (refutes claim #4). "Designing your own parachute" (Kelvin). External KATs catch codec drift, NOT state-machine bugs / replay windows / skipped-key DoS / PCS failures / backup-restore chain reuse (Carnot, Tesla). It's a multi-month expert+audit project, not DESIGN §4 step 2. "Avoid GPL" is a business constraint laundered into a security claim; the honest trade is *license-cleaner, correctness-dirtier*.
2. **The fork-detection beacon is security theater** (refutes claim #3). A partitioning island partitions the *beacon* too — each subgroup sees a self-consistent roster-hash. Non-equivocation needs an **out-of-band / gossip / transparency / federation channel** the design lacks. The design still secretly trusts the island for consistency while *claiming* it's untrusted.
3. **Wrong option-frame** (Carnot + Tesla explicit; Kelvin as missing tradeoff). The live v1 axis is NOT "MLS vs sender-keys" — it's **per-recipient pairwise fanout vs broadcast optimization**. At aiko's small/offline N, pairwise fanout is simpler, gives per-recipient FS/PCS, makes removal "stop encrypting to that device" (not O(N²) rotation), and deletes Layer 2 + most SKDM ordering surface. Sender-keys is a *scale optimization to add later*, not the foundation.
4. **Sender-keys degrades security for human-only groups** (refutes claim #2). Justifying weak FS / absent-automatic-PCS by the AI-plaintext floor "sacrifices the security of the many for the limitations of the few" (Kelvin). Human-only groups get materially worse security for no reason. **The floor is not a foundation.**
5. **#27 is deferred in the type system, not in remove-security** (refutes/reframes claim #1). `GroupMember = {memberId, devices}` defers the *send/receive wire*, but NOT: (a) **remove-completeness** — a forgotten/unlinked device is a permanent ghost decryptor, so "remove Alice" is a crypto lie (Tesla, Carnot); (b) **same-person history-sync to a new device** — needs an explicit cross-device key handoff that is crypto-shaped, not roster policy (Kelvin, Carnot).
6. **"Rotate on first send" is a silent residual-access window** (Carnot, Tesla). Until each remaining sender rotates, a removed member still holds live chain keys. In a quiet channel, "Alice removed" doesn't take effect for human traffic. **Removal must be force-rekey, not lazy first-send.**
7. **MLS-later is dual-stack purgatory, not a clean migration** (refutes claim #5). Pinned sender-key wire + sealed history becomes a permanent parallel decrypt path; MLS won't transmute it. Fine if named "forever dual decrypt," dishonest as "clean endgame cutover."
8. **Media keys are durable capability tokens** (scars claim #6 — the only claim that "survives with a scar"). Every retained message carries a live media key forever; message-store compromise → all media ever exchanged. Not a dissolve, but retention/deletion/backup/new-device-sync/removed-member semantics must be specified.
9. **AI-member as a silent peer leaf is the wrong coupling** (Tesla, sharp). A cloud AI holds every sender's chain key forever by membership and is a standing exfil target of the whole sender-key table; rotation is "incense" against a continuously-compromised host. Adding an AI silently reclassifies the *whole group's* plaintext floor → needs a **multi-party consent gate on AI-add** and a treatment of the AI as an explicit **decrypt-proxy role**, not a silent Signal peer.
10. **Undrawn prekey/X3DH spine** (Tesla). Prekey upload/rotation/replenishment/exhaustion + identity-misbinding (no AS, #1760 open) are first-class attacks on an untrusted island, and re-trust the island for key-material availability. Almost entirely undrawn in §3.3.

## The re-cast direction (what a v2 folds in)

- **Pairwise fanout first.** Per-recipient sealed messages; removal = stop encrypting to the removed device(s); per-recipient FS/PCS from a real ratchet. Defer sender-keys to a *named, evidence-triggered* optimization (real N or battery data), not the foundation.
- **Do NOT hand-roll the ratchet as a build step.** Resolve the crypto-build posture explicitly (see the two escalated decisions below) BEFORE pouring v2.
- **Be honest about non-equivocation.** The island IS trusted for consistency until federation (#1760) gives a second path. Drop the beacon-as-security-boundary; either name the residual trust or scope fork-detection to the federation layer. Don't build a detector that can't fire.
- **Remove = force-rekey**, not lazy first-send.
- **AI-member = consent-gated decrypt-proxy role**, with a multi-party consent gate on AI-add and honest badge copy.
- **#27 partial defer:** wire is device-granular (keep), but remove-completeness (device census) and same-person history-sync are crypto-shaped and must be designed, not deferred.
- **Media:** specify key retention/deletion/backup/new-device/removed-member lifecycle.

## Two decisions escalated to Nick BEFORE re-cast (they change what v2 IS)

1. **Crypto-build risk posture** (Nick owns risk tolerance; Maxwell owns the technical estimate). The single biggest finding. Options: (a) hunt a **non-copyleft vetted** ratchet/E2EE library (MIT/BSD/Apache) and adopt it; (b) accept a **hand-rolled + external-audit** obligation (multi-month, expert, priced); (c) **reduce scope** so there's minimal novel crypto (e.g. lean hardest on the existing `cryptography` package's vetted primitives + the smallest possible protocol surface). v2's shape depends entirely on this.
2. **Group-size-cap acceptability** (product call). Pairwise fanout is O(N)-send; is a bounded group size acceptable for v1 in exchange for the dramatically simpler + stronger-per-recipient scheme?

## Status

Round 1 of ≤3 recast rounds consumed. **Paused at the consent boundary** — v2 cannot be honestly poured until decisions (1) and (2) are made, because re-casting around unpinned Nick-owned variables is casting around a hole. Not a failure: the temper did exactly its job — it struck down a design the excited author would otherwise have carried to a plan.
