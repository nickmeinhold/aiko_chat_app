# 🜂 TEMPER — cross-family design strike

> Movement 4. Real cross-family strike (no persona fallback): **Kelvin** (Gemini
> 3-pro-preview), **Carnot** (Codex/GPT), **Tesla** (Grok), **Maxwell** (Claude,
> orchestrator). All fed CRUCIBLE + RESEARCH + DESIGN. 2026-07-13.

## Verdicts

**All three external families: RECAST-NEEDED.** Unanimous. The **ORE SURVIVES** —
every reviewer independently affirmed the core metal is real (new domain tag, NOT
reusing message `signingBytes`; app-homed protocol shape; separate X25519 over
birational conversion; sequence inversion behind #21). Nothing dissolved. But 5 axes
need folding before Blade.

## Consensus findings (2+ families — high confidence, all FOLD)

### F1. Seal the mutator, don't guard the flag *(Kelvin #3, Carnot #1/#6/#10, Tesla #1/#7/#10 — ALL FOUR)*
The send-time `record_signing_key` upsert is a second door into the trusted roster;
a `pop_proven` bool guarded by prose is spoofable the first time any write path is
wrong. **FOLD:**
- PoP is the **only** writer that may set `proven` (write-once/monotonic: NULL/false→true only).
- Dedicated **`POST /v1/keys/prove`** (challenge+verify pair) — do NOT overload bare
  `POST /v1/keys` with optional PoP fields (dual-semantics-on-one-route footgun).
- Either a separate `proven_keys`/`pop_attestations` table (written only by the verify
  path, joined for UI) OR one table with explicit `assert`|`prove` upsert modes where
  `assert` has a column allowlist that cannot touch proven fields, atomic with nonce consume.
- Enumerate **every** writer (send-time, REST POST, DELETE, future admin) + a
  transition table: ASSERTED→PROVEN only via PoP; DELETE clears both; re-assert after
  prove does NOT demote; double-prove idempotent.
- **API contract:** every roster read surface returns `state: asserted|proven` (or
  omits asserted from "trusted keys" endpoints) — else a client builds a false badge
  from `GET /v1/keys` and reintroduces the lie.

### F2. Audience is one gateway with two names, not two deployments *(Kelvin #1, Carnot #3/#4, Tesla #2/#9 — ALL FOUR)*
`chat.imagineering.cc` + `chat.enspyr.co` are **one logical verifier, two aliases**.
Deriving "canonical origin" from the client `Host` header is a **DNS-rebinding MITM**
(Kelvin: attacker manipulates Host → gateway issues a challenge for an attacker
audience → user signs a valid PoP for the attacker). **FOLD:**
- A **static configured `GATEWAY_AUDIENCE`/issuer allow-list**; audience derived from
  it, never from the untrusted Host header; reject Host not on the list.
- One logical audience shared across all hostnames of one deployment. Dual-hostname of
  ONE gateway is NOT a cross-relay attack; cross-relay requires distinct logical audiences.
- Client **echoes the challenge-bound audience** (from the challenge response), never
  re-derives it from its base-URL string (normalization wars).
- **Typed audience** (`kind: url | gateway_key` + value, or separate domain tags
  `pop:v1` vs `pop:v2`) — the "same opaque field upgrades to a pinned pubkey later" claim
  is FALSE (encoding/length/verification all change; URL string vs 32-byte key). Don't
  pretend one string is SSB-ready.
- **Named TRADEOFF:** URL/issuer audience ≠ SSB/Veilid pin; impostor-at-TLS-termination
  stays open until a pinned gateway key. Do NOT overclaim NIP-42 relay-binding strength.

### F3. The real Increment-1 threat is stolen-session → malicious PROVEN *(Kelvin #2, Carnot #5, Tesla #3 — ALL FOUR)*
Tesla's sharpest catch: an attacker with a **stolen JWT** can complete PoP for any key
they hold, binding the victim account to the **attacker's** sovereign key → verified
badge for the attacker under the victim's account. This undercuts the "low blast-radius"
claim. **FOLD:**
- Nonce row `{nonce (PK, CSPRNG-minted), user_id, audience, expires_at, consumed_at}`.
- Atomic consume in ONE statement: `UPDATE … WHERE nonce=? AND consumed_at IS NULL AND
  expires_at>now() AND user_id=?` → set consumed; fail closed (kills TOCTOU double-submit).
- `expires_at` from server issue-time is PRIMARY; client `signed_at_ms` is a secondary
  skew check (client can backdate within TTL otherwise).
- **Increment 2 nonce cannot bind to a not-yet-existent user** (Kelvin #2) — the
  session-minting flow needs its own globally-unique, user-context-free nonce scoping.
- Name the stolen-session threat explicitly; it is the primary Inc-1 window, not multi-URL.
- Optional harden: reject prove if the pubkey is already PROVEN for a *different* user
  (soft global-uniqueness on PROVEN only) — prepares multi-device without shipping Inc 2.

### F4. "Verified sender" over-promises identity *(Kelvin #4, Carnot #2, Tesla #4/#6 — ALL FOUR)*
Inc 1 proves only "under account U's passkey session, someone proved possession of key
K." Users read a checkmark as "this is really Alice." **FOLD copy + conditions, or defer
the chrome (see the product fork):**
- Rename away from "verified sender" (implies personhood) → e.g. "signed · key proven
  for this account."
- Show badge only when `originCryptoValid` ∧ PROVEN(account, pubkey) ∧ not-expired. Never
  for ASSERTED.
- **Named TRADEOFF:** Inc 1 delivers "this account proved this key," NOT "pubkey IS the
  human." Multi-key-per-account UI must be specified (see M1).

### F5. X25519 mint-now is low-value, possibly premature *(Carnot #7, Tesla #5)*
MLS/E2EE (#25) likely wants HPKE / per-device LeafNode credentials, not one long-term raw
X25519 next to Ed25519 — a mint-now key may be **unused forever**. And the "avoids
migration over every identity" justification is wrong: the migration cost was never the
local seed, it's everyone's **stored peer keys** (distributed state), which mint-now
doesn't touch. **FOLD:** defer wire publication; if minting locally, label
`e2ee_placeholder_v0`, never send it, never bind it into PoP or `signing_keys`; do NOT
claim MLS readiness.

## Unique catches worth folding

- **M1 (Maxwell, ties to session multi-device analysis):** multi-key-per-account is not
  an edge case — it's the NORMAL multi-device state, *because passkeys sync (iCloud/Google)
  but the sovereign Ed25519 key is device-local*. Same passkey account on a 2nd device →
  fresh key → fresh PoP → a 2nd PROVEN key. So the schema is multi-PROVEN-key-per-account
  from day one, and the UI must answer "N proven keys" (all badged? primary only?). This
  is the concrete cause behind Tesla #4's multi-key observation.
- **Increment 2 is an identity MIGRATION, not a paragraph** *(Carnot #8, Tesla #6)*:
  re-keying auth/moderation/blocks/reports from ULID-FK→pubkey is its own design doc, not
  a future §. **Framing fold:** Inc 1 = "possession-backed device-key registration under a
  passkey account" (WebAuthn-adjacent roster hardening) — NOT "the keystone of federation."
  Tesla names calling it the keystone while shipping a toe-dip **"enthusiasm smuggling"** —
  a fair hit on CRUCIBLE's framing. Own it: the reusable **primitive** is the metal #21/#24
  need; the checkmark is optional chrome.
- **Malicious-gateway boundary unstated** *(Carnot #9, Tesla #8)*: Inc 1 still fully trusts
  the gateway roster + account mapping; "sovereign identity" is NOT achieved in Inc 1. Name
  it. (Sovereignty lives at the message layer already; Inc 1 hardens the roster, it does not
  move the namer→attester needle — that's Inc 2.)
- **Deletion/revocation semantics missing** *(Carnot #10)*: DELETE of a PROVEN key —
  removes proof? tombstones? invalidates verified UI on old messages? allows re-registration
  under another account? Undefined; matters for spoofing/key-loss/compromise recovery.
- **Compromise/rotation** *(Tesla #4)*: malware with seed + stolen refresh token → permanent
  PROVEN until DELETE; no re-auth/rotation story. Android uninstall → free key rotation → new
  PROVEN key, old still PROVEN.

## The strongest simpler alternative (converged, all three)

**Ship the PoP primitive + sealed roster (`state=asserted|proven`, dedicated prove
endpoint, mutator invariants) and DO NOT light end-user "verified" chrome in Increment 1.**
Use the distinction for server-side policy / admin / future UI until copy + global-uniqueness
are decided. This dissolves the worst false-trust surface while keeping the real metal
(#21/#24 need the *primitive*, not the checkmark). If the UI must ship, gate it hard (F4)
with non-identity copy and a logical challenge-bound audience (F2).

## Recast checklist (minimum before Blade)

1. Mutator + API separation for ASSERTED vs PROVEN (F1) — sealed writer + `/keys/prove` + state on reads.
2. Logical `GATEWAY_AUDIENCE` allow-list + typed audience + honest pin tradeoff (F2).
3. Nonce row schema + atomic consume + stolen-session threat named + Inc-2 pre-auth nonce (F3).
4. UI claim reduced to proven-scope with hard conditions — **OR deferred (product fork, Nick's call)** (F4, M1).
5. X25519 local-only `e2ee_placeholder_v0`, no wire, no MLS-readiness claim (F5).
6. Reframe Inc 1 as roster-hardening primitive, not "the keystone"; split Inc 2 into its own migration design (framing folds).

## Survives without ore recast
New domain tag + not-reusing-signingBytes · app-homed split · reject birational conversion
· sequence inversion behind #21 · defer petnames/E2EE/MQTT plugin.
