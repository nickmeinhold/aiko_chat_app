# TEMPER.md — design 16, the CallKit ring client half

**Overall verdict: RECAST.**
**Struck:** `dt-1788184779`, 2026-09-01. Families seated: **Maxwell (Claude) + Kelvin (Gemini
2.5 Pro) + Carnot (GPT/Codex) + Tesla (Grok)** — 4/4. Wu (Kimi K3) disabled upstream.

Bundle: design 16 (under strike) + island design 12 (context, the co-owned peer record).

> ## POST-STRIKE ADDENDUM — flaw 5 is DECIDED, and its stated cost was wrong
>
> **Nick, 2026-09-01:** *"Yeah default-off for groups, default-on for DMs with friends I
> reckon."*
>
> Flaw 5 — the one this disposition names as the single thing gating a `CXProviderDelegate`
> line — is answered. Arm (iii) is the spine.
>
> **And the reason the strike gave for it being Nick's call does not exist.** The disposition
> below says (iii) *"publishes a per-conversation consent fact to the island."* It does not.
> `lib/features/call/data/ring_allowlist_store.dart` has shipped since Nick's 2026-08-26
> ruling and is **device-local by design**, argued from the same mute-vs-block doctrine the
> ring gates already use: a block is server-side moderation, a mute is device-local
> attention, and *"may this agent wake me at 3am"* is attention. The store's own docstring
> rejects the island-held roster explicitly — it would put a person's sleep under an
> operator's control and contradict ADR-0004's refusal of a central directory.
>
> So the privacy cost that made (iii) a product question was priced against a mechanism
> nobody was going to build. **Nothing is published. The island learns nothing.**
>
> Nobody in a 4/4 strike flagged this, because the sentence reasons correctly from its
> premise — the premise simply was never checked against a file in the same feature
> directory. A reviewer interrogates the argument; nobody re-measures the premise.
>
> **What it unblocks, carried into the v2 recast:**
> - Flaw 1 (*the ring fires before the signature is proven*) drops from a trust-boundary
>   dilemma to an implementation detail. The consented key set is small, local and known
>   before the push arrives, so Swift verifies Ed25519 with CryptoKit against those keys
>   **before** reporting to CallKit. Nothing rides in the payload.
> - Flaw 2 loosens with it — design 12's payload stays opaque *and* the proof happens
>   on-device, because the proof does not need the payload to name anyone. Tesla's
>   *"opacity and on-device proof cannot both be true"* was true only while verification
>   had to read the payload.
> - **New consequence to handle, not settled here:** `notDirectMessage` currently refuses
>   channel-wide rings outright. Default-off-for-groups is not never-for-groups — a
>   consented group ring is now expressible, and that gate needs re-deriving from the
>   consent store rather than from the channel kind. `call_invite.dart` says *"channel-wide
>   calls need their own consent model, not this door"*; per-conversation ring consent **is**
>   that model, and the two have sat in one directory unconnected.
>
> Everything below is the strike as it was struck, unedited apart from the marked
> correction at flaw 5. A temper is a record of what four families said at a moment; it is
> not rewritten when the world moves under it.

## Per-family verdicts

| Family | Verdict | One-line |
|---|---|---|
| Maxwell (Claude) | RECAST | The headline finding is real, but the doc built a false binary around it and its liveness object evaporates on cold start. |
| Kelvin (Gemini) | RECAST | Correctly identifies a trust-boundary-violating cold fault, then freezes before selecting the one path that resolves it — *"the design's failure is one of nerve."* |
| Carnot (GPT) | **DISSOLVE** | *"Not a shippable client design; a lucid incident report... it names three doors and walks through none."* |
| Tesla (Grok) | RECAST | *"You designed the echo after the bell."* — the ring authority is a Swift handler and the doc keeps legislating in Dart. |

**One DISSOLVE is a strong finding to fold, not a kill** (the bar is ≥2). But Carnot's
reasoning is adopted below rather than outvoted: its central charge — that §4 inventories
options where a design must choose — is made independently by Kelvin in almost the same
words, and neither is wrong.

## Fatal flaws, deduped, most-severe first

### 1. The option-frame in §4 excluded the arm that keeps the thesis. Raised by Maxwell + Tesla.

The doc reasoned *CallKit rings before Dart exists → verification cannot precede the ring*.
That is a fact about the Flutter engine wearing the costume of a fact about the device.
Swift is alive in `pushRegistry(_:didReceiveIncomingPushWith:)`; Ed25519 verification is
CryptoKit and takes microseconds; and §6 of the doc **already** establishes a Swift-readable
App Group cache that Dart maintains. Tesla: *"You heard Dart's silence and called it physics."*

**DISPOSITION: fold — add the missing arm.** Swift admits from signed bytes plus App Group
state (keys, mute, block, consent, ends), Dart maintains the cache. Constraint to state
honestly: a report is mandatory per VoIP push, so the arm is *verify → report → immediately
end on failure*, not *verify-or-silence*.

