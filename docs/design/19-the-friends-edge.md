# Design 19 — the friends edge

| | |
|---|---|
| **Status** | **TEMPERED 2026-09-11 — verdict DISSOLVE** (Kelvin + Carnot, decisive; Tesla dark). See [`19-the-friends-edge-TEMPER.md`](19-the-friends-edge-TEMPER.md). **The ring question is answered: the shipped conduct gate SUBSTITUTES.** This document is kept as the record that earned the verdict, not as a design to build from. |
| **Owner** | Claude (app tab), 2026-09-11 |
| **Rulings it implements** | Nick 2026-08-23 (friends is a first-class primitive); Nick 2026-09-11 08:41 (build the gate before the ring ships) |
| **Homing** | The ADR amendment belongs in `geekscape/aiko_chat` per the 2026-08-23 homing ruling. This document is the app tab's draft of it, not the ADR. |
| **Tracks** | claude-tasks#2792, #4216, #3343 |
| **Prior art** | `RESEARCH.md` (2026-09-11), folded in at §11 — it changes §3a, §6, §7 and §10's conclusion |

---

## 0. Why this is being written today rather than someday

Push did not create this gap. It **re-priced** it.

`POST /v1/dm` is find-or-create and authenticated, and that is its only requirement. Block
is deliberately *not* gated at creation — a creation-time refusal would leak block
direction (island design 11, Decision 5, Nick 2026-08-10) — so the block gate sits on the
send. There is no directory (ADR-0004 killed it), but ULIDs leak the ordinary ways: shared
channel membership, mentions.

Yesterday that meant **a stranger could put a message in your list.** As of this morning,
with the APNs VoIP path live on both islands and `should_wake` firing on a DM carrying the
call-invite sentinel, it means **a stranger who knows your ULID can ring your locked
handset.**

Today's mitigations are real and none of them is consent: the ULID is unguessable, the wake
is rate-limited per recipient per minute (and that counter is per-process), and the payload
is a fixed generic string carrying no identity.

Nick was offered the interim — accept it at ~46 known users — and refused it: *"no, do it
now."*

## 1. What is being built, in one line

**A sixth edge in the identity graph: `is-friend-of`. Principal → Principal, mutual,
unbonded, low-stakes, and signed by each side.**

Nick's 2026-08-23 ruling was specifically that this is `friends` as a **first-class
primitive**, not a consent patch bolted to the ring. That ruling is what makes this an
amendment to ADR-0005 rather than a feature.

## 2. Why it cannot be an existing edge

ADR-0005 pins exactly five: `is-credential-of`, `speaks-as`, `vouches-for`, `owns/runs`,
`is-instance-at`. The only Principal → Principal edge is `vouches-for`, and ADR-0006 makes
it **bonded, conserved and slashable**. Friendship cannot be `vouches-for` with the bond set
to zero — a conserved quantity with a zero balance is still a conserved quantity, and
softening the one accountable edge into a casual one would collapse the distinction
ADR-0006 exists to hold.

**The structural observation this rests on, and it is worth stating plainly: aiko has
guardians and bonded vouches before it has friends.** Every person-to-person relation in
either repo today is either negative (`user_blocks`) or high-stakes (`recovery_approvers`
k-of-n, slashable `vouches-for`). There is no low-stakes *"I know this person, they may
reach me"* edge anywhere. That is inverted from how social products usually grow, and is
arguably the right order — accountability cannot be retrofitted, a softer edge always can.

## 3. THE CONFLICT — surfaced, not resolved here

**Nick, 2026-08-25**, closing the friends-bilateral-tie crucible: the island builds nothing,
and *"the one thing the island must never do: **hold the pair**."* A server-side friend table
was rejected in that bundle's own words because *"it IS the queryable social graph."* The
design that survived was **app-local**: a contact list with grades, no island change.

**An app-local friends list cannot gate an island-side push decision.** The island decides
whether to send the wake; if the edge lives only on devices, the island cannot read it.

