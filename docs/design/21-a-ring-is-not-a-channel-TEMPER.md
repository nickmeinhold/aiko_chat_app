# TEMPER — Design 21: a ring is not a channel

**Overall verdict:** RECAST (unanimous among seated families)
**Struck:** dt-ring21 · families seated: Maxwell + Kelvin + Carnot · **Tesla DARK** (no output
inside the 30-minute background limit; the run was stopped and Tesla's file was empty: a
coverage gap, not a vote). Wu/Kimi disabled.

## Per-family verdicts

| Family | Verdict | One line |
|---|---|---|
| Maxwell (Claude) | RECAST | "Ring id" does two jobs; local routing ≠ dedup. Make the wire id a prerequisite, and replace the event buffer with state reads. |
| Kelvin (Gemini) | RECAST | A local id builds on a known-undecidable state; the wire `m` IS the ring identity; reject an invite without it. |
| Carnot (GPT) | RECAST | Two ids, not one (wire `callId` + local `ringInstanceId`); a per-call session object owns every child; converge iOS. |
| Tesla (Grok) | — dark — | no strike returned |

## Fatal flaws (deduped, most severe first)

1. **The wire identity is a prerequisite, not an open question.** Raised by all three. Without
   `m` on the invite, duplicate-vs-redial is undecidable on the device; a local-only rule is wrong
   in one real case. DISPOSITION: fold. `{c, k, m}`, `m` = the invite's server message id, which
   `call_end` already names via `reply_to`. **Cheapest now:** island PR #192 is unmerged and no
   Android build consumes FCM call wakes.
2. **One `ringId` conflates two identities.** Raised by Maxwell and Carnot. DISPOSITION: fold.
   `callId` (= wire `m`) is the semantic identity; a locally minted `ringInstanceId` binds
   presentation (screen, intents, keyguard callback, timer) to one incarnation.
3. **The event buffer should be removed, not keyed.** Raised by Maxwell; Carnot names the same
   root as ownership. DISPOSITION: fold, as ONE mechanism: a per-call **session** owns the
   notification intents, timer, listeners and engine lease, and Dart **reads current state**
   (`{phase, channel, callId}`) on listen and on each change signal instead of draining a queue.
   Retiring the session invalidates everything it owns.
4. **`Answered` has no discriminant without `m`.** Raised by Kelvin and Carnot. DISPOSITION: fold.
   Answered is keyed `(channel, callId)`; an invite with a different `callId` is a new call; one
   with the same `callId` is a duplicate.
5. **Blast radius: two identity models.** Raised by Carnot and Kelvin; Maxwell scoped it. If
   Android keys by `callId` while Dart, `reply_to` and iOS stay channel-keyed, there are two
   failure surfaces. DISPOSITION: fold. Converge iOS (`CallKitRinger`'s channel-keyed map and its
   8h `answeredCallTrustWindow`) in the same arc, or state the interim explicitly.

## What holds

The diagnosis (all three); separating Ringing from Answered (all three); the timer's
`(channel, at)` match as the pattern's first instance; the hardware-verified lock-screen flow,
single answer door, wake-lock work and warmed engine ("not the weak points": Carnot).

## Disposition

**RECAST → fold into design 21 (v2 section), re-strike.** The prerequisite is a cross-repo
contract change (island PR #192 adds `m`), so v2 waits on that agreement before any code. Round
1 of ≤3.

---

## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST

**Summary:** The diagnosis is right, but "ring id" is doing two jobs. One of them can't be done locally, and the other is better done by deleting the event buffer than by tagging what goes into it.

Vincent Vega: "It's the little differences." Here the little difference is between *which ring is this event about* and *is this the same call twice*. They're two different questions.

**Fatal flaws:**
- **(Wrong option-frame, §Proposed recast 1 vs Q1/Q2.)** "Ring id" covers two problems with different solutions, and the recast treats them as one:
  - (a) **Internal routing:** a listener, callback, timer or buffered event lands on the wrong *local* ring. A locally minted id solves this completely, because every one of these events is produced and consumed on the device.
  - (b) **External dedup:** is this `invite(c)` the same call delivered twice, or a new call? No local id can answer that, because the device has nothing to compare against. Only the sender knows.

  The doc half-sees this in Q2 ("may be undecidable on the current wire") but still presents recast item 1 as the fix and the wire id as an open question. Tesla's round-3 finding 1 (a re-ring after Answer) and the r1 redial concern are (b). The other ten instances in the class table are (a). A design that ships only the local id will re-meet (b) in the next review, and the instance count will say "the fix didn't work".
- **(Under-priced timing, Q1.)** The wire field is cheapest **right now** and at no other time. The island's FCM sender is an unmerged PR (aiko-chat-island #192), and no Android client in the field consumes FCM call wakes. Adding `m` (the invite's server message id, which `call_end` already names via `reply_to`) costs one string in an envelope that has zero consumers today. After the first store build ships, the same change becomes a versioned-payload migration. The doc frames Q1 as "is a local id worth building if the wire id is the real answer?". The better question is "why would anyone build either before adding the field while it's free?"
- **(A coupling to remove, not guard: recast 3, the held buffer.)** Item 3 makes the buffer per-engine and keyed by ring id, which puts the leak behind two more guards. The simpler move is that **native call actions don't need to be events at all.** The persisted record (with its generation) is already the source of truth. If `call/actions` carries a "state changed" signal and Dart *reads* the current state (`{phase, channel, ringId}`) when it listens and on each signal, there's no queue to drain into the wrong engine. A newly attached engine reads the truth as it stands now, not a backlog from a previous engine. Five rounds of findings came from the buffer, and this removes the buffer. Cost: the bridge contract changes on iOS too (Swift holds actions the same way), which Q3 already suspects is necessary.

