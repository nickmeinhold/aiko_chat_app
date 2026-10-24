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


---

# Re-strike round 2 (dt-1791281130) — against design 22 v2: RECAST 4/4 (narrower; folded as v3)

_Each family lands below as it returns. Arrival order, not a ranking._

---

<!-- landed 17:06:04 (in-process) -->
## MaxwellMergeSlam's Design Strike (re-strike round 2)

**Verdict:** RECAST

**Summary:** v2 closes round 1's flaws, but v2.3 lets native "end A on answer(B)" act on a fact it cannot see: whether A is still a held answer or already a live call in Dart.

Hans Gruber: "When you steal $600, you can just disappear. When you steal 600 million, they will find you."

**Fatal flaws:**
- **v2.3: the native answer slot conflates "held for Dart" with "in a call" (unstated assumption).** The slot means *answered, not yet joined*. Dart consumes the hold when it joins, but nothing tells native, so the slot persists for `ANSWERED_TRUST_MS` (120s) after A is already live. Inside that window, `answer(B)` ends A natively: the newest answer wins. Dart's own rule for the same moment is the opposite: `isInLiveCall` refuses B (`alreadyInLiveCall`), and the in-app banner says "You're already in a call". **Two doors, two opposite single-call rules, decided by whether 120s have elapsed.** After 120s, A's slot has expired, so native passes B through and Dart refuses it. Before 120s, native kills a live A. Fold: native must learn the hold was consumed. Dart calls a bridge `consumed(ref)` when it joins, and native clears the slot. Then `answer(B)` over a *held* A ends A (a hold is not a call), and over a joined A defers to Dart's refusal, as today. One rule: **a hold yields; a live call refuses.**
- **v2.1's iOS `instance` guards nothing named (wasted machinery).** Android needs `instance` because it has deferred artifacts: posted runnables, PendingIntents, a timer, an activity. After a86bf64, iOS runs every handler synchronously on main, and its only deferred artifact is a CallKit action, which already carries the UUID. A UUID is derived from `m`, and a same-`m` redelivery while live is a duplicate by §2. The design should either name the iOS deferred artifact an `instance` protects, or drop it from iOS. Otherwise it's a third identity added to the one platform where the race no longer exists.
- **v2.5's redirect needs the caller's door named.** The caller pushes `/call` with an extra carrying the ref it minted, which is fine. But `conversation_actions.startCall` mints the ref before the invite send completes, and the `finally` path that announces a hangup after a failed send must keep the ref. The design should say the outgoing ref exists from mint, independent of the ack. v2.0 deletes the ack wait, so this is now true, but it's unstated.

**What holds:**
- v2.0 v2-only: the premise is measured and confirmed, and it deletes more than it adds.
- v2.1's channel-out-of-equality with `oneChannelPerCall` as the one seam. Right for #3196.
- v2.4's sealed `(verb, ref, instance)` and the named supersession of design 21 item 4, with a revisit trigger.
- v2.6 dropping the prune: correct once disarm stops reading the map.
- The closure-proof test list: concrete and RED-provable.

**If RECAST, what to fold back:**
- v2.3: add `consumed(ref)` (Dart → native, on join). Restate the rule as "a hold yields to a newer answer; a live call refuses it", the same at both doors. Add test 8: `answer(B)` within 120s after A was joined does not end A.
- v2.1: name iOS's deferred artifacts or drop iOS `instance`.
- v2.5: state that the outgoing `CallRef` exists from mint, before the ack.

---

<!-- landed 17:06:36 rc=0 -->
## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. v2 closes most round-1 leaks: v1 is no longer dignified as a live call, nullable identity is gone, channel policy moved out of equality, incarnation comes back, and the answered set is deleted. That is real entropy reduction. But the recast now hides two different product/state machines behind one word, “answer,” and the sealed-event model still has an ownership hole at the outgoing/Dart edge. Dijkstra: "Simplicity is prerequisite for reliability." This is fixable, but not sound yet.

