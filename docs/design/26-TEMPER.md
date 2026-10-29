# 26-TEMPER.md — design 26, a session knows its island

**Overall verdict:** RECAST (4 of 4 families, no DISSOLVE). Temper round 1 of at most 3.
**Struck:** dt-1793274526. Families seated: Maxwell + Noether, Carnot, Tesla (Wu disabled).
**Bundle:** `docs/design/26-a-session-knows-its-island.md` at `61f841b`, the #439 round-1/2 ledger, and `secure_token_store.dart`, `token_provider.dart`, `providers.dart` at PR #439 head `6821909` (41.9KB).

## Per-family verdicts

| Family | Verdict | One line |
|---|---|---|
| Maxwell (Claude) | RECAST | The single record is right; a door that writes (lazy migration) races the real writers, and the island's identity is its URL |
| Carnot (GPT) | RECAST | Atomic storage isn't an atomic lifecycle: migration, refresh and sign-out can still undo one another without one session authority |
| Noether (DeepSeek) | RECAST | The legacy owner rule swaps one inference for another; `clear()` isn't one operation; 2f misses the shared in-flight refresh and the sign-out event |
| Tesla (Grok) | RECAST | The guessed island can still WRITE: a sign-in or switch on the guess destroys the labelled session Nick's decision says survives |

## Facts checked during synthesis

