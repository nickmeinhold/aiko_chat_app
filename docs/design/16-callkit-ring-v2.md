# Design 16 v2 — the CallKit ring, client half (the recast)

**Status:** RECAST OF RECORD. Supersedes [`16-callkit-ring-the-client-half.md`](16-callkit-ring-the-client-half.md)
(v1, struck 4/4 on 2026-09-01 — verdict in [`16-callkit-ring-TEMPER.md`](16-callkit-ring-TEMPER.md)).
v1 remains in the repo as the record that earned this one; it is not the design to build from.

**Tier:** trust boundary. `admitRing` is the app's single trust decision and this design moves
part of it into Swift. Cage-match by law before any of it merges.

**AMENDED 2026-09-11 (v3) by [`20-the-sealed-ring-envelope.md`](20-the-sealed-ring-envelope.md).**
§0's flaw-2 bullet, §1's admission input and §4's UUID contract were all written against a
payload that does not exist. Design 20 supplies the missing input — a **sealed envelope** — and
the island tab has accepted it **in principle, with conditions** (design 20 §8). It is **not
built and not blessed**: §4a's key material has not been seen by a cryptographer, and nothing
below should be implemented ahead of that.

**Peer record:** `../aiko-chat-island/docs/design/12-native-call-ui-callkit-connectionservice.md`.
Where this document disagrees with design 12 the disagreement is **marked and surfaced**, never
folded in silently — see §2, which reverses one of design 12's recorded assignments and does not
have the standing to do so alone.

