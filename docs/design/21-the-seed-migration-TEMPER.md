# TEMPER.md — the seed migration (design 21)

**Overall verdict:** **RECAST** — 3/3 adversary families, no DISSOLVE. The
single-migrator frame survives; the *attribution* half of the design does not.
**Struck:** dt-1790391476, families seated: Maxwell + Kelvin + Carnot + Tesla (4/4; Wu disabled)

## Per-family verdicts

| Family | Verdict | One-line |
|---|---|---|
| Maxwell (Claude) | RECAST | The design's own inherited constraint mandates the worse harm in the only case it was written for. |
| Kelvin (Gemini) | RECAST | Correct recast of the race, but the migrator's own initial state is undefined on an offline first launch. |
| Carnot (GPT) | RECAST | "A migrator that cannot answer ownership is not yet a design; it is a cleaner place to put the hard question." |
| Tesla (Grok) | RECAST | The migrator still chooses an owner before the handset can know one, and deletes the last way back. |

## Fatal flaws (deduped, most-severe first)

1. **"Adopt-then-scope is the only order that works" is FALSE for the case the design
   exists to handle** — raised by Tesla, independently reasoned by Maxwell.
   The constraint was inherited from the island tab and is correct for a handset that
   has held ONE account. For a handset that has held two — the precondition for #4831
   mattering at all — that pubkey is **already in both histories**. Copying it into one
   scoped slot means the winner's *future* messages verify as a pubkey in the loser's
   *past*. That is forgery, on the wire, with no database access: the original defect
   one octave higher. Minting fresh strands a link; adopting a shared key forges an
   author. **The constraint ranked the lesser harm impossible and the greater harm
   mandatory.**
   DISPOSITION: fold — split the law. Adopt-then-scope is mandatory only for a key a
   single account has ever used; for a key more than one account has signed with the
   mandatory order is **retire and mint**.

2. **"Before any account load" is the dead holder, transposed, with the whole install as
   blast radius** — Tesla.
   A migrator stuck in secure storage, a locked keychain or a network wait is exactly
   the section-that-never-completes the design's own constraints forbid. Worse:
   validate-before-commit forbids deleting bytes that are not a 32-byte seed, so a
   **corrupt** legacy slot can never be emptied, the gate never opens, and with
   `clear()` uncalled the install never signs again. Round 2's wedge with the timeout
   removed and the wait kept.
   DISPOSITION: fold — an account that already has a scoped slot never waits on the
   migrator; invalid legacy bytes are disposed as garbage, not awaited as a key.

3. **"Once per process" ≠ "lifetime of the install", so the second writer is the next
   process** — Carnot and Tesla independently.
   Copy into the scoped slot, die before the delete, and the restarted process is
   another writer of the same legacy slot — the uncancelled corpse with the stall
   replaced by a kill. A second desktop process does the same, and desktop was parked
   as "not decided here" while the one-writer claim depends on that posture.
   DISPOSITION: fold — one durable storage state machine that a restart and a second
   process both obey; the tombstone is written before the source name is removed, and
   the tombstone is the lock. If two processes can run it and the tombstone is not the
   lock, the one-writer claim is withdrawn.

4. **Option A makes the island a writer of the private key** — Tesla.
   The cost is not a round trip. A `GET /v1/keys` boolean becomes the **commit bit**
   for a seed that has never left the handset. An IDOR, a compromised directory or a
   confused yes does not leak a pubkey list — it writes the legacy seed into the
   caller's scoped slot.
   DISPOSITION: fold — the island may **veto or confirm**; it may never be the thing
   that writes.

5. **The island cannot answer the question either, precisely when the answer would cut** — Tesla.
   Once the bug has fired, both accounts registered the same pubkey, so both queries
   return yes: the island stored the *symptom*. `first_seen_at` is then option C with
   a server clock. When only one account ever registered it, a local count would have
   done the job and the round trip is theatre.
   DISPOSITION: fold — discard the A/B/C frame; see flaw 6.

6. **A/B/C is a false-choice frame** — Kelvin, Carnot, Tesla, all three.
   (C) is a known impersonation vector the design itself post-mortemed. (B) is
   "first-to-ask wearing a lab coat" (Carnot) — "exactly one known account" is not
   "the legacy seed belongs to that account", and at first start the auth list is often
   not hydrated, so the majority single-account handset looks like **zero** accounts,
   mints, and strands itself. (A) has the blast radius above. **The frame has no
   automatic destination of *nowhere*** (Tesla) — which is the option that was missing.
   DISPOSITION: fold — replace with a non-automatic attribution rule over a quarantine.

7. **Offline first-launch-after-upgrade is a product state, not an edge case** — Kelvin, Carnot.
   Named and not designed. Block forever and the wedge is back; mint and the immutable
   pubkey row strands adoption; adopt later over a key already announced and the account
   forks into two live sovereign identities.
   DISPOSITION: fold — offline never mints over an open quarantine. Sign with an
   already-scoped key, or do not sign.

8. **The wrong copy looks healthy, and adopting burns the only repair** — Tesla.
   "Never burn the repair copy" protects a torn *scoped* slot. One octave up, the legacy
   slot is the only repair for a bad **attribution** — and after deletion the wrong
   account holds 32 valid bytes, so validation swears the key is sound on every cold
   start. The witness cannot catch it (the assert is inert), rotation is parked,
   `clear()` has no caller. The 3am symptom is silence.
   DISPOSITION: fold — a bad adoption is irreversible while nothing in production can
   wipe a scoped slot, so the design does not get to spend the legacy bytes on a guess.

9. **Recovery / terminal states are still absent** — Carnot.
   A design that can brick signing must name the unbricking mechanism or prove it cannot
   brick. DISPOSITION: fold as an explicit terminal-state list; `clear()` wiring stays
   a separate question but "no path at all" does not.

10. **The witness's consuming boundary is unnamed** — Carnot.
    Demoting it from guard is right, but an unnamed boundary risks a second ornamental
    assertion. DISPOSITION: fold — name the boundary, and record that the
    `disposed`-before-`start()` check is the real stale-build guard.

11. **`userId` as a raw `String` in storage-key construction** — Carnot, both rounds.
    DISPOSITION: named tradeoff or fold — a branded `UserId` / storage-key constructor
    makes null, empty and platform-hostile names unreachable rather than guarded.

## What holds

- **The coupling diagnosis, unanimously.** Four guards were four ways of asking whether
  someone else is writing the shared slot. Delete the question; do not add a fifth guard.
- **Per-account scoping bound at the provider**, empty-id-as-null, the never-written
  ephemeral key, stable-within / meaningless-across.
- **The witness demotion** — `SovereignKey.userId` as evidence, not a guard, with the
  `disposed` check as the real protection.
- **Validate before adopting; never sweep the fallback before the scoped bytes decode** —
  with Tesla's correction that this must not stretch into "garbage can never be removed".

## Disposition

**RECAST.** Fold flaws 1-10 into design 21 v2 and re-strike (temper round 2 of ≤3).
Flaw 1 carries a product decision that is not the panel's to make: **retire-and-mint
strands authorship history for multi-account handsets.** That contradicts a constraint the
island tab supplied on 2026-09-25 and must be raised with them — the constraint is right
for the single-account case and inverted for the case it was quoted about.

## Instrument note

Kelvin returned RECAST here with two real flaws, having returned a zero-finding APPROVE on
the code round that contained four. Same model, same session, different task shape —
evidence that the config-J/K brief effect is task-specific, and a reminder that one seat's
silence on one task is not a capability reading.
