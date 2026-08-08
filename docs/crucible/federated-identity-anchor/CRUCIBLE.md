# CRUCIBLE — The identity anchor: key vs home

**Forged:** 2026-08-07 · **Track:** A (foundational) · **Ends in:** `docs/adr/0004-sovereign-identity-federation.md` + a scoped, non-foreclosing first increment.

## The ore (verified real, not invented)

Three artifacts, three altitudes, and they disagree — each leaning *more* home-anchored as you descend toward the metal:

| Layer | Artifact | What it says | Lean |
|---|---|---|---|
| Philosophy | `docs/adr/0005-identity-graph.md` | "the Principal here is **deliberately sovereign**"; but *Unresolved Q#4* = "port the key, re-earn standing… is that the right cross-island story?" **never answered** | key-anchored (in principle) |
| Mechanism | `docs/design/06-…federation.html:89,133,151,250` | L89/133: identity is "**gateway-independent**", "**portable**", "you everywhere". L151: but a remote gateway trusts your key "via a federation **vouch from the author's home gateway**." L250: "keep identity gateway-independent **and** … carrying **origin gateway**" — *both arms in one sentence* | home-anchored (in plumbing) |
| Code | `lib/app/config.dart:20`, `lib/features/auth/domain/identity_models.dart` | single hardcoded `kDefaultGatewayBaseUrl`; **no origin/home field anywhere** on the identity outcome | home-anchored *by omission*, not even federation-capable |

Plus the second accidental choice, from cheap-check #6: `lib/features/auth/data/passkey_auth_client.dart:60` is a **thin pass-through** — it sets no `residentKey`/`authenticatorAttachment`, so passkeys mint as **iCloud/Google-synced (vendor-custodied)** by default. Two anti-sovereign defaults, both shipped by omission.

## The pinned fork (sharper than the handoff's binary)

The keypair being portable is **settled**. The genuinely-undecided question is the **binding authority**:

> **Who certifies `key X → @handle + reputation`?**
> **(HOME)** a home gateway vouches, and other gateways trust it transitively → home island dies ⇒ binding orphaned, handle unrecoverable.
> **(KEY)** the binding is itself gateway-independent (a signed self-issued identity doc + a directory/rotation-key, à la `did:plc`) → any gateway verifies it, no home need be alive.

And nested under KEY, a **custody sub-axis** the recovery trilemma forces (sovereignty / recoverability / simplicity — pick 2): is the key **device-bound** (sovereign, lose-phone-lose-self) or **synced** (recoverable, vendor-custodied)? The app currently answers *synced* — by accident.

## Why this thrills me AND what it changes

This is the **keel of the boat**. Every downstream hard problem — cross-island E2EE keying, guardian recovery, Carried-Record portability, @-mention resolution — is a function of this one answer. Settle it and four stuck things unstick at once. What genuinely lights me up: **key-anchored-with-a-gateway-independent-binding is a model *deeper than Matrix*** — Matrix spent a decade trying to unweld `@user:server` and couldn't; we can start unwelded because passkeys already made identity a key. And the binding layer that makes it work (a signed identity doc + rotation key) is the *same graph* as the vouch/reputation graph from ADR-0006 — so identity portability and portable reputation turn out to be one substrate, not two. That's the "of course" — the Carried Record and sovereign identity were always the same object seen from two sides.

**One-line spark:** *your phone is your self, and no island's death can revoke you — because the thing that says "this key is @nick" is signed by @nick, not by @nick's landlord.*

## The falsifier (what would prove this ore is slag)

**If the app's passkeys are irreducibly vendor-synced AND users overwhelmingly stay inside one island, then key-anchored buys nothing real today** — the "sovereignty" is theatre (Apple already holds custody of the key) and the migration cost is pure overhead vs just shipping the single-gateway model honestly. Concretely, this ore is slag if: (a) there is no reachable device-bound or user-custodied key path on the target platforms, **and** (b) the empirical federation demand (enspyr↔imagineering overlapping users wanting one identity) turns out to be aspirational rather than a real request. The handoff asserts (b) is real (Nick confirmed overlapping people) — Temper must not let me assume it.

## Scope guard (what the first increment must NOT do)

The Blade increment must (a) not foreclose key-anchored if it wins, and (b) ship without redesigning E2EE / recovery / Carried-Record / mentions all at once. The likely shape — *add the origin/binding seam without moving the trust root yet* (globally-namespaced IDs carrying origin, an identity-doc type, no behaviour change) — is the near-zero-cost "keep the future open" move Design 06 §L248 already gestures at. Temper decides if that's enough or a fig leaf.
