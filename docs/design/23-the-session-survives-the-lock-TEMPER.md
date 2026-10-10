# TEMPER.md — Design 23, the session survives the lock

**Overall verdict:** RECAST (4 of 4 families, no DISSOLVE)
**Struck:** dt-1791559532, families seated: Maxwell + Kelvin (gemini-2.5-pro) + Carnot (gpt-5.5, medium) + Tesla (Grok)  (Wu disabled)

## Per-family verdicts
| Family | Verdict | One-line |
|--------|---------|----------|
| Maxwell (Claude) | RECAST | Freshness is read at the wrong instant; measuring at native push receipt may dissolve the at-rest trade |
| Kelvin (Gemini)  | RECAST | The bearer token's power is unaudited, and delete-then-add migration is brittle; require an atomic migration |
| Carnot (GPT)     | RECAST | Token readability is necessary, not sufficient; specify the locked-call state machine, refresh under lock, pair atomicity and rollback |
| Tesla (Grok)     | RECAST | `delete` ignores accessibility, so every save becomes delete-then-add; migrate to new account names instead |

## Fatal flaws (deduped, most-severe first)
1. **The migration as written turns every token save into a non-atomic delete-then-add, and can split the pair.** (Tesla, Carnot, Kelvin; *verified*: `performDelete` sets `accessibilityLevel = nil`, so `delete(legacy)` also removes the migrated item.) The island rotates the refresh token before the phone persists it, so jetsam between delete and add loses the session, on any refresh, not once. The two tokens migrate independently, so a mixed state reads as signed out while a live refresh token remains. — DISPOSITION: fold. Write the pair as **one serialized value under a NEW account name** born at `first_unlock_this_device` (Tesla's new-names idea plus Carnot's pair atomicity). Read new first. Copy forward from legacy only while unlocked. Delete legacy only after the new item reads back. The steady state never calls `delete` (the plugin's `SecItemUpdate` of `kSecValueData` handles rewrites). No collision, no shim, no pair split.
2. **Wrong option-frame: an alternative may dissolve the at-rest trade.** (Maxwell; Carnot's call-scoped admission credential is the same family.) Measuring invite freshness against a native-recorded push-receipt time for exactly this `CallRef` passes runs 1 and 4 with tokens left at `WhenUnlocked`, and replay stays closed because an old `signed_at` still fails. The doc filed this as a companion, not an alternative. — DISPOSITION: fold an **Alternatives** section weighing A (`first_unlock` tokens) against B (receipt-time freshness), and surface the **product decision** that chooses between them: does iOS connect *before* Face ID (A), or after it, as Android already does with `requestDismissKeyguard` (B suffices)? **Nick's call.**
3. **The bearer token's power is assumed, not audited.** (Kelvin, Carnot, Tesla, Maxwell.) An AFU refresh token can mint a video token, join a live call, read history, and rotate the phone's own session away. Which surfaces render bearer-only actions as authoritative without the sovereign signature is unverified. — DISPOSITION: fold an enumerated table (send, react, call invite, admit, media mint, key upload, device and session revoke) saying which are signature-gated, and price the trade on that basis.
4. **The locked-read status contract is wrong in the doc.** (Maxwell, Tesla; *verified*: a locked read returns `errSecInteractionNotAllowed`, which the plugin raises as a `FlutterError`, so Dart throws.) The pseudocode and unit test 4 assume null. Flattening it to null anywhere risks `SovereignKeyStore` minting a new identity. — DISPOSITION: fold. `errSecItemNotFound` means absent; −25308 means "signed out for this wake: no delete, no refresh, no mint". The fake must model both statuses.
5. **The end-to-end locked-call path is unspecified.** (Carnot; Maxwell on the 30 s CallKit audio lease.) Covers answer-before-auth, refresh under lock (single-flight?), invite fetch, admission, video mint, and expiry, against the lease and the freshness window as one composed budget. — DISPOSITION: fold a state table and timing budget.
6. **First call after update, before the app has been opened unlocked, still fails.** (Carnot.) — DISPOSITION: fold. Migrate on any unlocked foreground. Name the residual window and test it explicitly.
7. **No rollback.** (Carnot.) — DISPOSITION: fold forward and backward behaviour (new names make rollback a read of the legacy account, if it is kept until a later release).
8. **Proof of the class change.** (Tesla.) — DISPOSITION: fold. Read `kSecAttrAccessible` back with `kSecReturnAttributes` in the hardware test.

## What holds
- The four-run diagnosis (run 3 against run 4) isolates keychain readability. All four families accept it.
- The split: the sovereign key stays class A, and only revocable credentials can step down.
- `_this_device` over plain `first_unlock` for a bearer token.
- macOS and Android are rightly left alone. Before the first unlock after boot, no class can ring; name it as physics.

## Disposition
RECAST. Fold 1 and 3–8 into DESIGN v2, and put flaw 2's A-vs-B choice to Nick first, because it decides whether v2 changes keychain classes at all. Re-strike v2 (round 2 of ≤3).


## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST

**Summary:** The diagnosis is right and the migration trap is a real catch, but the design weakens at-rest protection to fix what is really a clock read at the wrong moment. Measure freshness at push receipt, and the keychain trade may not be needed at all.

**Fatal flaws:**
- **Wrong option-frame (the illegal move).** The defect is "the invite is judged at *Dart-admit time*, which on a locked phone means after Face ID". The design treats that instant as fixed and moves the *credentials* to make Dart-admit happen sooner. But the native side receives the VoIP push about 1 s after persist, in every run (0.35–0.98 s) and in every lock state, with no keychain involved. If freshness compared `signed_at` against a native-recorded **push-receipt timestamp for exactly this CallRef**, rather than against `now()` when Dart finally gets there, then runs 1 and 4 would pass with the tokens left at `WhenUnlocked`. Replay stays closed: an old signed invite pushed again carries an old `signed_at`, and a fresh receipt time cannot launder an old signature. This is claude-tasks#4233's "native session proves timeliness" idea, made concrete. The doc lists it under "Not in scope" as a *companion*, when it may be the *alternative* that dissolves the at-rest trade. The doc must weigh the two head to head.
- **Unstated assumption: that connecting on the lock screen is the goal.** With `first_unlock`, Dart could authenticate and join *before* Face ID. Android deliberately does the opposite: `IncomingCallActivity.answer()` requires `requestDismissKeyguard` before joining. The doc does not say whether iOS should join pre-unlock (better UX, weaker at rest) or match Android's unlock-first (a receipt-time fix is enough, and nothing is traded). That product call is what decides between the two options, and it is missing.
- **Migration pseudocode is wrong about the locked read.** "read(legacy options) fails while locked; that's fine" implies it returns null. It does not. `SecItemCopyMatching` returns `errSecInteractionNotAllowed`, and the plugin turns any non-success, non-not-found status into a `FlutterError`, so Dart **throws**. The pseudocode must catch exactly that code (−25308) and treat it as "migration deferred". It must not catch broadly, or a real keychain failure would be swallowed as "no legacy item". (Today's restore path already treats a throw as transient, not as a logout: `token_provider.dart` clears only on `RefreshRejected`, and `auth_controller.dart:599` documents the locked throw. So the outcome is safe, but the doc's stated mechanism is false.)
- **Under-counted: the 30 s CallKit audio lease.** Under either fix, if Face ID or the join takes longer than the armed audio lease (30 s, `disarm` at +30 s in runs 1 and 4), the call dies anyway. The doc does not say what the post-fix join path's timing budget is against that lease.

**What holds:**
- The four-run isolation (run 3 against run 4) is clean evidence that keychain readability is the variable.
- Keeping the sovereign key at `WhenUnlocked`, and only revocable credentials ever weaker, is the right split if a trade is made.
- `_this_device` over plain `first_unlock` is correct for a bearer token.
- The plugin trap (accessibility in the lookup query, so `errSecDuplicateItem` on write) is real and well specified, and it is what would have caused a silent logout during a refresh.

**If RECAST, what to fold back:**
- Add an "Alternatives" section that weighs **(A) `first_unlock_this_device`** against **(B) freshness measured at native push receipt**, on the same axes: at-rest cost, pre-unlock connect, wire change (none for B: `m` already identifies the call), replay resistance, and Android parity.
- State the product decision explicitly: does iOS connect before unlock, or after (as Android does)? If after, B alone suffices and A is unnecessary.
- Fix the migration pseudocode: catch `errSecInteractionNotAllowed` specifically, and say what each other error does.
- Give the join-timing budget against the 30 s CallKit audio lease, and say whether the lease must stretch to cover unlock.


## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** no real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. The core diagnosis is likely right: `WhenUnlocked` tokens make the locked PushKit path thermodynamically impossible, and moving only revocable session credentials to `AfterFirstUnlockThisDeviceOnly` is the right direction. But the design is not yet reversible enough: it frames the keychain class change as the fix while under-specifying the actual call-answer state machine, token-refresh coupling, and migration atomicity. Dijkstra: "Simplicity is prerequisite for reliability." The fold-back is: separate `locked-call admission` from `general session persistence`, define a minimal pre-answer auth path with explicit refresh/no-refresh behavior, and make migration either native/atomic or deliberately unlocked-only before relying on it.

**Fatal flaws:**
- The design proves token readability is necessary, not sufficient. It assumes that once `/v1/me` and invite fetch happen within 1-2s, answer will join. The measured defect includes CallKit answer timing, Dart startup, websocket/REST admission, token refresh, video-token minting, and invite freshness. The design fixes one entropy source but does not define the end-to-end state machine for answer-before-auth, auth-before-answer, and answer-after-expiry.
- The wrong coupling is being preserved: a locked incoming call still depends on the full durable session token pair. The simpler dissolving alternative is a call-scoped, PushKit-delivered or server-mintable admission credential with a narrow audience and TTL, so the locked path does not need the refresh token at all. That may be more work server-side, but it deletes the worst trade: exposing standing refresh credentials in AFU just to answer a transient call.
- Refresh-token behavior is under-specified and high blast-radius. If the access token is expired during a locked wake, the app may need the refresh token while locked. The doc accepts AFU exposure for refresh, but does not specify whether refresh is allowed during CallKit wake, whether rotation is atomic, what happens on partial write of access vs refresh, or how concurrent REST/WSS refresh attempts are serialized.
- Migration has a dangerous partial-pair failure mode. `read()` reads access then refresh independently. If one item migrates and the other fails, crashes, or is deleted, the store returns null and may strand a half-migrated pair. The design discusses delete-then-add per item but not pair-level invariants. Credentials are a thermodynamic working fluid: leak one side of the cycle and the engine stops.
- The doc's plugin premise is partly stale against the bundled source. `delete()` already clears accessibility constraints inside `performDelete`, so the proposed `delete(legacy options)` mental model does not match the actual plugin behavior. Conversely, `containsKey()` still queries with accessibility through `baseQuery`, so write collision analysis remains plausible. This mismatch needs exact implementation-level confirmation before build.
- The security trade is too qualitative for a trust-boundary change. 'Attacker who can run code as the app or extract the keychain' hides very different capabilities: jailbreak with AFU keybag access, app process compromise, backup restore, MDM/forensics, and stolen device after reboot. The design needs an explicit threat table for access token, refresh token, sovereign key, message history, and session revocation latency.
- The claim that stolen-session sends cannot create verified-looking messages is an unverified assumption and may be fatal. If any chat surface, reaction path, call signaling path, or fallback renderer treats authenticated server-originated content as acceptable without sovereign signature enforcement, then moving the refresh token to AFU expands from 'read account messages' to impersonation or social attack.
- The first-call-after-update failure is waved away as 'normal path'. For a call feature, update-then-background is not exotic. If 0.0.6 blocks on iOS, the very population needing the fix may install and later receive a locked call before opening the app. That is an expected failure mode, not an edge case.
- Freshness is declared out of scope too aggressively. The defect is produced by the composition of auth latency and `kCallInviteFreshness`. Even after AFU, APNs delivery, cold Dart startup, refresh rotation, and server latency can exceed 10s. Feynman: "What I cannot create, I do not understand." If the design cannot recreate all slow-path clocks, it cannot prove freshness is no longer binding.
- No rollback plan is specified. Once tokens are migrated to `AfterFirstUnlockThisDeviceOnly`, reverting the app or changing policy back to `WhenUnlockedThisDeviceOnly` faces the same query/accessibility trap. A trust-boundary migration needs forward and backward behavior, including sign-out semantics.

**What holds:**
- The measured evidence is strong: foreground and post-lock grace succeed; long-locked cold wake waits for Face ID and misses the 10s freshness gate. That isolates keychain availability as a real blocker.
- The split between session token and sovereign signing key is the right design instinct. Revocable bearer credentials and non-revocable author keys should not share a protection class. Hamming: "The purpose of computing is insight, not numbers." This split is actual insight, not numerology.
- `AfterFirstUnlockThisDeviceOnly` is a coherent iOS class for background-readable, non-migrating secrets. The `_this_device` choice correctly avoids encrypted-backup session transplantation.
- The migration trap around accessibility being included in plugin queries is real enough to design around. The doc correctly notices that naive option switching can turn reads into misses and writes into duplicate-item failures.
- The test plan includes the right kind of hardware test, including the nasty 'answer, wait, then Face ID' case. That is the irreversibility test: can the engine do useful work before the user unlocks?
- Keeping macOS and Android out of scope is reasonable if the platform paths truly differ as stated. Avoiding cross-platform churn is good entropy management.

**If RECAST, what to fold back:**
- Recast the decision as two layers: `minimum viable fix for 0.0.6` and `desired architecture`. For 0.0.6, AFU session tokens may be acceptable. For the architecture, define a call-scoped admission token that avoids refresh-token readability while locked.
- Specify the locked-call state machine with concrete states and invariants: push received, native ring shown, Dart restored, token read, optional refresh, invite fetched, invite admitted, answer observed, video token minted, join attempted, expiry handled. Include what happens when answer arrives before each state.
- Define refresh rules under lock. Either forbid refresh during locked call wake and require valid access token, or allow it with single-flight rotation and atomic persistence. Do not leave this to the auth interceptor by accident.
- Make token persistence pair-atomic at the application layer. Store the JWT pair as one serialized keychain value, or introduce a versioned envelope so access/refresh cannot migrate independently. This also reduces duplicate migration code and wasted query work.
- Prefer a tiny native shim for `SecItemUpdate` of accessibility if schedule allows. If not, explicitly accept unlocked-only migration and gate it: on app launch while unlocked, migrate immediately and record success; do not rely on opportunistic migration during a call wake.
- Correct the plugin analysis against the actual bundled implementation: deletes ignore accessibility, reads and contains checks do not. The design should name exact plugin methods and expected OSStatus outcomes for read, contains, update, add, and delete while locked.
- Add a security matrix: attacker capability vs obtainable artifact vs consequence vs mitigation. Include revocation latency, signed-message enforcement, call signaling, message read access, and backup/restore behavior.
- Verify every unsigned or server-authenticated send surface before merge. If any user-visible message/reaction/call action can appear authoritative without the sovereign key, either fix that first or narrow the AFU token's scope.
- Add an update-path test where the app is upgraded but not opened unlocked before the first incoming call. Decide whether the user-facing failure is acceptable, mitigated by launch migration, or requires a compatibility shim.
- Keep freshness in the design as a composed invariant: `push latency + process wake + token read/refresh + invite fetch + admission < freshness`. If the native answered-call proof is the real future invariant, say exactly when it replaces the 10s gate. The second law says entropy wins when clocks are hand-waved.



Ripgrep is not available. Falling back to GrepTool.
## KelvinBitBrawler's Design Strike

**Verdict:** RECAST

**Summary:** The design correctly identifies a thermal barrier to liveness but proposes a solution that rests on absolute zero diligence and a migration path with the structural integrity of thin ice.

**Fatal flaws:**
- **Class: Unverified Assumption.** The entire security trade-off (`What this trades`) is founded on the hope that a stolen refresh token is a low-value asset. The design admits it has not verified this, stating it as an **assumption** that a stolen token cannot be used to sign messages and that unsigned messages are clearly marked. `Frank Herbert: "The mystery of life isn't a problem to solve, but a reality to experience."` This is not a mystery to experience; it is a threat model to be calculated. The blast radius of a compromised bearer token is an unmeasured variable. Without a complete audit of every action a bearer token permits via the API, the trade of confidentiality for liveness is a blind one. This is not design; it is a prayer to a cold and indifferent universe.
- **Class: Brittle Design.** The migration plan (`Migration: the trap in the plugin`) is a textbook example of a cold fault. By accepting the `flutter_secure_storage` plugin's limitations, it recommends a non-atomic `delete-then-add` sequence for migration. This creates a critical window for irreversible data loss—the session tokens—if the process terminates between the two operations. The design notes this ("a crash between the two loses the session") but dismisses the risk as a one-time event with a low-impact failure mode ("a sign-in"). This is a failure of imagination. The risk is present on *every single token refresh* until the migration completes for that user, and a forced sign-out is a sharp edge for the user. `Roy Batty: "The light that burns twice as bright burns half as long."` This design's convenience burns bright, but its robustness is fleeting. Choosing to defer a native shim is prioritizing short-term ease over long-term system stability.

**What holds:**
- The diagnosis of the defect is crystalline and correct. The `kCallInviteFreshness` window is a red herring; the true bottleneck is keychain accessibility in a locked state.
- The decision to change the iOS session tokens to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is the proper thermodynamic state for this feature to function.
- The architectural split between the revocable session credential and the non-revocable sovereign signing key is sound. The thermal isolation is correct; `SovereignKeyStore` must remain at its higher potential energy.

**If RECAST, what to fold back:**
- In **`What this trades`**: The section must be rewritten. The assumption regarding the limited power of a bearer token must be replaced with a rigorous audit of the API. Enumerate every possible authenticated action—read, write, delete, configure—and state definitively which are firewalled by sovereign key signing and which are not. The risk must be quantified, not qualified.
- In **`Migration: the trap in the plugin`**: The recommendation to "accept the gap for v1" must be struck from the record and replaced with a mandate for a robust, atomic migration. The design must specify the following:
  > A small, targeted native shim **is required** to bridge the limitations of the current plugin. This shim will expose a function to atomically update the `kSecAttrAccessible` attribute of an existing keychain item using `SecItemUpdate`. The brittle 'delete-then-add' strategy is rejected.
  The migration logic in the design must then be redefined to use this atomic update, eliminating the data loss window entirely. The failure mode of a sign-in is not an acceptable cost of doing business. We are building a foundation, not a frost heave.


## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** The accessibility step-down is the true frequency of the missed call, but the migration is scored in delete-then-add and treats a keychain error as silence, so the refresh that joins the call is the same gesture that drops the session.

Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration."

**Fatal flaws:**

- **The locked-legacy proof is tuned to a chord `read` does not play.** In `FlutterSecureStorage.read`, only `errSecItemNotFound` is rewritten to `(status: errSecSuccess, value: nil)`. A class-A item touched while the class key is gone returns the raw status (`errSecInteractionNotAllowed`) and a nil value. The migration section "Migration: the trap in the plugin" says a locked legacy `read()` returns null, the ring stays signed-out, nothing is deleted, and no refresh runs. Unit test 4 teaches the fake the same null. On a cold PushKit wake the real status is an error. Thrown, it lands in session restore while the native call is already up. Caught and flattened to null, it is the same null `SovereignKeyStore._loadOrCreate` already treats as "no seed, mint a new self." The two stores share that mapping even though their classes differ. The design's split holds only while absence and lock-failure stay different notes.

- **`write()` as specified moves the "one-time microsecond gap" onto every refresh.** `performDelete` sets `accessibilityLevel = nil` and deletes by account and service, both synchronizable bits. `delete(legacy options)` therefore deletes whatever item wears that account, including a token that already sits at `AfterFirstUnlockThisDeviceOnly`. After migration, every persist is delete-then-add. The island rotates the refresh token before the phone writes it. This design says so, and runs 1 and 4 already showed the rotation. Jetsam between those two calls, the ordinary death of a PushKit process, leaves the new refresh token nowhere. There are two accounts, `aiko_access_token` and `aiko_refresh_token`, written one after the other, and `SecureTokenStore.read` demands both. The pseudocode migrates a single `t`. One key on the new class and one still class A looks like signed-out, while a live refresh token remains in the keychain. The next accessibility-blind delete is what finishes it. The pseudocode also returns `t` with no check on the delete or the write, so a failed persist still hands the caller a session it just erased.

- **"What this trades" prices a house key as a library card.** An AFU refresh token can mint the video token, join the live call, read history, and burn the phone's own session by rotating first from anywhere else. The sovereign seed staying `WhenUnlocked` keeps signed-at-birth payloads unverified only on surfaces that actually verify. The design leaves that as an assumption for the temper and does not list the bearer-only actions: send, react, invite, admit, media mint, key upload, device list, revoke-other-sessions. Those speak as the user until revocation. The seizure case is the blast they counted. The standing one is quieter: once the class key survives lock, every later background wake decrypts the long-lived bearer into the Dart heap with no one present. Class A was the coupling between use of the credential and a person here. This step-down cuts it for the life of the boot.

**What holds:**

- The measurement holds. Runs 3 and 4 isolate `kSecAttrAccessibleWhenUnlocked` as the binding constraint, and an unbounded Face ID wait cannot be tuned out of `kCallInviteFreshness`. `AfterFirstUnlockThisDeviceOnly` matches a PushKit process, and run 3 is the steady state once the item is actually in that class.
- The cut holds. Admit and join need the bearer. Verifying the caller uses their public key. `SovereignKeyStore` staying class A is the right split, as long as a locked read stays an error and never becomes a mint.
- `ThisDeviceOnly` holds. A refresh token restored from backup onto another phone is a session that moved without a sign-in. A fresh sign-in is the same price passkey re-binding already charges. macOS and Android are correctly left alone.
- Before first unlock after boot, this class cannot ring. The design already says so. That residual is physics, and it should stay named so the next locked failure is not mistaken for a regression of this fix.

**If RECAST, what to fold back:**

- Replace the same-account delete-then-add in DESIGN.md with new account names. Leave `aiko_access_token` and `aiko_refresh_token` as legacy. Be born at `first_unlock_this_device` under new names. Read the new names first. Copy forward only on a true not-found while unlocked. Delete legacy only after the new items read back. A crash leaves the legacy pair in place. Steady-state `write` and refresh touch only the new names, via the plugin's existing `SecItemUpdate` of `kSecValueData`, and never call `delete`. That removes the duplicate-item collision `baseQuery` creates, and it removes the shim debate.
- Write the status contract into the migration section. `errSecItemNotFound` means absent. `errSecInteractionNotAllowed` means signed out for this wake: do not delete, do not refresh, do not mint. Point the unit test at those two statuses. State that `SovereignKeyStore` must keep receiving the error on a locked class-A read.
- Migrate per key. A mixed-class pair is a recoverable state. `read()` returning null for the whole pair is what invites the clobbering write.
- Replace the temper assumption with an enumerated bearer-versus-signature list covering message send, reaction, call invite, admit, media-token mint, device and session revoke, and key upload. Price the trade as live-call join, impersonation on bearer-only surfaces, and refresh rotation that can kick the phone, alongside history read.
- Keep hardware tests 1 and 2, lock past the grace period. Change test 3 to assert the interaction-not-allowed status and an untouched legacy item. After migration, read `kSecAttrAccessible` back with `kSecReturnAttributes` so a joined call is not the only proof the class changed.


---

# Round 2 — v2 (an answered ring is judged by when it rang)

**Overall verdict:** RECAST (4 of 4, no DISSOLVE). All four accept the reframe: judging freshness at native receipt dissolves every v1 keychain hazard.
**Struck:** dt-1791594945, families seated: Maxwell + Kelvin (gemini-2.5-pro) + Carnot (gpt-5.5) + Tesla (Grok)

## Fatal flaws (deduped, most-severe first) → fold into v3
1. **The receipt and the invite race** (Maxwell, Tesla). The receipt rides bridge events (replayed at `onListen`); the invite arrives by REST; nothing orders them. If the fetch wins, `admitRing` falls back to `now`, refuses `stale`, and never re-enters. That is the original bug, now intermittent. → **Query, don't copy:** `RingController` awaits a native `wakeAge(callRef)` over the control channel before calling `admitRing` (which stays pure). Native already holds the live record when Dart admits.
2. **Clock domains; the "receipt ≤ now" lemma is false** (Tesla, Carnot). `signedAt` is the caller's wall clock, native `at` is the device wall clock (iOS freezes it; Android re-projects `elapsedRealtime` at emit), and `now` is Dart's. → **Native returns a monotonic DURATION since the wake** (iOS `ProcessInfo.systemUptime`/`clock_gettime(CLOCK_MONOTONIC)` stamped at wake; Android `elapsedRealtime`), and Dart computes `receivedAt = now − wakeAge`. One clock (Dart's `now`) on our side, so `receivedAt ≤ now` holds by construction and native wall-clock steps drop out. Across a reboot the monotonic clock resets, but so does the record, so there is nothing to compare.
3. **#220 is the safety proof, not a prerequisite; the 60 s horizon is an invented constant** (Carnot, Kelvin, Tesla). → **Trust the wake only while the native call is actionable**: ringing, or answered and not ended or joined, as the native side itself defines it, with a dedicated `wokeAt` set once by the wake handler (never by duplicate, displacement or Dart-report paths). #220's stale-record fix ships in the same change, and the replay test covers *old invite plus old same-call record present*.
4. **The 30.0 s teardown after Answer must be pinned** (Kelvin, Carnot, Tesla). It is now the product's binding constraint, and naming it does not close it. → Trace it before v3 (island ring ceiling as an end wake, or an app-side expiry), and put the composed budget (Answer → Face ID → join versus that timer) in the doc, with a hardware case that strikes it (answer at ~20 s, unlock at ~25 s).
5. **Admission order and call scope** (Carnot). The receipt query needs the signed `CallRef`, so parse it after `originCryptoValid` and reject missing or malformed calls before the lookup. The native records are channel-keyed with `call` as a value, so the lookup must be by `CallRef` and must prove that overlap, replacement and duplicate paths cannot return another call's wake.
6. **END composition** (Carnot). A prompt wake must not admit a call whose end already raced in by another path: check the pending-END buffer and native retirement before trusting the wake.

## Disposition
RECAST. Pin the 30 s timer (flaw 4) and read #220's record lifecycle, then write v3 and run round 3 (the last of ≤3).

## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST

**Summary:** The reframe is right, and it dissolves every v1 keychain hazard. But v2 assumes the receipt time is already in Dart's hands when admission runs. On a cold start the receipt (bridge events) and the invite (a REST fetch) race, and if the fetch wins, the stale refusal is final.

**Fatal flaws:**
- **Ordering race (missing failure mode).** `RingController` admits from messages as they arrive (`admitRing(..., now: now)` then telemetry and `return` on refusal). The receipt arrives on the bridge EventChannel, replayed at `onListen`. Nothing orders "bridge listener attached and pending replayed" before "first message fetch". In run 1 the first REST traffic and the websocket both came within about 2 s of unlock. If the invite is admitted before the receipt map is populated, it falls back to `now`, is refused as `stale`, and the refusal is terminal: the doc defines no re-evaluation. That reproduces the original bug intermittently, which is worse than reproducing it deterministically. Fold: either (a) admission **asks** native for the receipt (`receivedAt(callRef)` over the control MethodChannel, awaited before `admitRing`, which is sync), or (b) a stale refusal for an invite whose `CallRef` later receives a receipt within the horizon is re-admitted. (a) is simpler and removes the race, rather than guarding it.
- **Receipt provenance is under-specified (unstated assumption).** "Only the wake handler writes it" must be a rule in code, not a description. On iOS the same persisted record map (`stored()`, `entry.at`) may also be written when Dart reports a ring it admitted in-app, or re-stamped on a duplicate push ("duplicate invite for a ring already live", seen in the 2026-10-09 logs). If any non-wake path creates or refreshes `at`, `receivedAt` stops meaning "the wake arrived". Fold: stamp a dedicated `wokeAt` field, set once by the push handler, never overwritten by duplicates, displacements or Dart reports. Admission uses `wokeAt` only.
- **The call-id match must be against the signed body, at the moment of the query.** The doc says so in prose. With option (a) this becomes `receivedAt(callRef)` keyed by the `CallRef` parsed from the *verified* body, which also makes "names a different call id" structurally impossible rather than checked.
- **Horizon vs answered state.** An answered record's receipt is honoured only while `now − wokeAt ≤ 60 s`. A user who answers at +25 s and takes 40 s to Face ID is refused, even though the call (if the 30 s teardown is extended later) might live. That is acceptable and should be stated as the coupling: the horizon must be at least the ring ceiling plus the answered-but-unjoined lifetime, so if one grows, the other must.

**What holds:**
- The reframe: judging freshness at native receipt removes the keychain trade, the migration, the pair-atomicity hazard and the rollback problem in one move. It is the "remove the coupling, don't guard it" answer to v1.
- Replay analysis: a re-push of an old invite produces a fresh receipt with an old `signedAt`, so `receipt − signedAt` stays large. Receipt ≤ now makes the rule monotone toward admission, which is why the horizon and liveness bounds carry the load. The doc says this correctly.
- The owned 60 s horizon instead of iOS's 120 s and 8 h trust windows is the right call, and the doc found those windows in the code rather than assuming them.
- Naming #220 as a prerequisite rather than a nice-to-have.
- Honesty about the unpinned 30.0 s teardown.

**If RECAST, what to fold back:**
- Replace the "Dart keeps a short map from bridge events" mechanism with an awaited `receivedAt(callRef)` query on the control channel, called by `RingController` before `admitRing`. Keep `admitRing` pure (the receipt is passed in, like `now`).
- Specify `wokeAt`: set once by the wake handler on each platform, not touched by duplicate, displacement or Dart-report paths; null if the record was not created by a wake.
- State the horizon coupling (horizon ≥ ring ceiling + answered-unjoined lifetime) next to the constant.
- Add a unit and a hardware case for the race: the invite fetch completes before the bridge listener attaches.


Ripgrep is not available. Falling back to GrepTool.
## KelvinBitBrawler's Design Strike

**Verdict:** RECAST

**Summary:** This design correctly identifies absolute zero—the keychain lock state—as the thermal barrier, but its proposed solution is a fragile construct of unpinned timers and slushy dependencies, exchanging one ticking clock for two.

**Fatal flaws:**
- **Class: Unspecified Constraint.** The design has measured its own coffin but declines to ask who the carpenter is. It identifies its new binding constraint—a 30-second CallKit audio lease that dooms the call—and then labels the source of this timer as "Unpinned." This is not design; this is deferring the phase-change calculation until the material is already failing in production. A solution that does not understand its own critical path is merely a hypothesis. `Frank Herbert: "The mystery of life isn't a problem to solve, but a reality to experience."` This is not a mystery to experience; it is a time budget to be calculated.
- **Class: Arbitrary Constant.** The design decommissions one magic number (`kCallInviteFreshness`'s 10s) only to commission another (a 60s "receipt horizon"), justified with combinatorial hand-waving ("covers ring ... plus Answer ..."). This is not a solution; it is thermal drift. It solves nothing; it merely moves the point of entropic decay, ensuring that a user who takes 61 seconds to find their face will still experience a cold death. A proper design derives its constants from first principles or empirical measurement; it does not invent them.
- **Class: Brittle Dependency.** The entire security premise leans on the future, perfect fix for #220 ("a native ring record that outlives its call"), a problem so intractable that the native layer's current solution is an 8-hour trust window—a thermal exhaust port the size of a planet. To predicate v2's replay-safety on the perfect sealing of this wound, without defining the explicit contractual interface for what "fixed" means, is to build a cryogenic vessel on a foundation of rapidly melting ice. `GLaDOS: "This next test is impossible. Make no attempt to solve it."` This design assumes the impossible test will be solved by someone else.

**What holds:**
- The diagnosis is crystalline. Measuring freshness from the moment of native receipt is the correct thermodynamic principle. The clock was indeed being read at the wrong instant.
- The decision to keep the session keys in cold storage (`WhenUnlocked`) and fix the clock, rather than warming the keys as v1 proposed, is fundamentally sound. It correctly prioritizes a stable, low-energy state over a dangerous security trade.

**If RECAST, what to fold back:**
- The 30-second "audio lease" must be pinned. In "The locked-call path", the design must identify the source of this timer, its variance, and its configurability. The budget is not a suggestion; it is physics.
- The 60-second "receipt horizon" must be rigorously justified. In "Why this does not open a replay", the design must provide data on user unlock latencies to support this value or state the Pxx metric it is meant to satisfy.
- The coupling to #220 must be replaced with a hard, explicit contract. The design must specify the exact, verifiable properties it requires of the native call record store (e.g., "The native layer guarantees that looking up a `callRef` will NEVER return a record whose `receivedAt` is older than the `liveCallTrustWindow` of 120 seconds, regardless of its `answered` state"). Define the interface; do not simply point to a bug number and hope. We are engineers, not archaeologists of failure.


## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** no real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. This v2 finds the right thermodynamic variable: the freshness gate was reading heat after the engine had already lost work to Face ID. Measuring invite age at native receipt can dissolve the keychain-class trade. But the design is not yet reversible: it depends on a native live-record invariant it has not actually secured, borrows a 60s replay horizon while the real answer lease is still unpinned, and leaves clock/bridge semantics loose enough for entropy to leak back in. Dijkstra: "Simplicity is prerequisite for reliability." Feynman: "What I cannot create, I do not understand." Hamming: "The purpose of computing is insight, not numbers."

**Fatal flaws:**
- #220 is not merely a prerequisite; it is the load-bearing safety proof. The whole design says an old record for the same call id can admit an old invite if it remains live. Then it puts '#220 out of scope except prerequisite'. That is not a boundary, it is a hole with a label on it. The PR must either fix stale native records first or implement the 60s live-record horizon in the same change and prove ended/retired records cannot be consulted.
- The 60s receipt horizon is under-justified against the actual post-answer lease. The doc says CallKit/audio teardown happened exactly 30.0s after Answer, but does not know whether island lease, app expiry, or CallKit behavior enforces it. A 60s receipt record can remain trusted after the user-visible call may already be dead. The design needs one composed invariant: native record trusted only while the system call is still actionable, not merely while a wall-clock horizon has not elapsed.
- The bridge contract is underspecified for state, not just for a timestamp field. Dart needs to know that the receivedAt belongs to a live ring/answered record for this exact CallRef. A naked `receivedAtMs` on action events can become a fossil if pending events replay after native state has already ended, if end arrives before invite fetch, or if the Dart map misses the retirement edge. Entropy accumulates in maps that are only 'dropped when the record ends' without a proof every end path crosses the bridge.
- The design moves the age gate before the current code can safely name the call record. In the excerpt, `admitRing` computes age before it rejects `v1Call` and before it binds `body.call` into the admitted invite. v2 needs the signed CallRef to query the native receipt, so the admission order changes. That is probably safe after `originCryptoValid == true`, but it must be made explicit: parse signed v2 call id after signature verification, reject missing/malformed call before receipt lookup, then compute age.
- Android timestamp conversion is a clock-domain footgun. Android stores `elapsedRealtime` and later converts to wall time using `currentTimeMillis - (elapsedRealtime - instance)`. If wall clock moves between receipt and emit, the synthetic wall timestamp moves too. Since freshness compares against signed wall time, this can admit or refuse incorrectly. The cleaner design is to carry both domains or compute age at native receipt and pass a bounded age/proof, not reconstruct wall time later.
- The replay test is too weak. 'Reuse an old call id' and 're-send a signed invite more than 10s old' proves fresh receipt cannot launder an old signature, but it does not test the actual scary case: old signed invite plus old same-call native record still present and marked live/answered. That is the second-law path: stale state does work later.
- The design says the receipt is device-local and only the wake handler writes it, but the native record is keyed in the excerpt by channel with `call` as a value, not by CallRef as the primary identity. One-call-per-channel may be intended, but admission security is now call-scoped. The doc must prove channel-keyed storage cannot return the wrong call's receipt during overlapping, replacement, duplicate, or delayed-pending-event paths.
- The product answer 'connects after Face ID' dissolves v1, but the design still treats native ring receipt as an admission credential without saying what happens when the user answers after the caller hung up. END admission, pending END buffers, native end wakes, and invite admission must be composed. Otherwise a prompt receipt can admit a call whose teardown raced through another path.

**What holds:**
- The main reframing is correct. Freshness should measure invite arrival at the handset, not Dart's eventual authenticated recovery after Face ID. That deletes the wasted work of weakening durable session-token storage.
- Keeping session tokens `WhenUnlocked` preserves the stronger at-rest posture and avoids the migration trap that v1 fell into. That is the Carnot move: remove the heat leak instead of insulating it with more machinery.
- The replay argument is directionally right: a fresh receipt cannot make an old signature fresh because `receivedAt - signedAt` still grows with the invite's age.
- The design correctly separates invite freshness from ring duration. Those are different clocks, and conflating them was the original entropy source.
- The locked-read contract is now stated correctly: locked keychain reads throw and must not be flattened to absence. That protects `SovereignKeyStore` from minting a new identity under lock.
- The hardware test reproducing answer, wait 5s, then Face ID is the right liveness proof for the reported defect.

**If RECAST, what to fold back:**
- Make #220 part of this design's acceptance criteria: no trust of ended/retired records, no stranded answered record usable for admission, and a test where an old same-call record survives intentionally and must not admit.
- Replace '60s horizon' with a named invariant tied to native call actionability. If 60s remains, justify it against the 30s teardown and prove the system cannot join after the native call has died.
- Specify the exact admission order in Dart: verify signature, parse v2 CallRef from signed body, match native live receipt for that CallRef, compute age from receipt or now, then continue. Pin the refusal reason ordering deliberately.
- Strengthen the bridge contract: include `receivedAtMs` plus an explicit native state or generation, replay pending events only with current native liveness, and clear Dart's map on every native end/reset/timeout path.
- For Android, avoid wall-clock reconstruction drift. Prefer passing a receipt-age computed from monotonic clocks, or pass native wall time captured at receipt plus a test covering wall-clock changes between receipt and Dart emit.
- Add replay tests for the real bad state: old invite, same call id, old native record still marked ringing/answered, pending event replayed after end, and channel replacement by a newer call.
- Pin the 30s teardown source before merge. The design may still ship without extending it, but it cannot budget against a mystery clock.
- State the simpler architecture as the long-term ideal: a narrow call-scoped admission proof, not durable session credentials and not broad native live records. v2 is acceptable only if it proves this local receipt is exactly that proof and no more.


## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** You moved the hand of the clock and left the gavel on the ingest wall, so a photocopy of the receipt riding an event bus will arrive after the judge has already said stale — and the lemma that a receipt can only shrink age is already humming out of tune.

Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration."

**Fatal flaws:**
- **The receipt is judged at ingest, and ingest does not yet have the receipt (Decision; The locked-call path; What it costs; ring_controller excerpt).** v1 read the clock at the wrong instant. v2 writes the right instant on the native record, then *decides* on the Dart fetch, from a `CallRef → receivedAt` map filled by bridge events and `onListen` replay. Those are two frequencies. Session restore and invite fetch are not sequenced against `onListen`. The first `admitRing` on the locked path can see `receivedAt == null`, fall back to `now`, refuse `stale`, and return. The controller does not re-enter the gate when the answer event later arrives carrying the stamp. Runs 1 and 4 fail in production the same way they fail today, with a 13 s Face ID wait, whenever the photocopy is late. You already own the live native record at the moment Dart admits — 13 s old, sitting in `callkit.liveCalls`. Photocopying it onto the event bus is the coupling that shakes the glass.
- **The replay proof rests on a false lemma (Why this does not open a replay).** "A receipt can only make age smaller. `receivedAt ≤ now` always" is not physics, it is two wall clocks agreeing. `age = (receivedAt ?? now) − signedAt` can grow, and it can go negative: native wall ahead of Dart turns an admission into `stale`; native wall behind the signer turns a locked join into `clockSkew` on the path you are saving (receivedAt is earlier than `now`, so skew that today's late `now` would have forgiven now fails). The bound you need is still true without the lemma — signedAt versus receipt, live matching `CallRef`, device-local stamp, horizon on receipt age — but the proof as written will be cited as a closed door while a clock step walks through it.
- **Three clocks, six windows, two platform meanings of the same field (Decision; Android; AppDelegate excerpt; How we know it worked §3–4).** `signedAt` is the signer, `receivedAt` is native, `now` is Dart. iOS freezes `entry.at` as wall-clock seconds at remember-time. Android *reprojects* elapsedRealtime into `currentTimeMillis` at emit, so a wall-clock step after receipt moves Android's stamp and does not move iOS's. One Dart rule cannot hold both. Around them sit `kCallInviteFreshness` (10 s), island ring ceiling (30 s), CallKit disarm (30 s, unpinned), proposed horizon (60 s), `liveCallTrustWindow` (120 s), `answeredCallTrustWindow` (8 h). Unit test 3 says "older than the ring lifetime" — that name already means 30 s in `kInAppRingDuration`. Implement 30 and a slow unlock after a long ring misses. Implement 60 and you have minted a new trust window. Either way, "live" as UserDefaults-answered-for-eight-hours is the #220 zombie: if that `at` is ever copied into the admit map, the horizon is the only remaining fuse, and it is the fuse whose name the tests already blur.
- **The 30 s join lease is still an unnamed oscillator (The locked-call path; Not in scope).** The table hangs the whole product claim on Answer → Face ID → join < 30 s, then says the source of the 30.0 s `disarm` is unpinned and extending it is out of scope. Naming that hazard does not close it. If the island's ring ceiling is what ends an unanswered-to-the-island call, the user who answers at 20 s and unlocks at 25 s is inside your 60 s horizon and outside the island's mercy. The hardware test (answer, wait 5 s, Face ID) never strikes that frequency.

**What holds:**
- The four-run diagnosis still sings: the native wake is prompt in every lock state; Dart-now is what the 10 s gate was never meant to measure.
- Nick's product answer holds. Tokens stay `WhenUnlocked`. Face ID before join is Android's contract. The v1 keychain migration, the delete-then-add pair-split, the locked-read-as-null mint — gone, and good riddance.
- A fresh receipt cannot launder an old `signedAt`. Hostile re-push of an old body creates a record *now*; `receivedAt − signedAt` is the body's age. Mismatch of push `m` against the signed call id falls back to `now`. Fail closed.
- No wire change, no island change, sovereign key stays class A, locked read stays a throw. Revert is drop the field.
- The hardware test shape (lock past grace, kill, answer, wait, then Face ID) is the right strike. Keep it.

**If RECAST, what to fold back:**
- Make `receivedAt` an argument to `admitRing`, not a shadow map filled from events. `age = (receivedAt ?? now) − signedAt`. Parse `body.call` after signature and before the age clause so the controller can key the lookup; leave the v1 refusal last.
- At admit time, *query* the live native record for that `CallRef` (method-channel read of the map you already persist — `entry.at` / Android instance). On the locked answered path it has been sitting there for seconds. Do not decide stale from an event-bus photocopy. If a native ring is live for this id and the query still returns null, *hold* the invite and re-run the stale clause when the stamp arrives; do not let the first refuse win.
- Populate the freshness map only from the wake that created a ringing record, TTL the design's own horizon, matching call id. Never copy an 8 h answered UserDefaults zombie into it. Then #220 is not a prerequisite for this gate; say so, and keep #220 from blocking 0.0.6.
- Strike the sentence "a receipt can only make age smaller." Bound replay by the four remaining clauses. Define one clock: stamp monotonic plus wall, horizon against monotonic delta, age against wall `receivedAt − signedAt`, same reconstruction on both platforms. Name `kNativeReceiptHorizon = 60s` in the tests; stop saying "ring lifetime."
- Pin the 30 s `disarm` (island end vs app-side pending-answer) in this doc before the budget is a claim. If it is the island ending a call it has not heard joined, write that as the user-visible residual: unlock plus join must beat that lease. Extending it can stay a later decision; pretending the path is specified cannot.
