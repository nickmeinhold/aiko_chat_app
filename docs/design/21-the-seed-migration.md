# 21 — The seed migration: one migrator, not every load

> ## ⛔ DISSOLVED 2026-09-26 — and the thing that dissolved it was a number
>
> **This whole design is unnecessary.** It exists to migrate the pre-#4831 unscoped
> seed while preserving authorship continuity. Nobody priced what was being
> preserved. The live island does:
>
> ```
> users            42
> signing_keys     19      <- 23 users have never signed anything
> distinct pubkey  18
> messages         46
> signed msgs      44      <- the entire authorship corpus
> SHARED PUBKEY (>1 user)  exactly ONE — held by `nicki` and `nick`
> ```
>
> Forty-four signed messages. One shared pubkey, and **both of its accounts belong
> to the same person.** The ambiguous case that the quarantine state machine, the
> tombstone-as-lock, the island veto and the offline-first-launch policy all exist
> to adjudicate is *"which of Nick's two accounts owns this key?"* — answerable by
> asking him.
>
> **So the seed is discarded, not adopted.** Nineteen pubkeys stop matching new
> signatures, and in exchange **all twenty-three findings** from two cage-match
> rounds and this four-family temper become *unreachable rather than fixed* — every
> one of them lived in the adoption path. `SovereignKeyStore` went 374 → 228 lines;
> the tests went 24 → 15; `_adoptLegacySeed`, `_legacyAlreadyClaimed`,
> `_serialised`, the `Expando` gate, `_gateTimeout` and `_sweepLegacySeed` are all
> gone. What survives is: scope per account, delete the old slot, mint if absent.
>
> **Why it was missed, which is the transferable part.** The constraint
> *"adopt-then-scope is the only order that works"* was inherited from the island
> tab and treated as a law. Its premise is true — `signing_keys` rows and persisted
> `origin.sender_pubkey` ARE immutable. The inference is not: **immutability makes
> history unfixable, it does not make history valuable.** And the user count was
> never in the bundle, so four adversary families struck twenty-three times inside
> an unpriced frame and none could reach the dissolve — **an adversary can only
> strike what you show it.** The question that found it was four words from Nick:
> *"are you sure you're not overcomplicating this?"*
>
> Kept, not deleted: the strike below is a real record, and flaw 1 (adopting a
> shared key forges an author) remains true and is why *retire-and-mint* is now the
> universal rule rather than the multi-account exception.


