# 27-TEMPER.md — design 27, one session authority

**Final verdict (2026-11-16): CONVERGED AT THE CAP. Build v3 + the v3.1 requirements (design §6).**
Rounds: 1 RECAST 4/4 → 2 RECAST 4/4 → 3 RECAST 3/4, with Maxwell's SOUND withdrawn. No DISSOLVE
in any round. The panel shrank toward one mechanism (see "Round 3" below).

**Round-1 verdict:** RECAST (round 1 of at most 3), 4 of 4 families RECAST, none DISSOLVE.
**Struck:** dt-1794795469, 2026-11-16. Families seated: Maxwell + Noether, Carnot, Tesla (Wu disabled).
Bundle: `27-one-session-authority.md` @ 7cf005e + `lib/services/session_vault.dart` +
`lib/features/auth/application/auth_controller.dart` (87 KB). Cited-but-not-sent check ran: 0 paths not sent.
**Decided by Nick before the strike (2026-11-16):** §2d's switch order, and that
https://github.com/nickmeinhold/aiko_chat_app/issues/447 race 4 as written is not a harm. Both
held: Tesla and Maxwell each say so explicitly, and no family attacked either.

## Per-family verdicts

| Family | Verdict | One line |
|---|---|---|
| Noether (DeepSeek) | RECAST | The ban is a seventh nameless outcome, and the vault erases the credential the unpair needs. |
| Carnot (GPT) | RECAST | Credential fencing isn't session isolation: publication, bans, teardown and the singleton transport still act after their authority expires. |
| Maxwell (Claude) | RECAST | "The person means whatever is here now" confuses the time of the tap with the time of the commit, and the controller's own state is the unstamped half. |
| Tesla (Grok) | RECAST | The equality check guards an instant that has already passed, and a refresh deadline on one PREVIOUS token of grace turns two slow replies into a logout. |

## Fatal flaws (deduped, most severe first)

Each was checked against the source before folding. CONFIRMED means it was read in the code.
PLAUSIBLE means it rests on behaviour outside the bundle.

1. **A signal's teardown runs while the next sign-in commits.** Raised by Carnot, Tesla, and
   Maxwell (as the logout window). CONFIRMED: `_becomeUnauthenticated` publishes `data(null)`
   first, then `unawaited(_teardownResources())` (`auth_controller.dart:1041-1044`). `logout()`
   has the same shape (`:810-813`). The login screen is live while the teardown awaits the
   credential read, the debt write, the cache clear and `disconnect()` on the singleton
   transport. A sign-in that commits in that gap is unpaired with its own credential, and its
   socket gets closed. The `SessionEnded` equality check passed before any of this ran.
   **DISPOSITION, fold (the producer is removed, not guarded):** admission stays closed until the
   end is complete. Every end publishes `loading` (the router parks on `/splash`), runs the whole
   teardown, and only then publishes logged-out. No ceremony can start inside the teardown, so
   nothing is there to guard. This also kills flaw 4. `claimHandle` gets the same admission guard
   as `_ingress` (it has none today, `:677`).
2. **The ban is a seventh nameless outcome.** Raised by Noether, Carnot and Maxwell. CONFIRMED:
   every ban branch settles through `_settleSuspension` (`:376-413`), which reads `state.error`
   and ends whatever is current. **DISPOSITION, fold:** add the ban to §0's table as row 7.
   `AccountSuspended` is already a subtype of `Unauthorized`, so it gets the credential stamp
   from flaw 7. Settlement ends with that stamp, and flags `/suspended` only if it ended the
   session it names.
3. **The presentation commit is unfenced.** Raised by Carnot, Maxwell, and Tesla (as "UI state
   is the generation last rendered"). CONFIRMED: `_applyOutcome` awaits `setTokens`, then
   `_writeCachedUser`, then returns the user for `_ingress` to publish (`:658-662`, `:356`). If
   the person signs out after the adopt, A is shown signed in while the vault is signed out.
   **DISPOSITION, fold, new §2g:** one setter, `_publishSession(user, lease)`, lands only while
   `vault.lease == lease`. `_applyOutcome`, `claimHandle` and `_restoreSession` publish through
   it. A superseded attempt drops without writing anything, which also settles Noether's point
   that `SessionSuperseded` becomes an `AsyncError` that overwrites the state.
4. **The person's own sign-out has deferred authority.** Raised by Carnot and Maxwell. Noether
   and Tesla both defended unfenced `signOut()`. **DISPOSITION, folded through flaw 1, not a
   fence:** once admission is closed until the end completes, nothing new can exist for the
   person's end to hit. `signOut()` stays unfenced, as Tesla and Noether argued. Maxwell's
   "capture the lease at the tap" proposal is withdrawn: it would be a second mechanism for a
   window that flaw 1 already removes.
5. **The unpair reads a credential the vault already erased.** Raised by Noether, Tesla and
   Maxwell. CONFIRMED (`:795`). **DISPOSITION, fold:** the end returns the credential it ended,
   and the teardown unpairs with that value. It never calls `currentAccessToken()`. §4 doesn't
   claim the device-row residual is closed until this lands.
6. **§2c contradicts §2f, and §2d's error path contradicts itself.** Tesla raised the first
   (the person's own end also emits `SessionEnded`, the listener sends them to login, and the
   "couldn't sign out" message never renders). Noether raised the second (§2d says both "the
   picker shows the error" and "signed out"). **DISPOSITION, fold:** `SessionEnded` is emitted
   only for ends the person didn't ask for (a refresh rejection, a fenced 401, a ban). The
   person's path renders its own outcome. A failed end on disk is a state ("ended in memory,
   not on disk") that the screen shows, and retrying calls `signOut()` again. §2d states one
   invariant: the app is signed out, and the live config and the saved preference still name
   the old island.
7. **The 401 stamp is a lease alone, and it's optional.** Tesla raised it. PLAUSIBLE: a refresh
   doesn't move the lease, so a forwarded 401 on an access token that has since been rotated
   carries the current lease and would end the session that was just refreshed. Whether the
   interceptor can forward such a 401 is outside the bundle. **DISPOSITION, fold, and it costs
   little either way:** `Unauthorized` carries the presented credential (lease + access token).
   The vault ends only if both are still current. "This request carried no credential" becomes
   its own type, not `lease == null`. §2c's "or the lease is current" wording is deleted.
8. **The refresh deadline: two lost replies in a row may end the session.** Tesla raised it, and
   Noether and Carnot raised §2e too. PLAUSIBLE: this depends on exactly what island #420's
   PREVIOUS grace does (does a PREVIOUS retry return the same rotation, or rotate again?). The
   island tab must answer. **DISPOSITION, fold, plus a question to the island tab:** the 15 s
   deadline goes on the refresh request alone (CONFIRMED that `bare` is shared with
   `GatewayRestApi`, so a client-wide timeout would also cut off passkey ceremonies,
   `gateway_rest_api.dart:944,964`).

   **Lost replies are safe. A request the deadline gave up on is not.** I first marked this
   flaw REFUTED after checking only lost replies. The island tab corrected me (2026-11-16
   13:47). The island code is in `aiko-chat-island/src/aiko_gateway/domain/auth_session.py`:
   - Presenting CURRENT (`:163-166`) sets current to a new token and previous to the presented
     one.
   - Presenting PREVIOUS (`:167-170`) sets current to a new token and leaves previous
     unchanged. So any number of *lost replies* stays recoverable.

   But the deadline creates a case that isn't a lost reply:
   1. Attempt A presents R1, stalls, and is abandoned at 15 s.
   2. Retry B presents R1 and lands first (current R2, previous R1). The app stores R2.
   3. A lands late. R1 is now PREVIOUS, so current becomes R3 and previous stays R1.
   4. The app's next refresh presents R2, which is neither: `RefreshReused`, and the session
      ends.

   The docstring at `:118-119` deleted the 30 s re-issue window because "the app keeps one
   refresh in flight". A client deadline breaks that assumption silently. Tesla's original
   wording ("do not send the refresh token again after a timeout") pointed at this exact case.

   **The real fix is the attempt id**,
   https://github.com/nickmeinhold/aiko-chat-island/issues/452: one persisted id per logical
   refresh, reused on retries, which the island answers idempotently. That issue is
   drafted-only and unscheduled, and needs a minor-wire release with the island deploying
   first.

   **DISPOSITION, NAMED TRADEOFF until #452, owner app tab, prioritising #452 is Nick's call:**
   - The deadline goes on the refresh request alone. It's long relative to realistic stalls (a
     fixed whole-request bound, of the order of the island's own request timeout, not 15 s per
     phase).
   - A timeout cancels the request, which aborts its connection, so bytes not yet sent never
     arrive.
   - A reply for an abandoned attempt is never adopted.

   Residual: a request already on the wire can still land after the retry. That costs one
   passkey sign-in, not a loop. The alternative, no deadline, is task 79's harm: a hung
   refresh stops reconnection forever, which is worse.
9. **No table of who ends what.** Noether raised it: `deleteAccount` and `_settleSuspension`
   lost their ender when §3 took `clearTokens()` out of the teardown. **DISPOSITION, fold:**
   §3 gains a table. `logout` and `switchIsland` call `signOut()`. `deleteAccount` calls
   `signOut()` on its own success, fenced by flaw 1's closed admission. Signal paths call the
   credential-stamped end. `_teardownResources` ends nothing.
10. **Carnot's recast: a session-scope object** that owns the transport, the pairing and the
    identity, and is retired before cleanup. **DISPOSITION, NAMED ALTERNATIVE, not adopted,
    owner app tab.** Flaws 1, 3 and 5 give the same isolation with no new object: admission
    closed until the end completes, one fenced publish door, and the credential carried by
    value. Round 2 checks whether any shared-resource leak survives those three. If one does,
    the scope object comes back.

## What holds (agreed by every family that addressed it)

- §0's diagnosis: one producer, terminal outcomes that drop the session they belong to.
- The lease as the fencing token: monotonic, in-process, never moved by a refresh.
- Deleting the transport's logout listener instead of guarding it.
- `adopt(..., since:)` in the serial lane, with the lease read before the network call.
- §2d's order (the end on disk before the island moves) and the race 4 pushback.
- §4's residuals, especially the abandoned island session.

## Disposition

RECAST: fold flaws 1-9 into design 27 as v2 and re-strike (round 2 of at most 3). Flaw 8's
residual is closed only by island #452's attempt id. Scheduling it is Nick's call. Nothing else waits on the island.

<!-- Each section below was written when that family returned. Arrival order, NOT a ranking. -->

## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The design conserves "every terminal outcome names its session" across six rows — but a terminal outcome it never enumerated (the ban) still travels nameless, and the one writer it anoints (the vault) quietly consumes the credential the unpair was conserving.

**Producer first:** The harm is "an outcome produced under session A ends, replaces, or redirects session B" — the stale logout, the late adoption, the ban landing on a person who signed in since. The producer is **each boundary that converts a lease-stamped outcome into a bare one**: the REST interceptor (`_authedCall`), `_restoreSession`'s `on Unauthorized`, the sign-in's `setTokens`, and the auth-event stream. That producer *is* deletable, and the design mostly deletes it: row 3's transport listener and row 6's switch ordering are removed outright, and rows 1/2/4/5 stop erasing the lease (the bad state "an outcome with no session" becomes unrepresentable — the right move, not a better guard). But the producer is **not** deleted for the ban: `AccountSuspended` is a terminal outcome that still travels without a lease and still reaches the unfenced `_settleSuspension`, which ends "whatever is current." So the first flaw is a producer the design left standing while claiming none is left.

**Fatal flaws:**
- **The ban is the seventh place, and it is unfenced** (design 26 §2c / design 27 §1, §2c). `AccountSuspended` is a terminal auth outcome produced by a request that carried a credential, exactly like `Unauthorized` — but the design stamps only `Unauthorized` with a lease. `_restoreSession`'s ban branch, `refreshUser`/`saveProfile`'s ban branch, and `_settleSuspension` all end "whatever is current," and `_settleSuspension` also clears the credential and flags `/suspended`. Reachability: session A, a settings `saveProfile` in flight (A's credential); the person signs out and signs in as B; A's 403 arrives; `_settleSuspension` flags B suspended and clears B's credential. §2c's "no unfenced door left" is false, and §1's "one thing, in six places" under-counts the blast radius. **Make it impossible:** stamp `AccountSuspended` with the lease of the credential that got the 403 (the same `extra['aiko_credential']` source), and route every ban branch through `endIf(lease)`; then no ban-specific fence is needed.
- **The unpair's credential is consumed by the vault before the teardown reads it** (§2c, §4). The design ends the session *in the vault* first (`endIf(lease)` in `_becomeUnauthenticated`, or `_end` inside `_fly` before `SessionEnded` fires), *then* runs the teardown, which reads `currentAccessToken()` to hand the credential to `unpair`. Since the vault is now the only writer and it has already written `SignedOut`, that read is **null on every signal path** — the device debt loses the credential the design's own `_clearCredentialAndUnpair` doc says it must carry "by value." §4 claims this change closes the "island keeps a live routable row forever" residual; on the two signal paths it reopens it. (The switch is fine only because §2d orders unpair *before* `signOut`.) **Make it impossible:** unpair before `endIf`, or carry the ended credential in `SessionEnded`, or have `endIf` return the credential it ended.
- **§2d's failure path is incoherent.** It asserts both "the picker shows 'couldn't sign out, try again'" and "the app is signed out on the old island." Those cannot both hold: the switch publishes `loading` (router → `/splash`), and a signed-out publish sends the router to `/login` — the picker is unmounted either way. Either leave the picker mounted (don't publish logged-out) or drop the claim and surface the error on `/login`. Pick one and state the invariant: *app signed out, live config and pref unchanged on the old island.*
- **§3 removes `clearTokens()` from the teardown but names only two replacement enders.** `deleteAccount` and `_settleSuspension` both reach `_clearCredentialAndUnpair`/`_teardownResources` and rely on the removed `clearTokens()` to end the session. The design names `logout()` (§2f) and `_becomeUnauthenticated` (§2c) as the new enders and is silent on the other two. As written, a completed account deletion or a settled ban can leave a live session in the vault. **Name every ender explicitly:** person/switch paths call `signOut()`; signal paths call `endIf(lease)`; `_teardownResources` ends nothing.
- **§2b's "no state change, no error shown" is under-specified.** The ceremony runs inside `_ingress`'s `AsyncValue.guard`, so a thrown `SessionSuperseded` becomes `state = AsyncError(...)` — which *clobbers* the state the superseding action (sign-out, switch) just published. "Abandoned" must mean "drop without writing," not "write an error." State how `_ingress` recognizes `SessionSuperseded` and leaves the superseding state intact.
- **§2e's PREVIOUS-token grace is a correctness dependency mislabelled "residual."** The deadline is client-side, but the *recoverability* of a lost rotation reply is entirely island-side. If any supported island lacks the grace (or its window is shorter than the transport's reconnect backoff), a lost reply becomes a terminal logout. That is a hard contract, not a residual — version-gate it or state the logout-on-lost-rotation fallback.

**What holds:**
- The producer deletion for row 3 (the transport stops being a logout trigger) and row 6 (end-on-disk before the island moves) is the correct shape — remove the door, don't guard it.
- The lease is a sound fencing token: monotonic, in-memory, advanced on `adopt` and `_end`, never on `refresh`; the vault's serial lane makes `endIf`'s check-and-end atomic against a concurrent `adopt`.
- `signOut()` staying unfenced for the person's own action (and a switch) is correct — "whatever is here now" is exactly what the person means.
- Threading the lease through rows 1/2/4/5 (rather than adding a guard beside the erasure) is the right move: it makes the nameless outcome unrepresentable.
- §2e's timeout mapping (transient, not `RefreshRejected`) preserves the transient-vs-terminal boundary.

**If RECAST, what to fold back:**
- Add `AccountSuspended.lease` (same source as `Unauthorized.lease`) and route `_restoreSession`, `refreshUser`, `saveProfile`, `_payOwedHandle`, `_settleSuspension` through `endIf(lease)`. Re-count §1's table: seven places, not six.
- Fix the unpair: unpair (or capture the credential) before `endIf`/`_end`, or put the ended credential in `SessionEnded`. Otherwise delete §4's claim that the device-row residual is closed.
- Resolve §2d's error path to a single invariant and drop the unreachable "picker shows" line.
- Add an explicit "who ends the session" table: `logout`/`switchIsland`/`deleteAccount` → `signOut()`; `_becomeUnauthenticated`/`_settleSuspension`/`_restoreSession` terminal branches → `endIf(lease)`; `_teardownResources` ends nothing.
- Specify `_ingress`'s handling of `SessionSuperseded` (drop, don't publish).
- Promote §2e's island grace to a versioned requirement, or name the logout fallback.

## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** The vault is a credible authority for credentials, but the design mistakes credential fencing for session isolation. Identity publication, bans, teardown and island changes still mutate shared state after their authority expires. Dijkstra: "Simplicity is prerequisite for reliability." No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. Here, the entropy escapes through the controller.

**Producer first:** The harms are signing out a later user, publishing an abandoned identity, and allowing old-session work to affect a different island. Delayed replies, queued events and storage failures are triggers. Our producers are unfenced clearTokens calls, asynchronous writes to shared auth/cache state, teardown of a singleton transport, and independently changing session and island state. The proposal removes two producers correctly: signal-driven unconditional credential clearing and the transport's duplicate logout channel. It leaves other producers intact. Credential checks remain necessary because remote outcomes can arrive after their session ends; shared mutable controller state and shared teardown targets are architectural choices that can be removed.

**Fatal flaws:**
- Make old-session teardown of a new session impossible: give each session ownership of its transport, pairing and identity state, and retire that captured scope; then repeated lease checks around shared-resource teardown become unnecessary. In §2c, a SessionEnded event can pass its lease check, begin awaited unpair/cache cleanup, and then disconnect B's singleton transport or clear B's cache after B signs in. The vault's serial lane does not serialize those effects.
- A successful adopt is not a completed sign-in. A can adopt, await its cache write, then be signed out or replaced before _ingress publishes A's returned user. No SessionSuperseded is thrown: adoption already succeeded. Late cancellation, errors and PendingHandle outcomes also bypass adopt entirely and can overwrite newer controller state. Make ceremony results belong to a disposable attempt/session scope, with identity publication derived from the active scope; fencing only setTokens leaves the actual resurrection producer running.
- The terminal-outcome inventory omits bans and successful deletion. AccountSuspended is caught before Unauthorized and reaches unconditional clearing through _restoreSession or _settleSuspension; settleBan carries no provenance. An A ban arriving after B signs in can suspend and clear B. Likewise, A's late deleteAccount success invokes teardown against B. These outcomes must retire their originating session scope. A user initiating deletion under A does not authorize its eventual completion to end B.
- The switch is ordered internally but is not exclusive against adoption. After signOut advances the lease, the saved and live island remain old while the preference write awaits. An old-island ceremony starting in that interval captures the new lease and can legitimately adopt after the switch ends. Loading is presentation state, not admission control; a SessionEnded handler may also replace loading with logged-out state. Make switching revoke the old island's ability to issue acceptable adoption capabilities for the entire transition, rather than relying on the router to prevent calls.
- Even explicit logout still has deferred authority. The supplied _clearCredentialAndUnpair awaits credential lookup and durable unpair recording before invoking the unfenced end. Logout publishes logged-out first, so B can sign in during that interval and be cleared by A's pending logout. Section 2f does not specify a replacement ordering. Capture the departing session and synchronously retire its admission/publication authority when logout begins; pairing cleanup must operate on that captured session. 'The person asked' does not make a delayed operation permanently authoritative over future sessions.
- Section 2e promises a 15-second deadline but specifies three phase timeouts. Those settings do not establish one elapsed-time bound for the refresh flight, including an indefinitely progressing response. Define the bounded operation and ensure expiry releases the flight while preventing the abandoned request from committing later. The PREVIOUS-token retry argument also needs an explicit server contract for overlapping timed-out requests, grace expiry and repeated lost responses; one retry example does not establish recovery for all those schedules.

**What holds:**
- Keeping credential ownership and serialized durable mutations in the existing vault avoids another coordinating object.
- Deleting the transport's logout authority removes a producer instead of decorating it with guards.
- Leases distinguish replacement from refresh; access-token equality and userId cannot provide that distinction.
- Persisting the session end before saving the destination island closes the stated legacy-placement crash hazard.
- The named storage-failure and abandoned-server-session residuals are candid and useful.

**If RECAST, what to fold back:**
- Recast around a session scope: an immutable identity/island association with owned resources and revocable authority. Keep the vault responsible for durable credentials; derive controller presentation from the active scope.
- Retire the scope immediately on logout or switch, before awaited cleanup. Cleanup captures the departing resources and cannot touch their replacements.
- Treat sign-in attempts and switching as competing authority transitions. A switch closes old-island admission before any await and opens destination admission only after durable end and config settlement.
- Carry origin through every asynchronous completion: success, cancellation, PendingHandle, Unauthorized, AccountSuspended and account deletion. Remove unconditional clearing from delayed completion paths.
- Add adversarial schedules covering logout after adoption but before publication, B signing in during A's teardown, stale bans and deletion success, and a ceremony starting between switch end and config settlement.
- Specify and test an elapsed refresh deadline plus server behavior when an expired attempt remains in flight.


## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST

