# ADR-0001: The federation vocabulary

| | |
|---|---|
| **ADR** | 0001 |
| **Status** | Accepted (retroactive; two named forks open) |
| **Owner** | Andy Gelme (write-up: Nick Meinhold, with Claude) |
| **Created** | 2026-07-10 (decision) / 2026-07-17 (write-up) |
| **Thread** | *(Discussion link once posted)* |

## Summary

Names the concepts the Aiko Chat federation is built from, so every later design conversation shares one language. The core set was developed by running the naming problem through two independent model families (ChatGPT and Claude) and keeping what both converged on; where they diverged, a real design decision is hiding, and those divergences are recorded here as open forks rather than papered over.

## Motivation

Vocabulary drift is design drift. "Server", "user", and "identity" each meant three different things across the codebase, the Signal threads, and the design docs. A federation involves enough genuinely distinct concepts (deployment boundary, transport adapter, accountable identity, chat-visible entity) that reusing everyday words silently merges them.

## The vocabulary (Accepted)

| Term | Meaning |
|------|---------|
| **Island** | An operator-run deployment; the sovereignty boundary. Owns domain, policy, reputation, identity admission, storage, and federation relationships. Contains multiple Aiko Services. The user-facing federation word. |
| **Gateway** | A thin internal bridge service inside an Island, adapting app/web/federation transports onto Aiko Service Interfaces. Deliberately not the whole system: auth, reputation, and directory become sibling services as they mature. |
| **ChatSpace** | The HyperSpace-backed graph of channels, participants, policy, and trust. Already `chat_space` in code. |
| **Participant** | Any chat-visible entity: human, bot, robot, service, agent. Addressing already distinguishes `@human` / `@@bot`. |
| **Principal** | The accountable identity behind participants; what bonds, vouches, and gets rate-limited. |
| **Self** | Product/UI word for the phone/device-held identity. In code it is a Principal credential, never a class named `Self`. |
| **Registrar** | Aiko *service* discovery within an Island. Explicitly not the federation directory. |

## Rationale and alternatives

Cross-family model consensus was the selection mechanism: two model families with different training lineages independently proposing the same name is meaningfully stronger evidence than one model liking it. The terms above were the convergent set from the 2026-07-10 pass.

## Unresolved questions (the two open forks)

1. **ChatServer → ChatRouter.** Both passes see a rename coming; they differ on timing. Position of record: keep `ChatServer` / `chat_server:1` for now because it is a versioned protocol identity, and revisit only after HyperSpace/LLM/robot responsibilities are factored out.
2. **IslandDirectory.** One pass names it (federated discovery of Islands, distinct from Registrar); the other folds it into future sibling services. Leaning toward naming it: two-level discovery (Registrar within an Island, IslandDirectory across the federation) is a real seam with different trust properties on each side. ADR-0006's genesis question is a further argument for naming it.

## Rejected ideas

- **`Self` as a code-level class.** It is a credential of a Principal, not a node of its own (elaborated in ADR-0005).
- **A single "user" concept.** The Participant/Principal split is load-bearing; collapsing them re-imports every ambiguity this vocabulary exists to remove.