**Status:** DESIGN, awaiting temper. Supersedes the migration in PR #208 (not the
scoping — see "What is banked").
**Ticket:** [#4831](https://github.com/nickmeinhold/claude-tasks/issues/4831).
Related: #4775.

## The defect that started it

The sovereign Ed25519 seed lived under one unscoped key, `aiko_sov_private_seed`,
and `clear()` had no caller — so the seed outlived a sign-out. Sign out, sign in
as someone else on the same handset, and **both accounts signed with the same
pubkey**. `origin.sender_pubkey` rides in every message to every recipient, so
that is a *public* cross-account link: no database access needed, and reachable
through an ordinary supported sign-out.

Scoping the seed per `user_id` fixes it and gives device attribution for free —
one account on two handsets still mints two keys. **Stable within an account,
meaningless across it.** Nobody has disputed that in two cage-match rounds.

## What is banked

Keep, unchanged, from PR #208:

- **Per-`user_id` seed scoping, bound at `sovereignKeyStoreProvider`** rather than
  threaded through call sites, so a call site cannot ask for another account's key.
- **An empty id is the same state as a null one** — both get an ephemeral key that
  is never written. `_seedKeyFor('')` was otherwise one slot shared by every
  empty-id session: the same defect under a new name.
- **`SovereignKey.userId`**, as a *witness* rather than a guard (see below).
- The test suite's shape: every assertion has a control that runs the other way.

## What is being recast, and why it is a design problem

Two review rounds produced twelve real findings. Round 1's eight were fixed;
**round 2's four were all defects in those fixes.** Three costumes, one shape:

| Round | Finding | Guard added |
|---|---|---|
| 1 | Adoption *copies* the seed, so deleting the legacy **name** cannot un-write a scoped **copy**. Bob-first after a failed delete inherits Alice's identity. | `_legacyAlreadyClaimed` — a `readAll` scan |
| 1 | Two store instances both adopt before either deletes. | `_serialised` — a process-wide `static` chain |
| 2 | That chain wedged production and 4 tests: a holder that never *completes* blocks every account forever. | `Expando` on the storage + a 5s bounded wait |
| 2 | `Future.timeout` does not **cancel**. The stalled predecessor resumes and still writes, after the successor has claimed and deleted. Two scoped copies — #4831 in its terminal form. | *(none — this is where it stopped)* |

Plus `_sweepLegacySeed`, which was the first guard of all.

**Four guards on one invariant** (Tesla). That is the tell, and the round-cap
rule says the fifth guard is not the answer.

### The coupling

> Every account load — and every *discarded* store whose future is still running —
> is a writer of one shared legacy slot.

Every guard above exists only to survive that. The exclusivity scan, the mutex,
the timeout, and the sweep are four different ways of asking "is somebody else
writing this right now?", which is a question that should not be askable.

## The recast: one migrator

**The legacy slot has exactly one writer, and it is not an account load.**

1. **A migrator runs once per process, before any account load can begin.** It
   owns `aiko_sov_private_seed` and is the only code that may read, copy or delete
   it. Account loads touch `aiko_sov_private_seed_<uid>` and nothing else.
2. **The migrator's job is to empty the legacy slot**, exactly once, to exactly
   one destination, and then it is done for the lifetime of the install.
3. **Account loads become the simple thing they should have been**: read my slot,
   mint if absent, never look at anyone else's. No scan, no mutex, no timeout, no
   sweep — none of them have anything left to protect.

With one writer, all four guards are deleted rather than fixed, and the
uncancelled-corpse finding cannot be expressed: there is no second writer for a
late callback to race.

### The question the migrator must answer, and cannot answer locally

**Whose identity is the legacy seed?** On a single-account handset — the
overwhelming majority — it is the only account's, and adoption is exact. On a
handset that has held two, **nothing on the device records which one owned it**,
and first-to-ask does not merely orphan the loser's history: it hands the loser's
private key to the winner. That is impersonation, not a lost link (Tesla).

The island can answer it exactly. `GET /v1/keys` lists a user's registered
pubkeys with `first_seen_at`/`last_seen_at`, so *"is this legacy pubkey already
mine?"* is a straight question — at the cost of a network round trip before the
first signature.

Three candidate answers, for the temper to choose between:

- **(A) Ask the island.** Exact. Costs a round trip on the signing path's first
  load, and needs an answer for *offline* first-launch-after-upgrade.
- **(B) Adopt only when the handset has exactly one known account**, else leave the
  legacy seed untouched and mint. Never wrong, sometimes declines a legitimate
  adoption — and "known accounts on this handset" may not be locally answerable
  either, which would make this A in disguise.
- **(C) First-to-ask, as shipped.** Cheapest, and accepts assigning an author
  rather than discovering one. Currently undocumented as a *security* tradeoff
  rather than a continuity one, which is the thing that changed.

### Why the ownership witness stays, but not as a guard

`SovereignKey.userId` was added in round 2 with a consumer-side assert, and **the
assert is inert**: both operands derive from `authControllerProvider` in the same
provider build, so they agree by construction and the throw is unreachable. Two
of three reviewers filed it under "The Good" anyway; one read the data flow.

The stamp is still worth having as a *witness* — it makes a foreign key
identifiable at a boundary that can actually see two builds. It is not a guard,
and the pre-existing `disposed` check before `repo.start()` is what really keeps a
stale key off a started repo. Nobody should delete that believing the stamp
replaced it.

## Constraints any recast must satisfy

- **Adopt-then-scope is the only order that works.** The island's `signing_keys`
  rows and every persisted `origin.sender_pubkey` are **immutable**, so minting
  fresh does not merely lose the link going forward — it strands every past
  message under a key the account no longer claims (island tab, 2026-09-25).
- **Validate before committing.** Nothing is written or deleted until the bytes
  decode and are 32 bytes long. Round 1 deleted the only other copy first and
  bricked the identity on every cold start.
- **Never burn the repair copy.** The hit path currently sweeps the legacy seed
  *before* decoding the scoped one, so a torn scoped slot destroys its own fallback
  and then throws — with `clear()` uncalled, that account never signs again.
- **A dead holder must not wedge signing.** Whatever replaces the gate must not be
  blockable by a section that never completes, and "never completes" is a distinct
  failure from "throws".
- **No recovery path exists today.** `clear()` has no production caller, so every
  throw above is terminal. Whether sign-out *should* call it is a separate
  question; that there is no path at all is not.

## Open, and deliberately not decided here

- **Desktop.** Per-account scoping plus `FlutterSecureStorage` over
  libsecret/DPAPI. Tesla's read is that the blast radius was already every account
  in one login collection, so scoping changes who is correlatable on the wire, not
  what a compromise costs. Worth settling with the desktop storage posture.
- **Rotation after compromise**, which is the real question `clear()` gestures at —
  not correlation, which scoping already takes.
- **`userId` as a raw `String`** in storage-key construction (Carnot). A branded
  type would make the empty case and odd platform key names unreachable rather
  than guarded.

## Instrument note

Kelvin returned `APPROVE` with zero findings on the round that contained all four
of the above, and praised the inert assert. Carnot praised it too. This repo has
`reference_kelvin_approves_the_defect` at n=9 for that shape; this is n=10, with a
second family joining. **Three families agreeing is not three families checking** —
and the finding that mattered most in each round came from a single seat.