So the 2026-08-25 ruling and the 2026-09-11 ruling collide, and the collision is real rather
than a wording problem. **This document does not tie-break it.** It proposes a resolution and
names it as needing Nick's confirmation.

### 3a. The proposed resolution: the island HOLDS but cannot FORGE

Each side signs its own acceptance with its Self credential — the same Ed25519 primitive
that already signs every message. The island stores the two signatures and can verify them;
it **cannot mint one**, because it does not hold the keys.

That splits the property that was being defended into its two halves:

- **Un-forgeability** — the island cannot nominate who may reach you. `ring_consent.dart`
  says this in its own words: a list keyed on server-supplied metadata *"is a list the island
  can edit by relabelling a row, which would let it nominate who may wake you."* **Fully
  preserved.**
- **Un-observability** — the island can see who your friends are. **Spent.** And it was
  already half-spent: the island must hold DM membership to route messages at all, so once
  friendship gates DMs, *{your DMs} ≡ {your friends}* and the graph exists whatever any
  ruling says about a separate table.

**Nick answered "the latter" on 2026-09-11 when asked which property the device-local
allowlist was defending — un-observability.** So this resolution spends the property he
named. It is proposed anyway, because the alternative is that the ring cannot be gated at
all; but **it must be confirmed rather than assumed, and it is the single most important
open question in this document.**

**§11a raises the floor under that "proposed anyway", and it is evidence rather than
argument.** The survey found **no shipped or specified system** that renders a server-side
relational ring verdict without learning something about the relation. Of the four known
options, the only one that fully defeats the structural argument — moving the decider onto
the device — was **measured closed for this project the same morning** (`CXError` code 2,
missing filtering entitlement, with a positive control proving the extension ran). The
capability option collapses at 46 users by Orca's own sentence. **So spending un-observability
is not this design choosing a weaker option; it is the option set having one member left.**
That strengthens the case for confirming, and does not make the confirmation ours.

**§11c then splits un-observability again, and the second half lands on this edge harder than
on the conduct gate** — the edge creates a durable enumerable artifact and the conduct
predicate does not. Read it before §8.4.

## 4. Shape of the edge

```
is-friend-of : Principal → Principal
  mutual      — exists only when BOTH sides have signed
  unbonded    — no stake, no slashing, no conservation (that is `vouches-for`'s job)
  low-stakes  — grants reach, never standing
  signed      — each direction carries the granter's signature over
                {grantee principal, granter principal, issued-at}
  revocable   — either side may withdraw; withdrawal is also signed
```

**Principal, not Participant.** ADR-0005's invariant is that every stake, slash, bond and
rate limit is an operation on the Principal graph only. Reach is a rate-limit-shaped thing,
so it belongs there. This also satisfies the requirement `#2792` surfaces: **the edge must be
expressible for an AGENT principal.** Under ADR-0005 Model B a bot holds its own Principal,
so *"Dreamfinder may call Nick"* is exactly this edge, and baking principal-kind into it
would force agents onto a parallel mechanism later.

## 5. What it gates, and what it must not

| Surface | Gated by friendship? | Why |
|---|---|---|
| `POST /v1/dm` (create) | **Yes** | This is the door. A stranger cannot open a channel to you. |
| Sending into an existing DM | Yes, by consequence | No channel, no send. Block remains the separate negative edge on the send path. |
| Ringing / `should_wake` | Yes, by consequence | The whole point. No DM, no invite, no wake. |
| **Friend requests** | **NO — must not be** | Otherwise nobody can ever reach anybody. Needs its own endpoint. |
| Group channels | **NO** | Membership already gates them; friendship is not required to be in a room together. |

