# Design 24 — the answer fetches its own invite

| | |
|---|---|
| **Status** | **PROPOSAL.** Un-tempered. Nothing built. |
| **Owner** | Claude (app tab), 2026-10-19 |
| **Answers** | #392 at the level the cage-match could not reach: *why does a dead socket mean a failed answer?* |
| **Provoked by** | PR #395 hitting the three-round cage-match cap with a growing diff, and Nick asking *"hang on, is this island work?"* — which surfaced that the build had skipped the cross-tab read this repo's CLAUDE.md requires. |
| **Wire change** | **None.** The island already serves everything this needs. |

---

## 0. The defect, measured

On a Pixel (release build, island-sent ring, 2026-10-19), a warm app whose phone slept lost
its island socket for good. The ring still arrived, because FCM rides Play Services' own socket.
The user answered, unlocked within 3 s, and the answer was held for 30 s and resolved
`neverAdmitted`. Full trail in `project_392_root_cause_refresh_once` and on PR #395.

PR #395 fixes **why the socket stayed dead**: a refresh tried once and never retried, an expired
token, and 403s until restart. Hardware verified: round 1's build joined 1.35 s after Answer. Three
cage-match rounds then found a new interleaving in the transport every round (an orphaned timer,
an unowned refresh, a retry policy that cannot tell a fresh token from a stale one), and the diff
grew each time: 128 → 144 → 152 KB. Round 9.8's stop signals both fired.

**Every round asked how to make the socket recover better. None asked why the answer needs the
socket at all.**

## 1. Why the answer needs the socket — read from the code, not inferred

A held answer resolves only when `RingController` admits the invite. It receives invites from
`ChatRepository.inboundMessages`, which `_announceInbound` feeds from **one persist door**
(`_persistInbound`) with **two feeds** (`chat_repository.dart:176-186`):

1. **Live fanout:** the socket delivers the message.
2. **History sync:** `_fetchDeltaHistory` over REST.

The second feed has **exactly one caller**, `_runReconnect` (`:753`). It runs on
`ConnectionState.connected` and starts with `_transport.subscribe(...)`, whose `suback` supplies
the fences the delta loop fetches up to. So **both feeds are gated on a socket connect.** The
REST path exists, but it sits behind the socket.

(An earlier version of this reasoning said *"the wake carries no invite, so it must come over the
socket."* That was an inference from the payload, and it missed the history feed. The conclusion
held, but the reason did not. Recorded so the wrong reason is not re-used.)

## 2. What the record already says

**Island design 19, TEMPER and RECAST** (the call as a wire object; nothing decided, nothing built):

- Temper flaw 2, disposition: ***keep v2 in-band*** (`aiko:call/2 <ulid> …` on the existing
  dual-island history bus, with the same object on the wake). The invite **stays a channel
  message**, so channel history is a legitimate place to read it from. Pulling it off that bus
  severs federation.
