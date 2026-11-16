# 27-TEMPER.md — design 27, one session authority

**Overall verdict:** RECAST (round 1 of at most 3), 4 of 4 families RECAST, none DISSOLVE.
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
   `gateway_rest_api.dart:944,964`). §2e states what a second consecutive timeout does, based
   on the island's answer. Until https://github.com/nickmeinhold/aiko-chat-island/issues/452
   lands, if a retried PREVIOUS rotates again, the deadline ships with "no new rotation after a
   timeout until the next foreground". This is NAMED TRADEOFF, owner app tab.
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

RECAST: fold flaws 1-9 into design 27 as v2 and re-strike (round 2 of at most 3). Before the
re-strike, ask the island tab flaw 8's question (what a PREVIOUS retry returns).

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

