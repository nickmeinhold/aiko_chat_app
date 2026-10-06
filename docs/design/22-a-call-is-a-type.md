# Design 22 — A call is a type, not a nullable string

**Status:** DRAFT, for `/design-temper`. Written 2026-10-06 because PR #210's v2 cage-match
reached its three-round cap without converging (ledger: PR #210 comments 6010330924, round 2,
and 6010544755, round 3).

**Builds on:** design 21 v2 (this repo), island design 12 Decision 1 + its 2026-10-06 addendum
(the call/2 bytes). **Changes no wire bytes.** The island carries `m`, owns no call object, and
none of this reaches it.

## Why this exists

PR #210 has had six review rounds across two designs. Every one found the same defect with a new
face:

| Round | What an event was keyed by | What went wrong |
|---|---|---|
| v1 r1-r3 | the channel | an event for one call landed on another call's ring |
| v2 r1 | channel + `callId: String?` | a missing id matched every call in the room (the wildcard) |
| v2 r2 | "null means v1, exactly" | a deep link's null was read as "the v1 call" and ended one |
| v2 r3 | the same, plus a `namesACall` flag | the flag was honoured at one site and not the next; `stopRinging` was keyed by nothing; Android ignored the channel for v2 while iOS and Dart required it |

Round 3 also found two defects that round 2's own fixes had made. That is the cap rule's
"not converging" signal, so the class goes to design rather than to round 4.

**The class:** a call's identity travels as the pair `(String channelId, String? callId)`, and
`null` carries three meanings — *a v1 call*, *names no call* (a deep link), and *nobody passed
one*. Each of roughly a dozen sites re-derives which meaning applies and how to compare. They
disagree, and every fix adds another site.

## What the record already says — and where the build drifted from it

Read before writing this, per the #2634 rule:

- **Island design 12 Decision 1 + addendum:** the call id is client-minted and lives in the
  signed body. `m` is present exactly for v2 and absent (never null, never empty) for v1. **v1 is
  read forever.** So "v1" is a permanent, legitimate identity, not a legacy null. This design
  gives it a name.
- **Design 21 v2, item 3:** "*Answered is keyed by `callId`*". **The build has ONE answer slot.**
  Tesla raised this in rounds 2 and 3, and I ruled it not-a-defect both times without re-reading
  item 3. It is a drift from the design of record. This design closes it (§3).