**Fatal flaws:**
- v2.3 changes the single-call product rule without paying the product cost. The earlier design explicitly kept “answering a second call while in one ends the new one” as pinned behavior. v2.3 flips native incoming behavior to “newer answer wins”: answer(B) ends A, replaces the slot, and emits ended(A) before answered(B). That is not a mechanical fold; it is a user-visible policy change. Worse, in-app and native can now disagree: in-app may refuse B while native accepts B and kills A. This is a wrong option-frame, not just an implementation detail. Fold-back: name one product transition table for all entry points. Either second answer is refused everywhere, or switch-call is accepted everywhere with explicit UI/audio semantics and tests.
- The incarnation model is underspecified for non-ring entry points, especially outgoing/caller screens. v2.1 says instance is minted natively when a ring or answer presentation begins, while v2.5 says the caller’s own screen carries the ref it minted. v2.4 then says Dart ignores events for a `(ref, instance)` it does not hold. What instance does an outgoing Dart-created call hold before native presentation exists? If the answer is “none,” the design has reintroduced a privileged null-like state at the most dangerous boundary. Feynman: "What I cannot create, I do not understand." Fold-back: every joined call has a session/incarnation before media joins, including outgoing, or events to outgoing calls must use a separate, explicit state-read path.
- `oneChannelPerCall` is named as a door policy but the doors are not closed-list enumerated. The design says channel is stored beside the ref and checked “at the door,” but the surfaces include invite, end, admitRing, reportEnd, Dart route admission, native actions, pending runnables, and snapshots. If any end/action path constructs `CallRef(id)` and skips the channel policy, a same-ULID payload from another channel can match by equality and affect the live call. Moving policy out of `==` is right; failing to enumerate every enforcement point is the new entropy leak.
- v2.4 still substitutes ordered sealed events for design 21’s state-read model, and the supersession is only partly justified. Sealing `(verb, ref, instance)` fixes wrong-call and stale-incarnation events, but not listener attach/crash boundaries: a commit can occur, the process can die before the posted event reaches Dart, and the next listener only gets whatever snapshot exists. The design mentions snapshot on listen, but does not define its full state shape, version, or precedence against queued sealed events. Hamming: "The purpose of computing is insight, not numbers." The insight is a single native state table plus invalidations; if keeping events, specify the snapshot as authoritative and make event delivery purely advisory.
- The v1-only-as-history fold mostly dissolves the null class, but the iOS report-and-end buzz remains a known remote-visible side effect until the island stops waking v1. Calling it “old dev builds only” depends on a measured deployment premise, not a protocol invariant. If any island or test environment emits v1 VoIP wakes, users can still see system call UI for a thing the app says is not a call. Fold-back: make “stop waking v1” a prerequisite for iOS v2-only behavior, or explicitly accept and test the buzz as compatibility debt with an owner and removal trigger.
- The “net negative line count” acceptance criterion is thermodynamic theater unless tied to semantic deletion. A smaller diff can still preserve the wrong state machine; a larger diff can delete a failure class. Use it as a smell, not a gate. The real acceptance criterion is fewer owners of call state, fewer transition interpreters, and tests proving stale artifacts are inert.

**What holds:**
- v2-only calling is the right dissolution if the measured premise is accepted: v1 renders as signed history and never becomes a live call. That deletes the V1 identity swamp instead of insulating it.
- `CallRef(id)` with equality by ULID is cleaner than `V2(channel,id)`. Channel is policy, not identity, and one named `oneChannelPerCall` seam is the correct place for future #3196/gathering changes.
- Restoring incarnation identity is essential and correct. Every timer, intent, activity, keyguard callback, native row, and posted runnable must prove both “same call” and “same local machinery.”
- Refusals before side effects holds. Parse, duplicate, cross-channel policy, then displacement is the reversible order; side effects before validation were the heat leak.
- Deleting the answered set is an improvement. The set was a compensating structure for unclear ownership; a single native owner of the answer slot is simpler.
- Sealing event payloads under the critical section is better than posting a runnable that re-derives what happened later. The runnable may decide whether anyone is listening, but not what transition occurred.
- The audio lease fold holds: `armed: Set<UUID>` in memory matches the lifetime of CallKit audio better than a persisted UUID map. Dropping pruning is also correct once disarm no longer consults stale rows.
- `/call` requiring an admitted non-null call is the right fix. A joined room addressable by nothing was a hot mic with a philosophical hat on.

**If RECAST, what to fold back:**
- Write the single-call transition table explicitly and apply it to native, Dart, Android, and iOS. Decide whether second answer wins or is refused; do not let entry point choose policy.
- Define `CallSession = (ref, instance, channel, phase)` as the thing Dart/native hold. Mint it before any media join for both incoming and outgoing calls. Then `CallRef` is semantic identity, and `CallSession` is local ownership.
- Closed-list every `oneChannelPerCall` enforcement site: invite wake, end wake, admitRing/admission, native action, reportEnd/endSystemCall, Dart route construction, snapshot read, and queued runnable execution. Add tests proving same `m` on another channel cannot end, answer, stop, or admit the live call.
- Make snapshot-on-listen authoritative. Specify the snapshot shape, its version/instance, and how queued sealed events interact with it after crash, listener attach, and engine replacement. If events remain, call them invalidations with payloads, not the source of truth.
- For v1 iOS wakes, either require the island change before app behavior is considered closed, or add a named compatibility debt: report-and-end may buzz, owner island, removal when v1 wakes stop, tested on hardware.
- Replace the line-count gate with semantic gates: no nullable call identity in live paths, no joined room without a session, no stale artifact can affect a new instance, same id on another channel is refused before side effects, answer/end order is stable across crash/listen boundaries. Then line count can be an odor, not a law.

---

<!-- landed 17:07:47 rc=0 -->
## KelvinBitBrawler's Design Strike

**Verdict:** RECAST

**Summary:** The design achieves a brilliant, simplifying chill by freezing out v1 and clarifying identity, but its break-before-make answer model creates a new cold fault, a path to total connection loss.

**Fatal flaws:**
- **(Missing failure mode, v2.3)** The `answer(B)`-over-`A` transition is a destructive, non-atomic operation at the user level, guaranteeing data loss. The design celebrates ending call `A` within the same critical section that anoints `B`, calling this a simplification. It is, but at absolute zero cost to the user's connection. "Answering" a call involves fallible operations beyond this critical section: media negotiation, resource allocation. If any of these fail for `B` *after* `A` has been terminated, the user is left with no call at all. The system has failed to a state of total communications blackout, sacrificing connection resilience for state-machine purity. This is an unacceptable thermodynamic loss. `Frank Herbert, Dune: "A beginning is a very delicate time."` This design burns the transport ship before confirming the new planet has a breathable atmosphere.

