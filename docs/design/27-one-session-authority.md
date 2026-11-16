# Design 27: one session authority

**Status:** draft v3, 2026-11-16. v1 and v2 were each struck RECAST 4/4 (`27-TEMPER.md`, runs
dt-1794795469 and dt-1794797382). This version folds round 2. Round 3 is the cap.
Opens PR B of design 26 (task 77).
**Closes:** https://github.com/nickmeinhold/aiko_chat_app/issues/447, two cases deferred to it
from the cage-match of https://github.com/nickmeinhold/aiko_chat_app/pull/453 (round 2), and that
PR's deferred refresh deadline (round 1).
**Builds on:** the session vault (design 26 §2c, merged as `f7f4c2d`).
**Decided by Nick (2026-11-16):** §2f's switch order, and that #447 race 4 as written is not a
harm.

**Touches a trust boundary:** which session an operation is allowed to end, restore, replace or
*show*.

## 0. The producer question

**The harm.** An operation that started under one session does one of these:
- ends a later session;
- brings back an earlier one;
- shows one that isn't there (or hides a ban that is);
- sends a session to an island that didn't issue it.

**What produces it.** One shape, at two layers.

**At the vault: outcomes that don't name their session.** Each place below hands on an outcome
that once named a session, but drops the name on the way.

| # | Where | Carries today | Should carry |
|---|---|---|---|
| 1 | A sign-in's late `setTokens` (#447 race 1) | tokens | the lease the attempt started under |
| 2 | `authEventsProvider` (#447 race 2) | `void` | the session the vault ended |
| 3 | The transport's `unauthenticated` (#447 race 3) | a state | nothing: it isn't an end |
| 4 | `Unauthorized` from `_authedCall` | a status code | the credential that got the 401 |
| 5 | `_restoreSession`'s `on Unauthorized` | nothing | the same as 4 |
| 6 | `switchIsland` moving the island | an order of steps | "the end is on disk" before "the island moved" |
| 7 | A ban: `AccountSuspended` → `_settleSuspension` | `state.error` | the lease of the call that learned it |
| 8 | `settleBan()` from moderation (`:940-943`) | a made-up `AccountSuspended` | the same as 7 |
| 9 | `deleteAccount`'s completion (`:1020-1030`) | "whoever is here now" | the lease captured when it was sent |

**At the controller: writers of what the app shows, with nothing ordering them.** The controller
holds four pieces of session state: `state`, `pendingHandle`, `suspended`, and the cached user.
Fifteen lines in ten methods write `state` (`grep -n "state = "` in `auth_controller.dart`):

- `:355-356` `_ingress`;
- `:399` `_settleSuspension`;
- `:673-674` `claimHandle`;
- `:811` `logout`;
- `:852`, `:860` `refreshUser`;
- `:912`, `:918` `saveProfile`;
- `:941` `settleBan`;
- `:978`, `:1009` `switchIsland`;
- `:1028` `deleteAccount`;
- `:1043` `_becomeUnauthenticated`.

Each of those is an async path that can finish after another has started. v2 gave them one
publish door, but the ceremonies still assigned their own return values, the sibling state
stayed unfenced, and "an end is running" was itself a writable value (round 2, flaws A-F).

**Removing both.** The vault already has the answer to the first: a serial lane, and a lease
checked at every commit. **The controller gets the same: a transition lane.** Every write to the
four pieces of session state happens inside one transition, and every transition is issued for
a lease and checks it first. Neither layer gets a new kind of object. The controller simply
does what the vault already does.

### A hazard I suspected, and checked: it doesn't happen

The no-credential path in row 3 can't fire at boot. The transport's only `connect()` comes from
`chatRepositoryProvider` (`chat_providers.dart:733`), which needs a signed-in user, and the wake
kicks are ignored until something has asked to connect. Row 3 is still closed by deletion (§2d).

## 1. Facts this rests on

- **The vault is the only writer** of the session. It serialises every change in `_serial`
  (`session_vault.dart:145`).
- **A `Credential` is `(accessToken, lease)`** (`:161`). The lease advances on `adopt` and on
  `_end`, never on a refresh. `refresh` already supersedes a stale lease and returns the newer
  credential for a stale access token (`:186-191`).
- **`_fly` writes `_state` only after `await _put`** (`:241-242`), so a read taken outside the
  lane can see the pre-rotation token while a rotation is committing.
- **The transport's `disconnect()` detaches synchronously** and closes without waiting
  (`gateway_transport.dart:214-226`).
- **The router listens to `state`, `pendingHandle` and `suspended`**, and today's settlement
  writes them in one synchronous run for that reason (`auth_controller.dart:397-399`).
- **`_teardownResources` clears `suspended` unconditionally** (`:726`).
- **The bare Dio is shared**: the refresh uses it, and so do `GatewayRestApi`'s unauthenticated
  calls (`gateway_rest_api.dart:944,964`).
- **Island rotation** (`aiko-chat-island/src/aiko_gateway/domain/auth_session.py`): presenting
  CURRENT (`:163-166`) moves it to previous; presenting PREVIOUS (`:167-170`) mints a new current
  and leaves previous alone; anything else ends the session. Lost replies are recoverable. A
  request that lands after a later one is not (§2g).

## 2. The design

### 2a. The vault

- **`int get lease`**: read synchronously.
- **`Future<Credential?> endIf(Credential presented)`**, for a **token outcome** (a 401). In the
  lane, it ends the session only if both the lease and the access token are still current, and
  returns the credential it ended. The access token matters because a refresh doesn't move the
  lease: a 401 on a rotated-away token must not end the session that rotated it.
- **`Future<Credential?> endIfLease(int lease)`**, for an **account outcome** (a ban, a
  deletion). It ends the session if the lease is still current, whatever the access token is.
  A refresh keeps the account. Only a new session or an end changes whose account it is.
- **`Future<Credential?> signOut()`**: unfenced, the person's own. Returns what it ended.
- **`adopt(island, tokens, {required int since})`**: throws `SessionSuperseded` if the lease has
  moved. Returns the new lease.
- **`Stream<SessionEnded> ended`**: one event per end the person didn't ask for (a refresh
  rejection in `_fly`, an `endIf`/`endIfLease` that ended something). It carries the lease
  advanced *to* and the ended credential by value. **It's emitted after the lane turn returns**,
  so a handler that calls back into the vault never waits on the lane from inside it.
  `signOut()` emits nothing. `StreamController<void>` for auth events goes away.

