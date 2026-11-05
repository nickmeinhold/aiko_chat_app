# RECOMBINATION.md — the Aiko Chat capability ledger

> A `/recombine` ledger. Each entry is a **third thing** born in the gap between shipped capabilities — minted as a first-class artifact with its own `{function, consumes, emits}`, so a later pass can recombine *these* with each other and the originals (the Fold). Append; never blend.

---

## Pass 1 — 2026-08-02 · inline · target: Aiko Chat's shipped capability stack

**Inventory (functions, not objects):**

| # | thing | function | consumes → emits |
|---|---|---|---|
| T1 | sovereign message signing | mints unforgeable authorship+integrity at birth | message + device key → signed self-verifying record |
| T2 | passkey identity | device-bound passwordless personhood-anchor | biometric + device → authenticated account, no shared secret |
| T3 | federation trust root | binds a mark to a citizen across islands | mark + vouching island → portable verified identity |
| T4 | robots-as-first-class-citizens | non-humans get real verifiable identities | agent + ingress seam → a citizen that can sign + accrue standing |
| T5 | reputation-not-personhood | trust from behaviour, substrate-agnostic | action history → a portable trust signal |
| T6 | takedown-retraction | revoke an event on the verifiable log | a decision → a signed forward-ULID retraction riding the history cursor |

**Anchor `Z` = "a signed event on a carried log."** A message, a moderation retraction, and a judgment-about-conduct are the *same type*. T1 · T5 · T6 glue on it.

### ⭐ Third thing: **The Carried Record**
- **function:** turn reputation from a platform-assigned score into a subject-owned, island-portable, cryptographically-verifiable ledger of one's own signed actions + the signed judgments on them.
- **consumes:** signed action events (T1) · signed conduct-judgments (T6, exapted) · a portability channel (T3).
- **emits:** a portable proof-of-conduct that anyone can verify and no authority assigns — identical substrate for humans and AI agents.
- **operator:** *exaptation* — co-opt the takedown-retraction organ (built to un-say content) to carry **conduct events**. You don't build a reputation system; you reuse moderation+signing you already ship.
- **inevitability sentence:** *If every action is signed at birth and every judgment is a signed retraction on the same log, then reputation just **is** that log — owned by the subject, provable to anyone, assigned by no one.*
- **subtraction (deletes two couplings):** (1) "reputation needs a central authority" — removed; the log *is* the reputation. (2) "a banned actor escapes by re-registering" — removed; a fresh identity carries a provably-thin record, and signed history can't be shed by island-hopping.
- **preserved seam:** identity stays distinct from its record; human-citizen stays distinct from agent-citizen — but both run the **same** substrate. The click: *the exact thing that lets a robot be a first-class citizen (it carries a provable track record) is the exact thing that defends against sybils (a newcomer's record is provably thin).* Two problems, one organ.
- **conventional core + atypical tail:** core = verifiable message history (shipped). tail = the same primitive making an **AI agent's trustworthiness a thing it owns and proves**, not a vendor grants.
- **build order:** ① signed history — ✅ shipped · ② exapt retraction → signed *conduct* events (machinery mostly built) · ③ portability via the trust root (federation north star) · ④ agent-citizens carry the same log. Each step independently useful; no big-bang.
- **consent spine (cage before monster):** a conduct event is signed **and contestable** (attach a signed rebuttal); the record is **subject-carried, never platform-surveilled** — the private+public join must *invite*, never surveil.
- **assay:** aliveness HIGH (genuine *oh-of-course*: the retraction organ was hiding a reputation system) · impact HIGH (missing substrate under two stated north stars) · not-a-heap / not-a-monster / not-a-gimmick ✓. Honest caveat: partially latent-and-deferred in the graph already ([[project_identity_personhood_vs_reputation]]) — recombine's contribution is naming that **the machinery to build it already shipped**.
- **disposition:** un-built. Cold-pole next move = `/ascend` then a worktree spike. Cross-repo (island-side ingress for agent-citizens, #2403/#2404) — a handoff, not an app-tab build.

**Fold status:** pass 1 minted one third-thing (The Carried Record). Not yet folded — a pass 2 could anchor The Carried Record with T2 (passkey custody for agent keys) or the app-store preflight (admission-preflight for inbound federated identities). Deferred.
