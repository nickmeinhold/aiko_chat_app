# TEMPER — design 19, the friends edge

**Overall verdict: DISSOLVE** (decisive — two adversary families, independently)

**Struck:** 2026-09-11, bundle = design 19 + `RESEARCH.md` + a peer-repo fact sheet.
**Families seated:** Maxwell (Claude) + Kelvin (Gemini 2.5 Pro) + Carnot (GPT/Codex).
**Dark seat:** Tesla (Grok) — see *Panel integrity* below. Wu (Kimi K3) disabled upstream.

This is a **verdict, not a design**. It goes back to the island tab as a finding.

---

## Per-family verdicts

| Family | Verdict | One line |
|---|---|---|
| **Kelvin** (Gemini) | **DISSOLVE** | *"The design pays a cost the owner has explicitly forbidden to buy a capability the system already has."* |
| **Carnot** (GPT) | **DISSOLVE** | *"Its remaining justification is doing negative work: the shipped conduct gate already closes 100% of the wake harm, while the friends edge creates exactly the durable, enumerable social graph the owner previously rejected."* |
| **Maxwell** (Claude) | RECAST — *"and the recast is mostly a DELETION"* | The ring justification was re-scoped into gating who may MESSAGE you, and it is that un-ruled extra reach that manufactures the artifact. |
| **Tesla** (Grok) | *dark* | Produced no verdict. Not a SOUND vote. |

**Convergence, and it was not seeded.** Kelvin and Maxwell independently reached the same
falsifier — *block is already the un-reply* — from different directions, and neither was
handed it: the fact sheet given to the panel never mentioned blocking. Kelvin reasoned it
from design 19 §0's own text; Maxwell filed it as the highest-value unverified premise.

---

## THE KILL SHOT, AND IT IS NOW VERIFIED RATHER THAN ARGUED

**§10 weakness 1 is false.** The document's last standing argument for
*precedes-not-substitutes* reads:

> **Consent is permanent and unrevocable.** One reply, ever, and that principal may ring you
> forever. **There is no un-reply.**

**There is an un-reply. It is `block`, it is shipped, and it is enforced TWICE on the wake
path.** Read directly in island source this session
(`src/aiko_gateway/domain/push_service.py`, island `main`):

1. **At the message layer** — a wake can only be scheduled after
   `messages_service.create_outbound` returns `created=True`, and that mutator refuses a DM
   send between blocked parties (`BlockedDmSend`). The module's own docstring:
   *"a blocked peer cannot wake you, because they cannot get the message written."*
2. **At the fanout layer, independently** —
   `blocked = await moderation_service.blocked_pair_user_ids(session, sender_id)` and
   `excluded = set(exclude_user_ids) | blocked`, with the comment that this is *"the caller's
   fanout set UNIONED with the service's own read, so neither is trusted alone."*

Withdrawability was carrying *precedes* almost alone after the 2026-09-11 strike of weakness
3. **It cannot carry it, because it is not a property the edge would add.**

**State the residue honestly, because it is the only thing left.** `block` is a *total
severance*, not a ring-only withdrawal. So the true claim is not *"consent is unrevocable"* —
it is **"revocation is all-or-nothing; there is no way to stop someone ringing you while
still exchanging messages."** That is a real gap and a much smaller one. It is already filed
as **#3343** (per-conversation ring mute), which §10 itself says *"composes rather than
competes."* **A coarse-grained revocation gap justifies a mute, not a first-class edge in the
identity graph.**

---

## Fatal flaws (deduped, most-severe first)

1. **Withdrawability — the load-bearing argument — is false.** Raised by Kelvin and Maxwell;
   **verified against island source.** DISPOSITION: **fold into design 19 §10 as a strike of
   weakness 1**, the same in-place treatment weakness 3 got. With 1 and 3 struck and 2
   conceded as a scoping note, §10's case for *precedes* has nothing left standing.

2. **The edge creates the forbidden artifact; the conduct gate does not.** Raised by all
   three seated families; §11c's own argument, confirmed under strike. Kelvin:
   *"The conduct gate lets the social graph be tears in rain… the friends edge carves it in
   stone."* Kelvin also rejects §3a's proposed resolution as *"a distinction without a
   difference — still a queryable, durable social graph, just trivially more expensive to
   read."* DISPOSITION: **surfaced to Nick, NOT resolved by this panel** (§3 was explicitly
   out of the panel's jurisdiction). But note the panel did not need §3 resolved to reach
   DISSOLVE — flaw 1 is sufficient on its own.

3. **Scope smuggle: §0 argues the RING, §5 gates DM CREATION.** Maxwell. Neither cited ruling
   says strangers may not DM you — 2026-08-23 says *friends is a first-class primitive*,
   2026-09-11 says *build the gate before the ring ships*. A much larger product decision is
   riding in on a ring justification, and **the extra reach is precisely the part that
   manufactures the artifact in flaw 2.** DISPOSITION: if any friends primitive is revived,
   it must be **ruled separately from the ring**, not carried in on it.

4. **§6 contradicts the constraint §10 itself quotes.** Maxwell. §10 records
   `project_no_refused_ring_record` (Nick 2026-09-01): *the island keeps no record of who
   called whom; blocked rings are dropped, a log line at most, never a stored row.* §6 then
   requires friend-request rate limiting *"that is not per-process"* — durable server-side
   state keyed on (requester, target), i.e. **the island recording who tried to reach whom,
   including refusals.** The pending/rejected request set is a *richer* artifact than the
   friend graph. §3a prices the friend graph and never prices the request log.

