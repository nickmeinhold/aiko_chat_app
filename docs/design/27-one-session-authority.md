# Design 27: one session authority

**Status:** draft v2, 2026-11-16. v1 was struck RECAST 4/4 (`27-TEMPER.md`, run dt-1794795469).
This version folds its flaws 1-9. It's due for temper round 2 of at most 3. Opens PR B of
design 26 (task 77).
**Closes:** https://github.com/nickmeinhold/aiko_chat_app/issues/447, two cases deferred to it
from the cage-match of https://github.com/nickmeinhold/aiko_chat_app/pull/453 (round 2), and that
PR's deferred refresh deadline (round 1).
**Builds on:** the session vault (design 26 §2c, merged as `f7f4c2d`).
**Decided by Nick (2026-11-16):** §2e's switch order, and that #447 race 4 as written is not a
harm.

**Touches a trust boundary:** which session an operation is allowed to end, restore, replace or
*show*.

## 0. The producer question: what lets an operation from an ended session still change the current one?

**The harm.** An operation that started under one session does one of these:
- ends a later session (a stale logout signs out the person who signed in since);
- brings back an earlier one (a late sign-in revives a session the person left);
- *shows* one that isn't there (the screen says signed in, and the vault says signed out);
- sends a session to an island that didn't issue it.

**What produces it.** Two things, and v1 named only the first.

1. **Terminal outcomes travel without saying which session they belong to.** Each place below
   hands on an outcome that once named a session, but drops the name on the way:

