# ADR-0004: Sovereign identity federation — the identity anchor

| | |
|---|---|
| **ADR** | 0004 |
| **Status** | Draft, requesting comments (distills the reserved slot; supersedes the unresolved tension in Design 06) |
| **Owner** | Nick Meinhold, with Claude |
| **Created** | 2026-08-08 |
| **Thread** | Crucible: `docs/crucible/federated-identity-anchor/` (CRUCIBLE · RESEARCH · DESIGN · TEMPER) |
| **Reference** | [Design 06: Sovereign identity federation](../design/06-sovereign-identity-federation.html); [ADR-0005: The identity graph](0005-identity-graph.md) |

## Summary

Identity is anchored to your **key**, not your home island. Concretely: **AIKO is email + cryptographic authorship.** Your Ed25519 key *is* you, everywhere and provably; your handle (`nick:imagineering`) is a **mutable, home-scoped display alias**, not the identity. "Same person across islands" is delivered by the key (clients follow keys, not names); cross-island chat is home-to-home relay (Design 06, a separate axis). We build **no central directory** — cross-island discovery is a **federated per-island member roster** you browse island-first, gated on the federation handshake, with **opt-out** visibility. The near-term deliverable is an additive, non-foreclosing **IdentityDoc seam** (Increment 1) that keeps every heavier option open.

