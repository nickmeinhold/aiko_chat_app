# 🜂 HEAT — Proof-of-Possession Identity Binding · RESEARCH

## TL;DR (Q1 verdict first)

1. **This is a genuinely SPLIT forge, tilted ~55% gateway / ~45% app — but it is CORRECTLY homed in the app repo** because the app owns the primitive that already exists (the sovereign key + `signingBytes` domain-separation discipline) and the *decisions* this crucible must make are protocol-shape decisions, not Python plumbing. It is **not** mis-homed slag. The falsifier ("~entirely gateway-side") is **FALSE**.
2. The single biggest finding: **"peer PR B" is already built.** The gateway has a `signing_keys` table, `POST/GET/DELETE /v1/keys`, and an implicit send-time upsert (`signing_keys_service.record_signing_key`). What's built is the *observation roster*. What is **missing on BOTH sides** is the one thing this forge is actually about: a **proof-of-possession challenge** (the client signs a fresh gateway-issued nonce with the sovereign key). The gateway's own `SigningKey` docstring names this exact gap and says the stance "flips ONLY once key REGISTRATION gains proof-of-possession."
3. The closest prior art (Nostr NIP-42) is a near-exact template: relay sends `["AUTH", challenge]`, client signs an event binding **relay-URL + challenge + timestamp**, replay is stopped by single-use challenge + `created_at` freshness. SSB's Secret Handshake requires the client to **already know the server's pubkey** — which is the crack in the "islands are interchangeable" premise (see Q3).
4. **Key material: recommend SEPARATE X25519 key, do NOT convert.** Decisive engineering reason (not just best-practice hand-waving): *neither* stack ships the Ed25519→X25519 birational conversion. Dart `cryptography` 2.9.0 has `Ed25519` and `X25519` as independent generators with no `pk_to_curve25519`; the Python island has no PyNaCl/libsodium at all. Converting means hand-rolling field arithmetic on both sides — the exact "don't hand-roll the security boundary" line the codebase already refuses to cross.
5. Two open decisions Cast must make: **(a)** does the PoP challenge bind to a *stable gateway identity* the app pins (needed for cross-relay replay defense + the islands story), or only to a self-declared URL (Nostr's weaker model)? **(b)** does PoP-login *replace* the JWT-issuing passkey flow, or *augment* it (register the key under an already-authed session)? These are protocol-shape calls, which is precisely why the forge belongs in the app repo.

---

## Q1 — The app/gateway split (the falsifier)

### What exists today, verified in the code

**The app already holds a sovereign Ed25519 key and signs with domain separation.**
- `lib/services/sovereign_key_store.dart:80-101` — mints + persists a 32-byte Ed25519 seed in `FlutterSecureStorage`, derives the keypair, exposes `rawPublicKey` + `keyVersion`. Software key by necessity (`sovereign_key_store.dart:13-19`: Secure Enclave/StrongBox are P-256-only).
- `lib/features/chat/domain/message_signing.dart:69-103` — `signingBytes` is a hand-built, length-prefixed, domain-separated byte layout with tag `aikochat:msg:v1:EdDSA` (`message_signing.dart:27`). The pubkey is bound *into* the signed bytes (`message_signing.dart:95`) as key-substitution defense.
- `lib/features/chat/domain/origin_envelope.dart:242-304` — `validateOrigin` is a byte-for-byte mirror of the gateway's `validate_origin`, pinned to a golden vector.

**The gateway already has the pubkey→account roster — "peer PR B" is NOT deferred, it is SHIPPED.**
- `src/aiko_gateway/domain/models.py:433` — `class SigningKey(Base)` with `UNIQUE(user_id, pubkey)`.
- `src/aiko_gateway/domain/signing_keys_service.py:33` — `record_signing_key`, the single idempotent upsert door.
- `src/aiko_gateway/rest/keys.py:67-125` — `POST /v1/keys` (bind under the authed user), `GET /v1/keys`, `DELETE /v1/keys/{pubkey}`, with an atomic per-user cap. Route docstring (`keys.py:12`): *"The app does not call these yet. They are shipped fully hardened + tested anyway."*
- Implicit binding: `src/aiko_gateway/realtime/ws.py:155-159` + `create_outbound` folds `record_signing_key` into the message insert, so a signed send observes the key atomically.

**What is MISSING on both sides — the actual ore of this forge:**
- There is **no challenge-response over the sovereign key** anywhere. `grep` for a sovereign PoP endpoint returns only *message*-signing and *passkey* (WebAuthn) hits. The only challenge/nonce infra is for passkeys (`passkey_service.py`) and social nonces (`nonce_service.py`) — neither touches the Ed25519 sovereign key.
- The current binding of pubkey→account is **assertion, not possession.** The gateway *knows* "the account that held a valid JWT presented this key" — never "the holder of this key proved the private half." The `SigningKey` docstring says this in plain words (`models.py:444-472`): per-user (not global) uniqueness is the *only honest model* precisely because there is no PoP; *"Global uniqueness becomes correct — and this stance flips — ONLY once key REGISTRATION gains proof-of-possession (a challenge the caller signs with the private key)."* (`models.py:468-470`).
- Today auth is JWT: passkey ceremony → `_tokens(user.id)` (`rest/auth.py:61-63`), and the WS connects with `?token=<access jwt>` (`ws.py:30-35`, `gateway_transport.dart:173`). The gateway is the **namer**.

### The split, concretely

| Layer | App (Dart) work | Gateway (Python) work |
|---|---|---|
| Challenge issue | call `POST /v1/keys/challenge` | **new endpoint**: mint single-use TTL'd nonce (clone `nonce_service`/`passkey_service` challenge store) |
| Sign challenge | **new**: `signChallenge()` — a *login* `signingBytes` variant with a NEW domain tag (`aikochat:pop:v1:EdDSA`) binding verifier-id + nonce + ts | — |
| Verify + bind | send `{pubkey, sig, nonce}` | **new endpoint**: verify Ed25519 sig over the reconstructed bytes, consume nonce atomically, upsert via existing `record_signing_key`, flip the binding to **PoP-proven** (enables global-unique stance) |
| Session outcome | route into existing `_applyOutcome` | reuse `_tokens` OR issue a pubkey-scoped session |

Roster persistence, the multikey codec, the atomic single-use nonce pattern, the per-user→global-unique migration path — **all already exist gateway-side**. The genuinely new Python is one challenge endpoint + one verify endpoint (~a service module + two routes), reusing `signing.decode_multikey`, `nonce_service`'s atomic-consume pattern, and `record_signing_key`. The genuinely new Dart is `signChallenge()` (a second `signingBytes` layout) + the two REST calls + wiring it into the auth controller.

**Why it is correctly app-homed despite the LOC tilting gateway-side:** the load-bearing artifact is the *signing discipline* (`signingBytes`, the domain tag, key-substitution defense) which lives in the app and which the gateway only *mirrors*. The forge's decisions (new domain tag, what goes in the challenge bytes, replace-vs-augment JWT, one-key-vs-two) are **app-authored protocol shape** the gateway conforms to — same relationship as the message-signing crucible, which was also correctly app-homed with a gateway carrier mirror. This is that crucible's twin: message-signing proved *authorship of content*; this proves *authorship of identity*.

**Verdict: genuinely split (~55/45 gateway/app by LOC), correctly homed in the app repo by design authority. Falsifier defeated.**

---

## Q2 — How prior art does relay/broker challenge-response

### Nostr NIP-42 — the near-exact template

Flow ([NIP-42 spec](https://github.com/nostr-protocol/nips/blob/master/42.md)):
1. Relay sends `["AUTH", <challenge-string>]`.
2. Client publishes a `kind: 22242` ephemeral event with **≥2 tags**: `["relay", "wss://relay.example.com/"]` and `["challenge", "<challenge>"]`, signed by the client's identity key.
3. Relay verifies: signature valid, `created_at` within ~10 min of now, `challenge` tag == the challenge it issued, `relay` tag == its own URL.

Replay defense = **single-use challenge + `created_at` freshness + relay-URL binding inside the signed event.** Pubkey→connection binding: the authenticated pubkey is valid for the *duration of that connection* (the spec is thin on the mechanism — it's connection-scoped state, not a token).

**Directly transferable:** the aiko sovereign key IS a Nostr-style identity key; `signingBytes` IS the canonical-event-serialization discipline. The port is: challenge string ⇒ gateway nonce; `relay` tag ⇒ verifier identity binding; `created_at` ⇒ `signed_at_ms`; `kind:22242` domain ⇒ a new `aikochat:pop:v1` domain tag.

### SSB Secret Handshake (SHS) — the cautionary contrast

SHS ([Tarr, *Designing a Secret Handshake*](https://dominictarr.github.io/secret-handshake-paper/shs.pdf)) is a **4-pass mutual** auth over Ed25519 that proves *both* peers hold their private keys and derives a shared session key, keeping long-term keys secret from unauthenticated actors. Crucially: **the client must ALREADY KNOW the server's public key to connect** — the server pubkey is an access *capability*.

**The pitfall it warns about, load-bearing for this forge:** mutual auth needs a *known server identity*. Nostr binds to a self-declared *URL* (weaker — a MITM/impostor relay declares any URL). SSB binds to a *pubkey the client pre-knows* (stronger — but requires out-of-band key distribution). This is exactly the CRUCIBLE secondary falsifier ("if replay/domain-separation needs the gateway advertising a stable identity the app can pin, the interchangeable-islands premise cracks"). See Q3.

### MQTT 5.0 Enhanced Auth — the #24 reuse target, with a real constraint

MQTT 5.0 adds the `AUTH` packet + `Authentication Method`/`Authentication Data` properties for SASL-style challenge-response (SCRAM, Kerberos) ([HiveMQ](https://www.hivemq.com/blog/mqtt5-essentials-part11-enhanced-authentication/), [EMQX](https://www.emqx.com/en/blog/mqtt-5-0-control-packets-06-auth)). The client picks a method string (e.g. `SCRAM-SHA-256`) in CONNECT; server and client exchange `AUTH` packets until CONNACK.

**The constraint that matters for "islands":** broker support is asymmetric. **EMQX and HiveMQ** fully support SCRAM/custom challenge-response ([EMQX SCRAM docs](https://docs.emqx.com/en/emqx/latest/access-control/authn/scram.html)). **Mosquitto** recognizes the AUTH packet structure but ships **few built-in methods** — a custom Ed25519-PoP SASL mechanism on mosquitto means a **plugin**, not config. Memory `project_gateway_runtime_topology` says the gateway currently *borrows the matrix-aiko-bridge's mosquitto*. So the #24 "dumb MQTT island authenticates with the same handshake" story is real on EMQX/HiveMQ but requires a plugin on mosquitto. **(Unverified: whether a mosquitto Ed25519-SASL plugin exists off-the-shelf — flag for #24, not this forge.)**

### The common pattern (extract) + shared pitfalls

**Common pattern:** (1) verifier issues a fresh unpredictable challenge; (2) client signs a *canonical structure* binding {challenge, verifier-identity, freshness} — never the bare challenge; (3) verifier checks sig + freshness + its-own-identity + single-use; (4) auth is connection/session-scoped, not a replayable token.

**Pitfalls every spec warns about:** signing a bare challenge with no domain/verifier binding (cross-protocol + cross-relay replay); no freshness window (captured-challenge replay); self-declared verifier URL vs. pre-known verifier pubkey (impostor relay); reusing the *message*-signing structure for *login* (a login sig that is also a valid message sig — the domain-tag must differ).

---

## Q3 — Replay + domain separation for a login challenge

### What the message signing binds today

`signingBytes` (`message_signing.dart:69-103`) signs, length-prefixed, in order: domain tag `aikochat:msg:v1:EdDSA` · rawPublicKey · channelId · clientMsgId · signedAtMs (u64) · body · replyTo. The domain tag (`message_signing.dart:22-27`) exists so *"a signature can't be replayed against another structure and an attacker can't downgrade the interpretation by swapping a wire `alg` field."* The pubkey-in-bytes is key-substitution defense.

**Critical observation:** this structure has NO verifier/relay identity and NO server-issued nonce. It binds to *content* (channel/body), not to *who is asking* or *when they asked*. A login challenge needs the opposite bindings. **Reusing `signingBytes` for login would be a bug** — a login signature could be a valid message signature or vice-versa. The login challenge MUST get its own domain tag (e.g. `aikochat:pop:v1:EdDSA`), which is exactly the discipline `message_signing.dart:22-27` already established.

### What a login challenge's signed bytes must contain (best practice, synthesized from Q2)

| Field | Why | Prior art |
|---|---|---|
| **domain tag** `aikochat:pop:v1:EdDSA` | separate the login structure from the message structure (no cross-use) | app's own `kSigningDomainTag` discipline |
| **rawPublicKey** | key-substitution defense; it IS the asserted identity | `signingBytes` field #2 |
| **verifier identity** (gateway id) | **cross-relay replay defense** — a sig to gateway A must not verify at gateway B | NIP-42 `relay` tag; SSB known-server-pubkey |
| **server-issued nonce** | freshness + single-use; the anti-replay core | NIP-42 `challenge`; passkey/social nonce stores |
| **signed_at_ms + gateway-enforced expiry** | bound freshness even if nonce store is lax | NIP-42 `created_at` ~10min |

Verifier binds pubkey→session **for the connection's duration** (NIP-42), then upserts the PoP-proven roster row via the existing `record_signing_key`.

### The risk the CRUCIBLE flagged — and it is REAL

*"Note the risk if the gateway has no stable advertised identity for the app to bind to."* Confirmed real:
- **Nostr's answer (weak):** bind to the *relay URL*. An impostor relay at a different URL simply issues its own challenge; the URL binding only stops a captured sig from *another* relay being replayed *here*, not an impostor *being* here.
- **SSB's answer (strong, but heavier):** the client pre-knows the server's Ed25519 pubkey out-of-band; the handshake proves the server holds it. This is what makes islands *not* interchangeable-as-anonymous — you pin the island's key.
- **Today's gateway has NO advertised stable cryptographic identity.** `.well-known` serves only WebAuthn association files (`rest/well_known.py`); `islands.py:27-36` lists islands/gateways but (unverified whether it exposes a per-gateway pubkey — the `list_gateways` body wasn't read in full). **This is the load-bearing open decision** (Q1 open-decision (a)): if Cast picks URL-binding (Nostr), the islands-interchangeable premise holds but impostor-island defense is weak; if it picks pubkey-pinning (SSB), islands each need an advertised sovereign key and a discovery/pinning story — heavier, but it's the actual federation trust root.

---

## Q4 — Key material: one Ed25519 vs Ed25519 + X25519

### The engineering fact that decides it (not just best-practice)

- **Dart:** `cryptography` 2.9.0 (`pubspec.lock:236`, `pubspec.yaml:61`) exposes `Ed25519` and `X25519` as **independent** classes (`.../cryptography-2.9.0/lib/src/cryptography/algorithms.dart`). There is **NO** `ed25519_pk_to_curve25519` / birational-conversion helper — `X25519` has its own keypair generator.
- **Python island:** deps are `cryptography>=46` (pyca) only — **no PyNaCl, no libsodium** (`grep` of `pyproject.toml`/`src` for nacl/libsodium/x25519 = empty). pyca `cryptography` has native `X25519PrivateKey` but, like the Dart lib, **no Ed↔Curve conversion**.

So converting a single Ed25519 seed into an X25519 key would require **hand-rolling the birational map** (twisted-Edwards→Montgomery field arithmetic) on *both* sides and pinning them to a cross-language golden vector — the precise "we do NOT hand-roll the security boundary" line the codebase already refuses to cross (`passkey_service.py:31-33`, `origin_envelope.dart` mirror discipline).

### The security consensus (corroborating, not the deciding factor)

Reusing one keypair for both sign + DH is *provably* safe under specific constructions ([IACR 2021/509](https://eprint.iacr.org/2021/509)), and libsodium *supports* it via `crypto_sign_ed25519_pk_to_curve25519` ([libsodium docs](https://libsodium.gitbook.io/doc/advanced/ed25519-curve25519)) — **but** the standing recommendation is **distinct keys**, because signing keys are long-term while DH keys should skew ephemeral ([Filippo Valsorda, *Using Ed25519 keys for encryption*](https://words.filippo.io/using-ed25519-keys-for-encryption/)). What the real systems do:
- **Signal:** separate identity (Ed25519-ish) + a *ratchet* of ephemeral X25519 keys (X3DH/Double Ratchet). **age:** native X25519 recipients, separate from any signing. **Matrix/Olm:** separate Ed25519 (signing/fingerprint) + Curve25519 (Olm DH) identity keys per device. Nobody's production E2EE reuses the signing key as the *sole* DH key.

### The domain-matched precedent: Veilid VLD0 (VeilidChat is a Flutter sovereign E2EE chat)

The strongest single reference, because it is *our exact use case* — [Veilid's VLD0 crypto suite](https://veilid.com/how-it-works/cryptography/) powers VeilidChat, a Flutter, sovereign-identity, E2EE messenger — and it chooses **distinct primitives per operation**, verified on that page:
- *"Authentication is Ed25519"* (identity + signing) **and, separately,** *"Key Exchange is x25519"* (DH / symmetric-key agreement) — two named primitives, not one converted key.
- *"Message Digest is BLAKE3"* (hash/KDF/PRF), *"Encryption is XChaCha20-Poly1305"* (24-byte-nonce AEAD), *"Key Derivation is Argon2"* (password hashing).

So a serious crypto team (cDc/DilDog), building the *same* Flutter-sovereign-chat shape aiko targets, lands on **Ed25519 identity + a separate X25519 key-agreement key** — a domain-matched precedent for the recommendation, not a generic one. **Honesty note (verified against the page):** the Veilid *page* names the primitive set but does **not** on that page spell out the two finer claims made in passing — that the X25519 key is a *distinct key* rather than a birational conversion of the Ed25519 one, and that a BLAKE3 round is applied to the raw DH output for extra signing/crypt domain separation. Those are consistent with VLD0's design and with the separate-key recommendation, but are **unverified from this source** (they'd need the veilid-core implementation, not the overview page). The primitive *set* (separate Ed25519 + X25519 + BLAKE3 + XChaCha20-Poly1305 + Argon2) IS confirmed and is what the citation rests on — it does not contradict the recommendation; it corroborates it.

### Recommendation

**Separate X25519 key, generated + stored alongside the Ed25519 sovereign key.** Decisive reason: neither stack ships the conversion, so "single key with conversion" means hand-rolled crypto on the security boundary — disqualifying. Corroborating reason: separate is the industry-standard posture and keeps the door open to ephemeral/ratcheting DH later. **Scope guard:** this decides only *key-material readiness* (mint + persist a second X25519 seed in `SovereignKeyStore`, reserve a wire slot) — it does NOT commit to X3DH/MLS/any scheme (#25). The `keyVersion` slot (`sovereign_key_store.dart:31-33`) already models additive migration; add an X25519 public key as an additive, unused-for-now field.

**Tradeoff stated:** two keys = two things to back up/rotate/lose and a slightly larger identity blob. Accepted because the alternative is hand-rolled birational conversion, which is strictly worse.

---

## Q5 — Known failure modes / what others hit

| Failure mode | Bites aiko because | How Nostr/SSB/others handle it |
|---|---|---|
| **Sybil via fresh key (reputation whitewashing)** | A new Ed25519 keypair is free and instantly a "new user" — sheds all bad reputation. Memory `project_identity_personhood_vs_reputation`: aiko *defends on reputation, not personhood*, so cheap fresh keys directly attack the model. | Nostr: doesn't solve it — relies on relay-side allowlists / web-of-trust / paid relays. SSB: pub-invite gating + follow-graph (a key nobody follows is invisible). aiko's own answer: newcomers start *below neutral* + vouching (per that memory). |
| **No-recovery == block-evasion** (CRUCIBLE hazard 2) | Sovereign key is device-local, NOT synced (unlike passkeys) — lose the device, lose the identity; and a blocked user just mints a new key. Same coin. | Nostr: nsec backup is the user's problem; block-evasion is unsolved (mute lists are per-client). SSB: identity loss = new identity, accepted. **No prior art "solves" this** — it's inherent to sovereign keys; aiko must name it as a named tradeoff, not pretend to close it. |
| **Global correlation of a static pubkey** (CRUCIBLE hazard 3) | The pubkey rides in every echoed `origin` (`signing.py:18-23`) and would ride in every PoP login — a permanent, unrotatable cross-gateway correlation handle. | Nostr: same problem, largely accepted (your npub is your identity everywhere). SSB: long-term keys kept secret from *unauthenticated* actors by SHS — but authenticated peers still correlate. Mitigation exists only via rotation/per-context keys — deferred to #1760. |
| **Human-naming floats free (Zooko's triangle)** | A pubkey is not a name; `aiko_username`/`display_name` (`auth_models.dart`) are gateway-assigned, not key-bound. A petname layer is explicitly out of scope (CRUCIBLE). | Nostr: NIP-05 (DNS-based `name@domain` → pubkey) — a *petname/verification* layer bolted on top, exactly the deferred dependency. SSB: petnames per-user. Confirms Cast should NOT design naming here, only *not preclude* a NIP-05-style layer. |
| **Android Keystore wiped on uninstall vs iOS Keychain survives** (CRUCIBLE hazard 5) | Asymmetric free rotation: an Android user uninstalls → fresh key → fresh reputation, cheaper than on iOS. | No cross-platform prior art normalizes this; it's an aiko-specific consequence of `FlutterSecureStorage` platform semantics (`sovereign_key_store.dart:16-18`). Name it; a synced-backup story is the only fix and it reopens the multi-device question (#21). |

---

## Slag vs metal

### KEEP (the metal)
- **The Nostr NIP-42 challenge shape**, ported to `signingBytes` discipline: fresh single-use gateway nonce + verifier-identity + freshness, signed under a NEW domain tag `aikochat:pop:v1:EdDSA`.
- **Reuse of everything already gateway-side:** `record_signing_key` (the single upsert door), `signing.decode_multikey` (the codec), the atomic single-use nonce pattern (`nonce_service`/`passkey_service`), and the documented per-user→global-unique flip that PoP unlocks (`models.py:468-470`). Cast should build the challenge endpoint by *cloning `nonce_service` + `passkey_service`'s challenge store*, not inventing one.
- **Separate X25519 key for E2EE readiness** — additive, unused-for-now, minted in `SovereignKeyStore`.
- **The forge stays in the app repo** — it authors the protocol shape; the gateway conforms (its twin, message-signing, was homed the same way).

### DROP (the slag)
- **The framing that "peer PR B" is unbuilt.** It is built (`signing_keys` roster). Cast must retarget: the ore is the *PoP challenge*, not the roster. The stale app comments (`origin_envelope.dart:22-24`, `message_signing.dart:11-12`) that say "binding is peer PR B, deferred" are **out of date** — the binding-as-observation shipped; only binding-as-*proof* is missing.
- **Any "single Ed25519 key doubles as the DH key via conversion" option** — disqualified: no conversion in either stack, would be hand-rolled boundary crypto.
- **Designing a petname/human-naming layer here** — out of scope (Zooko deferred to #1760); only ensure the design doesn't preclude a NIP-05-style layer.
- **Assuming mosquitto gives the #24 islands handshake for free** — it needs a plugin; that's #24's problem, not this forge's, but don't let the design *assume* it.

### The 2–3 open decisions Cast MUST make
1. **Verifier-identity binding: URL (Nostr, weak) vs. pinned gateway pubkey (SSB, strong).** This is the load-bearing call — it decides whether the gateway must advertise a stable cryptographic identity (`.well-known` / `islands.py`) and whether "interchangeable islands" survives. The federation north-star (memory `project_federation_north_star`) argues for the SSB direction, but it's heavier. **Cast must pick and price both arms.**
2. **Replace vs. augment: does PoP-login MINT the session (replacing the JWT-issuing passkey ceremony), or does it register/prove the key UNDER an already-authed session (augmenting)?** Augment is the low-blast-radius first step (the key becomes a *second, provable* identity next to the passkey account); replace is the full "pubkey IS the user id" inversion (#21). These can be sequenced — augment first, replace as #24 — but Cast must state the order.
3. **Is the PoP-proven binding global-unique (flipping the `models.py` stance) at first ship, or still per-user until multi-device (#21) is resolved?** Global-unique is the *point* of PoP, but it collides with multi-device (one human, N device keys). Cast must decide whether first ship flips the constraint or defers the flip behind the multi-device decision.

---

### Sources
- [Nostr NIP-42 — Authentication of clients to relays](https://github.com/nostr-protocol/nips/blob/master/42.md)
- [Dominic Tarr — Designing a Secret Handshake (SHS paper)](https://dominictarr.github.io/secret-handshake-paper/shs.pdf)
- [HiveMQ — MQTT 5 Enhanced Authentication](https://www.hivemq.com/blog/mqtt5-essentials-part11-enhanced-authentication/) · [EMQX — AUTH packet](https://www.emqx.com/en/blog/mqtt-5-0-control-packets-06-auth) · [EMQX — SCRAM authn docs](https://docs.emqx.com/en/emqx/latest/access-control/authn/scram.html)
- [IACR 2021/509 — On using the same key pair for Ed25519 and an X25519 KEM](https://eprint.iacr.org/2021/509) · [libsodium — Ed25519 to Curve25519](https://libsodium.gitbook.io/doc/advanced/ed25519-curve25519) · [Filippo Valsorda — Using Ed25519 keys for encryption](https://words.filippo.io/using-ed25519-keys-for-encryption/) · [Veilid VLD0 cryptography (VeilidChat, Flutter sovereign E2EE — domain-matched precedent)](https://veilid.com/how-it-works/cryptography/)
- Code: `aiko_chat_app/lib/{services/sovereign_key_store.dart, features/chat/domain/message_signing.dart, features/chat/domain/origin_envelope.dart, features/auth/**}` · `aiko-chat-island/src/aiko_gateway/{domain/signing_keys_service.py, domain/signing.py, domain/models.py:433, rest/keys.py, rest/auth.py, realtime/ws.py, domain/nonce_service.py, domain/passkey_service.py}`
