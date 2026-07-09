# TEMPER — cross-family design strike (round 1)

> The cold pole. Cage-match adversaries struck `CRUCIBLE.md + RESEARCH.md + DESIGN.md` hunting
> FATAL DESIGN flaws. **Real temper** (not persona-provisional): Maxwell + two cross-family
> adversaries landed. Kelvin (Gemini-2.5-pro) returned empty this round → noted, not blocking.

## Panel & verdicts

| Reviewer | Family | Verdict | Status |
|---|---|---|---|
| Maxwell | Claude (author-instance — low weight on intent, kept for domain-local catches) | REQUEST_CHANGES | ✓ |
| Carnot | Codex / GPT | REQUEST_CHANGES | ✓ full review |
| Tesla | Grok | REQUEST_CHANGES | ✓ full review |
| Kelvin | Gemini | — | empty output (down this round) |

Gate: Maxwell + ≥1 adversary → **satisfied** (two adversaries). Every finding is foldable;
**none dissolves the candidate** → the ore survives, the design hardens. This is fold-back
round 1 of ≤3.

## Findings (4 consensus + fold decisions)

### T1 — Emit-before-deploy is a permanent history split, not a dormant switch (CONSENSUS: Maxwell F1, Carnot C3, Tesla F1) — **FOLD**
"Safe-but-inert" verified the *transport* instrument, not the *trust/history* instrument.
Messages sent while the gateway lacks carriage are acked but stored origin-less **forever**
(no backfill; alembic 0011 does not resurrect dropped JSON). Sender-local reads "signed";
network-of-record + every other device read "unsigned, no envelope" → split-brain that does
NOT self-heal. C3 ("doesn't break sending") is true and nearly irrelevant.
**Fold:** remove the coupling, don't guard the window. Emission is **gated on per-gateway
observed carriage capability** (probe/version), NOT lock-step deploy — this is also the correct
FEDERATED design (peer islands deploy on their own clocks; we can't deploy-first for islands we
don't own). Truth-claim scoped to `created_at ≥ carriage-active` per gateway. For the one
gateway we control, deploy carriage first as well.

### T2 — Inbound trust-boundary inversion: persist the echo without re-validating (CONSENSUS: Maxwell F2, Carnot) — **FOLD**
The echo arrives over transport; the design `jsonEncode`s it straight to SQLite. A
stale/compromised/dev/federated gateway can inject unbounded/nested JSON → row growth, hostile
`jsonDecode`, base58/Multikey decode-cost bomb. "The gateway validates" is inheriting
authentication from the transport.
**Fold:** mirror `validate_origin`'s gate on app ingest BEFORE cache write (exact-7-keys,
primitive types, length caps, timestamp bounds, base64url charset, Multikey length cap). Invalid
origin → **drop the origin, keep the message** (mark unverified), never kill the message. Reuse
the Dart `validate_origin` port we build for the outbound golden-vector test as the SAME
inbound admission gate (one door).

### T3 — C2 "opaque/verbatim" is false as written; Map→jsonEncode IS re-canonicalization (CONSENSUS: Carnot C2, Tesla F2 — Maxwell MISSED) — **FOLD**
`fromView` → Dart `Map` → `jsonEncode` to TEXT is a second serialization: key order, spacing,
number format not wire-identical. C2 claimed byte-identity but specified a path that fails it.
The signature covers `signingBytes` rebuilt from FIELDS, not JSON envelope bytes → byte-identity
is the WRONG invariant anyway.
**Fold:** downgrade C2 to **semantic field-identity** — "the persisted origin reconstructs
`signingBytes` and re-verifies," with a test that does NOT assert `utf8(wire)==utf8(cache)`.
Persist a **canonical app-owned `OriginEnvelope`** (validated per T2), not a blind blob. (If a
byte-exact re-echo audit is ever needed, store the raw frame substring separately — not needed
now.)

### T4 — C5 is a half-law: clear-on-diverge without set-on-success or dual-store coherence (CONSENSUS: Maxwell F3, Carnot C5, Tesla F3) — **FOLD**
Collapse only CLEARS origin on signed-field divergence; it never **SETS** the echoed origin onto
a reconciled row when fields match → own optimistic messages may keep local sig columns but never
persist an envelope. Two stores (local `sig/pubkey/signedAtMs/keyVersion` columns + `origin` TEXT)
can disagree. Three legal states unnamed.
**Fold:** full invariant — (a) **set-on-success**: on ack/echo with matching signed fields, write
the (re-validated) echoed origin onto the surviving row; (b) **dual-store coherence**: if either
store is cleared, clear both; if both present they MUST project the same key/sig/time/version;
(c) name the three legal states — *columns-only* (pre-feature history), *origin-only* (others'
messages / rehydrate), *both* (own, reconciled) — and define which store feeds verify.
**Depends on** an unstated fact to confirm at build: does the sender self-receive its own message
echoed with origin, or only an `ack`? (branches set-on-success). Flag to resolve at step 1.

### T5 — Raw inbound persist without local-verify is negative useful work (Carnot build-order, Tesla echo) — **FOLD**
Before PR B there's no sender UI; a persisted-but-unverified origin is attacker-controlled
decoration with storage+DoS cost. The first useful sink is bounded-ingest + local verdict.
**Fold:** merge DESIGN steps 3 and 5 — validate + persist + compute/store a verify verdict in
ONE step (no UI). "No verified-sender UI" stays; a stored local verdict is not UI.

## The rhyme (one law, three sites)
T1 + T2 + T3 all reduce to **"delivered ≠ carried/authenticated/conserved"** — the
transport-vs-trust-boundary law. Folded as a chord, not three patches: the app never trusts a
property (carriage, authenticity, integrity) it hasn't independently established at the boundary
where that property is consumed.

## Judgment call surfaced (not a fold — for Nick)
Carnot's option-frame strike: product value is gated TWICE (gateway deploy + pubkey→account
binding PR B), so is the wire half worth building now with no verified-sender UI? Named tradeoff
#1/#3 already logs this. My read: yes — frozen contract + portable local history are independently
useful and waiting couples us to the peer timeline — but it's Nick's call, surfaced not buried.

## Outcome
Design SURVIVES (all findings foldable). Re-cast applied to DESIGN.md v2. A re-strike (round 2)
is available but each fold answers a precise named finding; recommend proceeding to Blade with
the folds visible, Nick's option-frame call taken first.
