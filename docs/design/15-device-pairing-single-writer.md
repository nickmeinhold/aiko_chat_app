# 15 — Device pairing: one writer, checked after the fact

**Status:** design, awaiting temper. **Scope:** app-side only (`DeviceRegistrar`,
`PendingUnregisterStore`). **Supersedes:** the ordering/repair strategy on
`feat/push-pairing-wiring` (PR #156) as of `e5d7c01`.

---

## Why this is a design note and not another review round

The device-pairing straggler has now been fixed five times, each fix correct
against the finding it answered and each one opening the next:

| # | The guard | How it failed |
|---|---|---|
| 1 | Await the `DELETE` before clearing credentials | Lost the teardown; a re-login inside the window had its fresh tokens stomped |
| 2 | Fence the clear on a token check | Mis-fired on an ordinary 401 refresh, parking the user on `/login` holding a **live** credential |
| 3 | Pin `_register` behind `_settling` | Correct, but unbounded — a hung `DELETE` blocked re-registration indefinitely |
| 4 | Bound that wait with `.timeout(...)` | `Future.timeout` does not cancel the original. The `DELETE` stayed in flight with a loaded gun |
| 5 | Stop ordering it; **repair** after it lands | Below — the repair is itself an unorderable write, gated by a check sampled before its own `await` |

The repo's own rule puts the signal at guard **two**. We are at five. The
recurrence is the finding: each round treated the symptom as a timing problem
and answered it with a timing primitive, inside a system where **no operation
can be cancelled, recalled, or ordered.**

This document does not propose a sixth guard. It proposes deleting the property
that keeps generating them.

## Defect five, stated concretely

`_attemptUnregister` ends with a repair: if our late `DELETE` removed a row that
had since become live, re-`POST` it.

```dart
if (_registered != token) return;        // check
try {
  await _api.registerDevice(...);        // in flight — and unorderable
  // nothing re-examines _registered here
```

The check is sampled **before** the round trip; the write completes after it.
A session ending inside that flight is unobserved:

1. Session A registers `T`. Logout → debt(`T`) recorded, `DELETE₁` in flight, slow.
2. Same user signs back in. `drainPending` deletes the row; `start` re-`POST`s it. `_registered = T`.
3. `DELETE₁` finally lands and removes the **live** row. `_registered == T`, so the repair issues `POST₁`.
4. **Logout again**, inside `POST₁`'s flight. `_registered = null`, debt recorded, `DELETE₂` fires, lands, clears the row *and forgets the debt*.
5. `POST₁` lands. It **re-creates a routable row for a signed-out handset**, and nothing is left that will ever clear it.

That is the exact outcome the feature exists to prevent — *"the next person to
hold this handset does not receive the previous owner's pushes"* — reached by
the mechanism added to prevent it.

**Stated at its proven scope:** this instance is narrow. It requires a
straggling `DELETE` that outlives a full logout/login cycle, and then a second
logout inside a single round trip. It is *narrower* than the race round 3 was
fixing. The argument for changing the design is **not** the severity of instance
five; it is that instance five was produced by the fix for instance four, and
was found by a state-space pass rather than by four model families across four
rounds. The generator is still running.

## What the island can and cannot do (verified, not assumed)

Read directly from `../aiko-chat-island` at `a344943`:

- `unregister_device` matches on `(user_id, token)` and returns a bool; the REST
  route (`rest/devices.py:44`) discards it and answers **204 unconditionally** —
  deliberate, since a 404 would leak whether a token is registered.
- `register_device` upserts on `UNIQUE(token)` and **reassigns** `user_id` on
  conflict.
- `DeviceToken` carries `updated_at`, but **no version, generation or fencing
  token is exposed**, and no conditional delete exists.

So: an in-flight `DELETE` issued for a dead session and one issued for a live
session are indistinguishable to the island once dispatched, and its response
tells us nothing about what it did. **We cannot order these operations and we
cannot ask what happened.** Every app-side design must take that as given.

## The invariant

> For a given `(island, token)` this app issues **at most one device-roster
> write at a time**, and decides the next write only after the previous one has
> completed.

The correctness argument for solving this client-side — rather than waiting for
a server-side fence — is a property of the domain, not an assumption:

**A push token is unique per install, so this install is its only writer.**
Another handset holds a different token and touches a different row. There is no
second client to serialize against. Client-side single-flight is therefore not
an approximation of a distributed lock; it is the whole of the mutual exclusion
the row requires.

Process death breaks in-memory single-flight, and that is exactly what the
durable debt record already covers: on the next start, `drainPending` runs
strictly before `start`, which is a `DELETE`-then-`POST` sequence — the same
converging order, recovered from disk.

## The design: a reconciler, not a choreography

Replace "each operation repairs after itself" with one serialized loop.

- **Desired state** is `_registered`: a token, or `null`. It changes only on
  session edges (`start`, `_register`, `unpair`) — never inside a round trip.
- **Believed island state** is what our last completed write established.
- **One operation in flight**, chained. When it completes, re-compare desired
  against believed and issue the next write only if they differ.

```
loop:
  desired = _registered            // sampled AFTER the previous await
  if desired == believed: stop
  op = (desired == null) ? DELETE(believed) : POST(desired)
  await op                          // may fail; may have landed anyway
  believed = (op succeeded) ? desired : UNKNOWN
  repeat
```

Three properties fall out, and each one retires a guard rather than adding one:

1. **The pre-issue check disappears.** Nothing is gated on state sampled before
   an `await`, because the loop's only decision point is *after* one. Defect
   five is not fixed — it is unstateable.
2. **The straggler disappears as a category.** There is never a second write in
   flight to straggle past. "Unorderable" stops mattering when there is only one.
3. **It converges and terminates.** Desired state changes only at session edges;
   each iteration moves believed toward desired; equality stops the loop. A
   failed write sets believed to `UNKNOWN`, which is never equal to desired, so
   the loop retries rather than assuming — and `UNKNOWN` is the honest reading
   of a lost response, which may have landed.

`unpair` keeps its current contract exactly: await only the **durable debt
write** (a local preferences write, microseconds), then return, leaving the
credential clear unconditional and immediate. The reconciler is what runs out of
band, and it carries the credential by value as `_attemptUnregister` already does.

## What this subtracts

Not a new layer — a smaller one. It deletes `_settling`-as-fire-and-forget, the
repair branch and its pre-check, and the asymmetry where `_register` guards on
`_generation` while `_attemptUnregister` guards on `_registered`. Two liveness
proxies for one question become one loop condition.

`_generation` may survive for `start`'s permission-sheet window, which is a
different concern (an OS prompt, not a round trip) — the temper should rule on
whether the reconciler subsumes it or the two genuinely answer different
questions.

## Named residuals

- **A gap where the island holds no row.** Between a stale `DELETE` landing and
  the reconciler's `POST`, a push is lost. Bounded by one round trip; degrades
  reach, never correctness. Not closable without server-side fencing.
- **Sign out offline and never sign in again on this handset.** The island keeps
  a routable row. Unchanged by this design, and unreachable by any client
  mechanism; it needs a server-side expiry. Already filed.
- **`UNKNOWN` after a failed write costs a redundant round trip** on the next
  reconcile. Deliberate: re-`POST`ing a token the island already holds is an
  idempotent upsert, so guessing wrong is cheap and guessing right is
  load-bearing.

## Island handoff (separate, not a precondition)

The class exists because the roster offers no fencing. Worth proposing to the
island tab, on its own timeline: a conditional unregister — the app sends the
`updated_at` (or an opaque etag) it received from its own `register`, and the
island deletes only if the row still carries it. A stale `DELETE` then no-ops
**server-side**, which is the only place it can be made to no-op reliably.

This design does not depend on it. It is what would let a later version drop the
`UNKNOWN` retry.
