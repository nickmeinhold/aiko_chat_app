# DESIGN — Sovereign signing, the wire half (v2, post-temper)

> The mold, re-cast after the round-1 cross-family strike (`TEMPER.md`). Cast from `CRUCIBLE.md`
> + `RESEARCH.md`. Task #19/#1817. Continues `../DESIGN.md` (the signing core).
> **v2 changes:** capability-gated emit (T1), inbound re-validation (T2), C2 → semantic
> field-identity (T3), full dual-store collapse law (T4), persist+verify merged (T5).

## Problem

The app signs every message locally but **emits nothing on the wire** (by design — the core
crucible deferred carriage). The gateway now carries `origin` (island PR #66). Wire the two
ends — emit `origin` outbound, validate+persist+verify it inbound — so a signed message
*travels* signed and a recipient can reconstruct the signed bytes and verify. This is the
hinge that makes the federation north star non-inert.

**Governing law (from the temper): delivered ≠ carried/authenticated/conserved.** The app never
trusts a property (carriage, authenticity, integrity) it has not independently established at the
boundary where that property is consumed.

## The shape

One net-new primitive + capability-gated outbound + validated/verified inbound. The frozen 7-key
envelope (`RESEARCH §C`) is the contract; both ends golden-vector-pinned to `../SIGNING-SPEC.md`.

```
primitive: OriginEnvelope  — encode (raw-32 → Multikey), base64url-unpadded sig,
                             + a Dart port of validate_origin (the SINGLE admission gate,
                             used for BOTH the outbound golden test AND inbound ingest)
outbound:  sign() → MessageSignature (in hand)
           → OriginEnvelope.fromSignature(...)  → assert it passes the gate before emit
           → emit ONLY IF the target gateway advertises carriage capability (T1)
inbound:   ServerFrame.parse → msg['origin']
           → validate_origin gate (T2): pass → canonical OriginEnvelope; fail → drop origin, keep msg
           → verify signature over reconstructed signingBytes → store {origin, verdict} (T5, no UI)
collapse:  reconcileAck: SET-on-success + clear-on-diverge + dual-store coherence (T4)
```

### The primitive: `OriginEnvelope` (`lib/features/chat/domain/origin_envelope.dart`)
- `encodeMultikey(Uint8List raw32) -> String` = `'z' + base58btc(0xed01 ‖ raw32)` (mirror of the
  gateway `decode_multikey`, reversed; gateway's exact `_B58_ALPHABET`).
- `base64UrlUnpadded(Uint8List) -> String`.
- **`validateOrigin(Map raw, {required String frameClientMsgId}) -> OriginEnvelope?`** — a Dart
  port of the gateway's `validate_origin`: exact-7-keys, `alg=='EdDSA'`, Multikey decode to
  raw-32 (len-capped 128), `sig` unpadded-base64url→64 bytes (charset-gated), `client_msg_id`
  ≤64 AND `== frameClientMsgId`, `signed_at_ms` in [0, 2^62] inclusive (matches the gateway), primitive types only. Returns a
  canonical `OriginEnvelope`, or throws `OriginError` (caller drops origin). **This one function
  is the single door** — outbound builds through it (fromSignature then self-assert), inbound
  admits through it.
- `OriginEnvelope.fromSignature(MessageSignature s, {channelId, clientMsgId})` → the 7-key value;
  `.toWire() -> Map` emits EXACTLY the 7 keys (no extras — gateway `_REQUIRED_KEYS` is exact).

### Data shapes
- Outbound: `OutgoingMessage` gains `Map<String,dynamic>? originWire` (built at send via `toWire`).
- Inbound: `Message` gains `OriginEnvelope? origin` + `bool? originCryptoValid` (the local verdict —
  data, not UI). `fromView` runs `validateOrigin` on `v['origin']`; on `OriginError` → `origin =
  null` (message still delivered, unverified).
- **Cache: NO JSON blob (T3 resolved — Nick).** The drift schema ALREADY has the typed columns
  (`sig` base64 raw-64, `senderPubkey` base64 raw-32, `signedAtMs`, `keyVersion`,
  `drift_cache.dart:70-78`) — currently populated for our OUTBOUND signature and null on inbound.
  Inbound origin populates the SAME columns from the validated `OriginEnvelope` (the column
  `senderPubkey` = the actual sender's key; the semantics generalize from "our sig" to "the
  signature carried with this message"). The framework serializes typed columns → there is NO
  JSON persistence to re-serialize, so the byte-drift question dissolves rather than being guarded.
  A verifier reconstructs `signingBytes` from these typed fields + the message's content fields.
  Migration v3→v4 adds **two** columns: `origin_crypto_valid INTEGER NULLABLE` (the ingest verify
  verdict — we self-verify outbound at sign-time, but must verify inbound) + `signed_client_msg_id
  TEXT NULLABLE` (the signed id for inbound rows whose PK is the ULID, keeping the stored sig
  re-verifiable). `toWire` regenerates a valid envelope from fields on demand for re-emit/forward —
  storing wire bytes is unnecessary. NB the verdict field is named `originCryptoValid`, NOT
  `originVerified` — it proves signature-integrity-over-content, never sender identity
  (cage-match: prevent a future badge misreading it as "verified sender").

### Emit capability gate (T1 — remove the coupling)
Emission is gated on the **target gateway advertising origin carriage**, per gateway — not a
lock-step deploy. Mechanism (cheapest first, decide at build): a version/capability field on the
already-fetched `GET /v1/auth/providers` or a `GET /v1/gateways` self-descriptor; cache per host.
If unknown/absent → **do not emit** (fail-closed: an un-advertised gateway may drop it into the
permanent-unsigned void). This makes the app correct across a FEDERATION of islands on different
deploy clocks, and dissolves the emit-before-deploy split-brain for every gateway, not just ours.

## Build order (v2 — proof is never discarded at the edge)

1. **`OriginEnvelope` primitive + `validateOrigin` gate + golden-vector test.** Pure, no wire.
   The interop anchor AND the shared admission gate. Test: `encodeMultikey(fixturePubkey)`
   decodes back to raw-32 by the gateway's rule; the 7-key `toWire()` passes `validateOrigin`;
   RED cases (extra key, bad alg, padded sig, `client_msg_id` mismatch) throw. **Resolve here:**
   does the sender self-receive its own message echoed with `origin`, or only an `ack`? (branches
   T4 set-on-success) — confirm against the deployed gateway fanout.
2. **Inbound: validate + persist + verify (T2+T5 merged).** `Message.origin`/`originCryptoValid`,
   `fromView` runs `validateOrigin`, cache v3→v4 migration, `_fromDomain`/`_toDomain`, verify on
   ingest → store verdict. **No UI.** Independently useful (portable, *verified* local history)
   and harmless anytime — it only ever tightens what we accept.
3. **Collapse law (T4).** `reconcileAck`: set-on-success (write re-validated echoed origin onto a
   reconciled row when signed fields match) + clear-on-diverge (join origin+verdict to the
   existing clear-list) + dual-store coherence (either cleared → both cleared; both present →
   must project the same key/sig/time/version). Name the 3 legal states in code + tests.
4. **Deploy gateway carriage (infra precondition).** Deploy PR #66 to `chat.imagineering.cc`
   (rsync + `compose up -d --build` + alembic→`0011`); advertise the carriage capability (T1).
   Peer/infra-owned — explicit consent; never `down -v`; never clobber host `.env`.
5. **Outbound emit, capability-gated (T1).** Thread `originWire` through `OutgoingMessage →
   SendFrame.toJson`, emit only when the target gateway advertises carriage. Effective the instant
   it ships against a carrying gateway; silent (not emitted) against a non-carrying one.
6. **Live round-trip verification → the "done" gate.** From a SECOND client / fresh history fetch
   (never the sender's optimistic row — it would miss the collapse-loss flaw): send → gateway
   persist → echo → recipient reconstructs `signingBytes` from the echoed origin → verify == true.
   Only after this passes is the wire half "done," and only for `created_at ≥ carriage-active`.

## Blast radius & consent spine (cage before monster)

- **Only outward mutation:** the gateway deploy (step 4) — shared, peer-owned host state
  (`nick@imagineering`, container `aiko-chat-island-1`, borrowed mosquitto). #18/#1816 territory.
  → explicit consent; may drive with consent (host access) or hand to peer. Never `down -v`.
- **App changes are local + reversible**, now doubly protected: emit is capability-gated (never
  fires into a void) AND inbound is fail-closed (invalid origin dropped, message preserved).
- **No blast on send:** `sign()` self-verifies before returning; `fromSignature` self-asserts
  through the gate before emit → only well-formed 7-key envelopes ever leave.
- **No blast on receive:** inbound `validateOrigin` caps every field before any persist/decode →
  no unbounded row, no hostile-decode bomb.

## Named tradeoffs (owner + cost + mitigation)

1. **No "verified sender" UI.** Echo ≠ identity ("forgery-as-echo"); pubkey→account binding is
   peer PR B (`signing_keys`), not live. Owner: product/security (**task #20/#1818**). Cost: a
   locally-verified signature the user can't *see* verified. Mitigation: honest until a trust
   root exists. Note: we DO store a local verify verdict (T5) — data, not a badge.
2. **`key_version` constant `1`.** No rotation infra. Owner: federation phase. Mitigation: field
   carried, so rotation is a value change. **Open harmonic (Tesla):** old signed history under a
   rotated/lost key — verification of historical rows across a key change is out of scope here;
   flag for the rotation design (not this task).
3. **Truth-claim scoped, not global.** "Messages travel signed" holds only for `created_at ≥
   carriage-active` per gateway; pre-carriage messages are permanently unsigned-on-wire (absent
   origin == unverified, never invalid). Owner: this task's step 6 gate. Mitigation: capability
   gate means we never *newly* create void messages against a known-carrying gateway.

## Named limitation (cage-match Carnot, re-review) — read-path identity binding

Inbound `validateOrigin` enforces envelope SHAPE but NOT the gateway's send-side
`client_msg_id` binding: the `message_view` carries no frame id, so the signed id lives only in
`origin` and the check is self-referential. Therefore `originCryptoValid` proves "a valid
signature exists over these content fields," NEVER "this sender signed THIS message position."
A dishonest gateway could relocate a validly-signed origin onto a different row with identical
channel/body/reply and it would verify. **Accepted** under the no-trust-root tradeoff (no
verified-sender UI until peer PR B binds key→account); pinned by the swapped-origin test. The
`_originFromRow` reconstruction is gated on `originCryptoValid != null` so an outbound LOCAL
signature never masquerades as a carried origin. Also named: `copyWith` cannot CLEAR
`origin`/`originCryptoValid` (null == preserve) — fine today (only `_persistInbound` writes them,
always-set); a future clear-transition needs an explicit mutator, not `copyWith`.

## Claims to falsify (v2)

- **C1.** The 7-key `toWire()` passes `validateOrigin` and the gateway's `validate_origin`
  unchanged. *Falsifier:* step-1 golden + RED tests; step-6 live round-trip.
- **C2 (dissolved — T3, Nick).** No JSON is persisted, so there is nothing to re-serialize. The
  origin is stored as typed columns and `signingBytes` is reconstructed from those fields.
  *Falsifier:* persist (typed columns) → read → reconstruct `signingBytes` → verify==true. There
  is no `utf8(wire)==utf8(cache)` claim because there is no stored wire form.
- **C3 (reframed — T1).** Emission never creates a permanently-unsigned message against a gateway
  the app *believes* carries origin. *Falsifier:* capability gate refuses to emit when capability
  unknown; step-6 round-trip against the carrying gateway.
- **C4.** Frame `client_msg_id` == signed `clientMsgId`. *Falsifier:* identical by construction
  (RESEARCH §D) + an equality test.
- **C5 (full law — T4).** Collapse SETS on success, CLEARS on diverge, and keeps the two stores
  coherent; no row ever shows a present-but-unverifiable origin. *Falsifier:* the state-space
  test across all 3 legal states + a mid-ack divergence race.
- **C6 (new — T2).** No inbound origin is persisted or decoded before passing the app-side gate.
  *Falsifier:* a hostile-oversized-origin ingest test asserting drop-origin-keep-message + no
  unbounded write.

## Rejected alternatives

- **Emit unconditionally / deploy-first-only.** Rejected (T1): deploy-first fixes only the one
  gateway we own; a federation of islands needs per-gateway capability gating. Remove the
  coupling, don't guard the window.
- **Persist the echoed origin opaque/verbatim.** Rejected (T2+T3): trusts the transport AND is
  not actually byte-verbatim through a Map. Validate + store canonical instead.
- **Fetch the signature from cache at send.** Rejected: it's in hand at `chat_repository.dart:
  339-351`; a re-fetch adds a re-encode drift surface.
- **Persist inbound without local verify (separate fast-follow).** Rejected (T5): raw persist is
  attacker-controlled decoration with DoS cost; verify in the same step.
- **Wait for peer PR B and ship both halves together.** Rejected: carriage is independently useful;
  PR B is peer-owned with no app dependency. (Carnot's counter logged as tradeoff #1/#3 — Nick's
  call, surfaced.)

## Open variables

- **Operational:** is the peer deploying PR #66, or do we (with consent)? — decided at step 4.
- **To confirm at step 1 (not a design gap, a fact to read):** does the gateway self-fanout the
  sender's own message with `origin`, or only `ack`? — branches T4 set-on-success.