| # | Where | What it carries | What it should carry |
|---|---|---|---|
| 1 | A sign-in's late `setTokens` (#447 race 1) | tokens | the lease the attempt started under |
| 2 | `authEventsProvider` (#447 race 2) | `void` | the session the vault ended |
| 3 | The transport's `ConnectionState.unauthenticated` (#447 race 3) | a state | nothing: it isn't an end |
| 4 | `Unauthorized` from `_authedCall` (Carnot, #453 round 2) | a status code | the credential that got the 401 |
| 5 | `_restoreSession`'s `on Unauthorized` → `clearTokens` | nothing | the same as 4 |
| 6 | `switchIsland` moving the island (Noether, #453 round 2) | an order of steps | "the end is on disk" before "the island moved" |
| 7 | **A ban**: `AccountSuspended` → `_settleSuspension` (temper flaw 2) | `state.error` | the credential that got the 403 |

2. **The app shows a new state before its last step has finished** (temper flaws 1 and 3). Two
   shapes:
   - **An end publishes signed out, then tears down.** `logout()` and `_becomeUnauthenticated`
     put the login screen up first, then await the unpair, the cache clear and the disconnect
     (`auth_controller.dart:810-813`, `:1041-1044`). A sign-in that lands in that gap gets its
     own credential unpaired and its socket closed.
   - **A sign-in commits, then publishes, with a wait in between.** `_applyOutcome` awaits
     `setTokens`, then `_writeCachedUser`, then returns the user that `_ingress` publishes
     (`:658-662`, `:356`). A sign-out in that gap leaves the screen showing a user the vault
     no longer holds.

**Removing them.**
1. Every outcome that isn't the person's own action carries the credential it was about. The
   vault applies it only while that credential is still current.
2. **Nothing new can be admitted until an end is complete, and nothing is shown unless it's
   still current.** Every end holds `loading` from its first step to its last. Every publish
   goes through one door that checks the lease.

Neither part needs a new object: it's the vault with no unfenced door for signals, and the
controller with one door for what it shows.

### A hazard I suspected, and checked: it doesn't happen

The no-credential path in row 3 looked like design 26's harm still reaching `main`: the door for
a guessed island returns null, the transport calls `_setUnauthenticated()`
(`gateway_transport.dart:343-347`), and the controller's teardown writes signed out over another
island's record. **It can't fire at boot.** The transport's only `connect()` comes from
`chatRepositoryProvider` (`chat_providers.dart:733`), which needs a signed-in user. The wake
kicks are ignored until something has asked to connect (`reconnectNow`'s `_wantConnected`
guard). Row 3 is still closed, for race 3's sake, by deletion (§2c).

## 1. Facts this rests on

- **The vault is the only writer** of the session (design 26 §2c). Every end goes through
  `_end`, and every new session through `adopt`.
- **A `Credential` already names its session.** It carries `(accessToken, lease)`
  (`session_vault.dart:161`). `vault.refresh` already compares both: a stale lease is
  superseded, and a stale access token gets the newer credential (`:186-191`).
- **The lease is in memory only.** It starts at 0 in each process and advances on `adopt` and
  on `_end`, never on a refresh. Nothing persists one.
- **A switch saves the new island before it ends the session** today (`switchIsland`).
  Design 26's placement rule 2 reads that saved island.
- **The auth controller listens to `ConnectionState.unauthenticated`** as its own logout trigger
  (`auth_controller.dart:197-201`).
- **`_ingress` refuses to start while `state.isLoading`** (`:353`). `claimHandle` has no such
  guard (`:677`).
- **The transport's `disconnect()` doesn't await the close.** It detaches the channel
  synchronously and closes it without waiting (`gateway_transport.dart:214-226`), so a teardown
  that calls it finishes in local time.
- **`buildGatewayBackend`'s bare Dio has no timeouts and is shared.** The refresh uses it, and
  so does `GatewayRestApi` for its unauthenticated calls (`gateway_rest_api.dart:944,964`).
- **Island refresh rotation** (`aiko-chat-island/src/aiko_gateway/domain/auth_session.py`):
  - presenting CURRENT (`:163-166`) moves it to previous and mints a new current;
  - presenting PREVIOUS (`:167-170`) mints a new current and leaves previous alone;
  - anything else ends the session.

  Lost replies are therefore always recoverable. A request that lands *after* a later one is
  not (§2f).

## 2. The design

### 2a. The vault: one fenced end for signals, one unfenced end for the person

- **`int get lease`**: the current lease. Read synchronously.
- **`bool isCurrent(Credential c)`**: synchronous. True when `c.lease == lease` and `c`'s access
  token is the one the vault would present now. The access-token half matters (temper flaw 7):
  a refresh doesn't move the lease, so a 401 on an access token already rotated away must not
  end the session that rotated it.
- **`Future<Credential?> endIf(Credential presented)`**: runs in the serial lane. Ends the
  session only if `isCurrent(presented)` holds there. Returns the credential it ended, or null.
- **`Future<Credential?> signOut()`**: the person's own sign-out, or a switch. It stays
  unfenced, because it means "whatever is here now". It returns the credential it ended.
  (v1's "capture the lease at the tap" proposal was withdrawn: §2c's closed admission removes
  the window it was for.)
- **`adopt(island, tokens, {required int since})`** throws `SessionSuperseded` when the lease
  has moved since `since`. It returns the new lease.
- **`Stream<SessionEnded> ended`**: emitted for every end the person didn't ask for. That's a
  refresh rejection inside `_fly`, and every `endIf` that ended something. `SessionEnded`
  carries the lease the vault advanced *to* and the credential it ended, by value. **`signOut()`
  emits nothing**, because the person's path renders its own outcome (§2g, temper flaw 6).
  `authEventsProvider`'s `StreamController<void>` is replaced by this stream.

### 2b. A sign-in commits only on the lease it started under, and shows only what's current (race 1, flaw 3)

Each sign-in ceremony (passkey sign-in, register, handle claim, link-to-existing) reads
`vault.lease` **before its first network call** and passes it to `adopt`. If the person signed
out, switched island, or finished another sign-in in the meantime, the lease has moved and
`adopt` throws `SessionSuperseded`.

**What the controller shows goes through one door**, `_publish(AppUser? user, {required int
lease})`. It lands only while `vault.lease == lease`, and otherwise drops without writing
anything. `_applyOutcome`, `claimHandle` and `_restoreSession` publish through it, with the lease
`adopt` returned. A sign-out in the gap after `adopt` moves the lease, so the publish drops.
The same rule covers a superseded attempt: `_ingress` recognises `SessionSuperseded` and leaves
`state` exactly as the superseding action left it. It writes no `AsyncError` (Noether, flaw 3).

Reading the lease early is safe: the read is synchronous, and nothing holds the lane across the
network call.

### 2c. An end holds the door shut until it's finished (temper flaws 1, 4, 5)

Every end, signal or person, goes through one controller method, `_endSession(...)`:
1. `state = loading`. The router parks on `/splash`, and `_ingress` and `claimHandle` refuse
   to start (`claimHandle` gains `_ingress`'s guard).
2. End in the vault (`endIf`, `signOut`), or receive the credential a `SessionEnded` carries.
3. Tear down **with that credential, by value**:
   - unpair with it. The teardown never calls `currentAccessToken()`, which would read the
     signed-out vault and get null (Noether, flaw 5);
   - clear the cached user;
   - `disconnect()`, which returns without awaiting the close.

   `_teardownResources` ends nothing.
4. `_publish(null, lease: <the lease the end advanced to>)`.

No sign-in can start between steps 1 and 4, so there's no newer session for the teardown to
touch. That's the whole fix for flaw 1, and it's a removal, not a check: the gap the teardown
used to share with a sign-in no longer exists. Steps 2-3 are local work (a keychain write, a
preferences write, a cache clear, a synchronous detach), so `/splash` lasts milliseconds, not
seconds.

**Signals.**
- **`vault.ended`**: the controller handles a `SessionEnded` only while `vault.lease` still
  equals its lease. Otherwise a later end or sign-in has superseded it, and it's dropped.
- **`Unauthorized`** carries a required `Credential`, set by `_authedCall` from the credential
  the failing request carried. A request with no credential raises a distinct `NotSignedIn`, not
  `Unauthorized` with a null lease: a missing stamp can't read as "end nothing" (Tesla, flaw 7).
  Every `on Unauthorized` in the controller (`_restoreSession`, `refreshUser`, `saveProfile`,
  `_payOwedHandle`) calls `vault.endIf(e.credential)` and nothing else. If it ended something,
  the resulting `SessionEnded` drives `_endSession`. That's one teardown path, not two.
- **The transport stops being a logout trigger.** Its `unauthenticated` state stays, as a UI fact
  about the socket, but the controller stops listening to it:
  - **A socket refresh that was rejected** went through `vault.refresh`, which ended the session
    and emitted `SessionEnded`. The controller already hears it through the one channel.
  - **A socket with no credential** isn't the end of anything, so it now goes nowhere.

### 2d. A ban names its session (row 7, temper flaw 2)

`AccountSuspended` is already a subtype of `Unauthorized`, so it carries the same credential.
`_settleSuspension(credential)`:
- **with a credential**: if `!vault.isCurrent(credential)`, the ban was about a session that has
  already ended. It's dropped, with no flag and no end. Otherwise, as today: clear pending and
  flag `/suspended` synchronously (the router atomicity the existing comment protects), then
  `_endSession` via `endIf(credential)`;
- **with none** (a ban answering a sign-in ceremony, which carries no credential): flag only.
  There's no session to end.

The check and the flag are adjacent synchronous statements, and the end's `endIf` re-checks in
the lane. A sign-in can't land between them, because it needs a tap, and admission is closed
from the flag onward.

### 2e. A switch is one ordered operation (race 4, row 6; Nick's decision)

1. No-op guard, as today.
2. `state = loading` (admission closed, as §2c).
3. **`vault.signOut()`, awaited.** Then unpair with the credential it returned. If it throws
   (`vault.end_unsaved`), the switch **stops here**: the island doesn't move and nothing is
   saved. In memory the session has already ended (the vault ends it whatever the disk does).
4. **Then** save the new island. If that fails, the app is signed out on the old island.
5. `invalidate(configProvider)`, then `_publish(null, ...)`.

**One invariant covers every failure** (Noether, flaw 6): *the app is signed out, and the live
config and the saved preference both still name the old island.* The error is shown on
`/login`, where the router lands, and not on a picker that has since unmounted. If step 3 failed,
the next launch restores the old record on the old island, and only there.

This gives up one thing from today's order: a failed *save* used to leave the session intact,
and now it leaves the person signed out where they were. Nick accepted this (task 84). The old
order's failure mode was a moved island with the session still on disk, which is what turns
Noether's case into one island's token sent to another.

**#447's race 4 as written is not a harm** (Nick agreed, task 85). The person asked to leave the
island, and a session B on that island is part of what they asked to end. Admission is closed
from step 2 in any case. The harm next to it, a sign-in that commits after the switch's end, is
fenced by §2b.

### 2f. The refresh has a bound (task 79; temper flaw 8)

- **The bound goes on the refresh request alone**, via per-request options on the `post`. It does
  not go on the shared bare client, so passkey ceremonies keep their own timing. It's one
  whole-request deadline, set long relative to realistic stalls (of the order of the island's own
  request timeout), not 15 s per phase.
- **A timeout cancels the request**, which aborts its connection, so bytes not yet sent never
  arrive. It's transient by the existing taxonomy: the flight ends, `_flight` clears, and the
  transport schedules its reconnect.
- **A reply for an abandoned attempt is never adopted.** The cancelled future's result is
  discarded, and only the current flight commits.

**NAMED RESIDUAL until island #452.** Lost replies are always recoverable (§1). But a request
already on the wire when it was abandoned can land after its retry succeeded. The island then
mints over the app's new token, and the app's next refresh reads as reuse. The session ends,
which costs one passkey sign-in, not a loop. The real fix is the attempt id in
https://github.com/nickmeinhold/aiko-chat-island/issues/452, which makes a repeated attempt
idempotent. Scheduling it is Nick's call (task 89). No bound at all is worse: a hung refresh
stops reconnection forever (task 79).

`test/transport_observation_test.dart:75` flips from pinning the stuck flight to expecting
`reconnect.scheduled`.

### 2g. The person's sign-out says when it couldn't sign out (temper flaw 6)

`logout()` is `_endSession` via `signOut()`. If `signOut()` rethrows, the session has ended in
memory but not on disk, and the next launch would restore it. That's a state the app shows: the
login screen says "Couldn't finish signing out. Try again", and retrying calls `signOut()` again,
which writes the tombstone or deletes the slots. No `SessionEnded` fires for this end, so no
listener can replace that message with a bare login screen.

### 2h. Account deletion ends through the same door

`deleteAccount()`, on the island's success, is `_endSession` via `signOut()`. A deletion that's
already been sent can only end the session that sent it, because admission has been closed
since its first step.

## 3. Who ends a session

| Path | Ends with | Emits `SessionEnded` |
|---|---|---|
| `logout()` (the person) | `signOut()` | no: it renders its own outcome (§2g) |
| `switchIsland()` | `signOut()` | no |
| `deleteAccount()` success | `signOut()` | no |
| Refresh rejected (REST or WSS) | the vault's `_fly`, in the lane | yes |
| A 401 in the controller | `endIf(credential)` | yes, if it ended something |
| A ban with a credential | `endIf(credential)` | yes, if it ended something |
| A ban at sign-in | nothing: no session | no |
| A transport `unauthenticated` | nothing | no |
| `_teardownResources` | nothing: it only tears down | no |

**What goes away:** `clearTokens()` as a way for anything but the person to end a session; the
`connectionStateProvider` listener as a logout trigger; `StreamController<void>` for auth events;
saving the island before the end is on disk; publishing logged-out before the teardown finishes;
`currentAccessToken()` in the teardown.

## 4. Named tradeoffs, residuals and alternatives

- **A failed save during a switch now signs out** instead of leaving the session intact (§2e).
  NAMED TRADEOFF, owner app tab. Accepted by Nick.
- **A refresh abandoned at the deadline can land late and end the session** (§2f). NAMED
  RESIDUAL until island #452. Nick decides whether to schedule it (task 89).
- **A sign-in abandoned by a lease move leaves a session open on the island** that the app never
  adopted. It's never presented, and it ages out. Revoking it would need a logout-by-token
  endpoint on the island. NAMED RESIDUAL.
- **The lease is in-process.** A crash mid-switch can leave the old record, with its island:
  design 26's allowed failure.
- **Carnot's session-scope object** (one owner for the transport, the pairing and the identity,
  retired before cleanup) was considered and NOT ADOPTED. §2b's publish door, §2c's closed
  admission and the credential carried by value give the same isolation without a new object.
  If round 2 finds a shared-resource leak these don't cover, it comes back. Owner: app tab.

## 5. Tests (observable outcomes under adversarial orderings; mutation-check each)

1. **A transport `unauthenticated` alone** (no `SessionEnded`) leaves the session and the UI
   state alone.
2. **A late sign-in after a sign-out** commits nothing: the vault is still signed out, and the
   state is still logged out.
3. **A sign-out between `adopt` and the publish** leaves the state logged out, not showing A.
4. **A queued `SessionEnded` for lease n, delivered after a sign-in**, leaves the new session and
   its UI state alone.
5. **A signal end while a sign-in tries to start**: the ceremony refuses until the end is
   complete. The new session's credential is never unpaired, and its socket is never closed.
6. **Carnot's case:** A refreshes, B signs in, A's pinned retry gets a 401. B stays signed in.
7. **Tesla's case:** a refresh commits (the lease doesn't move), then a 401 arrives for the
   pre-rotation access token. The refreshed session stays.
8. **A stale ban:** A's 403 lands after B signed in. B is neither suspended nor signed out.
9. **A WSS refresh rejection** logs out exactly once, through `SessionEnded`.
10. **The teardown unpairs with the ended credential**, never null.
11. **A switch whose sign-out fails** leaves the saved island and the live config unchanged, and
    the error shows on `/login`. The next boot restores the old record on the old island only.
12. **A hung refresh** times out, the transport schedules a reconnect, and a later refresh starts
    a new flight. **Two timeouts in a row** followed by a success stay signed in. A reply that
    arrives for an abandoned attempt is not adopted.
13. **A person's sign-out whose disk write fails** shows "couldn't finish signing out", and
    retrying writes the end.
14. **`claimHandle` during an end** refuses to start.
