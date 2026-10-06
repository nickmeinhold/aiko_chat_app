# TEMPER — Design 22 (a call is a type)

**Overall verdict:** RECAST (4/4: Maxwell, Kelvin, Carnot, Tesla; no DISSOLVE)
**Struck:** dt-1791273013, families seated: Maxwell + Kelvin (gemini-2.5-pro) + Carnot + Tesla (Wu disabled)
**Bundle:** design 22 (under strike) + grounding: app design 21 + its TEMPER, island design 12 incl. the 2026-10-06 call/2 addendum (71 KB).

## Per-family verdicts

| Family | Verdict | One line |
|---|---|---|
| Maxwell (Claude) | RECAST | v1 is to be READ forever, not RUNG: no store build ever placed a v1 call. Go v2-only and the null class dissolves instead of being typed |
| Kelvin (Gemini) | RECAST | §3's persisted answered set has no exhaust |
| Carnot (GPT) | RECAST | `CallRef` is right, but it is a partial of design 21 v2 (state-read + session) passed off as closure; FIFO isn't a correctness proof |
| Tesla (Grok) | RECAST | the incarnation id was dropped; channel in `==` blocks #3196; the set's snapshot is one cell; `retire` decides at run time; a null screen is a hot mic |

## Fatal flaws (deduped, most severe first) and dispositions

