# Design 23: an answered ring is judged by when it rang

**Status:** v3.1, 2026-10-10. Tempered over 3 rounds and converged at the cap; **build to v3 plus the seven v3.1 requirements in `-TEMPER.md` (Round 3)**: a three-valued wake answer, a sleep-inclusive monotonic clock, the join deadline under suspension, Android keeping the wake through Answer, the preflight boundary, END across the split, and named residuals. The build PR gets `/cage-match`. · **Issue:** #219 · **Blocks:** iOS half of 0.0.6 (#214)
**Supersedes v1** ("the session survives the lock"), which moved the session tokens to
`AfterFirstUnlockThisDeviceOnly`. v1 was struck RECAST 4/4 (`-TEMPER.md`, round 1). The
temper surfaced a product question, and Nick answered it on 2026-10-10: **a call answered
on a locked iPhone connects after Face ID, as Android already does.** With that answer the
keychain trade and its migration are no longer needed. v2 is the alternative v1 had filed as
"out of scope".
**Touches a trust boundary:** call admission (the freshness gate). `/design-temper` round 2,
then `/cage-match` on the PR.

## The defect, measured

On a locked iPhone with the app not running, the call rings and can be answered, but it
**never joins.** Four rings on 2026-10-09 (iOS 26.6.2, 0.0.6 ad-hoc build, enspyr):

