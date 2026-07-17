# RFC-0006: Sybil resistance: reputation, not personhood

| | |
|---|---|
| **RFC** | 0006 |
| **Status** | Draft, requesting comments |
| **Owner** | Nick Meinhold, with Claude (stands on RFC-0005's Principal graph) |
| **Created** | 2026-07-17 |
| **Thread** | *(Discussion link once posted)* |
| **Reference** | [Design 09: Sybil resistance](https://nickmeinhold.github.io/aiko_chat_app/design/09-sybil-resistance-reputation-not-personhood.html) (full detail incl. verified literature pass, §6.1) |

## Summary

A self-minted keypair is free, so sovereign identity needs an abuse gate. This RFC proposes pricing admission in reputation rather than proving personhood: an existing member stakes their own standing to co-sign a newcomer (bonded vouching) and is slashed if the newcomer misbehaves. Vouching draws on a conserved budget (transfers standing, never mints it) and is root-anchored at the island operator. No CAPTCHAs, no biometrics, no personhood tests anywhere, because robots are first-class citizens and every personhood mechanism is a bouncer whose job is keeping robots out.

## Motivation

Per-island spam, abuse, and impersonation are the real threats; global proof-of-personhood is a category error for a robots-first-class app and sits on an unsolved trilemma anyway (sybil-resistance / self-sovereignty / privacy: pick two). The one scarce resource neither a human nor an AI can multiply is reputation someone will lend you and can lose.

## Proposal

**Guide-level:** joining an island means someone vouches for you, putting a slice of their own standing on the line. Behave well and both of you are fine; abuse and the bonds unwind, costing your voucher too. Running 10,000 sybils requires earning 10,000 sybils' worth of standing, at which point the farm has paid the full price of being 10,000 good members, which is the point: the system never has to tell a farm from a crowd.

**Reference-level (detail in Design 09):** three layers with distinct jobs. RLN-style per-epoch rate limiting (substrate-blind); a time ramp (newcomers start below neutral); and bonded vouching carrying the actual sybil-count bound. Root-anchored trust propagation (EigenTrust-family, teleporting to the island operator) plus conserved vouching defeats sock-puppet rings: a closed ring with no inflow from real roots holds ≈0 standing regardless of internal vouching.

## Rationale and alternatives

Every possessable denomination (money, devices, aged accounts) fails the robots economics test: an AI agent can possess it at scale as cheaply as a human. Personhood mechanisms (Worldcoin, Idena, Proof-of-Humanity) are forbidden by construction here, not merely rejected. Unbonded web-of-trust is refuted in the literature (free vouching = free sybils); bonding is precisely the variable that inverts that refutation.

## Prior art (adversarially verified, 2026-07-17)

A 3-vote-per-claim verified literature pass ran over this design; the full scorecard is Design 09 §6.1. Headlines:

- **The core mechanism is TrustDavis (DeFigueiredo & Barr, 2005)** - bonded vouching as accepted liability, deposit-gated admission, and conserved vouching as max-flow capacities, all verified 3-0 with verbatim quotes. Reassuring rather than deflating: the idea has stood for twenty years.
- **"Bonding inverts the free-vouch refutation" is supported 3-0** ("a malicious party must back each identity with funds").
- **One honest correction taken:** global conductance-based sock-puppet detection is *refuted* for small community-structured graphs (a sybil ring is indistinguishable from a legitimate tight sub-community; detection accuracy anticorrelates with modularity at -0.81). It survives only as local whitelisting around the island's trust root, which is the form this design already uses; Design 09 §5 was corrected accordingly.
- **The composition is coherent by proof:** structural detection can only ever *bound* sybils per attack edge (Yu 2011 lower bound), so an admission-cost gate is complementary, not redundant.
- **Still open in the literature pass:** Advogato's real-world attack history, the exact Friedman-Resnick whitewashing result, EigenTrust parameter guidance, and whether anyone has composed reputation-gated registration with RLN. The full composition appears unpublished: plausibly novel, needs-citation.

## Unresolved questions

1. **Genesis:** what vouches for the *first* island operator, and how does a new island earn federation standing from zero? (Feeds RFC-0001's IslandDirectory fork.)
2. **Stake denomination:** for a no-token, phone-first app, what does the registration stake concretely resolve to, and where is the app/gateway split?
3. **Budget mechanics:** how vouch capacity replenishes with earned standing; how slashing propagates through transitive trust.
4. **Measure, don't assume:** the structural instrument's strength depends on an island's measured mixing time and modularity; a small tool computing these on a real vouch graph would turn the theory caveat into an engineering dial.

## Rejected ideas

- **Any personhood mechanism** (biometric, ceremony, or video-based): filters out the users the app exists to include.
- **Money as the default stake:** optional per-island policy at most; as the default it fails the robots economics test and imports plutocracy.
- **Global structural detection:** refuted by the verified literature pass; local whitelisting only.