1. **The incarnation identity is missing from the design** (Tesla, Carnot). Design 21 v2 split *which call* (`callId`) from *which callback* (`ringInstanceId`). Design 22 kept only the first. FCM redelivers at least once, so a queued `retire` of `V2(c,m)` can land on a new ring of the same `m`. **Fold:** every native artifact (timer, intent, activity, keyguard callback, posted runnable) carries `(CallRef, instance)`. A runnable whose instance isn't current is a no-op. Android already has `instance`; iOS gets one on its row. Semantic tests replace the grep as the closure proof (the grep stays as a tripwire).
2. **v1 is mispriced** (Maxwell: don't ring it; Tesla: `V1(channel)` collapses every v1 call on a channel and swallows a redial; Carnot: spell out v1's degraded guarantees). **Fold: v2-only calling.** v1 sentinels render as history, forever, and never ring, admit, answer, end or announce. Measured: the v1 sentinel landed 2026-08-16, after 0.0.3 (08-10); calling was gated off from 0.0.4 and is off in every store build. The `V1` variant, the channel fallback, the random-UUID path and the v1 hangup's ack wait are deleted. **Needs Nick's confirmation**, as a behaviour change for dev builds. Cross-tab ask: the island stops waking for v1 bodies.
3. **`V2` equality including the channel** (Tesla against; Carnot for). **Fold:** equality is the ULID. The channel is stored beside it and checked at the door by ONE named policy function, `oneChannelPerCall` ("a call is one DM today"). That function is the seam #3196 / Decision 1b will change. Round 3's Android complaint is met at the door, not inside `==`.
4. **§3 (answered set): no exhaust** (Kelvin), **a one-cell snapshot of a multi-cell set** (Tesla), **compensating for missing ownership** (Carnot). **Fold:** native owns the one-answer rule. `answer(B)` ends A natively, in the same critical section: it ends A's system call and seals `ended(A)` for Dart. So the slot stays ONE cell, holding a `CallRef`, which is what design 21 item 3 asked for ("keyed by callId"). The set, its pruning and its snapshot problem are all gone.
5. **§4: `retire` decides at run time on global engine state** (Tesla); **FIFO is not a correctness proof** (Carnot). **Fold:** seal `(verb, CallRef, instance)` under the lock. The main-thread runnable does the engine work with that sealed value and never re-reads slots or the global engine to decide *what happened*. Only whether anyone is listening is decided late. Dart ignores an event for a `(CallRef, instance)` it does not hold. Add an ordering test: `end(A)` posted after `answer(A)` is never observed first. iOS `reportEnd` emits the same sealed `ended`.
6. **Design 21 item 4 (state-read) claimed as satisfied** (Carnot). **Disposition: named tradeoff, not closure.** Design 22 *supersedes* item 4 with "sealed, incarnation-tagged events, plus a snapshot on listen". The stale-phase hazard item 4 targeted is covered by flaw 1's incarnation check, and a third bridge rewrite in this PR fails the cap rule's shrinking-diff test. Owner: the app tab. Revisit if a stale-phase defect appears that the incarnation check does not stop.
7. **A null-call screen can hold a live room** (Tesla, Carnot). **Fold:** `/call` with no admitted `CallRef` does not join media. The route requires its extra, and a bare deep link redirects home. `CallScreen.call` is non-null, so "a joined room addressable by nothing" cannot be constructed.
8. **§5: the arm-site list is unwritten; the prune window could harvest a live row** (Tesla). **Fold:** the closed list of `armed` inserts is one site, the CallKit answer (verified: `CallAudioSession.arm()` is called only there; outgoing calls don't use CallKit audio). Pruning is **dropped** from the design: once disarm stops consulting the map, a corpse row costs nothing that the existing 8h window doesn't already bound.

## What holds (cross-family)

- One `fromWire`/`toWire` per language as the only place the wire's absence is interpreted (4/4).
- §2 refusals before side effects (4/4).
- §5's lifetime argument: a process-local audio lease belongs in process memory (4/4).
- Deleting `namesACall`, and owning the design 21 drift openly (Carnot, Tesla).

## Disposition

RECAST → fold flaws 1-8 into design 22 as **v2**, confirm flaw 2 (v2-only calling) with Nick, then re-strike (round 2 of ≤3).

<!-- Each section below was written when that family returned, before the others
     finished. Arrival order, NOT a ranking. Round 6 replaces this header with the
     synthesized verdict; if it never runs, what is here is still real. -->

## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST

**Summary:** Design 22 builds a type to carry v1 calls correctly forever, but no store build has ever placed or rung a v1 call, so the honest move is to stop RINGING v1 at all and let `CallRef` have one variant.

John McClane: "Now I have a machine gun. Ho-ho-ho."

**Fatal flaws:**
- **ILLEGAL MOVE — the premise "v1 is a permanent, legitimate identity" conflates READING with RINGING (§1, "What the record already says").** Island design 12's addendum says v1 is *recognised* forever, because it sits in signed history. That obliges the app to RENDER a v1 sentinel forever. It does not oblige the app to ring, admit, answer, end, or announce a v1 call. Measured: the v1 sentinel first landed 2026-08-16 (#139); 0.0.3 was cut 2026-08-10; calling was gated off before 0.0.4 (#170) and has stayed off in every store build since (0.0.5 verified OFF 2026-10-05). **No store build has ever placed a v1 call.** Every v1 invite in existence came from a dev build. The design spends its whole V1 variant, the `{c}`-only wake arm, Android's channel-fallback dedup, iOS's random-UUID path, and `CallEndAnnouncer`'s wait-for-ack (v1's `reply_to`) on a population of zero end users. Class: wrong option-frame + simpler alternative that dissolves.
- **Consequence: the null class dissolves instead of being typed.** With calling v2-only, a call identity is exactly a call/2 ULID, and `null` can mean only "names no call". There is no second meaning to type away. `CallRef` = `(channel, id)`, never optional inside, and `CallRef?` = "no call". Most of the round-3 instances evaporate rather than being converted: Android `sameCall`'s channel fallback, the v1-hold-vs-v2-hold matching in the navigator, the id-less `ended` rules, and the v1 hangup's ack wait.
- **Unstated cost the draft does not price: the diff GROWS.** The cap rule's question is "is the diff shrinking toward the fix?" A three-language type conversion of ~12 sites adds surface to a PR that has just failed to converge. A v2-only recast *deletes* code on every platform. The design should be judged by its delta size, and it does not state one.
- **§3 (answered set) is still owed under a v2-only frame**, and design 21 item 3 says so. But its justification needs restating: the set exists for "answer A, ring B, answer B, A's end", which is a v2-only scenario. Keep it.
- **Blast radius the draft misses: what a v1 WAKE does after the recast.** The island still sends v1 wakes (no `m`) and will keep recognising v1. Android: don't ring, log. iOS: must-report means a v1 VoIP push still has to be reported and ended, which is a momentary buzz per v1 invite from an old dev build. That's acceptable only because the population is Nick's own devices. Ask the island tab whether to stop sending VoIP/FCM call wakes for v1 bodies altogether; it's one line in their sender and removes the buzz.

**What holds:**
- §2 (refusals before side effects) — independent of the frame, and a real ordering rule.
- §4 (post inside the critical section) — still needed; v2-only doesn't remove the answer/end interleaving.
- §5 (an in-memory audio lease) — independent of identity entirely, and it fixes a pre-existing defect.
- The diagnosis table: the drift from design 21 items 3 and 4 is real and correctly owned.

**If RECAST, what to fold back:**
- Replace §1's two-variant `CallRef` with **v2-only calling**: v1 sentinels RENDER as history and never ring, never admit, never end, never announce. `CallRef(channel, id)` is a value class; `null` = names no call.
- Add a "what v1 does now" table per surface (render: yes; in-app ring: no; native ring: Android drop, iOS report-and-end; admission: refused with a named reason; hangup: never sent).
- Add a cross-tab ask: the island stops waking for v1 call bodies (it still stores and serves them).
- State the expected net delta (lines deleted vs added) and make "net negative" an acceptance criterion, per the cap rule.
- Pin the measurement behind the premise (the 08-10 / 08-16 dates, and calling OFF in every store build) so the next reader doesn't have to re-derive it.

---

<!-- landed 14:51:37 rc=0 -->
## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. Design 22 correctly attacks the entropy source in PR #210: nullable `callId` is carrying three thermodynamic states in one bit pattern, so every consumer re-derives identity and leaks heat into the next call. `CallRef` is a real simplification. But it is not the whole reversible engine promised by design 21 v2. The design narrows the problem from “state and ownership across native/Dart/iOS” to “typed equality”, then patches the remaining races with sets, buffers, ordering rules, and greps. That is wasted work. Dijkstra: "Simplicity is prerequisite for reliability." The fold-back is to keep `CallRef`, but make it the value inside the already-recorded design 21 v2 state-read/session model, not a substitute for it.

**Fatal flaws:**
- Contradicts the design 21 v2 record by declining full state-reading while claiming the original purpose is satisfied. Design 21 v2 item 4 deleted the held buffer and made `call/actions` a change signal followed by a native state read. Design 22 keeps event delivery, keeps Android snapshot semantics, keeps iOS `pending`, and then tries to prove events harmless by attaching `CallRef`. That fixes wrong-call action, but not stale-phase action, replayed transition order, or engine ownership. This is a partial against a recorded full recast, not just a scoped implementation note.
- The design deletes one ambiguity but leaves the bigger coupling: native/Dart still exchange transitions instead of state. §4’s “post inside the lock” is a guard around the coupling design 21 already dissolved. Posting under a lock does not make a distributed state machine reversible; it merely preserves one producer’s enqueue order. Feynman: "What I cannot create, I do not understand." The created thing should be a state machine with a read API, not a sequence of events whose interpretation depends on arrival timing.
- `CallRef` conflates semantic call identity with local presentation/incarnation ownership. Design 21 temper required `callId` for semantic identity and `ringInstanceId` or a per-call session for local callbacks, intents, timers, activities, and engine leases. Design 22 has `V2(channel,id)`, but no incarnation identity and no explicit session owner. A stale notification intent, keyguard callback, timer, or activity binding can still need to prove not merely “same call” but “same native incarnation of the call machinery.”
- The v1 treatment is under-priced. The record says v1 is read forever, yes, but design 22 elevates `V1(channel)` to a permanent legitimate identity without spelling out which v2 guarantees are impossible for it. A v1 call still has duplicate-vs-redial ambiguity and channel-only collision. If `CallRef` equality makes v1 feel equally safe, entropy has been renamed. The design needs explicit v1 degraded semantics and fences, not just a constructor.
- §3’s answered set is likely over-built because it compensates for not adopting state reads and session ownership. A persisted set of answered calls plus newest-entry snapshot plus Dart’s one-answer hold is a three-body orbit. The simpler engine is: native owns current call state keyed by `CallRef`, Dart reads it, and the product’s single-call rule is enforced in one transition table. Hamming: "The purpose of computing is insight, not numbers." The insight is ownership, not cardinality.
- §4’s FIFO claim is too local. Main looper FIFO gives order only among runnables posted to that looper; it does not prove semantic order across FCM workers, binder callbacks, CallKit/ConnectionService callbacks, persisted state reads, and Dart listener attachment. If the runnable decides what to emit at run time, the posted order is not necessarily the transition order unless the state version it reports is captured and monotonic.
- §5’s iOS audio lease fix is sound locally, but it exposes the missing unifying state model. `armed: Set<UUID>` is another lifecycle side table beside the map row and `CallRef`. It may be necessary, but the design does not say how UUID, `CallRef`, CallKit action, pending event, and Dart state cohere under reset, duplicate invite, displacement, and process restart. That is a blast-radius undercount.
- The “class closed by grep” test is a brittle proxy for design closure. It catches `String? callId` syntax, not semantic re-derivation through maps keyed by channel, UUID rows, route extras, persisted JSON, or bridge payloads. Source-text bans are insulation, not thermodynamics; they do not prove there is one owner of call identity.
- The deep-link/null question is not resolved. “Names no call” as `CallRef? = null` is clean, but a deep-linked `/call` screen joined to the same room as a system call can now be intentionally immune to system end. The design asserts this may be okay because it entered without CallKit; it does not prove the product invariant. Null should mean “no native call binding,” not silently answer whether the media session should remain joined.
- The design says “changes no wire bytes” as a virtue, but the record’s strongest lesson was that the wire id changed the problem. Now that call/2 exists, the app-side design should spend its complexity budget deleting legacy adaptation paths around events and nullable ids. Keeping the old bridge shape because the bytes are stable preserves the machinery that produced six review rounds.

**What holds:**
- The core diagnosis holds: `String? callId` is doing three jobs, and that is an entropy pump. A sealed `CallRef` with `V1(channel)` and `V2(channel,id)` is the right type-level correction.
- Structural equality requiring channel for v2 is correct for the current record. Island design 12 says a call lives in one DM, and the addendum pins `m` as copied from the signed body. Same id on another channel should not silently alias today.
- Moving malformed-wire interpretation into one `fromWire` per language is right. Absence means v1, valid presence means v2, malformed presence is rejected or must-report-ended depending on platform obligations. That removes a whole family of local reinterpretations.
- Deleting `namesACall` is good. A flag beside nullable identity is precisely the kind of irreversible heat leak that creates “honored here, forgotten there” defects.
- Refusals before side effects in §2 is a real invariant. Validation before displacement is the right order, especially for iOS must-report paths.
- The drift callout is honest: design 21 said answered is keyed by call, and the build had one answer slot. Naming that as drift rather than laundering it as implementation detail is good engineering hygiene.
- The iOS audio lease lifetime argument is strong. A persisted UUID map is the wrong oracle for a process-local audio lease; an in-memory armed set better matches the lifetime of the resource it describes.
- Keeping the island out of app-side `CallRef` object ownership is correct. The island carries `m`; it does not own a call object in this design tier.
- The proposed golden vectors and shared grammar tests are necessary. The ULID frame is part of the trust boundary, not formatting trivia.

**If RECAST, what to fold back:**
- Keep `CallRef`, but make it the canonical value in a native state-read API: Dart receives a change signal, then reads `{phase, call: CallRef, instance/version, timestamps}` from native. Delete transition replay as the primary bridge behavior.
- Reconcile explicitly with design 21 v2: either implement the full “state, not events” bridge now, or mark Design 22 as an interim deviation that does not close item 4. Do not claim the original purpose is satisfied by typed event equality alone.
- Introduce an explicit per-call session or incarnation/version concept for native-owned artifacts: notification intents, activity bindings, keyguard callbacks, timers, stop listeners, engine lease, and CallKit/ConnectionService UUID rows. `CallRef` identifies the semantic call; the session/version proves this callback still belongs to the live machinery.
- Define v1 as a degraded permanent compatibility mode. Spell out which guarantees v1 lacks, how long v1 rings may be admitted, what duplicate policy applies, and which tests prove v1 cannot poison v2 state.
- Replace the answered set with one native transition table if possible. If the set remains, justify it against the simpler state-read/session model and prove the exact race it alone handles by a RED test.
- For §4, capture a monotonic native state version inside the lock and have Dart read state by version, or emit only invalidation signals. Do not rely on looper FIFO as the design’s correctness proof.
- Unify iOS UUID map, `armed`, pending events, and `CallRef` under one documented ownership graph. Every end path should say which owner removes which row and whether Dart observes state, an event, or both.
- Replace the grep closure test with semantic tests around the dangerous boundaries: stale timer, stale activity/keyguard intent, duplicate v2 invite, v1 redial, cross-channel same-`m`, end-before-listen, answer-then-end race, iOS displacement, and process restart.
- Resolve the deep-link invariant: distinguish “no native call binding” from “media session should ignore native end,” and test the crafted/shared-link case explicitly.
- After folding, re-strike the smaller design: `CallRef` as type, native state as source of truth, session/version as owner. That is the Carnot improvement: fewer moving parts, less wasted work, less entropy to pump uphill.

---

<!-- landed 14:51:47 rc=0 -->
## KelvinBitBrawler's Design Strike

**Verdict:** RECAST

**Summary:** This design correctly lowers the temperature on a chaotic system by freezing ambiguity into a solid `CallRef` type, but it leaves one thermodynamic leak in the engine room.

**Fatal flaws:**
- **(Missing failure mode, §3)** The persisted Android `Answered` set is a state sink with no exhaust. The design specifies entries live for `ANSWERED_TRUST_MS`, but provides no mechanism to remove them from the persisted `Set` when that time expires or if an `end` event is lost. Unlike the iOS map which is explicitly pruned (§5), the Android set is doomed to accumulate corpses. This is a cold fault: a slow, entropic decay leading to unbounded growth of a preferences file. The system will eventually slow to absolute zero under the weight of its own history. `Roy Batty: "I've seen things you people wouldn't believe... All those moments will be lost in time, like tears in rain."` Here, they are not lost; they are cryogenically preserved forever in a JSON file.

**What holds:**
- The core of the design is sound. Replacing the `(channelId, callId?)` tuple-of-damnation with the sealed `CallRef` type is the correct phase transition. It dissolves an entire class of identity-aliasing bugs by moving interpretation to a single `fromWire` boundary, correctly modeling the v1/v2 reality from island design 12.
- The `grep` test in §1 is inspired. It is not enough to propose a better state; you must prove the deprecated one has been sublimated.
- The "refusals before side effects" rule in §2 is a necessary guard against state corruption.
- The concurrency fix in §4, posting to the looper from inside the critical section, correctly orders state changes and their notifications. The author's self-questioning reveals a healthy fear of multithreading, but the proposed mechanism is sound.
- The iOS audio lease fix in §5 is absolute zero for that problem. It correctly matches the lifetime of the lease to the in-process state that requires it, not to a persisted map of ghosts.

**If RECAST, what to fold back:**
- In §3, add an explicit garbage collection rule for the persisted Android `Answered` set. On every write to the set, it must also prune any entry `e` for which `now() > e.at + ANSWERED_TRUST_MS`. This mirrors the hygiene rule from §5, closes the thermodynamic loop, and makes the system stable over time.

---

<!-- landed 14:58:27 rc=0 -->
## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** `CallRef` tunes every consumer to the call's name, so a second incarnation of that name, a retire that chooses its note at runtime, and a snapshot that sounds only the newest cell are the frequency that shakes this design to glass at 3am (Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration.").

**Fatal flaws:**
- **§1 closes the fossil and leaves the oscillator.** Design 21 v2 item 2 split two identities on purpose: `callId` says what the call is, `ringInstanceId` says which local incarnation a timer, screen, keyguard callback, or posted runnable belongs to. Design 22 keeps the first and drops the second, then declares the class closed because `grep` finds no `String? callId` outside `fromWire`/`toWire`. That grep hears the absence of a string. It cannot hear a runnable. FCM is at-least-once: retire of `V2(c, m)` clears the live slot, posts its runnable, and a redelivery of the same `m` starts a new ring before the runnable runs. Both incarnations are the same `CallRef`, so the stale `ended` lands on the new ring. That is design 21's r3 "expired ring's posted `ended` fires against the new ring," still in the type. The same hum sits in the iOS row: §1's table says "the map key stays channel" while design 21 v2 item 5 says `CallKitRinger` keys by `callId`. One channel key, one row, two incarnations, and the second overwrites the UUID the first still needs.
- **§1's `V2(channel, id)` puts the channel back inside the identity the record just took out.** Island addendum and design 21 v2 item 3: the call is the client ULID; `end(callId)` ends that call; Answered is keyed by `callId`. Equality that also demands the channel makes `V2(c1, m) != V2(c2, m)`, and §2 step 3 then report-and-ends "this id live on another channel" as a bad payload. Decision 1b says Decision 1 stays forward-compatible with a gathering ACL, and #3196 is still open on whether a gathering spans islands. The first legitimate wake of one ULID on a second channel dies here, inside `==`, the one operator every converted site shares. The attack this buys is a stranger guessing 128 secure bits. Meanwhile the `V1(channel)` arm is that same channel wearing a sealed name. v1 is forever (addendum). Until call/2 is the live traffic, and for every v1 body after, `invite` during `ANSWERED_TRUST_MS` is a duplicate of the call just answered. Open question 4's two policies, the set versus "refuse ring while an answer is held," are one policy on the only arm that rings today. A redial inside the trust window is swallowed at every site that learned `==`, and no single site can opt out.
- **§3 remembers hangs with a reader that is deaf to them.** `answer` adds and never overwrites, so answer A, answer B, and the set holds both, specifically so A's later `call_end` can still emit `ended(A)`. `heldAnswer` then returns the newest entry. The release of A is delegated to Dart ("a second releases the first"), which only happens if Dart saw A. The cold-start listener, the path this whole ring exists for, attaches in that window, is handed B, and never held A, so it never ends A's system call. A stays answered, armed, and on the mic for `ANSWERED_TRUST_MS` while the UI is in B. "In practice the set is size 0 or 1 by the time a listener reads it" is a wish about the only interval the set was built to survive. Design 21's second unconverged class, one record doing two jobs, is now a JSON array in the same prefs whose public snapshot is still one cell.
- **§4 posts a rune and lets it decide later.** "The looper is FIFO, so lock order becomes delivery order" is true of payloads sealed under the lock. It is false of `retire`, whose runnable still chooses at runtime on main: "an engine survives, so tell Dart; else release it." That decision reads the process-global engine, not the call that posted it. Post A-retire, then a new invite obtains the engine, then the runnable runs, sees a survivor, and speaks about A's death with B's instrument in its hands. Open question 1 feels this and leaves it open. It is the flaw. A second queue between that runnable and the Dart channel (anything other than the platform call happening on this looper before the runnable returns) is a third oscillator, and a crash between the prefs commit and the post splits the store from the story Dart heard. iOS §4 adds `ended` on `reportEnd` and inherits the same unordered push into a navigator that still consumes events.
- **§1's null is a hot mic with no name.** "Null's only meaning is names no call" is the thesis, and open question 2 immediately posits a `/call` screen that has joined the room with `call == null`. A joined room is a call. The red button emits `ended(CallRef)` for the CallKit leg; null matches nothing; `stopRingingFor` no-ops; the screen keeps publishing. No `restorationScopeId` does not make this exotic. A shared link is a normal door, and so is any navigator that opens the route with only a channel. The three old meanings of null were v1, names-no-call, and nobody-passed-one. The fourth, "in the room and addressable by nothing," is what a null join compiles to. The type forbids representing it, so the mic stays open until the trust window or the process dies.
- **§5's census counts answers and then prunes by an unnamed window.** `arm()` inserts in exactly one place, the answer action, and every end disarms iff `armed` is empty. Any audio this process holds without that insert, an outgoing call being the obvious one, is invisible. The next decline of a waiting incoming finds an empty set and tears the lease down. That is the bug §5 exists to kill, aimed at the holder the set does not list. Separately, `mutateMap` "prunes rows past their window" on every write and never says whether the window is the ring TTL or the answered trust (design 21's iOS figure is 8h, the Android answer latch is `ANSWERED_TRUST_MS`). A write triggered by some other channel harvests the UUID of a call that is still connected. `reportEnd` looks up a corpse, the live CallKit call stays, and the in-app banner remains an answer door. The in-memory set was the right lifetime for the audio session. The map prune is a second lifetime, still coupled to the UUID `reportEnd` needs.

**What holds:**
- One meaning for null, once a joined screen is forbidden from using it. The v2 r2 deep-link disaster was a real three-way overload, and a sealed `V1 | V2` with a single `fromWire` per language is the right resonator for the bytes the addendum pinned. The golden-vector row across Dart, Kotlin, and Swift will hold.
- §2's order holds under load: parse, duplicate, cross-channel policy, and only then displace. Android `ring()` and iOS `reportInvite` finally share a sequence, and a refusal no longer spends a side effect first.
- §5's central insight holds: the audio lease and a map that outlives the process are different lifetimes, and `disarm` consulting the map will withhold `disarm` forever. Process death clears both the in-memory set and the audio session. `providerDidReset` clearing the set is the right "every call is gone."
- The refusal to touch wire bytes, to reopen the single-call product rule, and to pretend item 4 is done. Those scopes are honest. They stay survivable only after the folds below.

**If RECAST, what to fold back:**
- In §1, restore design 21 v2's second identity. `CallRef` answers "which call." A local incarnation, minted when a ring or answer presentation begins, answers "which callback." Every timer, keyguard callback, activity, and posted runnable carries both, and a runnable whose incarnation is no longer current is a no-op even when the `CallRef` matches. Replace the closure claim with three tests: the `grep`; a redelivery of the same `m` after a queued retire does not end the new incarnation; a v1 invite inside `ANSWERED_TRUST_MS` has its swallow-or-ring outcome written in the test name as a permanent v1 residue, per the addendum, not as a closed class.
- Take the channel out of `V2` equality. Equality is the ULID. The channel is the wake address stored beside the ref and checked at the door. Rewrite §2 step 3 as a named policy, "one live channel per id, because a call is one DM today," with one function as the seam Decision 1b / #3196 will change. Do not store that policy in `==`. State in §1 that `V1(channel)` collapses every v1 call on that channel for the life of the signed history, so open question 4's set and the refuse-window are the same rule for all current traffic.
- In §3, make native the owner of "one live answer." On `answer(B)`, end A's system call inside the same critical section that inserts B; do not wait for a Dart listener the snapshot is allowed to blind. `heldAnswer` returns every entry still in the set. Delete the sentence that says the set is in practice size 0 or 1. A's `call_end` may still emit `ended(A)` after that, and Dart must ignore `ended` for a call it does not hold.
- In §4, seal the payload under the lock: `CallRef`, incarnation, and the verb (`answered` or `ended`). The main-thread runnable performs the `AikoEngine` work with that sealed value and does not re-read global slots to decide whether an engine survives. Commit the prefs, then post, then drop the lock. The runnable invokes the platform channel before returning. Add the ordering test the open question is dancing around: `end(A)` posted after `answer(A)` cannot be observed first. Apply the same sealed `ended(call)` to iOS `reportEnd`.
- In §1 and open question 2, a route with `call == null` does not join media and does not publish. Joining resolves an admitted `CallRef` first. A deep link that cannot resolve stays a lobby. Hangup of a system call leaves the room for the ref it names, and there is no joined screen with nothing to match.
- In §5, write the closed list of `armed` insert sites. If outgoing audio is not on it, say so as a fact and keep outgoing off `disarmIfNoCallRemains`. Define the prune window: a row whose UUID is in `armed`, or whose `CallRef` is still inside the answer trust, is not a corpse. Keep the channel-keyed map only as an occupancy index under the one-call-per-channel displacement rule, and say explicitly that this departs from design 21 v2 item 5, with the incarnation-bearing row as the identity `reportEnd` looks up.
- Close the five open questions in the doc with those rulings so the next cage-match cannot treat them as still open.
