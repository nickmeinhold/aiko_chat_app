## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST

**Summary:** The diagnosis is a title belt and the invariant is a folding chair, but the reconciler is a championship-grade machine built to win a fight the design never established it has to have — the option-frame assumes both failure directions must be repaired, and they are not remotely equal.

**Fatal flaws:**

- **WRONG OPTION-FRAME (the illegal move, and it is the whole match).** `DESIGN.md` treats "the island holds no row when it should" and "the island holds a row when it should not" as one problem with one fix. They are not the same failure and they do not deserve the same machinery:
  - *Over-delete* → the handset loses push. **Reach degradation. Self-healing. No disclosure.**
  - *Under-delete* → the next person holding this handset receives the previous owner's notifications. **A privacy leak. Not self-healing. Not recoverable.**
  This repo's own rule is that fail-direction inverts by domain. For a roster that routes a stranger's messages to a handset, the correct bias is **fail toward deletion**. The entire repair branch exists to undo an over-delete — that is, to convert the *safe* failure back into reach at the cost of issuing a second unorderable write. Defect five is the bill for that trade. `John McClane: "Nine million terrorists in the world and I gotta kill one with feet smaller than my sister."` You built a state machine to win back the one failure you could have simply accepted.

- **A SIMPLER ALTERNATIVE DISSOLVES IT, and the design never priced it.** Delete the repair branch. Defect five ceases to exist — not "becomes unstateable", *ceases*, in one diff hunk with no new concepts. The only cost is that an over-deleted row stays deleted until something re-asserts the pairing. Then make that re-assertion **periodic and idempotent**: re-`POST` the current token on app resume / session reconcile, from a **live session**, where desired state is read at issue time and there is no dead-session write in play. `register_device` is an upsert keyed on `UNIQUE(token)` — re-asserting is free and safe by island design. That is how every roster/lease system on earth converges: not by choreographing corrections, but by periodically restating the truth from the only place that knows it. No `UNKNOWN`. No single-flight. No persisted `inFlightKind`. The straggler stops mattering because nothing is trying to *correct* it.

- **UNSTATED ASSUMPTION dressed as a verified fact.** "A push token is unique per install, so this install is the row's only writer... is a property of the domain, not an assumption." That sentence is doing load-bearing work it has not earned, and it is *my* sentence, which is exactly why it needs striking. It is a claim about one live Dart isolate, not about the row. Already-dispatched HTTP from a dead incarnation is a writer nothing in the loop can see.

- **THE SUBTRACTION IS NOT SCHEDULED, ONLY ASSERTED.** `DESIGN.md` claims "there is never a second write in flight" while leaving `drainPending` and `_register` as independent callers of `unregisterDevice`/`registerDevice`. Same process, same token, second sign-in, first `DELETE` still humming — two writers. The claim is a property of a system that was described but not designed. Until `drainPending`'s set-valued worklist and `_register`'s private POST are *on the chain*, this is guard six with better prose.

- **The ledger is a SET; desired state is a SCALAR.** `_registered` holds one token; `PendingUnregisterStore` holds up to 16 per island because rotation plus offline sign-outs leaves multiple live rows. A loop whose desired state is one token structurally cannot discharge a set. The design does not mention this and the mismatch is exactly where a "converges" proof goes to die.

**What holds:**

- Defect five is real, reachable, and correctly diagnosed as a check sampled before its own `await`. Three adversary families verified it against the source independently.
- The island facts are verified rather than assumed — no fence, unconditional 204, upsert-reassigns — and they are the right constraints to design inside.
- The `unpair` contract (durable debt awaited, credential clear immediate and unconditional, credential carried by value) is the one genuine asset five rounds produced. Nothing here reopens it.
- "Decide after the await, never before" is the correct principle even if the reconciler is the wrong vehicle for it.
- Refusing to make the island etag a precondition is right. It is the only place a stale DELETE can no-op as a *fact*.

**If RECAST, what to fold back:**

- **Lead with the asymmetry.** Add a section stating the two failure directions and their unequal costs, and make "fail toward deletion" the design's governing principle. Every mechanism below it is then judged on whether it buys reach without risking a leak.
- **Demote the reconciler to the alternative, and evaluate `delete-the-repair + periodic idempotent re-assertion` as the primary.** Price both honestly: the simple version costs bounded deafness between re-assertions; the reconciler costs a persisted state machine, a retry policy, and a set/scalar reconciliation. If the simple version holds, the reconciler is machinery this design should not build.
- **Restate the invariant as an assumption with named counter-examples** — dead-incarnation writes in flight, and a backup-restored debt file.
- **Either put every roster write on one chain, or drop the single-writer claim entirely.** No middle position is honest.
