# 15 — Device pairing: fail toward deletion

**Status:** cast 3, tempered twice (RECAST, RECAST), awaiting re-strike or build.
**Scope:** app-side only (`DeviceRegistrar`). **Supersedes:** the repair strategy on
`feat/push-pairing-wiring` (PR #156) as of `e5d7c01`.
**Round records:** `…-TEMPER.md` (r1), `…-TEMPER-r2.md` (r2), `temper-strikes/`.

> **Cast 1** proposed a serialized reconciler — RECAST 4/4; its single-writer premise was
> asserted, never scheduled.
> **Cast 2** deleted the repair branch and hung reach on a resume timer — RECAST. Two findings
> broke it, both traced against the source: the resume timer is **deaf at the one frequency
> over-delete actually occupies**, and a late `POST` crossing a logout is not an idempotent
> upsert but a **cross-account reassignment** — a theft that owing a `DELETE` cannot undo.
> **Cast 3** keeps cast 2's deletion, and replaces its clock with evidence.

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

## The governing principle: the failure directions are unequal — but not uniform

| | Cost | Recovers? |
|---|---|---|
| **Over-delete** (a row removed that should be live) | The handset goes deaf: a missed call, a missed MFA code, a missed alert | Yes — but only if something **restates** the pairing |
| **Under-delete** (a stale row kept) | The signed-out user keeps receiving their own previews; on a transferred handset, a stranger's | No. Disclosure is not undoable |
| **Reassignment** (a late `POST` hands the row to the *previous* user) | The **current** user's whole session is deaf while the previous owner receives their notifications | No — and a `DELETE` cannot fix it (below) |

Round 2 corrected two things here, and neither is cosmetic.

**Lost reach is an availability failure, not a private inconvenience.** Cast 2's table filed it
under "self-heals" and moved on. A user who misses the only call that mattered is not consoled
that the row would have healed. Privacy still orders *ahead* of reach — a leak is irreversible
and deafness is not — but "recoverable" only counts if a mechanism actually recovers it, which
is what cast 2 got wrong.

**And the safe direction is not uniform.** `register_device` upserts on `UNIQUE(token)` and
**reassigns `user_id`**. So a `POST` that crosses a logout does not merely linger — it takes the
row *back* from whoever owns it now:

> A's re-assert `POST` goes in flight → logout → B signs in → `drainPending` → `start` (row is
> B's) → **A's `POST` lands and reassigns the row to A**. B's credential cannot delete A's row
> (`unregister` matches `(user_id, token)`), and B's drain already ran. B's entire session is
> the previous owner's lock screen.

**A reassignment cannot be repaired by owing a `DELETE`.** Only a `POST` from the *current*
session takes the row back. Fail-toward-deletion is right for a **stale** row and wrong for a
**stolen** one, and a design that applies one remedy to both is choosing the wrong failure half
the time.

## The design

### 1. Delete the repair branch

`_attemptUnregister` becomes: issue the `DELETE`, `forget` the debt on success, log on failure,
and **signal** (part 3). No `POST`. Defect five does not become unstateable — it **ceases**,
along with the category of "a `POST` issued to correct a `DELETE`".

This is Tesla's adopted acceptance bar, and cast 3 meets it by deletion, not by replacement.

### 2. One `POST` door, with a complete check on the far side

Round 2 found cast 2's invariant was prose rather than a door: `_register` returns **before the
wire** when `token == _registered` — exactly the steady state a re-assertion exists to restate.
So skip-if-same is demoted to what it always was (an optimisation for the refresh path), and
every register — `start`, rotation, re-assert — enters **the same tail**. A second copy of the
check would be guard six.

> **REGISTER INVARIANT.** Every `registerDevice` re-checks, **after** its `await` and on
> **success or throw**, whether the pairing it was issued for is still current — testing *both*
> the issue-time generation *and* the desired token. If it is not current, it takes the remedy
> that matches what the write did.

Three corrections round 2 forced into that sentence, each from a traced defect:

- **On throw, too.** Deleting the repair branch nearly threw away its one real insight: *"it threw" is not "nothing happened".* A `POST` whose response was lost may have landed. Outcomes are classified **definitely-not-landed** vs **maybe-landed**; where the REST client cannot distinguish them, it says so and the maybe-landed branch is taken.
- **Generation is not enough.** `_generation` answers *session* liveness, not *token* currency. A re-assert of `T1` in flight across a rotation to `T2` lands with the generation still matching, rolls `_registered` back to `T1`, and `T2` then leaks. The check tests both.
- **The remedy is direction-dependent** — the correction that matters most:

| What the stale `POST` did | Who owns the row now | Remedy |
|---|---|---|
| Registered for a session that has since ended, and no session is live | The dead session's user | **Owe a `DELETE`** (the debt record, as today) |
| Registered for a dead session **while another session is live** — a reassignment | The *previous* user | **Nudge the live door** — only a `POST` from the current session takes it back |

### 3. Re-assert on evidence, not on a clock

Cast 2's fatal flaw: over-delete is not a mystery outage. It is `unpair`'s `DELETE₁` completing
on the **ordinary second sign-in, same isolate, app already foregrounded** — where Flutter
delivers no `resumed` event for the session you are already sitting in, and a throttle refuses
anyway because `start()` just succeeded. The clock was deaf at the one frequency the fault
occupies.

So the trigger is the **evidence**, at the moment it arrives:

- **Primary — the straggler's own completion.** When `_attemptUnregister` finishes, success or failure, and this registrar still holds `_registered == token`, it **signals the live door** to restate the current pairing at the current generation. It does **not** `POST` from the `DELETE` path; that path has a dead credential and a dead session's state, which is how defect five was born. An *observed* over-delete now heals in one live round trip.
- **Secondary — a detected reassignment.** The stale-`POST` branch of the invariant, per the table above.
- **Backstop only — resume plus a throttle.** For an *unobserved* over-delete: a `DELETE` that succeeded and then threw, so nothing knows a row was removed. Explicitly a backstop, and explicitly **not** the primary self-heal. Answering the already-foreground gap by setting the interval to zero is how a throttle becomes a correctness parameter and how a flaky network fills the isolate with uncancelled `POST`s.

**Is the nudge a compensating write — guard six?** The honest test, and the thing to strike
hardest: a compensating write corrects *a specific prior operation* using state sampled before
its own `await`. The nudge does neither. It restates **current desired state**, from a live
session, at the current generation, through the one door, subject to the same post-`await`
check as every other register. It is not aimed at the straggler; the straggler is merely when we
learned to look.

Ordering with `drainPending` is preserved **by construction**: the nudge fires only when
`_registered != null`, which is true only after `start` completed, which is after the drain.

## What cast 3 does not need, and cast 1 did

Each was a round-1 fatal flaw, and round 2 re-litigated none of them. They are **absent**:

- **No single-writer claim.** The premise all four families struck has no role here.
- **No `UNKNOWN`**, no un-actionable state, no `DELETE(believed)` ghost.
- **No retry loop**, so no backoff proof, no termination proof, no `while(true)` against a hung island. A failed `DELETE` leaves the debt and stops — today's path, which round 1 confirmed correct.
- **No scalar-vs-set mismatch.** `drainPending` keeps its set worklist untouched.
- **No queue**, so no unbounded delay behind a hung `DELETE`.
- **No persisted state machine** — no `inFlightKind`, no `lastKnownToken`, no new durability boundary.

## Net change

| | |
|---|---|
| **Deleted** | the repair branch and its pre-`await` check |
| **Added** | a `force` entry sharing `_register`'s tail; a signal from `_attemptUnregister`'s completion; the resume backstop |
| **Widened** | the existing post-`await` block — runs on throw too, tests desired-token as well as generation, and branches to nudge-or-owe |
| **Unchanged** | `unpair`'s contract, the debt store, `drainPending`'s ordering, `_generation` |

`unpair` keeps its contract exactly: await only the **durable debt write** (local preferences,
microseconds), then return, credential clear unconditional and immediate. That contract is what
five rounds actually bought and nothing here reopens it.

## Named residuals

- **An unobserved over-delete waits for the backstop.** Where the `DELETE` succeeded and then threw, nothing knows a row was removed, so the primary signal never fires. Bounded by the resume backstop, the next sign-in, or process death. This is the honest bound; cast 2's "recovery drops to the next foreground" was not.
- **A stale re-assert can plant a debt that later over-deletes a live row.** Safe direction, real cost, named rather than covered. Mitigated by the next restatement, not by `_generation`.
- **A `POST` in flight across an account switch reassigns the row** until the live session restates it. The nudge is what closes this; until it lands, the previous owner rides the handset.
- **A hung `DELETE` is still un-cancellable.** It is no longer ordered against anything, so it delays nothing and triggers no compensating write.
- **Sign out offline and never sign in again on this handset.** The island keeps a routable row. Unchanged, unreachable by any client mechanism; needs server-side expiry. Filed.
- **The debt store's 16-entry FIFO eviction** drops a debt, leaving a row this client can never clear — a degradation in the **leak** direction, which is the one that does not self-heal. Deserves its own decision. Filed.
- **A backup-restored debt file** names another living device's token and would `DELETE` it under the same `user_id`. Independent of this design. Filed.

## Island handoff (separate, not a precondition)

Worth proposing to the island tab on its own timeline: a **conditional unregister** — the app
sends the `updated_at`/etag its own `register` returned, and the island deletes only if the row
still carries it. A stale `DELETE` then no-ops **server-side**, which is the only place it can
be made to no-op as a *fact* rather than as a hope, and it would let a later version drop the
over-delete residual entirely.

This design does not depend on it.

## Acceptance bar

**Tesla's subtraction test, adopted round 1 and re-affirmed round 2** (he declined to move it
after being cited):

> The recast is real only when `_attemptUnregister`'s repair is **gone**. If it remains beside
> anything, this document is guard six and must not supersede #156.

Cast 3 meets it by deletion. The open question handed forward — and the thing to strike hardest
— is **whether the nudge is a restatement or a compensating write in better clothes.** The
design's answer is in part 3; it is an argument, not a proof, and it is where cast 3 is most
likely to be wrong.

**Design temper only. The implementation is UNPROVEN and a code cage-match is owed on whatever
ships.**
