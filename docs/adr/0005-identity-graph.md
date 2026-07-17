# ADR-0005: The identity graph

| | |
|---|---|
| **ADR** | 0005 |
| **Status** | Draft, requesting comments |
| **Owner** | Nick Meinhold, with Claude (vocabulary foundation: ADR-0001) |
| **Created** | 2026-07-17 |
| **Thread** | *(Discussion link once posted)* |
| **Reference** | [Design 12: The identity graph](https://nickmeinhold.github.io/aiko_chat_app/design/12-identity-graph.html) (full detail) |

## Summary

ADR-0001 named the identity nouns; this ADR pins the *relationships* between them, because that is where the design decisions live. Three claims: identity stratifies into three layers (Principal / Participant / runtime); Self and Owner are edges between layers, not concepts of their own; and every Participant gets its own Principal, with bots hanging off a vouch bond so that bot independence becomes per-island policy on a fixed schema.

## Motivation

Two concrete pressures. First, the bot-cardinality question (does a bot act under its creator's identity or its own?) cannot even be *expressed* in a glossary: cardinality is a property of an edge, and it silently decides blast radius, rate-limiting shape, and whether a robot can ever earn standing. Second, the registry's `owner` field is today an unauthenticated OS username; as islands federate it needs a principled home, and it should get one without renaming anything.

## Proposal

**Guide-level:** you hold a Self (your phone-held credential). It proves control of your Principal (the thing that has standing and can be slashed). In channels you appear as a Participant. Services you run point back at your Principal through the registry's existing `owner` field. When you run a bot, the bot gets its *own* Principal, backed by a bond from yours; how independent it starts is your island's policy, not a schema fork.

**Reference-level (detail in Design 12):**

1. **Three layers.** Principal = accountability (durable, stake-bearing); Participant = presence (what a channel sees, `@human` / `@@bot`); ServiceTopicPath = runtime (an address; a restart changes it, trust never attaches to it).
2. **Five edges.** `is-credential-of` (Self → Principal), `speaks-as` (Participant → Principal), `vouches-for` (Principal → Principal; bonded, conserved, slashable, per ADR-0006), `owns/runs` (Principal → Service), `is-instance-at` (→ ServiceTopicPath).
3. **One invariant.** Every stake, slash, bond, and rate limit is an operation on the Principal graph only. If a design needs to slash a Participant or trust a topic path, something upstream is wrong.
4. **Bot cardinality is a policy dial.** Schema commits to own-Principal-plus-vouch (Model B); "bot shares my identity" (Model A) is just Model B with a zero-standing Principal living entirely on your bond. Islands choose the default; the federation only has to agree on the graph.
5. **Owner roadmap, staged.** Stage 0: today's `get_username()` (fine intra-island). Stage 1: the value becomes a Principal id (same field, same S-expression wire format, no structural change). Stage 2 (only when cross-island traffic exists): registration is signed, so `owner` becomes claim-checked. No renames, nothing blocked on this.

## Rationale and alternatives

- **Why not Model A (bots share the creator's Principal)?** Simpler, trivially sybil-proof, and no new machinery, but it fails robots-first-class permanently: a robot could never earn standing of its own. A system where that is impossible has re-imported the personhood test through the back door.
- **Why not a fourth identity concept for services?** The `chat.py` TODO hinted at one ("Owner"); reading the code showed Owner is already an edge (a pointer from a running Service to its accountable party), so promoting it to a node would mint exactly the duplicate-concept problem ADR-0001 exists to prevent.

## Prior art

Matrix welds identity to homeservers (`@user:server`) and has spent a decade trying to unweld it; the Principal here is deliberately sovereign (Design 06). The Participant/Principal split parallels actor-vs-account distinctions in ActivityPub, where their partial merge is a recurring source of moderation pain.

## Unresolved questions

1. **Dial default:** where on the shadow-to-independent spectrum should a community island start a newcomer's bot?
2. **Emancipation:** may a robot Principal that has earned real standing outlive its creator's vouch?
3. **Vouch rights:** may bot Principals vouch for others, or is vouching reserved for Principals holding a Self credential?
4. **Portability:** is "port the key, re-earn the standing, arrive with a letter-of-introduction vouch" the right cross-island story?
5. **Owner roadmap:** any objection to Stage 1 as the eventual direction, so nothing built meanwhile paints over the seam?

## Rejected ideas

*(grows as the thread resolves)*