- **Design 21 v2, item 4:** "*Dart reads the current state on a change signal*". The build does
  that only on listen (Android's answer-slot snapshot); after that it pushes events, and iOS keeps
  a `pending` buffer as a named exception. Class II below is the part of that drift that
  produces defects. Moving all of it to state-reading is **not** proposed here (see "Not in this
  design").
- **Island #4278:** the island does not send `call_end` to iOS VoIP tokens today
  (`end_wake_needs_voip`). So iOS `reportEnd` is reached only by tooling until #4278 opens.
  §4's iOS half is correctness ahead of traffic, not a live bug.

## §1 — `CallRef`: one sealed identity, one equality, three languages

```
CallRef = V1(channel)            -- a call/1 call: the channel is all v1 can say
        | V2(channel, id)        -- a call/2 call: the id, AND the channel it was rung on
```

- **"Names no call" is not a `CallRef`.** It is `CallRef?` = null, and that is null's ONLY
  meaning anywhere in the call feature. A deep-linked `/call` screen has `call == null`, so it
  matches no event, ends no system call, and is silenced by nothing. (`namesACall` is deleted.)
- **One equality: structural.** `V1(c) == V1(c)`, and `V2(c, m) == V2(c, m)`. A V1 never equals a
  V2. **V2 equality requires the channel too**, which fixes Carnot's round-3 finding. It matches
  what Dart `endsInvite` and iOS `reportEnd` already did. Android `sameCall` was the outlier.
- **One wire parser per language**, the ONLY place absence is interpreted:
  `fromWire(c, m)`: `m` absent → `V1(c)`; `m` matches the call-id grammar → `V2(c, m)`; `m`
  present and malformed → **no CallRef**: the event is dropped (Android, Dart) or
  reported-and-ended (iOS, must-report). That is today's rule, moved into one function.
  `toWire` is its inverse: `{c}` or `{c, m}`.
- **Languages:** Dart `sealed class CallRef` with `final class V1Call` and `final class V2Call`
  (value equality); Kotlin `sealed interface CallRef` of two `data class`es; Swift
  `enum CallRef: Hashable { case v1(channel:), v2(channel:, id:) }`.
- **The contract test grows by one row:** the three `fromWire` outcomes over the shared golden
  vectors, asserted for all three languages (the grammar row exists already).

### Sites that convert (each becomes `==` on `CallRef`, or a `CallRef?` null check)

| Where | Today | After |
|---|---|---|
| `CallInvite` / `CallEnd` (Dart) | `channelId` + `callId?` | `CallRef get call`; `endsInvite` = author check AND `end.call == invite.call` |
| `SystemCallAction` + bridge decode/encode | `channelId` + `callId?` | `CallRef call` (decode = `fromWire`) |
| Navigator hold | `_answered` + `_answeredCallId` | `CallRef? _held` |
| Navigator admission | key `"$channel/$callId"` | `Map<CallRef, Timer>` |
| Navigator `_leaveIfOpen` | `callIdOf(extra) != callId` | `routeCall == action.call` (null never equal) |
| Navigator → in-app ring stop | `stopRinging(cause)` (whatever is live) | `stopRingingFor(CallRef, cause)`: no-op unless the live invite's `call` equals it |
| `CallRouteExtra` / `CallScreen` | `outgoing.callId ?? callId`, `namesACall` | `CallRef? call` (+ `outgoing` for the announcer) |
| `CallEndAnnouncer` | `channelId`, `inviteId`, `callId?` | `CallRef call` + `inviteId?` (only the v1 reply_to needs the ack) |
| Android `Ring` / `Answered` / `sameCall` / `endFromDart` | `channel` + `callId?`, `sameCall` ignores channel for v2 | `CallRef`; `sameCall` deleted, `==` |
| iOS map row / `reportEnd` / `endSystemCall` / `emit` | `call: String?` beside a channel key | `CallRef` (the map key stays channel; the row stores the ref) |

**The test that makes the class closed rather than named:** after the conversion, `grep` for a
`String? callId` parameter in `lib/features/call`, and for `callId: String?` in the two native
files, returns nothing outside the three `fromWire`/`toWire` functions. That grep is added as a
test (the repo already pins source text this way in `system_call_channel_contract_test.dart`).

## §2 — Refusals before side effects

Tesla, round 3: iOS `reportInvite` ended the live call by displacement and **then** asked whether
the new id was even allowed (round 2's cross-channel guard). The rule: **every refusal a handler
can make runs before its first side effect.** For `reportInvite` that order is:

1. parse (`fromWire`): malformed → report-and-end;
2. the same `CallRef` already live → duplicate → report-and-end;
3. this id live on ANOTHER channel → bad payload → report-and-end;
4. only now: displace a different call on this channel, remember, report.

Android `ring()` has the same order already (parse, duplicate checks, then displace). It is
stated here so the two stay alike.

## §3 — Answered is keyed by call (design 21 item 3, as written)

Android's ANSWER slot becomes a **set of `Answered(call: CallRef, at)`**, persisted (JSON in the
same prefs, committed), each entry living `ANSWERED_TRUST_MS`.

- `answer(instance)` adds its call; it never overwrites another call's entry.
- `end(call)` after an answer finds *that* call's entry, removes it and emits `ended(call)`.
  Tesla's scenario (answer A, ring B, answer B, then A's `call_end`) now tells Dart A ended.
- `invite(call)` is a duplicate if that call is in the set.
- `dartEnd(call)` removes that call's entry.
- `heldAnswer` (the snapshot a new listener is handed) returns the **newest** entry. Dart holds
  ONE answer and a second releases the first (that already ends the first's system call, which
  removes its entry), so in practice the set is size 0 or 1 by the time a listener reads it.
  The set exists so that a hangup is never lost between those two moments.

The single cell was a second, coarser identity sitting beside `CallRef`: "the" answer.

## §4 — An emit happens inside the transition it reports

Tesla, round 3 (Android): `answer` clears the ring, writes the answer, **releases the lock**,
dismisses (a binder call), and only then posts `answered`. A `call_end` in that gap takes the
lock, clears the answer and posts `ended` first, so Dart sees the hangup before the answer and
joins a room the caller left.

**Rule:** whatever a transition delivers to the main looper is **posted inside the same
critical section that writes the slot.** The looper is FIFO, so lock order becomes delivery order.
Concretely:

- `answer`: `post(answered)` moves inside the lock, before the dismiss binder call.
- `end` after an answer: `post(ended)` is already inside, by construction (it is in the same
  `synchronized` block as `clearAnswer`). Order it and answer's post on the same lock.
- `retire` already posts ONE runnable that makes the engine decision ("an engine survives, so
  tell Dart; else release it") and emits from inside it. The change is only *where that runnable
  is posted*: from inside the caller's critical section instead of after it. The decision itself
  still runs on main, where `AikoEngine` requires it. The notification dismiss (a binder call) and
  the stop listeners stay outside the lock.

So no emit is ever posted and then withdrawn. Each transition contributes one runnable, queued in
lock order.

**iOS parity:** `reportEnd` (a remote hangup of a live ring) emits `ended(call)` as Android's
`retire(ended = true)` does. Today iOS emits only on displacement, so the in-app banner stays an
answer door until the signed end arrives over the websocket. The Dart navigator's `ended` then
also calls `stopRingingFor(call, .endedInSystemUi)` (§1), so a native end silences the in-app
banner for **that call only**.

## §5 — iOS: the audio lease is owned by the calls this process armed

Today `disarmIfNoCallRemains` asks the **persisted** map "is any call left?". That map's job is
"which UUID belongs to which channel". It outlives the process, and its expired rows are never
deleted, so a dead row withholds `disarm()` indefinitely (Carnot + Tesla, round 3). Meanwhile
`CXEndCallAction` disarms **unconditionally**, citing a one-call limit. But call-waiting across
two call groups was **measured** on 2026-09-20 (`reportInvite`'s own comment). So declining the
waiting call B would tear the audio out of connected call A (Tesla, round 3).

**Shape:** an in-memory `armed: Set<UUID>`, touched only on main (§ the one-queue change in
a86bf64).

- `arm()` succeeds on answer → insert the UUID. `arm()` is called in exactly one place (the
  answer action), so this is the only insert.
- Any end of a UUID (`CXEndCallAction`, `reportEnd`, `endSystemCall`, failed-answer cleanup) →
  remove it; **disarm iff the set is now empty.**
- `providerDidReset` → clear the set and disarm (every call is gone, by definition).
- Process death clears the set, and the audio session dies with the process, so the lease and
  the thing it describes have the same lifetime. That is the property the map never had.

Separately, `mutateMap` **prunes rows past their window** on every write, so a corpse stops
accumulating. The `live()` filter stays the read rule. Pruning is hygiene, not the fix.

**Needs a device:** call-waiting on iOS. Decline the waiting call while the first is connected,
and confirm that A's audio survives with §5 and dies without it. This is the iOS hardware item
already deferred in the handoff, and it is now a test with a predicted outcome.

## Not in this design (deliberately)

- **Fully state-reading Dart (design 21 item 4 in full).** With every event carrying a `CallRef`
  and every consumer comparing refs, a replayed or reordered event can no longer act on the wrong
  call. That was item 4's purpose. The remaining reason to read state is cold-start replay, which
  Android already has (the snapshot) and iOS covers with `pending`, kept for its diagnostics. Not
  worth a third rewrite of the bridge in this PR. Recorded as a deliberate partial, not as done.
- **The single-call product rule.** Kelvin, round 3: answering a second call while in one ends
  the new one. That is by design (pinned by a test), and CallKit's call-waiting UI on iOS is a
  product question for later.
- **Wire changes.** None. `fromWire`/`toWire` are exactly today's bytes.

## Open questions — the temper should attack these

1. **§4: is "post inside the lock" enough?** Posting from the FCM worker while holding the lock
   that main also takes on `answer` puts a `Handler.post` inside the critical section. That is
   non-blocking, but is there any path where main holds the lock and waits on something the worker
   owns? And does per-call delivery order actually follow, when `retire`'s runnable decides the
   emit at run time rather than at post time? This is the point I'm least sure of.
2. **A deep-linked call screen and a system red button.** With `call == null`, a deep-linked
   screen never matches a system `ended`, so the red button for a CallKit call on the same channel
   leaves that screen joined. Tesla, round 3, read that as a defect. My read: a deep-linked screen
   joined the room without CallKit, so the CallKit call's end is not its end. Is there a real path
   where the two are the same call? There's no state restoration (`restorationScopeId` is unused),
   so the only way in is a crafted or shared link.
3. **`V2(channel, id)` equality requiring the channel.** Could a legitimate flow present the same
   id on two channels? Island design 12 says the id is minted per call, and a call is in one DM. If
   cross-island gatherings (design 13, #3196) ever span channels, this is the line that changes.
   Is pinning it now right?
4. **Is the answered SET over-built?** Is "refuse `ring` while an answer is held" (Tesla's other
   option) simpler and sufficient? It costs a dropped real call during the 120s trust window after
   any answer, which is the case the set exists to avoid.
5. **Is the class actually closed?** Name any site where a call's identity would still be
   re-derived from a channel, or from a nullable id, after §1. That is the question this design
   must answer "no" to.

## Sequencing

1. `/design-temper` on this note (≤3 strikes).
2. Build on `feat/android-ring`: §1 (Dart, then Kotlin, then Swift, with the contract-test rows),
   §2, §3, §4, §5. Each fix is RED-proved by revert, then the real test command, then confirming
   it fails for the stated reason (cage-match Round 9.9).
3. A fresh `/cage-match` of the **delta** from a86bf64, asking the round-9.9 question: do these
   changes do what they claim, and do they break each other?
4. Hardware: Android v2 on the Pixel (cold+locked, end by `m`, answer, decline, cross-process end,
   displacement, plus §3's answer-A-ring-B-answer-B-end-A). iOS call-waiting audio (§5) when an
   iPhone session is available.

---

## v2 — after the temper (dt-1791273013: RECAST 4/4; full record in `22-a-call-is-a-type-TEMPER.md`)

The draft above is kept as written. **v2 replaces it.** Nick confirmed the v2-only frame on
2026-10-06.

### v2.0 — Calling is v2-only. v1 is history, not a call

- **Measured premise:** the v1 sentinel first landed 2026-08-16 (#139), after 0.0.3 was cut
  (2026-08-10). Calling was gated off from 0.0.4 (#170) and is off in every store build since
  (0.0.5 verified 2026-10-05). **No store build has ever placed or rung a v1 call.**
- **Island design 12's "v1 is recognised forever" is honoured as RENDERING:** a v1 body is a
  signed message in history and displays as one, forever. It is never a call.

| Surface | v1 body or v1 wake (no `m`) after v2 |
|---|---|
| Chat history | renders, as today |
| In-app ring / admission | not a call: `admitRing` refuses with the named reason `v1Call` |
| Android native wake | dropped and logged (Android has no must-report) |
| iOS VoIP wake | report-and-end (must-report): a momentary buzz, from old dev builds only |
| Hangup / announcer | never sent for v1; the announcer's wait-for-ack (v1 `reply_to`) is deleted |

**Cross-tab ask (island):** stop waking devices for v1 call bodies. Still store and serve them.
That removes the iOS buzz. The contract is otherwise unchanged.

### v2.1 — Two identities, both explicit (folds 1, 3)

- **`CallRef(id)`**: which call. A value class around a grammar-checked call/2 ULID.
  **Equality is the id alone.** It is built only by the one `fromWire` per language: `m` absent →
  no call (v1, see v2.0); `m` valid → `CallRef`; `m` malformed → dropped (Android, Dart) or
  report-and-end (iOS).
- **The channel is stored beside the ref, not inside it.** It is checked at the door by ONE named
  policy, `oneChannelPerCall(ref, channel)`: "a call is one DM today; the same id on a different
  channel is a bad payload". That function is the seam #3196 / design 12 Decision 1b will change,
  and nothing else encodes the rule.
- **`instance`**: which incarnation. Minted natively when a ring (or an answer presentation)
  begins. Android already has it; iOS gains it on its row. **Every native artifact carries
  `(ref, instance)`**: timers, PendingIntents (in the data URI, per a86bf64), the ring activity,
  the keyguard callback, and every posted runnable. An artifact whose instance is not current is a
  no-op even when the ref matches. Example: FCM redelivers `m`, a queued retire of the old ring
  runs, and it ends nothing.
- **`null` means only "no call".** It never appears where a call is being acted on (v2.5).

### v2.2 — Refusals before side effects (§2, unchanged)

The order is parse, then duplicate (same ref, live), then `oneChannelPerCall`, and only then
displace and remember. This is the same on Android and iOS.

### v2.3 — One answer, owned natively (fold 4; design 21 item 3 as written)

The answer slot stays **one cell**, holding a `CallRef`, which is what design 21 item 3 asked for.
The one-answer product rule moves into the native transition: **`answer(B)` while A is answered
ends A in the same critical section.** That means A's system call is ended, A's slot is replaced,
and a sealed `ended(A)` goes to Dart. A's later `call_end` then finds nothing, correctly, because
A is already over on this device. No set, no pruning, no one-cell snapshot of a many-cell store.

### v2.4 — Sealed events, posted in transition order (fold 5)

Inside the critical section that writes the slot, the transition seals `(verb, ref, instance)` and
posts it. The main-thread runnable does the engine work *with that sealed value*. It decides late
only **whether anyone is listening** (`AikoEngine.releaseIfHeadless`), never **what happened** or
**which call**. Dart ignores an event for a `(ref, instance)` it does not hold. iOS `reportEnd`
emits the same sealed `ended`, closing the round-3 asymmetry.

**Required test:** for one ref, `end` committed after `answer` is never observed by Dart before
it.

**Named tradeoff (fold 6):** design 22 **supersedes** design 21 v2 item 4 ("Dart reads state on a
change signal") with *sealed, incarnation-tagged events plus a snapshot on listen*.
- Why: item 4's target was a stale event acting on the wrong ring or phase. The ref + instance
  check stops exactly that, and a third bridge rewrite in this PR fails the cap rule's
  shrinking-diff test.
- Owner: the app tab.
- Revisit trigger: a stale-phase defect that the instance check does not stop.

### v2.5 — No call, no room (fold 7)

`/call` joins media only for an admitted `CallRef`. The route requires its extra, and a bare deep
link (no extra) redirects home without joining. `CallScreen.call` is **non-null**, so a joined
room that is addressable by nothing cannot be constructed. `namesACall` and `callScreenFor`'s null
branch are deleted. The caller's own screen carries the ref it minted.

### v2.6 — The audio lease (fold 8)

- `armed: Set<UUID>`, in memory, touched on main. **Closed list of insert sites: one**, the
  CallKit answer after `CallAudioSession.arm()` succeeds. That is the only `arm()` call in the
  file, and outgoing calls do not use CallKit audio.
- Every end of a UUID removes it; disarm iff the set is now empty. `providerDidReset` clears it and
  disarms.
- **Map pruning is dropped.** Once disarm stops consulting the persisted map, a corpse row costs
  nothing that the existing trust windows don't already bound, and a prune could harvest a live
  row (Tesla).
- iOS device test (deferred, predicted): decline the waiting call during call-waiting; the
  connected call's audio survives.

### Closure proof (replaces "class closed by grep")

The grep (no `String? callId` outside `fromWire`/`toWire`) stays as a tripwire. Closure is proved
by these tests, each RED-proved by revert:
1. a redelivered `m` after a queued retire does not end the new incarnation;
2. a v1 invite never rings or admits (each surface in v2.0's table);
3. the same `m` on another channel is refused at the door, and the live call is untouched (§2
   order);
4. `answer(B)` over answered A ends A and tells Dart `ended(A)` before `answered(B)`;
5. `end` after `answer` for one ref is never observed first;
6. a bare `/call` deep link joins nothing;
7. iOS: ending a UUID that is not in `armed` never disarms.

### Expected delta

**Net negative.** Deleted:
- the v1 call paths (wake, admission, announcer ack wait, `sameCall`'s fallback, the iOS random
  UUID);
- `namesACall`;
- the answered-set proposal.

Added: `CallRef`, `oneChannelPerCall`, the iOS instance, and the `armed` set.

Acceptance criterion: the PR's line count after v2 is below a86bf64's. If it isn't, that is a
finding.

### Open questions for the re-strike

1. v2.3: is ending A natively on `answer(B)` right for the user? It mirrors the in-app "already in
   a call" refusal inverted: here the newer answer wins. CallKit call-waiting may present it
   differently on iOS.
2. v2.4: is "decide late only whether anyone is listening" a real seam, or does `retire` still
   need global state?
3. v2.0: is report-and-end of v1 VoIP wakes (from old dev builds) acceptable until the island stops
   sending them?

---

## v3 — after re-strike round 2 (RECAST 4/4 again, narrower; record in the TEMPER)

v2 stands except where v3 replaces it. All four families converged on v2.3, and three further
holes were real. v3 closes the open questions with rulings.

### v3.1 — One product rule, every door: a second answer is REFUSED (replaces v2.3)

v2.3's "newer answer wins" inverted a pinned behaviour (`answering a second call while one is live
ENDS it`), made the lock screen and the in-app banner disagree, swapped calls break-before-make
(Kelvin), and passed the audio lease through empty mid-swap (Tesla). **Ruling: the pinned rule
everywhere.** If an answer is held or a call is live, a second answer is refused: B's ring and
system call end, and A is untouched.
- Native: `answer(B)` when the answer cell holds a live A → refuse, retire B, and tell Dart
  nothing about B beyond its end.
- Dart: `isInLiveCall` → refuse, as today. The banner shows "You're already in a call", as today.
- Consistency across the 120s trust window: while A's cell lives, native refuses; once it
  expires, native passes B and Dart refuses (`alreadyInLiveCall`). Same outcome either side, so
  no `consumed(ref)` signal is needed (Maxwell's round-2 fold is withdrawn).
- No swap exists, so there is no break-before-make and no empty-set gap. The answer cell is one
  cell holding a `CallRef`, and A's `call_end` always finds it.

### v3.2 — A call rings at most once per device: the tombstone (replaces v2.1's incarnation machinery for Dart and iOS)

Round 1's incarnation fold existed for one scenario: FCM redelivers `m` after the ring was retired,
and a queued retire then hits the new ring. **Dissolve the scenario instead of guarding it.** When
a ring for `ref` ends for any reason (end, decline, deadline, answer, refusal), native writes a
**tombstone** for `ref`, persisted and living `RING_CEILING_MS × 2`. An invite for a tombstoned
`ref` is a duplicate and is dropped (Android) or report-and-ended (iOS, must-report). The island's
FCM invite TTL is the ring ceiling, so a later redelivery cannot arrive.

Consequences:
- **A `CallRef` names at most one ring on a device.** So **Dart keys everything by `CallRef`
  alone** — the hold, the snapshot, the events, the screen — and never needs an instance. That
  answers Tesla's "a chord it is never handed".
- **iOS has no `instance`** (Maxwell r2: it guarded nothing once every handler runs on main).
- **Android keeps `instance`** only where it is already built and where it guards a non-call
  artifact: PendingIntent identity (the data URI) and the ring activity binding. It is an
  implementation detail of the notification, not a call identity, and Dart never sees it.

### v3.3 — The snapshot, the hold and the event are one shape (replaces v2.4's unwritten snapshot)

`CallState = {phase: ringing | answered, ref: CallRef, channel}`, or empty.
- **On listen**, Dart reads `CallState` (Android from the slots; iOS from the map row of the live
  call).
- **Events carry the same shape** plus a verb (`answered`, `ended`). They are sealed under the
  slot's lock (v2.4 stands) and posted in lock order.
- **Dart holds a `CallState`.** An event for a `ref` it does not hold acts only on what is keyed
  by that ref: the in-app banner for that ref, and the route for that ref.
- **iOS `pending` is named** as the pre-listen buffer for `ended` events whose call the snapshot no
  longer shows (the cold-start diagnostic, design 21 v2's named exception). It is replayed after
  the snapshot, and each entry is keyed by ref, so it acts on nothing else.
- Android: a `ended` before listen needs no buffer. The snapshot shows the slot empty, and the
  tombstone stops the banner's ref from re-ringing. The in-app banner is websocket-driven and
  ends on the signed end.

**Design 21 item 4, final disposition:** superseded by "snapshot on listen + sealed same-shape
events, keyed by a ref that names one ring". Named tradeoff, owner app tab, revisit trigger: a
defect where an event reaches Dart that the snapshot would have answered differently.

### v3.4 — The engine lease is a set of claims (closes v2's open question 2; Tesla r2)

`AikoEngine` holds `claims: Set<CallRef>` (Android, on main). `ring(ref)` claims, and `retire(ref)`
releases that ref's claim. The engine is destroyed only when no claims remain **and** no activity
is attached. `releaseIfHeadless` no longer consults a global census at run time. A queued retire of
ref A cannot release the engine ref B claimed. With the tombstone, A ≠ B always holds for distinct
rings.

### v3.5 — The audio lease predicate, exactly (fixes v2.6; Tesla r2)

**Disarm when — and only when — removing a UUID that WAS in `armed` leaves the set empty.**
Ending a UUID that was never armed (a declined waiting call, any ring) is a no-op on the lease.
That is closure test 7, now stated as the rule itself. There's no swap (v3.1), so the set never
passes through empty between two calls.

**The map's exhaust is delete-on-end**, which is what the code already does (`forgetLiveCall` on
every end path). It is stated here because v2 dropped pruning without saying so. There is no
time-based prune. Rows survive process death while ringing or answered, which is how a relaunched
app finds a live CallKit call.

### v3.6 — `oneChannelPerCall`: the closed list of doors (Carnot r2)

The policy runs exactly at the points where an external `(c, m)` first becomes a `CallRef`:
1. the Android FCM wake (`CallRing.handle`);
2. the iOS VoIP wake (`handle(payload:)`);
3. Dart admission of a signed invite or end (`admitRing`, `admitCallEnd`), which already check the
   channel against the envelope;
4. the native → Dart action decode (the channel in the sealed event must equal the held state's
   channel, or the event is dropped).

Everything after a door compares `CallRef` and trusts the channel stored beside it. Closure test 3
runs at each of the four doors.

### v3.7 — v1 VoIP wakes: a shipping gate, not a buzz (Tesla r2, Carnot r2)

A VoIP push for something the app says is not a call still costs a CallKit transaction Apple may
count. **The island stopping v1 call wakes is a gate for the first calling-ON store build
(0.0.6)**, owned by the island tab (asked 2026-10-06). Until then, dev builds report-and-end, which
is the accepted debt, and the debt is removed when the island ships the change.

### v3.8 — Acceptance (Carnot r2)

Line count is a smell, not a gate. The gates are semantic, and each is a RED-proved test:
v2's closure tests 1-7 (test 1 now reads: *a redelivered `m` after its ring ended is dropped by the
tombstone*), plus:
- 8: a second answer is refused at both doors, and A is untouched;
- 9: a queued retire of A never releases an engine B claims;
- 10: ending an unarmed UUID never disarms (test 7 restated as the rule).
