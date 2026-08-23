# CLAUDE.md — aiko_chat_app

The Flutter/Dart client for the aiko chat network. Talks to a self-hosted
**island gateway** (`../aiko-chat-island`) over a stable WSS + REST `/v1`
contract. Identity is a sovereign Ed25519 key (passkey-anchored); messages and
reactions are **signed-at-birth**. Stack: `dio` + `freezed` +
`json_serializable` (hand-written DTOs, no swagger codegen).

## Working conventions

- **Cross-tab grounding — read the ISLAND TAB's design record BEFORE ANY
  implementation, not just wire work.** The gateway is a peer repo
  (`../aiko-chat-island`, its own Claude tab) that co-owns far more than the wire:
  the identity model, moderation, federation, signing, community semantics,
  recovery, and the **deployment/runtime config of a shared island** (env,
  credentials, which services run where — reconfiguring APNs on enspyr in the
  middle of the island tab's push-topology design was the 2026-08-23 miss). Any of these can be decided in the island tab's docs and silently
  contradicted by an app change with **no wire touched at all**. So **before
  starting any non-trivial build, first check whether the island tab's record
  bears on it**, and if it does, build against THAT — the ticket is intent, the
  other tab's design is the other half of the binding contract. Read: the
  island's `docs/design/` and `docs/crucible/`, the `HANDOFF-to-app-tab-*`
  contract docs, the matching `nickmeinhold/claude-tasks` issue comments, and (for
  wire specifically) its served `/openapi.json` as a live drift-gate. This is the
  **#2634 lesson** (the reactions build came off a ticket + a narrow answer, never
  checked the recorded design, and a cross-family review then hardened the wrong
  premise for 7 rounds — a design-blind adversary confirms the author's frame, it
  doesn't question it). When the record and your memory disagree, that's a finding
  — surface it, don't tie-break. Reciprocal: the island tab has the mirror
  directive to read THIS repo's record before its builds.
  - **Our OWN design record is authoritative over an older cross-repo lock.** A
    numbered ADR here (`docs/adr/`) is the app tab's *decision of record*; when it
    post-dates a handoff answer we gave earlier, the ADR wins and the earlier lock
    is superseded (e.g. ADR-0004 "no central directory" supersedes the Aug-6
    mentions-directory handoff — mention *targets* key off the opaque identity,
    discovery is a per-island member roster you browse, no `/v1/mentions` search
    endpoint). Point the island tab at the superseding ADR when you notice the
    drift.

- **Conventional Commits.** Branch off `main`; commit + push proactively.
- **Signed-at-birth is a trust boundary.** Anything touching message/reaction
  signing, identity keys, or the wire contract gets an adversarial different-family
  review (`/cage-match`), not solo self-review.

## Where things live

- Design record: `docs/adr/` (numbered ADR outcomes — the decisions of record),
  `docs/design/` (design notes + newcomer explainers), `docs/crucible/`
  (tempered design docs).
- The gateway (peer repo): `../aiko-chat-island` — wire contract in its
  `HANDOFF-to-app-tab-*.md` + `docs/design/`, live schema at its `/openapi.json`.
- Tasks: `nickmeinhold/claude-tasks` (shared with the island tab).
- Message signer (the byte contract reactions mirror):
  `lib/features/chat/domain/message_signing.dart`.
