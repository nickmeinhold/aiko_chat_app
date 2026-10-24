# ADR-0009: A signing key belongs to one island account; continuity across islands is a link

| | |
|---|---|
| **ADR** | 0009 |
| **Status** | **Accepted** (Nick, 2026-10-24). **Amends ADR-0004**'s "the same key signs your messages on any island" line; its other decisions stand. |
| **Owner** | Nick Meinhold, with Claude |
| **Created** | 2026-10-24 |
| **Thread** | PR #208 ("the question this PR silently decides — please attack it"); `docs/crucible/federated-identity-anchor/TEMPER.md` scope fork C5 ("Nick's"); claude-tasks#3166 / public #265 (key→account binding); #236 (key continuity) |
| **Reference** | [ADR-0004](0004-sovereign-identity-federation.md) (identity anchor, `IdentityDoc` seam); `docs/crucible/pop-identity-binding/CRUCIBLE.md` hazard 3; `docs/crucible/passkey-rooted-identity/` (on PR #208's branch) |

## Summary

**One signing key per island account.** `nick` on enspyr and `nick` on imagineering are two accounts, so they sign with two keys and read as two authors, unless the person chooses to link them. **Continuity across islands is an explicit, consented, signed link between keys**, recorded in ADR-0004's `IdentityDoc` (`verificationMethod[]` is already a *set*). It is not one key shared everywhere.

This picks C5's second branch, *"identifier hygiene now, honest multi-home linking, PLC-directory only when a 3rd untrusted island appears"*, and it makes PR #208's per-account scoping a decision rather than a side effect.

## Motivation

ADR-0004 said: *"On any island you are the same person because the same key signs your messages."* The code delivered that by accident, through one device seed shared by every account and every island. What it actually produced:

- **Identity leaked without anyone choosing it (#4831).** Two accounts on one handset signed with the same pubkey, which rides in `origin.sender_pubkey` to every recipient. Measured 2026-09-26: one key held by `nick` on enspyr, `nick` on imagineering, and the since-deleted `nicki`. A per-island `GROUP BY pubkey` check is structurally blind to it.
- **A static key is a global, unrotatable correlation handle** (PoP crucible, hazard 3). Every island you post on can join your activity to every other island's by a byte string you can never change.
- **The adversary named it.** Tesla (PR #208's design temper): per-island unlinkability is *correct* design, and gluing keys back together without consent is "correlation with a hymn under it."
- **It's cheap to decide now.** Both islands together hold 217 signed messages, and the corpus can be inspected by hand. Every month of a shared key adds history signed under the wrong shape.

## Proposal

**Guide-level.** When you join an island you get a signing key for that account, and it is yours alone. People on that island see you as that key. If you want people to know that `nick:enspyr` and `nick:imagineering` are the same person, you link them: each key signs a statement naming the other, and anyone who sees both signatures knows the link is real. You can link some islands and not others. Until you link, no one (not even the islands, comparing notes) can join your accounts by key.

**Reference-level.**

1. **Scope.** The sovereign seed is scoped per `(island, user_id)`. Island `user_id`s are ULIDs and never collide across islands, so PR #208's per-`user_id` scoping already gives this. The storage key should say so in its name when next touched, so the scope is visible rather than incidental.
2. **The link (future increment, shape fixed now).** A *mutual* attestation: key A signs "A ↔ B", **and** key B signs the same statement. A one-sided claim proves nothing (anyone can claim to be Nick). The pair is carried in each account's `IdentityDoc` as additional `verificationMethod` entries plus the countersigned statement. Revocation is a signed "unlink" by either key. Building this is **not** part of this ADR; it fixes only that continuity arrives this way and no other.
3. **Key continuity (#236) gets simpler.** The app pins the first key it sees for each `(island, account)`. Moving islands no longer looks like a key change, because it's a different account. The open hard case stays **multi-device within one account** (several phones, one account), which this ADR does not decide.
4. **Unchanged from ADR-0004:** opaque identifiers; origin as a locator only; no central directory; home-scoped handles; the browse-by-island roster.

## Rationale and alternatives

- **One key per human, shared across islands (the shape before #208).** Rejected. It delivers portability by making every island a correlator, and it can't be withdrawn. "Same person everywhere" should be something you *assert*, not something leaked from a byte string.
- **One key per device (also the shape before #208, seen from the other side).** Rejected. It welds identity to hardware: two accounts on one phone become one author, and one account on two phones becomes two.
- **Passkey-derived keys (the passkey-rooted-identity crucible, unfinished).** Compatible, not competing. A WebAuthn PRF output salted with the island id would derive *this ADR's per-island keys* deterministically from one passkey: per-island unlinkability on the wire, recoverable from the passkey, with linking still an explicit act. If that crucible lands, it changes how the key is *made*, not which key signs.
- **Ed25519 key blinding (Tor-style, from the same crucible).** A later refinement of the link: continuity provable only to the recipients you choose. Needs libsodium FFI. Unbuilt.

## Consequences

- **PR #208's identity question is answered.** It stops being blocked on the ADR fork. Its code still needs its own review and a rebase onto `main`.
- **#3166 / #265 (key→account binding):** unchanged in kind, smaller in scope. The binding to establish is "this key ↔ this island's account". A hostile island can still lie about it, and key continuity (#236) remains the defence.
- **Authorship history (the Carried Record) is per island account** until linked. A link retroactively joins the histories it names, which is the point of consenting to it.
- **Island side:** `SigningKey` is already an *observed* binding, unique per `(user_id, pubkey)`. The island is a carrier: it records "account A presented key k" and never verifies a signature (`domain/models.py`, `SigningKey`). That fits this ADR unchanged, and needs no wire change. Its docstring names the trigger for global key uniqueness (proof-of-possession at registration), which this ADR leaves to the island. The future link needs a place in the island's IdentityDoc/`/v1/keys` surface; that's the island tab's to shape.

## Unresolved questions

1. **Multi-device within one account.** N devices: one key synced (as passkeys are), or N keys cross-signed (Matrix, Keybase)? Deferred; it's what #236 is really blocked on.
2. **Where links live and who serves them.** In each home's IdentityDoc, the islands' `/v1/keys`, or carried by the client? Island tab's view needed.
3. **Linking UX.** How a person proves control of both keys at once: both accounts signed in on one device is the obvious path, and possibly the only one at first.

## Rejected ideas

- **Leaving it implicit in #208.** The fork that ADR-0004 rejected (home-anchoring as an *unnamed default*) would have arrived through a bug fix, which is how #4831 and #4775 both arrived. This ADR exists so that it doesn't.
