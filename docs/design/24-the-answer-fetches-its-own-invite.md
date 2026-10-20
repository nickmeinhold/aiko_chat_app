# Design 24 — the answer looks up its own invite

| | |
|---|---|
| **Status** | **PROPOSAL v2**, folding temper round 1 ([`24-TEMPER.md`](24-TEMPER.md): 4/4 RECAST, zero DISSOLVE). Un-built. |
| **Owner** | Claude (app tab), 2026-10-19 (v1), 2026-10-20 (v2) |
| **Answers** | #392 at the level the PR #395 cage-match could not reach: *why does a dead socket mean a failed answer?* |
| **Wire change** | **None.** Every read below uses endpoints the island already serves. |
| **Scope** | **Android, warm process, phone woken from sleep.** iOS is unchanged (§2). |

**What v2 changes, in one line.** v1 made a REST page *impersonate a transport delivery*: persist each row and let the new-message announcement tell the ring. Three families independently said the answer does not need a delivery. **It needs a lookup of ONE call.** v2 is that change of object. The rest of v1's mechanism goes with it.

---

## 0. The defect, and what is still measured after #395

On a Pixel (release build, island-sent ring, 2026-10-19), a warm app whose phone slept had a dead socket and an expired token. The user answered and unlocked within 3 s; the answer was held for 30 s and resolved `neverAdmitted`. Every path to admission waits on a socket connect: `_fetchDeltaHistory` has exactly one caller, `_runReconnect`, which runs on `connected` and needs the `suback` fences.

**Honest status of the urgency (temper flaw 9).** PR #395 round 1 **joined on hardware** 1.35 s after Answer: it retries a failed refresh and kicks the socket on Answer. Its round 3 found one regression that is a one-line policy (a fresh token is new information, so retry immediately). **So this design is defence in depth, not the only fix.** What it buys over #395:

- **The call stops depending on the socket's own lifecycle at all.** #395 makes the socket recover fast; three cage-match rounds each found a new way for that recovery to stall (an orphaned timer, an unowned refresh, a retry policy). A call that must wait for the socket inherits every future member of that class.
- **The socket's 403 cannot tell "renew" from "stop".** The island rejects a WS handshake with 403 for *every* reason (`realtime/ws.py:32`). REST answers an expired token with **401** and a ban with a structured 403 (`rest/deps.py:40-43`), so REST renews where the socket cannot. Verified 2026-10-20.

Priority: **after** #395 merges with its round-3 fix.

## 1. The record this answers to

- **Island design 19, TEMPER and RECAST:** the invite stays **in-band**, a channel message on the history bus (temper flaw 2). Two delivery paths must agree on one object. The trilemma (stateless island, locked-phone join, sealed envelope: pick two) is cross-tab, claude-tasks#4374.
- **App design 20** (sealed ring envelope): arm C accepted in principle by the island tab, un-tempered. It is the design that lets a locked phone join **with the bytes already on the device**. This design does not do that and does not compete with it (§6).
- **App design 23** (the session survives the lock): freshness is judged by the native wake age, not by when Dart arrives. On a locked iPhone no Dart request authenticates until Face ID. Unchanged here.

## 2. Scope (temper flaw 9)

- **Android:** after Answer the activity is foreground and unlocked, the network is unblocked, and the push's temporary allowance is live. This is the case #392 measured.
- **iOS: unchanged.** Session tokens are `WhenUnlocked`, so the lookup waits for Face ID exactly as the socket does. Design 23 already admits by wake age.
- **The trilemma is NOT held (retracted from v1).** This design needs a sessioned round trip after the user's own authentication. That is design 23's accepted product, a horn declined, not held. Design 20 remains the only design that holds locked-phone join with a sealed envelope.

## 3. Decision (v2)

> **When a ring is answered, the answer looks up ITS call — by `CallRef` — first in the cache, then in history if the cache misses. It hands that one verified invite to admission directly, and races the socket until the answer deadline.**

### 3.1 The object: one call, not a page

The lookup key is the answered `CallRef` (`channel c` + call ULID `m`), already bound at the native door (design 22 v4.2). The lookup returns **at most two messages**: the signed invite whose verified body names that `CallRef`, and any signed END naming it. Nothing else on any page reaches the ring (temper flaw 4: a page is a burst).

### 3.2 Cache first (temper flaw 1: persistence is not delivery)

`_announceInbound` fires only on a **first** insert, so an invite already cached (live fanout before the controller subscribed, an earlier lookup, a controller rebuilt over a surviving cache) would never be announced again. So the lookup **reads the cache** for channel `c` before fetching anything, scanning recent rows for a verified invite or END naming `m`. A cache hit costs no network and cannot be missed by the announce-once rule.

### 3.3 On a miss: backward search through the existing page applicator (flaws 2 and 3)

History pages backward natively: with no cursor the island returns the newest `limit` items, **in ascending order**; `before: next_before` returns the next older page, also ascending (`messages_service.get_history`, `rest/messages.py`).

