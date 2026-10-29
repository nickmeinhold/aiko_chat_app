# Design 26: a session knows its island

**Status:** v2, 2026-10-29, for `/design-temper` round 2 of at most 3. v1 was struck RECAST 4/4
(`26-TEMPER.md`); v2 folds flaws 1–6, 9 and 10, and records 7 and 8 as named tradeoffs. It recasts
the credential half of PR #439 (https://github.com/nickmeinhold/aiko_chat_app/pull/439), whose
cage-match stopped at round 2 on two round-cap stop signals; the ledger is at
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

## 2. The design (v2)

### 2a. One record, and a durable end to the old format

The session is one Keychain item, `aiko_session`, with today's accessibility (design 23's
delete-then-add trap stays out of reach). It holds one of:
- a **record**: `{"v":1,"island":…,"access":…,"refresh":…}`;
- a **tombstone**: `{"v":1,"signedOut":true}`, written by sign-out.

**The legacy pair** (`aiko_access_token`, `aiko_refresh_token`) is read **only when no
`aiko_session` item exists at all**: neither a record nor a tombstone. Once this build has
written either one, the old format is retired for good, and crash order can't bring it back:
- sign-out writes the tombstone (one item), then deletes the legacy items;
- a crash between the two leaves a tombstone, and the legacy pair is never read again.

**The three-key format from PR #439's branch never shipped.** On a dev device that ran it,
`aiko_tokens_island` is a real label for the legacy pair beside it and is read as one (2b).

### 2b. Placing an old session, once

