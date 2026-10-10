# Design 23: an answered ring is judged by when it rang

**Status:** DRAFT v2, 2026-10-10 · **Issue:** #219 · **Blocks:** iOS half of 0.0.6 (#214)
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

## Decision

When `admitRing` judges an invite whose `CallRef` has a **live native ring record on this
device**, it measures age against **the time that record was created** (the native receipt
of the VoIP or FCM wake for that call id), not against `now`:

```
receivedAt = nativeRingReceivedAt(callRef)          // null if no live native record
age        = (receivedAt ?? now) − signedAt
```

Everything else in `admitRing` is unchanged and still runs first: signature verified, not
own, sender kind and consent, DM-only, not blocked, not muted, then age. `clockSkew` (negative
age) and `stale` (age > 10 s) keep their meaning; only the instant changes.

The session tokens stay `WhenUnlocked`. Nothing about the keychain changes. Joining needs
auth, auth needs Face ID, and the user gives Face ID by answering, the same contract Android
enforces with `requestDismissKeyguard` before it opens the app.

### Why this does not open a replay

The worry is a *stale* invite manufacturing a fresh receipt and vouching for itself.

- **A receipt cannot launder an old signature.** If an island (hostile or buggy) re-pushes an
  old signed invite, the native record is created *now*, so `receivedAt − signedAt` is as
  large as the invite is old, and it is refused exactly as today. The signed `signedAt`
  remains the only input from the caller. The receipt only stops the gate from also counting
  *our* latency after the push arrived.
- **A receipt can only make age smaller.** `receivedAt ≤ now` always, so the rule can only
  turn a refusal into an admission, never the reverse. That makes the next bound the
  important one:
- **The record must be live, and recent.** An *old* record for the *same* call id (for
  example one that survived its call, see #220) would let a replay of that original invite
  be admitted later with its original, prompt receipt time. So:
  - only a record in a **live** state counts (ringing, or answered and not yet joined or
    ended); a retired or ended record ("tombstone") never does;
  - and `now − receivedAt` must be within a **receipt horizon this design owns**, not one
    borrowed from the native trust windows. Those are far too loose for this job: iOS trusts
    a ringing record for 120 s and an *answered* record for **8 hours**
    (`liveCallTrustWindow`, `answeredCallTrustWindow` in `AppDelegate.swift`), the latter
    so that a force-quit cannot strand a call forever. Android's ring ceiling is 30 s
    (`RING_CEILING_MS`). Proposed horizon: **60 s**. That covers ring (≤ 30 s, the island's
    ceiling) plus Answer → Face ID → restore, and it is still short enough that a replay of
    an old invite, matched to an old record, is out of reach.
  The replay window is therefore bounded by a horizon close to the ring's own lifetime,
  which is the protection a freshness gate is for in the first place. **#220 (a native ring record that outlives its
  call) must be fixed first, or bounded by this check**, because it is exactly the stale
  record this rule must not trust.
- **The receipt is device-local.** It is not on the wire and nothing remote can set it. Only
  the wake handler that rings the phone writes it, keyed by the `m` the push carried, and that
  `m` is checked against the signed body's call id when Dart admits (a mismatch means no
  record, so `now` is used).

### What it costs

- **One field on the native→Dart bridge.** The action events (and the replay of pending ones
  at `onListen`) carry `receivedAtMs`: wall-clock milliseconds when the native side created
  the ring record. iOS already stamps it (`entry.at`, seconds since 1970). Android stamps
  `elapsedRealtime`, so it converts once at emit time
  (`currentTimeMillis − (elapsedRealtime − instance)`). This is an addition to the
  method-channel contract, pinned by `system_call_channel_contract_test`.
- **Dart keeps a short map** `CallRef → receivedAt` from bridge events, consulted by the
  ring controller when it calls `admitRing`, and dropped when the record ends.
- **No wire change. No island change.**

## The locked-call path, end to end (iOS, cold, locked)

| Step | Who | Needs keychain? | Budget |
|---|---|---|---|
| Wake arrives, ring record created (`receivedAt`) | native | no | ~1 s after persist (measured 0.35–0.98 s) |
| CallKit rings, user answers | native + user | no | user; the ring ceiling is 30 s |
| Audio session armed | native | no | measured: the call is torn down **exactly 30.0 s after Answer** if not joined (runs 1 and 4) |
| User unlocks (Face ID) | user | | user |
| Dart restores the session, fetches the invite | Dart | **yes** | ~2–3 s after unlock (run 1: 55.4 → 57.4) |
| `admitRing`: age = `receivedAt − signedAt` (~1 s) → admitted | Dart | no | immediate |
| Answer matched, video token minted, join | Dart | yes | ~0.3 s (Pixel: 140 ms) |

So the binding constraint becomes **Answer → Face ID → join < 30 s**, not anything about the
invite. Runs 1 and 4 would have joined at about 12 s after Answer. A user who takes longer
than ~25 s to unlock loses the call. **Unpinned:** what enforces that 30 s. In both failed
runs the CallKit call was torn down 30.0 s after Answer (`disarm` in the device log), but
this draft has not traced whether it is the island's ring ceiling arriving as an end, or an
app-side expiry of the pending answer. The build must pin it before relying on the budget.
Extending it is a separate decision.

**Locked-read contract (unchanged, now stated):** before Face ID, a keychain read throws
`errSecInteractionNotAllowed`, raised by the plugin as a `FlutterError`. Today's restore path
treats it as transient: `token_provider.dart` clears tokens only on `RefreshRejected`, and
`auth_controller.dart:599` documents the throw. No change. A rule, written down so no future
change breaks it: **a locked read must never be flattened to "absent"**, because
`SovereignKeyStore._loadOrCreate` treats "absent" as "mint a new identity".

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

1. **Hardware, the failing test:** iPhone locked for 30 s or more, app killed, ring through
   enspyr (`tool/hw_ring.dart invite --island`, `HW_RING_CHANNEL=01M02Y4QS94QRRQ3658BZAB0PG`),
   answer, **wait 5 s, then Face ID**. Pass = a video-token mint for `nick`.
2. **Replay, on hardware:** reuse an old call id. Re-send a signed invite that is more than
   10 s old (ring_probe with a stored old body), and let it wake the phone. Pass = refused
   as `stale`, no ring admitted.
3. **Unit (Dart):** `admitRing` with `receivedAt` set: admitted when receipt − signedAt ≤
   10 s even though now − signedAt is 16 s; refused when receipt − signedAt > 10 s; refused
   (falls back to `now`) when the record is not live, is older than the ring lifetime, or
   names a different call id; `clockSkew` still fires on negative age.
4. **Contract:** `receivedAtMs` present on answered and replayed events, both platforms;
   Android's converted value is within 1 s of wall clock.
5. **Android regression:** a Pixel cold ring still joins (the 2026-10-09 baseline).

## Not in scope

- Extending the 30 s CallKit audio lease to cover a slow unlock.
- #220, except that it is a **prerequisite**: v2 must not trust a native record that outlived
  its call.
- Connecting before Face ID (v1's goal). Declined by Nick, 2026-10-10.
