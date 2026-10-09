# Design 21 — A ring is not a channel: identity for the Android ring

**Status:** DRAFT for `/design-temper`. Not a decision.
**Origin:** PR #210 (`feat/android-ring`, claude-tasks#4421) reached the cage-match round cap (3)
with real findings in every round. Under the 2026-08-23 ruling, a diff still producing findings at
round 3 goes to a design pass, not to a fourth review round. This note says what the rounds found
and proposes the shape underneath them.

## What is built (and hardware-verified)

The Android receive half of the call ring. An FCM data push `{c, k}` reaches `AikoMessagingService`.
`CallRing.handle` applies a total function on `k`. `call_invite` puts up an insistent full-screen
notification, shows a native `IncomingCallActivity` over the keyguard, and warms the shared Flutter
engine so `admitRing` admits the signed invitation while the phone rings. Answer requires an unlock,
then emits `answered` over `call/actions` to the existing `SystemCallNavigator`, which joins only an
admitted invitation. Verified on a Pixel 4 / Android 13: cold + dozing + locked → ring, `call_end`
→ stop, Answer 40s after signing → call screen with camera, Decline → warmed engine torn down.

## What three rounds found

19 real findings were fixed across rounds 1-3. Their distribution is the evidence for this note:

| class | instances (round) |
|---|---|
| **Event applied to the wrong ring** — an action, listener or callback names only a channel, and lands on a different ring of that channel, or on the next engine | stale `ended` in the held buffer (r1 ×3 seats); ring screen bound to a displaced caller (r1, r2); backstop no-op at the expiry boundary (r2); `ended` after Answer lost (r2 ×2 seats); duplicate invite after Answer re-rings a taken call (r3); expired ring's posted `ended` fires against the new ring (r3); keyguard callback answers the old ring and finishes the new caller's screen (r3); held buffer drained into a later engine (r3 ×2 seats) |
| **One record, several concerns** — the SharedPreferences record is the ring phase AND the answer latch | Answered state added (r2), then overwritten by any invite (r3) |
| Lifetime / threading, each fixed once and not recurring | exported answer surface (r1), work outside FCM's wake lock (r1), one engine with two lifetimes (r1), two clocks (r1), reboot clock (r2), deferred-registration race (r1) |

The third row converged: each was fixed and nothing came back. The first two rows did not. Each fix
removed one instance and the next round found another, which is the signature of a missing concept,
not of careless code.

## The missing concept

**A ring has an identity, and the code uses the channel as that identity. A channel is not an
identity.** One channel can ring, end, be answered, ring again, and be displaced, all within a
minute. Every message that says only "channel X" is ambiguous about which of those rings it means:

- the stop listeners (`onRingStopped(channel)`),
- the `call/actions` events (`{action, channel}`),
- the held buffer that carries those events to a Dart that isn't listening yet,
- the keyguard callback (`openAnswered(c)`),
- the persisted record (one slot, keyed by channel),
- the timer (patched in r2 to `(channel, at)`, which was the first local instance of the fix this
  note proposes).

## Proposed recast

1. **A ring id, minted locally per ring.** `CallRing.ring` mints an opaque id (a counter, or
   `elapsedRealtime` + boot count) the moment a ring begins. Everything a ring creates carries it:
   the notification's intents, the ring screen's binding, the timer, the stop-listener callback, the
   keyguard callback, and the `call/actions` event. Every transition is keyed on `(channel, ringId)`.
   An event whose ring id isn't the current one is a no-op by construction. That removes the
   wrong-ring class instead of guarding each of its sites.
2. **The answer is its own slot, not a phase of the ring record.** `Ringing` and `Answered` are
   different facts with different lifetimes (60s vs 120s) and different enders (`call_end` while
   ringing vs `call_end` / Dart teardown after answer). Two slots: a new invite never touches the
   answer slot, and a duplicate invite for an answered `(channel)` is recognised as the same call
   *if* the island's invite carried an identity (see Q1). Until then, see Q2.
3. **The event buffer belongs to an engine, not to the process.** `held` lives on the engine
   `AikoEngine.obtain` creates and dies with it. An event emitted with no engine is buffered for the
   engine about to be created *by this ring*, keyed by ring id, and dropped if that ring retires
   first.