**What holds:**
- The diagnosis. The class table is the strongest artifact in the doc. It turns 19 findings into one missing concept and says so plainly.
- "What is NOT in question" really is out of question. Each item survived a direct challenge with hardware evidence.
- The timer's `(channel, at)` match is correctly called the first local instance of the fix, which shows the concept is already earning its keep in the code.

**If RECAST, what to fold back:**
- Split recast 1 into **1a** (a local ring id for internal routing) and **1b** (a wire invite id `m` for dedup). Make 1b a **prerequisite**, not an open question, and ask the island tab to add `m` to PR #192 before it merges. Then 1a can simply *be* `m`, so there's one identity end to end and no locally minted id.
- Replace recast 3 (a per-engine buffer) with **state over events**: `call/actions` signals a change, and Dart reads the current state from native, persisted with `m`. Delete `held`.
- Re-scope Q3 as a stated follow-up: iOS adopts `m` and the state-read bridge in the same change, or explicitly waits for it. The shared Dart bridge means a mixed design is a third shape to maintain.


## KelvinBitBrawler's Design Strike

**Verdict:** RECAST

**Summary:** The proposal correctly freezes the "wrong ring" bug class with a local identity, but leaves the system in a fatally ambiguous state when confronted with a duplicate invite, a problem that can only be dissolved by a wire-level identity.

**Fatal flaws:**
- **The proposed local identity is necessary but not sufficient, creating a known state of ambiguity.** The design correctly identifies that a local `ringId` cannot distinguish a re-delivered invite from a new call (Q2), yet proposes to build this flaw into the system. This isn't a degenerate state; it's a guaranteed race condition in any real-world network. A design that knowingly builds on an undecidable state is built on a cold fault, doomed to brittle fracture. `Ash: "I can't lie to you about your chances, but... you have my sympathies."`
- **The design fatally mis-frames the wire identity as an optional future instead of a prerequisite for correctness.** Q1 asks, "Is a local id worth building if the wire id is the real answer?". This is the wrong question. The real question is: "Is a system that cannot distinguish a new call from a re-delivery worth building at all?". By framing the wire ID as a costly follow-on, the design steers directly into the hazard. You are proposing to build a patch, not a system.
- **The proposed `Answered` state has an unstated dependency on the missing wire identity.** Recast #2 suggests a separate `Answered` slot, but without a wire identity, the system has no way to correctly process an incoming invite for that channel. Is it a duplicate that should be dropped? Is it a new call that should ring? The proposed design creates a new state but provides no discriminant to manage it, leaving it to drift in thermal chaos.

