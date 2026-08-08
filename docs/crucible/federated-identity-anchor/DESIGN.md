# DESIGN — The identity anchor: key-anchored with a gateway-independent binding

> Crucible phase: CAST. Grounded in `CRUCIBLE.md` (the fork) + `RESEARCH.md` (real-system mechanisms) +
> the code truth below. This is the mold Temper strikes. It ends in `docs/adr/0004-sovereign-identity-federation.md`
> + a scoped, non-foreclosing first increment.

## 1. Problem

The sovereign-identity thesis (*your phone is your self; your reputation travels with you*) rests on one
never-decided fork. Three artifacts answer it three different ways, each leaning more home-anchored
toward the metal (see `CRUCIBLE.md` table). Precisely pinned, the undecided question is **not** whether
the keypair is portable (settled — Design 06 L133) but **who certifies `key → @handle + reputation`:**

- **HOME:** a home gateway vouches (Design 06 **L151**); other gateways trust transitively. Island dies ⇒ binding orphaned, handle unrecoverable. This is the Matrix `@user:server` weld one layer below the portable key, and it is what the **code chose by omission** (single `kDefaultGatewayBaseUrl`, no origin field).
- **KEY:** the binding is self-certifying + gateway-independent (a signed identity record governed by a rotation key, `did:plc`-shaped). Any gateway verifies it; no home need be alive.

## 2. Code truth (measured, not recalled)

| Fact | Location | Consequence |
|---|---|---|
| A **separate** sovereign Ed25519 key already exists | `lib/app/providers.dart:99`, `chat_providers.dart:131` (`sovereignKeyStoreProvider.loadOrCreate()`) | The passkey/identity-key separation the research demands (§4) **already exists** — but the key is used only for message signing, not identity/auth. |
| It's already `did:key`-encodable | `lib/features/chat/domain/origin_envelope.dart:53` (Multikey `0xed01`‖raw-32, multibase base58btc) | The identity-document primitive is **already built**. |
| The key `loadOrCreate`s with no rotation/recovery/binding | same | Silently **Nostr's corner** (RESEARCH §2/§7): lose device → new signer, no recovery, no handle continuity. |
| Auth identity is a wholly separate passkey→gateway path with no origin field | `identity_models.dart`, `config.dart:20` | Identity binding is **home-vouched by omission**; two halves of one object, unconnected. |
| Passkeys are synced (BE=1), outside app control | `passkey_auth_client.dart:60` (thin pass-through) + RESEARCH §4 | Cannot force device-bound; **must not** bind the sovereign key's fate to the passkey. Passkey = login gesture / recovery *factor*, not the identity key. |

## 3. The shape

**Decision (the lean Temper must break): key-anchored, via a gateway-independent binding record — and key-anchored ≠ single-key (RESEARCH §2).** Concretely, separate three layers that Design 06 conflated into "home gateway":

1. **Identity anchor** — the durable "you." A self-certifying identity record (`did:key` for v1; upgradeable to a `did:plc`-shaped rotation-key-governed record). The anchor is the *key*, not any gateway. Handles live in an `alsoKnownAs`-style **soft pointer** (RESEARCH §5), never in the identity string — a name is stealable, an identity is not.
2. **Identity-governing key vs data-signing key** (RESEARCH §3). The existing sovereign key is the **data-signing** key (signs Carried-Record events). A **rotation key** (separate class) authorizes changes to the identity record itself — rotate the signing key, re-point a home, update the handle — so a lost/compromised *operational* key doesn't destroy the *identity*. v1 MAY collapse these (device-bound single key) **but must name that it's picking Nostr's recovery corner** (§7), with the rotation key as the v2 upgrade seam.
3. **Data / channel homing stays home-anchored — and that's correct.** Design 06's single-sequencer-per-channel (one home gateway assigns ULIDs) is a *data-ordering* axis, orthogonal to identity. The Matrix lesson is "don't put the island in the **identity**," not "don't home channels." Keep the ULID sequencer; cut only the identity weld.

**Passkey's role, resolved:** it stays the sole *login gesture* and doubles as a *recovery factor* (a synced passkey means the user's login survives device loss via iCloud/Google — the "recoverability + simplicity" corner), but it is explicitly **not** the identity anchor. This turns the #6 accidental-sync finding from a bug into a *named* recovery-corner choice.

## 4. Build order (core-first, each step independently useful, no big-bang)

