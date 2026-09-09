# Design 16 v2 — the CallKit ring, client half (the recast)

**Status:** RECAST OF RECORD. Supersedes [`16-callkit-ring-the-client-half.md`](16-callkit-ring-the-client-half.md)
(v1, struck 4/4 on 2026-09-01 — verdict in [`16-callkit-ring-TEMPER.md`](16-callkit-ring-TEMPER.md)).
v1 remains in the repo as the record that earned this one; it is not the design to build from.

**Tier:** trust boundary. `admitRing` is the app's single trust decision and this design moves
part of it into Swift. Cage-match by law before any of it merges.

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
- **Flaw 2 is not a contradiction.** Proof needs nothing from the payload, so design 12
  Decision 6's opacity survives intact.
- **The privacy cost v1 priced against arm (iii) does not exist.**
  `lib/features/call/data/ring_allowlist_store.dart` is device-local by design and publishes
  nothing. Nothing about ring consent reaches the island.

**What that buys, stated at its real strength and no higher.** The property is
**"no *sustained* ring before proof"** — not "no ring before proof". Every VoIP push must be
reported to CallKit before the delivery handler returns, so the arm is
*verify → report → immediately end on failure*, never *verify-or-silence*. A forged or
unverifiable push still produces a momentary ring. That residual is not cosmetic: it is the
input to flaw 9 (§7), where a bad report-and-end ratio costs VoIP delivery fleet-wide.

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
                 │
                 ├─ read App Group state  (consented keys · ends · mute · block)
                 ├─ verify Ed25519 over the signed bytes         (CryptoKit)
                 ├─ reportNewIncomingCall(with:update:)          (MANDATORY, always)
                 └─ on failure: reportCall(with:endedAt:reason:) (immediately)
                                                        │
