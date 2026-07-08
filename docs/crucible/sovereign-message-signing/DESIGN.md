# DESIGN v2 — The sovereign message-signing CONTRACT (Cast, reforged after Temper R1)

> Movement 3 of the /crucible forge, **reforged** after the cross-family Temper (see [TEMPER.md](./TEMPER.md)). v1 tried to *sign every production message now, gateway-opaque, as provable historical origin*. All three adversaries converged: that conflates "sign a message" (app-local) with "provable federated origin" (a system property needing the gateway + a trust root). v2 ships the **hard-to-change contract + key discipline**, verifier-complete and carriage-gated — the narrower candidate Carnot's INVALIDATE explicitly said would survive. Reforged 2026-07-08.

## 1. Problem (unchanged)

Message origin is **asserted by the gateway, not proven by the sender** — `SendFrame` (`envelopes.dart:211`) has "NO sender field by construction (server derives it)." The federation north-star (Design 06/08) must escape this. But — the Temper's correction — the app cannot *unilaterally* deliver provable federated origin, because that requires the gateway to carry the signed material and a trust root to bind the key to an identity. What the app CAN own now is the thing that is genuinely painful to change later: **the exact canonical bytes a signature is computed over, and the device key discipline that produces it.**

## 2. What v2 ships vs defers (the reforged scope)

**SHIP NOW (app-mostly-unilateral, real, not dead bytes):**
- Device Ed25519 keypair: generate, persist, load. A stable device signing identity.
- **`SIGNING-SPEC.md` + golden vectors** — the canonical byte format, complete enough that *any* future verifier (gateway-side or peer-side) reconstructs the exact bytes. This is the catastrophic-to-get-wrong-later artifact, and it is a spec + pure functions, not production wire commitment.
- Sender-side sign + **durable local persist** + **production round-trip self-verify**. Claimed value: *"the app signs its own messages and can verify them locally, and stores a locally-verifiable history"* — explicitly NOT "federated provable origin."

**GATED ON GATEWAY CARRIAGE (the co-requisite contract, peer-owned):**
- Emitting `origin` on the wire + persisting inbound `origin` + echoing the verifier-reconstructable fields. Because a signature the gateway strips is "locally signed, globally mute" (Temper F1/F5), production wire emission is **gated on a one-line gateway confirmation**: the gateway persists and echoes `origin` (incl. `client_msg_id` + `signed_at_ms`) on `MessageView`/REST, and exposes a key-registration surface.

