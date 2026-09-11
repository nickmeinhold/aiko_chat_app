## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST (and the recast is mostly a DELETION)

`John McClane: "Welcome to the party, pal."`

**Summary:** The design was ruled into existence to stop a stranger ringing a locked handset, and then quietly re-scoped itself into gating who may MESSAGE you at all — and it is that un-ruled extra reach, not the ring, that manufactures the durable social graph the owner rejected.

**Fatal flaws:**

- **THE ILLEGAL MOVE — scope smuggle between §0 and §5 (wrong option-frame).** §0's entire case is the ring: *"a stranger who knows your ULID can ring your locked handset."* §5 then gates **`POST /v1/dm` at creation**, and lists ringing as gated *"by consequence."* Those are different products. The ring harm is a 3am interruption; the DM harm is, in §0's own words, *"a stranger could put a message in your list"* — which the document itself characterises as the OLD, un-repriced problem. Neither ruling cited in the header says strangers may not DM you: 2026-08-23 says friends is a first-class primitive, 2026-09-11 says build the gate before the ring ships. **A product decision of much larger blast radius is riding in on a ring justification, and it is the part that creates §11c's artifact.** Narrow the edge to the ring and most of the design's cost disappears — along with most of its reason to exist.

- **§6 CONTRADICTS §10's own quoted constraint (internal contradiction, and it is load-bearing).** §10 records `project_no_refused_ring_record` (Nick 2026-09-01): *"the island keeps no record of who called whom; blocked rings are dropped… a log line at most, never a stored row."* §6 then requires friend requests to have *"a rate limit that is not per-process"* — which is server-side durable state keyed on (requester, target), i.e. **the island durably recording who tried to reach whom, including refusals.** The pending/rejected request set is a RICHER artifact than the friend graph: it contains approaches that were declined. §3a prices the friend graph and never prices the request log. **The design spends more un-observability than it admits to spending.**

- **CHARGE A: withdrawability CANNOT carry "precedes", because as designed it is not a guarantee — it is an island policy.** §4 asserts *"revocable — either side may withdraw; withdrawal is also signed."* Signed by whom, evaluated by whom? The island. So the property that is supposed to beat the conduct gate is enforced by **exactly the party the design says must not be trusted to nominate who may reach you** — and `ring_consent.dart`, quoted approvingly in §3a, is explicit that island-editable rows are the threat. An island that declines to honour a signed withdrawal is indistinguishable, from the handset, from one that honours it. To make withdrawal a *guarantee* rather than a policy you need either the device to decide (it is asleep — that is the whole of design 16) or a bearer token the caller must present (the capability model, which §11a establishes collapses at 46 users). **Withdrawability is real as a feature and hollow as an argument.**

- **AND THE FALSIFIER IS ONE GREP AWAY, WHICH IS WHY THIS IS THE HIGHEST-VALUE OPEN QUESTION.** §0 states block is not gated at creation, so *"the block gate sits on the send."* The wake is triggered by a send. **If `user_blocks` is consulted on the wake path, then blocking ALREADY revokes ring consent, withdrawability is already solved by an edge that exists, and §10 weakness 1 is simply false.** This tab has not read island source and must not assert it — but the document rests its last leg on a property that may already be shipped under a different name, and nobody checked. That check precedes any build.

- **THE THIRD MECHANISM THE DOCUMENT NEVER COMPARES (under-counted blast radius).** There are not two consent mechanisms here, there are **three**: the device-local per-conversation `RingConsent` (shipped, revocable, keyed on Multikeys precisely so *"the island cannot nominate who may wake you"*), the island conduct gate (shipped, unrevocable), and this proposed edge. §10 compares two of three. The omission has a user-visible consequence: **a user who revokes device-locally has revoked the in-app ring and NOT the cold-start wake, and nothing tells them.** The affordance lies. That is a live defect under BOTH arms of the fork and it belongs in whichever survives.

- **§5's leak analysis fails its own adversary test.** §5 argues a creation-time friendship refusal *"leaks only that no mutual edge exists — which the requester already knows."* It does not: the requester knows their own half. The refusal discloses whether the **target** has signed, and it distinguishes *never-responded* from *withdrawn*. Worse, §0 records that block is deliberately NOT gated at creation **because a creation-time refusal would leak block direction** (island design 11 Decision 5). A friendship gate at creation reintroduces that leak one layer up: compare the friendship-refusal path against the block-on-send path and you recover block direction by differential. **The design asks for this to be checked by an adversary rather than accepted; checked, it fails.**

- **"Low-stakes" is asserted, never argued (unstated assumption).** §1 and §4 call the edge *unbonded, low-stakes*, granting *"reach, never standing."* At 46 users, the power to wake a specific human at 3am is the highest-privilege operation in the system. ADR-0006 made `vouches-for` bonded because it is accountable; the document never argues why an edge conferring interruption rights is categorically less accountable than one conferring reputation. The enthusiasm picked "low-stakes" and the design inherited it.

**Charge A — can withdrawability carry "precedes"?** **No, not as designed.** See above: it is an island policy wearing a cryptographic costume, and its uniqueness claim may already be false via `user_blocks`. It could be made to carry precedes only by a construction the design does not contain.

**Charge B — is §11c's durable-artifact argument sound?** **Yes, and it is the strongest paragraph in the document — but it is narrower than it reads.** It is sound *for the edge as scoped in §5*. It would NOT hold against a ring-only edge stored device-locally, and §11c does not say so, which lets it read as an argument against any friends primitive rather than against this one's scope. Sharpen it or it will over-kill.

**Charge C — §6 and §7, tested.** **§7 (grandfathering): the recommendation holds and the reasoning improves it** — derived-from-conduct is exactly what the shipped gate is, so the answers must match; that symmetry is the real finding and it survives. **§6 (what a request carries): the recommendation is right and INCOMPLETE.** "Show the identity, neuter the payload" is good prior art, but §6's requirement for durable cross-process rate limiting collides with `no_refused_ring_record` (above), and *that* is the part that needed testing. A recommendation that answers the cosmetic half of a question and leaves the constraint-violating half open is not resolved.

**What holds:**
- §2's argument that this cannot be `vouches-for` — ADR-0006's conserved quantity does not soften, and a zero-balance bond is still a bond. Clean.
- The structural observation that aiko has guardians and bonded vouches before it has friends, and that this ordering is probably correct.
- §11a's option-set reasoning: the survey's own appendix closes the only scale-free escape, so the leak is not a choice. That is evidence, honestly handled.
- §3's refusal to tie-break the owner's 2026-08-25 ruling. Correctly surfaced, correctly not resolved.
- §10's in-place strike of weakness 3, showing its own cost rather than quietly deleting it.

**If RECAST, what to fold back:**
1. **Split the document.** The ring gate and the "may strangers DM me" gate are two decisions with two blast radii and only one of them was ruled. Ask for the second explicitly; do not carry it in on the first.
2. **Run the falsifier before anything else:** is `user_blocks` consulted on the wake path? If yes, §10 weakness 1 is false and the last leg of "precedes" is gone.
3. **Price the request log in §3a**, alongside the friend graph, and reconcile §6's rate limit with `no_refused_ring_record` or drop one of them.
4. **Fix §5's leak analysis** — it currently reintroduces block-direction disclosure by differential.
5. **Add the third mechanism to §10's comparison**, and file the device-local-revocation-does-not-revoke-the-cold-wake gap as a defect in its own right, because it outlives this fork.
6. **Argue "low-stakes" or drop the adjective.**