4. **`call/actions` carries the ring id to Dart.** `SystemCallNavigator` holds answers keyed by
   `(channel, ringId)`, and an `ended` for a different ring id doesn't consume them.

## Open questions — the temper should attack these

- **Q1. Should the ring id come from the WIRE?** The island's invite has a server message id. A
  wire-level identity, e.g. `{c, k, m}` with `m` = the invite's server id, which `call_end` already
  names via `reply_to`, would let the receiver tell *the same call delivered twice* from *a new call
  on the same channel*. A local id can't make that distinction. Tesla's r1 concern (a redial inside
  60s after a lost `call_end` is swallowed as a duplicate) and r3 finding 1 are both that missing
  wire field. Cost: an island change (#4421 contract), and FCM `data` stays `map<string,string>`.
  **Is a local id worth building if the wire id is the real answer?**
- **Q2. Without a wire identity, what is a duplicate?** Today: same channel, still Ringing. With
  an Answered slot: is `invite(c)` while Answered(c) a duplicate (drop), or a new call (ring
  again)? Both are wrong in one case. This may be undecidable on the current wire, which would make
  Q1 a prerequisite, not an option.
- **Q3. Is the iOS side carrying the same flaw?** `CallKitRinger` keys its UUID map by channel and
  has `answeredCallTrustWindow` (8h) because of a duplicate-push incident. If the right answer here
  is a wire identity, iOS should probably converge on it too.
- **Q4. Is this the wrong frame?** The rounds also kept finding *lifetime* defects
  (engine × activity × ring). Maybe the deeper missing concept is "who owns the engine", and identity
  is a symptom. The author has been inside this diff for a night.

## What is NOT in question

The native lock-screen ring screen, warming the engine at push time, the compile-time calling gate,
the single answer door (non-exported activity), and doing the work inside FCM's wake lock were each
challenged in review and held. The hardware results stand.

---

## v2 — after the temper (dt-ring21: RECAST from Maxwell, Kelvin and Carnot; Tesla dark)

Full strike: `21-a-ring-is-not-a-channel-TEMPER.md`. The v1 recast above is kept as written. v2
replaces it.

**The temper's central correction:** v1 proposed one locally minted "ring id" and treated the wire
id as an open question. All three seated families said that id was doing **two jobs**, and that one
of them can't be done on the device:

- **What the call IS** (dedup: is this invite the same call delivered twice?). Only the sender knows.
  → **`callId`, from the wire.**
- **Which incarnation a screen, timer or callback belongs to** (routing). A device-local fact.
  → **`ringInstanceId`, minted locally.**

### v2 shape

1. **PREREQUISITE: the invite carries its identity.** FCM `data = {c, k, m}`, where `m` is the
   invite's server message id. `call_end` already names the same id via `reply_to`, so the end
   carries `m` too. An invite without `m` doesn't ring (Kelvin). This is a change to the
   #4421 contract, and it's cheapest **now**: island PR #192 is unmerged and no Android build
   consumes FCM call wakes. The same field goes on the APNs VoIP payload.
2. **A call session per `callId`.** The session owns everything a ring creates: the notification
   intents (carrying `callId` + `ringInstanceId`), the ring-screen binding, the keyguard callback,
   the timer, the stop listeners and the engine lease. Retiring the session invalidates all of
   them. An event whose `(callId, ringInstanceId)` isn't the live session is a no-op by
   construction.
3. **Duplicate is decided by identity, not by phase.** `invite(callId)` when that `callId` is
   already Ringing or Answered → duplicate, dropped. A different `callId` on the same channel → a
   new call. `end(callId)` ends only that call. Answered is keyed by `callId` and lives
   `ANSWERED_TRUST_MS`.
4. **State, not events, crosses to Dart.** `call/actions` carries a *change signal*. On listen and
   on each signal, Dart reads the current state `{phase, channel, callId}` from native. The held
   buffer is **deleted**: a newly attached engine reads what is true now, not a backlog from a
   previous engine. `SystemCallNavigator` keys its hold by `callId`.
5. **iOS converges in the same arc.** `CallKitRinger` keys its UUID map by channel and carries an
   8-hour `answeredCallTrustWindow` because of a duplicate-push incident, which is this same flaw.
   With `m` on the VoIP payload it keys by `callId`, and the shared Dart bridge reads state on both
   platforms. A mixed design (Android on `callId`, iOS on channel) is explicitly NOT a stable end
   state.

### Sequencing

1. Agree `m` with the island tab, and get it into PR #192 before merge (FCM) plus the APNs VoIP
   payload builder.
2. Android: the session + state-read bridge on `feat/android-ring` (PR #210 stays open).
3. Dart: `SystemCallNavigator` keyed by `callId`; the bridge reads state.
4. iOS: `CallKitRinger` keyed by `callId`.
5. Re-strike v2 (temper round 2 of ≤3), then a fresh cage-match on the result.

### What v2 does NOT change

Everything in "What is NOT in question" above. Also the hardware results for invite, end, answer,
decline and cold start: those paths keep their shape, and only what they're keyed by changes.

---

## v2 correction — the call id was ALREADY DECIDED (island design 12, Decision 1)

**v2 item 1 above is superseded.** It proposed `m` = the invite's *server* message id. The island
tab pointed out (2026-10-06) that its merged design record already decided which identity, and it
isn't that one:

> island `docs/design/12-native-call-ui-callkit-connectionservice.md`, **Decision 1** (PR#149/#150):
> "the call id is CLIENT-minted; the island carries it, and owns no call object …
> `aiko:call/2 <ulid>` — the id is IN the signed invite body … The end sentinel references the
> same id."

It was decided and never built (`call/2` appears in neither repo's code). **Design 21 and its
temper never read it.** That's the #2634 failure this repo's CLAUDE.md exists to prevent. The
temper then hardened the gap: three families correctly converged on "identity must be on the wire",
but none of them had the record that says WHICH identity. A design-blind adversary confirms the
author's frame.

**Why the client-minted id is the right one**, beyond being the record (island tab's points,
verified):

1. **Signed, not asserted.** A ULID in the signed body is verifiable end to end. A server id is
   assigned after signing, so the device has to trust the island's `m`.
2. **The misdial path.** `CallEndAnnouncer` waits for the ack because `reply_to` needs the server
   ULID. With the id in the end's own signed body, the end can go out immediately.
3. **No sender-chosen pointer.** The island checks only that an end's `reply_to` exists in the
   channel, not that it's a call invite. A server-id `m` taken from `reply_to` would let a sender
   point an end at any row. With call/2, the island copies the id out of the signed body.
4. **Federation.** Server ids are island-local, and a client ULID crosses islands.

**v2 item 1, as corrected:** invite body `aiko:call/2 <ulid>`, end body its signed twin carrying
the same ulid (exact bytes to be pinned jointly). The wake payload is `{c, k, m}` with `m` = that
ulid, **copied by the island from the signed body**, on both FCM and APNs VoIP. The v1 sentinels
stay recognised forever because they're in signed history. A v1 wake still rings keyed by channel,
and the dedup weakness stays confined to v1 traffic. Items 2-5 stand, with `callId` = the ulid.

**App-side cost now includes a signed-body change:** minting the ulid; `isCallInviteBody`,
`admitRing`, `admitCallEnd` and `CallEndAnnouncer` learning v2; the end no longer waiting for the
ack. That touches the signing trust boundary, so it gets a `/cage-match` of its own.

### Dependency note — #4278 (the iOS end-wake interlock)

Today the island does not send `call_end` to VoIP rows (#4278 closed; alert rows skip ends as
`end_wake_needs_voip`), so a TYPED v2 end with an invented id reaches no iOS ring at all. **When
#4278 opens**, a forged end with an unknown `m` reaches iOS as a VoIP push, and it must still be
reported to CallKit (must-report). `reportEnd` handles it with report-then-end-immediately. If that
draws anything on screen, a DM peer gets a "flash per forged end" primitive. That's no worse than
v1 ends today, but it's the case to test on hardware when #4278 is answered. (Island tab,
2026-10-06.)