When the legacy pair is read (no `aiko_session` item exists), its island is, in order:
1. `aiko_tokens_island`, if present (dev devices that ran #439's branch only);
2. on a store build, **the saved island**, if there is one. An older build used it, and a switch
   cleared the tokens, so it is that pair's island;
3. on a store build with no saved island, **`kLegacyDefaultIslandBaseUrl` if a cached user exists**.
   The cached user lives and dies with the tokens, so it proves an older store build ran HERE on
   its compiled default. This is checked: the cached-user store (`f65906b`, #71) is an ancestor of
   every tagged release;
4. otherwise **unplaceable**, and always unplaceable on a dev build: the current `--dart-define`
   says nothing about which island an older dev build used.

**This runs once per install, inside the vault (2c), and its answer is recorded:** a placed pair
is rewritten as a record. It never reads the island currently on screen.

**An unplaceable pair is quarantined, not deleted:**
- it's never presented;
- a 401 never clears it;
- a sign-in replaces it.

It expires on its own. Island refresh tokens are fixed at 30 days from sign-in (island
`security.py`; app #427 isn't built), and the tokens carry no `iss` that could place them. So
quarantine costs nothing, and a delete would only be an irreversible step on something that
expires anyway. This survives refresh-token rotation (#427): rotation changes a token only when it's refreshed,
and a quarantined session is never presented, so it's never refreshed and keeps the fixed `exp`
in its token.

### 2c. One session authority

`SecureTokenStore` becomes the **vault**, the single authority over the session. Every operation
that reads a session to publish it, or writes one, runs **serially** inside the vault, and every
replacement or clear advances its **generation**.

`DefaultTokenProvider`, built per island, holds no authority of its own. Each of its operations
captures the vault's generation when it starts and loses its effect if the generation has
moved by the time it finishes. That applies to every one of them:
- a cache fill (a read started before a sign-in can't publish the old pair after it);
- a refresh's commit (it can't bring a signed-out session back);
- a rejection's clear (it can't delete the next session);
- the shared `_inFlight` (a new session never joins the old session's refresh);
- `onUnauthenticated` (a stale rejection can't sign the new session out).

**The door** presents a session only if its island is this provider's island. A session for
another island is left alone: not presented, not cleared by a 401. The door never writes. The
one write on a read path is 2b's placement, and it runs inside the vault, serialised with
sign-in and sign-out.

**Explicit sign-out** writes the tombstone, whoever issued the session (`_clearCredentialAndUnpair`
depends on that).

### 2d. The island follows a readable session

**Boot** (`main()`, before `runApp`, awaited; nothing it does can stop the app starting) reads
the vault:
- **a session for island L:** L is the island, saved if it isn't already;
- **positively no session** (absent, a tombstone, or quarantined): the settle decides
  (fresh → Enspyr; a signed-out older build with a passkey hint for the old default →
  imagineering) and saves;
- **unreadable** (locked, thrown, malformed, an entitlement error, all one branch): **nothing is
  saved and nothing is deleted.** The island shown for this launch is a guess, from the prefs
  evidence (`ranAnOlderBuild`). It is marked a guess.

The fact "this island is a guess" lives in the provider graph (`islandResolutionProvider`), not
local to `main`. Its default, for anything that never ran boot, is **unresolved: don't save.**
That fixes #439 round 2's finding 4 in the right direction.

**When the vault later reads a session for island L** (the first read after Face ID) and the
island shown is a guess other than L, the app **adopts L**: the shown island becomes L and is
saved, with no token cleared, because the session IS the truth. The backend rebuilds for L, and
L's provider presents the session.

**A guess can't write over a session.** A sign-in replaces the record only when the vault holds
nothing, a tombstone, a quarantined pair, or a session for the same island. `switchIsland`
reads the label first:
- if it equals the destination, it retargets without clearing;
- otherwise it's an explicit discard, read first and then cleared, as today's teardown is;
- if the vault is unreadable, the switch waits; it neither clears nor saves.

**Considered and rejected: no guess at all.** Hold the whole app until the Keychain answers.
That would delete the guess, and with it the need for adoption and the write rule. But the root
builds the transport at startup (`main.dart:95` → `transportWakeProvider` → `configProvider`),
19 files read the island, and the call-answer path (design 23) listens for native events from
the first frame. A gate in front of it risks the path design 23 just hardened. **Open to the
temper.**

### 2e. Keychain errors

`errSecInteractionNotAllowed` (-25308, locked) is expected and quiet. Every other failure
(-34018 entitlement, a malformed record, an exception) takes the same unreadable branch, and is
reported to telemetry so a permanently unreadable Keychain is visible.

## 3. What goes away

- **The door's write** (v1's lazy "migrate in place"). Placement is the vault's, serialised.
- **`IslandBoot.decided` as a default.** The default is now "unresolved: don't save".
- **The label-first/delete-last ordering** in `SecureTokenStore`. One item, plus a tombstone.
- **Deleting an unplaceable session.** It's quarantined.
- **Generation checks on the refresh write only.** The generation covers every operation.

## 4. What stays

- The once-per-install settle and its saved answer, now saved only after a positive "no
  session" read.
- `ranAnOlderBuild`, now only to pick the guess on an unreadable launch.
- `prod.json` pinned to `kDefaultIslandBaseUrl` by test.
- Explicit sign-out clears whatever is stored.

## 5. Residuals and named tradeoffs

- **The legacy placement (2b, steps 2–3) is an inference.** NAMED TRADEOFF, owner: app tab.
  - *Why it stays.* It runs once per install and its answer is recorded. Without it, every
    existing signed-in user is signed out by the update, which reverses Nick's decision.
  - *What it rests on.* Two checked invariants: a switch clears the tokens, and the cached user
    is present on every tagged release. Releases 0.0.1 to 0.0.5 can't be checked by tag. An
    install that never opened a cache-writing build is unplaceable, which is the safe direction.
- **The island's identity is its URL.** NAMED RESIDUAL. A host move must migrate the saved island
  and the label in the same release, owned by whoever moves the host. The durable fix is
  cross-repo: an `iss` claim carrying a stable island id in the island's JWTs, so every future
  token names its issuer. That goes to the island tab, which co-owns identity.
- **Rollback.** An older build reads only the legacy pair, which this build retires. A rollback
  (in practice an internal tester sideloading) starts signed out.
- **Quarantine relies on a quarantined token's own `exp`.** It holds under #427's rotation,
  because a quarantined session is never refreshed (2b). It would stop holding if the island ever
  honoured expired refresh tokens.
- **A dev build's sessions are labelled with the dev island.** A store build installed over that
  Keychain follows it. The label is telling the truth.

## 6. Tests to write (outcomes under adversarial orderings and crash states, not storage-call counts)

Each must fail on PR #439 at `6821909`, or on v1 as written, for the reason it names.

- **Resurrection.** For every point a process can die inside sign-out, the next launch presents
  nothing.
- **Stale cache.** A read started before `setTokens` can't publish the old pair after it.
- **Stale refresh.** A refresh that completes after `clearTokens` doesn't restore the session. One
  rejected after a new `setTokens` doesn't clear the new session or fire `onUnauthenticated`. A
  new session never joins the old one's in-flight refresh.
- **A locked reinstall.** For a labelled session for imagineering, after a locked boot the guess
  is Enspyr. The first readable read adopts imagineering and presents there. A sign-in attempted
  on the guess before that read can't replace the session.
- **An updating install.** With a legacy pair, a cached user and no saved island, it's placed on
  imagineering once and recorded. A crash during placement re-places it on the next read, with
  the same answer.
- **A reinstall's legacy pair** (no preferences) is never presented, isn't cleared by a 401, and
  is replaced by a sign-in.
- **A dev build's legacy pair** is unplaceable unless `aiko_tokens_island` is present.
- **Boot.** A throwing `setString` or Keychain read still reaches `runApp`. An unreadable launch
  saves nothing, and nothing that never ran boot saves either.
- **Telemetry.** A non-locked Keychain error reaches it; a locked one doesn't.
- **Mutation-check every one.**
