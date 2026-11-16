# Design 27: one session authority

**Status:** draft v1, 2026-11-16. Not yet tempered. Opens PR B of design 26 (task 77).
**Closes:** https://github.com/nickmeinhold/aiko_chat_app/issues/447, plus two cases deferred
to it from the cage-match of https://github.com/nickmeinhold/aiko_chat_app/pull/453 (round 2),
and that PR's deferred refresh deadline (round 1).
**Builds on:** the session vault (design 26 §2c, merged as `f7f4c2d`).

**Touches a trust boundary:** which session an operation is allowed to end, restore or replace.

## 0. The producer question: what lets an operation from an ended session still change the current one?

**The harm.** An operation that started under one session either:
- ends a later session (a stale logout signs out the person who signed in since), or
- brings back an earlier one (a late sign-in or refresh revives a session the person left), or
- sends a session to an island that didn't issue it.

**What produces it.** One thing, in six places. **Terminal outcomes travel without saying
which session they belong to.** Each place hands on an outcome that once named a session, but
drops the name on the way:

| # | Where | What it carries | What it should carry |
|---|---|---|---|
| 1 | A sign-in's late `setTokens` (#447 race 1) | tokens | the lease the attempt started under |
| 2 | `authEventsProvider` (#447 race 2) | `void` | the lease the refresh ended |
| 3 | The transport's `ConnectionState.unauthenticated` (#447 race 3) | a state | the lease it was about, or nothing |
| 4 | `Unauthorized` from `_authedCall` (Carnot, #453 round 2) | a status code | the lease of the credential that got the 401 |
| 5 | `_restoreSession`'s `on Unauthorized` → `clearTokens` | nothing | the same as 4 |
| 6 | `switchIsland` moving the island (Noether, #453 round 2) | an order of steps | "the end is on disk" before "the island moved" |

The vault already has the name: **`Credential.lease`**. It advances on a new session and on an
end, never on a refresh. The vault itself already obeys it: a refresh's commit and a rejection's
end are each fenced by it. **But nothing outside the vault does.** The REST interceptor, the
transport and the auth controller each turn a lease-stamped outcome back into a bare one, and
the auth controller then calls `clearTokens()`, which ends **whatever is current**.

**Removing it.** The vault stops offering "end whatever is current" to anything but the person.
Every terminal outcome that isn't the person's own action carries a lease, and the vault applies
it only while that lease is current. That is the one session authority #447 asked for. It isn't a
new object: it's the vault, with no unfenced door left.

### A hazard I suspected, and checked: it doesn't happen

The no-credential path in row 3 looked like design 26's harm still reaching `main`: the door for
a guessed island returns null, the transport calls `_setUnauthenticated()`
(`gateway_transport.dart:343-347`), and the controller's teardown writes signed out over another
island's record. **It can't fire at boot.** The transport's only `connect()` comes from
`chatRepositoryProvider` (`chat_providers.dart:733`), which needs a signed-in user, and the wake
kicks are ignored until something has asked to connect (`reconnectNow`'s `_wantConnected`
guard). Row 3 is still worth closing, for race 3's sake, and §2c closes it by deletion.

## 1. Facts this rests on

- **The vault is the only writer** of the session (design 26 §2c). Every end goes through
  `_end`, and every new session through `adopt`.
- **The lease is in memory only.** It starts at 0 in each process, so a lease from before a
  restart can't exist. Nothing persists one.
- **Every 401 the interceptor forwards came from a request with a credential.** Unless
  the request had no credential at all: then the 401 has no lease, and it's left as it is today
  (§2c).
- **A switch already signs out before it moves the config**, but it *saves* the new island
  **first** (`auth_controller.dart`, `switchIsland`, step 2). Design 26's placement rule 2 reads
  that saved island when it places a legacy pair.
- **The auth controller listens to `ConnectionState.unauthenticated`** as its own logout trigger,
  separately from `authEventsProvider` (`auth_controller.dart`, `build()`).
- **`buildGatewayBackend`'s bare Dio has no timeouts**, and the transport awaits the refresh
  before it schedules a reconnect (`gateway_transport.dart`, `_onConnectFailure`).

## 2. The design

### 2a. The vault exposes the lease, and two fenced operations

- **`int get lease`**: the current lease. Read synchronously.
- **`endIf(int lease)`**: ends the session only if `lease` is still current. Otherwise it does
  nothing and returns false. It runs in the vault's serial lane, so the check and the end can't be
  split by a sign-in.
- **`adopt(island, tokens, {required int since})`**: as today, but it throws `SessionSuperseded`
  when the lease has moved since `since`.
- **`signOut()` stays unfenced.** That's the person's own sign-out, or a switch: it means
  "whatever is here now", and that's correct.

### 2b. A sign-in commits only on the lease it started under (#447 race 1)

Each sign-in ceremony (passkey sign-in, register, handle claim, link-to-existing) reads
`vault.lease` **before its first network call**. It passes that lease to `setTokens`.

If the person signed out, switched island, or finished a different sign-in in the meantime, the
lease has moved, and the late commit throws `SessionSuperseded`. The controller treats that as
"this attempt was abandoned": no state change, no error shown.

Why it's safe to read the lease early: reading it is synchronous, and nothing holds the lane
across the network call (#447's "don't hold the lock across network work").

### 2c. Every logout signal names its lease, and "no lease" ends nothing (races 2 and 3, rows 4 and 5)

- **`authEventsProvider` carries `SessionEnded(lease)`**, the lease the vault advanced *to* when
  it ended the session. The controller tears down only if `vault.lease` still equals it. If a
  sign-in has landed since, the lease has moved past it, and the event is dropped.

  The vault has already written **signed out** by the time this event fires, so the controller's
  teardown no longer needs to clear the credential. It still resets the UI state, unpairs and
  disconnects.
- **`Unauthorized` gains `int? lease`**, set by `_authedCall` from the credential the failing
  request carried (`extra['aiko_credential']`). Every `on Unauthorized` in the auth controller
  (`_restoreSession`, `refreshUser`, `saveProfile`, the handle-payment path) calls
  `_becomeUnauthenticated(lease)`. That runs `endIf(lease)`, and tears down only if it ended
  something or the lease is current.

  A null lease (a request that carried no credential) reads as "nothing to end". Today's behaviour
  for an `Unauthorized` with no session is already a logged-out app, so nothing is lost.
- **The transport stops being a logout trigger.** Its `unauthenticated` state stays, as a UI fact
  about the socket. But the auth controller **stops listening to it**. There are two cases:
  - **The socket's refresh was rejected.** It went through `DefaultTokenProvider.refresh` →
    `vault.refresh`, which ended the session and fired `SessionEnded`. So the controller already
    hears it through the one channel.
  - **The socket had no credential.** That's not an end of anything, so it now goes nowhere.

  So #447's "second logout path" is closed by **deleting it**, not by guarding it.

### 2d. A switch is one ordered operation (race 4, row 6)

The new order:
1. No-op guard, as today.
2. Publish `loading` (the router parks on `/splash`).
3. Unpair, then **`vault.signOut()`, awaited**. If it throws (`vault.end_unsaved`), the switch
   **stops here**: the island doesn't move, nothing is saved, and the picker shows "couldn't sign
   out, try again". In memory the session has already ended (the vault ends it whatever the disk
   does), so the app is signed out on the **old** island. On disk the record still names the old
   island, so the next launch restores it **there**, and only there.
4. **Then** save the new island. If that fails, the app is signed out on the old island. That's
   the allowed failure: nothing is presented anywhere wrong.
5. `invalidate(configProvider)`, then publish logged-out.

This gives up one thing from today's order: a failed *save* used to leave the session intact.
Now it leaves the person signed out on the island they were on. I think that trade is right. The
old order's failure mode was a moved island with the session still on disk, and that combination
is exactly what Noether's case turns into one island's token sent to another.

**#447's race 4 as written ("a sign-in installs B between the switch's read and its clear") is
not a harm.** I'm pushing back on the issue here. The person asked to leave the island, and B is a
session *on the island they're leaving*. Ending it is what they asked for. The real harm next to
it is a sign-in that commits *after* the switch's end, and §2b's lease fences that.

### 2e. The refresh has a deadline (task 79)

The refresh POST gets a deadline: **15 s** connect, send and receive timeouts on the bare client
that `buildGatewayBackend` builds. A timeout throws a Dio timeout error. That isn't
`RefreshRejected`, so it's transient by the existing taxonomy:
- the flight ends;
- `_flight` clears;
- the transport schedules its reconnect.

**Under rotation, a timed-out refresh may still have rotated on the island.** The app then holds
the *previous* refresh token. Island #420 accepts PREVIOUS as a retry, so the next refresh
succeeds. The deadline relies on that grace. The attempt-id wire shape on
https://github.com/nickmeinhold/aiko-chat-island/issues/452 would make it explicit. Until it
lands, the grace is the contract.

`test/transport_observation_test.dart:75` flips from pinning the stuck flight to expecting
`reconnect.scheduled`.

### 2f. Sign-out says when it couldn't sign out

When `vault.signOut()` rethrows on the person's own sign-out (`logout()`), the app doesn't look
signed out until a relaunch quietly restores the session. The settings screen shows "Couldn't sign
out. Try again." The session is already ended in memory, so retrying writes the tombstone or
deletes the slots.

## 3. What goes away

- `clearTokens()` as a way for *signals* to end a session. Only the person's own sign-out, and a
  switch, end "whatever is current".
- The auth controller's `connectionStateProvider` listener as a logout trigger.
- `StreamController<void>` for auth events.
- Saving the island before the session's end is on disk.

## 4. Named tradeoffs and residuals

- **A failed save during a switch now signs out** instead of leaving the session intact (§2d).
  NAMED TRADEOFF, owner: app tab.
- **A refresh deadline relies on the island's PREVIOUS-token grace** (§2e). NAMED RESIDUAL
  until island #452's attempt id lands.
- **A sign-in abandoned by a lease move leaves a session open on the island** that the app never
  adopted. It's never presented, and it ages out. Revoking it would need the island to offer a
  logout-by-token endpoint. NAMED RESIDUAL.
- **The lease is in-process.** A crash mid-switch can leave the old record, with its island,
  which is design 26's allowed failure.

## 5. Tests (observable outcomes under adversarial orderings; mutation-check each)

1. **A transport `unauthenticated` alone** (no `SessionEnded`) leaves the session and the UI
   state alone.
2. **A late sign-in after a sign-out** commits nothing: the vault is still signed out, and the
   state is still logged out.
3. **A queued `SessionEnded` for lease n, delivered after a sign-in**, leaves the new session and
   its UI state alone.
4. **Carnot's case:** A refreshes, B signs in, A's pinned retry gets a 401. B stays signed in.
5. **A WSS refresh rejection** logs out exactly once, through `SessionEnded`.
6. **A switch whose sign-out fails** leaves the saved island unchanged. The next boot restores
   the old record on the old island only.
7. **A hung refresh** times out, the transport schedules a reconnect, and a later refresh starts
   a new flight.
8. **A sign-out whose disk write fails** surfaces "couldn't sign out".