- The trilemma handed to this tab (claude-tasks#4374): ***statelessness, locked-phone join, a
  sealed envelope — pick two.***
- §6.4 and Part 2: *two delivery paths (socket, wake) must agree on one object*. This is the
  silent-desync class.

**App design 20** (the sealed ring envelope; arm C accepted in principle by the island tab
2026-09-11 with three conditions, un-tempered): the payload carries a **sealed** signed invite,
as Signal does. That is the other way to take the socket off the answer's path, and it is larger:
crypto, an NSE path, and the island's three conditions.

**App design 23** (the session survives the lock): iOS session tokens are
`kSecAttrAccessibleWhenUnlocked`, so on a locked iPhone **no** Dart request authenticates until
Face ID. Freshness is measured from the native wake age, not from when Dart gets there. On iOS
the invite *already* "arrived by fetch after Face ID" (run 1). This design does not change that
constraint. It changes **what the fetch waits on**.

## 3. Decision (proposed)

> **When a ring is answered, the app fetches that call's invite itself, over REST, from the
> channel the wake named. It does not wait for the socket or its fences.**

- **Trigger:** the native `answered` action (`SystemCallNavigator._onAction`, which today kicks
  the transport). Optionally also the native wake, where the engine is warm (Android).
- **Read:** `GET /v1/channels/{c}/messages` with no `after` cursor, giving the newest page. `c`
  comes from the wake, and is already bound to the call at the native door (design 22 v4.2). The
  REST client renews an expired token on a 401 through `AuthInterceptor`, which is the step the
  socket kept getting wrong.
- **Write:** every message goes through **`_persistInbound`, the same door**. That keeps origin
  verification, server-ULID dedup (`inserted`) and Door-A retraction suppression, and it announces
  to `RingController` exactly as live fanout does. `admitRing` then runs unchanged, with
  `wakeAge`, consent, blocks and the end check.
- **The gap-fill bookmark is untouched.** `historyContiguousThrough` moves **only** through the
  delta loop's explicit `advanceHistoryContiguous(channelId, fence)` (`:913`). `_persistInbound`
  never writes it, so a targeted tail read cannot paper over a gap. Verified by reading.

### Why this sits well with the record rather than against it

- **The trilemma:** the island stays stateless (it already serves history), the envelope stays
  sealed (`{c, k, m}`, no participant set to Apple or Google), and a locked phone still joins: on
  Android after Answer, on iOS after Face ID exactly as today. It holds all three because the
  invite is read **after** the user's own authentication, not carried by the push.
- **Two-path agreement:** there is no second object. The REST response *is* the channel message
  the socket would have delivered, written through the one door that already reconciles the two
  feeds (cage-match #139's reason for putting `_announceInbound` there).
- **Federation:** nothing leaves the history bus.
- **Design 20:** complementary, not competing. Design 20 removes even the network read; this
  removes the socket dependency with no wire change and can ship first.

### What it does to PR #395

The socket still matters for chat: live messages, presence, sends. So #395's core fixes stay: a
failed refresh is retried, and kicks connect on answer, resume and online. But the transport is
no longer **on a call's critical path**, so:

- the round-3 regression (a kick at the backoff cap waits 30 s with a fresh token) still has to
  be fixed before merge, but it is chat latency, not a failed call;
- the transport state-machine recast becomes chat-quality work, not an emergency.

## 4. Hazards, stated rather than discovered

1. **Double arrival.** Socket and REST may both deliver the invite. The cache's
   `inserted`-once contract means only the first is announced. *Needs a test, not a belief.*
2. **The newest page may not contain the invite**, if 50+ messages follow it in the channel
   within the ring window. That is implausible in a DM within 30 s, but it is a bound, so state
   it. The miss is safe: the answer resolves `neverAdmitted`, exactly as today.
3. **Network genuinely dead.** REST fails too, and nothing can join. That is honest, and the
   ring telemetry should say `fetchFailed`, not `neverAdmitted`, so the two are distinguishable.
4. **Signed-out or locked iOS.** The fetch needs a session. On a locked iPhone it waits for Face
   ID, which is design 23's constraint, unchanged.
5. **A trust-boundary path.** It feeds `admitRing`, so cage-match by law, as design 23 was.
6. **A second trigger for history persistence outside `_runReconnect`'s epoch.** A
   reconnect choreography running at the same time also persists through the same door. The door
   is transactional (dedup inside the cache transaction), but its interleaving with
   `_runReconnect`'s abort epoch needs reading, not assuming.

## 5. Questions for the temper

1. Is "fetch on answer" **enough**, or should the wake also trigger it (Android, warm engine), so
   that admission can happen before the user even answers, as on a foreground app today?
2. Does a non-advancing tail read through `_persistInbound` have any interaction with the
   reconnect choreography's epoch that the dedup transaction does not cover?
3. Is hazard 2's 50-message bound acceptable, or should the read be `after:` a cursor derived
   from the wake (the call ULID `m` is time-ordered)?
4. Does this make design 20's urgency drop, and if so, does design 20 still need to exist for the
   *hostile island* threat it names in §0, which this design does not touch?

## 6. Provenance

The build of #395 went from the handoff straight to transport code. This repo's CLAUDE.md
requires reading the island tab's record first, and that read is what changed the question.
Three different-family review rounds hardened the socket-recovery framing without challenging it,
because the dependency they could not see lived in another file. That is the #2634 lesson again,
recorded here because it recurred.
