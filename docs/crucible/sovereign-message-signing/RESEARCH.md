# Sovereign Message Signing — Research (HEAT)

**Scope:** ship app-produced per-message signature *bytes* only (`sender_pubkey` + `sig` as gateway-opaque passthrough). Trust-root binding, verification, and cross-device key lifecycle are explicitly OUT of scope for this pass.

> Ground facts (verified, not re-investigated): `SendFrame` today carries only `client_msg_id`, `channel_id`, `body`, `reply_to` and has "NO sender field by construction (server derives it)" (`lib/features/chat/data/transport/envelopes.dart:212`). Only crypto dep is `crypto: ^3.0.7` (SHA-256 for PKCE). App already links `flutter_secure_storage`. Auth = passkeys (WebAuthn, non-exportable, auth-only) + social OAuth. iOS-first.

---

## 1. Prior art — per-message origin signing vs transport auth

**The distinction everyone draws:** "who carried it" (server/TLS/session/federation key) is separate from "who authored it" (a sender identity/signature key). No mature system derives authorship from the carrier alone.

- **Matrix — the cautionary tale.** Events are signed by the *originating homeserver's* key (federation/transport guarantee), NOT the user's device. [server-server signing](https://spec.matrix.org/latest/server-server-api/#signing-events). Per-device human authorship (Ed25519 device keys + a master key) was bolted on **years later as cross-signing**. [cross-signing](https://spec.matrix.org/latest/client-server-api/#cross-signing). In E2EE rooms, authorship rests on the **shared Megolm session key (MAC-based, deliberately deniable)** — so a session-key holder can forge sender-attributed messages. [megolm.md](https://gitlab.matrix.org/matrix-org/olm/-/blob/master/docs/megolm.md). Matrix also had to retrofit a **Canonical JSON** spec because JSON signatures are canonicalization-fragile. [canonical json](https://spec.matrix.org/latest/appendices/#canonical-json).
- **Signal — sealed sender is a metadata-privacy feature, not authorship.** It hides the sender from the *server*; authorship trust comes from the **sender certificate + long-term X3DH identity keys**, and per-message auth is a **symmetric MAC** off the Double Ratchet (deliberately deniable, no per-message signature). [sealed sender](https://signal.org/blog/sealed-sender/) · [double ratchet](https://signal.org/docs/specifications/doubleratchet/) · [X3DH](https://signal.org/docs/specifications/x3dh/).
- **MLS / RFC 9420 — the reference model, and the closest match to this candidate.** Every member holds a **signature key in their LeafNode/Credential**; `FramedContent` (application messages) is **signed by that leaf signature key** *and* MAC'd — a genuine per-message public-key signature, cleanly separated from the confidentiality ratchet, from day one. [RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html) · [framing](https://www.rfc-editor.org/rfc/rfc9420.html#name-message-framing) · [leaf node](https://www.rfc-editor.org/rfc/rfc9420.html#name-leaf-node-contents).
- **Briar — signature *is* the identity, but the canonicalization contract bit them.** Transport (BTP) auth secures the *link*; the *content* is signed at the **client layer** with the author's **Ed25519** key (BSP explicitly punts "what is a valid message" to the client). [briar-spec](https://code.briarproject.org/briar/briar-spec) · [BSP spec](https://code.briarproject.org/briar/briar-spec/-/raw/master/protocols/BSP.md). **The concrete regret:** a 2023 ETH Zürich audit found a **signature-malleability bug** — Briar *deserialized-then-reserialized before verifying*, so an attacker could swap the body for one that reserializes identically and keep the original signature valid (fixed 2023). This is exactly §4's "sign the exact wire bytes, never re-serialize before verifying." [Briar 2023 security fixes](https://briarproject.org/news/2023-three-security-issues-found-and-fixed/) · [ETH thesis](https://ethz.ch/content/dam/ethz/special-interest/infk/inst-infsec/appliedcrypto/education/theses/report_YuanmingSong.pdf).
- **SimpleX — the counter-design.** Deliberately **no global identity**; per-queue/per-connection keys. Authorship is relational ("holder of *this* queue's key"), which maximizes metadata privacy but forfeits global provable origin. [vision](https://simplex.chat/blog/20230422-simplex-chat-vision-funding-v4-2-security-audit-new-website.html) · [simplexmq](https://github.com/simplex-chat/simplexmq).
- **Session/Oxen — account = Ed25519 keypair.** Origin binds to the long-term identity key; Oxen service nodes are pure untrusted transport. [session protocol](https://getsession.org/blog/session-protocol) · [arxiv](https://arxiv.org/abs/2002.04609).

**Common pattern:** (1) always separate the identity/signature key from the ratchet/transport key; (2) the day-one primitive is a per-identity/per-device keypair; (3) *signature-per-message vs MAC-per-message is a deliberate non-repudiation ⇄ deniability choice* — MLS/Briar/Session choose signatures (provable origin), Signal/Megolm choose MACs (deniability). Aiko's "sovereign, provable origin" north-star points squarely at the **signature** camp (MLS/Briar shape).

**Mistakes to avoid:**
- **Deriving origin from the carrier** and retrofitting sender identity later = Matrix's multi-year migration onto a *live federated protocol*. Because Matrix event signing is homeserver-PKI, **a hostile homeserver can impersonate any user on it**. [anarcat critique](https://anarc.at/blog/2022-06-17-matrix-notes/). The live retrofit is **MSC4080 (client-owned cryptographic identities)** — and it's *hard precisely because signing wasn't designed in*: clients can't sign full events without `prev_events` (forward extremities only the server tracks), so MSC4080 must add new endpoints just to give a client enough context to sign. [MSC4080](https://github.com/matrix-org/matrix-spec-proposals/pull/4080). **Design lesson: the author must have everything needed to sign locally.** Build the sender-key passthrough now to hedge exactly this.
- **Under-specifying the signed-byte canonicalization** — Briar's deserialize→reserialize→verify order made valid signatures transferable to a different body (above). Sign the exact wire bytes.
- **Rooting provable authorship in shared/symmetric material** (Megolm) makes "who really sent this" ambiguous/forgeable.
- **Canonicalization-after-the-fact** is painful (Matrix Canonical JSON). Pin the exact signed byte-serialization on day one.
- **Ed25519 is the de-facto identity curve** across Briar/Session/Matrix-devices/MLS-common — choosing it keeps you ecosystem-native.

> Honesty flag: no team publishes a "we regret deferring signing" mea culpa in those words, but the pain is *documented, not just inferred* — Matrix's live MSC4080 retrofit + hostile-homeserver impersonation, and Briar's 2023 signature-malleability fix, are concrete sourced costs.

---

## 2. Dart/Flutter signing libraries for Ed25519

Verified on pub.dev, July 2026.

- **`cryptography`** (dint.dev) — v2.9.0, ~7mo; 310 likes, ~422k weekly dl; all 6 platforms; null-safe; Apache-2.0. Full Ed25519 keygen + detached `sign`/`verify`, **pure-Dart** default, verified publisher, actively maintained. [pub](https://pub.dev/packages/cryptography) · [gh](https://github.com/dint-dev/cryptography).
- **`cryptography_flutter`** — v2.3.4; FFI/native companion. Ed25519 acceleration is **Apple-only**; on Android it falls back to pure-Dart. Add only if profiling shows a hot loop. [pub](https://pub.dev/packages/cryptography_flutter).
- **`sodium`** (skycoder42) — v4.0.2+1, ~2mo; libsodium FFI via Dart native-asset build hooks; `crypto_sign_detached` = Ed25519; actively maintained. Cost: native libsodium in the bundle + build complexity. [pub](https://pub.dev/packages/sodium).
- **`sodium_libs`** — ⚠️ **DEPRECATED** (migrate to `sodium`). Do not adopt. [pub](https://pub.dev/packages/sodium_libs).
- **`pinenacl`** — v0.6.0, **~2yr stale**; pure-Dart TweetNaCl port, full Ed25519, null-safe; correct but unmaintained. Fallback only. [pub](https://pub.dev/packages/pinenacl).
- **`pointycastle`** — v4.0.0; broad primitives but **NO Ed25519** (only (DET-)ECDSA + RSA). Wrong tool. [pub](https://pub.dev/packages/pointycastle).
- **`ed25519_edwards`** — v0.3.1, **~4yr stale + unverified uploader**; works but avoid for a production security dep. [pub](https://pub.dev/packages/ed25519_edwards).
- **`crypto`** (Dart team) — v3.0.7; **hashing only** (SHA-family, HMAC), no signatures. Confirmed: keep for SHA-256, not signing. [pub](https://pub.dev/packages/crypto).

**Pure-Dart vs FFI:** pure-Dart adds ~zero native code (best binary size, no native-lib load); FFI (`sodium`) links libsodium (~hundreds of KB/arch) + build complexity. **Perf (load-bearing):** `cryptography`'s pure-Dart Ed25519 runs **~200 sign/verify per second on the Dart VM (~5 ms/sig)** per the maintainer's docs (~50/s only in *browsers*, irrelevant to native mobile). Signing one short message on a user-initiated send is negligible. [perf note on pub](https://pub.dev/packages/cryptography).

**Ranking:** (1) **`cryptography`** pure-Dart — production default, maintained, no bloat, fast enough; (2) `sodium` if you want libsodium semantics/interop at the cost of a native binary; (3) `pinenacl` fallback; (4/5/6) `ed25519_edwards` / `pointycastle` / `sodium_libs` — avoid.

> Flag: I found no GitHub issue documenting a *mobile* Ed25519 perf regression in `cryptography` — absence-of-evidence, not proof of none.

---

## 3. The Secure Enclave constraint — it's real

**iOS Secure Enclave = NIST P-256 ONLY. No Ed25519.**
- SE supports only 256-bit NIST P-256 EC keys (`kSecAttrKeyTypeECSECPrimeRandom`, 256 bits). [Apple: Protecting keys with the Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave).
- CryptoKit exposes only `SecureEnclave.P256` (`.Signing` = ECDSA, `.KeyAgreement` = ECDH). There is **no** `SecureEnclave.Curve25519`/`.Ed25519`/`.P384`/`.P521` type — the API absence is the proof. [SecureEnclave](https://developer.apple.com/documentation/cryptokit/secureenclave) · [P256.Signing](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/signing).

**Android hardware-backed keys:**
- TEE-backed ECDSA supports P-224/256/384/521. [AOSP keystore features](https://source.android.com/docs/security/features/keystore/features).
- **Curve25519 (Ed25519 / X25519) arrived only in KeyMint v2 / Android 13** — recent and device/HAL-dependent, so not portable. [AOSP hardware-backed keystore](https://source.android.com/docs/security/features/keystore).
- **StrongBox** (strongest, discrete SE) documents a *subset*: RSA-2048, AES, **ECDSA/ECDH P-256**, HMAC-SHA256, 3DES — **no Curve25519**. Unsupported algo with `setIsStrongBoxBacked(true)` throws `StrongBoxUnavailableException`. [Android: Keystore](https://developer.android.com/privacy-and-security/keystore).
- **Portable floor for hardware isolation on both platforms = P-256 ECDSA.**

**The crisp tradeoff:**
- **(a) P-256/ECDSA in SE/StrongBox** — key **never leaves hardware**, unextractable even under root/jailbreak/in-process compromise (strongest key-secrecy on mobile). ECDSA's nonce footgun is *neutralized* because the hardware owns nonce generation; residual risk is a bad hardware RNG. ECDSA sigs are malleable (`(r,s)`/`(r,-s)`) → canonicalize to low-`s` if you dedup on sig bytes. Cost: **different primitive** from the Ed25519/X25519/Noise/libsodium ecosystem → parallel identity or a bridge.
- **(b) Ed25519 in `flutter_secure_storage`** — deterministic (no RNG-nonce footgun at all), non-malleable by construction, ecosystem-native (Signal/Matrix/libsodium/Noise/age/SSH). Cost: **raw 32-byte private key exists in software memory** during signing. `flutter_secure_storage` gives encrypted-at-rest + OS-sandbox isolation (Keychain / Keystore) — another app can't read it — but it **is extractable by a privileged attacker** (root/jailbreak/debugger/in-process). Strictly weaker key-secrecy than (a).

**What comparable apps choose:** the entire Signal-protocol family (**Signal, WhatsApp**) and **Matrix** (vodozemac/olm) use **software Curve25519/Ed25519** identity keys — *because* SE/StrongBox are P-256-only and literally can't hold their curve. Signal uses XEdDSA (Ed25519 sigs over a Curve25519 key). [Curve25519Kit](https://github.com/signalapp/Curve25519Kit).

> Honesty flag: "Signal/Matrix identity keys are in software" is *inferred* from the curve-support fact (their curve can't be SE-backed), not a single vendor sentence. High confidence, but stated as inference.

---

## 4. Canonical serialization for signing

**The trap:** "verifies on my machine, fails on yours" = a canonicalization mismatch — signer hashes one byte sequence, verifier re-serializes the parsed object into a *different* one (key order, whitespace, number formatting, unicode escaping). [RFC 8785 rationale](https://www.rfc-editor.org/rfc/rfc8785).

**Two safe strategies, one unsafe.** Safe: (A) build ONE explicit canonical byte string, sign it, **transmit exactly those bytes** — verifier hashes what it received, no re-serialization; (B) transmit fields and have both sides **deterministically rebuild the identical bytes**. Unsafe: transmit JSON, re-parse, re-serialize with a general encoder, sign the re-serialization.

**Recommended: (A) hand-built, length-prefixed, domain-separated byte string.**
- **Length-prefix every variable field** (fixed-width big-endian). Naive concat is ambiguous: `"ab"||"c"` == `"a"||"bc"`, letting a signature be reinterpreted into another shape. [domain separation](https://en.wikipedia.org/wiki/Domain_separation).
- **Prepend a fixed domain-separation tag** (e.g. `"aikochat:msg:v1"`) so a chat-message signature can't be replayed as a signature for another structure. Exemplar: EIP-191's `0x19` prefix. Make the tag itself fixed-length/delimited and never attacker-controlled.

**JCS (RFC 8785) — has a Dart interop landmine.** Sorts members by UTF-16 code-unit, no whitespace, UTF-8. Pitfalls: numbers serialized as IEEE-754 double via ECMAScript `Number.toString` (hard to get byte-exact); integers must stay within ±2^53−1 or be carried as **strings**; **no Unicode normalization** (precomposed vs combining `é` differ). [RFC 8785](https://www.rfc-editor.org/rfc/rfc8785). **Critical:** no pub.dev package claims RFC 8785 compliance. Google's [`canonical_json`](https://pub.dev/packages/canonical_json) is a *different* scheme (byte-value sort, rejects floats, mandates NFC) → **it will NOT agree with a real JCS verifier.** [reference JCS impls](https://github.com/cyberphone/json-canonicalization). This alone argues against JCS for a Dart client talking to a peer-owned gateway.

**CBOR (deterministic, RFC 8949 §4.2)** — preferred/shortest form, definite-length only, bytewise-sorted map keys. Better-behaved than JSON, but floats remain a hazard and two coexisting map-ordering rules (§4.2.3 legacy) can disagree unless both ends pin one. [RFC 8949 §4.2](https://www.rfc-editor.org/rfc/rfc8949#section-4.2). Use if you need a *standard* structured format; still weaker than the hand-built string for a small fixed schema.

**Fields that MUST be inside the signed payload:**
- `body` — the content (the point).
- `channel_id` — else a valid sig **replays into another channel**.
- `client_msg_id` — binds a stable per-message id (dedup the sig actually covers; blocks re-injection).
- `timestamp` and/or `nonce` — **replay defense** (timestamp = coarse freshness; server-issued single-use nonce = exact-once; include both if you can — repo already has server-issued nonce infra).
- `alg`/version tag — binds the scheme so an attacker can't **downgrade** interpretation across versions.
- **`sender_pubkey` — YES, include it.** Defends **key-substitution attacks** (an adversary crafting a different key that verifies the same sig to claim authorship). Signing the pubkey makes the sig assert "*this specific key* signed this." [IACR 2019/779](https://eprint.iacr.org/2019/779.pdf) · [key-substitution revisited](https://link.springer.com/article/10.1007/s10207-005-0071-2).

**Ed25519 malleability:** signing is **deterministic** (nonce = hash of key+message, no RNG). [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032). Standard Ed25519 is **non-malleable** via the verification check that decoded `S` is in `[0, L)` — a canonical in-range sig has no second valid form. RFC 8032 states this directly. The remaining nuance is cofactor / non-canonical-encoding *acceptance-set disagreement* between libraries (a consensus-system concern), **not** the ECDSA `(r,s)/(r,-s)` flip. Practically: mainstream libs enforce the `S`-range → non-malleable enough for chat; no need to hash-wrap the sig.

> Flag: "libsodium enforces canonical S / rejects non-canonical R" is well-established but was not re-verified against libsodium source this pass.

---

## 5. The "sign now, verify later" forward-compat envelope

**Algorithm agility:** carry an explicit **algo id** (reuse JOSE values — Ed25519 = `"EdDSA"` per [RFC 8037](https://www.rfc-editor.org/rfc/rfc8037); `alg` model from [RFC 7515 §4.1.1](https://www.rfc-editor.org/rfc/rfc7515#section-4.1.1)). **The verifier MUST pin/allowlist algorithms and never trust the envelope's claimed alg** — the classic **alg-confusion** bypass (RS256→HS256) is exactly this. [RFC 7515 §10.6](https://www.rfc-editor.org/rfc/rfc7515#section-10.6) · [PortSwigger](https://portswigger.net/web-security/jwt/algorithm-confusion). So the algo id is a *migration lever + audit signal*, not an instruction the verifier obeys.

**Public-key encoding — recommend Multikey / did:key-compatible.** Options: raw base64url (smallest, zero self-description); JWK (`{"kty":"OKP","crv":"Ed25519","x":…}` — self-describing but verbose, [RFC 8037 §2](https://www.rfc-editor.org/rfc/rfc8037#section-2)); **Multikey** = multicodec varint prefix + multibase. `ed25519-pub` multicodec code `0xed` serializes to bytes `0xed 0x01` (hence specs write `0xed01`); base58-btc multibase prefix `z`. [multicodec table](https://github.com/multiformats/multicodec/blob/master/table.csv) · [Multikey](https://www.w3.org/TR/controller-document/#Multikey). **did:key** wraps that into a resolvable self-certifying id (`did:key:z6Mk…`). [did:key spec](https://w3c-ccg.github.io/did-key-spec/). Multikey is the only option that is simultaneously compact, **algorithm-self-describing**, and a **natural trust-root binding for federation** — the same bytes lift straight into a `did:key` verificationMethod later.

**Signature encoding:** ed25519 → **raw 64-byte sig (R‖S), base64url-unpadded**. No DER (DER is an ECDSA concern only). [RFC 8032 §5.1.6](https://www.rfc-editor.org/rfc/rfc8032#section-5.1.6) · [RFC 8037 §3.1](https://www.rfc-editor.org/rfc/rfc8037#section-3.1) · base64url-unpadded is the JOSE default [RFC 7515 §2](https://www.rfc-editor.org/rfc/rfc7515#section-2) / [RFC 4648 §5](https://www.rfc-editor.org/rfc/rfc4648#section-5).

**The mature model to steal — W3C Data Integrity / VC.** A `proof` object splits **what secured it** (`cryptosuite`, e.g. `eddsa-jcs-2022` / `eddsa-rdfc-2022`) from **which key** (`verificationMethod`, a Multikey) from **the bytes** (`proofValue`, multibase). Three orthogonal fields = migrate algorithm, rotate key, or change encoding independently. [VC Data Integrity](https://www.w3.org/TR/vc-data-integrity/) · [VC-DI-EdDSA](https://www.w3.org/TR/vc-di-eddsa/).

**Minimal-but-future-proof envelope (ship now):**
- `v` — envelope version (int) — lets the field set / canonicalization change unambiguously later.
- `alg` — `"EdDSA"` today — migration lever; verifier keeps its own allowlist.
- `sender_pubkey` — **Multikey multibase** (`z…`, `0xed01`+32 bytes) — self-describes key type, compact, lifts into `did:key` for federation.
- `sig` — raw 64-byte ed25519, base64url-unpadded — no DER.
- **A pinned canonicalization** (from §4) — the ONE thing that cannot be deferred; "verify later" silently breaks without it.

> Flag: multicodec `ed25519-pub` is formally "draft" (long-stable in practice); current normative cryptosuite names are `eddsa-rdfc-2022`/`eddsa-jcs-2022` (older label `eddsa-2022` is legacy). Specific 2026 JWT-confusion CVE numbers not independently re-verified; the mechanism + allowlist mitigation are RFC-grounded.

---

## 6. Failure modes & the honest hard-parts

| Failure mode | In-scope now? | Note |
|---|---|---|
| **Key loss (phone lost, no recovery)** | Deferred | A new device = a new key = a new sovereign identity until federation binds them. Acceptable: this pass ships bytes only. Leave the Multikey hook so trust-root binding can adopt recovery later. |
| **Multi-device key divergence** | Deferred | Each device signs with its own key; without cross-signing (Matrix's exact retrofit pain, §1) a user reads as N identities. The envelope's `sender_pubkey` per-message is forward-compatible with a future cross-signing/credential layer. |
| **Replay** | Partially in-scope | App already has `clientMsgId` + server-issued nonce infra (auth). Bind `client_msg_id` + `timestamp` (+ nonce if cheap) *inside* the signed bytes (§4) so replay defense is authenticated, not bolt-on. |
| **Unsigned-history migration** | Deferred | Pre-feature messages have no sig; verifiers must treat "absent sig" as "unverified," never "invalid." The `v`/`alg` envelope makes "unsigned" a distinguishable state. |
| **Signing perf on every send** | Non-issue | ~5 ms/sig pure-Dart (§2); one signature per user-initiated send is negligible. Not per-keystroke — per-send. |
| **Trust-root gap (sig proves key-holder, not human)** | Explicitly deferred (federation's job) | A signature proves "the holder of key K signed this," NOT "person P authored this." Binding K→identity is the federation north-star, out of scope here. This is a *feature*: origin becomes provable-by-key instead of asserted-by-JWT, and the binding layer is where trust roots plug in later. |
| **Malleability / dedup on sig bytes** | Handled by choice | Ed25519's `S`-range check makes it non-malleable (§4) — safe to skip if using Ed25519; would need low-`s` canonicalization only under the P-256/ECDSA path (§3). |

---

## Recommendation seeds for Cast

1. **Library: `cryptography` (pure-Dart) for Ed25519.** *Why:* maintained, verified publisher, first-class detached sign/verify, no binary bloat, ~5 ms/sig (far faster than needed). *Risk:* pure-Dart (not FFI-hardened) — mitigate by pinning the version and adding `cryptography_flutter` only if profiling ever demands it. **Confidence: solid.**
2. **Key type + storage: Ed25519 with the private key in `flutter_secure_storage` (software), NOT hardware P-256.** *Why:* SE/StrongBox are P-256-only (§3) and can't hold Ed25519; every comparable messenger (Signal/WhatsApp/Matrix) makes the same software-Ed25519 choice for ecosystem fit + deterministic non-malleable sigs; and the north-star is Ed25519/did:key federation. *Risk:* raw key extractable by a *privileged* (root/jailbreak/in-process) attacker — a strictly weaker key-secrecy guarantee than hardware isolation; name it as an accepted tradeoff, revisit if the threat model adds device-compromise. **Confidence: solid** (constraint verified; the choice is a named tradeoff).
3. **Serialization: hand-built, length-prefixed, domain-separated (`"aikochat:msg:v1"`) byte string; sign it and transmit those exact bytes.** *Why:* sidesteps every canonicalizer pitfall AND the Dart JCS interop gap (no RFC-8785 lib in Dart — §4). *Risk:* it's a bespoke format the peer gateway must reproduce byte-for-byte — pin it in a shared spec doc from day one. **Confidence: solid.**
4. **Signed fields: `body, channel_id, client_msg_id, timestamp, nonce, alg/version, sender_pubkey`** (pubkey included to block key-substitution). *Why:* everything a receiver acts on must be authenticated; `channel_id`/`timestamp`/`nonce` close replay/context-confusion. *Risk:* forgetting one field silently unauthenticates it — enumerate in the spec. **Confidence: solid.**
5. **Wire envelope: `{v, alg:"EdDSA", sender_pubkey: <Multikey multibase>, sig: <base64url raw64>}` as gateway-opaque passthrough.** *Why:* Multikey/did:key-compatible pubkey makes a future gateway/peer verifier + federation trust-root adoption a no-app-change upgrade. *Risk:* multicodec `ed25519-pub` is formally "draft" (stable in practice) and did:key adds ~encoding complexity vs raw base64url — acceptable for the forward-compat payoff. **Confidence: plausible** (the *shape* is solid; the did:key-vs-raw-base64url call is a judgment worth Temper's scrutiny).

---

## Claims I could NOT verify

- **"Teams regretted deferring signing"** — no first-party mea-culpa *quote* exists, but the cost is documented (Matrix MSC4080 retrofit + hostile-homeserver impersonation; Briar's 2023 signature-malleability fix). The word "regret" is a fair summary of sourced pain, not a cited quote (§1).
- **"Signal/Matrix/WhatsApp identity keys are in software"** — inferred from the SE/StrongBox curve-support facts (their Curve25519 keys literally cannot be hardware-backed), not a single vendor sentence. High confidence, but inference (§3).
- **Any shipping StrongBox that supports Ed25519 beyond the AOSP-documented baseline** — vendor-specific; the AOSP list is the documented floor, not a proven universal ceiling (§3).
- **libsodium's exact canonical-`S` / non-canonical-`R` rejection** — well-established but not re-verified against libsodium source this pass (§4).
- **No documented mobile Ed25519 perf regression in `cryptography`** — absence-of-evidence from an issue search, not proof none exists (§2).
- **Specific 2026 JWT alg-confusion CVE numbers** — the mechanism + allowlist mitigation are RFC-7515-grounded; individual CVE ids not independently re-verified (§5).
