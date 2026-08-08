# TEMPER — cross-family design cage-match ledger

**Struck:** 2026-08-07 · **Panel:** Maxwell (Claude), Carnot (GPT/Codex), Tesla (Grok), Kelvin (Gemini) seated; **Wu (Kimi K3) dark** — 403 billing-cycle quota, no same-account fallback. Gate valid: Maxwell + 3 adversaries (≥2 required).

**Verdict tally:** REQUEST_CHANGES ×3 (Maxwell, Carnot, Tesla) · APPROVE ×1 (Kelvin) · dark ×1 (Wu). **No consensus APPROVE → recast required.** Kelvin's lone APPROVE raises the *same* top findings as the three RC votes but files them as "named tradeoffs to communicate" rather than blocking fold-backs — so the panel is 4-way agreed on the findings, split only on the blocking bar.

## The headline: the ore is REAL but PARTIAL — negative constraints survive, positive claim does not

Unanimous (all four seated, incl. Kelvin's approve):

- **APPROVED — the negative constraints (buildable now):** (a) no island in the durable identity string [Matrix lesson]; (b) passkey out of the identity-key seat [WebAuthn reality]; (c) data/channel ULID sequencer stays home-anchored as a separate axis; (d) key-anchored ≠ single-key [separate governing vs signing keys]. §7b's code proof (self-verifying envelope ⇒ message relay needs no home vouch) is **CONFIRMED** by Tesla + Carnot.
- **REJECTED — the positive claim:** "KEY alone is the binding authority for handle + reputation." **Self-certifying relocates authority, it does not dissolve it.** Handles need a name-allocation authority; reputation needs stored graph data (home/directory); recovery needs an authority. "No island's death can revoke you" is true for a bare key, **false** for the handle + history + reputation users actually care about.

## Consensus findings (≥2 families) → disposition

| # | Finding | Families | Disposition |
|---|---|---|---|
| C1 | **Handle uniqueness needs an authority key-anchoring can't provide.** `@nick` = one person is a global invariant; pure key gives unique *keys*, colliding *handles* (Nostr NIP-05: "follow keys, not names"). | **ALL 4** | **FOLD-BACK.** ADR must pick handle-uniqueness scope: per-island (`@nick@island`, cheap) / global directory (new infra) / follow-keys-not-handles UI. State: *key-anchored identity ≠ key-allocated handles.* |
| C2 | **Wrong option-frame: key-vs-home smuggles ~5 decisions into one.** Real axes: durable identifier · authorship · name-allocation authority · login-RP · data-order · recovery. | Carnot, Tesla | **FOLD-BACK.** Rewrite the decision-under-strike as multi-axis; key-vs-home is *one sub-choice* (durable identifier). |
| C3 | **Increment 1 must NOT equate `identity_id` to the live signing pubkey, nor weld origin into the durable id.** Additive nullable fields are fine; keying User PK / mentions / ACLs / Carried-Record attribution off today's pubkey is foreclosing (did:plc DID ≠ raw key ⇒ migration = new person). | Maxwell, Carnot, Tesla, (Kelvin: non-foreclosing *iff* this holds) | **FOLD-BACK (concrete).** `IdentityDoc` = versioned binding record from day 1: opaque `id`, `verificationMethod[]` (signing keys, a set), `rotationKeys[]` (empty v1), `alsoKnownAs[]`, optional `origin` as *locator only*. Origin carried on DATA objects only, never the identity string. |
| C4 | **"Passkey recovery factor" is a false identity-recovery story.** Synced passkey recovers the gateway *session*; device-local sovereign key is lost ⇒ new cryptographic person. **login continuity ≠ identity continuity.** | Carnot, Tesla, Kelvin | **FOLD-BACK.** Rename to "login continuity factor." ADR states passkey does NOT recover the identity key until Inc 3's envelope. |
| C5 | **Federation demand is an unverified premise the whole design rests on** — and the sharper question is *which* demand. Falsify not just "is federation real?" but "does it need gateway-independent BINDING, or only cross-island login + linked profiles?" If bilateral, the simpler dissolve beats the KEY machinery. | **ALL 4** | **NAMED TRADEOFF → NICK'S CALL** (see fork below). Only Nick can resolve the premise; ADR must record it as a *strategic bet with a threshold*, not proven value. |
| C6 | **Split-brain identity state / no doc versioning.** Before a PLC-log/sigchain exists, two gateways see different self-signed IdentityDoc versions for one key; self-signature validates both → equivocation. | Carnot, Tesla | **FOLD-BACK.** Doc versioning in Inc 1: monotonic seq or hash-linked `prev` pointer + created/valid timestamps + canonicalization + newer-wins/log-required rule. |
| C7 | **Carried Record doesn't survive on key alone.** If data/home stays home-anchored and home dies, history + reputation die even though the key verifies. Reputation is stored graph data, not self-certifiable by the subject. | Maxwell, Tesla | **NAMED TRADEOFF** (owner: Carried-Record / Inc 3). Migration = re-point + repo transfer (Bluesky-shaped). Do not sell Inc 1–2 as reputation portability. Rotation also needs a key-history chain or it orphans prior reputation. |
| C8 | **n-device split confirmed** (§7b) — Inc 1 must NOT "fix" it by equating account to one device key; end state is per-device keys under one identity (Keybase). | §7b, Carnot, Tesla, Kelvin | **CONFIRMED** — fold into C3's schema (signing keys are a *set*). |

## Unique high-value catches

- **Tesla #4 — WebAuthn RP-ID is an unstated login-homing weld.** Passkeys bind to an RP domain (`kDefaultGatewayBaseUrl`); "one passkey login across islands" is NOT free — needs related-origins / shared-RP / re-registration. A *third* homing axis (identity-key / data-home / **auth-RP**) nobody else surfaced. → FOLD-BACK: document login-homing; at bilateral scale shared-RP may beat did:plc.
- **Carnot #5 — self-signed binding can't prove CURRENT handle ownership** (replay/stale/duplicate claims valid forever from the key's view). → handle-claim freshness: issuer, scope, expiry, revocation, conflict behavior.
- **Tesla #8 / Carnot — three parallel identity objects after Inc 1** (A passkey→account, B device signing key, C IdentityDoc) bound by nothing. → Inc 1 acceptance criteria need a single domain-model diagram; no free-floating IdentityDoc nothing points at.

## Recast direction (the tempered design)

**Candidate NOT slag.** Recast, not abandon. The tempered shape:
1. Reframe ADR-0004 around the **multi-axis** decision (C2), approving the **negative constraints** explicitly and NOT the positive "key = binding authority" claim.
2. Inc 1 = **PLC-shaped versioned `IdentityDoc` schema** (C3+C6+C8), opaque identifier, origin as locator only, doc versioning from day 1 — the genuinely non-foreclosing seam.
3. Name-allocation authority (C1), recovery authority + Carried-Record survival (C4+C7), and login-RP (Tesla #4) each get an explicit axis + a named tradeoff, most deferred to Inc 2/3 but *named now*.
4. **The scope fork (C5) is Nick's** — see below. It decides whether ADR-0004 is "the full key-anchored binding project" or "identifier hygiene now, honest multi-home linking, PLC-directory only when a 3rd untrusted island appears."

**Blade (plan mode → ADR-0004) is deliberately NOT poured yet:** the recast's central axis is an empirical premise only Nick can resolve. Pouring the ADR before that would bake an unverified answer into the canonical record — the exact failure the crucible's premise-discipline exists to prevent.
