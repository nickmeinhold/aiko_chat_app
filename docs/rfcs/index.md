# Aiko Chat RFCs — index

*Draft Discussion body: the series kickoff post. Do not post until Andy has blessed the convention.*

---

This project is accumulating design decisions faster than any one thread can hold them: vocabulary, the EC/API split, identity, sybil resistance, porting. This post proposes a lightweight RFC convention so each decision gets a number, a thread, and a status - and newcomers can reconstruct *why* things are the way they are by reading the series.

## The convention (deliberately minimal)

- **One RFC = one decision = one Discussion.** Comments happen in the thread; the opening post is edited to record the outcome.
- **Statuses:** `Draft` (requesting comments) → `Accepted` / `Rejected` / `Superseded by RFC-NNNN`. Retroactive RFCs document decisions already made and enter as `Accepted`.
- **Numbering is decision order, not writing order.** Low numbers are the foundations later RFCs stand on.
- **Anyone can write one.** If a design conversation is going in circles, "write it as an RFC" is the escape hatch.

## The series so far

| RFC | Title | Status | Owner |
|-----|-------|--------|-------|
| 0001 | The federation vocabulary | Accepted (two named forks open) | Andy (retroactive write-up: Nick) |
| 0002 | EC for observation, API for structure | Accepted (retroactive) | Andy (retroactive write-up: Nick) |
| 0003 | Users: ChatServer CRUD + general-purpose ECConsumer | Reserved - Andy's to write (supersedes issue #6) | Andy |
| 0004 | Sovereign identity federation | Reserved (design exists, not yet RFC'd) | Nick |
| 0005 | The identity graph | Draft | Nick |
| 0006 | Sybil resistance: reputation, not personhood | Draft | Nick |
| 0007 | Porting Aiko Services to other languages | Reserved (Andy's research in progress) | Andy |

Reserved numbers are placeholders so the dependency order stays honest; they become real when their owner posts them.

## The template

Descended from Rust's RFC template with Python PEP's status machine, trimmed to our size:

```markdown
| RFC | NNNN | Status | Draft | Owner | name | Created | date | Thread | link |

## Summary        (three sentences, max)
## Motivation     (what breaks or stays ambiguous if we don't decide this)
## Proposal       (guide-level first: what it feels like to use;
                   reference detail links out to design docs)
## Rationale and alternatives
## Prior art      (what exists elsewhere; cite it)
## Unresolved questions
## Rejected ideas (grows as the thread resolves; starts empty)
```

Retroactive RFCs may collapse sections that don't apply. If an RFC ever specifies
wire-level behaviour, adopt RFC 2119 keywords (MUST/SHOULD/MAY) for that section.

## Why RFCs and not just Discussions?

A Discussion is a conversation; an RFC is a conversation *with a decision at the end*. The status field is the whole trick: six months from now, "why do bots have their own Principals?" is answered by RFC-0005's thread, not by archaeology across Signal, issues, and commit messages.

Comments on the convention itself welcome here. First real threads (0005, 0006) follow once this shape settles.
