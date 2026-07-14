# 🜂 DESIGN v2 (tempered) — Proof-of-Possession Identity Binding

> Cast, recast after the cross-family Temper (see `TEMPER.md` — unanimous
> RECAST-NEEDED, ore survived). This v2 folds all 5 consensus findings (F1–F5) +
> M1 + the framing corrections. Scoping (Nick): **design the full inversion arc,
> ship the toe-dip**; and (post-temper) **ship the badge WITH hardened copy**.

## Framing correction (Temper: "enthusiasm smuggling")

Increment 1 is **NOT** "the keystone of federation." It is **possession-backed
device-key registration under a passkey account** — a WebAuthn-adjacent hardening of
the roster. The reusable **primitive** (domain-separated PoP + a sealed roster) is the
metal that #21 and #24 need; the badge is optional chrome. Increment 1 does **not**
move the gateway from namer to attester — that is Increment 2, which is an **identity
migration** (its own design, task #30), not a paragraph here.

## Problem

Messages already carry a sovereign Ed25519 signature. The gateway already keeps a
pubkey→account **roster** (`signing_keys` table, `POST/GET/DELETE /v1/keys`, send-time
upsert via `record_signing_key`) — but every current write path records an **ASSERTED**
pubkey, never one **PROVEN** to be controlled. The one missing brick: a
proof-of-possession challenge, plus a roster that cannot confuse proven with asserted.

## Shape

### Atypical element — a new signing domain
PoP is signed over the tag `aikochat:pop:v1:EdDSA`, **never** the message
`signingBytes` (cross-protocol reuse = bug). Payload:
```
signed_bytes = domain_tag("aikochat:pop:v1:EdDSA")
             ‖ audience_kind ‖ audience_value   (TYPED — F2; not one opaque string)
             ‖ nonce                            (server-minted, CSPRNG, single-use)
             ‖ signed_at_ms                     (secondary skew check only)
             ‖ sender_pubkey                    (raw-32, key-substitution defence)
```

### F1 — seal the mutator, don't guard the flag *(all 4 reviewers)*
- **Dedicated `POST /v1/keys/prove`** (challenge + verify pair). Do NOT overload bare
  `POST /v1/keys` with optional PoP fields.
- **PoP is the ONLY writer** that may set `proven` (write-once monotonic: null/false→true).
- Storage: a separate **`proven_keys`** (attestation) table written only by the verify
  path, joined for reads — OR one table with explicit `assert`|`prove` upsert modes where
  `assert` has a column allowlist that **cannot touch proven fields**, atomic with nonce
  consume. (Lean: separate table — hardest to contaminate.)
- **Writer census + transition table** (must be exhaustive): send-time `record_signing_key`
  (assert only) · `POST /v1/keys` (assert) · `POST /v1/keys/prove` (the only prove) ·
  `DELETE /v1/keys` (clears both) · future admin. Transitions: ASSERTED→PROVEN only via
  PoP; DELETE→gone; re-assert after prove does NOT demote; double-prove idempotent.
- **API contract:** every roster read returns `state: asserted|proven` (or omits asserted
  from "trusted keys" endpoints) — so no client can build a false badge from `GET /v1/keys`.

### F2 — audience is one gateway, many names *(all 4)*
- A **static configured `GATEWAY_AUDIENCE`/issuer allow-list**. The audience is derived
  from that list, **NEVER from the client `Host` header** (Kelvin: Host-derived audience =
  DNS-rebinding MITM — the user signs a valid PoP for an attacker origin). Reject a Host
  not on the list.
- One logical audience shared across all public hostnames of one deployment
  (`chat.imagineering.cc` + `chat.enspyr.co` = one verifier, two aliases; NOT a cross-relay
  attack).
- **Client echoes the challenge-bound audience** (from the challenge response), never
  re-derives it from its base-URL string. Server rejects if signed audience ≠ challenge audience.
- **Typed audience** (`audience_kind: url | gateway_key`): the "same field upgrades to a
  pinned pubkey later" claim is false (encoding/length/verification all change). `pop:v1`
  = url; a future `pop:v2` = pinned key.
- **Named tradeoff:** URL/issuer audience ≠ SSB/Veilid pin; impostor-at-TLS-termination
  stays open until a pinned gateway key (deferred). Do not overclaim NIP-42 strength.

### F3 — the real Inc-1 threat is stolen-session → malicious PROVEN *(all 4)*
A stolen JWT lets an attacker complete PoP for **their** key, binding the victim account
to the attacker's sovereign key (verified badge for the attacker under the victim's
account). This demolishes the naive "low blast-radius" claim.
- Nonce row `{nonce (PK, CSPRNG), user_id, audience, expires_at, consumed_at}`.
- **Atomic consume**, one statement, fail-closed:
  `UPDATE … WHERE nonce=? AND consumed_at IS NULL AND expires_at>now() AND user_id=? …`
