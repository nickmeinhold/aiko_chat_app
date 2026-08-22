# 15 — Device pairing: fail toward deletion

**Status:** cast 2, tempered once (RECAST), awaiting re-strike.
**Scope:** app-side only (`DeviceRegistrar`). **Supersedes:** the repair strategy on
`feat/push-pairing-wiring` (PR #156) as of `e5d7c01`.
**Round 1 record:** `15-device-pairing-single-writer-TEMPER.md` + `temper-strikes/`.

> **Cast 1 proposed a serialized reconciler and was RECAST 4/4.** Its central claim —
> "this install is the row's only writer" — was asserted rather than scheduled, and every
> family struck it. Cast 2 does not fix that claim. **It no longer needs it.** If that reads
> as a retreat, note what it costs: cast 2 is a net deletion, and the premise four families
> spent their strike on has no role in it.

---

## Why this is a design note and not another review round

The device-pairing straggler has been fixed five times, each fix correct against the finding
it answered and each one opening the next:

| # | The guard | How it failed |
|---|---|---|
| 1 | Await the `DELETE` before clearing credentials | Lost the teardown; a re-login inside the window had its fresh tokens stomped |
| 2 | Fence the clear on a token check | Mis-fired on an ordinary 401 refresh, parking the user on `/login` holding a **live** credential |
| 3 | Pin `_register` behind `_settling` | Correct, but unbounded — a hung `DELETE` blocked re-registration indefinitely |
| 4 | Bound that wait with `.timeout(...)` | `Future.timeout` does not cancel the original. The `DELETE` stayed in flight with a loaded gun |
| 5 | Stop ordering it; **repair** after it lands | Below — the repair is itself an unorderable write, gated on a check sampled before its own `await` |

The repo's rule puts the signal at guard **two**. We are at five. The recurrence is the
finding: each round read the symptom as a timing problem and answered it with a timing
primitive, inside a system where **no operation can be cancelled, recalled, or observed.**

## Defect five, stated concretely

`_attemptUnregister` ends with a repair: if our late `DELETE` removed a row that had since
become live, re-`POST` it.

```dart
if (_registered != token) return;        // checked BEFORE
try {
  await _api.registerDevice(...);        // ... and never re-checked after
```

Verified reachable, independently, by three adversary families:

1. Session A registers `T`. Logout → debt(`T`) recorded, `DELETE₁` in flight, slow.
2. Same user signs back in. `drainPending` deletes the row; `start` re-`POST`s it. `_registered = T`.
3. `DELETE₁` lands and removes the **live** row. `_registered == T`, so the repair issues `POST₁`.
4. **Logout again**, inside `POST₁`'s flight. `_registered = null`, debt recorded, `DELETE₂` fires, lands, clears the row *and forgets the debt*.
5. `POST₁` lands. It **re-creates a routable row for a signed-out handset**, and nothing remains that will ever clear it.

The root cause is a **lifecycle violation**, not merely a TOCTOU (Kelvin): the repair consults
state belonging to a *new* session to correct an operation issued by a session already dead.

**At its proven scope:** this instance is narrow — narrower than the race round 3 fixed. The
case for changing the design is the recurrence, not the severity.

## What the island can and cannot do (verified at `a344943`, not assumed)

- `unregister_device` matches `(user_id, token)`; the REST route discards its bool and answers **204 unconditionally** (a 404 would leak whether a token is registered).
- `register_device` upserts on `UNIQUE(token)` and **reassigns** `user_id` on conflict.
- `DeviceToken` carries `updated_at`, but **no version, generation or fencing token is exposed**, and no conditional delete exists.

An in-flight `DELETE` for a dead session and one for a live session are indistinguishable to
the island once dispatched, and the response says nothing about what it did. **We cannot order
these operations and we cannot ask what happened.** Every app-side design takes that as given.

---

## The governing principle: the two failure directions are not equal

Cast 1's mistake was treating "the island holds no row when it should" and "the island holds a
row when it should not" as one problem deserving one mechanism.

| | Cost | Recovers? |
|---|---|---|
| **Over-delete** (a row removed that should be live) | The handset loses push | **Yes** — self-heals, see below |
| **Under-delete** (a row kept that should be gone) | The next person holding this handset receives the previous owner's notifications | **No.** Disclosure is not undoable |

Reach degradation is recoverable and private. A leak is neither. This repo's own rule is that
**fail direction inverts by domain**; for a roster that routes a stranger's messages to a
handset, the safe direction is **toward deletion**.

The repair branch exists solely to convert the *safe* failure back into reach, by issuing a
second unorderable write. Defect five is the bill for that trade.

## The design

Three parts. Two of them are deletions.

### 1. Delete the repair branch

`_attemptUnregister` becomes: issue the `DELETE`, `forget` the debt on success, log on failure.
Nothing else. Defect five does not become unstateable — it **ceases to exist**, along with the
entire category of "a `POST` issued to correct a `DELETE`".

### 2. Name the invariant `_register` already obeys

The repair was not the only `POST` site; it was the only one that got this **wrong**. The
existing `_register` already ends:

```dart
if (generation != _generation) {
  await _pending.remember(_islandBaseUrl, token);   // landed into a dead session — owe a DELETE
  return;
}
```

That is the whole rule, and it was already here. Promote it from an implementation detail to a
stated invariant every present and future `POST` site inherits:

> **REGISTER INVARIANT.** Any `registerDevice` that may have landed re-checks liveness
> **after** its `await`. If the pairing it was issued for is no longer current, it **records a
> debt** rather than assuming it was harmless.

Note the direction: the post-await check's remedy is always to *owe a deletion*, never to issue
a compensating write. That is what keeps it from generating a guard six. `_generation` is the
liveness signal — **not deleted, not "an open question": it is the mechanism** (unanimous
adversary ruling, round 1).

### 3. Restore reach by re-assertion, not by correction

Deleting the repair means an over-deleted row stays deleted. Unmitigated, the handset is deaf
until the next sign-in — days. So reach is restored by **periodically restating the truth from
the only place that knows it**:

> On app resume, **if a pairing is already established** (`_registered != null`) and the last
> successful register is older than `_reassertAfter`, re-`POST` the current token.

- It is a `POST` from a **live session** — desired state read at issue time, current credential, no dead-session write in play.
- It is an **idempotent upsert** on `UNIQUE(token)` by island design, so re-asserting is free and safe.
- It obeys the **register invariant** above, so a logout landing inside its flight owes a `DELETE` rather than leaving a row.
- It cannot disturb `drainPending`'s strict-before-`start` ordering **by construction**: `_registered` is non-null only after `start` completed, which is after the drain.

Recovery from an over-delete drops from *the next sign-in* to *the next foreground*. That is
what makes deleting the repair affordable; the two halves are one design.

`_reassertAfter` is a throttle, not a heartbeat — a foreground event is frequent and a
round trip is not free. Start at 6 hours and treat it as a tuning knob, not a correctness
parameter: correctness never depends on how often this fires, only reach does.

## What cast 2 does NOT need, and cast 1 did

Each of these was a round-1 fatal flaw. They are not fixed here; they are **absent**:

- **No single-writer claim.** The premise all four families struck — "a push token is unique per install, so this install is the row's only writer" — has no role. Nothing here assumes it. Already-dispatched HTTP from a dead incarnation is handled by the register invariant, not excluded by an assumption.
- **No `UNKNOWN` state**, so nothing un-actionable is stored and no `DELETE(believed)` ghost exists.
- **No retry loop**, so no backoff, no termination proof, no `while(true)` against a hung island. The failure path is today's: leave the debt, stop, pay at the next session edge — which round 1 confirmed was correct.
- **No scalar-vs-set mismatch.** `drainPending` keeps its set worklist untouched; nothing tries to express a 16-entry ledger as one desired token.
- **No queue**, so single-flight's unbounded delay behind a hung `DELETE` never arises.
- **No persisted state machine** — no `inFlightKind`, no `lastKnownToken`, no new durability boundary.

## Net change

| | |
|---|---|
| **Deleted** | the repair branch and its pre-`await` check (~20 lines) |
| **Added** | a re-assert path on app resume + its throttle (~15 lines) |
| **Promoted** | an existing 4-line block to a stated invariant (0 lines) |
| **Unchanged** | `unpair`'s contract, the debt store, `drainPending`'s ordering, `_generation` |

`unpair` keeps its contract exactly: await only the **durable debt write** (local preferences,
microseconds), then return, credential clear unconditional and immediate. That contract is what
five rounds actually bought and nothing here reopens it.

## Named residuals

- **Deafness between an over-delete and the next re-assertion.** Bounded by `_reassertAfter` and by the app being foregrounded. Reach, never correctness, never disclosure — the direction we chose deliberately.
- **A hung `DELETE` is still un-cancellable.** It is no longer *ordered against* anything, so it no longer delays a `POST` or triggers a compensating write. It lands, or it doesn't, and the debt outlives it either way.
- **Sign out offline and never sign in again on this handset.** The island keeps a routable row. Unchanged, unreachable by any client mechanism; needs server-side expiry. Filed.
- **The debt store's 16-entry FIFO eviction** drops a debt, leaving an island row this client can never clear. Named in the store, and now named here: it is a **correctness degradation in the leak direction**, which is the direction that does not self-heal. It deserves its own decision, not a footnote — filed.
- **A backup-restored debt file** names another living device's token and would `DELETE` it under the same `user_id`. Independent of this design. Filed (device-stamp each debt; discard on mismatch — fails closed).

## Island handoff (separate, not a precondition)

Worth proposing to the island tab on its own timeline: a **conditional unregister** — the app
sends the `updated_at`/etag its own `register` returned, and the island deletes only if the row
still carries it. A stale `DELETE` then no-ops **server-side**, which is the only place it can
be made to no-op as a *fact* rather than as a hope, and it would let a later version drop the
over-delete residual entirely.

This design does not depend on it.

## Acceptance bar (Tesla's subtraction test, adopted from round 1)

> The recast is real only when `_attemptUnregister`'s repair is **gone**. If it remains beside
> anything, this document is guard six and must not supersede #156.

Cast 2 meets it by deleting the repair rather than replacing it. The remaining question for the
re-strike is whether **re-assertion** is a fourth writer in disguise — the design's answer is
that it is not, because it obeys the register invariant and issues from a live session, and
that answer is the thing to strike hardest.