**What holds:**
- The diagnosis that a **channel is not an identity** is the absolute zero of this problem. This insight is correct and valuable.
- The principle of using a unique, opaque identifier for each ring is sound.
- Separating `Ringing` and `Answered` states (Recast #2) is the correct approach to state machine design, assuming a proper discriminant exists.
- The low-level Android primitives under "What is NOT in question" have been pressure-tested and survived. They are a solid foundation.

**If RECAST, what to fold back:**
- **The wire identity is not optional.** Elevate Q1 from a question to a mandate. The `m` (server message id) from the island's invite **is** the ring identity. A local `ringId` is an implementation detail; the wire `m` is the source of truth. An invite without a unique message-level identifier is an invalid event and must be rejected. No wire ID, no ring. Full stop.
- **Redefine "duplicate" and the state machine using the wire identity.** An invite for `(channel, m)` is a duplicate if a ring for `(channel, m)` is already `Ringing` or `Answered`. An invite for `(channel, m_new)` that arrives while `(channel, m_old)` is `Answered` is correctly identified as a new call. The ambiguity dissolves.
- **Mandate systemic convergence.** Q3 notes the iOS client has its own patch (`answeredCallTrustWindow`) for the same ambiguity. This is not an Android-specific problem; it is a protocol flaw. The wire identity fix must be applied to the entire system, iOS included, to prevent entropy from creeping back in. One protocol, one identity, one state of matter.


## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. This design correctly diagnoses the recurring entropy source: channel identity is being reused for ring identity, so callbacks and buffered events become irreversible heat leaks into later rings. But the proposed local ring id is only a partial regenerator. It fixes in-process misdelivery, yet cannot distinguish duplicate delivery of the same invite from a legitimately new invite on the same channel. That makes Q1 not optional: wire identity is the fold-back. Dijkstra: "Simplicity is prerequisite for reliability." The simpler design is one call/invite identity from the island, carried end-to-end across Android, Dart, timers, buffers, notifications, and iOS. Local ids may still exist, but only as incarnation ids for runtime ownership, not as semantic call identity.

**Fatal flaws:**
- The design frames wire identity as an open question, but the stated failures prove it is a prerequisite. Without `{c,k,m}` or equivalent, duplicate-vs-redial is undecidable, so Q2 cannot be solved locally.
- A locally minted ring id prevents stale local events from hitting the current ring, but it cannot correlate `call_end reply_to`, duplicate FCM delivery, server retries, answered state, or cross-platform behavior. It removes some wrong-ring bugs while leaving the semantic hole intact.
- The duplicate policy is under-specified exactly where correctness matters most: `invite(c)` while `Answered(c)` can be either duplicate delivery or a new call. Any local-only rule will be wrong in one real case.
- The design still risks coupling identity to lifecycle. There are at least two identities here: the call/invite identity from the wire, and the local presentation/engine incarnation. Collapsing them into one `ringId` invites another round of accidental coupling.
- Blast radius is under-counted. If Android changes `call/actions` to `(channel, ringId)` but Dart, island `reply_to`, and iOS remain channel-keyed, the system has two identity models and therefore two failure surfaces.
- The engine-buffer proposal is directionally right but ownership is still muddy: 'buffered for the engine about to be created by this ring' needs a single owner state machine. Otherwise engine, activity, notification, and ring retirement can still race under nicer names.

**What holds:**
- The diagnosis that 'a ring is not a channel' is solid. The repeated findings are strong evidence of a missing domain concept, not isolated implementation defects.
- The timer patch to `(channel, at)` was a local preview of the right pattern: stale work must carry enough identity to prove it still belongs.
- Separating `Ringing` from `Answered` is correct. They are different facts with different lifetimes, exit conditions, and consumers. One SharedPreferences record doing both jobs violates thermodynamic reversibility: after overwrite, you cannot reconstruct which fact was true.
- Keying `SystemCallNavigator` by ring/call identity instead of channel is necessary. An `ended` for a newer or older call must not consume an answer for the admitted one.
- Moving held events from process-global state to engine-owned state is the right pressure gradient. Process-global buffers are entropy reservoirs: everything eventually mixes unless identity prevents it.
- The hardware-verified lock-screen flow, single answer door, FCM wake-lock work, and warmed engine are not the weak points. The weak point is semantic identity crossing their boundaries.

**If RECAST, what to fold back:**
- Make wire call identity mandatory: island sends `{c,k,m}` where `m` is the server invite/message id, and `call_end` names the same `m` via `reply_to` or an explicit field. If this contract cannot change, the design should say correctness is impossible for duplicate-vs-redial.
- Define two ids, not one: `callId` from the wire for semantic identity, and `ringInstanceId` minted locally for Android presentation/engine incarnation. Most state keys should include `callId`; local callbacks that can outlive their UI should also include `ringInstanceId`.
- Recast duplicate handling around `callId`: same `(channel, callId)` is duplicate/retry; same channel with different `callId` is a new call; `call_end(channel, callId)` ends only that call.
- Make `Answered` keyed by `(channel, callId)` with its own TTL and teardown path. New invites must not overwrite it unless they carry the same `callId` and are explicitly classified as duplicate delivery.
- Make the engine owner explicit: a per-call session object owns buffer, warmed engine lease, notification intents, activity binding, timers, and stop listeners. Retiring the session cancels or invalidates all children. Hamming: "The purpose of computing is insight, not numbers." The insight here is ownership, not more guards.
- Converge iOS in the same design pass. If `CallKitRinger` keys by channel and uses an 8h trust window to paper over duplicate pushes, it is carrying the same second-law leak. A platform split would preserve the defect in stereo.
- Only after the wire identity lands should Android carry `callId` through notification intents, keyguard callbacks, timers, held engine events, `call/actions`, and Dart admission. Feynman: "What I cannot create, I do not understand." Create the state machine explicitly, then implement it.

