# Aiko design records — index

*Draft Discussion body for the series kickoff. Do not post until Andy has seen the shape.*

---

On the 2026-07-16 call Andy proposed the documentation approach this puts into practice: **OpenSpec** (spec-driven development, so coding agents get a constitution to build against) with **classic RFCs as the format for protocols**. Working through it produced a distinction worth keeping, because the two kinds of document we actually have want different voices:

## Two document classes

**ADRs (Architecture Decision Records)** record a *decision*: what we chose, why, what we rejected. They argue. They live in `docs/adr/`, numbered in decision order, with a status (`Draft` → `Accepted` / `Rejected` / `Superseded`).

**RFCs** specify a *contract*: wire formats, protocols, state machines, written dry and normative (RFC 2119 keywords, test vectors), implementable from the document alone. They live with the code that proves them, and their conformance suites are generated from the reference implementation - so they are exactly the constitution OpenSpec wants to hand a coding agent.

The pipeline: ADR (why) → RFC/spec (what) → code (derived, verified against the spec's vectors).

## The ADR series

| ADR | Title | Status | Owner |
|-----|-------|--------|-------|
| 0001 | The federation vocabulary | Accepted (two named forks open) | Andy (write-up: Nick) |
| 0002 | EC for observation, API for structure | Accepted (retroactive) | Andy (write-up: Nick) |
| 0003 | Users: ChatServer CRUD + general-purpose ECConsumer | Reserved (supersedes issue #6; ChatServer CRUD example may be Nick's to build, per the call) | Andy + Nick |
| 0004 | Sovereign identity federation | Reserved (design exists, not yet distilled) | Nick |
| 0005 | The identity graph | Draft | Nick |
| 0006 | Sybil resistance: reputation, not personhood | Draft | Nick |
| 0007 | Porting Aiko Services to other languages | Reserved (Andy's research in progress) | Andy |

## The RFC series (protocol specifications)

| RFC | Title | Status | Home |
|-----|-------|--------|------|
| 0001 | The Aiko S-expression wire format | Draft (conformance suite: 15+15 vectors generated from parser.py) | `aiko_services_dart/docs/rfc/` |
| — | Actor dispatch protocol (proxy/dispatcher mirror contract) | Future | |
| — | Eventual Consistency protocol | Future | |
| — | Registrar protocol | Future | |

Writing RFC-0001 immediately paid for itself: specifying the length-prefix rule precisely surfaced (and fixed) a real cross-language bug - the Dart codec counted UTF-16 units where Python counts code points, silently corrupting any emoji on the wire.

## ADR template

Header table (ADR / Status / Owner / Created / Thread), then: Summary · Motivation · Proposal (guide-level first) · Rationale and alternatives · Prior art · Unresolved questions · Rejected ideas. Retroactive ADRs may collapse sections.

## Why this and not just Discussions?

A Discussion is a conversation; an ADR is a conversation *with a decision at the end*, and an RFC is a contract a machine can be held to. Six months from now, "why do bots have their own Principals?" is answered by ADR-0005's thread, and "what exactly does `3:` mean?" is answered by RFC-0001 §3.3 - not by archaeology across Signal, issues, and commit messages.
