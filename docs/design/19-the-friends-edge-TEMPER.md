# TEMPER — design 19, the friends edge

**Overall verdict: DISSOLVE** (UNANIMOUS — all three adversary families, independently)

**Struck:** 2026-09-11, bundle = design 19 + `RESEARCH.md` + a peer-repo fact sheet.
**Families seated:** Maxwell (Claude) + Kelvin (Gemini 2.5 Pro) + Carnot (GPT/Codex) +
Tesla (Grok). **Full panel.** Wu (Kimi K3) disabled upstream.

> **CORRECTION, same session.** This document first recorded Tesla as a DARK SEAT. That was
> wrong, and the error was mine, not the instrument's: Tesla's output file was read **while
> the process was still writing it** (263 bytes at the time, a preamble), and the partial was
> banked as the result. The completion notification arrived afterwards. The finished strike is
> 10KB, votes **DISSOLVE**, and contains findings no other family reached. Everything below is
> the corrected record. See *Panel integrity*.

This is a **verdict, not a design**. It goes back to the island tab as a finding.

---

## Per-family verdicts

| Family | Verdict | One line |
|---|---|---|
| **Kelvin** (Gemini) | **DISSOLVE** | *"The design pays a cost the owner has explicitly forbidden to buy a capability the system already has."* |
| **Carnot** (GPT) | **DISSOLVE** | *"Its remaining justification is doing negative work: the shipped conduct gate already closes 100% of the wake harm, while the friends edge creates exactly the durable, enumerable social graph the owner previously rejected."* |
| **Maxwell** (Claude) | RECAST — *"and the recast is mostly a DELETION"* | The ring justification was re-scoped into gating who may MESSAGE you, and it is that un-ruled extra reach that manufactures the artifact. |
| **Tesla** (Grok) | **DISSOLVE** | *"The resonant frequency is not a stranger ULID. It is the first unfriend that erases a living DM, or the first operator dump of the table you were told the island must never hold."* |

**Convergence, and it was not seeded.** Kelvin and Maxwell independently reached the same
falsifier — *block is already the un-reply* — from different directions, and neither was
handed it: the fact sheet given to the panel never mentioned blocking. Kelvin reasoned it
from design 19 §0's own text; Maxwell filed it as the highest-value unverified premise.
Tesla arrived at the same place by a third route — that the edge **cannot express** the
property it is sold on (below) — and named the existing send-path block alongside `#3343`.

**Three of three adversary families DISSOLVE. The author instance was the sole holdout, and
its verdict is the weakest evidence in the room by construction.**

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

2b. **THE TOMBSTONE GRAPH — §11c under-counted its own blast radius.** Tesla, and no other
   family reached it. A **signed withdrawal persists relationship HISTORY, not a snapshot.**
   At 46 users the sensitive query is not *"who talks to whom"* — that is already inferable
   from DM membership — it is **"who is missing, who withdrew."** That table does not exist
   anywhere today. **This design mints it**, and it mints it as a durable, signed, enumerable
   artifact. The very revocability sold as the edge's advantage is what creates the worst
   version of the artifact Nick objected to. DISPOSITION: fold into §11c if any friends
   primitive is ever revived.

2c. **Withdrawal is INCOHERENT as specified — the edge cannot express the property it is
   sold on.** Tesla. §5 gates `POST /v1/dm` create and gets ring-gating *"by consequence"*, so
   a withdrawal that **destroys** the channel couples *"stop ringing me"* to *"delete our
   conversation"* — nobody uses that at 3am — and a withdrawal that **leaves** the channel
   does not stop the invite. **The property actually wanted is revocable ring permission
   without erasing the conversation, and §4–§5 cannot express it. `#3343` can.** This is the
   same conclusion as flaw 1 reached from the opposite end: not *"the property already
   exists"* but *"this mechanism could not deliver it anyway."*

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

## A strike that landed on THIS MORNING'S FOLD-IN, not on the design

**§11a overclaims, and Tesla named it (Charge E).** §11a was written hours before the strike
and concluded that the option set *"has one member left"*. That is stronger than the evidence:

- The NSE measurement establishes **closed today, for this spike** — `CXError` code 2, a
  missing `com.apple.developer.usernotifications.filtering` entitlement — **not closed
  forever**. Apple's documented rationale for that path is *"when your server can't determine
  whether an outgoing notification is a request for a VoIP call"*, and §10 records that
  **MLS kills the cleartext `CALL_INVITE_BODY` comparison** — i.e. this project moves
  *toward* Apple's stated grant criterion, not away from it.