**Summary:** The lease is the right name, but §2a smuggles in an illegal move: it treats the person's own sign-out as "whatever is here NOW" and leaves `signOut()` unfenced, when "now" is the moment of the tap, and the controller commits that intent many awaits later. The same nameless-outcome producer then survives in the one place the design never stamps, the controller's own published state.

**Producer first:** The harm is a session presented, ended or revived by an operation that belongs to a different session. Triggers (a late reply, a slow keychain, a 403 ban, a human tap) are external; the producer is OURS and has two halves. (1) **Any writer that ends "whatever is current"**: the six rows, plus the ban path (`_settleSuspension` → `_clearCredentialAndUnpair` → `clearTokens()`, `auth_controller.dart:376-413`), plus the person's `logout()`, which publishes `data(null)` and then awaits `currentAccessToken()` and the debt write before it clears (`:810-813`, `:784-807`). (2) **Any writer of the controller's `state` that doesn't name the session it describes**: `_applyOutcome` awaits `setTokens` then `_writeCachedUser` then returns the user, which `_ingress` publishes (`:658-662`, `:356`). Both halves are removable, not guardable. (1) **Delete the unfenced `signOut()`.** Every end, the person's included, becomes `endIf(lease)`, with the lease captured synchronously at the tap (or at the switch's start). The vault then has no door that ends an unnamed session, and §3's list of "who may end whatever is current" is empty, so there's nothing left to audit. (2) **One door for the controller's signed-in state**, `_publishSession(user, lease)`, which lands only while `vault.lease == lease`. That makes a stale publish unrepresentable, so no per-path check is needed.

**Fatal flaws:**
- **Make "a person's sign-out ends a later session" impossible: capture the lease at the tap and end with `endIf(captured)`. Then `signOut()`'s unfenced door, and the window-reasoning in the `_clearCredentialAndUnpair` doc, become unnecessary.** (§2a, unstated assumption.) The design's justification ("the person means whatever is here now") conflates intent-time with commit-time. Today's code already publishes logged-out first, then awaits a keychain read and a durable prefs write before the clear. A sign-in that commits inside that window is ended by a tap that predates it. Carnot found the same window. I'm naming the deeper shape: an unfenced door that's "correct by intent" is the producer this design exists to delete, and it was left in as the one exception.
- **Make "a stale ceremony publishes its user" impossible: one fenced publish door for the controller's state.** (§2b, missing failure mode.) `adopt(since:)` fences the *credential* commit, but the *presentation* commit is three awaits later. Sign out after `setTokens` and before `_ingress` assigns `state`, and the app shows A signed in while the vault is signed out. The next cold start then says otherwise. `SessionSuperseded` never fires, because adoption succeeded (Carnot's flaw 2, confirmed in the source). Fencing the vault and not the controller fences half the session's state.
- **The ban is the seventh row.** (§0 table, under-counted blast radius.) `AccountSuspended` is a subtype of `Unauthorized`, so §2c's `int? lease` reaches it for free. But every ban branch settles through `_settleSuspension`, which reads `state.error`, never a lease, and ends whatever is current. Fold: the ban carries the 403's lease, and settlement goes `endIf(lease)` → flag `/suspended` only if it ended something or the lease is current. Raised independently by Noether and Carnot. That's three families on one row.
- **The unpair reads a credential the vault has already erased.** (§2c, contradiction with the design-26 doc.) `_clearCredentialAndUnpair` reads `currentAccessToken()` *after* §2c's vault has written signed out, so the debt record gets `null` on every signal path (Noether, confirmed at `:795`). The harm is mild: the token was rejected, and the debt carries over to the next sign-in. But §4 shouldn't claim the device-row residual is closed. Fold: `endIf` returns the credential it ended, and the teardown unpairs with that value.
- **`_becomeUnauthenticated`'s guard lets a signal tear down a switch in progress.** (§2d, coupling.) The guard is `state.value == null && !state.isLoading` (`:1042`), so during the switch's `loading` a current-lease `SessionEnded` proceeds, publishes `data(null)`, and reopens `_ingress` admission mid-switch. `claimHandle` never checks admission at all (`:677`). With leases captured at the tap, this collapses: the switch's own `endIf` bumps the lease, the signal's lease is stale, and it's dropped. That's another reason to delete the unfenced door rather than guard around it.

**What holds:**
- §0's producer framing ("terminal outcomes travel without naming their session") is right, and the lease is the right name: monotonic, in-memory, never advanced by a refresh.
- Row 3 is closed by deletion (the transport stops being a logout trigger), which is exactly producer-first.
- §2d's switch order (end on disk before the island moves) is sound, and Nick's two decisions hold under the strike. Race 4 is still not a harm once the switch captures its lease at its start, because B can't be admitted while the switch holds `loading`, except through `claimHandle`'s missing guard. Fix that guard, which is cheap.
- §4's residuals are honestly named.

**If RECAST, what to fold back:**
- §2a: delete unfenced `signOut()`. The vault's only end is `endIf(lease)`. `logout()` and `switchIsland()` read the lease synchronously at entry and end with it.
- New §2g: `_publishSession(user, lease)` is the controller's only signed-in setter, and it lands only on a current lease. `_applyOutcome`, `claimHandle` and `_restoreSession` publish through it.
- §0 table: add row 7, the ban. Route `_settleSuspension` through `endIf(lease)`.
- §2c: `endIf` returns the ended credential, and the teardown unpairs with it. Drop §4's "residual closed" wording if it isn't threaded through.
- `claimHandle` goes through the same admission guard as `_ingress`.
- Tests: logout-then-sign-in-inside-the-teardown-window, sign-out between adopt and publish, stale ban after a new sign-in, and a signal during a switch's `loading`. Mutation-check each against today's code.


Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration."

## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** The lease is the right name for a session, and it is deaf to the two events that actually arrive late — a refresh that does not bump it, and a teardown that runs while the next sign-in still shares it — so at 3am a corpse-token and a slow retry shake the live session to glass.

**Producer first:** The harm is a person watching the wrong session die, come back, or walk onto an island that did not mint it. The triggers are a late 401, a queued event, a dropped refresh reply, a crash. The producer is ours: something outside the vault applies a terminal outcome to whatever is current. `clearTokens()` is that producer, and §2a is right to take it away from signals. It can be deleted, and §2c then rebuilds it. `endIf`, the `SessionEnded` equality test, and `int? lease` are checks in front of a controller that still re-reads the live credential, unpairs, disconnects the singleton socket, clears the live cache, and publishes logged-out. Make that outcome impossible: the vault stays the only end (it already ends inside the lane on `RefreshRejected`, and already drops a stale refresh commit); an access-token 401 is answered in that same lane by comparing the access token to the one now presented, and a mismatch ends nothing; unpair takes the retired credential by value inside that end, before the lane admits the next `adopt`; the socket is born bound to that generation and can be closed only by identity. Then `endIf`, the controller lease check, and the nullable lease are unnecessary. Two checks stay, for causes that are not that producer. `adopt(..., since:)` stays: the island has already created the ceremony's session, so the late write cannot be prevented, only refused by the single writer. `signOut()` stays unfenced: the person, and the switch they asked for, mean whatever is here now, and no stamp can name a future they have not forbidden. The refresh deadline has a second producer. The harm is a slow link logging them out. The trigger is the timeout; the producer is the new flight, which sends the refresh token again after the island may have rotated, against a grace of one previous token (§2e). Make that impossible: a deadline may release the flight, and it must not start another rotation until the attempt is idempotent (island attempt id, [aiko-chat-island#452](https://github.com/nickmeinhold/aiko-chat-island/issues/452)). A longer timeout is another check and does not remove it.