**Decision of record it rests on:** Nick, 2026-08-29 — an incoming call must ring the handset
natively (claude-tasks#3609). Unblocked by Nick, 2026-09-01 — *"default-off for groups,
default-on for DMs with friends."*

---

## §0 — What v1's strike settled, and what it did not

The flaw-5 decision dissolved v1's headline crisis. Recorded here so nobody re-derives it:

- **Flaw 1 is not a trust-boundary dilemma.** v1 reasoned *CallKit rings before Dart exists →
  verification cannot precede the ring*. That is a fact about the Flutter engine wearing the
  costume of a fact about the device. Swift is alive in
  `pushRegistry(_:didReceiveIncomingPushWith:)`; Ed25519 verification is CryptoKit and takes
  microseconds; the consented key set is small, device-local and known before the push lands.
- **Flaw 2 is not a contradiction** — ~~Proof needs nothing from the payload, so design 12
  Decision 6's opacity survives intact.~~ **STRUCK 2026-09-11. The CONCLUSION holds and the
  REASON was false**, which is the worst shape for a sentence to survive in.

  **Proof needs EVERYTHING from the payload.** The island's `_render` emits
  `{"aps": {...}, "c": channel_id}` and its own docstring says `"c"` is the only custom field,
  so Swift had no signed bytes to verify and this document's whole admission architecture had
  no input. Read in island source 2026-09-11; the island tab confirmed it the same day.

  **Decision 6's opacity does survive — by encryption, not by omission.** Design 20's arm C
  puts the signed invite in the payload **sealed to the callee**, so Apple sees ciphertext and
  *"nothing about who-calls-whom on Apple's wire"* stays true as Decision 6 words it.

  **Why this survived a 4/4 temper:** the sentence was TRUE about its object (opacity survives)
  and false about its mechanism, and a design temper interrogates the claims it is handed. The
  claim *"there are signed bytes in the payload"* was never stated, so it was never struck.
- **The privacy cost v1 priced against arm (iii) does not exist.**
  `lib/features/call/data/ring_allowlist_store.dart` is device-local by design and publishes
  nothing. Nothing about ring consent reaches the island.

**What that buys, stated at its real strength and no higher.** The property is
**"no *sustained* ring before proof"** — not "no ring before proof". Every VoIP push must be
reported to CallKit before the delivery handler returns, so the arm is
*verify → report → immediately end on failure*, never *verify-or-silence*. A forged or
unverifiable push still produces a momentary ring. That residual is not cosmetic: it is the
input to flaw 9 (§7), where a sustained report-and-end pattern costs VoIP delivery on the
affected device (see the correction at §7a — not fleet-wide).

The gate v1 adopted — *no `CXProviderDelegate` line until flaw 5 is decided* — is **spent**,
its stated condition having cleared on 2026-09-01. Note for anyone reading the tracker: the
"hard gate adopted by both repos" line on claude-tasks#3745 is dated 2026-08-31T23:02, **hours
before** the ruling, and is a stale re-affirmation rather than a live gate.

---

## §1 — The admission architecture: Swift admits, Dart maintains

The ring authority is a Swift handler. v1 kept legislating in Dart; that is the thing this
recast changes.

```
VoIP push ──► pushRegistry(_:didReceiveIncomingPushWith:)   [Swift, always alive]
   │             │
   │             ├─ OPEN the sealed envelope  (device key)   ◄── design 20 arm C
   │             ├─ read App Group state  (consented keys · ends · mute · block)
   │             ├─ verify Ed25519 over the signed bytes         (CryptoKit)
   │             ├─ reportNewIncomingCall(with:update:)          (MANDATORY, always)
   │             └─ on failure: reportCall(with:endedAt:reason:) (immediately)
   │                                                     │
   └─ carries: "c" (channel) + a SEALED ENVELOPE         │
      holding the signed invite and the call id          │
                                                          │
Dart, when it next runs ──► maintains the App Group cache ◄┘
```

**The first line is new and it is the whole amendment.** Until design 20 this diagram's
verify step had no input: the payload carried a channel id and nothing else. *Where the
signed bytes come from* was never written down in either repo, which is how it went unnoticed
through a four-family temper — see §0's struck flaw-2 bullet.

**The division of labour is the design.** Swift owns *this ring, right now*, from bytes plus
cached state, with no isolate. Dart owns *what the cache contains*, on its own schedule. The
two never contend for the same decision.

### 1a. The App Group cache — contents and owner

One container (`group.cc.imagineering.aiko`), written only by Dart, read by both.

| key | contents | Dart writer | why Swift needs it |
|---|---|---|---|
| `consented_keys/<channelId>` | multikeys consented for this conversation | `RingAllowlistStore` on every consent change | the verify set |
| `ends/<islandMsgId>` | signed ends seen, with `at` | `RingController` on each admitted end | cold-start liveness (§3) |
| `muted/<userId>` | muted conversation ids | `ConversationMute` | mute must survive cold start |
| `blocked/<userId>` | blocked multikeys | moderation repo | defence in depth |
| `names/<channelId>` | display name for the ring UI | roster updates | caller name (§6) |

**This cache is a new on-disk artifact with a new exposure** — a plaintext map of channel id →
human name and consented keys, readable without the app running. It belongs in the
visibility-boundary doc (claude-tasks#3695) as a stated boundary, not discovered by it.

### 1b. The gate that must NOT move to Swift

`admitRing` carries nine start-gate refusals (enumerated from the `RingRefusal` enum, not its
prose — the doc comment names five). Swift replicates the four that can be answered from bytes
plus cache: `unverifiedOrigin`, `originMissing`, `senderBlocked`, `conversationMuted`.

The rest stay in Dart and run when the isolate wakes. **Two enforcers of one predicate is the
drift shape this repo keeps paying for**, so the Swift set is deliberately the *smallest* set
that makes the ring honest, and every constant it uses crosses the method channel as a value
rather than being re-declared in Swift.

### 1c. The crack this opens, and it is real

**Key-set freshness at wake time.** Swift reads a cache Dart maintains. A caller consented to
five minutes ago, on a handset that has not foregrounded since, **is not in it** — so a
legitimate ring fails proof and is ended immediately. The user experiences a phone that rang
for a quarter-second and stopped.

v1 left this open and it is still open. Three candidate answers, none chosen:

- **(a) Write-through on consent.** `RingAllowlistStore` writes the App Group synchronously in
  the same operation that grants consent. Closes the window for consent granted *on this
  device*; does nothing for consent granted on another.
- **(b) Accept and disclose.** First ring from a newly-consented caller may fail; the second
  succeeds. Cheap, and honest only if the settings copy says so.
- **(c) Grace arm.** Report the call, and let Dart adjudicate within a bounded window before
  Swift ends it. Recovers the legitimate case at the cost of extending exactly the
  ring-before-proof interval §0 just bounded.

**Recommendation: (a), with (b) as the stated residual for multi-device.** (c) is listed to be
rejected explicitly rather than silently — it trades the one property this design bought.

---

## §1d — The trilemma — **STRUCK 2026-09-09; REVISION DELIVERED 2026-09-11, see §1e**

> **DO NOT BUILD OR CITE THIS SECTION.** The `/design-temper` on island design 12a
> (4/4 RECAST) struck the dissolution below, and the strike holds. Tesla: *"The trilemma did
> not dissolve; it was recategorized into a cell Apple does not sell."*
>
> **What survives:** the three-outcome table is factually right about what the device *can do*.
> Swift can **decide** sustain-vs-retract before reporting.
>
> **What fails, and it is the load-bearing half:** Swift cannot **enact** silence.
> `reportNewIncomingCall` is an async RPC to SpringBoard, and `reportCall(endedAt:)` races
> "unknown UUID" before completion against a full-screen flash after it. More decisively,
> **report-and-immediately-end IS the iOS 13 abuse pattern the must-report rule was written to
> kill** — an app taking a VoIP push and not ringing. So flaw 9 is not a ratio to tune; routing
> refused callers through that cell is doing the prohibited thing systematically, and the
> consequence is per-device denial of VoIP delivery (corrected at §7a; the strike said
> fleet-wide revocation and that was never checked).
>
> **The precise error was mine and it is about spendability, not physics.** The momentary cell
> exists; it is a **malformed-push failure mode**, not a destination a design may route refused
> callers into. §0's downgrade ("no *sustained* ring before proof") is as far as the claim goes.
>
> **Consequence: refusal cannot be routed through the device**, which puts the trilemma back
> where the island tab found it. The revision is owed and is not attempted tonight.
>
> **Diagnosis worth keeping** (island tab's, and it indicts both tabs equally): *"we both needed
> a third cell to keep device-local consent and VoIP in the same design."* My §1d and their
> headline were the same wish, reached independently — which is precisely why agreeing with each
> other proved nothing.
>
> **(C) is NOT the escape.** Moved to a research appendix in 12a, on Tesla's warning that
> *"production will grab it at the first Apple warning, long before anyone who does this for a
> living has spoken."* Its unlinkability is not low-confidence, it is **spent**: the island
> stores an attributable invite on a named channel and holds the device token, and on a
> self-hosted island the anonymity set is a household.

## §1e — The owed revision, and two facts delivered it rather than an argument

**This discharges claude-tasks#4181.** §1d's strike ended *"refusal cannot be routed through
the device… the revision is owed and is not attempted tonight."* The revision was not written
that night because the missing piece was not an argument. **Two things shipped since, and
between them the question dissolves.**

### Fact 1 — the conduct gate is DEPLOYED, so the island now produces silence

**2026-09-11 ~14:41 AEST, v0.11.1, both islands.** Verified by this tab rather than taken on
report: `/health` reads `ref=v0.11.1` / `git_sha=4539cfe9` on `chat.enspyr.co` and
`chat.imagineering.cc`, and `git merge-base --is-ancestor b7dafac 4539cfe9` is **true** — the
gate is in the *running* build, not merely on `main`.

§1d's table said the `silent` outcome is producible by **the island only**. **It now is.** A
stranger's invite produces no push at all, so there is no device-side refusal to route.

### Fact 2 — arm C changes WHAT the device is refusing

Design 20: with the gate live, Swift's verification no longer answers *"may this stranger ring
me"* — the island answered it upstream. It answers **"is this island lying to me?"**

**That is what retires the strike's objection.** §1d was struck because routing *refused
callers* through report-and-immediately-end is the iOS 13 abuse pattern the must-report rule
exists to kill — doing the prohibited thing **systematically**. Under the deployed gate the
device-side end fires only on a **forged or hostile-island push**, which is a malformed-input
failure mode and not a population being routed through it.

**Which is exactly the distinction §0 drew and §1d's strike affirmed:** *"The momentary cell
exists; it is a malformed-push failure mode, not a destination a design may route refused
callers into."* The strike was right, and the DEPLOYMENT is what moved this design off that
destination — not a re-argument.

### What this does NOT settle, stated plainly

- **The report-and-end ratio is now an ASSUMPTION WITH AN OWNER, not a measurement.** "Forged
  pushes are rare" is load-bearing for flaw 9 and nobody has a number. The island tab named
  this as the thing someone has to own; **this document owns it and does not pretend to have
  measured it.** If the ratio is ever non-trivial in the field, flaw 9 returns unchanged.
- **A + B + C′ survives intact.** Arm C adds confidentiality to bytes that had to travel
  anyway; it changes nothing about who can produce which outcome.
- **The blind-signed capability arm stays available and stays unadopted**, on its original
  three objections — the revocation asymmetry is still disqualifying in that shape.

---

## §1d (struck) — the original argument, kept as the record

Framed by the island tab (2026-09-09), and it is the sharpest statement of what §1c and design
12's Decision 4 are circling:

- **(A)** A ring is earned by an established relationship.
- **(B)** `RingAllowlistStore` is device-local and publishes nothing.
- **(C)** The ring/no-ring fork sits at the island's send door, because there is no on-device
  window in which to reconsider.

*"The decision has to be made where the fact isn't. Any two work, all three don't."*

**They are contradictory only if ring/no-ring is binary. It is not.**

| outcome | who can determine it |
|---|---|
| **silent** — no push ever leaves the island | island only |
| **momentary ring** — VoIP sent, Swift verifies, fails, ends immediately | device only |
| **sustained ring** — VoIP sent, Swift verifies, passes | device only |

Device-local consent fully determines *momentary vs sustained*. **That is the on-device window
(C) says does not exist** — bounded to the report-then-end interval, but real. Only
*silent vs momentary* requires a decision where the fact is not.

So A + B + C-as-stated is contradictory, and **A + B + C′ is consistent**, where C′ is the
narrower true claim: **only the island can produce silence.** That is §0's "no *sustained* ring
before proof" restated as a topology rather than a caveat.

**The question the dissolution leaves is not "which two do we keep" but "what is a momentary
ring worth, and to whom?"** Two costs with different owners:

- **The user** — a quarter-second buzz through silent mode and DND from someone they refused.
  Bounded, and it is exactly the harassment surface, and it is *observable by the attacker*.
- **Us** — flaw 9 (§7a). A sustained report-and-end pattern costs VoIP delivery per device.

### The escape arm, kept open and not adopted

The island tab's pick is a **blind-signed ring capability** — the island verifies a capability
it cannot read, so a refused caller gets *silence* rather than a momentary ring. That is the
only mechanism on the table that buys the first row of the table above, so it stays alive.

**Three objections, recorded so the arm is not adopted by default:**

1. **Revocation asymmetry — disqualifying in this shape.** Device-local consent revokes at the
   enforcement point, instantly, by the person being woken. A minted capability sits **in the
   caller's hands** and cannot be revoked, only expired — inverting who holds the off switch in
   a mechanism whose whole purpose is that the sleeper controls it. Not hypothetical:
   **claude-tasks#3521** is open on exactly this class (*"revoking consent mid-ring makes the
   hangup unadmittable — the ring runs its full 30s"*). Short expiry is the only fix; short
   expiry needs frequent re-minting; re-minting needs a live channel, which a locked handset
   does not have. The island tab's own key-staleness worry and this are one defect seen from
   two ends.
2. **The ruling it cites does not reach it.** Nick's 2026-08-25 sender-anonymity ruling is about
   what the island *learns*, not about what gates a ring. claude-tasks#3745: *"This decision
   makes the ring SAFE without making it ANONYMOUS — the app tab had bundled those and they are
   orthogonal."* Reading it as a mandate for a consent mechanism re-bundles what that comment
   unbundled. **And the sentence after it cuts harder against the capability arm than anything
   either tab argued:** *"restricting the caller set SHRINKS the anonymity set. Friends/consent
   makes the island's picture of who-rang-whom more precise, not less."*
3. **Distribution.** A capability must reach the caller over some channel, which is a new trust
   surface. Device-local consent needs no distribution at all — its main virtue, not an
   incidental one.

**Position: A + B + C′ is this design's spine.** The capability arm is the named escape **if
flaw 9 measurement shows the report-and-end ratio is untenable** — a measurement, not a
preference. Neither document should harden around it before that number exists.

## §2 — The ring ceiling: design 12's Decision 1c inverts. **DECIDED — the island owns it.**

Design 12 records:

> A CallKit ring is system UI drawn before Dart exists and **does not self-expire**... **The
> app tab owns re-establishing it and has taken it.**

**That assignment was made against a mechanism that cannot run.** The app is suspendable the
instant the CallKit report completes. A Dart `Timer` needs an isolate the OS has not started;
a Swift timer is in a process iOS may suspend the moment the handler returns. Neither is an
enforcer. Today's derivation in `RingController._republish()` is the right *shape* — deadline
computed from the signed `signedAtMs`, never restarted, so no rebuild extends a ring — and the
derivation is worth keeping wherever it ends up running.

**THE RULING. Nick, 2026-09-09 21:43 AEST (*"yep"*), re-affirmed 2026-09-11 08:41 (*"island"*):
the island takes the ceiling and enforces it with a ring-lease expiry.** This reverses island
design 12's Decision 1c. It is not a preference between two workable designs — the app
*provably cannot* enforce it, per the paragraph above, so there was one candidate enforcer and
the decision names it.

**This section said "SURFACED, NOT DECIDED" for two days, and that cost a round.** The doc was
authored 2026-09-09; the ruling landed at 21:43 the same day and never reached the page. On
2026-09-11 the app tab read this section, believed the question open, and put it to Nick as a
fresh decision — so he answered it twice. **A re-ruling that reads as fresh is how a settled
decision quietly gets re-litigated.** The record was the tell and this repo did not hold it;
the island tab did. The original framing is preserved below rather than deleted, because the
reason it was framed that way is still correct and still binding on the next such call.

> **The framing that produced the question, kept as the record.** The island tab's position
> (2026-09-09, cross-tab) was that the island takes the ceiling back, on the reasoning that an
> enforcer which exists beats a contract line that reads well and does nothing; the app tab
> agreed on the engineering. **Two Claude tabs concurring is not corroboration** — a wrong
> answer wearing two signatures survives review better than either error alone, because the
> second signature reads as verification. It reversed a recorded decision in a peer repo's
> design of record. So it was put to Nick with both positions rather than tie-broken by mutual
> agreement between the two parties who would be relieved of the work. That was right, and the
> answer came back the same evening. Routed as claude-tasks#3744 finding 1.

### What the ruling has already cost downstream, and what it has not yet

**DONE (`e1259f6`, on `main`):** `kCallRingDuration` → **`kInAppRingDuration`**. The constant is
advisory for the in-app ring only; it never bounded the CallKit ring and now says so. The
pinned two-clock invariant of §3a was **restated, not retired**, in the same commit — the
2026-08-15 reasoning holds unchanged for the path the constant now names: an invitation still
fresh enough to ADMIT must still have ring time left, or the app admits a call and immediately
stops ringing it.

**OPEN — the third clock, and it is not fixable in this repo.** The island's ring lease now
bounds a CallKit ring this process cannot end, and **that value is not on the wire.** Nothing
here can assert against it. A lease shorter than `kCallInviteFreshness` lets the island ring a
handset for an invitation this app would refuse as stale, and the two halves then disagree
about whether a call is happening — the exact conflation Nick named on 2026-08-15, reachable
again one layer out. No test on either side alone catches it. It belongs in the cross-repo
contract: either the lease crosses the wire, or both sides pin against a shared constant with a
drift test. Filed as **claude-tasks#4233**.

---

## §3 — Cold-start liveness: the case this design exists for

Temper flaw 6, and v1 got it wrong. v1's §2 argued the liveness object already exists as a
signed end held in `RingController._ended`. It does not survive the case that matters:

```dart
// ring_controller.dart:78
final Map<String, List<({CallEnd end, DateTime at})>> _ended = {};
```

Plain in-memory Dart state. **Empty by construction on a push-woken cold start** — and the
controller's own docstring says push makes that the *normal* case rather than the exotic one:
*"the island wakes a handset on the INVITE body only, so a cold start processes the invitation
first by construction and the end is an ordinary afterthought."*

**It is worse than a cold-start problem, and v1 missed this too** (caught by the island tab,
2026-09-09, verifying rather than conceding). `_forget` bounds `_ended` to
`kCallInviteFreshness * 2` on the **warm** path as well, with its own comment saying so:
*"this can only ever hold the last few seconds of calls."* So the signed end is not merely
absent on cold start — **it has a seconds-wide applicability window always.** The honest
statement of the occupancy case (claude-tasks#3159) is therefore not "occupancy covers an
edge": it is **the sentinel has a seconds-wide applicability window and occupancy does not.**

A ring has three endings (ceiling, signed hangup, post-hoc refusal) and v1 moved only one of
them to the layer that is actually alive.

**Design: the App Group end-buffer** (`ends/<islandMsgId>` in §1a). The end-wake writes it;
Swift reads it before reporting and ends the call immediately if the invite it names is
already ended. No isolate in the path.

**And the retention bound has to move with it.** `ring_controller.dart:91` currently forgets a
held hangup after `kCallInviteFreshness * 2` (20s), with the stated reason *"an end is only
useful while its invitation could still be ADMITTED"*. That reason is right and is exactly why
the bound must change: under CallKit an invitation can be admitted for as long as the phone is
ringing. A hangup garbage-collected at 20s while a 30s ring is audible is **a phone ringing for
a corpse because we forgot the stop**.

New bound: **the island's ring lease** + `kPushDeliverySlack`. Written against a local
constant before §2 was decided; with the ceiling on the island the first term is **not a value
this repo holds**, which makes this bound the second live
instance of the third clock (§2, claude-tasks#4233) rather than an arithmetic fix. Until the
lease crosses the wire the honest implementation is a bound the app cannot derive — so this is
**open, and blocked on the cross-repo contract, not on a number**.

> **`kPushDeliverySlack` still has no value and no derivation.** It is the honest name for a
> number this design needs and has not earned: *how late can a stop arrive and still matter?*
> It cannot be picked at the keyboard. The one measured input available is the 17.55s
> observed on 2026-08-31 between a caller pressing call and the tap arriving — which is a
> calibration input for the ring *duration*, not for delivery slack. **Open.**

### 3a. The pinned two-clock invariant must be replaced in the same commit — **DONE, `e1259f6`**

**Discharged as specified.** The rename landed with the invariant restated in the same commit,
the 2026-08-15 reasoning shown to still hold for the path the constant now names, and the hole
the rename opens (the third clock) written into the test file as a named absence rather than
left unexamined. The requirement below is kept because it binds the next such move.

`call_invite_test.dart:996` pinned `kCallRingDuration > kCallInviteFreshness`, in a group named
*'the two clocks are different numbers'*, with Nick's 2026-08-15 reasoning in the comment
above it. If the clocks collapse, both lines go red **correctly**.

The failure mode is someone deleting the group to make the suite green, which retires an
invariant instead of replacing it. **Replacement is same-commit, never a later one**, and the
2026-08-15 reasoning must be shown to still hold under the replacement rather than deleted
with it.

---

## §4 — The UUID map: `payload UUID ↔ signed ULID ↔ end-key`

Temper flaw 8, and it is currently unwritten in **both** documents.

Swift must report a `UUID` before proof, and it comes from the island's push payload, not from
the signed body. Two failures follow if the map is left implicit:

- **Payload ULID ≠ signed ULID** ⇒ `reportCall(with:endedAt:)` cannot find the ringing call,
  and §3's whole end-buffer is theatre.
- **Payload reuse of a live UUID** ⇒ identity-as-mutable-key: call N stops call N−1, or two
  invites collapse into one system call.

> **AMENDED 2026-09-11 (v3).** The contract below was written against a payload carrying a
> cleartext id. Under design 20 arm C **the call id ships INSIDE the sealed envelope**, and
> that change is strictly in this section's favour — see §4c. Points 1 and 3 stand unchanged;
> point 2's corrected rule is *superseded, not wrong*, and is kept because the reasoning that
> produced it is what makes §4c safe.

**The client contract, stated:**

1. The caller mints the call id **client-side** as a ULID in the signed invite body
   (`aiko:call/2 <ulid>`). ULID is 128 bits → lossless as a `UUID`. Zero island schema.
2. ~~The island carries that id verbatim in the push payload. It is **not** authoritative — it
   is a lookup hint. Swift verifies the signed bytes and takes the id **from the signed body**,
   never from the payload envelope.~~ **CORRECTED 2026-09-09 — "never" is false under
   must-report.** On a verification *failure* there is no trusted signed ULID, and a report is
   still mandatory, so the failure path has no id but the payload's. Carnot and Tesla
   independently landed on the only self-consistent contract, adopted here: **always report the
   payload UUID; admit only if the signed ULID equals it; on mismatch, end the id already
   reported; never report a second id.** The island tab's own "authoritative by construction"
   was vacuous in the other direction — the island neither mints nor checks the UUID, so an
   attacker copying a **live** UUID into their own signed invite has it carried faithfully.
3. The CallKit `UUID` **is** that ULID. The end-buffer is keyed on it. `replyTo` on the end
   sentinel remains the **server ULID** of the invite row (`reference_reply_to_is_server_ulid_fk`
   — a `client_msg_id` there refuses the whole frame), so the buffer stores both and the map is
   written down once, here.

**Cost, stated:** invite wire v2, with a v1 read path forever.

### 4c. Under arm C the id is INSIDE the envelope, and the attack closes

Point 2 above exists because an attacker could copy a **live** UUID into their own signed
invite and have the island carry it faithfully — the island neither mints nor checks it. That
forced the awkward rule *always report the payload id; admit only if the signed ULID equals
it; end on mismatch*.

**Sealing the envelope removes the attacker's write access to the id.** The id travels inside
ciphertext only the callee can open, alongside the signature that authenticates it, so
`payload id` and `signed id` stop being two values that can disagree — **there is one id, and
it is already proven by the time Swift can read it.**

**Three consequences, all favourable:**

- The mismatch arm becomes **unreachable rather than merely handled**, which retires the
  identity-as-mutable-key hazard this section was written to survive.
- **The must-report obligation is unchanged.** A push that fails to open, or whose signature
  fails, still gets reported and immediately ended — §0's *"no sustained ring before proof"*
  is exactly as strong and no stronger.
- **A UUID must still be reported when the envelope cannot be opened.** With no readable id
  there is nothing to report but a locally-minted one, and it will match nothing. That is
  correct: the call it names does not exist, and the end that follows is the point.

**OPEN, and it belongs to the island tab's condition 1** (design 20 §8.1): the island asserts
the envelope's **version byte and length bound** without reading it. A malformed envelope must
therefore be distinguishable **island-side** from a well-formed one it cannot read — otherwise
the failure is client-only and presents as *"calls silently don't ring"*.

---

## §5 — Token kinds, and the debt store is the sharp edge

Design 12 Decision 2 adds `token_kind` (`alert` | `voip`). Decision 2a names the worst state:
a sign-out discharging only one kind leaves a routable VoIP row — **a stranger's handset
ringing full-screen for the previous owner.**

Grounded in this repo:

- **`PendingUnregisterStore` keys `island → Set<token>` with no kind.** The set shape is
  already right (rotation makes multiple live tokens real — cage-match round 3), so the change
  is to record the kind alongside each token, not to restructure. `_maxPerIsland = 16` gets
  **re-argued, not silently kept**, once each sign-out can owe two tokens rather than one.
- **`ApnsTokenChannel` (`AppDelegate.swift:21`) handles one registry.** PushKit is a second,
  independent one with its own rotation. The permission asymmetry is the part to hold:
  **a VoIP token requires no user permission at all**, so a user who declines notifications has
  a VoIP token and will never have an alert token. *"Reachable for calls, unreachable for
  messages"* is a normal state to model, not an error.
- **Sequencing: claude-tasks#3723 (sovereign-key-signed DELETE) before `token_kind`, not
  after.** If the signed unregister lands first it covers both kinds by construction.

---

## §6 — Caller name, Recents, and the cells this document deliberately does not fill

**Adopted as written from design 12 Decision 6:** three tiers — Swift-readable App Group name
cache → `reportCall(with:updated:)` once Dart is up → the placeholder **`Aiko`** (Nick,
2026-08-30: names the product, not the person).

**Verified, iOS 26.5 SDK** (`CXProviderConfiguration.h:25-27`): `includesCallsInRecents`
defaults to `YES`. Set it explicitly anyway — as intent made legible, not as defence against
an unknown default. `CXHandleTypeGeneric = 1` (`CXHandle.h:13-15`) is the pick; it is what an
aiko identity actually is.

**The Recents-tap trap, and it is a real one** (Apple Developer Forums 777724, read directly;
n=1 developer report, not documentation): the Recents path delivers the **deprecated**
`INStartAudioCallIntent`, not `INStartCallIntent`, despite deprecation warnings since iOS 13
telling you to adopt the latter. An implementation written correctly against current Apple
guidance gets **nothing** from a Recents tap — presenting as "tapping does nothing", with the
obvious debugging move finding everything correct. **Handle both in
`application(_:continue:restorationHandler:)`.** Adding deprecated strings to
`NSUserActivityTypes` is *not* evidenced as necessary — same forum poster declares only
`INStartCallIntent` and still receives the deprecated one.

Excluded as unsupported supposition: that a `.phoneNumber` `CXHandle` makes iOS attempt real
telephony. Neither tab found evidence either way.

### 6a. OPEN — the ring/record cells

Temper flaw 10 found that a post-hoc refusal writes a spoofed entry into system Recents: the
name cache paints a roster name on an unverified push, through DND, and `includesCallsInRecents`
then writes a missed call for a ring `admitRing` would have silenced. Harassment fills Recents
as "Mom".

**The frame this needs was not an engineering finding.** Four adversarial families filed the
Recents entry as leakage to *eliminate*, because a reviewer looks for what a feature exposes
and never for who needs the exposure. **The reframe — that for a harassment target the entry
is the product, as evidence — is Deanna's** (2026-09-01). **The 2x2 that follows from it —
that ring and record are independent axes, and the cell the bundling hides is *no ring +
record*: quiet phone, full log — is the app tab's.** Neither has appeared in a repo artifact
until this line. Carried forward here per the standing note that whoever writes the doc carries
the split.

**These cells are left unfilled deliberately.** They are product calls, not engineering ones:

1. Is the call record a user choice, and at what granularity — per conversation, or global?
2. Does a *refused* ring produce a record? (Flaw 10 says today's answer is an accident.)
3. Does the island keep any record? **Nick, 2026-09-01: no** — the harassment-evidence case
   was withdrawn, claude-tasks#3773 closed. So **the island deliberately forgets while iOS
   remembers on-device.** Written down as a choice it reads as a considered boundary;
   discovered later in the code it reads as an inconsistency.

**Recommended routing: Deanna, as TPO** — the frame originates with her and product questions
on this feature go to her directly (precedent set 2026-09-01). Recorded as a *recommendation*,
not as a jurisdictional fact: no such assignment exists on claude-tasks#3781 or #3782, and an
earlier statement of mine that these cells were "hers to spec, not a courtesy consult" was my
own inference restated until it read like a ruling. Nick decides who fills them.

Also settled and worth stating positively (the island tab's premise, and it is stronger than
design 12 6a's original one): **only a peer who can get a VoIP push delivered can write into
your call history.** `messages_service.create_outbound` raises `BlockedDmSend` before any row
is written, and `push_service` schedules a wake only on `created=True`. Combined with the
eligibility ruling, the set of people who can write into your Recents is exactly the set you
have already consented to be rung by.

---

## §7 — A hangup delivered as a VoIP push becomes a second ring

Temper flaw 7. Design 12 Decision 5 makes waking on the end sentinel the island's blocker.
Every VoIP delivery must be reported to CallKit before the handler returns. So:

- report the end as a **new** incoming call ⇒ **the stop becomes a start**;
- call only `reportCall(with:endedAt:)` ⇒ **unverified** whether Apple counts that as reported;
- downgrade the end to an alert push ⇒ **a locked ringing phone never hears it**.

**This may become a disagreement with Decision 5's transport, and it is not resolved here.**
The one thing this document does assert: the third arm is the worst of the three, because it
fails precisely in the state the mechanism exists for (§3's cold start), and fails silently.

### 7b. The island tab's predicate fix, and the tree it sits in

The island tab (2026-09-09) corrected design 12 Decision 4's fork in response to this finding:
it was never **call / not-call** — an end *is* call-related, which is how the stop became a
start. The right predicate is **ring-starting / not-ring-starting**, under which an invite is
VoIP and an end is not. Adopted as correct.

**But do not harden Decision 4 around it yet, because one experiment may make it unnecessary:**

```
Does reportCall(with:endedAt:) ALONE satisfy the must-report rule?
├─ YES → ends ride VoIP. Guaranteed wake, no second ring.
│        The predicate fix is unnecessary; Decision 5's transport stands.
└─ NO  → ends must go alert. The predicate fix is NECESSARY, and
         "does an alert wake a locked, RINGING handset in time?"
         becomes load-bearing and needs its own two-handset measurement.
```

**Unmeasured and load-bearing:** the top node. **One device, no island** — send a local VoIP
push, report only `endedAt`, observe whether iOS complains or degrades delivery. It gates the
arm choice and half the time it moots the second question entirely. **Run it before the arm is
picked, not after.**

### 7a. The revocation ceiling (flaw 9)


> **CORRECTION, 2026-09-10 — "fleet-wide revocation" was wrong, three times over.**
> Nick asked whether Apple *penalises* or *denies*. Fetched the source rather than
> answering from the memory that produced the word. Apple, verbatim:
>
> > *"On iOS 13.0 and later, if you fail to report a call to CallKit, the system
> > will terminate your app. Repeatedly failing to report calls may cause the
> > system to stop delivering any more VoIP push notifications to your app."*
>
> - **It is DENIAL OF DELIVERY, not a penalty or a revoked entitlement.** Nothing
>   is taken away; the OS simply stops handing pushes to the app.
> - **"The system" is the OS ON THE DEVICE, and "your app" scopes it there.** No
>   evidence for anything fleet-wide, and direct corroboration for per-device:
>   `CSDVoIPApplicationKillCounts`, found on this handset tonight, lives in the
>   **device-local** `com.apple.TelephonyUtilities` preferences domain.
> - **"May cause" — not deterministic**, and recovery is not established either
>   way, so "unrecoverable" was also unearned.
>
> **The conclusion survives and the reason improves.** A single failure already
> terminates the app, and per-device denial is *harder* to detect than a
> fleet-wide event, not easier: it accumulates silently on the devices that take
> the most calls, so calling quietly stops working for the heaviest users with no
> error surfacing anywhere. That is this project's recurring failure shape, and it
> argues for arm (a) more strongly than the overclaim did.
>
> Provenance of the error: the phrase entered as Tesla's temper wording
> (*"Apple revokes VoIP privileges for that"*), and I restated it four times —
> into this document twice, into design 18, and into a live ruling to the island
> tab — each time as established fact. Nobody checked it because it was never
> written as a claim.

A `should_wake` hole, or a retraction that is not actually sub-second, produces a sustained
report-and-end pattern, and **the system stops delivering VoIP pushes to the app on that
device**. The failure mode is calling silently ceasing to work, device by device. Design 12 Decision 7 priced harassment; v1 did not price
revocation. **It is priced here as a hard ceiling on §0's residual and on §1c arm (b):**
report-and-end must be rare, which means the verify set must be *right*, not merely *fast*.

---

## §8 — What this document does not cover

- **Android.** ConnectionService, full-screen intent, FCM's single token — design 12 Decision 8.
  The Play `USE_FULL_SCREEN_INTENT` declaration (claude-tasks#3615) has been required since
  31 May 2024, is a store-review gate rather than a code gate, and is **slower than the build**.
  Start it before the code.
- **Sender anonymity.** Nick's 2026-08-25 ruling (the island learns neither who is friends with
  whom nor who is calling) remains unreconciled with designs 12/16 building the ring as a
  stored, attributable message. claude-tasks#3745, and it stays a **separate** thread: this
  decision makes the ring *safe* without making it *anonymous*, and the two were bundled once
  already. Counterintuitive corollary worth keeping visible — **restricting the caller set
  SHRINKS the anonymity set.**
- **Occupancy.** claude-tasks#3159 is not subsumed by the end sentinel: an end covers the
  happy path, occupancy covers *no end was ever sent* (caller's phone died), *the end cannot be
  applied* (§3 cold start), and *answering into an empty room*. `ring_overlay.dart:96` is
  load-bearing on it landing.
- **Cross-island calling** (claude-tasks#3196) and **the P2P direct path** (#3740 / PR #169).
  §6a of v1 established why the ring half is transport-agnostic and that argument is unchanged:
  a suspended iOS app holds no sockets, so the first packet to a locked handset leaves the
  island whatever the media topology becomes. **The rendezvous can move. The wake cannot.**

---

## §9 — Sequencing

1. **§3a + §3 retention** — replace the pinned two-clock invariant, re-bind `_ended`. Correct
   under every arm of §2, so it is safe first. **Blocked on `kPushDeliverySlack` having a
   derivation.**
2. **§7b's one-device experiment** — does `reportCall(with:endedAt:)` alone satisfy the
   must-report rule? One handset, no island, decisive, and it gates §7's arm. **Run first: it
   may moot the two-handset alert-wake measurement below.**
2b. **The two-handset alert-wake measurement**, only on the NO branch — ring one device, send
   the end as an alert push, observe whether it lands and how late. The island tab drives its
   half. Worth batching with the two-device NAT measurement PR #169 already owes, since both
   need two real handsets on real networks.
3. **§2 decided by Nick.** The ceiling's owner. Everything about enforcement branches on it.
3b. **The island's end-sentinel wake.** **THE ACTUAL BLOCKER, and it is arm-independent** —
   without it a caller hangs up and the callee's handset rings on. Island design 12 calls it
   *"the real island blocker"* itself; the island tab has taken it as its next piece and is
   **not** waiting on the payload question. **Nothing below should be built before it.**
3c. **The sealed envelope contract** (design 20) — the payload shape, the version byte and
   length bound the island asserts without reading (§8.1), and the size budget written into
   the contract rather than discovered at the 5KB ceiling (§8.2). **Gated on a cryptographer
   seeing design 20 §4a**; neither tab may bless the key material.
4. **§4 the UUID map**, then **§1 the Swift admission path** — one change, since the delegate
   cannot report without the map. **Now downstream of 3c**: the map's id lives inside the
   envelope (§4c), so the envelope contract precedes it.
5. **§5 token kinds**, sequenced after claude-tasks#3723.
6. **§6a filled** by whoever Nick routes it to; **§6 tap handling** built with it.

§1, §2 and §5 are **one cage-match, not three** — the same trust boundary from three sides.

## Open questions, consolidated

- **`kPushDeliverySlack`** has no value and no derivation (§3).
- **Key-set freshness at wake time** — §1c, three arms, recommendation stated not decided.
- **Does `reportCall(with:endedAt:)` count as reported?** — §7, unmeasured, gates an arm.
- ~~**Who owns the ring ceiling**~~ — **CLOSED**: the island, Nick 2026-09-09 21:43, re-affirmed
  2026-09-11 (§2). It opened a successor: **the island's ring lease is not on the wire**, so
  neither the §3 retention bound nor any test here can be pinned against it — claude-tasks#4233.
- **What does Swift verify, and where do the bytes come from?** — **ANSWERED IN PRINCIPLE**
  (design 20 arm C; island tab accepting, with three conditions, design 20 §8), **OPEN IN
  FACT** until a cryptographer has seen design 20 §4a. claude-tasks#4254.
- **The forged-push ratio** — §1e. An assumption this document now owns, not a measurement.
- **The ring/record cells** — §6a, product, routing recommended not asserted.
- **The in-app ring path** — whether it is genuinely the same path as the push-woken one, or
  whether moving the ceiling amputates it. Carried from v1 and still unexamined.

## Provenance

Claude (app tab), 2026-09-09. Grounded by reading, this session: `call_invite.dart` (the
`RingRefusal` enum, not its prose), `ring_controller.dart`, `ring_allowlist_store.dart`,
`ring_overlay.dart`, `AppDelegate.swift`, `feature_flags.dart`, design 16 v1 + its temper
end-to-end, island design 12's headings, and claude-tasks#3609/#3744/#3745/#3781/#3782
end-to-end including comments.

**AMENDED 2026-09-11 (v3).** §0's flaw-2 bullet struck, §1's admission input defined, §4c
added, §1e written (discharging claude-tasks#4181), §9 resequenced, open questions updated.
**The inherited-claims caveat below is what this amendment is about:** the v2 statement that
`_payload` was "not read against island source by this tab" was accurate, and the section it
sat under — §0's *"proof needs nothing from the payload"* — was built on exactly that unread
source. **The caveat named the risk correctly and nobody followed the pointer for two days.**
Island internals ARE now read against source for the specific claims in §0, §1e and §4c:
`_render`, `should_wake`, `CALL_INVITE_BODY`, and the block enforcement on the wake path.

**Claims inherited rather than verified, marked as such:** everything about island internals is
design 12's or the island tab's and is attributed at each point — `create_outbound` /
`should_wake` / `_payload` were **not** read against island source by this tab. The iOS 26.5
SDK header quotes and the forum report are from #3781's comment, which states them as verified;
they are re-quoted here, not re-fetched. The 17.55s is from the 2026-08-31 on-device run.