- Tesla's phrasing: using a missing entitlement on a pre-MLS VoIP path to spend the 2026-08-25
  ruling **permanently**, while ignoring the already-shipped conduct substitute, is
  *"prophecy read backwards."*
- **And the option table omitted a fifth member** — the substitute already merged. §3a's
  *"the alternative is that the ring cannot be gated at all"* is false on the strike-context's
  own fact 4: the conduct gate covers 100% of the wake path. **§3a is not a hard remainder;
  it is a frame that hides SUBSTITUTES.**

DISPOSITION: **correct §11a in design 19.** The claim is time-boxed and spike-boxed, and the
correction was owed whatever the verdict was.

**One sharpening of §11c, also Tesla's:** *"the conduct predicate creates none"* is slightly
loud — the island already holds routing pairs as DM membership. The harm Nick named is a
**first-class enumerable social graph**, which the edge still newly creates. The argument
survives; the wording overreaches.

---

## Charge C — §6 and §7, tested rather than rubber-stamped

**Both recommendations were REJECTED on the full panel. They were folded in hours before the
strike, from prior art, and had been challenged by nobody — which is exactly why they were put
up. Tesla rejected both outright; recording that reversal is the point of having asked.**

- **§7 (grandfathering): REJECTED — and the reason is structural, not preferential.** The
  recommendation was *yes, and the answer must match §10's*. Tesla: **that symmetry is a
  rhetorical trap.** Deriving a *query* from `Message` rows is not the same act as
  **materialising** `is-friend-of`. And it collides head-on with §3a's un-forgeability: the
  island **cannot mint a signature**, so silent grandfathering is either (a) forged
  island-attested edges, (b) a fork of the primitive into signed-vs-derived, or (c) not
  grandfathering at all but a **signing campaign that severs everyone who does not sign.**
  The prior art does not transfer either — **Signal grandfathered a client-side filter, not a
  signed identity edge.** Maxwell's "the answers must match" reasoning is withdrawn.
- **§6 (what a request carries): REJECTED AS STATED, and it contradicts §11d.** The
  recommendation was *show the identity, neuter the payload*. Tesla: blurred avatars and
  un-linkified URLs are **internet-scale abuse hygiene — spam-frame machinery that §11d had
  just disqualified.** At 46 people the value is a **legible** decision, so identity-adjacent
  signal should be **clear, not neutered**; neutering makes consent *worse*. And MSC2403's
  reason field **reimports the free-text harassment surface** the fork claimed to close. **If
  SUBSTITUTES holds, the friend-request channel should not be built at all** — first contact
  at 46 people is already *"they are in a room with you"* or an out-of-band knock, and the
  ring is already gated by conduct.
- Kelvin's framing survives both: the recommendations *"are arguments for a first-contact gate
  in general, not this one in particular. They should be applied to the SURVIVING gate."*

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

- **All four families seated. The verdict is unanimous across the three adversaries.** The
  deciding flaw was additionally verified against island source, so it does not rest on
  agreement alone.
- **TESLA WAS FILED AS DARK AND WAS NOT, AND THE MECHANISM IS WORTH MORE THAN THE
  CORRECTION.** Its output file was read **while the process was still writing** — 263 bytes,
  a preamble announcing an intent to keep reading — and that partial was banked as *"no
  verdict produced"*. The completion notification for that very process arrived afterwards
  and was available. **A file being written and a file that is finished are different
  epistemic states, and `wc -c` cannot tell them apart**; the instrument that can is the
  process exit, which had not happened yet. This is the four-states crux (absence / silence /
  default / refusal) recurring inside the very session that named it, one substrate over: a
  partial read as a refusal.
  **Cost had it stood:** Tesla is the only family that found the tombstone graph and the
  withdrawal-incoherence flaw, and the only one that rejected BOTH §6 and §7 — the two
  recommendations every other family let pass. The seat most likely to be written off as
  empty was the one carrying the findings nobody else had.
- **Tesla also struck this panel's own fold-in**, not just the design — see the §11a
  overclaim above. An adversary correcting the framing it was handed is the one thing a
  shared premise bundle cannot do for itself.
- **Maxwell is the author instance** and its own verdict (RECAST) is the weakest evidence
  here by construction — it is recorded, and it is the one that was outvoted **3–1**. Two of
  its Charge C answers were reversed by Tesla and are marked withdrawn above.
- **The first launch of all three adversaries died silently** (backgrounding a CLI inside an
  already-backgrounded call orphans the child). Kelvin produced 0 bytes and Carnot no file.
  Caught by checking file sizes rather than by the absence of output — a 0-byte reviewer and
  a reviewer with no findings are indistinguishable until measured.
