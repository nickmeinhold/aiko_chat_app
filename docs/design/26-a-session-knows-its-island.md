# Design 26: a session knows its island

**Status:** draft, 2026-10-29, for `/design-temper`. It recasts the credential half of PR #439
(https://github.com/nickmeinhold/aiko_chat_app/pull/439), whose cage-match stopped at round 2
on two round-cap stop signals. The ledger is at
https://github.com/nickmeinhold/aiko_chat_app/pull/439#issuecomment-6495723068.
**Product decision (Nick, 2026-10-29):** a reinstall keeps the person signed in. The design
records the island that issued every session it writes, so those survive any reinstall. The one
exception is a session an older build wrote, on an install whose preferences a reinstall wiped:
nothing can place it, so it's cleared (section 5).
**Touches a trust boundary:** which island a credential is presented to.

## 0. The producer question: what lets a stored session exist without a known owner?

**The bad outcome.** One island's access or refresh token is sent to another island. That
island answers 401. The app reads the 401 as a revocation and deletes the credential, so the
person loses a working session on the island that issued it.

**What produces it.** A session and the record of which island it belongs to live in two
stores with different lifetimes:
- the island choice is a SharedPreferences key (`aiko_island_base_url`);
- the tokens are Keychain items (`aiko_access_token`, `aiko_refresh_token`).

iOS and macOS delete preferences on an uninstall and keep the Keychain. After a reinstall the
app holds a session with no record of its island, and every rule so far has *inferred* one
from the other:
- round 1: "tokens exist" was read as "imagineering's tokens";
- round 2: "no tag" was read as "this island's tokens".

Each inference was right in some states and wrong in others. Both rounds' findings sat where
the inference went wrong.

**Removing it.** Make the island part of the session, written in the same single Keychain
item, so a session can't exist without its owner. Then nothing infers ownership from
anything else. The one exception is a session written by an older build, which never recorded
an owner. Its owner comes from a fixed rule that doesn't depend on where the app happens to be
pointed at the moment (section 2b).

## 1. Facts this rests on

These were verified in code and need no re-deriving:
- **One door.** `DefaultTokenProvider` (`lib/core/auth/token_provider.dart`) is the only code
  that reads tokens to present them and the only code that writes them. It's built per island,
  by `buildGatewayBackend(baseUrl: config.httpBaseUrl, ...)`.
- **A switch clears.** `switchIsland` clears the tokens before it changes the island, so a
  session is always the session of the island that was current when it was written.
- **Locked reads throw.** Tokens are `kSecAttrAccessibleWhenUnlocked` (design 23, Nick
  2026-10-10). On a locked phone a Keychain read throws until Face ID. That is intended: a call
  answered on a locked iPhone connects after Face ID.
- **No other doors.** There's no Dart background isolate (`onBackgroundMessage` and
  `vm:entry-point` appear nowhere in `lib/`), and native code never reads the island key.
- **A session comes from an island.** Every cached-user write follows a REST answer, and every
  REST client is built from `configProvider`. So within a launch the island resolves before
  any session is recorded.
- **Refresh writes.** An access-token refresh writes the pair back (`_doRefresh`).

## 2. The design

### 2a. One record

The session becomes a single Keychain item, `aiko_session`, holding
`{"v":1,"island":…,"access":…,"refresh":…}`, written and deleted as one item, with the same
accessibility as today.
- **No accessibility change.** That keeps it clear of design 23's "delete-then-add" trap.
- **Atomic.** One item can't show one island's label beside another island's tokens. The
  label-first/delete-last ordering from round 2 goes away.
- **Old format.** The two legacy items are read only to migrate them (2b).
- **`clear()`** deletes `aiko_session` and both legacy items.
- **`write(tokens, island:)`** writes `aiko_session`, then deletes the legacy items. If the
  process dies between the two, both formats exist, and reads prefer `aiko_session`.

### 2b. Who owns an old session

A session an older build wrote has no island. Its owner can be known only from THIS install's
own preferences, and only two facts in them can establish it:
1. **The saved island** (`aiko_island_base_url`). An older build always used it when it had one,
   and switching islands cleared the tokens, so it's that session's island.
2. **No saved island, but a cached user.** The cached user lives and dies with the tokens, so it
   proves the older build that wrote this session ran *here*, with nothing saved, which means on
   its compiled default. That's `kLegacyDefaultIslandBaseUrl` on a store build, and the
   `--dart-define` island on a dev build.

**Neither fact:** the session **can't be placed**. A reinstall wiped this install's preferences,
and any island would be a guess. It's never presented, and boot deletes it once the Keychain is
readable. The sovereign identity key is a different item and is untouched. The person signs in
again with their passkey.