**Fatal flaws:**
- Make "a stale terminal signal mutates the live session" impossible, as above; then the new checks in §2a and §2c become unnecessary. The shatter frequency is the one §1 is proud of: the lease advances on a sign-in and on an end, never on a refresh. Carnot's pinned retry ([aiko_chat_app#453](https://github.com/nickmeinhold/aiko_chat_app/pull/453) round 2, §2c row 4) is safe for B only because B's sign-in moved the lease. The same retry against a refresh that committed and did not move the lease still carries the current lease, and `endIf` ends the session that just rotated. Test 4 never plays that note. §2c's predicate makes it worse: tear down "if it ended something or the lease is current." After a newer sign-in, a lease is current. That sentence swings the axe at the survivor.
- The `SessionEnded` compare is true for the whole life of the dangerous sign-in. §2c carries the lease the vault advanced *to*. A ceremony that starts after the end reads that same number (§2b) and is allowed to `adopt` it. Equality fails only once that adopt has committed. Test 3 delivers the event after the sign-in. The production order is the other one: the listener has passed the compare, then awaits unpair, cache clear, and `disconnect` on the singleton transport, while the new ceremony commits. Unpair re-reads whatever credential is current (`_clearCredentialAndUnpair` already does). The late `disconnect` closes the new socket, the same singleton the file's own Carnot note says `connect()` will reuse. The check guards the instant that has already finished.
- §2e calls a timeout transient, then the transport schedules a reconnect that starts a new flight (test 7). Island grace is one previous token (design 26's own #420 rule, restated in the vault: presenting anything but CURRENT or PREVIOUS ends the session). One abandoned rotation leaves PREVIOUS in the client's hand. The second timeout, likely on the same slow link that blew the first 15s, rotates again and the token in hand is neither. The third attempt is a terminal end. The taxonomy says transient. The island's window makes the second loss terminal. Shipping the deadline before the attempt id is a logout machine with a 15-second crank.
- §2c and §2f cannot both be true. Every `_end` advances the lease, so every end, including the person's `signOut`, emits `SessionEnded`. The listener then publishes logged-out and tears the UI down. §2f needs the settings screen to remain and say the disk write failed, so a retry can write the tombstone. The listener eats that screen. The person is standing on the login wall, memory already ended, disk still holding the session. The next launch restores it. That is the bug §2f says it is closing, played an octave higher. `SessionEnded` does not say whether the end was quiet, so the listener cannot tell a refresh rejection from a disk failure.
- §2c's `int? lease` and `extra['aiko_credential']` are the original disease in a side pocket. A credentialed 401 that forgets the side channel becomes "end nothing," and a dead session stays on screen. A required lease on the authed failure, with a separate type for "this request carried no credential," makes the silent no-op unrepresentable. Do not add a fallback check for a missing key.
- §2e puts the 15s connect, send, and receive deadlines on the bare Dio that `buildGatewayBackend` builds. §1 names that client as the one with no timeouts, and the transport awaits it for refresh. If that Dio is the gateway client, every other call inherits the refresh's deadline. Fold the deadline onto the refresh request alone.

**What holds:**
- The diagnosis in §0 is the true one. Six call sites, one producer: a terminal outcome that drops the session it was born under. The vault already fences its own refresh commit and its own rejection. The work is to stop anyone else from ending "whatever is current."
- Deleting the transport listener (§2c, §3) is the right deletion for the two cases named: a rejected socket refresh already ends inside `vault.refresh` and can emit one signal; a socket with no credential is not an end. A third local `_setUnauthenticated` that never enters the vault would leave a signed-in UI on a dead socket, which is the residue to confirm on the transport, not a reason to put the listener back.
- `adopt(..., since:)` inside the serial lane (§2b) is the right fence for race 1. The early read is safe because the compare happens on the lane at commit, and the lane is not held across the network.
- §2d's order holds under load. The island moves only after `signOut` has landed on disk. A failed tombstone stops the switch and leaves the old record on the old island. A failed save after a landed tombstone leaves them signed out where they were. Losing the old "failed save keeps the session" behaviour is the right trade against one island's token being presented to another. The pushback on [aiko_chat_app#447](https://github.com/nickmeinhold/aiko_chat_app/issues/447) race 4 holds: a sign-in that lands on the island being left is part of what the person asked to end, and §2b fences the commit that arrives after the end.
- The in-process lease (§1, §4) holds. It starts at 0, nothing persists it, and a previous process cannot present one. A crash mid-switch that leaves the old record is still design 26's allowed failure.
- The abandoned island session (§4) is a true residual. Revoking it wants a logout-by-token the island does not offer. Do not invent a client check for it.

**If RECAST, what to fold back:**
- Rewrite §2c so the controller is not an ender. `Unauthorized` from an access token calls the vault with that credential. The vault, on the lane, ends only when that access token is still the one presented, or when the refresh token was `RefreshRejected` (already implemented). A 401 for a token already rotated returns without moving the lease. Delete `endIf` as a controller tool. One signal leaves the vault after a real end, carrying the retired access token by value and the generation advanced *to*.
- Unpair runs inside that end, with the retired token, before the lane accepts the next `adopt`. The handler never calls `currentAccessToken()`.
- The socket is created for a generation and closed by that identity. Remove "disconnect whatever `transportProvider` holds now" from the signal path.
- UI auth state is the vault generation the controller last rendered. Applying an older generation is a no-op, including a `data(null)` from a signal whose generation has already been succeeded. State the predicate as "this generation is still the one on the vault," and delete "or the lease is current."
- Split the person's `signOut` from the quiet end in the signal. Disk failure is a state the settings screen renders (`ended in memory, tombstone not on disk`), reachable because the listener does not navigate that state to a bare login. Retry calls `signOut` again.
- §2e: the 15s bound is per refresh request, on that request alone. On timeout, drop the flight and do not send the refresh token again. Reconnect may retry only once the attempt id makes that send the same attempt. Until [aiko-chat-island#452](https://github.com/nickmeinhold/aiko-chat-island/issues/452), a timed-out refresh stays parked and the session stays. Update test 7 so a second timeout must not be able to reach `RefreshRejected`.
- Add the two orderings that actually hum. A refresh commits, the lease stays still, the pinned pre-rotation retry gets a 401, and the refreshed session is still the one presented. `SessionEnded` is in flight, unpair and disconnect are awaiting, a sign-in that read the post-end lease commits, and the new credential is not unpaired and the new socket is not closed.
- Keep §2b, §2d, the listener deletion, and the unfenced `signOut`. Those already resonate.



---

# Round 2 — dt-1794797382, v2 @ d9cfd18

**Round-2 verdict:** RECAST, 4 of 4, none DISSOLVE. All four seated (bundle 136 KB, Carnot returned).
Bundle: v2 + this record (round 1) + `session_vault.dart` + `auth_controller.dart`.

Every family says v2 removed round 1's producers. The findings are narrower, and they converge on
**one shape: the controller still has several unsequenced writers of what it shows** (`state`,
`pendingHandle`, `suspended`, the cached user), and "an end is running" is a value any of them
can overwrite. Round 1 fenced the *vault*. Round 2 says the *controller* needs the same thing.

## Round-2 flaws (deduped, all checked against the source)

A. **The ceremony still writes `state` itself.** Raised by Noether and Tesla; Carnot covered it in
   his publication inventory. CONFIRMED: `_ingress` assigns `state = await
   AsyncValue.guard(...)` (`:356`), and `claimHandle` does the same (`:677`). §2b's `_publish`
   drop is then overwritten by the returned user.
B. **The ban checks the wrong things, and its flag isn't atomic with its end.** Raised by all
   four. A ban is about the *account*, so it must compare the lease only (a refresh keeps the
   lease and rotates the token). The flag must also be set from the result of the lane, not from
   a synchronous `isCurrent` taken outside it (Tesla: `_fly` writes `_state` only after `_put`).
   CONFIRMED that `settleBan()` (`:940-943`, called from `moderation_controller.dart:134,219`)
   creates an `AccountSuspended` with no credential, a ninth door.
C. **"An end is running" lives in `state.isLoading`, which other writers overwrite.** Raised by
   Maxwell and Carnot. Overlapping ends both run cleanup (Carnot). A `signOut` that throws
   latches `/splash` with no release (Tesla).
D. **Sibling state is unfenced.** Raised by Noether, Carnot and Tesla. `pendingHandle` is set by
   a late `PendingHandle` outcome. Teardown clears `suspended` unconditionally (CONFIRMED
   `:726`), which is the opposite of what §2d needs. The cached user is written by a late
   `_writeCachedUser` from A over B's (Carnot).
E. **A late delete ends the person who signed in since.** Tesla raised it; Carnot covered it in
   his inventory. CONFIRMED: `deleteAccount` awaits the island, then tears down (`:1020-1030`),
   so §2h's "admission closed since its first step" is false.
F. **The switch doesn't go through the common door**, and its error path has no screen (Carnot,
   Tesla).
G. **Test 12 tests one schedule and certifies the other** (Tesla). Noether asks to make #452 a
   prerequisite, which is task 89's alternative for Nick.
H. **Small items:** `_restoreSession` doesn't `adopt` (Maxwell). `_clearCredentialAndUnpair`
   must lose its `clearTokens()` (Noether). Emit `SessionEnded` after the lane turn returns, so
   a handler can't wait on the lane from inside it (Tesla).

## Disposition: one fold that removes A-F together

**The controller gets its own transition lane**: the vault's pattern, lifted one layer. Every
change to what the app shows runs as one serial transition, and every write to `state`,
`pendingHandle`, `suspended` and the cached user happens only inside one:
- a sign-in's commit;
- an end of any kind;
- a switch;
- a ban;
- a delete's completion.

Each transition is issued for a lease, captured before the network call, and it starts by
checking that lease. Network work stays outside the lane, and only commits enter it.
Admission is "the lane is idle". It's released in a `finally`, so a throwing end can't latch
`/splash`.

That removes:
- A: ceremonies return `void`, and their commit is a transition.
- C: no flag can be overwritten, and overlapping ends queue.
- D: each transition writes the whole picture once.
- E: a delete captures its lease at send, and its completion is a fenced transition.
- F: the switch is one transition.

B gets the lease-only predicate for account outcomes, with the flag set from the lane result.
G splits test 12. Carnot's scope object stays not adopted: the lane *is* the single owner of
transitions he asked for, without a new type.

Round 3 is the cap. If v3 doesn't converge, report it provisional, as design 26 did.

## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The design conserves “every terminal outcome names the session it may end,” but it lets a ban’s authority ride on a rotated access token and lets a pending-handle ceremony write identity state without a lease — so a stale 403 and a late provisioning token still cross the fence.

**Producer first:** The harm is a stale outcome ending, replacing, or redirecting a session it does not own. The producers are: (1) `_ingress` and `claimHandle` still assigning `state` directly from a ceremony’s return, so a ceremony that adopted before a sign-out can have its dropped `_publish` overwritten by the returned user; (2) `_settleSuspension` applying `isCurrent` (lease + access token) to `AccountSuspended`, so a 403 on an access token that rotated during a refresh is dropped and the banned session survives; (3) the `PendingHandle` branch writing `pendingHandleProvider` with no lease check, so a sign-out during the ceremony can be overwritten by a late provisioning token; (4) the refresh retry after timeout sending the same refresh token without an attempt id, so a late abandoned reply can rotate the island’s current token and force the next refresh to end the session. Each producer can be removed: (1) make `_publish` the only writer of `AppUser?` and delete direct `state =` assignments in `_ingress`/`claimHandle`; (2) ban checks lease only, or `endIf` ignores access token for bans; (3) pending writes carry the lease and drop if it moved; (4) do not retry a timed-out refresh until #452’s attempt id exists. Checks are not the answer; the writes must be unable to land.

**Fatal flaws:**
- **The one publish door is bypassed by `_ingress`/`claimHandle`** (design 27 §2b, §2c; flaw class: unremoved producer). The design says every show goes through `_publish(user, lease)`, but `_ingress` still does `state = await AsyncValue.guard(() => ceremony(prior))` and `claimHandle` still assigns `state` directly. If `_applyOutcome` adopts, then a sign-out moves the lease, `_publish` drops the user — and `_ingress` writes the returned user anyway. The fence is decorative until those direct writes are deleted.
- **Ban settlement uses the wrong fence predicate** (design 27 §2d; flaw class: wrong invariant). `isCurrent(credential)` requires both lease and access token. A 403 `AccountSuspended` is about the account, not the token. If a refresh commits between the banned request and settlement, the lease is unchanged but the access token is new; `isCurrent` is false, the ban is dropped, and the user stays signed in. Even if the flag is set, `endIf(credential)` re-checks `isCurrent` and fails to end. Bans must fence on lease alone.
- **`PendingHandle` is unfenced identity state** (design 27 §2b; flaw class: unguarded sibling write). `_applyOutcome`’s `PendingHandle` branch sets `pendingHandleProvider` without reading the lease. A sign-out or switch during the ceremony clears pending, then the late ceremony re-sets it. The router then drives a logged-out user to `/claim-handle`. The design’s one-door publish covers `AppUser?`, not this sibling state. Fold it into the same lease-fenced door.
- **The refresh-timeout residual is the design’s own harm** (design 27 §2f; flaw class: named residual that violates the invariant). The lease never moves on refresh, so the client fence cannot see a late abandoned reply. The island rotates, the app’s stored token becomes neither CURRENT nor PREVIOUS, and the next refresh ends the session. Shipping the deadline before #452 is a logout machine under slow links. Make #452 a prerequisite, or on timeout do not re-send the refresh token until the attempt id exists.
- **Two hidden second enders / missing state resets** (design 27 §2c, §2d; flaw class: incomplete removal). `_clearCredentialAndUnpair` currently calls `_tokens.clearTokens()`; if that remains, the teardown advances the lease again and the `_publish(null, lease: <end lease>)` drops. Also, `_settleSuspension` “with none” says “flag only” but does not reset `state` from `AsyncError(AccountSuspended)` to clean `AsyncData(null)`, so the router may not land on `/suspended` cleanly. State both explicitly.

**What holds:**
- The lease as a monotonic in-memory fencing token, never advanced by refresh, is the right shape.
- Deleting the transport’s logout listener and the `StreamController<void>` is the correct producer deletion.
- `adopt(..., since:)` in the serial lane fences the credential commit for sign-ins that actually reach adopt.
- `_endSession` holding `loading` from first step to last closes the sign-in-during-teardown window for new ceremonies.
- §2e’s switch order (end on disk before island move) and the named tradeoff are sound.
- §3’s table of enders is the right audit surface.

**If RECAST, what to fold back:**
- Make `_publish` the only writer of `AppUser?`; delete direct `state =` assignments from `_ingress` and `claimHandle`. They orchestrate, they do not publish.
- Split ban settlement from `Unauthorized`: `AccountSuspended` checks only `credential.lease == vault.lease` (or add `endIfLease`), and `endIf` for a ban ignores the access-token half.
- Fence `pendingHandleProvider` with the same lease door: the ceremony captures the lease before its first network call and the pending write drops if the lease moved.
- Make #452 a prerequisite for the refresh deadline, or on timeout do not retry the refresh token until the attempt id exists. Update test 12 to include a late abandoned reply landing after a successful retry.
- In `_settleSuspension` with no credential, explicitly reset `state = AsyncValue.data(null)` synchronously before flagging.
- State that `_clearCredentialAndUnpair` no longer calls `clearTokens()`; the ender is only `endIf`/`signOut`.

## CarnotCodeCarver's Design Strike (round 2)

**Verdict:** RECAST

**Summary:** Credential fencing improves substantially, but loading is still a shared presentation value masquerading as exclusive ownership. Old completions and overlapping ends can reopen admission or mutate shared resources. Dijkstra: "Simplicity is prerequisite for reliability." No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. The remaining entropy is in controller ownership.

**Producer first:** The harms are B losing its socket or cached identity to A's cleanup, an abandoned ceremony redirecting the current island, and admission reopening before a switch finishes. Late responses and storage delays are triggers. Our producers are independently completing operations that write shared controller state, sibling routing providers, cache and singleton resources without owning those destinations. Remove those producers through revocable attempt ownership and a single owner of session transitions. Credential comparisons remain necessary: remote outcomes cannot be prevented from arriving after replacement, and the vault must decide whether they still have authority.

**Fatal flaws:**
- Make stale work unable to reopen admission or clean up replacement resources: give one transition exclusive ownership until cleanup and configuration settlement finish, and retire ceremony publication authority synchronously when that transition starts; then state.isLoading admission checks become unnecessary. §2c blocks new ceremony starts but neither serializes competing ends nor revokes already running ceremonies. Two logout calls can both enter cleanup; the faster one publishes logged-out, B signs in, and the slower cleanup clears B's cache or disconnects its socket. The same overlap exists between a signal-driven cleanup and a person's end. A lease check at the final publish cannot undo those effects.
- The publication inventory still omits non-adopting outcomes. §2b handles authenticated success and SessionSuperseded, but cancellation, ordinary errors, PendingHandle and credential-free bans can complete without adopt ever checking the captured lease. A ceremony starts on island A; a switch begins; its late PendingHandle installs A's provisioning token, or its credential-free ban flags the destination suspended. Cancellation or AsyncError publication can also replace loading during teardown. §2d's assertion that a new sign-in requires a tap overlooks ceremonies already in flight. These outcomes need the originating attempt's revocable publication authority, including sibling providers.
- The fenced UI publish leaves the durable identity producer running. An adopted A can still be awaiting _writeCachedUser when logout clears the cache and B subsequently signs in. A's delayed write can replace B's cached identity; A's delayed failure fallback can clear B's successful write. Dropping A's final _publish does neither rollback nor isolation. refreshUser and saveProfile also retain userId-based fences, which cannot distinguish successive sessions of the same account. Make cached identity part of the owning session record or serialize its mutation under session ownership; the existing asynchronous cache writes remain outside both fences.
- Suspension has contradictory ownership. §2d flags suspended before _endSession, while the supplied _teardownResources clears suspended unconditionally. The design does not specify removal of that clear or a replacement transition that preserves the ban. Following the stated shared teardown therefore converts a current ban into ordinary login, restoring the loop suspension routing exists to prevent.
- The switch is not actually specified through the common teardown door. §2e lists signOut, unpair, preference save, invalidation and publication, but omits cached-user clearing, pending-handle clearing and explicit transport detachment. §2c simultaneously says every end uses _endSession, whose final logged-out publication would reopen admission before the switch saves its destination. Config invalidation may dispose some resources, but the bundle does not establish that it clears all routing and identity state. Define one transition whose ownership spans both cleanup and destination settlement.

**What holds:**
- Deleting the transport's logout authority removes a duplicate producer.
- Required credential provenance and atomic endIf comparison correctly distinguish stale access-token failures from current-session failures.
- adopt(since:) fences late credential adoption, and a lease-fenced publish closes the authenticated-success presentation gap.
- Persisting the end before moving the island preserves the accepted placement invariant and Nick's switch decision.
- The refresh deadline now has a defined scope, cancellation behavior and an explicitly acknowledged server-ordering residual. That accepted residual is not a new reason to reject this revision.
- Returning the ended credential by value and separating personal sign-out notifications are sound improvements.

**If RECAST, what to fold back:**
- Introduce explicit ownership for transitions and attempts. Concurrent ends join or queue behind the owner; only the owner releases admission after cleanup and island settlement. A session-scope object is one implementation, not a requirement.
- Retire an attempt's authority synchronously on end or switch. Route success, cancellation, errors, PendingHandle, credential-free suspension and sibling routing mutations through that authority.
- Bind cached identity to its session and island, and prevent retired work from writing or clearing the replacement's cache. Include refreshUser, saveProfile and _payOwedHandle in this ownership inventory.
- Make suspension a terminal transition outcome preserved through cleanup, rather than a flag that generic teardown immediately clears.
- Specify switch cleanup and final publication as one transition; retain the accepted durable-end-before-preference order.
- Add adversarial schedules for overlapping ends, late PendingHandle/error/cancellation during a switch, stale cache write and fallback-clear after B commits, and a current ban surviving complete teardown.


## MaxwellMergeSlam's Design Strike (round 2)

**Verdict:** RECAST (small)

**Summary:** v2 removes the producers round 1 named, but §2c's "closed admission" is stored in `state.isLoading`, a value that any publish can overwrite, so the door v2 relies on can be opened by the same race it was built to remove.

**Producer first:** v2 adds one new check, `_ingress` and `claimHandle` refusing while an end runs. The harm is a sign-in landing inside a teardown. The producer v2 removes is "the login screen is up while the teardown runs", and it removes it correctly by holding `loading` until step 4. But it represents "an end is running" as `state.isLoading`, and `state` has several writers: `_publish(null, lease)` from a superseded signal, `_settleSuspension`'s synchronous `data(null)`, and the switch's own publish. So the closed door is a value, not an ownership. Make it impossible: admission is an explicit count owned by `_endSession` and `switchIsland` (`_ending++` at step 1, `--` in a `finally` after step 4), and `_ingress`/`claimHandle` refuse while `_ending > 0`. Then no publish can reopen the door, and `isLoading` goes back to being presentation only.

**Fatal flaws:**
- **Make "admission reopens mid-end" impossible: an explicit end count, not `state.isLoading`.** (§2c, coupling to remove.) Here's the schedule. A refresh rejection's `SessionEnded(n)` and a switch run together. The signal's `_endSession` reaches step 4 and calls `_publish(null, lease: n)`. That lands, because the switch hasn't reached `signOut()` yet, so `vault.lease == n`. `state` is now `data(null)` with the switch still at step 3, so `_ingress`'s guard passes and a ceremony can start on the old island's config. §2b's lease fence would later supersede that ceremony's `adopt`, so no credential leaks. But the person sees `/login` flash mid-switch and starts a ceremony that's bound to fail. The design's claim "no sign-in can start between steps 1 and 4" is false as written.
- **A ban is about the account, so it must not use §2a's access-token currency.** (§2d, wrong reuse.) `isCurrent` requires the access token to match, which is right for a 401 (Tesla's flaw 7). But a 403 ban on a request carrying the pre-rotation token, under the same lease, is about the same account, and v2 drops it as "a session that already ended". The ban is then lost until the next authed call happens to 403 again. Fold: bans compare the lease only (`c.lease == vault.lease`). 401s compare both. State why: a token can be stale, but an account ban can't be.
- **`_restoreSession` doesn't `adopt`**, so "publish with the lease `adopt` returned" doesn't apply to it. (§2b, wording that a builder would mis-implement.) Restore publishes with the lease of the credential `present()` returned. Say so, or a builder will thread a lease that doesn't exist.

**What holds:**
- Producer 2 (show-before-done) is the right second producer, and both halves of the fix are removals: §2b's publish door makes a stale publish a no-op, and §2c's ordering removes the shared window.
- §2a's split is clean: `endIf` for signals, unfenced `signOut()` for the person, and `SessionEnded` only for ends the person didn't ask for. It resolves Tesla's §2c/§2f contradiction without a cause flag.
- The ended credential carried by value, with no `currentAccessToken()` in the teardown, removes flaw 5 rather than guarding it.
- `NotSignedIn` as a separate type makes the "missing stamp" state unrepresentable.
- §2f now tells the truth: lost replies are safe, a late landing is a named residual, #452 is the fix, and the bound sits on the request alone.
- §3's table leaves no unlisted ender. `deleteAccount` and the ban have doors.

**If RECAST, what to fold back:**
- §2c: "admission closed" becomes `_ending`, a counter incremented at step 1 and decremented in `finally`. `_ingress` and `claimHandle` check it. `state.isLoading` is presentation only. Add test: a signal end and a switch run together, and no ceremony starts until both finish.
- §2d: bans check the lease only, and the reason is stated. Add test: a ban on a pre-rotation token under the same lease still settles.
- §2b: `_restoreSession` publishes with its presented credential's lease.




## Tesla, the Arc-Prophet's Design Strike (round 2)

**Verdict:** RECAST

**Summary:** The lease is still the right name for a session, but three account-level endings were tuned to the access-token frequency that only a 401 sings in, so a refresh hides a living ban and a late delete shakes whoever signed in while it was in flight.

**Producer first:** The harm is a person signed out of a session they just entered, shown as signed in after the vault has let go, or left inside an account the island has already banned or deleted. The triggers stay outside us: a late 401, a late 403, a late 204, a keychain refusal, a refresh that rotates. The producers are ours.

A 401 applied to whatever session is current is deleted by keeping the only application inside `endIf`, comparing the access token on the lane. That compare stays. The island's 401 is untrusted input and will keep arriving after a rotation; nothing in the client stops the byte from landing. `adopt(since:)` stays for the same reason: the island has already minted the ceremony's session, so the single writer can only refuse the late write.

The screen showing a user the vault has already released is a second writer sitting behind `_publish`. `_ingress` and `claimHandle` assign `state` from `AsyncValue.guard` on the ceremony's return (§2b, and `auth_controller.dart` as it stands). That assignment is removable. One compare then remains, at the only door, because the island's `AppUser` is born outside the vault and can outlive it. A second check beside the guard is the wrong shape.

A ban or a successful delete applied to the wrong session, or dropped on the right one, is `isCurrent` and unfenced `signOut` used on an outcome they do not name. A 401 is about the access token that was presented. A ban and a delete are about the account, which survives the rotation that keeps the lease still. Both mis-wirings are removable: an account outcome carries the lease captured when the request was sent, and the vault commits flag-and-end in one turn of the lane, or commits neither. `signOut()` stays unfenced for a tap that has already closed admission synchronously — logout and the switch. It is the wrong tool for a reply that outlives that tap.

The refresh deadline guards a different harm, a hung `_flight` that never reconnects. Clearing the flight on cancel deletes that producer. The logout that can follow is a second producer: posting the same refresh token again after the abandoned attempt may have rotated. That post can be withheld until the attempt id in [aiko-chat-island#452](https://github.com/nickmeinhold/aiko-chat-island/issues/452). It was kept on purpose, as one forced sign-in. The check I will not forgive is test 12, which certifies the schedule where that logout cannot happen.

**Fatal flaws:**
- Make the resurrected face impossible: stop returning the user into `AsyncValue.guard`. §2b sends `_applyOutcome`, `claimHandle` and `_restoreSession` through `_publish`, and correctly says a sign-out in the `_writeCachedUser` gap moves the lease so the publish drops. The same section leaves the ceremony returning that user, and today's `_ingress` and `claimHandle` assign `state` from the guard when the future completes (`auth_controller.dart`, the guard assignment after `ceremony(prior)`, and `claimHandle`'s identical assignment). The drop and the assignment are the same write done twice, and the second one does not look at the lease. The vault is signed out; the screen shows A. Test 3 only catches this if it awaits the whole ingress. A unit test of `_publish` alone goes green and the resurrection ships. `claimHandle` is worse on the error path: §2b teaches only `_ingress` to swallow `SessionSuperseded`, so a claim that loses the race writes `AsyncError` over the logged-out state the end just published. `refreshUser` and `saveProfile` still assign `AsyncData` from their own returns (§2b's door list omits them). One door means the ceremony returns `void`.
- Make a living ban look ended, and the flag sticks when the end no-ops (§2d, §0 row 7). `isCurrent` requires the access token the vault would present now. That half is right for temper flaw 7, a 401 on a token a refresh has already replaced: the lease did not move, and ending would kill the session that rotated. A ban is the other frequency. Refresh keeps the lease and replaces the access token, and the account is still banned. §2d reads a failed `isCurrent` as "that session has already ended" and drops the ban, so a 403 for the pre-rotation token leaves a suspended account in chat until some later call happens to 403 again. The flag is worse. It is set from a synchronous `isCurrent` outside the lane, and `endIf` re-checks later inside the lane. Those two reads are not one moment. `_fly` writes `_state` only after `await _put`, so during the keychain write the controller still sees the old access token, flags `/suspended`, and queues `endIf`. The commit lands first, `endIf` returns null, no `SessionEnded` fires, and the flag is up on a session that is very much alive. Dismiss clears the flag and the vault walks them back in. `settleBan` is the ninth door §3's table forgot: it fabricates an `AccountSuspended` with no credential, and §2d's "with none, flag only" branch then does not end the session that is standing there.
- Make a late delete unable to end the successor (§2h, §3). `deleteAccount` sends the request while admission is open — the person is still signed in, which the request needs — and only on the island's 204 enters `_endSession` via unfenced `signOut()`. §2h says the deletion can only end the session that sent it, "because admission has been closed since its first step." The step that closes admission is inside `_endSession`, which runs after the await. A refresh rejection in that interval publishes logged-out and opens admission; a sign-in adopts; the 204 then means "whoever is here now." That is the producer this design exists to remove, wearing the person's door. Close it by capture: the lease (not the access token) taken at send, `endIf` on success, teardown only if that call ended something. A 204 for an account already left is a no-op. A refresh in between still matches, because the account's lease did not move.
- A `signOut` that throws latches `/splash`, so the sentence the person must see has no screen (§2c, §2e, §2g). The end sets `loading` as its first step and publishes logged-out as its fourth. §2g's disk failure rethrows from step 2, and the numbered steps have no release after that. The router stays on `/splash`, which has no "try again", while memory is ended and disk will restore the session on the next launch — the bug §2g says it is showing, played an octave higher. §2e has the same split: step 3 says the switch stops on `vault.end_unsaved`, and the invariant says the error is on `/login`, where the router lands only after a logged-out publish. Test 11 demands `/login`. The steps and the test name two different apps. The same end-picture omits `pendingHandle`. Today's teardown clears it because an uncleared pending outranks `/login` and wedges the router on `/claim-handle`. §2c's replacement steps never clear it.
- Test 12 mutes the residual §2f just named. "Two timeouts in a row followed by a success stay signed in" is true when the cancel happens before the bytes leave. The shatter is the other timing, which §2f itself writes down: attempt A is already on the wire, retry B rotates first, A's late landing mints over the token the app stored, the next refresh is `RefreshReused`, the session ends. A test that cancels before send goes green and certifies the logout machine as transient. Split the schedule. Pre-send cancels stay signed in. An on-wire abandon followed by a retry is asserted as the one forced passkey sign-in, until [aiko-chat-island#452](https://github.com/nickmeinhold/aiko-chat-island/issues/452).

**What holds:**
- §0's diagnosis holds under load. Terminal outcomes were travelling without the session they were born under, and showing a new state before the last step finished is the second producer. Stamping the credential, and closing admission synchronously before any await of an end the person asked for, is the right shape.
- The access-token half of `isCurrent` holds for a 401. A refresh leaves the lease still, so a corpse token that carries the current lease must not end the session that rotated. Test 7 plays the note that round 1 found missing. `NotSignedIn` as its own type holds: a missing stamp can no longer read as "end nothing."
- `adopt(..., since:)` inside the lane holds. The lease is read before the network call, the lane is not held across it, and the compare happens at the commit. A ceremony that read the pre-end lease cannot land after the end.
- Deleting the transport listener holds. A rejected socket refresh already ends inside `vault.refresh` and can emit once. A socket with no credential is not an end. `disconnect()` staying a synchronous detach holds as a fact about the transport; the new session's channel is safe while admission stays shut until that detach has returned.
- Unfenced `signOut()` holds for `logout` and for the switch. The person means whatever is here at the commit, and §2c closes admission in the same synchronous turn, before the vault is touched. Capturing the lease at the tap would be a second mechanism for a window that close already removes. `signOut` emitting nothing holds with that, once the failure path actually reaches a screen: the person's disk error must not be eaten by `SessionEnded`.
- §2e's order holds. The island moves only after the end is on disk. A failed tombstone leaves the old record on the old island. A failed save after a landed tombstone leaves them signed out where they were. [aiko_chat_app#447](https://github.com/nickmeinhold/aiko_chat_app/issues/447) race 4 is still not a harm: a session on the island being left is part of what the switch asked to end, and §2b fences a commit that arrives after that end.
- The in-process lease, the abandoned island session, and the deadline living on the refresh request alone (the shared bare client stays untouched) all hold. Carnot's session-scope object still does not need to come back: the credential is carried by value, and this round's leaks are mistuned outcomes and a second writer, not a singleton the lease cannot name.

**If RECAST, what to fold back:**
- §2b: the ceremony returns `void`. `_ingress` and `claimHandle` await it for control flow only. `SessionSuperseded` is swallowed on both doors and writes nothing. `_publish` is the only assignment of auth state, including `refreshUser`, `saveProfile` and the optimistic branch of `_restoreSession`. Test 3 awaits the ingress, not the door in isolation.
- §2d and §0 row 7: split the predicate. A 401 ends only when the access token is still the one presented. A ban ends when the lease is still current, even if the access token has rotated. Flag and `endIf` are one turn of the lane: the vault returns whether it ended the session, and the flag is set only from that result. A failed re-check leaves no flag. `settleBan` takes the credential of the call that learned the ban and is a row in §3. A sign-in ban with no credential flags and publishes logged-out, and leaves no `AsyncError`.
- §2h: capture the lease at send, close nothing by `signOut`. On 204, `endIf` that lease. Teardown runs only when it ended something. A successor adopted during the request has a newer lease and is untouched. Say this in §3, where `deleteAccount` currently points at `signOut()`.
- §2c, §2e, §2g: `signOut`'s throw still publishes logged-out with "Couldn't finish signing out. Try again", and does not save the island or invalidate config. `/splash` is released on that path. Every end publishes a full logged-out picture: pending handle cleared; the suspended flag cleared on logout, switch and signal ends; the ban path sets the flag from the lane result and the later publish leaves it set. Emit `SessionEnded` after the serial turn returns, so a handler that touches the vault cannot wait on the lane from inside the lane.
- §2f / test 12: two sentences, two schedules. Cancels before the bytes leave, then a success, stay signed in. A request already on the wire, then a retry that wins, is the named one-time sign-in. Do not let one test assert both.



---

# Round 3 — dt-1794798238, v3 @ b1d1980 (the cap)

**Round-3 verdict:** RECAST from Noether, Carnot and Tesla. Maxwell said SOUND, and **that
vote is withdrawn**: Carnot and Tesla independently found the echo (flaw R3-1) in sections the
author wrote and then graded. That's the self-review blindness this panel exists to catch.

**Disposition: CONVERGED AT THE CAP → v3 + v3.1 requirements** (the design-26 precedent, and
Nick's 2026-08-23 cap ruling). At round 3 the question is whether the design is shrinking
toward the fix, not whether there are more findings. It is:
- round 1 found ten flaws across two layers;
- round 2 found eight, one shape (the controller's unsequenced writers);
- round 3 found **no new layer and no new shape**. Every finding sits inside the lane's own
  life cycle, and four of the six fixes *delete* something.

No round 4. The v3.1 requirements below bind the build. The PR B cage-match is the next gate,
and it checks each requirement by its named test.

## Round-3 flaws (deduped; each checked against v3's text or the source)

- **R3-1. The echo: an end announced twice, and the second announcement erases the ban.**
  Raised by Carnot and Tesla. CONFIRMED in v3 §2a/§2d. `endIf` and `endIfLease` emit
  `SessionEnded(L+1)`. The calling transition settles (`suspended: true`). The queued event
  then passes `vault.lease == L+1`, tears down again, and writes `suspended: false`. Every
  authed ban loops back to `/login`. The 401 and delete doors unpair and disconnect twice.
  **Fold, by deletion:** `endIf` and `endIfLease` emit nothing. `SessionEnded` belongs to
  `_fly`'s rejection alone, the one end with no caller waiting.
- **R3-2. The lease is checked when a transition starts, not when it writes.** Raised by
  Noether and Carnot. CONFIRMED against v3 §2b. A body awaits a cache write while `_fly`'s
  rejection, an independent writer, ends the session. The body then publishes a user who's
  gone. **Fold:** the picture is written in one synchronous run that starts by re-reading
  `vault.lease`. A sign-in commit uses the lease `adopt` returned. Dart's single thread makes
  that read and the write atomic. The end that moved the lease is already queued behind, and
  it clears the cache.
- **R3-3. An attempt's life cycle was undefined.** Raised by Noether, Carnot and Tesla.
  CONFIRMED in v3 §2b/§2d:
  - a commit never consumed its own attempt, so after a cancel or an error, admission stayed
    shut;
  - "if nothing was ended, write nothing" left a person's logout during a first sign-in, on an
    empty vault, stuck on `loading`;
  - an end retired "whatever attempt is current", including one begun after the end.

  **Fold:** every commit consumes its own attempt, whatever the outcome. An end retires the
  attempt captured when the end was *issued*. A person's end always writes its logged-out
  picture, whether or not a credential existed. `_transition`'s `finally` writes a terminal
  picture for an attempt that's still current (Tesla), so `loading` can't outlive its attempt.
- **R3-4. One picture, four notifications.** Raised by Tesla. CONFIRMED: the existing comment
  at `auth_controller.dart:391-396` records that the router reacts to each provider on its own.
  **Fold:** the router watches **one session value** (`state`, pending, suspended), assigned
  once. The flag-before-state ordering convention is deleted.
- **R3-5. Boot restore inside `build()`.** Raised by Noether and Maxwell. **Fold:** `build()`
  returns a not-yet-known state. Restore does `present()`/`me()` outside the lane and commits
  through a transition, so the lane is never held across a network call.
- **R3-6. `_payOwedHandle` runs after `adopt`, and it's a network call.** Raised by Tesla.
  **Fold:** it's its own transition, for the lease `adopt` returned, with the network call
  outside the lane. A 403 there is the ban picture.
- **REFUTED: R3-x, a switch's unfenced `signOut()` ends a newer lease** (Noether). A newer lease
  can only come from `adopt`, which commits through the controller's lane, and the switch holds
  that lane. So `signOut()` inside the switch can end only the switch's own session, or nothing.

The build requirements are in the design, §6 (v3.1).

Bundle: v3 + this record (rounds 1-2) + `session_vault.dart` + `auth_controller.dart` (168 KB). All four seated. Arrival order, NOT a ranking.

## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The invariant at stake is that every write to what the app shows is conserved under the lease that authorized it; v3’s transition lane checks the lease at admission but not at commit, so a vault end during the body can still publish a picture for a session that no longer exists.

**Producer first:** The bad outcome is a stale picture: the app shows or caches a session the vault has already ended, or a new sign-in is silently cancelled by an old end. The trigger is external (a late refresh rejection, a ban, a socket death), but the producer is ours: the transition lane’s single admission check plus a body that awaits local writes or the vault lane while the vault’s independent lane advances the lease. The producer is removable. Make the final picture write a synchronous run that begins with `if (vault.lease != lease) return;`, and for `adopt` use the returned lease and re-check it before any side effect. Make boot restore do its network call outside the lane and commit through the same re-check. Then the check is not a better guard; the stale write is structurally unable to land.

**Fatal flaws:**
- **The transition lane checks the lease at admission, not at commit** (§2b, §2c, §3). The body may await `adopt`, `_writeCachedUser`, or other local writes. During those awaits the vault can advance the lease (a signal end, a ban, a refresh rejection). The transition then writes the picture without re-checking. Test 3 expects no cached A when a sign-out happens between `adopt` and the cache write, but the design provides no mechanism to prevent it. The fix is to make the picture write a synchronous run that begins with a lease re-check, and to skip any side effect (cache write) if the lease moved.
- **Boot restore is not integrated with the transition lane** (§2c). `_restoreSession` is called by `build()`. In an `AsyncNotifier`, `build()` returns the initial state; you cannot write `state` via a transition before `build()` returns. If `_restoreSession` holds the lane during `me()`, it violates Rule 2 (network outside the lane) and blocks all other transitions. If it does `me()` outside and then queues a commit transition, the design must say so and must include a commit-time lease check. As written, a signal end during boot `me()` can be overwritten by the restore publishing a signed-in picture.
- **A `SessionEnded` end transition can cancel a sign-in that started after the vault end but before the event was processed** (§2d, §2b Rule 3). The event carries the lease advanced *to* (n). A new sign-in begin that runs before the end transition reads the same lease n (because the vault already advanced) and takes an attempt. The end transition then runs, checks `vault.lease == n`, passes, and clears the current attempt. The new sign-in is cancelled. The design’s admission rule does not prevent this because the end transition is not yet running when the begin runs. The end transition must not retire an attempt created after the vault end.
- **The attempt’s own commit does not clear the attempt** (§2b Rule 3). The design says “Any later end, switch or sign-in clears the current attempt,” but the commit itself is not a later end/switch/sign-in. If the commit does not clear the attempt as part of its picture, admission remains closed forever. This is a state-machine hole that must be stated explicitly.
- **`signOut()` is unfenced and used in the switch transition** (§2f). If the vault lease advances during the switch transition (e.g., a refresh rejection in the vault lane runs before the switch’s `signOut()`), the unfenced `signOut()` ends the new lease. The switch was for the old lease. This is redundant in the common case, but it means the switch transition’s initial lease check is not sufficient to prevent it from acting on a lease that is no longer current. For the switch, use `endIfLease(lease)` or re-check the lease immediately before `signOut()`.

**What holds:**
- The vault lease as a monotonic, in-process fencing token advanced only by `adopt` and `_end`, never by refresh.
- Deleting the transport’s logout listener and the `StreamController<void>` removes a duplicate producer.
- `adopt(..., since:)` inside the vault’s serial lane correctly fences the credential commit.
- The split between `endIf` (lease + access token for 401s) and `endIfLease` (lease only for account outcomes) preserves the 401-vs-ban distinction.
- The switch order: end on disk before the island moves, with the named tradeoff that a failed save signs out.
- The refresh deadline’s scope (per-request, not on the shared bare client) and the named residual until island #452.
- The `SessionEnded` stream emitting after the vault lane turn, avoiding a re-entrant deadlock.

**If RECAST, what to fold back:**
- §2b: state that every transition’s picture write is a single synchronous run that begins with `if (vault.lease != lease) return;`. For sign-in commits, use the lease returned by `adopt` and re-check it before the cache write and before the picture.
- §2c: specify the boot path. `build()` returns an initial loading/unknown state, then queues a restore transition that does `present()` and `me()` outside the lane and commits with a lease re-check. Do not hold the transition lane across `me()`.
- §2d: state that a `SessionEnded` end transition must not retire an attempt that was created after the vault end. Either have the begin transition read a lease that cannot equal the post-end lease (e.g., the event carries the ended lease and the controller compares the current attempt’s start order), or ensure the end transition is queued before any new begin can run.
- §2b Rule 3: state explicitly that a sign-in commit clears the current attempt as part of its picture.
- §2f: for the switch, replace unfenced `signOut()` with `endIfLease(lease)` or add a synchronous lease re-check immediately before `signOut()`; if the lease has moved, drop the switch and write nothing.

## CarnotCodeCarver's Design Strike (round 3)

**Verdict:** RECAST

**Summary:** The transition lane removes much of round 2's wasted machinery, but it does not yet establish one authority: vault ends can bypass it, controller ends generate duplicate settlements, and ending an empty vault can leave an attempt alive. Dijkstra: "Simplicity is prerequisite for reliability." No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. Here, entropy still crosses the boundary between the two lanes.

**Producer first:** The harms are showing an identity after its session ended, erasing a ban with a second settlement, and leaving login stuck after the person cancels an in-flight sign-in. Late responses and storage delays are triggers. Our producers are an asynchronous transition that checks authority only on entry, two consumers publishing the same vault end, and treating 'no credential ended' as 'no controller work remains.' These producers can be restructured as described below. Remote credentials and outcomes still require fencing: the app cannot prevent their arrival after replacement. That justifies adopt(since:), token-sensitive 401 settlement and lease-sensitive account settlement; it does not justify duplicate publishers or incomplete retirement.

**Fatal flaws:**
- Make duplicate settlement—and a ban being erased by its own end event—impossible: give each vault end exactly one controller settlement owner; then overlapping-end suppression is unnecessary for that duplicate. In §§2d–2e, the ban transition calls endIfLease(L), which advances the vault to L+1 and emits SessionEnded(L+1). The original transition tears down and publishes suspended:true. Its queued event then passes _transition(L+1), tears down again and publishes suspended:false because the event has no ban outcome. No successor sign-in is needed. Test 12's ban therefore becomes ordinary login, and test 7's 'one teardown' is false for a controller end plus its notification. Carry the terminal outcome through one authoritative settlement path, or make the initiating transition the sole settlement owner.
- The controller lane does not exclude the vault's independent terminal writer. §2b checks vault.lease before an asynchronous body, but WSS/REST refresh rejection can advance that lease while the body awaits a cache write. For example, refreshUser's success transition enters under L and awaits its cache write; an independent refresh rejects and ends L; the transition resumes and publishes the user after the session ended. The SessionEnded handler is queued behind it. Serial controller writers do not make the entry check valid across an await. Make identity publication derive from current authority, with retirement invalidating publication, or provide an explicit common ordering boundary for terminal retirement and publication. The named deadlock check proves absence of a wait cycle, not this safety property.
- Ending a credential and retiring an attempt are different operations, but §2d conflates them. Start sign-in with an empty vault, then invoke logout before the ceremony completes. signOut advances the lease but returns no ended credential. Step 1 says 'If nothing was ended, stop and write nothing,' so the attempt remains current and loading remains published. Its eventual commit drops because the lease moved. The app can remain stuck indefinitely. PendingHandle abandonment has the same empty-vault problem. Make every accepted personal end retire the controller attempt and publish its complete logged-out picture; credential-dependent teardown is only one part of that transition.
- Attempt completion is unspecified. Admission requires 'no attempt is current,' but §2c's cancellation, error and PendingHandle pictures do not retire the attempt. Rule 3 names only a later end, switch or sign-in as retirement—and a later sign-in cannot pass admission while that attempt remains current. Thus cancellation can prevent retry, and PendingHandle can prevent claimHandle's begin. Define attempt completion as consuming its authority in the same transition that publishes every outcome, including successful adoption. Do not add another admission exception.

**What holds:**
- The controller transition lane is a useful simplification. A session-scope object is not required merely to serialize controller-owned cache writes, teardown and island settlement.
- Required credential provenance, separate NotSignedIn, token-sensitive endIf and lease-sensitive endIfLease correctly distinguish token rotation from account replacement.
- Deleting transport unauthenticated as a logout authority removes a duplicate producer.
- Returning the ended credential by value removes teardown's dependency on an already-cleared vault.
- The durable-end-before-island-save order preserves Nick's accepted decision.
- The refresh deadline's scope, cancellation behavior and late-arrival residual are now explicit. The split tests acknowledge that residual; it is not a fresh objection in this strike.

**If RECAST, what to fold back:**
- Choose one settlement owner per vault end and preserve its terminal reason. Test a current ban through both the initiating door and delivery of its actual SessionEnded event: one teardown, suspended remains true.
- Specify the ordering between independent vault retirement and controller publication across local awaits. Test refresh rejection during a delayed refreshUser/saveProfile cache write.
- Separate controller retirement from whether a credential existed. Test logout during the first sign-in and logout from PendingHandle with an empty vault.
- Consume each attempt on every completed outcome. Test cancel→retry, error→retry and PendingHandle→claimHandle.
- Keep the lane design, but make these ownership rules explicit before calling it one session authority. A third-round cap limits review rounds; it does not supply the missing invariant.


## MaxwellMergeSlam's Design Strike (round 3)

**Verdict:** SOUND (with three build notes, none fatal)

**Summary:** v3 finally puts the controller under the rule the vault already obeys, one serial writer checking a lease, and I can't find a schedule in rounds 1-2's inventory that it doesn't remove. What's left is wording a builder could misread, not a producer left running.

**Producer first:** v3 adds no new check beside a producer. It moves every write of the four pieces of session state into `_transition`, which is a producer *removal*: an unordered writer becomes unrepresentable, not guarded. The one check it adds, `vault.lease == lease` at the start of a transition, exists because outcomes are born outside the app (a ceremony's reply, a 403, a 204) and can arrive after their session ends. That trigger can't be removed. The producer that turned it into harm, a writer that didn't name its session, is gone. The vault's two predicates (`endIf` for token outcomes, `endIfLease` for account outcomes) answer two different questions, so they aren't a check duplicated. Round 2's ban finding is answered by the split, not by a guard.

**Fatal flaws:**
- None. Round 1's ten and round 2's eight each map to a section of v3, and §3's table lists every writer the grep found (`:355-1043`).

**Build notes (fold as wording, not re-strike):**
- **Admission must say "logged out and no attempt current".** §2b defines admission as "no attempt is current", but a committed sign-in clears its attempt, so a signed-in app reads as admissible. Today's `_ingress` also requires `state.value == null`. Keep that half.
- **`_restoreSession` runs inside `build()`.** Riverpod takes `build()`'s return value as the state, so the restore transition's picture must be *returned* through `build`, not assigned. Any transition queued during build (a `SessionEnded` from the listener `build` registers) runs after it, which the serial lane already guarantees. Say so, or a builder will assign `state` inside `build` and race its own return.
- **"Written together in one synchronous run" can't include the cached user**, which is an awaited disk write. Rule 1 should read: disk effects first, inside the body; then `state`, `pendingHandle` and `suspended` together, with no await between them.
- **Named, not new:** a 401 that survives a successful refresh on a chat call (outside the controller) ends nothing, today and under v3. Only refresh rejection and the controller's own calls are doors. That's unchanged behaviour, so §4 should name it rather than leave it implied.

**What holds:**
- The two-layer diagnosis (§0): nameless outcomes at the vault, unordered writers at the controller. The fix is the same mechanism at both layers.
- Rule 3, attempts retired by the next transition, collapses round 2's whole publication inventory (success, cancel, error, `PendingHandle`, sign-in ban) into one check.
- Account outcomes compare the lease only, and token outcomes compare both. The flag comes from the lane result, so the ban can't flag a live session or drop on rotation.
- The switch is one transition with one invariant. Nick's two decisions are still intact.
- §2g and tests 18/19 tell the truth about the residual, and task 89 holds the decision.
- The deadlock argument (the vault never awaits the controller, and emits after its turn) is correct for the calls named.



## Tesla, the Arc-Prophet's Design Strike (round 3)

**Verdict:** RECAST

**Summary:** The lane is tuned true, and then `SessionEnded` sings the post-end lease again and damps the ban out of the picture, so a banned account at 3am loops sign-in, 403, login wall.

**Producer first:** The harm is a person on `/login` after the island has already banned the account, or staring at splash while the vault holds a session it just stored. The late 401, the late 403, the late 204, the keychain refusal, and the refresh that rotates are triggers. They will keep arriving.

Two checks stay, because the producer is not ours to delete. The island mints the ceremony's session before `adopt`, so `adopt(..., since:)` can only refuse the late write. A 401 can name a token a refresh has already replaced, and a refresh does not move the lease, so `endIf` on the vault lane, comparing that access token, stays. A further check in front of either of those is the wrong shape.

Two producers are ours, and both can be removed.

The first is a second picture of one end. `endIf` and `endIfLease` advance the lease and emit `SessionEnded` carrying the lease advanced *to* (§2a). The caller is already inside the end transition that tears down and pictures (§2d, §3). The listener queues another transition for that same post-end lease. §2b's `vault.lease == lease` passes, because that number is the live lease. §2d's "the second finds the lease already moved and drops" is tuned to a *pre-end* stamp. The echo is the other harmonic, so the drop never fires. Delete the emission on ends the controller called. `_fly`'s rejection is the one end with no caller waiting. It alone emits, and it alone pictures. The drop-check then has nothing left to judge.

The second is `loading` with no last frame. A begin publishes `loading` and takes an attempt (§2c). The commit's picture sits after `adopt` and a fallible cache write, and a dropped commit writes nothing (§2b). A throw there leaves the attempt current, the router on `/splash`, and a session already on disk. Put the attempt's terminal picture in `_transition`'s `finally`. The cache write stays best-effort, after the picture exists. A splash watchdog is then unnecessary.

The same shape, one octave down: Rule 1's "one picture" is four notifier writes. This controller already records that `suspended` and `state` each notify the router on their own. One session value, one assignment, and the field-order convention goes away.

**Fatal flaws:**
- Make the second picture impossible: `endIf` and `endIfLease` return the ended credential and emit nothing. `SessionEnded` belongs only to `_fly` (§2a, §2d, §3). As written, every authed ban — restore, `refreshUser`, `saveProfile`, `_payOwedHandle`, `settleBan(lease)` — pictures `suspended: true` from `endIfLease`'s return, and the echo is already queued behind it. The event is added when the vault turn returns, while that transition still holds the controller lane, so the echo is the next turn of the same lane, every time. The echo's picture is `suspended: false`, because a `SessionEnded` carries a lease and a credential and no ban (§2a), and step 3 sets the flag only "for a ban" (§2d). Test 12 passes if it returns before the stream drains, and fails once the queue runs. The standing wave is adopt, 403, flag, echo, `/login`, sign-in again. `/suspended` never becomes a place they stay. A sign-in ban with no session (§2c) survives only because it never touches the vault. A ban after `adopt` does, and the echo eats it. The under-counted radius is the other two emitting doors, the 401 and `deleteAccount` (§3): a second unpair of the same credential and a second `disconnect()`. Test 7 cannot see them. The "second end" it queues still carries the pre-end lease, and that one does drop. Three doors emit. The switch and the person's `signOut` stay silent (§2f, §2h), which is why those two hold on the note that shatters the other three.
- Make a begin's `loading` unable to outlive its attempt (§2b, §2c). `adopt` advances the lease, then the body writes the cached user, then it pictures. A throw from that write skips the picture, `finally` only releases the lane (§2f states that for the switch), and admission is "no attempt is current," so the attempt that is still current keeps the door shut. The session is on disk. The screen is `/splash` until the process dies. `_payOwedHandle` is the same interval, and §2c never names it. The pay uses the vault-backed client, so it can run only after `adopt`. Held inside the commit, the lane sits across a round trip. Run after the commit as a bare assignment, and the ceremony is a writer of `state` again, the producer round 2 deleted. It needs its own transition, issued for the lease `adopt` just returned.
- Make the half-picture unrepresentable (§2b Rule 1). Four providers in one synchronous block are still four notifications. The router in this controller hops on the intermediate `(logged out, suspended: false)` — the file says so beside `_settleSuspension`. That tuple is `/login`, the front door of the loop. The echo then commits it. One value, one assignment.

**What holds:**
- §0. Terminal outcomes were travelling without the session they were born under, and the controller had a crowd of writers. The lane is the vault's shape, lifted one storey, and it is the right shape.
- The split predicate. A 401 is the access token (`endIf`). A ban and a delete are the account (`endIfLease`). A refresh keeps the lease still, so it can no longer hide a ban, and a successor on a newer lease stays untouched.
- The ended credential by value. Teardown does not call `currentAccessToken()`.
- Unfenced, silent `signOut()` for logout and for the switch. The disk error reaches `/login` because that path emits nothing (§2h). §2f's order holds: the tombstone lands, then the island moves, and a failed tombstone leaves home where it was. Race 4 stays a non-harm.
- Deleting the transport listener. A rejected socket refresh ends inside `_fly`. A socket with no credential is not an end. `disconnect()` detaches synchronously, so the lane can cover it.
- `adopt(..., since:)` on the vault lane, the lease read before the network call, the lane free across that call for an ordinary ceremony.
- The in-process lease, the abandoned island session, the owed-handle store outside the lane, and the refresh bound on the one request, with both schedules named (tests 18 and 19). The on-the-wire residual stays Nick's until the attempt id in https://github.com/nickmeinhold/aiko-chat-island/issues/452.
- Emitting after the vault turn returns. The handler stays off the vault lane. That timing stays. It is what makes the echo the next picture rather than a deadlock.

**If RECAST, what to fold back:**
- §2a and §3: `endIf` and `endIfLease` return the credential and emit nothing. `SessionEnded` fires only from `_fly`. The listener is that row alone. Remove the claim that a queued second end drops because the lease moved.
- §2d step 3: the ban picture is written once, by the transition that called `endIfLease`, from that call's return. After the event loop drains, `suspended` is still true. Test 12 waits for that drain. Test 7 includes the listener and asserts it does not teardown a ban, a 401, or a delete the caller already settled.
- §2b: an end retires the attempt id captured when the transition was *issued*, not whatever attempt is current when the picture runs. A begin that the queue runs first, under the post-end lease, keeps its attempt. `_transition`'s `finally` always leaves a terminal picture. A throw after a successful `adopt` still pictures the user and clears the attempt that commit owns. The cache write is best-effort and follows the picture.
- §2c and §3: `_payOwedHandle` is its own transition, for the lease `adopt` returned, network outside, picture inside. A 403 there is the ban picture.
- §2b Rule 1: the router watches one session value. `state`, `pendingHandle`, `suspended`, and the cached user are fields of that single assignment.

