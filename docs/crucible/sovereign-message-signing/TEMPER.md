# TEMPER — the strike record (Movement 4)

> Cross-family design cage-match over CRUCIBLE.md + RESEARCH.md + DESIGN.md (v1), 2026-07-08. Verdicts, findings, disposition, and the reforge decision. The honesty-restorer of the /crucible forge — this is where the excited author's casting met four cold strikes.

## Verdicts (v1 casting)

| Reviewer | Family | Verdict | C1 steelman |
|---|---|---|---|
| Maxwell | Claude | (author — did not self-grade) | — |
| Kelvin | Gemini | **REFORGE** | C1 DISSOLVES as stated; "ore is good, poured at the wrong time" |
| Carnot | GPT/Codex | **INVALIDATE** | C1 does not survive as stated; a **narrower C1 survives** |
| Tesla | Grok | **REFORGE** | sign-at-birth is the real invention; wire path is verifier-deaf |

**Consensus:** the v1 central bet — *"sign every production message now, gateway-opaque, as provable historical origin"* — **does not survive.** But the ore is not slag: all three praise the crypto core + sign-at-birth spine. The candidate is **REFORGED to the narrower scope all three converged on**, not abandoned. This is Temper Round 1 of ≤3.

## Why v1's C1 fell (the convergent core)

Three reviewers, three angles, one structural verdict: **the app conflated "sign a message" (app-local, easy) with "provable federated origin" (a system property needing the gateway + a trust root).** v1 scoped the former while claiming the latter.

- **Verifier deafness (Tesla F1 — the killer).** signingBytes binds `client_msg_id` + `sent_at_ms`, but `MessageView` (Design 01) exposes only `msg_id` + server `created_at` — no `client_msg_id` by construction. The `origin` envelope doesn't echo the two fields a verifier must feed into `signingBytes()`. A future verifier literally cannot reconstruct the signed bytes. Every federation path in CRUCIBLE (courier, blind relay) dies here.
- **Gateway carriage is the boundary, not a side-note (all three).** If the gateway strips `origin`, signatures are "locally signed, globally mute." C5 as "named-open, non-blocking" undercounts: federation value is *gated*, not parallel.
- **Unbound keys aren't provable origin (Carnot, Kelvin).** Without contemporaneous, retained K→account binding, signed history proves only "some anonymous key said this" — arguably weaker than the current JWT assertion. Trust-root binding was deferred, so the historical-origin value evaporates.
- **Matrix urgency laundered (Tesla F4, Kelvin).** MSC4080 pain = server-graph-dependent signing (`prev_events`). Aiko's send is locally complete, so the retrofit here is drift columns + sign hook + spec — real, not catastrophic. The *canonical byte contract* is the genuinely catastrophic-to-get-wrong-later part, not the production wire bytes.

## Findings ledger (disposition)

| # | Finding | Source | Disposition in v2 |
|---|---|---|---|
| F1 | Verifier deafness — `client_msg_id`+`signed_at` not echoed to any verifier | Tesla | **FOLD** — SIGNING-SPEC requires them on `origin` + gateway echo + MessageView; production wire gated on carriage |
| F2 | Ack timestamp betrayal — ack replaces `createdAt` with server time; verifier using it rejects valid sigs | Tesla | **FOLD** — hard invariant: verify reads durable `signed_at_ms`, never post-ack `createdAt` |
| F3 | Downgrade hole — `alg` in envelope, not in signed bytes | Tesla, Carnot | **FOLD** — bind alg inside signingBytes (domain tag → `aikochat:msg:v1:EdDSA`) |
| F4 | Matrix analog laundered — urgency overstated | Tesla, Kelvin | **FOLD** — reframe "now" = canonical contract + key discipline, drop "catastrophic/historical-origin" overclaim |
| F5 | Gateway carriage is prerequisite, not follow-up | Kelvin, Carnot, Tesla | **FOLD** — production-signing step (wire emission) GATED on gateway carriage + key-registration contract |
| F6 | Debug-only self-verify → can ship broken sigs for months | Tesla | **FOLD** — production round-trip verify on every sign() + golden-vector CI gate |
| F7 | Inbound origin not persisted — outbound-only = "sender diary" | Tesla | **FOLD** — inbound `origin` parse+persist (nullable) in the same pass, or narrow to contract-only |
| F8 | Multikey string signed → C4 flip invalidates all sigs; premature coupling | Tesla, Carnot | **FOLD** — sign the RAW 32-byte pubkey; Multikey only on the wire |
| F9 | No rotation/revocation → first compromised phone = permanent author | Carnot | **FOLD** — key-version + state hooks reserved in envelope; lifecycle deferred but distinguishable |
| F10 | Wrong option-frame: "sign all now vs defer all" omits the smaller primitive | Carnot | **FOLD** — v2 IS the smaller primitive: contract + keygen + golden vectors + carriage contract |
| F11 | Replay/context undercounted (no epoch/sequence/window) | Carnot | **NAMED-OPEN** — reserve signed context fields; exact-once acceptance policy is the verifier's (federation) call |
| T1 | Stable per-device pubkey linkability — owned by product/security, not "like token store" | all three | **NAMED TRADEOFF** — owner: product + security; cost: durable pseudonymous graph; mitigation: no "verified identity" UI until trust-root; consider per-community keys |
| T2 | Software Ed25519 key-secrecy boundary | Kelvin, Carnot | **NAMED TRADEOFF** — owner: security; accepted (SE/StrongBox are P-256-only); revisit if device-compromise enters threat model |
| T3 | Multikey/did:key encoding on the wire | Carnot, Tesla | **NAMED-OPEN (C4)** — plausible, not fatal; raw-key extraction rule in SIGNING-SPEC decouples it |
| T4 | Dual-authority UX (JWT sender vs naked pubkey) | Tesla | **NAMED TRADEOFF** — owner: federation/#1760; no "verified sender" UI until binding lands |
| T5 | Server edit/tombstone vs signed body | Tesla | **NAMED-OPEN** — owner: Phase 2 edit/delete; future edit re-signs or marks `origin` superseded |

