# CRUCIBLE — Sovereign signing, the wire half (`origin` envelope carriage)

> The hot-phase artifact. This is the **enthusiasm case + its falsifier**, written so a
> cold cross-family adversary (Temper) can strike the assumptions the excitement smuggled in.
> Task **#19 / claude-tasks #1817**. Continues the signing *core* crucible in the parent dir.

## The spark (why drop everything for this)

Sovereignty that never leaves the device is a **diary, not a protocol**. The app already
signs every message client-side (Ed25519 over a frozen, length-prefixed, domain-separated
byte layout — `../SIGNING-SPEC.md`, golden-vector pinned) and keeps a *local* verifiable
history — but it **deliberately emits nothing on the wire** (`message_signing.dart:10`).
The whole federation north star ("better than Matrix" — messages that carry their own proof
independent of any server's goodwill) is **inert** until a signed message actually *travels
signed* and a recipient can *verify it from bytes alone*.

As of **2026-07-09**, for the first time, both ends of that wire exist: aiko-chat-island
**PR #66** shipped the gateway carriage — `validate_origin()` (fail-closed shape check at the
WS trust boundary) + `messages.origin` (migration `0011`) + persist/echo through the two
single choke points (`create_outbound`, `message_view`). Its PR body names **#1817** as the
thing it unblocks. This increment is the hinge: it turns "we sign locally" into "aiko
messages are portably, cryptographically self-authenticating across islands."

## Why it's real (not an invention)

- **The mold was cast before the metal existed.** The app's own signing-core crucible froze
  the wire envelope shape (`SIGNING-SPEC.md §45`, "NOT shipped yet — gated on gateway
  carriage") and *chose* to defer emission. We are picking up a baton set down on purpose.
- **One frozen object, two views.** App `SIGNING-SPEC §45` and gateway `validate_origin()`
  demand the **identical seven keys** — `v, alg, key_version, sender_pubkey, client_msg_id,
  signed_at_ms, sig` — both pinned to the same golden vector. This is carriage, not redesign.

## Scores (aliveness × impact)

- **Aliveness 3** — load-bearing artifact of the federation north star
  (`project_federation_north_star`); the app spec left a door open *specifically* for this.
- **Impact 3** — unblocks the entire "verifiable history *travels*" property; nothing
  downstream in federation works without it. Removes no human task directly, but it is the
  precondition for every trust feature that does.
- **Product 9.** No slag on either axis.

## The falsifier (what would prove this ore is slag)

**If the gateway does not actually persist + echo `origin` on the live read paths**, the app
emits into a void and "verifiable travel" is a lie. PR #66 is merged to island `main`, but
`project_gateway_deploy_mechanism` warns the gateway is **not auto-deployed** (rsync + compose
rebuild on the host). **Heat's first job: confirm a round-tripped `origin` survives on the
deployed `chat.imagineering.cc`** before casting any design. If it does not survive, the ore
is cold and the real work is "get carriage deployed," not "emit from the app."

## Claims to falsify (carried to Temper)

1. **The contract is truly frozen and symmetric** — app §45 and gateway `validate_origin`
   never diverge (golden vector is the guard). *Risk:* the app emits a field the gateway caps
   or rejects (e.g. `sender_pubkey` Multikey length, `client_msg_id` width 64).
2. **Emission is a pure plumbing add** — the send frame gains one nested object; no existing
   field changes. *Risk:* the transport envelope (`envelopes.dart`) or ack/echo parsing has a
   strict-shape assertion (PR#7 cage-match "String-keyed bug") that a new key trips.
3. **`origin.client_msg_id` MUST equal the frame's `client_msg_id`** (gateway's sole binding).
   *Risk:* the app uses a different id at the frame level vs. what it signed → gateway rejects
   `bad_origin` and the message silently fails to send.
4. **Inbound persist is safe and idempotent** — storing an echoed `origin` in the local cache
   (`drift_cache.dart`) and re-verifying is additive. *Risk:* re-serialization on cache read
   (`.wire` round-trip) mutates bytes and breaks a later verify (the app's own `feature-
   interaction` lifecycle axis).
5. **No "verified sender" UI ships** — the gateway header is explicit: echo ≠ identity
   ("forgery-as-echo"); the pubkey→account binding is PR B (`signing_keys`), not live.
   *Risk:* the temptation to render a checkmark from a locally-verifying sig with no trust root.

## Rejected alternatives (carried to Temper)

- **Emit unconditionally, ignore the gateway's tolerance window.** Rejected: the handoff says
  the gateway *tolerates* absent origin and only later flips `social_nonce_required`-style
  strictness; but a malformed origin is `bad_origin`-rejected *now*. Fail-closed emission
  (self-verify before emit, already in `sign()`) is the safe path.
- **Verify inbound at render time, don't persist the envelope.** Rejected: loses portability
  — a recipient forwarding/re-syncing history must carry origin, and re-derivation on every
  read is wasteful. Persist verbatim; verify once on ingest, cache the verdict.
- **Wait for PR B (`signing_keys` / pubkey→account binding) and ship both together.** Rejected:
  the carriage is independently useful (local verify + portable bytes) and PR B is peer-owned
  (#18/#1816) with no app dependency. Shipping the wire half now is the core-first build order.

## Named tradeoff (pre-declared)

**No trust root yet** → the wire half carries and locally-verifies signatures but renders **no**
"verified sender" affordance. Owner: product/security (task #20 / #1818). Accepted cost:
a verifiable signature the user can't *see* verified. Mitigation: it's the honest state until
PR B binds pubkey→account; a premature checkmark would be forgery-as-echo.