> **Precision (engineering-facing, so this record can't be misread).** "Identity is the key" is the deliberately-compressed *public* framing — keep it as the product line. The exact technical statement below it: the **key is the unit of *authorship continuity*** (it proves "the same actor signed this, everywhere"). A person's **social identity is key + observed history + home-scoped label + contact caches + recovery policy** — the key does not, by itself, carry the handle, the reputation, or the recovery story. The temper struck down "the key alone certifies handle + reputation"; do not let the snappy slogan quietly re-import that error in reverse. Every "identity" in this doc means *authorship-continuity anchor*, not *the whole person*.

> **Blocking dependency (promoted from a tangent — this is what makes the decision real).** This ADR specifies one half of a two-party contract. It has **zero shipped value** until `aiko-chat-island` agrees and implements the server side: the `IdentityDoc` shape, signature verification, and the roster endpoint with its opt-out enforcement. Until that cross-repo handoff lands, this is a private client-side data structure, not federated identity. Treat the island handoff as a **named blocking dependency on Increment 2**, not a follow-up.

## Motivation

The sovereign-identity thesis (*your phone is your self; your reputation travels*) rested on a fork nobody had decided. Three artifacts answered it three ways, each leaning more home-anchored toward the metal: ADR-0005 calls the Principal "deliberately sovereign" but leaves portability open (Q#4); Design 06 says identity is "gateway-independent" **and** "carrying origin gateway" in one breath (L250) and trusts a key only "via a federation vouch from the author's **home gateway**" (L151); the code chose home-anchored *by omission* — a single `kDefaultGatewayBaseUrl` (`lib/app/config.dart:20`), no origin field. A second accidental choice: passkeys mint as vendor-synced (`passkey_auth_client.dart:60` is a thin pass-through, sets no device-binding). Two anti-sovereign defaults, shipped by omission because the fork was never faced.

A cross-family design cage-match (Maxwell/Carnot/Tesla/Kelvin; Wu dark on quota) struck the first framing down: **"self-certifying" does not dissolve authority, it relocates it** — handle-uniqueness, recovery, and reputation each still need *some* authority, so "key vs home" was the wrong axis. The decision was then reframed against four operational properties (usability / performance / access / maintenance), which converged on the email model — a shape with a 40-year existence proof.

## Proposal

**Guide-level.** You hold a key on your phone; that key is you. On any island you are the same person because the same key signs your messages, and clients recognise the key, not the name. Day to day you see people as a **display name + a key-derived Blockie avatar** (already shipped) — the home tag `:imagineering` only surfaces when two real people share a name. To reach someone new on another island you don't memorise their address: you pick the **island** (from the ones you federate with) and browse its members. You're listed to those peers by default and can opt out. Nothing central resolves names; each island publishes its own roster to its peers.

**Reference-level.** Identity is **six separable functions**, each placed by the axis that dominates it (full derivation: `docs/crucible/federated-identity-anchor/TEMPER.md`):

| Function | Locus | Notes |
|---|---|---|
| **Authorship** (who signed) | **key**, carried in the envelope | already shipped (`origin_envelope.dart` self-verifies; home vouch is an optimisation, not structure) |
| **Identity continuity** ("same person") | **key** | clients/UI key off the key; handle is a display alias (Nostr/Bluesky's hard-won rule) |
| **Name allocation** (`@nick`) | **home namespace** (`nick:imagineering`) | home-scoped; no global reservation, no land-grab, no central owner |
| **Discovery** (find a stranger) | **federated per-island roster** | browse island-first; enumeration gated on the peering handshake; **opt-out** visibility, enforced server-side at the roster endpoint; opt-out ≠ unmentionable |
| **Recovery / rotation** | **home-assisted re-attestation** (v1) | + a key-history chain from day 1 of any rotation, or the Carried Record orphans |
| **Data / channel order + history** | **home** ULID sequencer | Design 06 unchanged; survival needs separate mirroring |

**Increment 1 (the seam — additive, non-foreclosing, ships alone):** a **versioned `IdentityDoc`** — opaque/stable `id`, `verificationMethod[]` (signing keys, a *set*), `rotationKeys[]` (empty in v1), `alsoKnownAs[]` (the `nick:imagineering` alias), optional `origin` as a **locator field only**. Doc versioning (monotonic seq or hash-linked `prev`) from day 1. **Origin is banned from primary/foreign keys, author IDs, ACL subjects, and mention targets** — those key off the opaque identity, never a home-qualified string. No trust-root move, no wire break, no directory. This is the whole of what we build now.

## Rationale and alternatives

- **Why email-shaped, not "deeper than Matrix"?** Every survivor learned "follow the key, not the name" (Nostr NIP-05, Bluesky DID-vs-handle). Email already solved federated identity with home-scoped names, no central directory, and 40 years of low maintenance. AIKO's one addition — cryptographic authorship — is what makes it *sovereign* rather than self-hostable Discord.
- **Why no central directory?** It's the only thing that buys a globally-reserved bare `@nick` and home-death survival of your *name* — but at the cost of a central trust-root someone runs, can censor from, and must keep highly available (Bluesky's own team wants to decentralise PLC and hasn't). Nick's stated need — "be the same person across islands and chat with people on other islands" — is met by the **key** (continuity) + **home relay** (reach) with no directory. The browse-by-island roster covers cold discovery federatedly.
- **Why opt-out (not open / opt-in / operator-gated)?** Default-discoverable maximises the point of federation (reaching people), while the peering gate already bounds the blast radius to vetted peers, and the individual escape hatch protects anyone who wants it. Chosen deliberately, not shipped by omission.
- **Why `did:key` is NOT the durable identifier.** `did:key` = the raw pubkey; `did:plc` = hash of a genesis op — different namespaces, so welding the identifier to today's pubkey would force a "become a new person" migration later. Increment 1 stores an opaque `id` with the key as a *verification method*, so a directory or rotation model can be added later without changing anyone's identity.

## Prior art

Bluesky `did:plc` (rotation-key-governed record in a directory — the reference for "island is a venue"), Nostr (pure key + "follow keys not names"; unsolved key-loss is the cautionary tail), Matrix (`@user:homeserver` welded into every event — the decade-long unweld we avoid by never putting the island in the identifier), Keybase (per-device keys under one sigchain — the multi-device end state), email/SMTP (federated, home-scoped names, no central directory). Detail + citations: `docs/crucible/federated-identity-anchor/RESEARCH.md`.

## Unresolved questions (named tradeoffs, deliberately deferred)

1. **Home-death survival of the *name*.** v1 does **not** promise it: if imagineering dies, `nick:imagineering` stops resolving; your key and its signed history survive and you re-home as `nick:enspyr` with a letter-of-introduction (ADR-0005 Q#4). A directory is the only thing that rescues the *name* — deferred until it's a felt need. **Accepted for now** — is "key + history survive, re-home under a new label" an honest-enough sovereignty story? (Nick's call, revisit when a 3rd untrusted island appears.)
2. **Recovery mechanics.** v1 = home-assisted re-attestation + synced-passkey **login continuity** (explicitly *not* identity-key recovery). Full self-custody rotation (Keybase/PLC-shaped) is Increment 3. Passkey copy must be labelled "login continuity factor," never "recovery." **But the recovery *judgment* is not deferrable even though the *implementation* is:** IdentityDoc versioning, the opaque-id vs key-as-id choice, key-history, and device-add/loss semantics are all *shaped by* the recovery model — so Increment 1 must be designed against a chosen recovery *direction* (home-assisted re-attestation) even while deferring the code. Deferring the build is fine; deferring the decision would let Increment 1 pick a shape Increment 3 can't live with.
3. **Carried-Record data survival.** Reputation/history is home-anchored; portability needs export/mirror (Bluesky-shaped re-point). Do not sell Increment 1–2 as reputation portability.
4. **Login-RP homing.** Passkeys are RP-domain-bound; cross-island "one login" needs related-origins / shared-RP for the known island pair — operational, not architectural.
5. **Current-ownership freshness.** A self-signed "I am @nick" proves a *claim*, not *current* assignment; the home signs the handle-assignment as a locator claim with freshness/revocation (Increment 2).

## Rejected ideas

- **Home-anchored (what shipped by accident), left implicit.** Rejected as an *unnamed default*; its honest form (home-scoped names) is in fact adopted — but as a *decision*, with the key as the portable anchor above it.
- **Central directory in v1.** Deferred, not built — buys only global-bare-`@nick` + name-survival, at a trust-root/ops cost the current scale doesn't warrant.
- **Passkey as the identity key (device-bound).** Infeasible — an RP cannot force platform passkeys device-bound (WebAuthn L3); would push every user to hardware keys.
- **`did:key`/origin as the durable primary key.** Forecloses `did:plc`/rotation; replaced by the opaque-id + verification-method seam.