### 2. That arm collides head-on with design 12 Decision 6, and neither document marks it. Raised by Tesla.

Design 12's payload is deliberately opaque (`c` only) *"because naming the caller would tell
Apple who calls whom."* **That payload cannot carry a signature, `signedAtMs`, or an
invite-vs-end discriminator.** Tesla: *"Opacity and on-device proof cannot both be true. One
of the two documents has to give. Neither currently does."*

**DISPOSITION: fold as a cross-repo finding, surfaced not tie-broken.** This is precisely the
class CLAUDE.md's cross-tab rule exists for. It goes to the island tab as a conflict between
Decision 6's opacity and any on-device proof requirement, with the cost of each arm named.

### 3. The 30s ceiling is not "taken" — it may be un-takeable client-side. Raised by Tesla.

Design 12 Decision 1c records the app tab as owning re-establishment of the ring ceiling.
Design 16 §3 offered three arms. Tesla strikes all of them: the app is suspendable the
instant the CallKit report completes, so **a Swift `Timer`/`asyncAfter` does not reliably run
either**. Arm (c) was already dismissed correctly. What is left is `beginBackgroundTask`
racing an OS budget we do not own — plus design 12's signed end-push. *"Maxwell's 30s pillar
is not 'taken'; it is gone."*

**DISPOSITION: fold, and it changes the cross-repo contract.** If the ceiling cannot be held
client-side, Decision 1c's assignment is wrong and the island's end-push is not an
optimisation but the only enforcer. That must go back to the island tab explicitly.

### 4. `CXAnswerCallAction` is a trust decision the document does not contain. Raised by Tesla.

The whole reason CallKit exists is that a locked-device human can press Answer. That action
arrives in Swift **before Dart exists, therefore before `admitRing`**. Fulfill-then-refuse
puts the user in a live audio session for a forged, muted or blocked call; fail-after-tap
reads as a crash at the exact moment the product promised to feel like a phone.

**DISPOSITION: fold — a whole missing section.** *"'How fast to stop' is a ringing-state
sentence. Answered-state is a different machine, and it is the one that fires at 3am."* The
doc's own one-sentence version is therefore incomplete, not merely under-specified.

### 5. §4 inventories where it must choose, and two families named the same choice. Raised by Carnot + Kelvin (independently).

Carnot: *"VoIP ringing is not a property of any signed DM; it is a capability granted only
after a relationship/consent state has been made available to the send path."*
Kelvin: *"First contact is an alert; an established relationship earns a ring."*

Both land on arm (iii) — but **as the spine, not an option**. Carnot adds the sharper
framing: separate *signed call invite as message* from *ring-capability as delivery policy*,
and never let `body == sentinel` alone imply PushKit eligibility.

**DISPOSITION: this is the recast's centre — and it is still Nick's call**, because (iii)
publishes a per-conversation consent fact to the island.

> **CORRECTION, 2026-09-01 (post-strike).** The clause after "because" is false — the shipped
> `RingAllowlistStore` is device-local by design and publishes nothing. And the call has since
> been made: default-off for groups, default-on for DMs with friends. See the addendum at the
> top of this file. The rest of this disposition stands, and its last sentence turned out to
> be the important one.
 What changes is that the doc must
present it as *the design*, with the others as rejected alternatives and their rejection
argued, rather than as three equal doors. Note it also **bounds** flaw 1 rather than solving
it (Kelvin is explicit: the ring still precedes the check, but only for vetted callers) —
and under (iii) the flaw-1 arm gets *cheaper*, because Swift can verify against the small
set of already-allowed keys without the payload naming anyone.

### 6. Liveness evaporates on cold start — the case the design exists for. Raised by Maxwell + Tesla.

§2 argues the liveness object already exists as a signed end held in `RingController._ended`.
That map is **in-memory Dart state**, empty by construction on a push-woken cold start.
Tesla's framing is sharper: a ring has three endings — ceiling, signed hangup, post-hoc
refusal — and the doc moved only one of them to the layer that is actually alive.

**DISPOSITION: fold.** Either an App-Group end-buffer keyed by the ringing UUID, populated by
the end-wake and applied without an isolate, or §2 states plainly that cold-start liveness is
window-only and re-argues the window on that basis.

### 7. A hangup delivered as a VoIP push becomes a second ring. Raised by Tesla.

Design 12 Decision 5 makes waking on the end sentinel the island's blocker. Every VoIP
delivery must be reported to CallKit before the handler returns. If Swift reports the end as
a *new* incoming call, the stop becomes a start; if it only calls `reportCall(endedAt:)`, it
is unverified whether Apple counts that as reported; if the end is downgraded to alert, a
locked ringing phone never hears it.

**DISPOSITION: fold, and it may become a disagreement with Decision 5's transport.**

### 8. The CallKit UUID is an unsigned identity key. Raised by Tesla.