- **Increment 1 (the Blade target) — the seam, no trust move.** Add the *origin/binding* representation without moving the trust root:
  - an `IdentityDoc` domain type (did:key Multikey of the sovereign key + `alsoKnownAs` handle pointer + optional `origin` gateway), reusing `origin_envelope.dart`'s existing Multikey codec;
  - an `origin`/`did` field on the identity/User model (currently absent);
  - globally-namespaced IDs carrying origin (Design 06 L248's "near-zero present cost" move).
  No rotation key, no E2EE change, no recovery flow, no migration. Behaviour identical; the future is kept open. **This is the increment that (a) doesn't foreclose key-anchored and (b) ships alone.**
- **Increment 2 — bind key→handle without a home vouch.** The identity doc is self-signed by the sovereign key; gateways verify the signature directly instead of vouching transitively (cuts Design 06 L151's weld). Handle-uniqueness stays a per-island soft-pointer claim.
- **Increment 3 — the rotation key + recovery envelope.** Introduce the second key class; pick and *name* the recovery-trilemma corner deliberately (device-quorum à la Keybase, or directory à la PLC, or explicit "no recovery" à la Nostr). This is where E2EE/guardian-recovery/Carried-Record-portability braid in — deliberately deferred so increment 1 ships now.

## 5. Tradeoffs (named, with owners)

- **Directory-vs-no-directory is deferred, not dodged (owner: increment 3).** Pure `did:key` (v1) has no rotation/recovery; `did:plc`-shape buys it but adds a directory dependency (RESEARCH §6). v1 accepts Nostr's corner *explicitly*; the ADR records this as a named choice so it isn't emergent.
- **Handle uniqueness across islands is unsolved here (owner: increment 2).** Soft-pointer handles can collide across islands; global uniqueness needs a directory or a namespacing convention. Out of scope for increment 1.
- **Passkey sync = vendor custody of the login factor (owner: accepted).** We cannot force device-bound (RESEARCH §4). Accepted: the identity key is separate and app-custodied, so vendor sync of the passkey is a login-convenience, not an identity-custody, concession.

## 6. Blast radius & consent spine

Increment 1 is **read-additive**: new type + new nullable field + ID namespacing. No trust-boundary change, no wire-breaking change (origin field is additive; island must agree the field name — a v2-wire-contract touchpoint, coordinate via the existing island handoff channel). No new attacker surface (no new endpoint, no new signature-verification path yet). Reversible. → self-review-tier for increment 1; **increments 2–3 touch the trust boundary and are cage-match-by-law.**

## 7. Claims to falsify (for Fold + Temper)

1. **"Key-anchored buys something real today."** Falsified if federation demand is aspirational (handoff asserts enspyr↔imagineering overlap is real — verify, don't assume) AND no user-custodied key path exists. If both, ship the honest single-gateway model instead.
2. **"Identity-homing and data-homing are cleanly separable."** Falsified if the ULID sequencer or the vouch-relay actually needs the identity to be home-anchored (does Design 06 L151's relay *require* a home to exist, or merely use it as an optimization?). If they're entangled, cutting the identity weld also breaks message relay — a much bigger increment 1.
3. **"The existing sovereign key can become the identity key without breaking the Carried Record."** Falsified if promoting the message-signing key to identity-anchor changes its custody/rotation assumptions in a way that invalidates already-signed Carried-Record events.
4. **"Increment 1 truly doesn't foreclose."** Falsified if any additive choice (ID format, did method, field shape) locks out `did:plc`-shape or rotation keys later.

## 7b. FOLD — author's self-strike (pre-adversary; folded back before Temper)

- **Claim #2 (identity-homing vs data-homing separable) — RESOLVED, holds.** Code proof: `origin_envelope.dart:13-14,20-24` — the wire envelope carries `sender_pubkey` and self-verifies on inbound (`verifySignature`), explicitly distrusting the transport. Cross-island relay verifies a message from the *carried* pubkey; Design 06 L151's home-gateway vouch is an **optimization, not a structural requirement**. ⇒ Cutting the identity weld does **not** break message relay. Increment 1 stays small. (Temper: press whether *handle-uniqueness enforcement*, as opposed to message verification, still needs a home authority — it may.)
- **Corroboration, not gap:** the key→account binding is **already a named, deferred seam** in code — `origin_envelope.dart:22-24` ("pubkey→account binding is peer PR B… no 'verified sender' UI until it lands"). Increment 2 lands an existing marked seam, not fresh architecture.
- **Degenerate state the adversary should CONFIRM (n-device):** passkeys sync (BE=1, RESEARCH §4) but `sovereignKeyStoreProvider.loadOrCreate()` writes **device-local** secure storage. ⇒ **one account across two devices mints two sovereign keys today** — the live form of multi-device (#27). Increment 1 must not worsen it; the *right* end-state is Keybase-shaped **per-device signing keys under one identity** (RESEARCH §5), governed by the increment-3 rotation key. Named here so it's a designed layer, not an emergent bug.
- **Claim #3 (promote message key to identity key) — holds provisionally.** The sovereign key is already the message author-identity; making it the identity anchor is consistent, not breaking. Temper: confirm no already-signed Carried-Record event's validity depends on the key staying *non*-identity.
- **Claim #1 (federation demand real) — CANNOT self-resolve.** Empirical premise only Nick can confirm (handoff asserts enspyr↔imagineering overlap). Carried to Temper *and* surfaced to Nick — do not let the forge assume it.

## 8. Rejected alternatives (so the excited author can't launder past them)

- **Pure home-anchored (what shipped by accident), made honest.** Cheapest; forecloses cross-island reputation/recovery/E2EE (CRUCIBLE falsifier). Rejected *unless* claim-1 falsifies.
- **Full `did:plc` clone in increment 1.** The "correct" end state, but drags in a directory, rotation keys, and a migration flow — violates the ship-without-redesigning-everything constraint. Deferred to increment 3, not rejected.
- **Make the passkey the identity key (device-bound).** RESEARCH §4 proves the RP can't force device-bound on platform authenticators; would push every user to hardware keys. Rejected on feasibility.
- **Bind key→handle via home-gateway vouch (Design 06 L151 as-is).** The weld itself. Rejected as the thing we're cutting.