- Server `expires_at` from issue-time is PRIMARY; client `signed_at_ms` is a secondary skew check.
- **Soft global-uniqueness (harden):** reject prove if the pubkey is already PROVEN for a
  **different** user — closes cross-account key sharing and prepares Inc-2 without shipping it.
- **Named threat:** stolen-session is the primary Inc-1 window; the badge means "the account
  session proved control of this key," NOT "this human's durable device."

### F4 + M1 — the badge ships, with hardened copy *(Nick's call; all 4 flagged the over-promise)*
- **Relabel** away from "verified sender" → e.g. **"signed · key proven for this account."**
  Never implies personhood.
- Show ONLY when `originCryptoValid` ∧ `PROVEN(account, pubkey)` ∧ not-expired. **Never for
  ASSERTED.**
- **M1 — multi-key is the NORMAL state, not an edge case:** passkeys sync (iCloud/Google)
  but the sovereign key is device-local, so a 2nd device on the same passkey account mints a
  2nd key → a 2nd PROVEN key. The UI must answer "this account has N proven keys" (all badged;
  a "primary" concept is deferred to the multi-device design, task #27).
- **Named tradeoff:** Increment 1 delivers "this account proved this key," NOT "pubkey IS the
  human." A tooltip states exactly that.

### F5 — X25519 local-only placeholder *(Carnot + Tesla)*
Mint a separate X25519 key locally, labelled `e2ee_placeholder_v0`; **never send it on the
wire, never bind it into PoP or `signing_keys`.** MLS/E2EE (#25) likely wants HPKE/per-device
LeafNode credentials, so this does **not** claim MLS readiness — it only avoids the
Ed25519→X25519 birational-conversion fantasy (unavailable in both stacks). Correction: the
migration cost that mattered was never the local seed, it's everyone's stored *peer* keys
(distributed state), which this does not touch.

## Build order (core-first)

1. **PoP primitive** (app Dart + gateway Python mirror): the `aikochat:pop:v1` typed
   signed-bytes builder/verifier, golden-vector pinned (like the message-signing twin).
   No UI, independently testable. ← reusable metal for #21/#24.
2. **Gateway: challenge + prove + sealed storage** — `GATEWAY_AUDIENCE` allow-list;
   `POST /v1/keys/challenge` (nonce row); `POST /v1/keys/prove` (atomic consume + write
   PROVEN); `proven_keys` table / allowlisted upsert; `state` on all roster reads; DELETE
   clears; reject-prove-if-proven-under-different-user.
3. **App: PoP registration under the authed session** — challenge → sign (typed audience,
   echoed) → prove.
4. **App: the badge** — hardened copy, strict conditions, multi-key rendering. ← Increment 1 ships.
5. **(local) X25519 placeholder** provisioning.
6. **(separate designs) Increment 2** identity migration (task #30); **key lifecycle**
   deletion/revocation/rotation (task #31).

## Blast radius + consent spine

- **Increment 1: low, but not trivial** — the stolen-session→PROVEN window (F3) is the real
  risk; mitigated by atomic consume + soft-uniqueness. Trust boundary = gateway PoP
  verification, backend-enforced. Injection surface = the challenge endpoint → rate-limit.
- **Malicious-gateway boundary (named, Carnot #9):** Increment 1 still trusts the gateway
  roster + account mapping. Sovereignty already lives at the *message* layer; Inc 1 hardens
  the roster, it does NOT achieve gateway-independent identity — that's Inc 2.
- **Increment 2: high** — auth-model / trust-boundary change; cage-match by law; task #30;
  gated on multi-device (#27).

## Claims to falsify (survived / folded)

All 5 seeded claims were struck and folded (see `TEMPER.md`): F1 proven/asserted (folded:
sealed mutator + dedicated endpoint + state on reads), F2 multi-URL replay (folded: static
allow-list + typed audience + MITM fix), F3 nonce/stolen-session (folded: atomic consume +
named threat), F4 false-trust (folded: hardened copy + strict conditions), F5 X25519
(folded: local-only placeholder).

## Open variables (enumerated)

- **[Build-time] Storage choice:** separate `proven_keys` table vs allowlisted single-table
  upsert. Lean separate; confirm against the gateway ORM in step 2.
- **[Dependency] Increment 2** gated on multi-device (#27); its own design (#30).
- **[Dependency] Key lifecycle** (deletion/revocation/rotation) = task #31 — Increment 1
  must at least define DELETE clears both states.
- **[#24 note, out of scope] MQTT reuse** needs a mosquitto plugin (not free); the PoP
  primitive is transport-agnostic and reusable there.

## Survives without ore recast
New domain tag + not-reusing-signingBytes · app-homed split · reject birational conversion ·
sequence inversion behind #21 · defer petnames/E2EE/MQTT.