This is one pure function, `ownerOfLegacySession(prefs)`, returning an island or "unplaceable",
used everywhere below. **It never reads the island the app is currently pointed at.** In round 2
the app was pointed at a guess (the settle's in-memory island on a locked launch), and that guess
was what got the old session presented to the wrong island.

Nick's decision is about what this design writes. Every session this build writes carries its
island, so every future reinstall keeps its session. The only sessions that fall back to signing
in are older builds' sessions that lost their preferences: a one-time residue that shrinks to
nothing as installs open this build, because the door labels a legacy session on its first read
(2c).

### 2c. The door

`DefaultTokenProvider` presents a stored session only if it is this island's:
1. read the session (one item read; fall back to the legacy pair);
2. if it's legacy, its owner is `ownerOfLegacySession(prefs)`. If that's this island, migrate
   it in place (write `aiko_session` tagged with the owner), then present it. If it's another
   island, or unplaceable, don't present it;
3. if it's tagged with another island, don't present it, and don't delete it.

Explicit sign-out (`clearTokens`) still clears everything, whoever issued it.
`_clearCredentialAndUnpair` depends on that: a signed-out app must never leave a live
credential for the next cold start.

Because ownership is decided when a token is *read*, a read that only succeeds after Face ID,
later in the same process, gets the same answer as a read at boot. No flag carries "boot
couldn't read" through the process. That's what removes round 2's finding 2 and the `decided`
default that couldn't report its own absence (finding 4).

### 2d. Boot: choose the island to show

`main()` resolves the island before `runApp`, awaited, and nothing it does can stop the app
starting:
- **an island is saved:** done (the door migrates any legacy session lazily);
- **a tagged session:** save its island;
- **a legacy session with an owner:** save that island and migrate the session;
- **an unplaceable legacy session:** delete it, then let the settle decide as for no session;
- **no session:** the settle decides (fresh install → Enspyr; a signed-out older build with a
  passkey hint for imagineering → imagineering), and saves its answer;
- **the Keychain refuses (locked):** the settle picks an island **for this launch only** and
  saves nothing. The door still won't present another island's session (2c). The guess picks
  the screen; it can't move a credential.
- **every write's result is checked**, and an exception never escapes `main()`. A failed save
  leaves the decision to the next launch, where the session's own label answers it.

The settle's in-memory choice for a locked launch still uses the prefs evidence (a cached user,
or a passkey hint for the old default). That matters to the largest group: existing users whose
first launch after the update is a call on a locked phone. They land on imagineering, Face ID
unlocks the session, and the door migrates it and presents it there.

### 2e. Keychain errors are not all "locked"

The boot read distinguishes `errSecInteractionNotAllowed` (-25308, locked) from everything else
(for example -34018, a broken entitlement). "Locked" is quiet: it's expected. Anything else is
reported to telemetry, so a permanently unreadable Keychain is visible, not silent.

### 2f. A session's refresh ends with the session

A refresh in flight belongs to the session that started it. `DefaultTokenProvider` keeps a
generation number, which `setTokens` and `clearTokens` advance. A refresh that completes in a
later generation is discarded:
- a success doesn't rewrite the store, so a refresh can't bring a signed-out session back;
- a rejection doesn't clear the store, so it can't delete the next session.

This predates #436 (round 2, finding 3) and rides along because it's the same door.

## 3. What goes away

- **`pinIslandForSurvivingTokens`'s inference.** Boot reads the session's label, or applies 2b.
- **`IslandBoot` as a process-wide flag**, and its `decided` default that couldn't report its own
  absence. The door decides per read. Boot keeps one local fact: "the Keychain refused, so don't
  save this launch's guess".
- **The label-first/delete-last ordering** in `SecureTokenStore`.
- **"Untagged means mine"** at the door.

## 4. What stays

- The once-per-install settle and its saved answer: the trap where a fresh install's own sign-in
  reads as older-build evidence stays closed.
- `ranAnOlderBuild` (prefs evidence), now only for the island shown on a launch with no
  readable session.
- `prod.json` pinned to `kDefaultIslandBaseUrl` by test.

## 5. Residuals, named

- **An unplaceable legacy session signs the person out once.** That's an older build's session on
  an install whose preferences a reinstall wiped. Before #436 it would have been restored on
  imagineering, which was right for imagineering users and a credential leak for anyone on
  another island (Enspyr via the picker on 0.0.8, for example). Now it's cleared:
  - imagineering users who reinstall before ever opening this build sign in again, and must
    switch to imagineering first, because a fresh install starts on Enspyr;
  - this is the one place the design trades a sign-in for safety; it applies once per install;
  - **open to the temper:** is that cost acceptable, or is there a fact that can place these
    sessions that this note missed?
- **A dev build's sessions are labelled with the dev island.** A store build installed over that
  Keychain pins the dev island. The label is telling the truth. Dev machines only.

## 6. Tests to write (each must fail on PR #439 at `6821909` for the reason it names)

- A crash between the label write and the pair write can't relabel a foreign pair: there's one
  item, so test that a write is one storage operation.
- A legacy session on a reinstall (no preferences): it's never presented, to Enspyr or
  imagineering, including on a read after unlock in a locked-boot process, and the next readable
  boot deletes it.
- The same sequence on an updating install (preferences present, cached user present): it is
  presented to imagineering, after Face ID, in the same process.
- A refresh that completes after `clearTokens` doesn't restore the session, and one rejected
  after a new `setTokens` doesn't clear it.
- Boot with a throwing `setString` still reaches `runApp`.
- A non-locked Keychain error reaches telemetry; a locked one doesn't.
- Mutation-check every one.