Dart, when it next runs ──► maintains the App Group cache ◄──────┘
```

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

## §2 — The ring ceiling: design 12's Decision 1c inverts. SURFACED, NOT DECIDED.

Design 12 records:

> A CallKit ring is system UI drawn before Dart exists and **does not self-expire**... **The
> app tab owns re-establishing it and has taken it.**

**That assignment was made against a mechanism that cannot run.** The app is suspendable the
instant the CallKit report completes. A Dart `Timer` needs an isolate the OS has not started;
a Swift timer is in a process iOS may suspend the moment the handler returns. Neither is an
enforcer. Today's derivation in `RingController._republish()` is the right *shape* — deadline
computed from the signed `signedAtMs`, never restarted, so no rebuild extends a ring — and the
derivation is worth keeping wherever it ends up running.

**The island tab's position (2026-09-09, cross-tab):** the island takes the ceiling back and
enforces it with an end-push, on the reasoning that an enforcer which exists beats a contract
line that reads well and does nothing. **The app tab agrees on the engineering.**

**This document does not record that as settled, and the agreement is why.** Two Claude tabs
concurring is not corroboration — a wrong answer wearing two signatures survives review better
than either error alone, because the second signature reads as verification. This reverses a
recorded decision in a peer repo's design of record. **It is Nick's call, and it is put to him
with both positions rather than tie-broken by mutual agreement between the two parties who
would be relieved of the work.** Routed as claude-tasks#3744 finding 1.

Downstream of whichever way it goes: **`kCallRingDuration` acquires a second enforcer or moves
outright.** If the island owns it, the Dart constant becomes advisory for the in-app path only
and must be renamed to say so.

---

## §3 — Cold-start liveness: the case this design exists for

Temper flaw 6, and v1 got it wrong. v1's §2 argued the liveness object already exists as a
signed end held in `RingController._ended`. It does not survive the case that matters:

```dart
// ring_controller.dart:78
final Map<String, List<({CallEnd end, DateTime at})>> _ended = {};
```

Plain in-memory Dart state. **Empty by construction on a push-woken cold start** — which
CallKit makes the normal case, not the exotic one. A ring has three endings (ceiling, signed
hangup, post-hoc refusal) and v1 moved only one of them to the layer that is actually alive.

**Design: the App Group end-buffer** (`ends/<islandMsgId>` in §1a). The end-wake writes it;
Swift reads it before reporting and ends the call immediately if the invite it names is
already ended. No isolate in the path.

**And the retention bound has to move with it.** `ring_controller.dart:91` currently forgets a
held hangup after `kCallInviteFreshness * 2` (20s), with the stated reason *"an end is only
useful while its invitation could still be ADMITTED"*. That reason is right and is exactly why
the bound must change: under CallKit an invitation can be admitted for as long as the phone is
ringing. A hangup garbage-collected at 20s while a 30s ring is audible is **a phone ringing for
a corpse because we forgot the stop**.

New bound: `kCallRingDuration + kPushDeliverySlack`.

> **`kPushDeliverySlack` still has no value and no derivation.** It is the honest name for a
> number this design needs and has not earned: *how late can a stop arrive and still matter?*
> It cannot be picked at the keyboard. The one measured input available is the 17.55s
> observed on 2026-08-31 between a caller pressing call and the tap arriving — which is a
> calibration input for the ring *duration*, not for delivery slack. **Open.**

### 3a. The pinned two-clock invariant must be replaced in the same commit

`call_invite_test.dart:996` pins `kCallRingDuration > kCallInviteFreshness`, in a group named
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

**The client contract, stated:**

1. The caller mints the call id **client-side** as a ULID in the signed invite body
   (`aiko:call/2 <ulid>`). ULID is 128 bits → lossless as a `UUID`. Zero island schema.
2. The island carries that id verbatim in the push payload. It is **not** authoritative — it
   is a lookup hint. Swift verifies the signed bytes and takes the id **from the signed body**,
   never from the payload envelope.
3. The CallKit `UUID` **is** that ULID. The end-buffer is keyed on it. `replyTo` on the end
   sentinel remains the **server ULID** of the invite row (`reference_reply_to_is_server_ulid_fk`
   — a `client_msg_id` there refuses the whole frame), so the buffer stores both and the map is
   written down once, here.

**Cost, stated:** invite wire v2, with a v1 read path forever.

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

**Unmeasured and load-bearing:** whether `reportCall(with:endedAt:)` alone satisfies the
must-report rule. That is a one-device experiment and it gates the arm choice. **It should be
run before the arm is picked, not after.**

### 7a. The revocation ceiling (flaw 9)

A `should_wake` hole, or a retraction that is not actually sub-second, produces a fleet-wide
report-and-end ratio, and **Apple revokes VoIP privileges for that**. The failure mode is
losing the right to ring *anyone*. Design 12 Decision 7 priced harassment; v1 did not price
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
2. **§7's one-device experiment** — does `reportCall(with:endedAt:)` alone satisfy the
   must-report rule? Cheap, decisive, and it gates §7's arm.
3. **§2 decided by Nick.** The ceiling's owner. Everything about enforcement branches on it.
4. **§4 the UUID map**, then **§1 the Swift admission path** — one change, since the delegate
   cannot report without the map.
5. **§5 token kinds**, sequenced after claude-tasks#3723.
6. **§6a filled** by whoever Nick routes it to; **§6 tap handling** built with it.

§1, §2 and §5 are **one cage-match, not three** — the same trust boundary from three sides.

## Open questions, consolidated

- **`kPushDeliverySlack`** has no value and no derivation (§3).
- **Key-set freshness at wake time** — §1c, three arms, recommendation stated not decided.
- **Does `reportCall(with:endedAt:)` count as reported?** — §7, unmeasured, gates an arm.
- **Who owns the ring ceiling** — §2, a cross-repo decision-of-record conflict, Nick's.
- **The ring/record cells** — §6a, product, routing recommended not asserted.
- **The in-app ring path** — whether it is genuinely the same path as the push-woken one, or
  whether moving the ceiling amputates it. Carried from v1 and still unexamined.

## Provenance

Claude (app tab), 2026-09-09. Grounded by reading, this session: `call_invite.dart` (the
`RingRefusal` enum, not its prose), `ring_controller.dart`, `ring_allowlist_store.dart`,
`ring_overlay.dart`, `AppDelegate.swift`, `feature_flags.dart`, design 16 v1 + its temper
end-to-end, island design 12's headings, and claude-tasks#3609/#3744/#3745/#3781/#3782
end-to-end including comments.

**Claims inherited rather than verified, marked as such:** everything about island internals is
design 12's or the island tab's and is attributed at each point — `create_outbound` /
`should_wake` / `_payload` were **not** read against island source by this tab. The iOS 26.5
SDK header quotes and the forum report are from #3781's comment, which states them as verified;
they are re-quoted here, not re-fetched. The 17.55s is from the 2026-08-31 on-device run.
