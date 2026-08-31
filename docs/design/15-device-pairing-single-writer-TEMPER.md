# TEMPER.md — Device pairing: one writer, checked after the fact

**Overall verdict:** **RECAST**
**Struck:** four families, all seated — Maxwell (Claude) + Kelvin (Gemini 3 Pro) + Carnot (GPT/Codex) + Tesla (Grok). Wu (Kimi) disabled.
**Target:** `docs/design/15-device-pairing-single-writer.md`, bundled with the current
`device_registrar.dart` and `pending_unregister_store.dart` from `feat/push-pairing-wiring`
so every family could verify the design's claims about the code rather than trust them.

## Per-family verdicts

| Family | Verdict | One line |
|---|---|---|
| Maxwell (Claude) | RECAST | The option-frame is wrong: the two failure directions are not equal, and a far smaller design may dissolve the problem. |
| Kelvin (Gemini) | RECAST | Right prescription, faulty proof — the correctness argument rounds absolute zero down to a comfortable approximation. |
| Carnot (GPT) | RECAST | Defect five is real, but this is an intuition with the hard parts hidden inside `UNKNOWN`, persistence and ownership. |
| Tesla (Grok) | RECAST | The one-writer invariant dies on the exact path that produces defect five: the ordinary second sign-in, same process, first DELETE still humming. |

**Unanimous on the one thing that mattered most:** defect five is **real and reachable**, verified
independently against the source by three adversary families. It was not invented to justify a
redesign. The generator is still running.

**Also unanimous:** the design as written does not yet earn its central claim.

## Fatal flaws (deduped, most-severe first)

1. **The single-writer property is asserted, never scheduled.** — *Tesla, Maxwell, Carnot*
   `drainPending` and `_register` remain independent callers of `unregisterDevice`/`registerDevice`.
   Same process, second sign-in, first `DELETE` still in flight → two writers, same token. "There is
   never a second write in flight" describes a system that was not designed here.
   **DISPOSITION: fold.** Either every roster write goes on one chain, or the single-writer claim is
   dropped entirely. Tesla's subtraction test is adopted as the acceptance bar: *the recast is real
   only when `_attemptUnregister`'s repair, `_register`'s private POST, and the unjoined `_settling`
   are gone. If they remain beside the loop, this document is guard six and must not supersede #156.*

2. **Wrong option-frame — the two failure directions are not equal, and the simpler alternative was never priced.** — *Maxwell*
   Over-delete costs **reach** (self-healing, no disclosure). Under-delete costs a **privacy leak**
   (a stranger receives the previous owner's notifications; not recoverable). The repair branch exists
   solely to convert the safe failure back into reach, and defect five is the bill for it.
   **DISPOSITION: fold, and re-open the frame.** The recast must price `delete-the-repair-branch +
   periodic idempotent re-assertion from a live session` as the **primary** candidate, with the
   reconciler as the alternative. If the simple version holds, the reconciler is machinery this design
   should not build.

3. **The ownership claim is an assumption wearing a fact's clothes.** — *all four*
   "A push token is unique per install, so this install is the row's only writer" is a claim about one
   live Dart isolate, not about the row. Named counter-examples: already-dispatched HTTP from a dead
   incarnation; a **backup-restored debt file**; device clones; multi-account handsets.
   **DISPOSITION: fold.** Restate as an assumption with its counter-examples named, and narrow to
   Carnot's defensible form — *this process serializes the writes it initiates, while alive.*

4. **`UNKNOWN` is un-actionable for a DELETE.** — *Carnot, Tesla*
   `op = (desired == null) ? DELETE(believed) : POST(desired)` is undefined when `believed` is
   `UNKNOWN` — there is no token to delete. POST-on-unknown is a harmless upsert; DELETE-on-unknown is
   a ghost.
   **DISPOSITION: fold.** Believed becomes `lastToken | ABSENT`. No un-actionable state is stored.

5. **The convergence claim is false as stated — no termination, no backoff.** — *Carnot, Tesla*
   "`UNKNOWN` is never equal to desired, so the loop retries" is a `while(true)` against a hung or
   500ing island, and a post-logout credential that 401s hammers until the next session edge by
   coincidence.
   **DISPOSITION: fold.** State termination honestly: convergence holds only under eventual successful
   transport and a finite number of session edges. Otherwise the loop **parks the durable debt and
   stops spinning** — which is today's failure path, and it was correct.

6. **Desired state is a scalar; the ledger is a set of up to 16 with FIFO eviction.** — *Tesla, Maxwell*
   A loop whose desired state is one token cannot discharge a set. The store's eviction residual — a
   dropped debt is an island row this client can never clear — is named in the store and **unnamed in
   the design**.
   **DISPOSITION: fold.** The worklist is the set; the eviction residual is named as a correctness
   degradation, not a footnote.

7. **Keep `_generation`; the loop does not subsume it.** — *Kelvin, Carnot, Tesla* (unanimous among the adversaries)
   An OS permission sheet is not an island write. `start` cannot know the token until after
   `requestPermission()`/`currentToken()`, and that window is precisely why the fence exists.
   **DISPOSITION: fold as a ruling, not an open question.** `_generation` stays; the design must say
   the two answer different questions.

8. **Single-flight converts a straggler into unbounded queue delay.** — *Tesla*
   A hung `DELETE` delays the `POST` that restores reach, and the delay is unbounded because
   `Future.timeout` does not cancel. "The straggler disappears as a category" is an overclaim.
   **DISPOSITION: fold.** Strike the sentence; the reach residual is bounded by process death, not by
   one round trip.

9. **Root cause is a lifecycle violation, not merely a TOCTOU.** — *Kelvin*
   The repair consults state belonging to a *new* session to correct an operation issued by a session
   that is already dead.
   **DISPOSITION: fold as a sharpening** of "Defect five, stated concretely".

10. **The debt file must be excluded from iCloud / Android Auto Backup.** — *Tesla*
    A restored `aiko_pending_device_unregisters` makes this handset issue a `DELETE` for **another
    living device's** token under the same `user_id` — silently deafening a phone that did nothing
    wrong. Actionable regardless of which design wins.
    **DISPOSITION: filed separately** (claude-tasks). Not gated on this design.

## What holds

- **Defect five is real** — verified independently by three adversary families against the source.
- **The island constraints are the right cage**, verified at `a344943` rather than assumed: `(user_id, token)` matching, unconditional 204, upsert-reassigns, no fencing token anywhere.
- **The `unpair` contract is the one genuine asset five rounds bought** — durable debt awaited, credential clear immediate and unconditional, credential carried by value. Nothing here reopens it, and nothing should.
- **"Decide after the await, never before"** is the correct principle, whichever vehicle carries it.
- **The island etag handoff is correctly a separate timeline**, not a precondition. It remains the only place a stale DELETE can no-op as a fact rather than as a hope.
- **`drainPending` strictly before `start`** is genuinely load-bearing and must survive any recast.

## Disposition

**RECAST**, and specifically *not* "the reconciler with patches". Flaw 2 re-opens the frame: the next
cast must price the small candidate first — delete the repair branch, accept the safe failure
direction, and restore reach by periodic idempotent re-assertion from a live session — and adopt the
reconciler only if that fails to hold.

Round 1 of ≤3. This is a design temper only: **the implementation is UNPROVEN and a code cage-match
is still owed** on whatever ships.
