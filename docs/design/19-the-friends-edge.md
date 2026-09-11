# Design 19 — the friends edge

| | |
|---|---|
| **Status** | DRAFT, un-tempered. Nothing here has survived a cross-family adversary. |
| **Owner** | Claude (app tab), 2026-09-11 |
| **Rulings it implements** | Nick 2026-08-23 (friends is a first-class primitive); Nick 2026-09-11 08:41 (build the gate before the ring ships) |
| **Homing** | The ADR amendment belongs in `geekscape/aiko_chat` per the 2026-08-23 homing ruling. This document is the app tab's draft of it, not the ADR. |
| **Tracks** | claude-tasks#2792, #4216, #3343 |

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

A friend request must reach someone you have no edge with. That is a new channel and it is
the spam vector.

- It is **not a DM** and must not create one.
- It **must never ring, never wake, never produce a VoIP push.** A request that could ring is
  the hole wearing a new hat.
- It should carry a small amount of context or it is a blank knock from an opaque ULID.
- It needs a rate limit that is not per-process (today's wake limiter is per-process, which
  is a pre-existing weakness worth not copying).

**Open: what a request carries.** A free-text note is a harassment surface. No note at all
makes requests unactionable. Not resolved here.

## 7. What this does NOT cover

- **Migration.** Every existing DM predates the edge. Are current DM partners grandfathered
  into friendship, or does the gate apply only to new channels? Grandfathering is almost
  certainly right — the alternative silently severs live conversations — but it means the
  initial friend graph is derived from routing data rather than consented to.
- **Discovery.** ADR-0004 killed the central directory. If you cannot find someone, you
  cannot friend them. This does not make discovery a requirement, but it does mean the
  friends edge inherits whatever the answer is.
- **Cross-island friendship.** Out of scope; noted so it is not assumed to work.
- **The ring ceiling.** Settled separately: Nick ruled **island** on 2026-09-11, reversing
  design 12's Decision 1c. `kCallRingDuration` becomes advisory for the in-app path and must
  be renamed to say so.

## 8. Open questions, consolidated

1. **§3 — does the island holding the pair supersede the 2026-08-25 ruling?** Nick's. Highest
   stakes in this document; everything else is downstream.
2. Are existing DM partners grandfathered? (§7)
3. What does a friend request carry? (§6)
4. **Does the conduct gate (§10) SUBSTITUTE for this edge, or PRECEDE it?** Nick's. Both
   tabs read it as *precedes*; neither should settle it in a design doc.
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

1. **Consent is permanent and unrevocable.** One reply, ever, and that principal may ring you
   forever. There is no un-reply. *"I answered them once in 2024"* is not consent today, and
   **this is precisely what the primitive gives you that the proxy cannot.**
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
