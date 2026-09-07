# ADR-0008: Island self-description and the operator attestation

| | |
|---|---|
| **ADR** | 0008 |
| **Status** | Draft, requesting comments (island-side half is a named blocking dependency) |
| **Owner** | Nick Meinhold, with Claude |
| **Created** | 2026-09-07 |
| **Thread** | Andy's notes 2026-09-07 ("Server: Name, URL, ☐ Description"), worked through in the app tab |
| **Reference** | [ADR-0004: Sovereign identity federation](0004-sovereign-identity-federation.md) (identity=key, home-scoped handles, no central directory); `lib/features/settings/domain/island_entry.dart`; claude-tasks#3774 (an evidence viewer must verify signatures itself) |
| **Prior art — found AFTER drafting** | **claude-tasks#3973** (`project:aiko-chat-island`, 2026-09-06, open, *"crucible it"*) — attestation as a FOUNDATION under #3796, #1962 and the update audit. **This ADR is a consumer of that layer, not a substitute for it.** See "Prior art" below. |

## Summary

An island's directory entry is **untrusted self-description**, and the client must
treat it in exactly two tiers:

- **COSMETIC** — `label`, `description`, `region`, icon. Renderable as-is. A lie
  here costs a reader nothing they were relying on.
- **ATTESTED** — anything that names a *person* or asserts *accountability*.
  Rendered **only** when it carries a signature the device verifies itself.

The operator field is ATTESTED. Concretely: the **operator's key signs a statement
naming the island**; the island serves that statement; the client verifies it
on-device before rendering. An island signing *"I am operated by K"* is worthless —
the liar signs its own alibi — so the signature direction is the entire mechanism,
not an implementation detail.

Second, and the same question one layer out: **discovery is additive, never a
gate.** A client's reachable set MUST NOT be reducible to what the island it is
currently on chooses to advertise.

> **Blocking dependency.** This ADR specifies the client half. It has zero shipped
> value until `aiko-chat-island` serves the attestation: a statement shape, a place
> to store it, and a way for an operator to produce one. Until that lands, the
> honest client behaviour is to render **no operator at all** — which is this ADR's
> fail-closed default, not a degradation of it.

## Motivation

The island picker's list source is, per its own doc comment, *"the live directory
fetched from the CURRENT island, merged over the known-islands seed set."*

**So island A tells you about island B.** Today everything A says about B is
cosmetic, and the exposure is bounded — A can give B an unflattering description.
The moment an operator identity enters that record, A can assert that B is
operated by *anyone*, including a person the reader trusts. The reader is then
making a trust decision about B by reading a stranger's claim about a third party,
with no way to tell.

This is the shape claude-tasks#3774 already names in a different screen: *"an
evidence viewer MUST verify signatures itself and never render the island's
attribution."* Rendering `Operator: @andy` because a JSON field said so is that
failure verbatim.

