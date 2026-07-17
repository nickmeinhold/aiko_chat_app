# RFC-0002: EC for observation, API for structure

| | |
|---|---|
| **RFC** | 0002 |
| **Status** | Accepted (retroactive) |
| **Owner** | Andy Gelme (write-up: Nick Meinhold, with Claude) |
| **Created** | 2026-07 (decision, Signal + aiko_chat#6 thread) / 2026-07-17 (write-up) |
| **Thread** | *(Discussion link once posted)* |

## Summary

Eventual Consistency (EC) shares are a one-way observation surface; anything structural (create, update, delete) goes through the HyperSpace/Category API. An EC observer is looking at an Actor's *internal state*, not a public contract, so EC must never become a mutation path or an implied API.

## Motivation

Aiko Services offers two ways to get data out of a running system, and without a rule they blur: EC shares (ECProducer/ECConsumer, push-based, cache-friendly) and the Category/HyperSpace API (request/response, typed, structural). The `user_list` proposal (aiko_chat#6) forced the question: should a gateway learn the user list by observing an EC share, or by calling the API?

## The decision

1. **EC = observe.** Dashboards, liveness, telemetry, "what is this Actor doing right now." One-way by design. The observed variables are the Actor's internal state and may change shape without notice.
2. **API = structure.** CRUD on channels, users, and anything else with a lifecycle goes through the ChatServer / Category API, with "list users" as a named priority.
3. **The generic ECConsumer pattern.** The EC side grows a general-purpose consumer: (a) listen to a remote ECProducer with a filter, (b) keep a local cache of recent values, (c) offer a non-blocking `get` of the latest value. This makes observation cheap everywhere without minting bespoke shares per use case.

Consequence: aiko_chat#6's bespoke `user_list` EC share dissolves into this split (its need is met by 2 + 3). The follow-up build is tracked in RFC-0003 (reserved, Andy's).

## Rationale and alternatives

The alternative was EC-as-API: cheap to start (a 3-line share) but it freezes an Actor's internals into a de-facto public contract, and every consumer becomes a reason the Actor can never refactor. The chosen split gives structural consumers a typed contract and leaves Actors free to evolve internally.

## Prior art

The same fault line as CQRS (command/query responsibility segregation) and as "metrics are not APIs" in observability practice: read-side projections may be denormalized, lossy, and reshaped; the write side is the contract.

## Unresolved questions

- Filter semantics and cache-invalidation behaviour of the general-purpose ECConsumer (design lives with RFC-0003's build).