| Run | Phone state | Push → native ring | Push → first Dart request | Joined |
|---|---|---|---|---|
| 1 | locked a while | +0.4 s | +13.7 s, after Face ID | no |
| 2 | app in foreground | n/a | invite admitted over the websocket at ~1 s | yes |
| 3 | just locked (inside iOS's post-lock grace period) | +0.5 s | **+1.1 s**, before Answer | yes |
| 4 | locked 2 h; answer, wait 5 s, then Face ID | +0.35 s | +13.7 s, ~7 s after Answer | no |

The session tokens are `kSecAttrAccessibleWhenUnlocked`, so on a locked phone Dart cannot
authenticate until Face ID. It then fetches the invite and `admitRing` computes
`age = now − signedAt` using **now, the moment Dart got there**. After a Face ID that is
about 16 s, past `kCallInviteFreshness` (10 s), so the invite is refused and the answer has
nothing to join.

**The clock is read at the wrong instant.** The native side received the push for this exact
call at +0.35–0.98 s in every run, whatever the lock state. That instant is the event the
freshness window was standing in for: *did this ring reach us promptly?* Everything after it
(Face ID, session restore, the fetch) is the user's and the app's latency, not the invite's.

## Decision (v3, folding temper round 2)

When `RingController` is about to admit a verified invite whose signed body names a
`CallRef`, it **asks the native side how long ago the wake for exactly that call arrived**,
and measures freshness from then:

```
// RingController, before calling the (still pure) admitRing:
wakeAge = await native.wakeAge(callRef)     // Duration?, null unless actionable (below)
receivedAt = wakeAge == null ? null : now - wakeAge
// admitRing(..., now: now, receivedAt: receivedAt)
age = (receivedAt ?? now) - signedAt        // clockSkew / stale unchanged
```

`admitRing` order (Carnot): signature verified → not own → parse the signed v2 `CallRef`
(reject missing or malformed **before** any lookup) → sender kind and consent → DM-only → not
blocked → not muted → **ended?** → age. The `CallRef` used for the query is the one from
the *verified body*, so a different call's wake cannot be returned by construction.

### Four properties, each removing a round-2 flaw rather than guarding it

1. **Query, don't copy (removes the race).** The wake age is read from native *at the
   moment of admission*, over the control `MethodChannel`, awaited by `RingController`. Native
   already holds the record when Dart admits, so there is no event that can arrive late and no
   map to fill. Run 1's timeline shows the race was live: Dart ran throughout the locked
   ring and got the `answered` event at Answer, while the invite arrived by fetch after Face ID.

2. **A duration on a monotonic clock, not a timestamp (removes the clock domains).** Native
   stamps the wake on its monotonic clock (iOS `ProcessInfo.systemUptime`, Android
   `SystemClock.elapsedRealtime()`, which `Ring.instance` already is) and answers the query
   with `uptimeNow − wokeUptime`. Dart computes `receivedAt = now − wakeAge` on **its own**
   clock. Native wall-clock steps drop out, and `receivedAt ≤ now` holds by construction
   (`wakeAge ≥ 0`). If the stored uptime is greater than the current one, the device rebooted
   since the wake: the answer is null.
   The stamp is a dedicated `wokeUptime`, set **once** by the wake handler when it creates
   the record. Duplicate deliveries, displacement and Dart-initiated reports never write it.

3. **Trusted only while the system says the call is actionable (removes the invented
   horizon and neutralises #220).** `wakeAge` is null unless:
   - **iOS:** `CXCallObserver().calls` contains this call's UUID (the lossless
     ULID → UUID map) with `hasEnded == false`. That is CallKit's own state, not our
     persisted record, so a leftover record from an ended call (the "displaces 54X7" case in
     #220) is not actionable however long it lingers;
   - **Android:** `CallRing` holds this call id as the live `Ring` or the pending `Answered`
     (not retired, not ended), which is the same state `answer()` and `end()` consult.
   No horizon constant remains. The lifetime of the trust is exactly the lifetime of the
   ring or answered call, as each OS defines it. (The iOS 120 s and 8 h trust windows stay
   as they are, for their own jobs; v3 does not read them.)

4. **Composed with END (Carnot).** If the ring controller's END buffer (`_ended`) or the
   native retirement record holds this `CallRef`, admission refuses before age is computed,
   so a prompt wake cannot admit a call whose end already arrived by another path.

### Why this does not open a replay

- A re-pushed old invite creates a *new* wake, so `wakeAge` is small and
  `receivedAt − signedAt` is as large as the invite is old: refused `stale`, as today.
  `signedAt` remains the only input from the caller.
- An *old* wake for the *same* call can vouch only while that call is still actionable in
  CallKit or `CallRing`, i.e. while it is genuinely ringing or answered. Replaying an invite
  for a call that is actually ringing right now admits the call that is actually ringing,
  which is what admission is for.
- The wake age is device-local. Nothing on the wire sets it.

### The locked-call budget (pinned)

The teardown that killed runs 1 and 4 is **Dart's own join deadline**:
`system_call_navigator.dart:298`, `Timer(kInAppRingDuration /* 30 s */)`, armed on `answered`,
released as `neverAdmitted` (pinned after round 2, see `-TEMPER.md`). So the contract is:

| Step | Measured | Counts against |
|---|---|---|
| wake → native ring | 0.35–0.98 s | the invite (`receivedAt − signedAt` ≤ 10 s) |
| ring → Answer | user (island ceiling 30 s) | the island's ceiling |
| Answer → Face ID | user | **the 30 s join deadline** |
| Face ID → restore + fetch | ~2–2.5 s (run 1: :55.4 → :57.4) | the 30 s join deadline |
| admit → join | ~0.3 s | the 30 s join deadline |

So a locked answer joins if the user unlocks within about 27 s of answering. That limit
comes from the join deadline, which is derived from `kInAppRingDuration` ("joinable as long as
the invitation would still be ringing"). Changing it is a separate decision. The hardware
plan below strikes it directly.

The session tokens stay `WhenUnlocked`, so before Face ID a keychain read throws
`errSecInteractionNotAllowed` (raised as a `FlutterError`). The restore path treats that as
transient (`token_provider.dart` clears only on `RefreshRejected`; `auth_controller.dart:599`
documents it). **Invariant: a locked read is never flattened to "absent"**, because
`SovereignKeyStore._loadOrCreate` treats absent as "mint a new identity".

### What it costs
- One control-channel method, `wakeAge(call) → int? (ms)`, both platforms, pinned in
  `system_call_channel_contract_test`.
- A `wokeUptime` field on the iOS persisted record (`stored()`), written once by the wake
  handler. Android already has `Ring.instance`.
- `admitRing` gains a `receivedAt` parameter (pure; still unit-testable without native).
- No wire change. No island change. No keychain change.

## What the v1 temper found, and where it went

| Round-1 finding | Under v2 |
|---|---|
| delete ignores accessibility, so every save becomes a non-atomic delete-then-add (Tesla, Carnot, Kelvin) | **Gone.** No keychain migration. |
| the bearer token's power is unaudited (all four) | **Gone as a trade.** The token's protection is unchanged. (The audit is still worth doing on its own; not this design.) |
| the locked read throws, not returns null (Maxwell, Tesla) | **Stated** above as a contract. |
| first call after update fails until an unlocked open (Carnot) | **Gone.** Nothing to migrate. |
| no rollback (Carnot) | Reverting is: drop the field, use `now`. No persisted state. |
| state machine, timing budget, CallKit lease (Carnot, Maxwell) | **Folded** (table above). |
| the wrong frame: the clock at the wrong instant (Maxwell); a call-scoped admission credential (Carnot) | **This is v2.** |

## Android

Same rule, same field. Android's cold path measured 4.2 s and joins today, but it is exposed
to the same class through FCM tail latency (one observation of 14 s, claude-tasks#4233). With
v2, a slow wake still counts against the invite (receipt − signedAt), but the cold start and
the `requestDismissKeyguard` unlock after it no longer do.

## How we know it worked

1. **The failing test, on hardware:** iPhone locked for 30 s or more, app killed, ring through
   enspyr (`tool/hw_ring.dart invite --island`, `HW_RING_CHANNEL=01M02Y4QS94QRRQ3658BZAB0PG`),
   answer, wait 5 s, Face ID. Pass = a video-token mint for `nick`.
2. **The budget edge:** answer at ~20 s into the ring, unlock ~25 s after answering. Pass =
   joins. At ~32 s after answering, pass = released as `neverAdmitted` (the deadline, by design).
3. **Replay with an old record present:** answer and end call X; re-send X's signed invite
   (old `signedAt`) so it wakes the phone. Pass = refused (the record is not actionable in
   CallKit; the new wake gives `receipt − signedAt` > 10 s).
4. **The race:** with the invite fetch completing before the bridge listener attaches
   (unit: fake channel answers `wakeAge` while no event has been emitted). Pass = admitted.
5. **Unit (`admitRing`, pure):** admitted when `receivedAt − signedAt` ≤ 10 s with
   `now − signedAt` = 16 s; `stale` when `receivedAt − signedAt` > 10 s; falls back to `now`
   when `receivedAt` is null; `clockSkew` on negative age; refused before age when ended;
   malformed or missing `CallRef` refused before any lookup.
6. **Native:** `wakeAge` null after reboot (stored uptime > now), null for an ended CallKit
   call, null for a different call id; never re-stamped by a duplicate push.
7. **Android regression:** a Pixel cold ring still joins.

## Not in scope

- Extending the 30 s join deadline (`kInAppRingDuration`, `system_call_navigator.dart`) to cover a slow unlock. (Earlier drafts called it a "CallKit audio lease"; it is the navigator's timer.)
- #220's leftover records are neutralised for admission by property 3 (CallKit, not the
  record, decides "actionable"). Fixing the leftover itself remains #220.
- Connecting before Face ID (v1's goal). Declined by Nick, 2026-10-10.