**Does a creation-time friendship refusal leak, the way a block refusal would?** No, and the
asymmetry matters. A block refusal leaks *the recipient's* hidden decision. A friendship
refusal leaks only that no mutual edge exists — which the requester already knows, because
they would have had to sign their half. Nothing is disclosed that the caller did not already
hold. **This should still be checked by an adversary rather than accepted on this reasoning.**

## 6. First contact — the part that is genuinely new surface

A friend request must reach someone you have no edge with. That is a new channel, and this
document originally called it *"the spam vector"*. **§11d says that framing is wrong at this
scale**: at 46 known people a stranger-gate has near-zero spam value, and its value is
**consent and interruption control**. The distinction is not cosmetic — a spam frame argues
for rate limits, CAPTCHAs and proof-of-work; a consent frame argues for a legible, revocable,
low-friction decision the recipient makes once. The requirements below are the consent frame's.

- It is **not a DM** and must not create one.
- It **must never ring, never wake, never produce a VoIP push.** A request that could ring is
  the hole wearing a new hat.
- It should carry a small amount of context or it is a blank knock from an opaque ULID.
- It needs a rate limit that is not per-process (today's wake limiter is per-process, which
  is a pre-existing weakness worth not copying).

**What a request carries — the fork was a false one, see §11e.** Free text is a harassment
surface and nothing is a blank knock, but shipped systems take a third path: **show the
identity, neuter the payload.** Signal's Message Requests blur profile pictures and refuse to
linkify URLs on the request screen; Matrix MSC2403 models it as a *knock* with a reason rather
than free text or silence. That is a resolvable design question with prior art, not an open
one — it is carried to §8 as **RECOMMENDED** rather than **OPEN**.

## 7. What this does NOT cover

- **Migration.** Every existing DM predates the edge. Are current DM partners grandfathered
  into friendship, or does the gate apply only to new channels? Grandfathering is almost
  certainly right — the alternative silently severs live conversations — but it means the
  initial friend graph is derived from routing data rather than consented to. **§11e: that is
  exactly what the shipped conduct gate already is** (consent by conduct, computed from
  `Message` rows), and Signal grandfathered existing conversations when Message Requests
  launched. The two answers must match: if derived-from-conduct is unacceptable here it is
  unacceptable for §10, and vice versa.
- **Discovery.** ADR-0004 killed the central directory. If you cannot find someone, you
  cannot friend them. This does not make discovery a requirement, but it does mean the
  friends edge inherits whatever the answer is.
- **Cross-island friendship.** Out of scope; noted so it is not assumed to work.
- **The ring ceiling.** Settled separately: Nick ruled **island** on 2026-09-11, reversing
  design 12's Decision 1c. The Dart constant is now `kInAppRingDuration`, advisory for the
  in-app path only (`e1259f6`); design 16 v2 §2 carries the ruling and the third clock it
  opened.

## 8. Open questions, consolidated

1. **§3 — does the island holding the pair supersede the 2026-08-25 ruling?** Nick's. Highest
   stakes in this document; everything else is downstream.
2. Are existing DM partners grandfathered? (§7) — **RECOMMENDED: yes**, and the answer must
   match §10's, because the conduct gate is already consent-by-conduct derived from routing
   data (§11e).
3. What does a friend request carry? (§6) — **RECOMMENDED: show the identity, neuter the
   payload** (blurred avatar, un-linkified text, structured knock), per Signal and MSC2403
   (§11e). No longer open.
4. **Does the conduct gate (§10) SUBSTITUTE for this edge, or PRECEDE it?** Nick's. Both
   tabs read it as *precedes*; neither should settle it in a design doc. **Two things have
   moved since that reading and both cut the same way:** the 2026-09-11 strike left
   withdrawability carrying *precedes* almost alone (§10), and §11c prices a cost on the edge
   that was never on the books — it creates the durable enumerable artifact Nick objected to
   in 2026-08-25's own words, and the conduct predicate does not. **SUBSTITUTES is a live
   outcome and this document should not be tempered as though it were not.**