**What holds:**
- The v2-only premise (v2.0) is a masterstroke of simplification, correctly using measurement to sublimate an entire class of legacy problems.
- The `CallRef(id)` and `instance` dual-identity model (v2.1) is the correct phase transition, separating *what* call from *which incarnation*. This fundamentally resolves the oscillations of the prior design.
- Sealing event payloads (`verb`, `ref`, `instance`) under a lock before posting (v2.4) is a robust pattern that prevents runnables from acting on stale realities.
- Eliminating the unaddressable, joined "hot mic" state (v2.5) plugs a critical vacuum leak.
- The in-memory `armed` set (v2.6) correctly matches the audio lease's lifetime to the process that owns it, fixing a fundamental flaw in the previous persistence model.

**If RECAST, what to fold back:**
- The transition for `answer(B)`-over-`A` in v2.3 must be converted to a **make-before-break** pattern. The system must fully establish and stabilize call `B` before terminating the native resources and system call for `A`. If answering `B` fails at any point, the process must be aborted, leaving call `A` completely untouched. This preserves the user's active connection, which is the system's prime directive. The state machine must serve the connection, not the other way around.

---

<!-- landed 17:11:37 rc=0 -->
## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** v2 tunes the call to a ULID and tags the local incarnation, then leaves the engine lease, the Dart hold, and the audio lease humming in three different keys, so the first swap, the first decline during an outgoing, and the first VoIP v1 wake are the frequency that shakes the glass at 3am (Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration.").

**Fatal flaws:**
- **The ninth seat is still empty (v2.1, v2.4, open question 2; folds 1 and 5 incomplete).** Three names are written down: `CallRef` (which call), `instance` (which incarnation), CallKit UUID (which system row). Six places keep them: the wire, the one answer cell, native artifacts, the iOS map, `armed`, Dart's hold. The ninth is the engine lease. Design 21 v2 item 2 gave that lease to the session; v2.1 hangs `(ref, instance)` on timers, intents, the activity, the keyguard callback, and the posted runnable, and leaves `AikoEngine` as a process-global instrument. v2.4 seals `(verb, ref, instance)` so the runnable no longer decides *what happened*, then lets it decide *whether the engine lives* with `releaseIfHeadless` at run time. FCM redelivers at least once. The queued retire of instance 1 runs after instance 2 has `obtain`ed the same engine for a live ring, sees no Dart listener yet (the warm is for `admitRing`, the `call/actions` listener attaches later), and releases instance 2's instrument. Native still shows B; answer talks to a dead engine. Open question 2 is this flaw, named. Naming it did not close it.
- **Dart is asked to match a chord it is never handed (v2.1, v2.3, v2.4, v2.5).** The snapshot on listen is one cell holding a `CallRef`. The seal is `(verb, ref, instance)`. The ignore rule is "Dart ignores an event for a `(ref, instance)` it does not hold." `CallScreen.call` is a `CallRef`. Those four sentences cannot be implemented together. A cold-start listener that obeys the ignore rule has no instance and drops every event, including the `ended` that arrives because the user already hung up in system UI. A listener that matches on `CallRef` alone reopens design 21's r3: the expired ring's posted `ended` against the new incarnation of the same `m`. The snapshot also has no ringing phase and no channel; `call/actions` is still the pipe; iOS `pending` is no longer named. An `ended` posted before listen has nowhere to sit on Android, so Dart admits from history and leaves the in-app banner up for a call the system already buried. Fold 6 superseded design 21 item 4 with "events plus a snapshot"; the snapshot's contents were never written, so the deaf path is back inside the replacement.
- **`armed` still disarms on an empty census, and test 7 sings the opposite note (v2.3, v2.6, closure test 7; fold 8 incomplete).** The operational rule is "every end of a UUID removes it; disarm iff the set is now empty." Ending a UUID that was never inserted leaves the set empty, and "iff empty" fires `disarm()`. Closure test 7 says that path never disarms. The prose and the proof cannot both be the design. The 3am that test 7 exists for: an outgoing call (v2.6: not an `arm()` site, same `CallAudioSession` the lease describes), an incoming rings, the user declines. B was never in `armed`. Remove is a no-op, the set is empty, `disarm()` tears the outgoing mic down. The same empty-census fires on the v2.3 swap: `answer(B)` ends A in one critical section; remove A, set empty, `disarm()`, then `arm()` B. Audio dies in the gap, and B answers into a muted session. Decline-B-while-A-connected is safe only because A remains in the set; the swap and the outgoing+decline are the two notes that hit the vacuum. Fold 8 closed the insert list and dropped prune; it left the predicate that made `CXEndCallAction` lethal.
- **The map's exhaust was prune; v2.6 deletes prune and does not write delete-on-end (v2.6; Kelvin's leak in a new jar).** Disarm no longer consults the persisted map, so a corpse cannot withhold audio. The map still maps UUID to row across process death, which is the only way a killed app restores a live CallKit call. Rows that are never deleted and never pruned accumulate for the life of the install. Rows that a time window would have harvested can also stay as occupancy for a channel that has already moved on, so the next `reportInvite` on that channel displaces a ghost UUID or overwrites the UUID instance 2 still needs. The in-memory set was the right lifetime for audio. The map still needs a death: delete the row when that UUID ends, keep it while ringing or answered, and never harvest a UUID that is in `armed`.
- **v1 on the VoIP pipe is a revocation primitive until the island stops sending it (v2.0, open question 3; island Decision 4).** v2.0's iOS cell is report-and-end: a momentary buzz, "old dev builds only." Island Decision 4 is the standing law of that pipe: every VoIP push is a call, the client must report before the handler returns, and repeated junk reports revoke the privilege. v2.0's table makes "not a call" the app's truth about v1, then uses the call pipe to report it. The cross-tab ask (stop waking on v1 bodies) is the only cut that removes the buzz *and* the entitlement storm. Until that ask is a shipping gate, every leftover v1 wake in a calling-ON build is a CallKit transaction Apple is entitled to count against the app. Open question 3 prices this as taste. It is blast radius.
- **`answer(B)` ends A inverts the pinned one-call product on the only path CallKit actually presents (v2.3, open question 1; v1 "Not in this design").** Kelvin's pinned test: a second answer while in a call ends the *new* one. v2.3: the native transition ends *A*, "the newer answer wins." In-app refuse-B and lock-screen accept-B-kill-A are two products for one user. Call-waiting was measured on 2026-09-20; §5's `armed` set exists so declining B leaves A's audio up. Answering B now performs a programmatic end of A, which CallKit will also surface as the connected call dying under the user's finger. Combined with the empty-set disarm above, the swap is how a user who taps Answer on the waiting call loses both mics for a beat and the first remote hears a hangup. The set was killed so a hangup of A could not be lost; the fold made A dead instead of remembered. That is a coherent one-cell machine only after the product is pinned to *one* winner on *every* UI, and the native transition is a replace that never takes the disarm path in the middle.