Swift must report a UUID before proof, and it will come from the island's payload, not the
signed ULID. Payload ULID ≠ signed ULID means `reportCall(endedAt:)` cannot find the ringing
call and §1's hangup retention is theatre. Payload reuse of a live UUID is
identity-as-mutable-key: call N stops call N−1, or two invites collapse into one system call.

**DISPOSITION: fold — write the `payload UUID ↔ signed ULID ↔ end-key` map as the client
contract.** It is currently unwritten in both documents.

### 9. Arm (ii)'s blast radius reaches Apple, not just the user. Raised by Tesla.

A `should_wake` hole, or a retraction that is not actually sub-second (the doc concedes it is
unmeasured), produces a fleet-wide report-and-end ratio. **Apple revokes VoIP privileges for
that.** The failure mode of arm (ii) is losing the right to ring *anyone*. Design 12 Decision
7 priced harassment; design 16 did not price revocation.

**DISPOSITION: fold into arm (ii)'s cost column.**

### 10. Post-hoc refusal writes a spoofed entry into system Recents. Raised by Tesla.

The name cache paints a roster name on an unverified push, through DND, and
`includesCallsInRecents = true` then writes a missed call for a ring `admitRing` would have
silenced. Harassment fills Recents as "Mom". Design 12 Decision 6a scoped the Recents ruling
to *"a call they were party to"* — post-hoc refusal means they were not.

**DISPOSITION: fold — Recents and lock-screen identity become per-call and admit-gated.**
This is an active wire for #3695, not a disk-exposure footnote. **It also reopens a settled
ruling** (Nick, 2026-08-30) on a premise that has changed, which the island tab must be told.

### 11. `kPushDeliverySlack` is an undefined constant load-bearing in a step declared safe-to-start. Raised by all four.

Unanimous, which makes it the cheapest thing on this list to be wrong about. Kelvin wants it
*derived* (99th-percentile delivery to a sleeping device + the island's retry/expire window);
Carnot wants it replaced by a product rule (*stops matter until the native ring deadline;
after that they are state reconciliation, not ring control*); Tesla wants it dropped
entirely once ends live in Swift until the ceiling fires. Maxwell notes §7 declares its step
*"safe to do before the fork"* while the Open Questions concede the constant has no value —
an internal contradiction three headings apart.

**DISPOSITION: fold — Carnot's product rule is the cleanest and dissolves the constant.**

### 12. Two smaller, both conceded. Raised by Maxwell (§3 preference) and Carnot + Tesla (Android).

§3 states a preference for arm (b) while listing arm (b)'s only real objection as unexamined.
And Android is in the decision of record's header but unscoped in the body.

**DISPOSITION: drop the §3 preference to no-preference pending the check; retitle the doc
iOS-first or give ConnectionService its own inversion table.**

## What holds — unanimous across all four families

- **The central inversion.** CallKit turns a stale or refused call from a silent non-event
  into an audible, DND-piercing event that must be actively retracted. Nobody challenged it.
- **The nine-gate enumeration**, and the method that produced it — reading the `RingRefusal`
  enum rather than the prose that described it. Tesla: *"The instrument was honest even where
  the machine was not."*
- **The freshness→liveness direction.** `signedAtMs` plus a signed end is the right
  client-owned substrate; `createdAt` must not become authority. The anti-replay property is
  preserved — the 41-minute backlog stays refused while the 17.55s tap becomes admissible.
- **The three-sites census of `kCallInviteFreshness`**, especially `_ended` retention. Carnot:
  *"A hangup retention window shorter than the ring window is exactly how the system forgets
  the stop while the phone is still ringing."*
- **§5's token-kind debt analysis**, including sequencing #3723's signed DELETE before
  `token_kind` so one signed unregister covers both kinds. Tesla calls this *"the 3am of the
  next owner's phone"* and counts the blast radius as correctly priced.
- **Marking disagreement with design 12 rather than folding it in**, and the provenance
  block's honesty about which claims are inherited and unverified.

## Disposition

**RECAST.** Not a rewrite of the finding — a rewrite of the design built around it.

Two things must happen before a Swift `CXProviderDelegate` line is written, and Carnot's
gate is adopted verbatim: **reversibility is already lost once the phone rings.**

1. ~~**Nick decides flaw 5**~~ — **DECIDED 2026-09-01**, and the second half of the question
   was malformed: the island does not get to know, because the consent store is device-local
   and always was. Default-off for groups, default-on for DMs with friends. Arm (iii) is the
   spine. See the addendum at the top of this file.
2. **Flaws 2, 3, 7 and 10 go to the island tab as cross-repo findings** — the opacity/proof
   collision, Decision 1c's possibly-un-takeable ceiling, the end-as-VoIP dispatch problem,
   and the Recents ruling whose premise has changed.

Then re-cast §2, §3 and §4 with flaws 1, 4, 6, 8, 9, 11 folded, and re-strike. Round 1 of ≤3.