### 2b. The controller's transition lane

```text
_transition(lease, body):  queued behind every earlier transition;
                           runs body only if vault.lease == lease (else drops, writes nothing);
                           body may await the vault's lane, never the other way round.
```

**Rule 1. Only a transition writes session state.** All four pieces (`state`, `pendingHandle`,
`suspended`, the cached user) are written only inside `_transition`. They're always written
together as one **picture**, in one synchronous run at the end of the body, so the router never
sees half of one (today's atomicity, kept).

**Rule 2. Network work stays outside.** A ceremony, a profile save or a deletion does its network
call first, then queues one transition to commit what came back. The lane is held only for local
work: a keychain write, a preferences write, a cache write, a synchronous socket detach. So it's
held for milliseconds.

**Rule 3. An attempt is retired by the next transition.** A sign-in ceremony gets an attempt id
when its *begin* transition runs. Any later end, switch or sign-in clears the current attempt as
part of its own picture. The ceremony's *commit* transition runs only if its attempt is still
current, so success, cancellation, error, `PendingHandle` and a sign-in ban are all dropped
together once the attempt is retired. This is Carnot's "revocable attempt authority" without a
new type.

**Admission** is "no attempt is current". A tap during a transition queues its begin behind it,
and the begin re-checks admission when it runs, so nothing is refused or lost.

**Deadlock check:** the vault never awaits the controller, and its events fire after its lane
turn. The controller's lane may await the vault's. There's no cycle.

### 2c. A sign-in (#447 race 1; round 2 flaw A)

1. *Begin transition*: check admission, take an attempt id, read `vault.lease`, and publish
   `loading`.
2. Outside the lane: the ceremony's network calls and the authenticator sheet. **The ceremony
   returns its outcome, not a state.** Nothing assigns the guard's result to `state`.
3. *Commit transition*, for the begin's lease and attempt:
   - **Authenticated** → `adopt(..., since:)`, write the cached user, then picture
     `(user, pending: none, suspended: false)`. `SessionSuperseded` is dropped and writes
     nothing.
   - **`PendingHandle`** → picture `(logged out, pending: it)`.
   - **Cancelled** → picture `(prior)`.
   - **Error** → picture `(AsyncError)`.
   - **A ban at sign-in** (no session to end) → picture `(logged out, suspended: true)`.

`claimHandle` is the same shape, with its begin requiring the pending handle. `_restoreSession`
is a transition issued at boot for lease 0. It publishes with the lease of the credential
`present()` returned. Restore doesn't `adopt`.

### 2d. Ends (#447 races 2-3; rows 2-5; round 2 flaws C-D)

An **end transition** for lease L, through any door:
1. End in the vault: `signOut()`, `endIf`, or `endIfLease`. For a `SessionEnded` the vault has
   already ended it, and the event carries the credential. If nothing was ended, stop and write
   nothing.
2. Tear down with the ended credential **by value**:
   - unpair with it (never `currentAccessToken()`);
   - clear the cached user;
   - `disconnect()`.

   `_teardownResources` ends nothing and no longer clears `suspended`, and
   `_clearCredentialAndUnpair` loses its `clearTokens()`.
3. Picture `(logged out, pending: none, attempt: retired, suspended: <the outcome's>)`.
   `suspended` is `true` for a ban and `false` for everything else, so a ban survives its own
   teardown (round 2: Carnot, Tesla).

**The doors.**
- **`vault.ended`**: an end transition for the event's lease, with steps 2-3.
- **A 401** anywhere in the controller (`_restoreSession`, `refreshUser`, `saveProfile`,
  `_payOwedHandle`): `Unauthorized` carries a required `Credential`, set by `_authedCall` from
  the credential the request carried. A request with no credential raises `NotSignedIn`
  instead. The door is an end transition via `endIf(e.credential)`.
- **The transport's `unauthenticated`**: not a door. The controller stops listening. A rejected
  socket refresh already ended in `vault.refresh` and emitted `SessionEnded`. A socket with no
  credential ended nothing.
- **Overlapping ends queue.** The second finds the lease already moved and drops.

### 2e. Account outcomes: a ban and a deletion (rows 7-9; round 2 flaws B, E)

- **A ban on an authed call.** `AccountSuspended` carries the request's credential, and the door
  is an end transition via `endIfLease(credential.lease)`. **The flag comes from the result**:
  `suspended: true` is in step 3's picture only if `endIfLease` ended something. A ban that
  arrives on a pre-rotation token under the same lease still settles. A ban for an account
  already left ends nothing and flags nothing.
- **`settleBan(lease)`**: the moderation controller reads `vault.lease` before it sends the
  action whose response is the ban (`moderation_controller.dart:134,219`). It's the same end
  transition.
- **`deleteAccount()`**: reads `vault.lease` before it sends. On the island's success, it runs an
  end transition via `endIfLease(lease)`. A successor adopted while the request was out has a
  newer lease and is untouched.

### 2f. A switch is one transition (row 6; Nick's decision; round 2 flaw F)

One transition for the current lease:
1. No-op guard.
2. **`vault.signOut()`, awaited**, then unpair with what it returned, clear the cache, and
   `disconnect()`.
   - If `signOut()` throws (`vault.end_unsaved`), the switch stops: the island isn't saved, the
     config isn't invalidated, and the picture is `(logged out, error: "couldn't finish signing
     out")`. The transition ends there, and its `finally` releases the lane.
3. **Then** save the new island. If that fails, the picture is `(logged out, error)`, still on
   the old island.
4. `invalidate(configProvider)`, then picture `(logged out)`.

**One invariant for every failure:** the app is signed out, and the live config and the saved
preference both still name the old island. The error renders on `/login`, because that picture
is what the router reads. Nick accepted the tradeoff (a failed save now signs out, task 84) and
that race 4 is not a harm (task 85). Admission is closed for the whole transition.

### 2g. The refresh has a bound (task 79; round 1 flaw 8; round 2 flaw G)

- **The bound goes on the refresh request alone** (per-request options), not on the shared bare
  client. It's one whole-request deadline, long relative to realistic stalls (of the order of
  the island's own request timeout).
- **A timeout cancels the request**, which aborts its connection. The flight ends, `_flight`
  clears, and the transport schedules a reconnect. A reply for an abandoned attempt is never
  adopted.

**NAMED RESIDUAL until island #452.** If the request was already on the wire, it can land after
its retry succeeded. The island then mints over the stored token, and the next refresh reads as
reuse. That costs one passkey sign-in, not a loop. The real fix is the attempt id in
https://github.com/nickmeinhold/aiko-chat-island/issues/452. Scheduling it, or holding the
deadline until it lands (Noether's alternative), is Nick's call (task 89). No bound at all is
task 79's harm: a hung refresh stops reconnection forever.

### 2h. The person's sign-out says when it couldn't

`logout()` is an end transition via `signOut()`. If `signOut()` throws, the picture is
`(logged out, error: "couldn't finish signing out. Try again")`. Retrying calls `signOut()`
again, which writes the tombstone or deletes the slots. No `SessionEnded` fires for the person's
own end, so nothing replaces that message with a bare login screen.

## 3. Who writes what

| Door | Vault call | Emits `SessionEnded` | Picture |
|---|---|---|---|
| sign-in commit | `adopt(since:)` | no | user / pending / prior / error / banned |
| `_restoreSession` | `present()` | no | user, or logged out |
| `logout()` | `signOut()` | no | logged out (± error) |
| `switchIsland()` | `signOut()` | no | logged out (± error), then the new island |
| `deleteAccount()` success | `endIfLease(sent)` | yes, if ended | logged out |
| a ban (authed, or `settleBan`) | `endIfLease(sent)` | yes, if ended | logged out + suspended |
| a 401 | `endIf(credential)` | yes, if ended | logged out |
| refresh rejected (REST or WSS) | `_fly`, in the vault | yes | logged out |
| `refreshUser` / `saveProfile` success | none | no | user, for the lease at send |
| transport `unauthenticated` | none | no | none |
| `_teardownResources` | none | no | none: it only tears down |

**What goes away:** every `state =`, `pendingHandle` and `suspended` write outside `_transition`;
`clearTokens()` for anything but the vault's own ends; the `connectionStateProvider` listener as
a logout trigger; `StreamController<void>`; saving the island before the end is on disk;
`currentAccessToken()` in the teardown; `_clearSuspended()` in the teardown; the
`state.isLoading` admission guard; the made-up `AccountSuspended` in `settleBan`.

## 4. Named tradeoffs, residuals and alternatives

- **A failed save during a switch now signs out** (§2f). NAMED TRADEOFF, accepted by Nick.
- **A refresh abandoned on the wire can land late and end the session** (§2g). NAMED RESIDUAL
  until island #452 (task 89).
- **A sign-in abandoned by a retired attempt leaves a session open on the island.** It's never
  presented, and it ages out. NAMED RESIDUAL.
- **The lease is in-process.** A crash mid-switch can leave the old record on the old island:
  design 26's allowed failure.
- **The owed-handle debt store** (`:84`, `:124`) is per account, not per session, and stays
  outside the lane. It's keyed by `userId` and holds no credential.
- **Carnot's session-scope object**: NOT ADOPTED. The transition lane is the single owner of
  transitions it asked for, and the vault already owns the credentials. Owner: app tab.

## 5. Tests (observable outcomes under adversarial orderings; mutation-check each)

Each test drives the real controller and awaits the whole door, not a helper on its own.

1. A transport `unauthenticated` alone changes nothing.
2. A late sign-in after a sign-out commits nothing and shows nothing.
3. A sign-out between `adopt` and the cached-user write leaves the app logged out, with no cached
   A (awaiting the whole `_ingress`).
4. A late `PendingHandle`, cancellation or error from an attempt retired by an end writes
   nothing.
5. A queued `SessionEnded` for lease n, delivered after a sign-in, leaves the new session alone.
6. A signal end and a sign-in tap together: the tap queues, and B's credential is never
   unpaired and B's socket never closed.
7. Two overlapping ends: one teardown runs, and the second drops.
8. Carnot's case: A refreshes, B signs in, A's pinned retry 401s. B stays.
9. Tesla's 401 case: a refresh commits, then a 401 for the pre-rotation token arrives. The
   session stays.
10. **A ban on a pre-rotation token under the same lease settles**: signed out, and suspended.
11. A stale ban (A's 403 after B signed in) neither suspends nor ends B.
12. A ban survives its own teardown: the router lands on `/suspended`.
13. `settleBan` with a captured lease behaves as 10 and 11.
14. A delete whose success lands after B signed in leaves B alone.
15. A WSS refresh rejection logs out exactly once.
16. A switch whose sign-out throws: the island and config are unchanged, the error shows on
    `/login`, and the lane is released (a following tap runs).
17. A person's sign-out whose disk write fails shows "couldn't finish", and retrying writes the
    end.
18. **The refresh bound, schedule one:** cancels before the bytes leave, twice, then a success.
    Still signed in.
19. **The refresh bound, schedule two:** an attempt on the wire is abandoned, its retry wins,
    then the late attempt lands at a fake island. The app signs out once and doesn't loop.
    This is the named residual, asserted as such.
