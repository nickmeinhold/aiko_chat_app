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