**There is also a word collision, and it turned out to be the more interesting
finding.** `operator` is currently used in this app's prose for the moderation
seat — `report_queue_screen.dart` manages both words in a single sentence: *"The
**moderator** triage queue (#33/#35 — the **operator** seat)… lets an **operator**
take a message down."*

Two genuinely different roles had collapsed into one noun:

| role | what it is | accountable for |
|---|---|---|
| **Moderator** | takes messages down, dismisses reports, bans senders | **conduct** on an island |
| **Operator** | runs the island — the infrastructure, the deployment, the terms | **the island's existence** |

An operator may appoint moderators; a moderator need not be an operator; and on a
one-person island they are the same human wearing two hats, which is exactly why
the words drifted.

**The measurement (2026-09-07):** every IDENTIFIER is already correct —
`isModeratorProvider`, `AuthUser.isModerator`, the server's `ModeratorUser` gate.
`operator` appears **zero** times in identifier position across `lib/` and `test/`
(verified with a positive control on the same filter). All 42 `lib/` occurrences,
10 in `test/`, and 19 in `docs/` are prose. One file already uses the word in its
correct sense: `island_directory_client.dart:2` — *"which independent operators
exist to connect to?"*

So the code was right and only the language wobbled. The vocabulary fix is a
prose-only change with no code risk, and it FREES the word rather than forcing the
picker to find a weaker one.

## Proposal

### 0. Operator and Moderator are different things (decided 2026-09-07, Nick)

**Moderator** governs conduct: takedowns, report triage, bans. Scoped to an
island's *content*. Gated by `isModeratorProvider` / the server's `ModeratorUser`.

**Operator** runs the island: it exists because they run it. Scoped to the
island's *existence*. This is the role the picker field names, and it is the role
that signs the attestation in §2.

Neither implies the other. An operator may appoint moderators and hold no
moderator flag themselves; a moderator has no claim on the infrastructure. They
coincide on a one-person island, which is why they collapsed in the first place —
and a vocabulary that is only correct in the degenerate case is not correct.

**Consequence:** the prose that calls the moderation seat "the operator seat" is
wrong and should say "moderator" (see Motivation for the measurement — identifiers
are already right, so this is prose-only). The word `operator` is then available
for its real meaning, which is what this ADR needs it for.

### 1. Two tiers, and the tier is a property of the FIELD, not the island

| field | tier | client behaviour |
|---|---|---|
| `label` | cosmetic | render |
| `description` | cosmetic | render (optional; absent is fine) |
| `region` | cosmetic | render |
| icon / `IslandMark` | cosmetic | render (derived, not asserted — see §4) |
| **operator** | **attested** | render **only** on successful on-device verification |

A field does not become attested by an island promising it is true. The tier is
fixed by this document.

### 2. The operator attestation

The **operator's key** signs a statement naming the island:

```
{
  "island": "<the island's stable identifier>",
  "operator": "<operator public key>",
  "issued_at": "<ISO8601>",
  "expires_at": "<ISO8601>"
}
```

signed with the operator's Ed25519 key, using the same canonical-bytes discipline
as `lib/features/chat/domain/message_signing.dart`.

Three properties, each load-bearing:

- **Direction.** The *operator* signs, not the island. An island cannot forge a
  key it does not hold, so it cannot invent an operator.
- **The statement names the island.** Without this, a genuine attestation by K
  about K's own island can be replayed by a hostile island claiming K.
- **It expires.** Otherwise an island keeps serving a true-in-2026 attestation
  long after the operator walked away. Expiry is the cheap half of revocation;
  see Unresolved.

### 3. Fail closed, and fail SILENT

If the attestation is absent, malformed, expired, or fails verification, the
client renders **no operator** — not "unverified operator", not a warning triangle.

This is deliberate. An "unverified" label is still a claim about a person, and it
puts the word — and the name — in front of a reader who will remember the name and
forget the qualifier. An island that does not attest simply has no operator shown,
which is *true*.

### 4. Rendering: identicon primary, handle as a scoped hint

Both, per Nick's call — with the ordering fixed by ADR-0004.

The `IslandMark`-style identicon is **derived from the key**: stable, global,
unforgeable, and meaningful to anyone who has seen that key before. It is the
identity.

The handle is a **home-scoped display alias** (ADR-0004), so a bare `@andy` in a
list of four islands invites the reader to assume a global namespace this project
deliberately does not have. Render the handle with its home visible, as a
human-readable hint beneath the mark — never as the primary identifier.

### 5. Discovery is additive, never a gate

Today the picker's raw-URL field means **you can reach an island nobody has
listed**. That is the sovereignty property ADR-0004's "no central directory" exists
to protect.

A search field is a good idea and MUST NOT cost that. So:

- The field accepts search terms **and** URLs.
- A URL input surfaces "connect to this directly" as a **first-class result**, not
  a fallback after no matches.
- Search results are additive discovery over the current island's directory ∪ the
  ever-seen set — never the boundary of what is reachable.

**The failure this forecloses:** a search-only field collapses the reachable set to
whatever the incumbent island advertises. The data layer stays decentralised while
the *interaction layer* grows a directory dependency — one controlled by an island
that now decides whether its competitors are findable. "No central directory" is
not preserved by a decentralised data model if the UI only ever surfaces what one
party serves.

## Rationale and alternatives

**Alternative A — ship the operator field unsigned, with a weaker noun
("self-described as").** Rejected — and note that §0 removes the original
motivation for it. The weak noun was a workaround for a word collision that no
longer exists; what remains is the trust argument alone, which stands on its own. It manufactures exactly the confidence it
cannot back: the qualifier is read once and the name is remembered. It also does
not survive contact with a future redesign, because a weak noun on a strong-looking
row is precisely the thing a tidy-up deletes. Signing is cheap here — the app
already has Ed25519, canonical-bytes signing, and on-device verification — so the
weak-noun compromise buys nothing.

**Alternative B — the island signs "I am operated by K".** Rejected: it proves only
that the island said it. The party with the motive to lie is the party holding the
pen.

**Alternative C — a registry of island operators.** Rejected by ADR-0004: no
central directory. It would also make the operator field *more* trustworthy than
the identity system it sits inside, which is a smell.

**Alternative D — domain control as the attestation** (whoever holds the TLS cert
for `chat.example.com` is the operator). Genuinely attractive and **deferred, not
dismissed**: it is real-world evidence, already present, and needs no new
statement. But it proves control of a *host*, not possession of an *aiko identity* —
so it cannot express "Andy operates this" in the terms the rest of the product
uses, and it cannot be shown as an identicon. Worth revisiting if operator
attestation adoption is poor: domain control could be a second, weaker tier.

## Prior art

> **⚠ claude-tasks#3973 was found AFTER this ADR was drafted, and it should have been
> found before.** The global tracker search that would have surfaced it was run this
> same day for a different topic and not for "attestation" — the exact miss
> `feedback_assume_absence_before_inventory` names. Recording it here rather than
> quietly folding it in, because a citation added late reads identically to one
> found early, and the difference matters for how much independent weight the
> convergence below deserves.

**claude-tasks#3973 — "Attestation is the missing foundation under #3796, #1962 and
the update audit."** Opened 2026-09-06 on the island repo, one day before this ADR,
at Nick's explicit push (*"attestation solves this and other things!!"*), flagged for
a crucible. It reaches this ADR's central mechanism independently and states it more
generally:

> *"`/v1/island` is signed — but **by the island's own key**, so it proves identity,
> never honesty."*

That is exactly §2's rule (an island signing *"I am operated by K"* is worthless)
generalised past the operator field to every claim an island makes about itself. Its
framing is the better one and should govern: **the goal is not preventing a lying
operator but making dishonesty expensive, specific, and eventually visible** — the
Certificate Transparency posture, which does not stop a CA mis-issuing and instead
makes mis-issuance permanently public.

**Consequence for this ADR's status.** ADR-0008 is a *consumer* of that foundation,
not an alternative to it. Two things follow:
1. The operator attestation should be **one statement type within #3973's evidence
   layer**, not a bespoke signing path invented for the picker screen. If #3973's
   crucible produces a general attestation envelope, §2's payload becomes an instance
   of it.
2. The **transparency/visibility half is missing here.** This ADR makes a false
   operator claim *unrenderable*; it does nothing to make an attempt *visible*. On
   #3973's framing that is the weaker half of the job, and it is a real gap in §2
   rather than out of scope.

Convergence note, priced honestly: the app and island tabs reached "self-signature
proves identity, never honesty" separately, a day apart, from different problems.
That is genuine corroboration of the principle — and no evidence at all that either
document's *scope* is right, which is what the crucible is for.

- **ADR-0004** — identity is the key; handles are home-scoped; no central
  directory. This ADR is an application of all three.
- **claude-tasks#3774** — an evidence viewer must verify signatures itself and
  never render the island's attribution. Same rule, different screen.
- **The Carried Record** (`project_the_carried_record`) — the established
  carrier-not-verifier distinction: an island may *carry* a signed statement and
  never *certify* it.
- **Signed-at-birth messages** — the existing precedent that a claim about
  authorship travels with its own proof rather than relying on the transport.

## Unresolved questions

1. **Revocation beyond expiry.** Expiry handles the operator who walks away. It
   does not handle the operator who needs to disown an island *today*. Where does a
   revocation live, given no central directory? Plausibly: the operator's own
   island serves it, and clients that have seen the attestation re-check. Needs
   the island tab.
2. **What is the island's stable identifier** in the signed statement? The
   normalized URL is what the app dedupes on today, but URLs move. A URL-bound
   attestation breaks on migration; an id-bound one needs an id nobody can squat.
3. **Does a mutual attestation add anything?** (island also signs "K operates
   me".) It would let an island *decline* an operator's claim. Unclear whether
   that failure mode is real.
4. **Key → person binding is NOT solved here and is not this ADR's to solve.**
   Verification proves *"key K signed this"*, never *"K is the Andy you mean"*.
   That limit is inherited from ADR-0004, where identity *is* the key. The operator
   field is therefore meaningful to a reader who has met K and honestly
   meaningless to one who has not — which is the correct behaviour, and is why
   the identicon (recognisable on sight to someone who has seen it) is the primary
   rendering rather than the name.

## Rejected ideas

- **Rendering an unverified operator with a warning affordance.** See §3.
- **Trusting the directory because it arrived over TLS from an island you are
  logged into.** Transport is not trust: the session proves you are talking to the
  island you chose, and says nothing about that island's claims regarding third
  parties.
- **Deferring the whole question until multi-homing.** The exposure exists as soon
  as the field ships, and the field is otherwise a one-line UI change that would
  look entirely harmless in review.
