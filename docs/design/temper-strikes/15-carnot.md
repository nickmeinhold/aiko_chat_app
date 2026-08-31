## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** Defect five is real, but the proposed reconciler is not yet a design; it is an intuition with the hard parts hidden in `UNKNOWN`, persistence, and ownership. No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. This is closer to the reversible process than the current repair branch, but it still creates entropy by pretending one in-memory loop can define the row's history across failures.

**Fatal flaws:**
- The reconciler's liveness claim is false as stated. `UNKNOWN` is “never equal to desired,” so a persistent offline/network/auth failure becomes an infinite retry loop unless there is an explicit backoff, suspension, wake condition, or debt handoff. Dijkstra's warning applies: correctness arguments need their invariants stated, not smuggled through prose.
- The `UNKNOWN` transition is underspecified for deletes. If `believed = UNKNOWN` and `desired = null`, what token is deleted? The loop says `DELETE(believed)`, but UNKNOWN is not a device token. If the design actually retains `lastKnownToken`, say that; if it does not, the algorithm cannot discharge sign-out after an ambiguous failure.
- The “push token is unique per install, so this install is the row's only writer” premise is too strong. Same physical install can change accounts; debug/release builds may create separate app identities; restored devices, platform token reuse edge cases, app extensions/secondary processes, and multi-device Apple ID scenarios all need explicit scoping. The usable invariant is narrower: one `DeviceRegistrar` instance per `(island, app identity, platform token)` can serialize only writes it issues while alive.
- Process death is not solved by in-memory single-flight. A write already accepted by the OS/network stack can still land after the app dies, while the next process starts from durable debt and issues new writes. The design asserts the durable debt covers this, but it only covers known unregister debt. It does not define persisted desired/believed state, nor how a prior in-flight POST is neutralized after logout.
- The design claims subtraction, but unless the reconciler absorbs `drainPending`, `_generation`, `_settling`, and the repair semantics into one explicit state machine, this is guard six with a better name. The current proposal deletes one visible pre-check and adds an implicit loop, implicit unknown state, implicit retry policy, and implicit persistence boundary.

**What holds:**
- Defect five is real and reachable in the current code. `_attemptUnregister` checks `_registered != token` before `await _api.registerDevice(...)` and never re-checks afterward. A second `unpair` during that POST can record and pay the debt, then the late POST recreates a routable row while signed out.
- The core direction is right: serializing app-side writes by desired state is simpler than independent operations repairing after themselves. Feynman's standard fits here: if you cannot explain the state transitions after every await, you do not understand the design.
- The strict-before-start `drainPending` ordering is a real load-bearing property in the current design. Deleting it casually would reintroduce the exact live-row deletion it prevents.
- Keeping credential clear independent of network completion remains correct. Awaiting the authenticated DELETE before teardown was the original waste-work generator.
- Server-side fencing remains the clean endpoint. A conditional unregister using an etag/update token would dissolve most of this client choreography.

**If RECAST, what to fold back:**
- Recast the design as an explicit persisted state machine, not prose around a loop: fields for `desiredToken`, `lastKnownToken`, `inFlightKind`, `inFlightToken`, and retry scheduling. Define what survives process death.
- Replace `believed = UNKNOWN` with concrete cases. For `POST(token)` unknown, retrying POST(token) is valid. For `DELETE(token)` unknown, retrying DELETE(token) is valid only if the credential is still available or debt-drain semantics apply. Do not store an un-actionable UNKNOWN.
- State termination honestly: the reconciler converges only under eventual successful transport/auth for the required operation and a finite number of session edges. Otherwise it must park durable debt and stop spinning.
- Preserve or subsume `drainPending` explicitly. If the reconciler owns debts, it must maintain strict delete-before-post on sign-in for owed tokens, and it must account for the store's set semantics and 16-entry eviction as a correctness degradation, not a footnote.
- Keep `_generation` unless the reconciler also owns the permission-sheet window. OS permission prompts are not island writes; a single-flight network reconciler does not automatically fence a token sampled after a session ended.
- Narrow the ownership claim: “this process serializes writes it initiates for this app identity while alive” is defensible. “This install is the row's only writer” is not strong enough for a proof without platform-specific token guarantees and lifecycle caveats.
- Best dissolution path: push the fence server-side. Conditional unregister turns stale DELETE into a server no-op and deletes the whole repair/reconciler class of problems. As Hamming would say, the purpose of computing is insight, not numbers; the insight is that ordering belongs where the row is mutated.
