# 🜂 CRUCIBLE — the passkey IS the identity root

> Movement 1 (Ore) + consent gate. Candidate **pre-selected by Nick** 2026-09-26, out of
> the #4831 ADR-0004 collision. Ore was not scouted; it was given and then argued for.

## Scout-memory check — FIRED, AND IT CHANGED THE CASE TWICE

Required reading done: every `docs/crucible/*/TEMPER.md`, plus
`key-continuity/DESIGN.md` and `key-backup-and-known-keys/{CRUCIBLE,RESEARCH}.md`.

**First pass: I read the record as a blocker and reported it that way. That was wrong.**
I told Nick a four-family panel had gated federation on user count. It had not — the
string does not appear in `federated-identity-anchor/TEMPER.md`. I imported a
scale-pricing discipline learned earlier the same day (217 signed messages did not
justify a migration state machine) and applied it to the project's north star, where it
is the wrong instrument. **Corpus size is the right lens for machinery that protects old
data. It is not the lens for the thing the project exists to be.** Federation is
DECIDED (`project_federation_north_star`, 2026-06-30), with passkeys as its foundation.

**Second pass: the record POINTS AT this candidate.** Two findings from that same strike:

- **Tesla #4** (a unique catch, no other family saw it): *"WebAuthn RP-ID is an unstated
  login-homing weld… 'one passkey login across islands' is NOT free — needs
  related-origins / shared-RP / re-registration. → at bilateral scale **shared-RP may
  beat did:plc**."* A shared-RP root is exactly what this candidate is. The panel named
  the direction; nobody built it.
- **C4**: *"'Passkey recovery factor' is a false identity-recovery story. Synced passkey
  recovers the gateway SESSION; device-local sovereign key is lost ⇒ new cryptographic
  person. login continuity ≠ identity continuity."*

**C4 is the hinge, and it is correct GIVEN ITS PREMISE** — that the sovereign key is
minted independently (`_ed25519.newKeyPair()`) and stored device-local. That premise is
what makes passkey-recovery false. **Deriving the seed from the passkey removes the
premise**: there is nothing separate left to lose, so a synced passkey recovers the
identity key itself. The panel ruled on a world where the key is *minted*. It did not
rule on one where the key is *derived*.

Design 06 §4 says *"the passkey authorizes a sovereign key rather than being it."* That
is a design choice, not a platform constraint. This candidate is the version where
authorizing and being collapse into one artifact.

**What IS a rediscovery, and must not be sold as new:** PRF itself. There is already a
deep sourced pass at `key-backup-and-known-keys/RESEARCH.md:1324-1365` — spec links,
Chrome/Apple milestones, iOS 18.4 bug fixes. Heat must build on it, not repeat it.

**What is genuinely absent from `docs/` (verified by grep, zero hits):** Ed25519 key
blinding, per-island unlinkable derived keys, and linkage-as-a-user-facing-object.

**Prior prescribed shape, honoured:** `key-continuity/DESIGN.md` recommends *Arm B —
wait*, gating continuity on multi-device identity (#17) and rotation semantics (#21).
This candidate does not overrule that by fiat; it argues the gate is now cheaper to pass,
because a derived root delivers multi-device identity as a side effect rather than as a
prerequisite. Temper must strike that claim specifically.

## The pick

**Root the sovereign Ed25519 identity in the passkey, not in the install.**

```
master      = PRF(passkey, "aiko-sovereign-v1")      deterministic · syncs · human-scoped
island_key  = derive(master, island_scope)           per-island child
(later)     = blind(master, island_scope)            per-island UNLINKABLE, provable on demand
```

## Why this thrills me, and what it actually changes

The app has **two identity systems asking the same question twice and never speaking**.
Passkeys answer *"which human is this?"* — they are already the sole ingress. The Ed25519
seed answers *"who authored this?"* — and it is minted from nothing, per install. Every
hard problem in the last three weeks lives in that gap:

| Open problem | Today | Rooted in the passkey |
|---|---|---|
| **#4831** two humans, one handset, one pubkey | wire-visible cross-account link | different passkeys ⇒ different roots |
| **ADR-0004** key must be portable across a human's islands | per-`user_id` scoping breaks it | shared-RP ⇒ one root ⇒ portable |
| **key backup / #17 multi-device** | *no recovery path exists at all* | the platform already syncs it |
| **C4 login≠identity continuity** | true, and a named defect | dissolved — nothing separate to lose |

Four open threads, one mechanism. That is the *oh, of course*: we have been building a
second identity system beside the one the platform already syncs, and paying for the gap
in four places.

**The human task it removes:** "I lost my phone and became a new person."

## The falsifier — one thing that, if true, makes this slag

**If PRF cannot be evaluated deterministically on the same credential across two
devices** — different salts, unsynced hmac-secret, Apple's `enabled: true` returned
without the underlying capability — then the derived master is not stable, and a
"portable identity" that silently differs per device is strictly worse than today's
honest per-install key.

`key-backup-and-known-keys/RESEARCH.md:2154` already records the sharp end of this:
*"support is messy and the capability flag can lie — **probe by deriving**."* So the
first measured step is not reading `credPrf.isSupported`. It is deriving twice, on two
devices, and comparing bytes.

**A second falsifier, narrower:** if the app cannot use one shared RP-ID across islands
(related-origins fails, or each island must be its own RP), then one passkey cannot cover
two islands and the portability claim collapses to today's behaviour. Tesla #4 flagged
this axis; it is measurable against the existing `webcredentials:` entitlements.

## Scale, stated so nothing gets overbuilt

217 signed messages across both live islands, 56 users, and #4831 has fired exactly once
— between two accounts Nick owns. **This does not gate the candidate** (see the framing
error above), but it does govern the build order: the conventional core must be
independently useful at n=1, and the blinding tier must not be a prerequisite for it.