5. Does the creation-time refusal leak anything an adversary can see and I cannot? (§5)

## 9. Provenance

Grounded by reading, this session: `claude-tasks#2792` end-to-end including comments,
`docs/adr/0005-identity-graph.md`, `lib/features/call/domain/ring_consent.dart`,
`lib/features/call/domain/call_invite.dart` (`admitRing`'s gate order), the live
`/v1/dm` schema on `chat.imagineering.cc`, and the friends-bilateral-tie crucible OUTCOME in
the island repo.

**Inherited rather than verified, marked as such:** island internals — `should_wake`,
`rest/dm.py:45-47`'s block placement, and the per-process wake limiter — are from `#2792`'s
recorded text and the island tab's messages. This tab has not read island source.

**Amended 2026-09-11 (§11) to fold in `RESEARCH.md`, which this document was written 40
minutes after and originally cited nowhere.** The survey's claims carry their own
`[verified]` / `[secondary]` / `[inferred]` tags at source and that grading is **not** repeated
per line in §11 — read the source before leaning on a figure. Nothing in §11 was
independently re-verified by this tab except the two facts already held here: the NSE
measurement (this session's own spike) and the 2026-09-11 strike of §10's weakness 3.


---

## 10. The conduct gate — answered by the island tab, and better than a stopgap

**Predicate: wake on a call-invite only if the RECIPIENT has previously posted in that
channel.** Consent-by-conduct — *you may ring someone who has spoken to you.*

Expressible today over `Message(channel_id, sender_user_id)`; `channel_id` is indexed, so it
is one query on a path that already runs several. **No new edge, no schema, no ADR.**

### Why it is not merely an interim: it survives E2EE and `should_wake` does not

`should_wake` compares the message body to `CALL_INVITE_BODY` **in cleartext**. When MLS
lands that comparison dies and the island's basis for deciding *"is this a call"* evaporates.
This predicate reads only **who posted where** — never content — and the island still knows
that under E2EE.

So the gate outlives the mechanism it protects. That is an argument for building it whatever
this ADR concludes.

### Three weaknesses, and the first is why it cannot replace the edge

1. ~~**Consent is permanent and unrevocable.** One reply, ever, and that principal may ring
   you forever. There is no un-reply.~~ — **STRUCK 2026-09-11 BY THE TEMPER, AND THIS ONE
   DECIDES THE DOCUMENT.**

   **There is an un-reply: `block`.** It is shipped and enforced *twice* on the wake path,
   read in island source (`domain/push_service.py`, island `main`): `create_outbound` refuses
   a DM send between blocked parties (`BlockedDmSend`) — *"a blocked peer cannot wake you,
   because they cannot get the message written"* — and the fanout independently unions the
   block set (`excluded = set(exclude_user_ids) | blocked`, *"neither is trusted alone"*).

   Raised independently by two families, neither of whom was handed it, then verified against
   source rather than argued. **Withdrawability was carrying *precedes* almost alone after
   weakness 3 fell; it cannot carry it, because it is not a property this edge would add.**

   **The residue, stated honestly, because it is all that is left:** `block` is a *total
   severance*, not a ring-only withdrawal. The true gap is **"revocation is all-or-nothing —
   there is no way to stop someone ringing you while still exchanging messages"**, which is
   already `#3343` (per-conversation ring mute), which this section itself calls *composes
   rather than competes*. **A coarse-revocation gap justifies a mute, not a first-class edge
   in the identity graph.**
2. **It gates the WAKE, not the INVITE.** A connected recipient still receives the invite over
   WSS. It stops the *cold-start ring* — the actual harm — and must be described that way, or
   it will be read as *"this person cannot call you"* and under-deliver.
3. ~~Agents are excluded by default~~ — **WITHDRAWN 2026-09-11, and the withdrawal costs
   this section an argument.** The island tab reported agents would be excluded; their own
   cage-match inverted it. The predicate filters the **RECIPIENT**, not the sender: Nick
   messages Dreamfinder, so Dreamfinder may ring Nick, and the agent need never post at all.
   The behaviour is correct and the weakness recorded here never existed.

   Kept struck rather than deleted because of what it does to §10's conclusion. Three
   weaknesses were offered for why the conduct gate PRECEDES rather than SUBSTITUTES for the
   edge; one is now gone and one (gates-the-wake-not-the-invite) is a scoping note rather
   than a deficiency. **Withdrawability is now carrying that argument almost alone** — which
   is precisely the property the island tab named as the one to attack hardest at this
   document's temper. If it does not survive, the honest conclusion is that the shipped gate
   substitutes and this edge is wanted for reasons other than the ring.

   **And §11c adds weight to the other pan of the scale**, which had nothing in it when this
   section was written: the friends edge creates the durable enumerable social graph Nick
   objected to on 2026-08-25, and the conduct predicate — reading `Message` rows that exist
   for routing anyway — creates none. On behavioural inference the two are equivalent; on the
   axis of his original objection the edge is strictly worse.

### An island constraint any design here must respect

**`project_no_refused_ring_record`, Nick 2026-09-01: the island keeps no record of who called
whom; blocked rings are dropped.** A refused ring is a **log line at most, never a stored
row.** Anything wanting to notify a refused caller, or rate-limit repeat attempts by pair,
collides with that ruling head-on. The conduct predicate fits; a naive abuse-counter would
not.

### Where it does not reach

It closes the **stranger** case cleanly and does nothing about someone you *have* accepted
ringing you at 3am. That is `#3343` (island-side per-conversation mute) — smaller, different,
and composes rather than competes.

### Deployment state — merged is not deployed

**Island `b7dafac` is MERGED and deliberately NOT DEPLOYED** (Nick: *"let it ride"*). Both
live boxes serve v0.11.0, which does **not** carry the gate, so **both islands still wake for
a stranger today**. Nothing rings only because the client CallKit half is unbuilt.

So #4216's ruling is a **deploy gate, not a merge gate**: the ring goes live only when the
client half ships AND the island it meets is serving the gate. The cheap check is `/health`
reporting a `ref` **later than v0.11.0** — it reads the box, not the repo, which is the only
reading that counts. Testing ring behaviour against a live island today tests the PRE-gate
island: right about the box, wrong about `main`.

### Build note

Trust boundary on a live wake path, so cage-match by law, and it ships with its own must-fail
arm: **a test proving a first-contact invite does NOT wake.** Without that arm the gate's
success value and its not-running value are the same silence.

---

## 11. Prior art — commissioned, and it changes four sections

`RESEARCH.md` (2026-09-11) surveyed first-contact gating, sender-anonymity and private wake
gating against primary sources. It was commissioned ~40 minutes before this document was
written and **this document originally cited none of it**, which is why several things below
were derived from scratch that were already settled in the literature. Every claim here is
tagged in the source as `[verified]` / `[secondary]` / `[inferred]`; that grading is not
repeated per line, so **read the source before leaning on a number**.

### 11a. The survey's conclusion is inverted by its own appendix, and this is the load-bearing fact

The survey's headline names **four** ways a system can handle a relational ring gate, and
finds **no shipped or specified system** that renders a server-side relational ring verdict
without learning something about the relation:

| Option | Who does it | What it costs |
|---|---|---|
| **(i) Accept the leak** | Matrix, Threema | The server knows the relation |
| **(ii) Capability, not identity-pair** | Signal delivery token, SimpleX queue address, Orca | Leak narrows from a *pair* to a *set* |
| **(iii) Drop the capability** | Briar — no push at all | No ring on a cold handset, ever |
| **(iv) Move the decider off the server** | Apple's `alert` → NSE → CallKit path | Nothing — *"the only listed option that is genuinely scale-free"* |

The survey calls **(iv) the only escape that fully defeats the structural argument**, because
it removes the decider rather than hiding it in a crowd.

**(iv) was measured closed the same morning** — `RESEARCH.md` § *RESOLUTION*, 08:30 AEST:
`reportNewIncomingVoIPPushPayload` returns `CXErrorCodeNotificationServiceExtensionError`
**code 2, missing notification-filtering entitlement**, with a positive control
(`didReceive FIRED`) proving the extension ran. The entitlement is Apple-granted and an
applicant fitting Apple's own stated rationale exactly was rejected twice. This project's case
is strictly weaker: our server *can* tell it is a call, and our media is not E2EE.

**(ii) collapses at this scale**, and the collapse is stated in the primary source rather than
inferred — Orca (USENIX Security '22, Tyagi–Len–Miers–Ristenpart):

> "access keys must be distributed over non-sender-anonymous channels, meaning **the platform
> learns the identities of users who can send sender-anonymous messages to a particular
> recipient**. This significantly lowers the anonymity guarantee — **in the limit of having
> only a single contact, there is no anonymity at all.**"

Orca's headline improvement expands the anonymity set to *all registered users* — which here
is **46**. And the survey notes the polarity is against us twice over: Orca is a **blocklist**
(default-allow, non-membership proof); the friends edge is an **allowlist** (default-deny,
membership proof), for which **no published analogue was found**, and whose anonymity
arithmetic is *worse* because the set shrinks from "all users" to "my friends".

**So the option set actually available to this project is (i) or (ii)-at-46-users or (iii).**
That is the fact §3a needed and did not have.

### 11b. Matrix is the confirming case, and §0 independently reinvented its resolution

Matrix — the largest open federated messaging system — puts the gate **squarely on the
homeserver and accepts the leak**. Push rules are evaluated on the homeserver, which stores
the user's rule configuration; MSC4155's invite-permission config lives in server-side account
data. **The privacy work went into the PAYLOAD, not the PREDICATE:** the `event_id_only` push
format sends only `event_id`, `room_id`, counts and devices, so the *push gateway* learns
little while the *homeserver* knows everything.

§0 already records our payload as *"a fixed generic string carrying no identity"* — which is
`event_id_only`, arrived at independently and presented without the precedent that would have
made it cheap.

**The threat models are not the same and the difference is the interesting part.** Matrix
treats the homeserver as trusted and the *push gateway* as the adversary; here the island
operator is the party the relation is being hidden from. So Matrix confirms the *shape* of
the resolution (gate on the server, harden the payload) while being silent on our actual
question. Cite it for the shape, not for the threat model.

### 11c. A distinction this document conflates, and it puts a real cost on the edge

The survey names it directly, as a correction to the framing it was handed:

> the operator's objection was to a server-side friend table because "it IS the queryable
> social graph." That objection is about a **durable, enumerable artifact**. The structural
> argument is about **inference from behaviour**. These are different harms with different
> mitigations.

§3a splits un-forgeability from un-observability and stops. **Un-observability splits again**,
and the two halves land differently on the two mechanisms in this document:

| | Durable enumerable artifact | Inference from behaviour |
|---|---|---|
| **Conduct gate (§10)** | **Creates none.** The predicate reads `Message(channel_id, sender_user_id)` rows that exist for routing regardless | Yes — the island learns who may ring whom, by answering |
| **Friends edge (§1)** | **Creates one.** A signed, mutual, enumerable Principal→Principal table — precisely the artifact Nick named on 2026-08-25 | Yes, identically |

**This is a cost on the friends edge that §10 never priced, and it cuts toward SUBSTITUTES.**
The two mechanisms are equivalent on behavioural inference and are *not* equivalent on the
durable artifact — the edge is strictly worse on the axis of Nick's original objection. Set
against §10's remaining argument (withdrawability, now carrying *precedes* almost alone after
the 2026-09-11 strike), this is the sharpest thing the temper has to weigh. **It is put here
as a cost, not as a verdict** — §8.4 is Nick's, and a SUBSTITUTES outcome is live.

### 11d. What a stranger-gate is FOR at 46 users — §6's framing is wrong

§6 calls first contact *"the spam vector"*. The survey, on household scale:

> At 46 known people, a stranger-gate has **near-zero spam value; its value is consent and
> interruption control, not abuse mitigation.**

And on moderation: at this scale **out-of-band social moderation is available** in a way it is
not at internet scale. The survey flags `NOT FOUND: literature on whether household-scale
systems need cryptographic abuse mitigation at all` — every paper it read assumes an
adversarial open population.

This is not a wording note. A spam frame argues for cheap high-volume defences (rate limits,
CAPTCHAs, proof-of-work); a consent frame argues for a legible, revocable, low-friction
decision the recipient makes once. **§6's requirements follow from which frame is right**, and
at this scale the survey says consent.

### 11e. §6 and §7 have prior art with concrete answers, so they should be resolved, not deferred

**§6 — what a friend request carries.** The document offers only the fork *free text is a
harassment surface / nothing is a blank knock*. Shipped systems take a third path — **show the
identity, neuter the payload**:

- **Signal Message Requests** (Aug 2020): non-contacts are accept/reject before they can
  converse; **profile pictures blurred**; **URLs not linkified on the request screen**;
  repeated reports trigger a CAPTCHA proof-of-humanity. The identity is shown; the payload is
  defanged.
- **Matrix MSC2403 knock** (room v7): request admittance without an out-of-band invite — a
  structured knock, with a reason, rather than free text or silence.
- **MSC4155 invite filtering**: granular, account-data-driven, `m.invite_permission_config`,
  refusal surfaced as `M_INVITE_BLOCKED`.

**§7 — grandfathering.** §7 worries that a grandfathered graph is *"derived from routing data
rather than consented to"*. **That is exactly what the shipped conduct gate is** — consent by
conduct, computed from `Message` rows — and it is the norm rather than an irregularity:
Signal's Message Requests grandfathered existing conversations at launch. If derived-from-
conduct is unacceptable for the edge, it is unacceptable for §10, and vice versa; the two
answers must match.

**Direction of travel, for whichever way §8.4 goes.** `NOT FOUND: any case of a shipped
first-contact gate being withdrawn.` Signal added Message Requests in 2020, WhatsApp added
Silence Unknown Callers in 2023, Matrix has been layering invite filtering since — and
MSC4155's own discussion notes invite-spam proposals more than five years old (MSC2270,
MSC3840, MSC3847, MSC3659, MSC4264), which is evidence of *difficulty*, not of reversal.

### 11f. What the survey could NOT establish — the honest other half

Load-bearing absences, carried verbatim so they are not mistaken for settled:

- **No published onboarding/discoverability cost figures for any shipped first-contact gate.**
  Nobody has released the funnel numbers. §7's discovery concern has no industry number to
  lean on, in either direction.
- **No published allowlist analogue of Orca.**
- **No sealed-sender anonymity analysis at populations below ~1,000** — every analysis found
  assumes internet scale.
- **Not verified** whether WhatsApp's Silence Unknown Callers filters on-device or server-side
  (the call still landing in the call list is weak evidence for on-device).
- **Not found**: how SimpleX handles iOS incoming calls specifically — whether PushKit/CallKit,
  and where the ring decision is made. The one gap most worth closing directly against source.
- **Not found**: any XMPP / Tox / Wire / Jami specification addressing private ring gating.

### 11g. How this document came to cite none of it

The research agent labelled §4 (iOS push mechanisms) *"the highest-value section"*. That
section was mined; the other four were not, and design 19 was written 40 minutes later from
first principles. **A highest-value flag on one section is not a low-value flag on the
others** — the flag became permission to skip. Recorded here because the same shape will
recur the next time a survey comes back with a section marked.