5. **§5's leak analysis fails its own adversary test.** Maxwell. §5 claims a creation-time
   friendship refusal *"leaks only that no mutual edge exists — which the requester already
   knows."* It discloses whether the **target** signed, and distinguishes never-responded
   from withdrawn. And §0 records that block is deliberately *not* gated at creation
   **because a creation-time refusal leaks block direction**; a friendship gate at creation
   reintroduces that leak by differential against the block-on-send path.

6. **A live defect that outlives this fork — the revocation affordance lies.** Maxwell. Three
   consent mechanisms exist and §10 compares two: the device-local per-conversation
   `RingConsent` (shipped, revocable, keyed on Multikeys *precisely so the island cannot
   nominate who may wake you*), the island conduct gate (shipped), and this proposed edge.
   **A user who revokes device-locally has revoked the in-app ring and NOT the cold-start
   wake, and nothing tells them.** DISPOSITION: **file as a defect in its own right** — it is
   true whichever way this fork goes.

7. **"Low-stakes" is asserted, never argued.** Maxwell. At 46 users the power to wake a
   specific human at 3am is the highest-privilege operation in the system; ADR-0006 bonded
   `vouches-for` for less.

---

## Charge C — §6 and §7, tested rather than rubber-stamped

- **§7 (grandfathering existing DM partners): RECOMMENDATION HOLDS,** and the reasoning
  improves it. Derived-from-conduct is exactly what the shipped gate is, so the two answers
  must match — that symmetry is the finding, and it survives all three strikes.
- **§6 (what a request carries): RECOMMENDATION IS RIGHT AND INCOMPLETE.** "Show the
  identity, neuter the payload" (Signal Message Requests, MSC2403) is sound prior art, but it
  answers the cosmetic half; the constraint-violating half — durable cross-process rate
  limiting vs `no_refused_ring_record`, flaw 4 — is what needed testing and was not resolved.
- Kelvin's framing, worth keeping: both recommendations *"are arguments for a first-contact
  gate in general, not this one in particular. They should be applied to the SURVIVING gate."*

---

## What holds

- **§2** — this cannot be `vouches-for`. ADR-0006's conserved quantity does not soften and a
  zero-balance bond is still a bond. Unstruck by every family.
- **The structural observation** that aiko has guardians and bonded vouches before it has
  friends, and that this ordering is probably right — accountability cannot be retrofitted, a
  softer edge always can.
- **§11a's option-set reasoning.** The survey's own appendix closes the only scale-free
  escape, so the server-side leak is not a choice. Evidence, honestly handled.
- **§3's refusal to tie-break the 2026-08-25 ruling.** Correctly surfaced, correctly not
  resolved — and the panel honoured the same boundary.
- **§10's in-place strike of weakness 3**, showing its own cost rather than quietly deleting
  it. That habit is what made this temper cheap: the document had already told the panel
  where it was weakest.
- **The shipped conduct gate itself** (Kelvin: *"simple, already built, leverages existing
  data"*), whose one cited weakness turns out to be covered.

---

## Disposition

**DISSOLVE at ≥2 families ⇒ the candidate is invalidated. Do not re-cast.**

This is an **honest negative result**, and it was the outcome the island tab said it had no
stake against. What it means concretely:

1. **The ring question is answered: the conduct gate SUBSTITUTES.** It is shipped, it covers
   100% of the wake path, and its sole recorded weakness is already covered by `block`.
2. **The ring is now blocked on DEPLOY, not on design.** Island `b7dafac` is merged and
   deliberately undeployed; both live boxes still wake for a stranger. Kelvin's closing line
   is the action: *"Deploy island `b7dafac` and substitute it for this edge entirely."*
3. **Two real gaps survive and should be filed, not folded:** the coarse-revocation gap
   (**#3343**, per-conversation ring mute) and the lying revocation affordance (flaw 6).
4. **A friends primitive may still be wanted — for reasons other than the ring.** Nick's
   2026-08-23 ruling stands on its own terms. But it must be re-argued on its own purpose and
   ruled separately (flaw 3), not carried in on a ring justification that no longer needs it.
5. **§3 remains Nick's and remains open.** The panel did not resolve it and did not need to.

---

## Panel integrity — read this before weighting the verdict

- **Three of four families seated; Tesla (Grok) went dark**, returning 144 bytes claiming a
  truncated bundle and producing no verdict. A retry with a 60KB bundle was run. **A dark
  seat is a coverage gap, not a SOUND vote** — Tesla's bias is under-counted blast radius and
  future failure modes, so that is the lens this strike is thinnest on.
- **Two DISSOLVEs meet the decisive threshold** and the deciding flaw was independently
  verified against source, so the verdict does not rest on adversary agreement alone.
- **Maxwell is the author instance** and its own verdict (RECAST) is the weakest evidence
  here by construction — it is recorded, and it is the one that was outvoted.
- **The first launch of all three adversaries died silently** (backgrounding a CLI inside an
  already-backgrounded call orphans the child). Kelvin produced 0 bytes and Carnot no file.
  Caught by checking file sizes rather than by the absence of output — a 0-byte reviewer and
  a reviewer with no findings are indistinguishable until measured.
