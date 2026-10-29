# Design 26: a session knows its island

**Status:** v3, 2026-10-29, tempered over 3 rounds (RECAST 4/4, then 3/1, then 3/1) and
**converged at the cap**. Build to v3 plus the five **v3.1 requirements** in `26-TEMPER.md`
(Round 3), which override v3 where they differ:
- the sign-out fallback deletes the legacy items first;
- a failed placement write leaves the island unresolved;
- owner-unknown is discardable, not "never deleted";
- a non-lock Keychain error shows an error state;
- resolution is the only writer while unresolved.

The build is its own PR, and #439 rebases on it. The design recasts the credential half of PR #439
(https://github.com/nickmeinhold/aiko_chat_app/pull/439).

**Product decisions (Nick, 2026-10-29):**
- **A reinstall keeps the person signed in.** Every session this design writes records its island,
  so it survives any reinstall. The one exception is a session an OLDER build wrote, on an install
  whose preferences a reinstall wiped. Nothing can place it, so it's **owner-unknown: never
  presented** (section 2b). A sign-in, a switch or a sign-out may discard it (v3.1 requirement 3),
  and it expires on its own.
- **Scope.** Four session races that exist on `main` without #436 are split into their own
  design: https://github.com/nickmeinhold/aiko_chat_app/issues/447. They are:
  - a sign-in committing after a sign-out;
  - a stale logout signal;
  - the WSS logout path;
  - a non-atomic switch.

  This design closes #439's harm only.

**Touches a trust boundary:** which island a credential is presented to.

## 0. The producer question: what lets a stored session reach an island that didn't issue it?

**The bad outcome.** One island's token is sent to another island. That island answers 401, and
the app treats the 401 as a revocation and deletes the credential.

**What produces it.** Two things together:
1. **A session stored without its island.** The island choice lives in SharedPreferences and the
   tokens in the Keychain. iOS and macOS delete preferences on an uninstall but keep the Keychain,
   so after a reinstall the app holds tokens with no record of their island.
2. **Credential actors built for a guessed island.** On a launch where the Keychain can't be read
   (a locked phone), the app still builds the token provider, the transport and the auth flow for
   a guessed island. When the Keychain opens, those actors see a session that isn't theirs, and
   their "not mine, so sign out" path clears it. Verified at `6821909`:
   - the door's refusal leads to `_markUnauthenticated(clearStore: false)`;
   - that fires `onUnauthenticated` → `authEventsProvider` → `_becomeUnauthenticated`
     (`auth_controller.dart:204-205`) → `_teardownResources` → `_clearCredentialAndUnpair`;
   - the last step clears unconditionally.

**Removing both:**
1. **The island lives inside the session.** One Keychain item holds both, so for anything this
   build writes there's no session without an owner (2a).
2. **No credential actor exists for an unresolved island.** Until a readable Keychain has said
   whose session it holds, the token provider presents nothing and fires nothing, the transport
   doesn't connect, and the auth flow waits (2d).

   A guess may still pick which island the non-credential readers see. It can't touch a
   credential, because nothing that could is running.

## 1. Facts this rests on (all verified)

- **One door.** `DefaultTokenProvider` is the only code that reads tokens to present them and the
  only code that writes them. It's built per island by `buildGatewayBackend`.
- **A switch clears first.** `switchIsland` clears the tokens before it changes the island.
- **Locked reads throw.** Tokens are `kSecAttrAccessibleWhenUnlocked` (design 23, Nick
  2026-10-10). On a locked phone a read throws (-25308) until Face ID. A call answered on a locked
  iPhone connects after Face ID.
- **Island tokens don't name their island.** The JWT payload is `sub`, `type`, `gen`, `iat`, `exp`
  (island `security.py:35-46`), with no `iss` and no `aud`.
- **Refresh tokens expire 30 days after sign-in.** That expiry is in the token's `exp` and never
  slides (app #427 isn't built). Rotation, when it ships, changes a token only when it's
  refreshed.
- **The three-key format never shipped.** `aiko_tokens_island` exists only on #439's unmerged
  branch (`6821909`).
- **The cached user is on every tagged release.** The cached-user store (`f65906b`, #71) is an
  ancestor of every tagged release (`android/v0.0.6+17` onward).
- **No other doors.** There's no Dart background isolate, and native code never reads the island
  key.
- **The root builds the transport at startup** (`main.dart:95` → `transportWakeProvider` →
  `configProvider`). **The call-answer path** listens for native events from the first frame,
  and kicks the transport when answered (`system_call_navigator.dart:259`).

## 2. The design

### 2a. One item, four states

The session is one Keychain item, `aiko_session`, with today's accessibility. It is in exactly
one of four states:

| State | Content | Presented? | A sign-in may replace it? |
|---|---|---|---|
| **record** | `{"v":1,"island":…,"access":…,"refresh":…}` | to its island only | only when it holds the same island (switching is #447's) |
| **owner-unknown** | `{"v":1,"owner":"unknown","access":…,"refresh":…}` | never | yes |
| **signed out** | `{"v":1,"signedOut":true}` | — | yes |
| **unreadable data** | present, but not valid JSON or a version this parser doesn't know | never | yes, with telemetry |

**The legacy pair** (`aiko_access_token`, `aiko_refresh_token`) is read **only when no
`aiko_session` item exists at all**. Writing ANY of the four states retires the old format for
good:
- every write puts `aiko_session` first and deletes the legacy items after it;
- a crash between the two leaves an `aiko_session` that the next read obeys.

**Sign-out** writes "signed out". If that write fails, it deletes `aiko_session`, then the legacy
items, so a sign-out never leaves a credential behind (`_clearCredentialAndUnpair`). A crash
before sign-out's first write keeps the session, which is the allowed failure.

### 2b. Placing an old session: once, at boot, before the settle

When boot finds no `aiko_session` but finds the legacy pair, it places the pair **before anything
else runs**, and writes the answer into `aiko_session` before boot returns. The island is the
first of these that applies:
1. `aiko_tokens_island`, if present (only a dev device that ran #439's branch);
2. on a store build, **the saved island**, if there is one (an older build used it, and a switch
   cleared the tokens);
3. on a store build with no saved island, **`kLegacyDefaultIslandBaseUrl` if a cached user exists**
   (the cached user lives and dies with the tokens, so it proves an older store build ran here on
   its compiled default);
4. otherwise **owner-unknown**, and always owner-unknown on a dev build (the current
   `--dart-define` says nothing about an older dev build's island).

Two guarantees:
- **Placement never reads an island the settle saved.** It runs before the settle, and once
  `aiko_session` exists, placement never runs again: the legacy pair is never read again.
- **That is what v2 got wrong.** There, an owner-unknown pair stayed in the legacy items. On the
  next launch it was placed on the island the settle had just saved.

**Owner-unknown costs nothing to keep:**
- it's never presented and never refreshed;
- a sign-in, a switch or a sign-out may discard it (v3.1 requirement 3); nothing is lost,
  because nothing could ever use it;
- its own `exp` ends it within 30 days, with or without #427's rotation.

### 2c. The vault, and the door

`SecureTokenStore` becomes the vault: every read that publishes a session, and every write, runs
serially inside it.

**The generation advances only on a NEW session (`setTokens`) or a sign-out.** Placement and a
refresh are the same session and don't advance it. A `DefaultTokenProvider` operation captures
the generation when it starts, and loses its effect if the generation has moved by the end. That
covers:
- the cache fill;
- the refresh's commit;
- a rejection's clear;
- the shared `_inFlight`;
- `onUnauthenticated`.

(A sign-in's own network attempt isn't leased from its start. That's #447.)

**The door** presents a record only to the provider for its island. The door never writes.

### 2d. Resolution: no credential actor until the Keychain answers

`islandResolutionProvider` is either **resolved** (a readable Keychain has answered, and the
island is fixed) or **unresolved** (it hasn't). Anything that never ran boot reads **unresolved**:
a missing resolution can only withhold, never act.

**Boot** (`main()`, before `runApp`, awaited; it can't throw out of `main`):
1. Read the vault.
2. If readable, place any legacy pair (2b).
3. Then decide:
   - **a record for island L:** resolved to L, and L is saved;
   - **no presentable session** (absent, signed out, owner-unknown, or unreadable data): the
     settle decides and saves, then it's resolved. If any `aiko_session` item exists, this build
     has run here, so the settle ignores old-build evidence and a fresh install's own crash can't
     read as an older build;
   - **unreadable** (locked -25308, or any thrown read, -34018 included): **unresolved.** Nothing
     is saved or written. Anything other than the lock goes to telemetry.

**While unresolved**, the session's own actors don't run:
- **the token provider** is inert: it presents nothing, refreshes nothing, writes nothing and
  fires no `onUnauthenticated`;
- **the transport** doesn't connect;
- **the auth controller** is **waiting**, which is distinct from logged-out: it takes no auth
  action and runs no teardown, and the UI shows a neutral screen.

The island the other readers see (`configProvider`) is a guess from the prefs evidence
(`ranAnOlderBuild`). It reaches only unauthenticated reads (a manifest, a health check), never a
credential.

**Resolution runs again** whenever the Keychain may have opened:
- on app resume;
- on the call-answer kick (`TransportWakeReason.answered`), awaited before the transport
  connects.

It's the same function as boot's, serialised in the vault. Once it's resolved:
- if L differs from the guess, the island becomes L and is saved (the session is the truth, and
  no credential is cleared);
- then the provider, the transport and the auth controller start for L, and restore runs.

On the locked-call path, Face ID unlocks the Keychain, the answer kick resolves the island, the
transport connects and the call joins, in that order. Design 23 already places the join after
Face ID.

**While a session exists, the saved island is a synchronous cache of its label.** When signed
out, it's the person's choice. Resolution is cache invalidation, and a reinstall is a cold cache.

### 2e. What a sign-in may replace

`setTokens` for island X replaces the item only in the states the table marks. A record for
another island isn't replaced by a sign-in. A sign-in on another island can only happen after a
switch, and the switch's clear-first teardown is unchanged (its atomicity is #447's).

## 3. What goes away

- **The guess as a credential actor.** Its provider, transport and auth flow don't exist while
  unresolved, so v2's adoption fences and guess write rule are gone.
- **The door's write**, and the label-first/delete-last ordering. There's one item.
- **The legacy pair as a durable source.** It's read at most once, and then retired.
- **Deleting an unplaceable session.** It becomes owner-unknown.
- **`IslandBoot.decided` as a default.** The default is unresolved.

## 4. What stays

- **The once-per-install settle**, now only after a readable answer of "no presentable session",
  and blind to old-build evidence once this build has run.
- **`ranAnOlderBuild`**, only to pick the unresolved guess.
- **`prod.json` pinned to `kDefaultIslandBaseUrl`** by test.
- **Explicit sign-out clears whatever is stored.**

## 5. Named tradeoffs and residuals

- **Placement steps 2–3 are an inference.** NAMED TRADEOFF, owner: app tab.
  - It runs once and is recorded. Without it, every existing signed-in user is signed out by the
    update, which would reverse Nick's decision.
  - It rests on two verified invariants (section 1).
  - Releases 0.0.1 to 0.0.5 can't be checked by tag. An install that never opened a cache-writing
    build becomes owner-unknown, which is the safe direction.
- **The island's identity is its URL.** NAMED RESIDUAL.
  - A host move must migrate the saved island and the label in the same release.
  - The durable fix is cross-repo: an `iss` claim carrying a stable island id. That goes to the
    island tab.
- **Rollback.** An older build reads only the legacy pair, which this build retires, so a rollback
  starts signed out.
- **The four lifecycle races are on `main` today,** and #447 owns them. This design neither
  widens nor narrows them.

## 6. Tests to write (observable outcomes under adversarial orderings and crash states)

Each must fail on #439 at `6821909`, or on v2 as written, for the reason it names.

- **A reinstall, owner-unknown.** Boot 1 places it as owner-unknown and the settle saves Enspyr.
  Boot 2 doesn't re-place it on Enspyr and never presents it, and a 401 doesn't clear it. (This
  is v2's leak.)
- **A locked reinstall with a record for imagineering.**
  - While unresolved: nothing presented, no `onUnauthenticated`, no teardown, no transport
    connect.
  - After the answer kick: the island resolves to imagineering and the call connects there.
  - This also reproduces the `6821909` deletion-by-teardown, and must fail there.
- **An updating install** (legacy pair, a cached user, no saved island): placed on imagineering
  at boot and recorded. A crash during placement re-places it next boot with the same answer.
- **A dev build's legacy pair** is owner-unknown unless `aiko_tokens_island` is present.
- **Unreadable data** in `aiko_session` is replaced by a sign-in and reported. A locked read
  isn't reported.
- **Sign-out at every crash point** presents nothing next boot. A failing tombstone write falls
  back to deleting.
- **A stale cache fill, refresh commit or refresh rejection** has no effect after `setTokens` or
  `clearTokens`.
- **Nothing that never ran boot** saves an island or presents a session.
- **Mutation-check every one.**
