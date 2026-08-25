# Arm 2 — the offline sign-out, live

The last unproven half of PR #156's teardown ordering, and the first probe run
through a written probe contract (claude-tasks #8).

Arm 1 passed on 2026-08-24: an **online** sign-out issued `DELETE /v1/devices`,
got `204`, the island's row count went `1 → 0`, and the debt store was correctly
left empty. That proves the happy path and nothing about the mechanism, because
when the DELETE lands there is no debt and therefore no ordering to get wrong.

Arm 2 forces the DELETE to fail. That is the only way a durable debt exists at
the next sign-in, and the ordering of `drainPending()` against `start()` is the
whole safety argument for paying an old session's debt under a new session's
credential (`e5d7c01`, defended across four cage-match rounds).

**It is worth running because its unit test was VOID two independent ways**
(found in round 9.9, fixed in `cbba812`): the fixture used `tok-owed` and
`tok-1`, two strings that cannot collide, so the bug was unrepresentable; and
`FakeRestApi.unregisterDevice` recorded the call but never removed the
registration, so the fake was more forgiving than the island. Both are fixed and
the new test is RED-proven — but the test and the fix were authored by the same
instance in the same session. **Arm 2 is the independent look.**

---

## Probe contract

Filled in before the probe runs, not after. Any field that cannot be filled is a
reason to stop, not a caveat to note.

| Field | Value |
|---|---|
| **Artifact** | `restack-157` @ `84bc932` (= `origin/feat/apns-token-source`, restacked on #156). A debug build — see *Which build* below. |
| **Target environment** | **Deliberately unbound.** Resolved by observation in step 2, not asserted here. |
| **Actor** | The handset's signed-in account, whichever it is. Arm 2 is single-party; no second account is involved. |
| **Invariant** | `drainPending()` completes strictly before `start()` on every sign-in edge. |
| **Terminal observable** | `select count(*) from device_tokens` on the island the app is signed into, after the final sign-in settles. **1 = correct. 0 = the bug.** |
| **Positive control** | Step 2. A row must be seen to APPEAR before anything is torn down. |
| **Negative control (must-read-zero)** | Step 1. Both islands read zero at rest. |
| **Negative control (forces the bug)** | `tool/probes/arm2-reverse-order.patch` — step 8. |
| **Data freshness** | Every reading is a fact about the moment it was taken. The probe stamps each with a wall-clock time; re-read rather than reason from an earlier line. |
| **Permitted conclusion** | Only about **this** ordering on **this** platform's token behaviour. It says nothing about Android, nothing about a token that rotates across the sequence, and nothing about the multi-debt (set-valued ledger) path. |

### What this probe cannot see

- **Which island the app is pointed at**, until a row moves. That is device
  state; the probe queries both islands so a wrong guess becomes a visible
  reading rather than four silent hours.
- **Whether the DELETE was issued and lost.** The island answers `204` either
  way and offers no fencing token. The probe reads rows, never intentions.
- **The ORDER itself.** It reads the order's *consequence*. That is precisely
  why step 8 exists: an observable that cannot distinguish the bug is not
  evidence, and a run without step 8 is a green with no red behind it.

---

## Which build, and why it matters

`APNS_USE_SANDBOX=true` on **both** islands (verified 2026-08-25). A dev build's
token is valid only against sandbox and a TestFlight token only against prod,
and the two strings are indistinguishable — so today only a **debug build** can
ring (claude-tasks #3386).

Arm 2 does not need a push to be *delivered*; it counts rows. But use the debug
build anyway: it is the artifact the fix will ship in, and mixing build types
here reintroduces the exact class of ambiguity the contract exists to remove.

---

## The sequence

Nick's hands are needed from step 3 (airplane mode, sign-out/in). Everything
else is mine.

**1. Rest reading — both islands.**

```
./tool/probe_pairing.sh
```

Expect `UNBOUND` (both zero). This is the must-read-zero arm. If a row is
already present, stop and find out whose it is before continuing — an unexpected
row means the sequence starts from a state this runbook did not model.

**2. Sign in on the handset. Positive control + target binding, in one act.**

```
./tool/probe_pairing.sh
```

Exactly one island's count must go `0 → 1`. **That island is the target** for
every later reading; write it down. The probe is now bound, and it has been
shown to read non-zero.

> This step is also a functional precondition, not just an instrument check.
> `unpair` writes a debt only for the token in `_registered`, and `_registered`
> is set on *confirmed* success. No confirmed register ⇒ no debt ⇒ no ordering
> to test, and Arm 2 would pass while proving nothing.

**3. Record the token prefix** printed by step 2. `ROW <user> apns 8a3f21bc…[64]`.

**4. Airplane mode ON.** Confirm no cellular and no Wi-Fi — Wi-Fi coming back on
its own is the ordinary iOS behaviour and it would let the DELETE land, quietly
converting this into a second run of Arm 1.

**5. Sign out.** The `DELETE` cannot reach the island, so `unpair` writes a
durable debt and the out-of-band attempt fails. Nothing is observable from
outside yet; the island still holds the row.

**6. Airplane mode OFF.** Wait for the network. Do **not** sign in yet.

```
./tool/probe_pairing.sh
```

The row must still be there — count still 1. A drop to 0 here means something
paid the debt outside the sign-in edge, and the ordering under test never runs.

**7. Sign in again. Read the terminal observable.**

```
./tool/probe_pairing.sh
```

- **1 row, and the token prefix MATCHES step 3** → the ordering holds. Arm 2 passes.
- **0 rows** → the bug. `drainPending` ran after `start` and deleted the live pairing.
- **1 row, prefix DIFFERS from step 3** → **VOID, not a pass.** The platform
  reissued the token across the sequence, so the debt's token and the new
  registration cannot collide, and the bug was unrepresentable. This is the
  *same* defect that made the unit test void — two strings that cannot collide.
  Do not record a pass. Re-run.

**8. The red arm. Do not skip it.**

```
git apply tool/probes/arm2-reverse-order.patch
# rebuild, reinstall, repeat steps 1-7
```

Step 7 must now read **0 rows**. If it reads 1, the observable does not
distinguish the bug and the green in step 7 was worth nothing. Restore with
`git checkout lib/features/notifications/application/push_providers.dart`.

---

## Afterwards

- A pass either becomes a regression test or is explicitly recorded as future
  work on #156 — not left implicit.
- The island tab offered to watch the row transition from its side. **Coordinate
  by a comment on the claude-tasks issue, not `SendMessage`** — four of four
  sends expired undelivered on 2026-08-24.
- Whatever the contract table above got wrong is the real output of this run.
  #8 is the contract's home; this file is its first use.
