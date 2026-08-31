# TEMPER round 2 — "Fail toward deletion" (cast 2)

**Overall verdict:** **RECAST**
**Struck:** four families, all seated. Round 1's verdict was in the bundle as settled context.

| Family | Verdict | One line |
|---|---|---|
| Kelvin (Gemini) | **SOUND** | "Build it. There is nothing to fold back." |
| Carnot (GPT) | RECAST | The proof leaks heat at the exact place the author named: re-assertion is a new POST site, not a reuse. |
| Tesla (Grok) | RECAST | The self-heal is deaf at the only frequency over-delete occupies, and a late POST across a logout is a *theft*, not an upsert. |
| Maxwell (Claude) | RECAST | Concurs; I do not get to bank a SOUND vote that waived the question that broke the design. |

**On Kelvin's SOUND.** It is recorded, not banked. Kelvin explicitly set aside the one thing
that turned out to be fatal — *"'App resume' is an implementation detail, not a design flaw...
contained to resource usage, not correctness."* Tesla then proved that lifecycle question is
exactly where cast 2 fails. A SOUND that waives the crux is a **coverage gap wearing a verdict**,
which is the live-seat sibling of a dark seat. It does not offset two families with traced,
code-verified findings.

## Fatal flaws (deduped, most-severe first)

1. **The self-heal is deaf at the only frequency over-delete occupies.** — *Tesla*
   Over-delete is not a mystery outage: it is `unpair`'s `DELETE₁` completing on the **ordinary
   second sign-in, same isolate, app already foregrounded**. No `resumed` event fires — Flutter
   does not deliver one for the session you are already sitting in — and `_reassertAfter` then
   refuses for six hours because `start()` just succeeded. Recovery does **not** drop to "the
   next foreground"; it drops to the next sign-in, a rotation, or process death — the
   unmitigated case cast 2 called unaffordable. **Part 3 does not pay for Part 1.** A user who
   signs out and back in, then stays in the app, is a deaf handset for the working day, on a
   feature whose job is waking the phone for a call.
   **DISPOSITION: fold — re-assert on EVIDENCE, not on a clock.**

2. **A late `POST` across a logout is a cross-account REASSIGNMENT, and the invariant's remedy cannot undo it.** — *Tesla*
   `register_device` upserts on `UNIQUE(token)` and **reassigns `user_id`**. Trace: A's re-assert
   `POST` in flight → logout → B signs in → `drainPending` → `start` (row is B's) → **A's `POST`
   lands and reassigns the row back to A** → generation mismatch → `remember(T)`. But B's
   credential cannot delete A's row, and B's drain already ran. **B's whole session is the
   previous owner's lock screen.** The design verified reassign-on-conflict at `a344943` and then
   priced it as a no-op. "Idempotent and free" is true for the same user and false the moment the
   `POST` crosses a logout.
   **DISPOSITION: fold, and it forces a correction to the governing principle.** A reassignment
   cannot be repaired by owing a `DELETE`; only a `POST` from the *current* session takes the row
   back. Fail-toward-deletion is the right direction for a *stale row*, not for a *stolen* one.

3. **Re-assertion cannot reuse `_register`, so the invariant is prose, not a door.** — *Carnot and Tesla, independently*
   `_register` returns before the wire when `token == _registered` — precisely the steady state
   re-assertion exists to restate. The design's "0 lines, every future POST site inherits" claim
   is therefore false as written; and a second copy of the block is guard six.
   **DISPOSITION: fold — ONE `POST` door.** `start`, rotation and re-assert all enter the same
   tail; skip-if-same becomes an opportunistic guard on the refresh path, not a wall.

4. **The invariant fires only on success; a `POST` that landed and then threw is unhandled.** — *Carnot and Tesla*
   The repair branch's one genuine insight — "it threw" is not "nothing happened" — was deleted
   along with it. An ambiguous `POST` failure after a logout can still leave a row.
   **DISPOSITION: fold.** The post-`await` check runs on **success or throw**; a maybe-landed
   `POST` with a stale generation records a debt. Classify outcomes as definitely-not-landed vs
   maybe-landed, and if the REST client cannot distinguish them, say so and fail toward debt.

5. **`_generation` answers session liveness, not token currency.** — *Tesla, Carnot*
   A re-assert of `T1` in flight across a rotation to `T2` lands with the generation still
   matching, rolls `_registered` back to `T1`, and `unpair` then owes the stale token while `T2`
   leaks.
   **DISPOSITION: fold.** The post-`await` check tests **both** generation and desired-token.

6. **A stale re-assert can plant a debt that later over-deletes the live row.** — *Carnot*
   Safe direction, but it must be named and priced, not hidden under "covered".
   **DISPOSITION: fold as a named residual.**

7. **The asymmetry table oversells the leak and undersells the reach.** — *Tesla, Carnot*
   Defect five's typical body is the same person still receiving their own previews; the
   stranger-disclosure case is largely the offline-sign-out residual this design does not touch.
   And lost reach is a missed call, MFA code or safety alert — an availability failure, not a
   cheap private inconvenience.
   **DISPOSITION: fold.** Keep the privacy-first *ordering*; restate both costs honestly.

8. **`_reassertAfter` and "app resume" are under-specified.** — *Carnot, Tesla*
   Which platforms deliver resume; whether repeated foregrounds create concurrent `POST`s; how
   failures back off. And the knob is load-bearing for the claim that Parts 1 and 3 are one
   design — set it to infinity and only Part 1 remains.
   **DISPOSITION: fold**, but note Tesla's warning: answering flaw 1 by setting the interval to
   zero is how a throttle becomes a correctness parameter.

## What holds

- **The subtraction test is MET** — Tesla's own bar, and he declined to move it after being cited: the repair `POST` is gone, not sitting beside a new machine.
- **Fail toward deletion survives as a governing *direction*.** Cast 1's equal-weighting stays dead.
- **Defect five ceases as a category** when that branch ceases. Do not put the `POST` back in `_attemptUnregister`.
- **Everything cast 2 made absent stays absent** — no single-writer claim, no `UNKNOWN`, no retry loop, no scalar-vs-set, no queue. Not re-litigated by anyone.
- `unpair`'s contract, `drainPending` strictly before `start`, `_generation` as the session fence, the named residuals, and the island etag handoff as a separate timeline.

## Disposition

**RECAST to cast 3.** The findings are **convergent** — all six substantive ones point at the
same two changes (one `POST` door with a complete post-`await` check; re-assert triggered by
evidence rather than a clock) and none contradicts another. That is the signature of a design
converging, not thrashing.

Round 2 of ≤3. **Design temper only — the implementation remains UNPROVEN and a code cage-match
is owed on whatever ships.**
