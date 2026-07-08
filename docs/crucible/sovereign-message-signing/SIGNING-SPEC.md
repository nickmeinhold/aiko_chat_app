# SIGNING-SPEC — aikochat message signature v1

> The **interop contract** for sovereign message signatures. Any verifier — this app, the gateway, or a future federation peer — MUST reproduce the signed bytes below EXACTLY. This is pinned by a golden-vector test (`test/features/chat/message_signing_test.dart`); a change here is a `v2`, never a silent edit. Frozen field **shape** 2026-07-08 (crucible: sovereign-message-signing). Carriage on the wire is a separate, gated step.

## Algorithm
- **Ed25519** (RFC 8032), detached signatures, raw 64-byte `R‖S` (no DER).
- Deterministic: the same key + same bytes → the same signature, so retransmits are byte-identical.
- Verification enforces the canonical `S`-range → non-malleable; no low-`s` normalization needed (unlike ECDSA).

## The signed bytes — `signingBytes(payload)`
Hand-built, **length-prefixed, domain-separated**. Every variable-length field is preceded by a **fixed-width big-endian u32** byte-length. Concatenation order is fixed:

| # | Field | Encoding |
|---|-------|----------|
| 1 | domain tag `aikochat:msg:v1:EdDSA` | u32-len ‖ UTF-8 bytes |
| 2 | sender public key | u32-len ‖ **raw 32 bytes** (NOT Multikey — raw here) |
| 3 | `channel_id` | u32-len ‖ UTF-8 |
| 4 | `client_msg_id` | u32-len ‖ UTF-8 |
| 5 | `signed_at_ms` | **u64 big-endian** (no length prefix; fixed width) |
| 6 | `body` | u32-len ‖ UTF-8 |
| 7 | `reply_to` (or empty string) | u32-len ‖ UTF-8 |

**Why each field:** domain tag binds app + algorithm (anti-replay across structures, anti-downgrade); raw pubkey inside the bytes defends key-substitution; `channel_id` stops cross-channel replay; `client_msg_id` is the stable, verifier-reconstructable id; `signed_at_ms` is the compose-time clock (persisted independently of the server `created_at`, which ack reconciliation overwrites); `body`/`reply_to` are the content.

**Length-prefixing is load-bearing:** without it `channel_id="ab", client_msg_id="c"` and `channel_id="a", client_msg_id="bc"` would sign identical bytes.

## Golden vector (the CI-gated known answer)
Fixture:
- `sender_pubkey` = raw 32 bytes `00 01 02 … 1f`
- `channel_id` = `chan-1`
- `client_msg_id` = `tmp-abc`
- `signed_at_ms` = `1720000000000`
- `body` = `hello world`
- `reply_to` = null (→ empty)

`signingBytes` (hex):
```
0000001561696b6f636861743a6d73673a76313a456444534100000020
000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
000000066368616e2d3100000007746d702d6162630000019077fd3000
0000000b68656c6c6f20776f726c6400000000
```
(A verifier that produces different bytes for this fixture is non-conformant.)

## Wire envelope (NOT shipped yet — gated on gateway carriage)
When the gateway confirms it will persist + echo the object, messages carry:
```json
"origin": {
  "v": 1,
  "alg": "EdDSA",
  "key_version": 1,
  "sender_pubkey": "z6Mk…",       // Multikey multibase on the wire; raw 32 bytes recoverable per the extraction rule below
  "client_msg_id": "…",            // echoed so a verifier can rebuild signingBytes
  "signed_at_ms": 1720000000000,   // the SIGNED time, distinct from server created_at
  "sig": "base64url-unpadded-raw-64"
}
```
**Raw-key extraction rule:** the wire `sender_pubkey` is a Multikey (`0xed01` multicodec prefix ‖ 32 raw bytes, multibase `z…`). A verifier MUST strip the prefix and feed the **raw 32 bytes** into field #2 of `signingBytes` — the signed bytes never contain the multibase string. (This decouples the still-open Multikey-vs-base64url wire-encoding decision from the signature itself.)

**Verifier rules (for whoever builds verification):**
- Allowlist `alg` locally; NEVER trust the envelope's claimed `alg` (JWT alg-confusion class).
- Read `signed_at_ms` from the durable/echoed field, never the server `created_at`.
- Treat an ABSENT `origin` as "unverified," never "invalid" (unsigned history predates the feature).