**What holds:**
- v2-only calling. No store build has ever placed a v1 call; rendering v1 as history and refusing it at `admitRing` / Android drop dissolves the `V1(channel)` arm, the random-UUID path, `sameCall`'s fallback, and the announcer's `reply_to` wait. Maxwell's option-frame was right, and Nick's confirmation holds it.
- `CallRef` as a grammar-checked ULID, equality on the id alone, channel stored beside it, `oneChannelPerCall` as the single seam Decision 1b / #3196 will change. Round 3's Android channel skip is met at the door. `==` stays a tuning fork, not a policy engine.
- One `fromWire` / `toWire` per language as the only place absence is interpreted; malformed `m` still drops or must-report-ends; golden vectors across three languages.
- §2's order: parse, duplicate, door policy, then displace. A refusal spends no side effect.
- Native instance on artifacts, with a stale instance a no-op. That is the right second oscillator for FCM's at-least-once, and closure test 1 is the right proof of it.
- v2.5: a joined room requires an admitted `CallRef`; a bare `/call` goes home; `namesACall` stays dead. The hot mic with no name cannot be constructed.
- §5's lifetime insight: a process-local audio lease belongs in process memory; `providerDidReset` clears it; process death ends the lease and the session together.
- Sealing *what happened* under the lock, plus the ordering test that `end` committed after `answer` for one ref is never observed first. FIFO was never the proof; the seal is.
- Net-negative delta as acceptance, grep as tripwire, seven semantic tests as the real closure list. The class is being proved, not merely named.
- Wire bytes untouched; island still owns no call object.