- **The island's tokens don't name their island.** The JWT payload is `sub`, `type`, `gen`, `iat`, `exp`, with no `iss` or `aud` (island `src/aiko_gateway/domain/security.py:35-46`, `main` at `781fdb7`). So Tesla's "the unplaceable set is empty" doesn't hold; old unlabelled sessions really can't be placed from the token.
- **But they expire.** A refresh token is fixed at 30 days from sign-in (it never slides; app #427 isn't built). So every pre-#436 session dies on its own within 30 days of the release that ships this. Quarantining one costs nothing; deleting one is an irreversible step on something that would expire anyway.
- **The three-key format never shipped.** `aiko_tokens_island` exists only on PR #439's unmerged branch (`6821909`). Only a dev device that ran that branch can hold it.
- **The cached-user evidence exists on every tagged release.** The cached-user store landed 2026-07-11 (`f65906b`, #71) and is an ancestor of every tag (`android/v0.0.6+17` onward). Releases 0.0.1 to 0.0.5 predate tagging and can't be checked this way.

## Fatal flaws (deduped, most severe first)

1. **No single lifecycle authority.** Raised by all four. Each of these can undo or resurrect a session:
   - the door's lazy migration (a reader that writes);
   - a cache fill that crosses a sign-in;
   - a stale refresh's commit or clear;
   - a shared `_inFlight`;
   - a stale `onUnauthenticated`.

   DISPOSITION, fold into v2: one session authority (the vault) serialises every read that publishes and every write. Each operation carries a generation, and an operation from an older generation can't write, clear, fill the cache, share an in-flight refresh or fire the sign-out event. The door decides and never writes.
2. **The guessed island can write.** Raised by Tesla. On a locked reinstall, the guessed island's sign-in replaces the labelled session, or its `switchIsland` deletes it.

   DISPOSITION, fold: **the island follows a readable session.** When the vault first reads a labelled session and the current island is an unsaved guess, the app adopts the label's island (non-destructively) and saves it. A write may replace the record only when it's absent, holds the same island, or a discard has read the label. `switchIsland` reads the label first.
3. **The don't-save fact never reaches the saver.** Raised by Tesla; it echoes #439 round 2's finding 4. The settle in `IslandConfigController.build` saves unless told not to, and v1 deleted the only flag that told it.

   DISPOSITION, fold: the settle saves only after a positive read of "no session item". The default when nothing has read the Keychain is DON'T save. Locked, thrown, malformed and entitlement failures are one branch: save nothing, delete nothing, telemetry for anything that isn't the expected lock.
4. **`clear()` can resurrect across a crash.** Raised by Carnot, Noether and Tesla. If the new record is deleted first and the process dies, the legacy pair survives and is migrated forward.

   DISPOSITION, fold: retire the legacy format durably. `clear()` writes a tombstone record (one item), then deletes the legacy items. The legacy pair is read only when no `aiko_session` item exists at all.
5. **The dev-build legacy rule reads the current define.** Raised by Carnot and Noether.

   DISPOSITION, fold: an unlabelled session on a dev build is unplaceable.
6. **Deleting an unplaceable session is a second, irreversible producer.** Raised by Tesla.

   DISPOSITION, fold: quarantine. It's never presented to a guess, never cleared by a 401, and replaced only by a sign-in. It expires within 30 days (see Facts).
7. **The legacy owner rule is still an inference.** Raised by Noether.

   DISPOSITION, **named tradeoff** (owner: app tab):
   - **Why it stays.** It runs once per install, under the vault, and its answer is recorded as a label. Without it, every existing user is signed out by the update, which reverses Nick's decision. Noether's alternative, treating all legacy sessions as unplaceable, does exactly that.
   - **What it rests on.** Two verified invariants: a switch clears the tokens, and the cached user is present on every tagged release.
8. **The island's identity is its URL.** Raised by Maxwell. A host move refuses every labelled session.

   DISPOSITION, **named residual + cross-repo follow-up**. A host move must migrate the saved island and the label in the same release. The durable fix sits on the island side: an `iss` claim carrying a stable island id would make every future token name its issuer. That's for the island tab, which co-owns identity.
9. **Tests counted storage calls, not outcomes.** Raised by Carnot and Noether.

   DISPOSITION, fold: test the observable outcome under adversarial orderings and crash states: no presentation to the wrong island, no resurrection, no deletion by obsolete work.
10. **v1 didn't say whether the three-key format shipped.** Raised by Noether. DISPOSITION, fold: state it (see Facts). A dev device holding `aiko_tokens_island` has a real label, and v2 reads it.

## What holds

- **One Keychain item for the session**, with no accessibility change: the torn label/token record from #439 round 2 can't occur (all four).
- **The door decides per read.** No process flag pretends to know the Keychain's answer (Maxwell, Noether).
- **A foreign labelled session is left in place on the read path.** A 401 clears only the session it was issued for (all four).
- **Explicit sign-out clears whatever is stored** (Noether, Tesla).
- **2e and 2f's intent:** a broken entitlement isn't a locked phone, and an obsolete refresh can't write (all four).
- **Refusing to guess** for a session nothing can place (Carnot).

## Disposition

**RECAST.** Fold flaws 1–6, 9 and 10 into design 26 v2, record 7 and 8 as named tradeoffs, and re-strike (temper round 2 of at most 3).

Build note for afterwards: the vault is its own PR, and #439 (the default flip) rebases on it. The two changes have different blast radii, and #439's diff should stay reviewable at full context.

<!-- Each section below was written when that family returned, before the others
     finished. Arrival order, NOT a ranking. Round 6 replaces this header with the
     synthesized verdict; if it never runs, what is here is still real. -->


---

## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST

**Summary:** Putting the island inside the session record is the right move, and it removes the producer for every session this build writes. But section 2c makes the DOOR a writer (it "migrates in place"), and a reader that writes races the real writers. That's the illegal move. There's one wrong identity choice too: the island is keyed by URL.

**Producer first:** The bad outcome: one island's session is presented to another, and that island's 401 deletes it. The producer is a session stored without its island, plus an island choice made independently of it. 2a removes the first half for every session this build writes, because the label can't be separated from the tokens.
- **The door stays, with a stated reason.** Its check (config island vs label) remains because the island shown can still be chosen without reading the session. `configProvider.build` is synchronous, and on a locked phone the Keychain read throws until Face ID (design 23, Nick 2026-10-10). That second half can't be removed without making config async or teaching it to follow a session non-destructively, and both cost more than a comparison at the one door.
- **The legacy rule (2b) is the one inference left.** It applies only to residue. When it can't place a session it clears it, which errs toward a sign-in, never toward a leak.

**Fatal flaws:**
- **[coupling to remove] 2c makes the door write ("migrate it in place"), which can resurrect an old pair over a fresh session.**
  - The race: a token read (a WSS reconnect calling `currentAccessToken`) reads the legacy pair and decides it's ours. Meanwhile sign-in calls `setTokens`, which writes `aiko_session` and deletes the legacy items. The read then finishes its "migration" by writing the OLD pair into `aiko_session`, so the person's new session is silently replaced by the stale one.
  - Keychain has no compare-and-set, so no ordering of the door's writes fixes this.
  - Remove the coupling: the door decides and NEVER writes. Migration happens only at boot (before `runApp`, when nothing else runs). The first refresh or sign-in under this build writes a full labelled record anyway.
- **[broken invariant / missing failure mode] 2f's generation fences only the refresh's WRITE. The cache fill crosses generations too.**
  - `_cache ??= await _readOwn()` tests `_cache` before the await and assigns after it.
  - A read that started before `setTokens` (or `clearTokens`) assigns the stale pair (or the pre-sign-out pair) after it. The cache then serves the old session for the life of the provider, even though the store is right.
  - This predates #436, as the refresh race does, and it's the same door.
  - Fold: every await in the provider that ends in a cache or store write is fenced by the generation, not only the refresh's.
- **[under-counted blast radius] The island's identity is its URL.**
  - The label, the saved island and the door's comparison are all `httpBaseUrl` strings.
  - The day an island changes host, every labelled session for it stops matching and its people are shown a sign-in screen. Open question #7 (which island is "Enspyr Melbourne" and which is "Enspyr Sydney") suggests that day isn't hypothetical.
  - The tokens would still be valid at the new host: it's the same island, the same database, the same keys.
  - Fold: either label with a stable island identity, if ADR-0008's self-description provides one, or record as a named residual that a host move must migrate the saved island AND the session label in the same release, with the owner and the cost stated.

**What holds:**
- **2a's single record.** Atomicity comes from one item, not from ordering three. It needs no accessibility change, so design 23's delete-then-add trap is out of reach.
- **2b never reads the island currently on screen.** That's exactly where round 2's leak came from. And it refuses to guess, clearing instead, when this install's own preferences can't place the session.
- **Ownership decided at read time, not carried as a process flag.** A read that succeeds after Face ID gets the same answer as one at boot. That removes `IslandBoot`'s `decided`-means-nothing default.
- **Checked:** the cached-user store landed 2026-07-11 (`f65906b`, #71) and is an ancestor of every tagged release (`android/v0.0.6+17` onward). So 2b's cached-user evidence exists on every tagged build's restored session.
- **2e.** A broken entitlement stops looking like a locked phone.
- **2f.** A refresh that outlives its session can't bring it back or delete its successor.

**If RECAST, what to fold back:**
- **2c:** delete "migrate it in place". The door only decides. Migration is boot's job (2d), and the next `setTokens`/refresh writes the labelled record anyway.
- **2f:** extend the generation to every cache fill and store write in `DefaultTokenProvider`, and add a test where a read started before `setTokens` can't overwrite the cache after it.
- **Section 5, new residual:** the island's identity is its URL. A host move needs the saved island and the session label migrated together. Name the owner (whoever moves the host), or adopt a stable island id if ADR-0008 provides one.
- **Section 5, the cached-user assumption, sized honestly:**
  - verified for every tagged release (0.0.6 onward);
  - not verifiable by tag for 0.0.1 to 0.0.5;
  - an install that never opened a cache-writing build has no cached user, so it's unplaceable and signs in again. That's the safe direction.
- **Section 5, rollback:** writing `aiko_session` deletes the legacy items older builds read. A rollback, in practice an internal tester sideloading an older build, starts signed out. Name it.

John McClane: "Come out to the coast, we'll get together, have a few laughs." Single record, read-only door, generation everywhere. Then it's a party.


---

## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** The single session record removes real entropy, but atomic storage is being mistaken for an atomic session lifecycle. Migration, refresh, and sign-out can still undo one another. Dijkstra: "Simplicity is prerequisite for reliability." No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are.

**Producer first:** The harm is exposing a credential to the wrong island, destroying a working session, or restoring a session after sign-out. Reinstall, unlock, and delayed replies are triggers. Our producers are ownership inference, independent asynchronous store mutations, and an obsolete operation retaining authority to overwrite or clear the current session. The combined record structurally removes torn label/token combinations. It does not remove stale mutation authority. Put that authority in one shared session owner with ordered lifecycle operations. An ownership check remains justified where persisted credentials cross into an island-specific client: independently supplied island configuration cannot establish credential provenance.

**Fatal flaws:**
- Make resurrection and deletion of a replacement session impossible: give one shared session owner exclusive authority over migration, replacement, refresh commit, and deletion; then independent provider mutations and their local generation checks become unnecessary. Section 2f checks a generation when refresh completes, but does not specify an indivisible commit. A refresh can pass that check, begin an asynchronous write, and finish after clearTokens deletes the session. A rejection can similarly begin clearing before setTokens writes its replacement. Atomicity of each Keychain item does not order these operations.
- Lazy migration is another credential writer outside the proposed refresh protection. It can read legacy session A, suspend, then write A after sign-out or after replacement session B is installed. Likewise, currentAccessToken can finish a pending read after clearTokens resets its cache and repopulate it. The design needs lifecycle ordering for every reader that publishes credentials and every writer, not just the remote-refresh continuation.
- The claimed legacy provenance rule is false for dev builds. A cached user proves that an install ran, not which compiled default its previous executable used. Install an older dev build targeting A, then update it with a define targeting B while preserving preferences and untagged credentials: section 2b labels A's credentials as B's. This recreates the original credential disclosure. The current executable's define is not historical evidence.
- The migration's cleanup can resurrect superseded credentials across a crash. Section 2a explicitly permits both formats after writing a_session, while clear deletes three items without a durable invalidation protocol. If clear deletes the new record and the process dies before deleting the legacy pair, the next launch falls back to that pair and can migrate a signed-out session again. A single-item session does not make legacy fallback reversible or deletion atomic.

**What holds:**
- Co-locating island and tokens removes the original torn-record producer.
- Refusing to guess ownership for legacy sessions with no provenance is the correct trust-boundary decision.
- Keeping locked-launch selection unsaved and distinguishing operational Keychain errors are useful.
- The one-time sign-in cost for genuinely unplaceable legacy sessions is explicit and defensible.

**If RECAST, what to fold back:**
- Specify one shared session lifecycle authority, including ordering of pending reads, migration, refresh commits, replacement, sign-out, and provider disposal.
- Make legacy retirement durable before a migrated session can subsequently be cleared; define crash recovery for every intermediate state so fallback cannot revive retired credentials.
- Use only historically established legacy defaults. Treat changing dev-build defaults as unplaceable unless persisted provenance identifies the issuer.
- Test adversarial operation orderings and crash recovery through the observable outcome: no credential presentation, resurrection, or deletion by obsolete work. Counting storage calls does not establish those properties.


---

## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The conserved quantity at stake is *"a stored session's owner is a property of the session itself"* — the design conserves it for every session this build writes (island and tokens in one item), but for the legacy population it trades one inference for another, which is the same non-conserved quantity in a new coat.

**Producer first:**
- **Harm (as harm):** a live session on island X is destroyed — the person is logged out of a working account — because X's access/refresh token is presented to island Y, Y answers 401, and the app reads that 401 as a revocation.
- **Producer (ours):** the credential store permits a session to exist with *no recorded owner*, so the app must **infer** the owner, and the door then **presents** the inferred-owner credential to whatever island the app is on. The 401 is the trigger; the missing owner + the inference + the presentation is the producer.
- **Can it be removed?** For sessions *this build writes*, yes — and the design does it, in the right shape: island inside the same Keychain item, so a session cannot exist without an owner. That is a deletion of the producer, not a guard on it. Good.
- For sessions an *older build* wrote, the untagged pair already sits on the device — that residue is genuinely external and cannot be deleted. But the design does **not** make it unable to produce harm; it substitutes a new inference (`ownerOfLegacySession(prefs)`) for the old one and keeps the door's legacy fallback alive forever. That is a better guard on the same coupling for the very population that produced rounds 1 and 2 — the pattern the ledger told us to stop. The producer-free move is: **never present a legacy session to anyone.** At the first *readable* boot, migrate (tag) or delete it, and drop the door's legacy fallback entirely, so no read ever infers an owner. Then `ownerOfLegacySession`, the prefs read, and the multi-item clear window all become unnecessary. Cost: one sign-in for placeable legacy users — which section 5 already accepts for unplaceable ones.
- Checks whose producer genuinely cannot be deleted: 2e's error classification (the producer is `catch(_)` collapsing a broken entitlement into "undecided"; the untrusted-Keychain-error crossing is external — keep it). 2d's "check every write's result" (the producer is the deliberately-unawaited settle write; awaiting would be structural, best-effort is a stated choice — keep it).

**Fatal flaws:**
- **The legacy inference re-introduces the producer it claims to remove (2b/2c).** *Class: a better guard on the same coupling.* For the legacy population the door still infers an owner and still presents it. `ownerOfLegacySession` is a fresh inference resting on two invariants the design *asserts* rather than enforces — "the cached user lives and dies with the tokens" and "an older build's saved island is its tokens' island." A design whose whole thesis is "stop inferring ownership" should not open a second inference.
- **The premise about the old format is unverified and contradicts the code in the bundle (2a/2b).** *Class: wrong premise / unstated assumption.* 2a says "the two legacy items" and 2b says the owner "can be known **only** from prefs." But the store this design recasts (`secure_token_store.dart`) writes a **third** item, `aiko_tokens_island`, and `readIsland()`. If that format ever shipped, the design **discards a known in-store owner** and replaces it with a prefs guess. The design must state whether `aiko_tokens_island` shipped; if it did, read it.
- **`ownerOfLegacySession`'s dev branch reads the island the app is currently pointed at (2b).** *Class: the design's own broken invariant.* 2b says the function "**never** reads the island the app is currently pointed at," but its second fact is "the `--dart-define` island on a dev build" — and `IslandConfig.fromEnvironment()` *is* the current island. A dev rebuild with a changed define presents a foreign token to the new define. (Dev-only, but it is the exact symmetry the function claims to conserve.)
- **`clear()` and `write()` are not the single operation 2a claims (2a/§6).** *Class: under-counted failure mode — same class as round 2 finding 1, on the clear path.* One item is atomic, but `write` is write-then-delete-legacy and `clear` is up to three deletes with **no order specified**. A crash mid-clear either resurrects a cleared session (if `aiko_session` is deleted first and a legacy item survives) or fails to clear (if legacy is deleted first and `aiko_session` survives). §6's "test that a write is one storage operation" is unsatisfiable as written.
- **2f guards the store but not the other side effects of a stale refresh.** *Class: incomplete invariant.* The generation discards the store write, but `setTokens`/`clearTokens` do not invalidate `_inFlight` (single-flight is keyed on the provider instance, which survives a same-island sign-out/sign-in), so a new session can share — and be failed by — the old session's in-flight refresh; and a stale *rejection* can still fire `onUnauthenticated` and redirect the new session to login. The generation must cover the shared future and the event, not only the store.

**What holds:**
- Island in the same Keychain item as the tokens — the right shape; it kills the two-store/different-lifetime split for every session this build writes.
- The door deciding ownership **per read** instead of carrying an `IslandBoot.decided` flag — removes the round-2 default that could not report its own absence.
- "Don't present and don't delete a foreign session" — correctly scopes delete-on-401 to the token's own island.
- Explicit sign-out clears everything, whoever issued it — the right invariant to keep.
- 2e (classify locked vs. broken entitlement) and 2d ("check every write's result," nothing escapes `main()`) are correct guards for producers that cannot be deleted.

**If RECAST, what to fold back:**
- Resolve the legacy path to a *single* source: state whether `aiko_tokens_island` shipped; if it did, **read it as the owner** and use prefs only when it is absent. Delete the in-store fact never.
- Kill the producer for legacy too: **migrate-or-delete at the first readable boot and remove the door's legacy fallback.** The door then reads only `aiko_session`; `ownerOfLegacySession` leaves the read path; `clear()` becomes one delete; §6's test becomes true.
- If the inference is kept: enforce "cached user lives and dies with the tokens" structurally, and stop reading the current `--dart-define` (store the legacy default at migration, or treat dev as unplaceable).
- Specify `clear()` ordering (and the write window) explicitly, and reconcile it with "a sign-out must never leave a credential behind."
- Extend 2f: `setTokens`/`clearTokens` invalidate `_inFlight` and suppress `onUnauthenticated` on a generation mismatch — not just the store write.

---

## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** The one-item session is the right ore, and it still shakes itself to glass on a locked reinstall, because a second and third island-authority remain free to write.

Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration."

**Producer first:** The harm is a living session destroyed, or welded to the wrong island, after a reinstall that was supposed to keep the person signed in. The producer is ours: a presenter and a writer aimed by the prefs island or by the settle's in-memory guess, while the credential sits in a different lifetime inside the Keychain. The trigger (a locked phone, a crashed `clear`, a 401) is outside. The producer is not. It can be removed. While a session item exists, the only island a presenter may be built for is the island read from that item, and the only write allowed to replace the item is one that has read its label and names the same island, or an explicit discard that has read the label. A 401 may clear a credential only on a presenter built that way, because then the rejection is the issuing island itself and cannot be designed away. The door's match-check, the "guess cannot move a credential" claim (2d), and clear-on-switch as a safety property (section 1, 2c) then become unnecessary. Two checks stay because their producer cannot be deleted: the legacy quarantine, until a positive placement exists (an old item really can lack an owner), and the refresh generation (2f), because a reply already in flight cannot be unsent and must lose the capability to write when `setTokens` or `clearTokens` has moved on.

**Fatal flaws:**
- Make credential loss on the guessed island impossible: do not construct a presenter or a writer for an island the session item did not name. Design 26 §2d says a locked launch's guess "picks the screen; it can't move a credential," and §2c only refuses to present or delete on read. The screen is a writer. `write(tokens, island:)` replaces `aiko_session` outright (§2a), and §1's switch clears whatever is stored before the island changes. On the reinstall this design exists for, prefs are gone, so `ranAnOlderBuild` is false and the guess is Enspyr, including the VoIP wake §2d itself calls out. Face ID then unlocks an imagineering (or other) session which the Enspyr door will not present. The person signs in on the login screen that guess picked, or switches to the island they were actually on: the first replaces the surviving item, the second deletes it as its opening act. The session this build labelled, the one Nick's decision says survives any reinstall, dies in the gesture that tries to recover it. This is the same coupling as rounds 1 and 2 of [PR #439](https://github.com/nickmeinhold/aiko_chat_app/pull/439), heard one octave up: three authorities for one fact (prefs, label, guess), and the one that could not read still gets to write.
- The don't-save fact cannot reach the saver, so a wrong pref silences the label forever. §3 retires `IslandBoot` and keeps "one local fact" inside boot: Keychain refused, do not save. The settle that actually writes `aiko_island_base_url` lives in `IslandConfigController.build` / `settleUnsavedIsland`, which saves unless something tells it not to, and today that something is the flag this design deletes. §2d's precedence then makes "an island is saved" return before "a tagged session: save its island." One deaf save of Enspyr and every later boot is done. The label never speaks again. §2e splits `errSecInteractionNotAllowed` off for telemetry and never says a thrown read, a malformed body, or `-34018` is the same as locked: save nothing, delete nothing. The sentence "the next launch, where the session's own label answers" is true only while the pref is absent. A saved guess is a point of no return the design does not have.
- `clear()` can resurrect the session it just killed. §2a makes the new record one item, then leaves the legacy pair as a second source that §2c will migrate the moment `aiko_session` is absent. Write order is specified (new item, then delete legacy). Clear order is not. Delete the new item first, crash, legacy remains, next boot runs `ownerOfLegacySession` and writes the pair forward. §2c's own invariant, "a signed-out app must never leave a live credential," fails across process death. The in-memory generation in §2f does not see that launch. Delete legacy first and a crash can only leave the person signed in. That state is the one the migration reader is currently able to produce in the dangerous direction.
- §5's deletion of an unplaceable legacy session is a second producer, aimed at the residue the temper was asked to bless. Never presenting it is what stops the leak. Deleting it is what makes the sign-in permanent, and it is irreversible, and a locked boot cannot do it yet, so the clobber above gets there first. §2b asserts the owner "can be known only from this install's preferences" without a fact in §1. These are JWTs. If the access token names its island, the unplaceable set is empty and the delete is the design inventing a loss. If it does not, that negative fact belongs in §1, and the item still stays quarantined: a later choice of island may try a refresh, and a 401 on an unlabeled item must not clear it, or the recovery attempt becomes the revocation.

**What holds:**
- One Keychain item, same accessibility as design 23, written then legacy-deleted, so a crash can no longer fasten one island's label to another's tokens (§2a). That really does kill round 2's finding 1.
- A tagged session that is not this presenter's island is left in place on the read path (§2c step 3). The read path is the part that learned.
- A refresh completion that belongs to an older generation must not write and must not clear (§2f). Keep that binding.
- The no-session settle, saved once, so a fresh install's own sign-in cannot later masquerade as an older build (§4). It holds only after a positive read that the session item is absent.
- The sovereign key stays a different item (§5). Right boundary.

**If RECAST, what to fold back:**
- In §2a and §2c, a write may replace `aiko_session` only when the item is absent, or its island equals the writer's, or a discard ceremony has read the label and chosen to drop it. `switchIsland(dest)` reads first. If the label equals `dest`, retarget and do not clear. If the Keychain will not answer, do not clear and do not change the saved island. The ceremony waits until the label is readable.
- In §2d and §3, name every saver of `aiko_island_base_url`. The don't-save fact has to be visible to `IslandConfigController`, not local to `main`. The settle runs only after a positive read of "no session item." Locked, thrown, malformed, and entitlement failures are one branch: telemetry where it is not the expected lock, save nothing, delete nothing, build no presenter. After unlock, the label chooses the island, then the call connects.
- In §2a, `clear()` deletes the legacy items first and `aiko_session` last. State the crash residue: signed-in is the allowed failure; legacy-only after a signed-out new item is not a representable state.
- In §1 and §5, record whether the access token names its island. If it does, `ownerOfLegacySession` reads that and the unplaceable branch is gone. If it does not, quarantine instead of delete: never present to a guess, never clear on a 401 until the item is labeled with the island that rejected it. The one-time sign-in cost is then a choice the person makes, not a boot delete they cannot undo.



---
---

# Round 2: v2 at `4575b05`

**Overall verdict:** RECAST (Noether, Carnot, Tesla RECAST; Maxwell SOUND). **Maxwell's SOUND was
wrong:** it missed flaw 1 below, a real leak, which is the author-instance-can't-grade-its-own-
homework case this temper exists for. Temper round 2 of at most 3.

## Fatal flaws (deduped, most severe first)

1. **Quarantine isn't durable, so the next launch places the pair on the island the settle just
   saved.** Raised by Tesla and Noether; verified against v2's own text.
   - **The path:** an unplaceable pair stays in the legacy items. §2d counts "quarantined" as no
     session, so the settle saves Enspyr. On the next launch §2a still finds no `aiko_session`,
     re-reads the pair, and §2b step 2 places it on the saved island, which is the settle's own
     Enspyr. An imagineering session is labelled Enspyr and presented there.
   - **FOLD:** placement runs before the settle and writes a durable owner-unknown state into
     `aiko_session` before boot returns. The legacy pair is never read again. An island the
     settle saved is never an input to placement.
2. **A credential actor for a guessed island can bury a foreign session through the logout
   event.** Raised by Tesla and Carnot, plus Noether's "adoption is an unfenced write".
   - **Verified in code, and it defeats PR #439's `6821909` too.** When the door refuses, the
     refresh with nothing of its own calls `_markUnauthenticated(clearStore: false)`. That fires
     `onUnauthenticated`, which reaches `authEventsProvider`, then `_becomeUnauthenticated`
     (`auth_controller.dart:204-205`), then `_teardownResources`, then
     `_clearCredentialAndUnpair`, which clears the store unconditionally.
   - **FOLD:** no credential actor exists for an unresolved island. The token provider is inert
     (presents nothing, fires nothing) until resolution, which happens once, in one serialised
     operation, after the vault becomes readable: confirm the guess, or adopt the label. Native
     wake capture stays independent. The answer path needs credentials only after Face ID
     (design 23), which is exactly when resolution can run. This replaces v2's adoption fences and
     guess write rule.
3. **Lifecycle authority stops at the vault.** Raised by Carnot. All of these happen outside it:
   - a sign-in's commit isn't leased from the attempt's start, so a login that succeeds after a
     sign-out or a switch restores the session;
   - `authEventsProvider` carries `void`, so a stale event can tear down its successor;
   - the WSS "unauthenticated" signal is a second logout source;
   - `switchIsland` isn't one operation, so a switch can read A, a sign-in can install B, and
     the switch then clears B.

   These are pre-existing in kind: they exist on `main` today, without #436. **DISPOSITION:
   Nick's call (see below).**
4. **A malformed record is a permanent trap.** Raised by Tesla. Locked is transient. Malformed
   data, or a record version this parser doesn't know, is durable, and v2 handles them the same
   way, so a reinstall keeps the trap. **FOLD:** split the branch. Transient refusal: wait, save
   nothing, write nothing. Durable garbage: a state a sign-in may replace. Telemetry on both.
5. **Old-build evidence after this build has run.** Raised by Noether. A cached user that
   outlived its tokens across a crash reads as an older build. **FOLD:** any `aiko_session` item
   (record, tombstone or owner-unknown) proves this build ran, and the settle then ignores the
   old-build evidence.
6. **The header contradicts §5 again.** Raised by Noether and Tesla. v2's header still says
   "cleared"; §5 says quarantined. **FOLD:** fix the header. This is the second time a design-26
   headline has lagged its body.
7. **The island's identity is its URL.** Raised by Noether, who argues it undermines the core
   invariant. **DISPOSITION unchanged:** named residual, plus the cross-repo follow-up (an `iss`
   claim carrying a stable island id).

Maxwell's build notes also fold into v3:
- only a new session or a sign-out advances the generation;
- adoption has one trigger;
- a sign-out whose tombstone write fails falls back to deleting;
- while a session exists, the saved island is a cache of its label.

## Process

The class repeats for the third time: who may end or replace a session. Each pass widens the
authority (the vault, then the provider, then the auth attempt, the events and the switch). The
#439-specific harm and the session-lifecycle defects separate cleanly:
- **#439 needs** flaws 1, 2, 4, 5 and 6: the labelled record, the tombstone, the durable
  owner-unknown state, an inert credential actor until the island is resolved, and split error
  classes.
- **`main` already has** flaw 3's races. They are worth one session authority of their own, and
  that's a design in its own right.

Round 3 is the last allowed. Whether flaw 3 rides in v3 or becomes its own design is Nick's
call.

**Struck:** dt-1793275571. Landed in arrival order: Maxwell, then Noether, Carnot and Tesla together. **Bundle:** v2 + this file (round 1) + the #439 ledger + the same three source files (76KB).

---

## MaxwellMergeSlam's Design Strike

**Verdict:** SOUND

**Summary:** v2 folds every round-1 fatal flaw at its producer, not with a better guard:
- one vault serialises authority;
- a tombstone retires the old format durably;
- quarantine replaces an irreversible delete;
- the guess loses the ability to write.

What's left are three places the design is silent, which the build must pin down, not fatal flaws.

**Producer first:** The bad outcome is a session presented to, cleared by, or overwritten from an island that didn't issue it, or a signed-out session brought back. Each producer from round 1 is removed, not guarded:
- **Concurrent writers** → the vault serialises every publishing read and every write, and every operation is generation-scoped. That removes resurrection, stale cache fills, stale clears and a shared `_inFlight` together, rather than one check each.
- **Legacy fallback after sign-out** → a tombstone makes "legacy pair read after a sign-out" unrepresentable.
- **Irreversible delete** → quarantine, which costs nothing because a quarantined token is never refreshed and keeps its own `exp`.
- **The guess as a writer** → the write rule plus adoption; the guess picks a screen and can't replace a session.

The door's island comparison remains, with v1's stated reason, which v2 keeps and sharpens: the synchronous config can't read the async Keychain on a locked launch, and gating the root on the Keychain is rejected with a reason (2d) the temper can challenge.

**Fatal flaws:**
- none

**What holds:**
- **2a, tombstone.** "The legacy pair is read only when no `aiko_session` item exists at all" makes the crash-order question in sign-out moot. Every intermediate state is either a tombstone (never legacy again) or a live session (signed-in, the allowed failure). John McClane: "Now I have a machine gun. Ho-ho-ho." One item, and the old format is dead for good.
- **2b, placement.** Runs once, inside the vault, recorded; never reads the island on screen. Dev builds don't trust the current define. It names the inference it still makes, as a tradeoff with its owner and the evidence (`f65906b` ancestor of every tag).
- **2b, quarantine.** The expiry argument is right, including the correction about #427: rotation needs a refresh, a quarantined session never gets one, so its `exp` stands.
- **2c.** The generation covers the shared `_inFlight` and `onUnauthenticated`, not only the store. That closes Noether's round-1 finding, which the round-2 cage-match ledger had also carried (#439 round 2, finding 3).
- **2d.** "Unresolved: don't save" as the default for anything that never ran boot is the right direction for #439 round 2's finding 4. A missing boot can now only fail to save, never save a guess.
- **2d, the rejected alternative.** Its reason is concrete and checkable (`main.dart:95` → `transportWakeProvider` → `configProvider`; the answer path's native listener from the first frame).

**If RECAST, what to fold back:** (build notes; none of these is a fatal flaw)
- **2c, which operations advance the generation.** Only a NEW session (`setTokens`) and a sign-out (tombstone) do. 2b's placement and a refresh commit are the same session and must NOT advance it, or they cancel that session's own in-flight work: a placement during a token read would spuriously drop the read it was serving.
- **2d, who triggers adoption.** The vault publishes the island of the last session it read, a `sessionIsland` signal. `IslandConfigController` adopts it only while its state is marked a guess. A non-guess island is never changed by a read; only `switchIsland` changes it. Say this, so the build doesn't invent a second path.
- **2a/2c, a sign-out whose tombstone write fails.** Fall back to deleting `aiko_session`, then the legacy items, in that order. "A sign-out must never leave a credential behind" (`_clearCredentialAndUnpair`) has to survive the tombstone's own failure.
- **Framing, for the next reader.** While a session exists, the saved island is a synchronous CACHE of its label. When signed out, it's the person's choice. Adoption is cache invalidation, and a reinstall is a cold cache. Naming it so stops a future change treating the two as peers.


---

## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The conserved quantity is *“a stored session’s owner is a property of the session itself”*; v2 conserves it for every session this build writes, but the legacy population’s quarantine is not representable in the one-item format, and adoption is an unaccounted write on the read path, so the invariant still leaks through the cracks.

**Producer first:**  
The harm is a live session on island X being presented to island Y, answered with 401, and deleted. The producer is a stored session with **no recorded owner**, forcing an inference; the inference then presents the credential to whatever island the app happens to be on.  
- For sessions **this build writes**, the design **deletes the producer** by putting the island in the same Keychain item as the tokens (`2a`). That is the right move, not a guard.  
- For **legacy sessions**, the unlabelled pair is external residue already on disk; it cannot be deleted. The design’s quarantine (`2b`) is the correct structural answer: never present it, never clear it on 401, replace only by sign-in. That makes the residue unable to produce the harm — **provided quarantine is durable**.  
- But `2a` defines `aiko_session` as holding only a **record** or a **tombstone**. Quarantine is neither. If it is not written as a durable marker, the legacy pair will be read again on the next launch, re-running placement and potentially placing it differently as prefs change. The producer leaks back.  
- Adoption (`2d`) is a second write on a read path: “the shown island becomes L and is saved.” `2c` says “the one write on a read path is 2b’s placement.” If adoption is not serialised inside the vault and fenced by generation, a sign-out or switch can race it, saving an island for a session that no longer exists.  
- The cached-user evidence (`2b` step 3) rests on “the cached user lives and dies with the tokens,” but that is asserted, not structurally enforced. A crash between clearing tokens and clearing the cached user leaves stale evidence; `ranAnOlderBuild` then misclassifies and the settle saves the wrong island.

**Fatal flaws:**
- **Quarantine is not representable in the one-item format (`2a` vs `2b`).** Class: unrepresentable state / incomplete invariant. The design says an unplaceable pair is quarantined, but the storage format has no quarantine variant. Without a durable marker, “runs once per install” is false; the pair can be re-read and re-placed.
- **Adoption is an unaccounted write on a read path (`2c` vs `2d`).** Class: missing write authority / un-fenced side effect. `2c` claims the only read-path write is placement; `2d` adds adoption. If adoption is not serialised inside the vault and generation-fenced, it can save an island for a session that a concurrent sign-out has already cleared.
- **The cached-user invariant is asserted, not enforced (`2b` step 3).** Class: broken invariant / unstated crash window. If the cached user outlives the tokens across a crash, the settle can misclassify a signed-out current build as an older build and save the legacy default.
- **The island’s identity is its URL (`5`).** Class: named residual that undermines the core invariant. A host move breaks every labelled session unless both the saved island and the session label are migrated in the same release. This is a manual process, not a design guarantee; the durable fix is a stable island id in the JWT (`iss`) or in the session record.
- **The top-level product decision says an unplaceable reinstall session is “cleared (section 5)”, but section 5 says it is quarantined.** Class: contradictory design statement. One of the two must go; the design cannot both delete and quarantine.

**What holds:**
- One Keychain item for the session, with island and tokens inseparable (`2a`). This deletes the producer for every session this build writes.
- The door decides per read and never writes (`2c`). A foreign session is left alone; a 401 clears only the session it was issued for.
- Explicit sign-out writes the tombstone whoever issued the session (`2c`).
- Generation fencing covers cache fills, refresh commits, rejection clears, shared `_inFlight`, and `onUnauthenticated` (`2c`).
- Quarantine is the right direction for unplaceable legacy pairs — it just needs a durable representation.
- The “no guess at all” alternative was correctly rejected for risking design 23’s call-answer path (`2d`).

**If RECAST, what to fold back:**
- In `2a`, add a third variant to `aiko_session`: `{"v":1,"quarantined":true}` (or explicitly state that quarantine writes a tombstone). Placement must write this marker once, so the legacy pair is never read again.
- In `2c`, state that **adoption is a vault operation**, serialised with sign-in and sign-out, and generation-fenced. Remove the claim that placement is the only write on a read path.
- In `2b`/`4`, either clear the cached user inside the vault atomically with the session, or stop using `ranAnOlderBuild` when a tombstone or quarantine marker is present. The evidence must be as durable as the session it places.
- In `5`, if ADR-0008 provides a stable island id, put it in the session record and stop keying identity on the URL. Otherwise, name the host-move owner and add a migration test that proves the saved island and the session label move together.
- Resolve the top-level “cleared” vs section 5 “quarantined” contradiction: pick one and make it consistent everywhere.

---

## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** The single record and tombstone remove real entropy. The remaining losses come from lifecycle authority stopping at the vault while login, routing and island changes continue outside it. Dijkstra: "Simplicity is prerequisite for reliability." No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are.

**Producer first:** The harms are credential disclosure to another island, loss of a surviving session, and restoration after sign-out. Reinstall, unlock and delayed replies are triggers. The producers are constructing island-specific machinery before ownership is resolved, allowing delayed authentication work to obtain fresh mutation authority, and delivering session changes through unscoped application events. The first producer can be removed by separating native wake capture from authenticated backend activation. Delayed replies cannot be prevented, but their authority can expire structurally with the session or authentication attempt that created them. Legacy placement remains an inference; retaining it requires historical provenance because the tokens themselves cannot establish ownership.

**Fatal flaws:**
- Make wrong-island work during unresolved boot impossible: keep native wake capture running independently, and activate island-specific authentication and transport only after readable session resolution. Then guessed-backend adoption and guess-specific replacement rules become unnecessary. Section 2d rejects gating the whole app, but that is the wrong option frame: preserving the first-frame native listener does not establish that an authenticated backend must exist then. Nineteen readers measure coupling, not a requirement to retain it.
- The generation starts too late for sign-in. A login request starts on island L; the person signs out; its successful response later calls setTokens. If setTokens captures the generation when that operation begins, it receives current authority and restores the session. The same failure crosses an island switch. Section 2c covers refresh because its network work belongs to the provider operation, but never binds the originating login/register/passkey attempt to its eventual commit. Serial storage operations cannot distinguish an obsolete successful login from a newly intended one.
- Suppressing stale onUnauthenticated calls does not suppress stale event delivery. A rejection can validly enqueue an event, a new session can commit, and the broadcast listener can process the old event afterward. The supplied authEventsProvider carries void, so the consumer cannot identify which session ended. WSS unauthenticated events are another declared logout source outside the proposed vault coverage. Either can tear down the replacement session despite a correct vault.
- The island transition is still specified as separate actions: read label, decide, clear or retarget, then save and rebuild. Serializing individual vault operations does not serialize that ceremony. A switch can read session A, a concurrent login can install B, and the switch can then unconditionally clear B. Likewise, delayed adoption or preference persistence can publish an obsolete island after a later transition. The design must make the entire transition's authority explicit, including application state and persistence.

**What holds:**
- One atomic Keychain record structurally prevents torn ownership and token combinations.
- A tombstone durably disables legacy fallback after a completed sign-out write.
- Unreadable storage preserves credentials and preferences; telemetry distinguishes operational failure from expected locking.
- Quarantine avoids both speculative credential presentation and unnecessary deletion.
- The historic store-build placement tradeoff and URL identity residual are now explicit; neither needs to be rediscovered as an unnamed flaw.

**If RECAST, what to fold back:**
- Replace the whole-app-gate comparison with a concrete dependency design: native event capture remains active, session resolution remains explicit, and authenticated backend activation waits. Demonstrate the locked incoming-call sequence.
- Give each authentication attempt authority before its first network await. Sign-out, replacement, switch and disposal revoke that authority; a late response cannot acquire it again through setTokens.
- Move terminal session transitions into the shared authority. Publish session-identified observations afterward, so REST and WSS notifications cannot independently sign out a successor.
- Define one ordered island-transition operation covering the observed session, discard or adoption decision, configuration publication and preference persistence. Avoid holding its serialization lock across network work.
- Add adversarial outcomes for login success after logout or switch, queued REST/WSS rejection after replacement, and switch/adoption racing a new session. Specify sign-out crash guarantees from its durable commit point; a crash before that point can legitimately retain the prior session.


---

## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** The one-item session is true ore, and it still shatters on the boot after a legacy reinstall, because the settle writes an owner for the session quarantine just declared had none.

Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration."

**Producer first:** The harm is a live refresh token presented to an island that did not mint it. That island answers 401, the app deletes the credential, and the person loses the session a reinstall was supposed to keep. The same family has a second harm: a labelled session tombstoned by a logout the person never asked for. The trigger (locked phone, process death, 401) is outside. The producers are ours.

- **Door match (§2c).** Guards showing island X's token to island Y. The producer is a presenter built for an island the session item did not name. It can be removed. Build the presenter only after the vault has named an island, and only for that island. Design 23 already connects the call after Face ID, and Face ID is the same edge that makes the vault readable. The door check then becomes unnecessary. v2 still builds the presenter for the guess and checks at the door.
- **Write rule (§2d).** Guards a sign-in or switch on the guess replacing a labelled session. The producer is that same guess, still holding a writer. Remove the writer while resolution is unresolved or a guess, and the rule is idle.
- **Generation (§2c).** Guards a refresh, a cache fill, or `onUnauthenticated` that outlives its session. The reply already in flight cannot be unsent, so a vault that drops the commit when the generation has moved is structural and stays. Generation advances on replacement or clear only. Adoption is neither, so a guess-provider logout in the current generation keeps its authority. The fence does not cover the transition §2d adds.
- **Quarantine (§2b).** The unowned legacy pair was written by an older build. That residue is external and cannot be deleted. The producer of the harm is this build reading the pair again and assigning an owner. That producer can be removed: the first unplaceable result writes a durable owner-unknown marker into `aiko_session` in the same vault turn, and the legacy pair is never read again. "Never present" then becomes a property of the item. v2 leaves the legacy keys as a live input whenever `aiko_session` is absent.
- **Placement steps 2–3 (§2b, §5).** For an island an older switch saved before this build, the inference is the accepted tradeoff. For an island this build's settle saves after declaring the pair unplaceable, the producer is ours. The settle is minting the evidence placement consumes. Stop it from doing that.
- **Don't-save on unreadable (§2d).** The locked branch is removed as a producer: a refused read saves nothing. The quarantined branch is still a producer. §2d files owner-unknown under "positively no session" and the settle then saves an owner.

**Fatal flaws:**
- Make presentation of a quarantined legacy token to the fresh default impossible: the first unplaceable result writes a durable owner-unknown marker into `aiko_session` before boot returns, and the legacy pair is never read again. The settle's saved URL is not an input to placement. The door match, the per-read "never present," and step 2's trust in a pref this boot just wrote then become unnecessary. As written, the glass rings on the later boot. §2b reads the legacy pair whenever `aiko_session` is absent, and it records an answer only for a placed pair (rewritten as a record). An unplaceable pair stays in the old keys. §2d treats quarantined as positively no session, and the settle saves. A reinstall has emptied prefs, so `ranAnOlderBuild` is false and the saved island becomes the fresh default, Enspyr (§2d). Any once-per-install memo dies with the process. The next launch finds no `aiko_session`, finds a saved island, and §2b step 2 places the pair there. Step 2's premise — an older build used that saved island, and a switch cleared the tokens — is false of an island the settle wrote because placement failed. There is no mark on the pref that can tell the two apart once the process is gone. The legacy population's home is `kLegacyDefaultIslandBaseUrl`. The wiped-prefs settle writes Enspyr. So the unlabelled session a reinstall leaves in the Keychain, the one the product decision exists to keep, is welded to Enspyr and handed over. The door is satisfied, because the label and the presenter now agree. The 401 clears a credential that was valid on the island that minted it, and the bearer has already crossed the trust boundary named in the header. This is round 1 of [PR #439](https://github.com/nickmeinhold/aiko_chat_app/pull/439) one octave up: the refusal to guess manufactures the evidence the guess needed. The header already hears two futures at once — "nothing can place it, so it's cleared (section 5)" — while §2b says quarantined and left in place. §6's reinstall test stops on the first launch. The burn is the launch after the settle has saved.
- Make a guess-driven tombstone impossible: while `islandResolutionProvider` is unresolved or a guess, the graph builds no `TokenProvider`, arms no `onUnauthenticated`, and accepts no sign-in, switch, or sign-out against the vault. §2d's write rule and the adoption-versus-generation fence then become unnecessary. §2d adopts L when a later read sees a labelled session and the shown island is a different guess. §2c advances generation on replacement or clear, and adoption does neither. The provider that asked was built for the guess and is still inside the current generation when the read returns. The code this design recasts treats "nothing of ours" as `_markUnauthenticated` (`token_provider.dart`). The bundle's auth path reconciles that event into one logout (`providers.dart`, `authEventsProvider`), and §2c's explicit sign-out writes a tombstone whoever issued the session. A foreign label is left alone on the vault read and can still be buried by the logout that follows it. The call-answer path does not need this presenter early: design 23 connects after Face ID, the same moment the vault becomes readable. §2d's rejected alternative, holding the whole app, answered a larger question and left the writer in the room. Withhold the credential actor. Let the screen be a guess. The session stays asleep until its own label speaks.
- A malformed `aiko_session` is a durable resident of a store that survives reinstall, and §2d / §2e tune it to the same pitch as a locked phone. `errSecInteractionNotAllowed` is transient: the phone will open. Malformed is permanent. The item exists, so §2a will not fall through to the legacy pair. The write rule replaces a record only for absent, tombstone, quarantine, or the same island. `switchIsland` waits while the vault is unreadable. Sign-in cannot overwrite bytes the rule refuses to classify. Reinstall keeps the Keychain, so it keeps the trap, and every later boot is a guess that saves nothing and adopts nothing. A later record whose `v` this parser calls malformed falls down the same well. Split the branch. Transient refusal: save nothing, write nothing, wait. Durable garbage: a state sign-in is allowed to replace. Telemetry on both.

**What holds:**
- One Keychain item at design 23's accessibility (§2a). A crash can no longer fasten one island's label to another's tokens. Round 2's torn triple dies here.
- The tombstone written before the legacy delete (§2a). A crash inside sign-out leaves a marker that keeps the old pair unread. That retirement is real for sign-out. Quarantine never enters it.
- A labelled session presented only by a provider built for its own label, left in place, surviving that provider's 401 (§2c). The read path learned.
- A dev-build legacy pair stays unplaceable unless `aiko_tokens_island` is present (§2b). The current define is no longer historical evidence.
- The don't-save default when boot never ran, and the locked launch saving nothing (§2d). It holds for a labelled session. Filed under the same "no session" head, it is also what poisons the unlabelled one.
- The URL-identity residual (§5) is honestly owned. It stays named.
- The update-path inference for a saved island an older switch wrote (§5) holds on the two invariants it names. It holds for that island alone.

**If RECAST, what to fold back:**
- In §2b and §2d, an unplaceable result writes a durable owner-unknown marker into `aiko_session` before boot returns. Legacy keys become unread once that marker is durable. Crash residue: marker present, legacy still there, legacy unread. The settle may save an island only after a marker, a true absence, or a tombstone. Placement step 2 ignores any saved island written after an unplaceable result in this install. Add the §6 case: reinstall, legacy pair, process death after the settle saves, next launch presents nothing, and a 401 clears nothing.
- In §2c and §2d, unresolved and guess build no token provider and emit no auth-logout. Adoption rebuilds the presenter for L after the read, with the guess provider already unable to call `onUnauthenticated` or `clearTokens`. Answer the open question in the smaller gate: the shell may show a guess; the credential actor waits for the vault. Design 23's call still connects on the Face ID edge.
- In §2e, locked and entitlement-unwritable stay "save nothing, write nothing." Malformed and unknown `v` are replaceable by sign-in. Put that state on the write rule's positive list.