**DEFERRED (federation / #1760), hooks reserved:**
- Recipient verification & enforcement policy; trust-root K→account binding; rotation/revocation lifecycle; cross-device cross-signing; replay-acceptance window/epoch.

## 3. The revised central bet (C1′)

> **Getting the canonical byte contract + device key discipline exactly right now — and gating production emission on gateway carriage — beats improvising them later.**

This survives the deferral steelman *because* it does NOT claim historical-origin value from unbound keys or from bytes no verifier can read. Its value is narrower and real: (a) the byte format is a cross-team interop contract that is expensive to change once anything depends on it, so pin it early with golden vectors; (b) the device key exists and signs, so the moment carriage + trust-root land, verification is a pure forward-add with a growing local history already in the right shape. The Matrix "catastrophic" framing is dropped (Temper F4): aiko's send is locally complete, so the retrofit is drift columns + a sign hook + the spec — the *spec* is the hard part, and that's what we harden now.

## 4. Shape

### 4.1 Modules (new)
- **`lib/services/sovereign_key_store.dart`** — mirrors `secure_token_store.dart`. Ed25519 keygen on first use, 32-byte private seed in `flutter_secure_storage`; exposes `load()` (create-or-load) and the public key as **raw 32 bytes** (Multikey is a wire-encoding concern only — Temper F8). Carries a `keyVersion` int and a reserved `keyState` slot (active/retired) for a future lifecycle (Temper F9).
- **`lib/features/chat/domain/message_signing.dart`** — pure, golden-vector-locked:
  - `Uint8List signingBytes(SignedPayload p)` — the pinned canonical serialization (§4.3).
  - `MessageSignature sign(SovereignKey k, SignedPayload p)` — detached Ed25519 via `cryptography`, **immediately followed by a round-trip `verify` in production** (Temper F6); a self-verify failure throws rather than emitting a wrong-forever signature.
  - `bool verify(rawPubkey, sig, SignedPayload p)` — shipped now and used by the sender self-check; the recipient path that *calls* it is deferred, but the function is not.

### 4.2 Sign at birth, persist, never re-sign (unchanged — the praised spine)
Sign at row-mint in `chat_repository.sendMessage`; persist `sig` + raw `sender_pubkey` + `signed_at_ms` + `key_version` into the drift outbox. Retries retransmit stored bytes. **Hard invariant (Temper F2): verification reads the durable `signed_at_ms` column, NEVER the post-ack `createdAt`** (ack reconciliation overwrites `createdAt` with server time, which would fail every valid signature).

### 4.3 Canonical serialization — verifier-complete (folds F1, F3, F8)
Hand-built, length-prefixed, domain-separated; **alg bound inside the tag**, **raw pubkey signed** (not the multibase string), and every field a verifier needs is inside:
```
DOMAIN_TAG = "aikochat:msg:v1:EdDSA"       # alg bound in-bytes → no downgrade seam (F3)
bytes = len_prefixed(DOMAIN_TAG)
      ‖ len_prefixed(sender_pubkey_RAW_32)  # RAW key, not Multikey string (F8) — key-substitution defense
      ‖ len_prefixed(channel_id)            # else replays into another channel
      ‖ len_prefixed(client_msg_id)         # verifier-reconstructable id (F1)
      ‖ u64_be(signed_at_ms)                 # compose-time, fixed once; verifier reads durable column (F2)
      ‖ len_prefixed(body)
      ‖ len_prefixed(reply_to_or_empty)
```
Golden vectors (known key + payload → known sig + known signingBytes hex) committed and shared via `SIGNING-SPEC.md`. Reserved-but-empty trailing fields for future signed context (channel epoch, content-type — Temper F11) are versioned via `DOMAIN_TAG`'s `v1`, so adding them is a clean `v2`, never a silent change.

### 4.4 The wire envelope — carries what a verifier must reconstruct (folds F1, F5, F7)
```json
"origin": {
  "v": 1,
  "alg": "EdDSA",
  "key_version": 1,
  "sender_pubkey": "z6Mk…",      // Multikey multibase on the wire (raw-key extraction rule in SIGNING-SPEC)
  "client_msg_id": "…",           // ECHOED so a verifier can rebuild signingBytes (F1)
  "signed_at_ms": 1720000000000,  // the SIGNED time, distinct from server created_at (F2)
  "sig": "base64url-raw-64"
}
```
**Gateway contract (co-requisite, peer-owned):** persist `origin` and echo it — including `client_msg_id` + `signed_at_ms` — on `MessageView`/REST, and expose a key-registration surface so a future trust-root can bind the key contemporaneously (Temper: trust-root binding must be *captured at send time* to have historical value). Inbound `origin` is parsed and persisted (nullable) on the recipient device in the same pass (Temper F7) so history is verifiable, not a "sender diary."

### 4.5 The atypical element (unchanged)
Signing is hoisted to message-birth and persisted as durable message state — the signature is part of the message's identity, not a transport detail. v2 adds: the *spec is the deliverable*, the *bytes are gated*.

## 5. Blast-radius & consent spine (cage before monster)
- **Wire size:** +~180 bytes/message (pubkey + sig + echoed id/time). Negligible for text; gated anyway.
- **Gateway carriage is a PREREQUISITE, not a follow-up (Temper F5).** Steps 1/2/4 are unilateral; Step 3 (wire emission + inbound persist) does not ship until the gateway confirms carriage + key-registration. No dead bytes on the wire.
- **Linkability [T1] — NAMED TRADEOFF.** Owner: **product + security**. A stable per-device pubkey on every message is a durable pseudonym; cross-channel today, cross-island once federation exists. Signing keys are *identity*, not session secrets — so NOT "silent like the token store." Mitigation: document in the privacy posture; **no "verified identity/sender" UI until trust-root binding exists [T4]**; consider per-community keys before federation.
- **Key secrecy [T2] — NAMED TRADEOFF.** Owner: security. Software Ed25519 key is extractable under root/jailbreak/in-process; accepted because SE/StrongBox are P-256-only. Revisit if device-compromise enters the threat model; `key_version`/`keyState` hooks make a future hardware or revocation path additive.
- **Consent:** key generated silently like the token store *mechanically*, but its identity nature is documented per T1; no new user permission, no new PII off-device.

## 6. Build order (core-first; the gate is explicit)
1. **`sovereign_key_store` + `SovereignKey`** — keygen, persist/load, raw pubkey, key_version. *Unilateral.* Tests: create-once, load-stable, survives restart.
2. **`message_signing` + `SIGNING-SPEC.md` + golden vectors** — canonical bytes (alg-in-tag, raw pubkey, verifier fields) + `sign`/`verify` + committed known-answer vectors as a **CI gate**. *Unilateral.* The interop contract; the catastrophic-to-get-wrong-later artifact.
3. **⛔ GATE: gateway carriage confirmation.** One-line contract with the peer-owned island/gateway: persist + echo `origin` (incl. `client_msg_id` + `signed_at_ms`) on `MessageView`/REST + a key-registration surface. **Until confirmed, Step 4 does not ship to the wire.**
4. **Sign + persist + production self-verify (local)** — sign at row-mint, persist to drift, round-trip verify on every `sign()`. *Unilateral, no wire change yet* — proves the primitive end-to-end and builds locally-verifiable history. Emitting `origin` on the wire + inbound `origin` persist is the part gated by Step 3.

Steps 1, 2, 4-local are shippable now and independently useful. The wire/inbound half of 4 unlocks the moment Step 3's gate clears.

## 7. Claims to falsify (v2) {#claims}
- **C1′ (central, revised).** Pinning the canonical byte contract + key discipline now, gated on carriage, beats improvising later. *Steelman the null:* could the spec be written just-in-time with federation at zero retrofit cost, making even this premature? (Counter: golden-vector interop contracts are cheap to pin and expensive to change once two teams depend on them.)
- **C2′.** Is Step-4-local (sign + self-verify + persist, no wire) worth shipping before the Step-3 gate clears, or should even keygen wait? (Counter: keygen + spec + local history are the forward-optionality; they're not on the wire, so no dead bytes.)
- **C3′.** Is the `v1` domain-tag versioning enough to keep the reserved-context fields (F11) a clean migration, or does deferring channel-epoch/content-type now bake in a gap?
- **C4 (carried).** Multikey/did:key on the wire vs raw base64url — still open; decoupled from the signed bytes (raw key signed), so a flip no longer invalidates signatures.

## 8. Rejected alternatives (v2)
- **v1's "sign every production body now, gateway-opaque, for historical origin"** — rejected by Temper consensus: verifier-deaf, carriage-blind, unbound-key origin is not provable origin.
- Hardware P-256; JCS/RFC-8785; SimpleX per-connection keys; sign-at-transport — all as v1 (RESEARCH §3/§4/§1, unchanged).
- **Defer the entire feature until federation** — the null (C1′). Rejected because the byte contract + key discipline are the cheap-now/expensive-later parts and carry no dead-bytes cost when the wire half is gated.

## 9. Open variables {#open-variables}
- **OV1/C4** — wire pubkey encoding (Multikey vs raw base64url); decoupled from signed bytes.
- **OV2** — key scope per-device (default) vs per-account (federation's call).
- **OV3** — reserved signed-context fields (epoch, content-type) — versioned via domain tag, added in `v2` when acted upon (F11).
- **OV4** — gateway carriage + key-registration contract: the Step-3 gate. Owner: peer island/gateway.
- **OV5** — Freezed migration pressure from new domain types (note, don't couple).

## 10. Status
Reforged (Temper R1). Every REFORGE finding folded; five items recorded as named tradeoffs / named-open (TEMPER.md ledger). **Re-temper decision pending Nick:** the consensus prescribed exactly this scope, so a re-temper would largely confirm — offered, not assumed. Next: either a confirming re-temper, or Blade (plan mode) on the surviving Steps 1/2/4-local (the unilateral, un-gated core).
