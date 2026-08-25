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
| **Artifact** | `restack-157` @ `84bc932` (= `origin/feat/apns-token-source`, restacked on #156), built **release** and installed as container `CD5764BB-5FB8-494B-A192-2FCC76C45328` on `00008120-000428CE1EB8201E`. See *Which build* below — the obvious recipe does not work. |
| **Target environment** | **`https://chat.enspyr.co`** — BOUND by direct read of the handset's own `flutter.aiko_gateway_base_url` (`tool/probe_debt.sh`), not by assumption and not by waiting for a row to move. This is the value that cost four hours on 2026-08-24. Re-read it, don't remember it. |
| **Actor** | The handset's signed-in account, whichever it is. Arm 2 is single-party; no second account is involved. |
| **Invariant** | `drainPending()` completes strictly before `start()` on every sign-in edge. |
| **Terminal observable** | `select count(*) from device_tokens` on `chat.enspyr.co`, after the final sign-in settles. **1 = correct. 0 = the bug.** |
| **Second, independent observable** | `tool/probe_debt.sh` reads the handset's OWN debt ledger. The island probe reads a CONSEQUENCE; this reads the MECHANISM. They fail differently, which is why both run. |
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

**It must be a RELEASE build, locally signed.** The obvious recipe — `flutter
build ios --debug` then `devicectl install` + `launch` — produces a process that
starts, matches its container UUID, appears in `devicectl device info processes`,
and is **not running Flutter at all**:

```
[ERROR:flutter/runtime/ptrace_check.cc(75)] Could not call ptrace(PT_TRACE_ME): Operation not permitted
Cannot create a FlutterEngine instance in debug mode without Flutter tooling or Xcode.
```

A debug iOS build cannot start its engine unless `flutter run` or Xcode is
attached. Every process-level check reads green while no Dart executes — the
claim ("the app is running") sits one layer above the thing measured ("the
binary is executing"). Verify the ENGINE:

```
flutter build ios --release
xcrun devicectl device install app --device <udid> build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device <udid> --terminate-existing cc.imagineering.aikoChatApp
# then, in a syslog capture spanning the launch:
#   ptrace / "without Flutter tooling"  ABSENT   (the debug run is the control that proves this line is visible)
#   Runner(Flutter) ... Impeller ...    PRESENT
```

Release rather than debug does not change the APNs environment. That is set by
the **entitlement** in the provisioning profile, not by the Dart build mode: a
locally-signed build carries `aps-environment: development` and therefore a
SANDBOX token, matching `APNS_USE_SANDBOX=true` on both islands. A TestFlight
build would carry a production token and silently fail to match (claude-tasks
#3386). So: build locally, never test this against a TestFlight install.

**Gate the build on the artifact's mtime, never on the exit code.** `flutter
build ios` has been observed exiting 0 while `xcodebuild` was still running,
leaving a four-day-old binary on disk that installs as a clean success.

**Do not plan on Dart log lines.** `debugPrint` does not reach
`idevicesyslog` — of 929 lines emitted by the app process during a launch, every
one came from CoreFoundation/UIKit/Flutter-engine subsystems and none from Dart.
The registrar's `unregister deferred to next sign-in` and friends are NOT
observable this way. `tool/probe_debt.sh` is the replacement, and it is better:
it reads the debt itself rather than a message about it.

---

## The sequence

Nick's hands are needed from step 3 (airplane mode, sign-out/in). Everything
else is mine.

**1. Rest reading — both islands, and the handset.**

```
./tool/probe_pairing.sh    # expect UNBOUND (both islands zero)
./tool/probe_debt.sh       # expect: signed into <island>, owed nothing
```

The must-read-zero arm, on both instruments. An unexpected row or an unexpected
debt means the sequence starts from a state this runbook did not model — stop
and find out which, rather than proceeding and attributing it later.

`probe_debt.sh` carries its own **extraction control**: every SharedPreferences
key is prefixed `flutter.` and `.` is a `plutil -extract` keypath separator, so
one missing backslash makes every lookup report a confident, plausible ABSENT.
It resolves a key known to exist before it is allowed to report absence. This
bit once already, on the very reading it exists to take.

**2. Sign in on the handset. Positive control.**

```
./tool/probe_pairing.sh
```

The island named in step 1 must go `0 → 1`. **If a DIFFERENT island moves, the
handset's stored gateway and its live session disagree** — that is a finding,
not a nuisance; stop and reconcile before continuing.

> This step is also a functional precondition, not just an instrument check.

> `unpair` writes a debt only for the token in `_registered`, and `_registered`
> is set on *confirmed* success. No confirmed register ⇒ no debt ⇒ no ordering
> to test, and Arm 2 would pass while proving nothing.

**3. Record the token prefix** printed by step 2. `ROW <user> apns 8a3f21bc…[64]`.

**4. Airplane mode ON.** Confirm no cellular and no Wi-Fi — Wi-Fi coming back on
its own is the ordinary iOS behaviour and it would let the DELETE land, quietly
converting this into a second run of Arm 1.

**5. Sign out.** The `DELETE` cannot reach the island, so `unpair` writes a
durable debt and the out-of-band attempt fails.

```
./tool/probe_debt.sh
```

The ledger must now show `https://chat.enspyr.co` owing the token from step 3.
**This is the state the whole ordering exists to handle** — if it is empty, no
debt was written and steps 6-7 test nothing.

> Background the app first (swipe up) and give it a few seconds.
> `NSUserDefaults` flushes periodically and on suspend, not on every write, so a
> read taken immediately can legitimately show the previous state — and a stale
> read is indistinguishable from "the write never happened".

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