- **Each page is applied by the existing page applicator**, extracted from `_fetchDeltaHistory`: retractions first, then messages in ascending order, through `_persistInbound`. No message is persisted on its own, so the crash-between-insert-and-retract ghost stays closed. **The bookmark is not advanced:** `advanceHistoryContiguous` stays the delta loop's call alone.
- **Stop conditions, whichever comes first:** the `CallRef` is found; the page's oldest item is older than *wake − (freshness window + clock skew)* (an invite older than that cannot be admitted anyway); a page budget (proposed: 4 pages × 50); or the answer deadline. *Found* is matched on the **verified body's** `CallRef`, never on a cursor. The call ULID is the client's id, not the row's server ULID, so `after: m` would be wrong twice: wrong key and exclusive.

### 3.4 Admission: explicit, filtered, unchanged inside

The found invite (and END, if any) are handed to `RingController` through a new explicit entry, `considerAnswered(callRef, messages)`. It runs the **same** `_consider` path: `admitCallEnd`, then `admitRing` with `wakeAge` for that `CallRef`, consent, blocks, mute, and the END check. Nothing is admitted that does not name the answered `CallRef`; other rows on fetched pages persist as history and never ring.

### 3.5 Ownership (temper flaw 5)

The answer **hold** owns the lookup. It carries the hold's identity; every await is followed by an ownership check, and the lookup stands down when the hold resolves (joined, ended, displaced, deadline), on identity change, and on repository dispose. It does not borrow the reconnect epoch, because that epoch is cancelled by socket loss, which is the very case this exists for. Writes from a stood-down lookup are dropped before they reach the cache.

### 3.6 A race, not a fallback (temper flaw 6)

The lookup runs **alongside** live fanout. The first verified arrival of the answered `CallRef` from either path wins; the other is a no-op through dedup. The lookup retries a failed request (backoff bounded by the answer deadline) rather than giving up once: it must not recreate "tried once and never retried" over REST.

New ring telemetry, distinct from `neverAdmitted`: `answer.lookup` with `outcome = cacheHit | fetchHit | notFound | fetchFailed | superseded`. `fetchFailed` is evidence, never a terminal state, because the socket may still win the race.

## 4. What else a call needs the socket for (temper flaw 8)

| signal | before join | after join |
|---|---|---|
| the invite | this design (cache → history), racing the socket | — |
| the caller's END | found by this lookup if already sent; native FCM `call_end` wake stops the ring and emits `ended` to Dart | LiveKit `ParticipantDisconnectedEvent` / `RoomDisconnectedEvent` (`livekit_call_service.dart:258-274`) |
| the media token | REST mint (`livekit_call_service.dart:77`), already off the socket | — |
| retraction of the invite | applied by the page applicator, retractions first | — |
| a second device answering | **socket only today.** After a REST join with a dead socket, this device will not learn another device answered. Bounded: LiveKit occupancy shows it, and the existing `displaced` outcome handles it when the socket returns | — |

So **the transport kick from #395 stays a co-requirement.** It is no longer what decides whether the call joins, but the second-device signal still rides it.

## 5. Hazards and interleavings

| interleaving | outcome |
|---|---|
| answer during `_runReconnect` | both apply pages through the same door; dedup makes writes idempotent; admission is by explicit lookup result, not by announce, so neither depends on which insert won |
| invite arrives on the socket first | the hold resolves; the lookup sees the hold gone at its next ownership check and stands down |
| END already in history | the lookup returns it with the invite; `admitRing`'s END check refuses, and the answer resolves `endedInSystemUi` / `callerHungUp`, not `neverAdmitted` |
| logout or account switch mid-lookup | identity change stands the lookup down; no write |
| a page that contains other fresh invites | persisted as history only; never admitted (§3.4) |

Trust boundary: the lookup feeds `admitRing`, so **cage-match by law**, as for design 23.

## 6. Relationship to design 20 and to PR #395

- **#395 first**, with its round-3 fix. It stays a co-requirement (§4).
- **Design 20 is not made less urgent by this.** It is the only route to a locked-phone join without a network round trip, and the only answer to the hostile-island threat in its §0. This design touches neither.

## 7. Questions for temper round 2

1. Is cache-first plus a bounded backward search a complete retrieval contract, or is there a case where the invite exists on the island, is admissible, and neither the cache nor the bounded search reaches it?
2. Does extracting the page applicator from `_fetchDeltaHistory` without its bookmark advance leave any invariant of the delta loop that the extraction silently drops?
3. Is "the hold owns the lookup" sufficient ownership, or is there a writer that outlives the hold?
4. Is the second-device gap (§4) acceptable as bounded, or does it need its own non-socket path before this ships?

## 8. Provenance

v1 (2026-10-19) went from the handoff to transport code without the cross-tab read this repo's CLAUDE.md requires. Nick's *"is this island work?"* surfaced it; the read changed the question. v1's own temper then found it had kept the transport's shape (a delivery) while removing the transport: the #2634 pattern inside the design meant to escape it.
