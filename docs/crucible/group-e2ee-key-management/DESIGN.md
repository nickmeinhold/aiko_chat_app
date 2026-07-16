# DESIGN — group-E2EE key management for aiko-chat (v1)

> Movement 3 (Cast) artifact. The mold. Built on `RESEARCH.md`'s verdict: **sender-keys first, device-granular, MLS as endgame migration.** Carries a **claims-to-falsify** section and **rejected alternatives** for the Temper (Movement 4) to strike. Open variables are enumerated, not silently `[TODO]`'d.

## 1. Problem

aiko-chat messages are **signed, not sealed**: `message_signing.dart` proves *who* authored bytes (Ed25519, sign-at-birth), but the island relay/store reads every body. The sovereign-identity thesis — "the island is a replaceable *untrusted* relay" — is a *claim* until messages are confidential to the island. This design specifies the **group** key-management scheme that makes it true, for channel (group) chat, on a topology of frequently-offline phones + an untrusted store-and-wake island + always-on AI members holding keys.

## 2. Scope

**In:** the key-management + sealing scheme for group messages and media; the device-granular membership interface; the fork-detection layer; the FS/PCS tradeoff and its rotation mitigation; the build order.

**Out (named, not forgotten):** the Authentication-Service / identity↔key binding (that's federation #1760 — ghost-member defense lives there, not here); the #27 per-person-vs-per-device *policy* decision (this design is deliberately built to *not need it*); the MLS migration itself (documented as endgame, not built); background-delivery/push-wake (#29, orthogonal, already decoupled).

## 3. The shape

A layered scheme, each layer built from `cryptography 2.9.0` primitives we already hold (X25519, Ed25519, HKDF, XChaCha20-Poly1305, SHA-256). No HPKE, no TreeKEM, no Rust FFI.

```
Layer 5  Membership + fork-detection   (add/remove, sender-key rotation SM, roster-hash consistency beacon)
Layer 4  Media E2EE                     (per-blob random XChaCha20-Poly1305 key; scheme-independent)
Layer 3  Sealed message envelope        (mirror of signingBytes; domain tag aikochat:seal:v1:XChaCha20Poly1305)
Layer 2  Sender-key broadcast           (per-sender chain key + Ed25519 signing key; O(1) per message)
Layer 1  Pairwise secure channel        (X25519 + Double Ratchet; the distribution channel for Layer 2)
Layer 0  Primitives                     (cryptography 2.9.0 — HAVE)
```

### 3.1 The device-granular membership interface (the move that defers #27)

The crypto operates on **devices**, never on "persons." aiko already has a per-device key: `SovereignKey` in `sovereign_key_store.dart`.

```dart
class DeviceKey {            // one per physical device; == today's SovereignKey identity
  Uint8List signingPubKey;   // Ed25519 (identity, already exists)
  Uint8List agreementPubKey; // X25519 (NEW — for pairwise ECDH; see §3.2)
}
class GroupMember {
  String memberId;                 // == deviceId (per-device policy) OR a person handle (per-person policy)
  Set<DeviceKey> devices;          // the crypto fans out to THESE
}
```

Add/remove/encrypt operate on `DeviceKey`. **#27 chooses only how `memberId → devices` is populated** — it does not change the wire protocol or the scheme. This is the interface seam that makes "design group-E2EE now, decide #27 later" honest rather than hand-wavy. (Verified against Signal/WhatsApp/iMessage: all put devices at the crypto layer, person as a mapping.)

### 3.2 The two keys per device

The Ed25519 `SovereignKey` signs (identity/authorship — exists). Group E2EE needs a second per-device key for **key agreement**: an **X25519** agreement key. This mirrors the VLD0 / Signal separation (Ed25519 for signing, X25519 for DH — never a birational conversion; a distinct key). Extends `SovereignKeyStore` to mint + persist an X25519 keypair alongside the Ed25519 seed, under the same single-flight + `keyVersion` discipline already there.

### 3.3 Layer 1 — pairwise secure channel

X25519 handshake (X3DH-style: static + ephemeral + prekeys) → a **Double Ratchet** session between each ordered pair of devices. This is the footgun-dense core (skipped-key cache with a bounded `MAX_SKIP`, DH-ratchet step ordering, per-message-key nonce discipline). Built clean-room; `libsignal_protocol_dart` (GPL-3.0) read only as a correctness *oracle*; every step pinned to **external** known-answer vectors, never a self-roundtrip.

### 3.4 Layer 2 — sender-key broadcast

Each sender device holds a **chain key** (symmetric hash ratchet) + an **Ed25519 sender signing key**. It distributes `{chainKey, senderSigPubKey}` once to every other device over the Layer-1 pairwise channels (a `SenderKeyDistributionMessage`). To send: ratchet chain key → derive message key → seal once (Layer 3) → sign → hand the single ciphertext to the island for fanout. Recipients ratchet to the message's iteration, verify, unseal.

### 3.5 Layer 3 — the sealed envelope (signing's mirror)

A new canonical structure, built exactly like `signingBytes()`: length-prefixed, domain-separated, fail-loud at the crypto boundary. Domain tag **`aikochat:seal:v1:XChaCha20Poly1305`** (distinct from `aikochat:msg:v1:EdDSA` — reusing the signing tag was flagged a bug in the PoP crucible). Sealed messages are **also signed** (authorship survives; sealing adds confidentiality, doesn't replace the signature). AEAD = XChaCha20-Poly1305 (24-byte random nonce → no nonce-reuse worry at the message layer).

### 3.6 Layer 4 — media E2EE (scheme-independent, can land early)

Per-blob **random** XChaCha20-Poly1305 key; encrypt blob client-side; upload ciphertext to the island's object store (once, shared by all members); carry `{contentKey, sha256(ciphertext), pointer}` inside the E2EE message. **Never derive the blob key from the group/chain key** — that would break FS re-fetch of old media and new-member history access. Distinct domain tag `aikochat:blob:v1:XChaCha20Poly1305`.

### 3.7 Layer 5 — membership + the fork-detection consistency layer (the one atypical element)

Stock sender-keys gives no fork-detection; the untrusted island can partition the group (Q3). So the design *adds* a layer sender-keys doesn't have: a **roster-hash consistency beacon**. Each device computes `rosterHash = H(sorted(memberDeviceKeys) ‖ epochCounter)` and periodically publishes a *signed* rosterHash; a divergence between what two devices compute for the same epoch is a *detectable* fork. (This is the honest price of choosing sender-keys over MLS, which would give a transcript hash for free — folded into the design, not deferred.)

**Membership operations:**
- **Add:** existing senders distribute their current sender key to the new device pairwise. New device cannot read history (desired).
- **Remove:** every remaining device generates a fresh sender key + re-distributes (O(N²), amortized "rotate on first send after change"). Removed device's held chain keys are burned by the rotation.
- **Rotation policy:** periodic *mandatory* sender-key rotation independent of membership (mitigates coarse FS / absent-automatic-PCS), with a **shorter mandatory interval for AI members** (the fattest compromise target).

## 4. Build order (core-first; each step independently useful; no big-bang)

| Step | Deliverable | Independently useful? | Guards |
|---|---|---|---|
| **1** | **Sealing primitive** — `sealingBytes()` + seal/unseal for a message body, domain-tagged, **golden-vector pinned**. Extend `SovereignKeyStore` with the X25519 agreement key. | Yes — 1:1 DM bodies can be sealed. | External KATs; fail-loud invariants; self-verify on seal. |
| **2** | **Pairwise Double Ratchet** (Layer 1). | Yes — full 1:1 E2EE with forward secrecy. | `MAX_SKIP` bound; external Signal test vectors; nonce discipline. |
| **3** | **Sender-key broadcast** (Layer 2) for a **static** group (no membership change yet). | Yes — group E2EE for fixed-membership channels. | Iteration/key-ID tracking; skipped-key cache bound. |
| **4** | **Membership operations** — add/remove + rotation state machine (Layer 5 minus fork-detection). | Yes — dynamic groups. | The "rotate on first send" SM (subtle — can leak under a stale key). |
| **5** | **Fork-detection consistency beacon.** | Yes — partitioning island becomes detectable. | Signed rosterHash; out-of-band or beacon compare. |
| **6** | **Media E2EE** (Layer 4). Can be pulled EARLIER (scheme-independent) once Step 1 lands. | Yes — encrypted images/video. | Never derive from group key; SHA-256 verify before decrypt. |
| **7** | **AI-member rotation policy** + the "AI member = interface" seam so on-device inference can flip the FS/PCS calculus later. | Yes — hardens the fattest target. | Named tradeoff owner; mandatory short interval. |

Ship **behind a flag** (`e2ee_enabled`), interop contract (the sealed-envelope byte layout) **pinned by golden vectors before any wire emit** — the same discipline `message_signing.dart` used.

## 5. Blast-radius + consent spine (cage before monster)

- **Owner of the risk:** every aiko-chat user; the failure mode is cryptographic and *silent*.
- **The two catastrophic failure classes:**
  1. **Wrong-forever ciphertext** — a codec/ratchet bug that mints permanently-unreadable history or (worse) a self-consistent-but-wrong scheme that *looks* encrypted and isn't. Mitigation: **external known-answer vectors** on every primitive/codec (never self-roundtrip — [[c0de]]); golden-vector-pin the wire layout before emit; seal-then-self-unseal in production like `sign()` self-verifies.
  2. **False-secure UX** — a "🔒 end-to-end encrypted" badge that over-promises. The AI-member reality means "E2EE" = *island-blind*, NOT *nobody-ever-sees-plaintext*; a cloud AI member reads what you send it by design. Mitigation: badge copy scoped to the truth (same family as the PoP crucible's F4 badge over-promise) — e.g. "Encrypted so the server can't read it. AI members you add can read what you send them." **This is a product/security-owned copy decision, surfaced now, not shipped silently.**
- **Injection surface:** inbound sealed messages + sender-key distribution messages from other devices (attacker-influenceable). Every field a receiver acts on must be *inside* the AEAD/signature; fail-loud on malformed. Mirror `signingBytes()`'s length-prefixed injectivity.
- **Rollout:** flag-gated; sealed + signed in parallel during migration so old clients still verify authorship; no flag-flip to "on by default" until golden vectors + an interop round-trip pass against the real island.

## 6. Claims to falsify (hand these to the adversary)

1. **"#27 doesn't gate this."** The device-granular interface (§3.1) claims to absorb either identity policy. *Strike:* is there an operation (history access on device-add? cross-device sender-key sync?) where per-person vs per-device actually changes the *crypto*, not just the roster policy?
2. **"Sender-keys is adequate given the AI-member floor."** The FS/PCS-is-over-provisioned argument (RESEARCH Q2). *Strike:* name a concrete threat where the *absence of automatic PCS* hurts a group **without** a cloud AI member (human-only groups get full benefit — do they get *enough*?).
3. **"The fork-detection beacon actually detects forks."** *Strike:* can a partitioning island also partition the *beacon* (show each side a consistent-looking rosterHash)? Is out-of-band comparison the only real defense, making the beacon theater?
4. **"Clean-room from primitives is safer than the GPL dep."** *Strike:* is a hand-rolled Double Ratchet (multi-week, footgun-dense) genuinely *safer* than vendoring an audited implementation, or is "avoid GPL" trading a license problem for a correctness problem? Is there an MIT/BSD ratchet we missed?
5. **"MLS-later is a clean migration."** *Strike:* does casting sender-keys now create wire/state that makes the MLS migration *harder* than starting fresh — i.e. are we building a thing we'll have to tear out?
6. **"Media key independent of group key is free."** *Strike:* does storing per-blob keys in messages create an unbounded key-retention problem (every old message holds a live blob key forever — does that undercut FS)?

## 7. Rejected alternatives (what simpler/other shape was passed over, and why)

- **MLS first (RFC 9420).** Rejected for the first cast: no trustworthy Dart impl (Rust-FFI weight vs one-script-island goal), lockstep-Commit-chain hostile to sleeping phones, and it *forces* the #27 decision. Kept as documented endgame migration.
- **Pure pairwise fanout (encrypt-N-times, no sender-keys).** Simpler than sender-keys, strong FS (full Double Ratchet per recipient), no O(N²) removal rotation. Rejected: O(N) *per message* send/upload cost — the exact thing sender-keys exists to avoid — and heavier on the sender's battery/bandwidth. **BUT** worth the adversary's attention: at aiko's *small* group sizes, is pairwise-fanout's simplicity + stronger FS actually the better first cast than sender-keys' O(1)-send? (A real question, not a settled rejection — flagged for Temper.)
- **Adopt Veilid's VLD0 group scheme.** Rejected upstream this session (Veilid decision) — but its crypto suite (Ed25519+X25519+BLAKE3+XChaCha20) is the design precedent we're following.
- **Vendor `libsignal_protocol_dart` directly.** Rejected: GPL-3.0 copyleft on a proprietary app. Oracle-only.

## 8. Open variables (enumerated — resolve in Blade or flag as deferred)

1. **Wire encoding** of the sealed envelope + sender-key distribution message (Multikey vs base64url — same open decision `sovereign_key_store.dart` flags for the pubkey).
2. **Fork-detection concrete shape:** out-of-band roster-hash compare vs island-published signed beacon vs both. (§3.7 proposes the beacon; its sufficiency is claim-to-falsify #3.)
3. **Double Ratchet scope for v1:** full-fat vs a reduced variant (header keys? deferred?) — bounds the multi-week core.
4. **Sender-key state persistence:** extend `flutter_secure_storage` vs the Drift cache; retention/eviction of skipped keys.
5. **`MAX_SKIP`** value + eviction policy.
6. **Rotation intervals:** concrete numbers for mandatory sender-key rotation (human vs AI member).
7. **Pairwise-fanout vs sender-keys for v1** (rejected-alternative #2 reopened for the small-group case) — the Temper should settle this.