## The surviving candidate (v2 scope)

Ship the **hard-to-change contract + key discipline**, made verifier-complete and carriage-gated:
1. **Device keygen + secure key store** (Ed25519, `cryptography`, `flutter_secure_storage`) — unilateral, foundational.
2. **`SIGNING-SPEC.md` + golden vectors** — the canonical byte format with the COMPLETE field set (alg-in-bytes, RAW pubkey in bytes, verifier-reconstructable `client_msg_id` + `signed_at`). This is the genuinely catastrophic-to-get-wrong-later artifact, and it's a doc + pure functions, not dead production bytes.
3. **Sender sign + local persist + production round-trip self-verify** — proves the primitive end-to-end on-device; stores durable verifiable local history. Claimed value: "the app signs and self-verifies," NOT "federated provable origin."
4. **Gateway carriage + key-registration contract** — a named co-requisite handed to the peer-owned island/gateway team; production wire-emission of `origin` (+ inbound persist) is GATED on its confirmation.

Deferred with reserved hooks: recipient verification, trust-root K→account binding, rotation/revocation lifecycle, cross-device cross-signing, replay-acceptance policy — all federation/#1760.

**This dissolves Carnot's INVALIDATE** (which named exactly this surviving scope) and folds every REFORGE finding. Re-cast into DESIGN.md v2.

## Verdicts (v2 re-forged casting — Temper Round 2, focused)

| Reviewer | R1 | R2 (on v2) |
|---|---|---|
| Carnot (GPT) | INVALIDATE | **SOUND** — "a real reforge, not merely a relabel… moves the hard artifact to the correct thermodynamic boundary." F1/F2/F3/F6/F8 confirmed genuinely folded; F5/F7 no longer hidden. |
| Tesla (Grok) | REFORGE | **SOUND** — "the deaf wire is rewound into a contract that can hear itself." All R1 findings resolved. |

**Survived the fire.** Both hardest hitters (the INVALIDATE author + the killer-catch finder) confirm v2 resolves R1 and the **unilateral core (Steps 1/2/4-local) is safe to build now**, under one **bright line**:

> Build Steps 1/2/4-local ONLY as local cryptographic plumbing + local verifiable history. Do **NOT** emit `origin` on the production wire, do **NOT** show verified-sender/account-origin UI, and do **NOT** later upgrade pre-registration local signatures into account-bound historical origin (Joule: "we can neither create nor destroy force" — v2 cannot create trust-root energy from unregistered past heat).

**Residuals (named-open, do not block the core):** replay/epoch context (domain-tag `v2` migration), key rotation/revocation lifecycle (federation), linkability [T1] (product/security), gateway carriage + contemporaneous K→account registration [OV4] (peer-owned Step-3 gate). Operational note (Tesla): freeze golden-vector field **shape** now; the peer's carriage confirmation is a delay, not a redesign.

→ **Blade** on the surviving unilateral core.