**If RECAST, what to fold back:**
- **Write the session.** One native object, key `(CallRef, instance)`, owns the engine lease, the ConnectionService/CallKit UUID, the answer cell, the armed bit, and the channel stored beside the ref. Mint it when a ring or answer presentation begins. Every artifact already listed in v2.1 points at it. Retiring it drops *this instance's* engine claim, sealed beside the verb; `releaseIfHeadless` becomes "this claim released, release the engine only if no other session holds a claim," never a global census of listeners at run time.
- **Make Dart's hold, the snapshot, and the seal the same shape.** On listen, Dart reads `{phase, ref, instance, channel}` (ringing or answered or empty). Events may still wake it; they carry that same tuple. Dart ignores a tuple it does not hold. `CallScreen` takes the admitted session's `CallRef` *and* keeps the instance for as long as it is joined. Delete the sentence that the answer cell is the snapshot. iOS `pending` is named as the pre-listen buffer until the snapshot includes ringing and ended-while-headless.
- **Rewrite the disarm predicate so test 7 *is* the rule.** Disarm only when a UUID that *was* in `armed` is removed and the set is then empty. Ending an unarmed UUID is a no-op on the lease. `answer(B)` while A is answered is a *replace*: insert B, remove A, never pass through empty. Same critical section, same main queue. Predicted device test: decline waiting B while outgoing (or connected A) is live → audio survives; answer B while A is connected → A's audio ends, B's audio lives, no mute gap.
- **Map exhaust:** delete the row when that UUID ends; keep it while the session is ringing or answered (process death still restores a live CallKit call); no time-based prune. Duplicate detection is live-session identity (`CallRef` + instance), not a corpse in prefs.
- **Island stop-waking-v1 is a shipping gate** for any calling-ON build that reports VoIP. Until it lands, iOS v1 policy stays report-and-end *and* the entitlement risk is written in v2.0's table as a counted blast, not "a momentary buzz." Android drop stays.
- **Pin the one-call product in one sentence both UIs obey.** Either a second answer is refused everywhere (A lives, B's system call is ended as the already-in-a-call refusal), or a second answer switches everywhere (replace as above). Strike "newer wins" as an inversion of a pinned test unless that test is rewritten in this design. Call-waiting UI remains a later product question; it cannot disagree with the native transition that already ends A.
- **Close the three open questions with those rulings** so the next cage-match is a delta against a finished identity, not another pass at the same oscillator.


---

# Re-strike round 3 (dt-1791281566, FINAL) — against design 22 v3: RECAST 3/4 (Maxwell SOUND) — TEMPER CAP REACHED

---

<!-- landed 17:13:17 (in-process) -->
## MaxwellMergeSlam's Design Strike (re-strike round 3, final)

**Verdict:** SOUND

**Summary:** v3 closes round 2 by restoring a rule instead of inventing one (the pinned one-call refusal) and by deleting a scenario instead of guarding it (the tombstone). One transport assumption under the tombstone needs pinning before build.

Ellen Ripley: "Did IQs just drop sharply while I was away?" (No. They went up: round 3 is shorter than round 2.)

**Fatal flaws:**
- none fatal. One **unstated assumption to pin (v3.2):** "a later redelivery cannot arrive" rests on the island's push TTL being the ring ceiling on BOTH transports. FCM's invite TTL is stated (30s, design 21 / island). The APNs VoIP `apns-expiration` for `call_invite` is not stated in this bundle. If APNs can hold a VoIP invite longer than the tombstone (60s) for an offline device, iOS would report a dead call as new. Bounded (CallKit self-expiry, the island's `call_end`), but the tombstone's TTL must be derived from the larger of the two transport TTLs, not from the ring ceiling. Ask the island for the APNs figure, and set the tombstone to max(FCM TTL, APNs expiration) × 2.

**What holds:**
- v3.1: the second answer is refused at every door. The swap, the mute gap and the break-before-make all disappear with it, and the pinned test was already right.
- v3.1's cross-window consistency argument: native refuses while the cell lives, Dart refuses after, and the outcome is the same. No new signal is needed.
- v3.2: the tombstone makes `CallRef` name one ring, which is what lets Dart key by ref alone and drops iOS `instance`. Deleting a scenario beats guarding it.
- v3.3: one shape for the snapshot, the hold and the event; iOS `pending` named and ref-keyed.
- v3.4: engine claims by ref, so a retire releases only its own claim.
- v3.5: the disarm predicate is now test 10 itself.
- v3.6: a closed list of four doors.
- v3.7: v1 VoIP as a shipping gate with an owner.

**If RECAST, what to fold back:**
- (Not a RECAST.) Before build: pin the APNs VoIP expiration for `call_invite` with the island tab, and derive the tombstone TTL from it.

> **Maxwell's assumption, pinned (read from island `src/aiko_gateway/domain/apns.py`, 2026-10-06):** VoIP invite lease `_VOIP_LEASE_SECONDS = 30`; alert pushes `_ALERT_EXPIRATION_SECONDS = 60`; VoIP end `_VOIP_END_EXPIRATION_SECONDS = 300`; FCM invite TTL = 30s. The longest an invite can be stored is **60s**, so v3.2's `RING_CEILING_MS × 2` (60s) sits exactly on the edge. **Build with tombstone TTL = 2 × max invite lease = 120s**, and name the derivation in code.

---

<!-- landed 17:13:48 rc=0 -->
## KelvinBitBrawler's Design Strike

**Verdict:** RECAST

**Summary:** The design replaces an oscillating failure with a slow, freezing one by introducing a persistent tombstone state with no exhaust.

**Fatal flaws:**
- **(Unstated Assumption / Missing Failure Mode, v3.2)** The tombstone is a thermodynamic dead end. The design introduces a new class of persisted state (`tombstone` for a `CallRef`) to prevent re-ringing but fails to specify its exhaust mechanism. It defines a TTL (`RING_CEILING_MS × 2`) but is silent on the process that removes expired entries from persistent storage. This creates a resource leak; the tombstone store will grow indefinitely, a slow accumulation of entropy that will eventually degrade or break the system. A state machine must account for the total lifecycle of its artifacts, including their disposal. `Roy Batty: "All those moments will be lost in time, like tears in rain."` Except these tears are written to disk and never wiped away.

**What holds:**
- The `v2-only` premise, folded from the v2 temper, is the correct, simplifying dissolution of the v1 state class.
- Refusing the second answer (`v3.1`) is a safe, conservative resolution to the break-before-make failure, correctly prioritizing connection stability over a feature (call-waiting) that is not yet built.
- The unified `CallState` shape (`v3.3`) for snapshots and events brings necessary clarity and consistency to the native-Dart boundary.
- The explicit engine claims (`v3.4`) and the precise audio lease predicate (`v3.5`) correctly model resource ownership and prevent the previously identified leaks.
- The enumeration of `oneChannelPerCall` doors (`v3.6`) closes the cross-channel policy hole identified in the prior round.

**If RECAST, what to fold back:**
- Amend v3.2 to specify the tombstone exhaust. The same mechanism that writes a tombstone must also be responsible for garbage-collecting expired entries from the persisted store. This could be a simple periodic sweep on app start, or a GC pass piggy-backed on any new tombstone write. The design must state the mechanism that ensures the set of tombstones does not grow infinitely.

---

<!-- landed 17:13:48 rc=0 -->
## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. v3 is much closer: it deletes the swap, deletes Dart-visible incarnation machinery, names the snapshot shape, gives the engine a per-call lease, and turns the v1 VoIP problem into a gate. Entropy is down. But the design still lets native and Dart split authority over the single-call rule, and the tombstone proof rests on TTL assumptions that are not closed across every wake pipe. Dijkstra: "Simplicity is prerequisite for reliability." This is fixable, but not sound.

**Fatal flaws:**
- v3.1 says the product rule is "a second answer is REFUSED" everywhere, then admits that after the 120s answer trust window native passes B and Dart refuses via `alreadyInLiveCall`. That is not the same door, and it is not the same side-effect profile. Native has already accepted the system action, may dismiss UI, may touch audio, and may emit an answered-shaped transition before Dart kills B. The design has removed the swap, but it has not given native the fact it needs: whether a live Dart call exists after the answer cell expires. Fold-back: either native has a live-call claim/lease from Dart, or native never performs answer side effects for B until Dart admission confirms no live call.
- v3.2's tombstone dissolves instances by assuming a redelivered invite cannot arrive after `RING_CEILING_MS × 2` because the island's FCM invite TTL is the ring ceiling. That proof is transport-specific while the design is Android+iOS. The v1 section correctly prices VoIP as special, but the tombstone section does not state the APNs/VoIP expiration contract, offline delivery behavior, or island gate that makes the same proof true there. Feynman: "What I cannot create, I do not understand." Fold-back: make the tombstone lifetime a protocol invariant for every call wake transport, or keep instance protection on any platform/path where the TTL proof is not physically true.
- v3.6's `oneChannelPerCall` door list still mixes two different events under one Dart door: `admitRing` and `admitCallEnd`. An end is not just admission; it is a destructive action against existing UI/state. If an end with the same `m` and wrong channel reaches Dart after equality-by-ref, the only thing preventing cross-channel damage is this door. The design needs to say the wrong-channel end is refused before it can stop banners, close routes, clear holds, or write tombstones. The second law bites here: once a destructive event has diffused into consumers, you do not get reversibility back by documenting the policy upstream.
- `CallState = {phase, ref, channel}` is still missing ownership of the joined media session. v3 intentionally deletes Dart-visible `instance`, which is fine if a `CallRef` names at most one ring, but a live joined call can outlast native ring state, answer trust, process restarts, and tombstone windows. The design says Dart holds `CallState`, yet does not define when that state is consumed, cleared, or revalidated against native after crash/listen boundaries. Hamming: "The purpose of computing is insight, not numbers." The insight should be one native/Dart session ownership story, not a snapshot plus hope.
- v3.7 makes stopping v1 VoIP wakes a shipping gate for 0.0.6, which is the right price, but v3.8's acceptance gates do not list that gate. That turns a release blocker back into prose. Fold-back: add the island v1-wake stop as an explicit semantic gate alongside tests 1-10, with owner and verification signal.

**What holds:**
- v2-only calling still holds. Refusing to model `V1(channel)` as a live call dissolves the nullable-string swamp instead of insulating it.
- `CallRef(id)` equality by ULID, with channel as a door policy, is the right separation. Identity should not smuggle today's topology.
- v3.1 correctly rejects v2.3's newer-answer-wins swap. Refuse-B is the product rule that matches the pinned behavior and avoids break-before-make audio loss.
- v3.2's tombstone is a strong simplification where the TTL premise is true. If a call can ring only once per device, Dart does not need an incarnation token for that call.
- v3.3 improves the event model by making snapshot, hold, and event share one shape. That is real entropy reduction over sealed events with a hidden tuple Dart never received.
- v3.4's engine `claims: Set<CallRef>` is the correct direction: a queued retire of A must release A's claim, not consult a global listener census and accidentally kill B's engine.
- v3.5 states the audio lease predicate exactly: ending an unarmed UUID must not disarm. That closes Tesla's empty-set trap.
- v3.7 correctly prices v1 VoIP wakes as entitlement blast radius, not a cosmetic buzz.

**If RECAST, what to fold back:**
- Give native an explicit live-call/admission claim from Dart, or make native answer side effects provisional until Dart confirms admission. The single-call rule must be enforced with the same facts at every door, including after the 120s answer cell expires.
- Promote the tombstone TTL proof to a cross-transport invariant. Name FCM, APNs/VoIP, island expiration, and device behavior; where the invariant cannot be proven, keep a local instance guard.
- Split and test destructive wrong-channel ends separately from wrong-channel invites. Same `m` on another channel must not stop a banner, close a route, clear a hold, end a system call, or write a tombstone.
- Define the joined-call lifecycle: who owns it, when `CallState` is consumed, how it survives listener attach/crash, and how native learns enough to refuse later answers consistently.
- Move the v1 VoIP island change into the acceptance gate list. A gate that is not in acceptance is just heat leaking through polished prose.

> **Derivation, final (island tab, 2026-10-06 17:14, as of PR #192 77ca1ab):** invite lifetimes are
> APNs VoIP 30s and FCM 30s, both `push_result.RING_CEILING_SECONDS`, and APNs alert 60s
> (`apns._ALERT_EXPIRATION_SECONDS`, the max). **Tombstone TTL = 2 × max(RING_CEILING_SECONDS,
> _ALERT_EXPIRATION_SECONDS) = 120s**, and the code comment cites those two names. **The tombstone
> gates INVITES only.** Ends (300s, `END_WAKE_EXPIRY_SECONDS`) do not bound it: an end for an
> unknown or expired call is a no-op on Android and report-and-end on iOS (must-report). The only
> open item that could move these is claude-tasks#4233 (the four call clocks), and the island will
> flag it before merge.

---

<!-- landed 17:19:28 rc=0 -->
## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** v3 still keeps six clocks for one call, and the redelivered VoIP push, the third minute, and the lock-screen decline are the three frequencies that shake it to glass (Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration.").

**Fatal flaws:**
- **Six lifetimes, one call (v3.1, v3.2, v3.3, v3.4, v3.5).** The answer cell dies at 120s. The tombstone dies at `RING_CEILING_MS × 2`, counted from the end. `armed` dies with the process. The map row dies on `forgetLiveCall` and outlives the process. The engine claim dies at `retire`. Dart's `CallState` is whatever the slots say at listen. A live call is the beat those clocks do not share. Design 12 already measured this disease on the wire: island expiration 60s, app freshness 10s, six times apart, reconciliation named as unfinished work. v3.2's safety proof declares "the island's FCM invite TTL is the ring ceiling, so a later redelivery cannot arrive." That equality is the grounding document's open bug, borrowed as a premise. FCM TTL is not APNs VoIP expiration, and neither starts when the ring ends.
- **The tombstone ends the call it was built to protect (v3.2, v2.2 §2 step 2, design 12 Decision 1, Decision 4).** UUID is a pure function of the ULID. Answer writes a tombstone. A duplicate invite is then "report-and-ended." On iOS that phrase means a CallKit transaction against the UUID CallKit already holds for the connected call. `reportEnd` on that UUID removes it from `armed`; v3.5 then disarms because the set goes empty. The mic dies at 3am because the birth announcement was redelivered. v2.0 deleted the random UUID, so there is no sacrificial id left to satisfy must-report. v3.7 gates that same instant-end pattern for v1 dev wakes, then v3.2 makes it the production path for every legitimate redelivery. The FCM sentence does not bind APNs. An end that shares the tombstone's "already done" predicate is dropped, and the remote hangs up into silence.
- **Native refusal goes dark while the call is still up (v3.1, v2.6).** The ruling "a second answer is refused" is implemented as "the answer cell holds A." That cell expires at 120s, and a real call is longer than its grace. After that, native passes B: the lock-screen answer is fulfilled, and Dart is hoped to refuse later. CallKit has already accepted the second answer. The cell is also never written for outgoing — v2.6's outgoing call does not arm and does not pass through `answer()`. For every call the user places, and for every answered call older than two minutes, the native door is empty and the pocket answers B. "A's `call_end` always finds it" is the same sentence as "once it expires," and they cannot both be true. Withdrawing `consumed(ref)` because the outcomes match is only true inside the window, on an incoming call, with Dart awake.
- **Ended and empty are the same note, so history re-rings a buried call (v3.3, v3.6 door 3).** `CallState` is `ringing`, `answered`, or empty. A decline before Flutter exists clears the slot and writes a tombstone the snapshot does not read. Android explicitly keeps no pre-listen `ended`. iOS `pending` exists because the snapshot has already forgotten. The primary wake path, design 12 Decision 6, is native-before-Dart. The local decline is never signed out, the caller keeps ringing, and `admitRing` — door 3 checks the envelope, not the tombstone — raises the banner for the ref the lock screen already buried. v3.3 says the tombstone stops that banner and names no read.
- **Door 4 and the engine claim are wired to the wrong clock (v3.6 door 4, v3.4).** Door 4 drops a sealed event whose channel is not the held state's channel. v3.3 says an event for a ref you do not hold still reaches that ref's banner and route. Call-waiting was measured 2026-09-20 across two groups: decline waiting B while A is held, B's `ended` is eaten, B's banner stays. The channel was already bound at doors 1–3. Engine claims are taken only in `ring()` and released in `retire()`. The outgoing session never rings. Screen off, activity detached, a queued retire sees no claims and releases the engine under a live outgoing call. "No activity attached" is not a call lifetime.

**What holds:**
- v2-only calling, on the measured premise, with Nick's confirmation. v1 renders in history and is refused at the ring. The `V1(channel)` arm stays dead.
- `CallRef` is the ULID alone. The channel sits beside it. `oneChannelPerCall` is the seam #3196 / Decision 1b will change. `==` is not a policy engine.
- One `fromWire` / `toWire` per language. Malformed `m` drops or must-report-ends. Wire bytes untouched. The island still owns no call object.
- Refusals before side effects: parse, duplicate, door, then displace. The order holds. The duplicate's action on a live UUID does not.
- The product ruling itself: a second answer is refused, A is untouched, no break-before-make. Kelvin's blackout is closed as a ruling. The memory that is supposed to enforce it is not.
- v3.5's disarm predicate is the rule: disarm only when removing a UUID that was in `armed` leaves the set empty. An unarmed end is a no-op on the lease. Delete-on-end for the map, no time prune, rows survive death while the call is live.
- v3.7: stop-waking-v1 is a shipping gate for 0.0.6, island-owned. Dev report-and-end is named debt.
- v3.8: semantic tests, line count as a smell. Dropping iOS `instance` is right for synchronous main. Sealing the verb under the lock still holds. v2.5: no joined room without a `CallRef`.
- v3.4's incoming race is closed for two refs that both claimed: a retire of A does not drop B's claim. The hole is the call that never claims.

**If RECAST, what to fold back:**
- **One session, one lifetime.** Mint it at incoming ring and at outgoing mint, before the ack and before media. Key `(CallRef, channel, phase)`. It owns the answer memory, the engine claim, the CallKit/ConnectionService UUID, and the armed bit. It dies only on end. Delete the 120s cell as product memory and delete `RING_CEILING × 2` as the tombstone's clock. `ANSWERED_TRUST_MS` survives only as crash grace for a hold no session still shows as connected.
- **v3.2:** A tombstone means "do not create a session." It never `reportEnd`s a UUID that is ringing or answered. A duplicate push for a UUID CallKit already has completes the handler and leaves that call up. A tombstoned ref with no live UUID may report-and-end a fresh report, and that buzz is the same counted entitlement cost as v3.7, not a silent drop. Ends bypass the tombstone. Tombstone deadline is first-seen plus a named upper bound on invite push TTL for both FCM and APNs, pinned next to design 12's expiration — not inferred from the ring ceiling. Rewrite closure test 1: a redelivery never ends the live UUID and never starts a second ring.
- **v3.1:** While any session is live — incoming or outgoing, of any age — `answer(B)` is refused before the system answer is fulfilled, on Android and on iOS. After the cell's 120s, a connected map row or an `armed` UUID still refuses. Outgoing inserts the session at mint so the native door can see it. Add test 8b: answer B at t>120s while A is connected leaves A up and does not fulfill B; answer B during outgoing does the same.
- **v3.3:** `CallState` can be `{phase: ended, ref, channel}` for as long as the tombstone lives, read from the same store on Android and iOS. `admitRing` refuses it. A decline before listen is replayed so Dart still announces the signed end. Add the test: decline before first listen, history does not banner.
- **v3.6 / v3.4:** Remove door 4's comparison against the held channel. Doors 1–3 bind the channel; later events trust it and still apply to that ref's banner and route while another ref is held. Test: decline waiting B during A, B's banner stops, A stays. Engine claim is taken at session mint, including outgoing, and released at that session's retire.

---

## Round 3 synthesis: cap reached, design is **NOT tempered SOUND**

Three rounds, and none came back clean from at least two families: R1 RECAST 4/4, R2 RECAST 4/4,
R3 RECAST 3/4. Per the skill's guardrail, this stops here and is reported. **Status: RECAST
outstanding. Not cleared to build as v3.**

**The round-3 findings, classified** (against the code and the record, 2026-10-06 17:20):

| Finding | Families | Ruling |
|---|---|---|
| Native refusal goes dark after the 120s answer cell, and the native door never sees an OUTGOING call, so a lock-screen answer to B is fulfilled under a live A. On iOS CallKit then takes the audio session under a non-CallKit outgoing call | Tesla, Carnot (and Maxwell r2's withdrawn `consumed(ref)`) | **Real.** Native lacks the fact "a call is live" |
| A decline before Dart exists leaves no ended state that Dart reads; the invite then arrives over the websocket inside `kCallInviteFreshness` (10s), and the banner rings a call the lock screen buried | Tesla | **Real** |
| Tombstone has no exhaust | Kelvin | **Real** (doc gap; prune-on-write) |
| Tombstone TTL proof was FCM-only | Carnot, Tesla | **Closed after launch:** pinned to the island's shared constants (see above) |
| A wrong-channel END must be refused before any destructive effect | Carnot | **Real** (doc: split door 3 into invite vs end) |
| Door 4 contradicts v3.3 (an event for an unheld ref) | Tesla | **Real** (doc inconsistency) |
| The engine claim is never taken by an outgoing call | Tesla | **Real** (doc gap) |
| v3.7 gate absent from v3.8's acceptance list | Carnot | **Real** (doc) |
| "The tombstone report-and-ends the LIVE UUID and disarms" | Tesla | **Rejected: misread.** iOS report-and-end mints a throwaway `UUID()` (`AppDelegate.swift:823`), and never touches the live UUID or `armed`. Caused by v2.0's wording ("the random UUID is deleted" meant v1's ring UUID). The wording must be fixed |

**The convergence:** every real round-3 finding is the same missing object, **one call session
with one lifetime**: minted at incoming ring AND at outgoing mint; owning the answer memory, the
engine claim, the CallKit/ConnectionService UUID, the armed bit and the ended/tombstone phase;
dying only on end; and readable by native, so every door refuses with the same fact. **That object
is design 21 v2 item 2 ("a call session per callId owns everything a ring creates"), which has
never been built.** Each round of both designs has re-derived it piece by piece: slots, then
cells, then claims, then tombstones.

**Disposition: Nick's call** — see the session report. The options are a v4 that builds the
session as the spine (folding every row above), with the delta cage-match as the next gate; or
another design pass (`/crucible`) on the session object itself.
