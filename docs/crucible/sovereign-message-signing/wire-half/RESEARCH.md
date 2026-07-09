# RESEARCH — wire half (Heat phase)

> Ground-truth findings that separate metal from slag. Host probes run live against
> `chat.imagineering.cc` / `nick@imagineering` on **2026-07-09**; app-seam map from a
> read-only Explore pass. Nothing here is from memory — every host claim has a probe.

## A. The falsifier result: carriage is MERGED but NOT DEPLOYED

The wire half's precondition is that the gateway actually persists + echoes `origin`.
PR #66 is merged to aiko-chat-island `main`, but the **deployed** gateway does not have it.
Confirmed **three independent ways**:

| Probe | Result | Means |
|---|---|---|
| `grep -rl validate_origin /home/nick/apps/` | only unrelated `node_modules` hits | carriage code absent from deployed source |
| `docker exec aiko-chat-island-1 alembic current` | `0010 (head)` | PR #66's `messages.origin` migration `0011` NOT applied |
| deploy path | `/home/nick/apps/aiko-chat-gateway/` (rsync target, host kept old name), not a git checkout | stale rsync deploy; `main` ≠ deployed |

Running container: `aiko-chat-island-1` (image `aiko-chat-island:latest`). Health: HTTP 200.

**Deploy mechanism** (per `project_gateway_deploy_mechanism`, path corrected here): rsync
`src/` → `/home/nick/apps/aiko-chat-gateway`, then `docker compose up -d --build`, then the
container runs `alembic upgrade head` to reach `0011`. This is **peer/infra-owned** (the
gateway is #18/#1816 territory) — the app crucible does NOT unilaterally deploy it, but names
it as the hard precondition and can offer to drive it with consent.

### Consequence for build order
The app emit-half is safe to ship independently (see B), but the **truth-claim** "aiko
messages travel signed + verifiable" is FALSE until: (1) gateway deploys `0011` +
`validate_origin`, AND (2) a live end-to-end round-trip is verified (send → gateway persist →
echo → recipient reconstructs signingBytes → verify == true). Gate the claim on the
round-trip, never on the app merge. (transport-vs-trust boundary — delivery ≠ carriage.)

## B. Emitting `origin` NOW is safe-but-inert (does not break sending)

Deployed `src/aiko_gateway/realtime/ws.py:101 _handle_send` parses the send frame as a **plain
dict** — `frame["client_msg_id"]`, `frame["body"]`, `frame.get("reply_to")` — with **no
pydantic `extra="forbid"` model** on the send path (only `config.py:32` sets `extra="ignore"`,
and that's settings, not frames). So an unknown top-level `origin` key on today's gateway is
**silently dropped** — no `bad_origin`, no broken send.

→ The app can ship emission anytime; it activates the moment the gateway deploys. De-risks the
sequence: no lock-step release required.

## C. Post-deploy strictness the app MUST match (frozen contract, from PR #66 `domain/signing.py`)

`validate_origin(raw, *, frame_client_msg_id)` is **fail-closed** and pins the emitted shape:

- **Exactly seven keys, no more** — `_REQUIRED_KEYS = {v, alg, key_version, sender_pubkey,
  client_msg_id, signed_at_ms, sig}` (a frozenset; extra keys → `OriginError`). An extra debug
  field is silently ignored today but `bad_origin`-rejected post-deploy → emit EXACTLY these 7.
- `alg` must equal `"EdDSA"` (allowlist; never trusts the envelope's claim — alg-confusion).
- `sender_pubkey` must be a **multibase-base58btc ed25519 Multikey** (`z…`, `0xed01`
  multicodec prefix ‖ 32 raw bytes), decodable to raw-32. Capped 128 chars.
- `sig` must be **unpadded base64url** (`[A-Za-z0-9_-]`, no `=`), decoding to exactly 64 bytes.
  Charset-gated BEFORE decode (Python's decoder is permissive) — so the app must emit
  unpadded base64url, not standard base64, not padded.
- `client_msg_id` ≤ 64 chars AND **MUST equal the frame's `client_msg_id`** — the gateway's
  ONLY binding (envelope-vs-payload confusion defense). This is the single hard app-side
  correctness constraint: the value signed must be the value the frame is sent under.
- `signed_at_ms` a sane int in the INCLUSIVE range `[0, 2^62]` (gateway: reject `ts < 0` or
  `ts > 2^62`). The app gate matches this exactly (`ts < 0 || ts > _kMaxSignedAtMs`) — do NOT
  tighten to an open interval, that would diverge from the frozen contract (cage-match Carnot:
  the finding was a doc imprecision here, not a code bug). The SIGNED time, distinct from server
  `created_at`.
- What it does NOT bind: `sender_pubkey` → authenticated account. Echo proves "*some* key
  signed *these* bytes", never "*this user*". The pubkey→account binding is PR B
  (`signing_keys`), not live → **no "verified sender" UI** (named tradeoff, task #20).

`signing_bytes()` (the canonical reconstruction the gateway golden-vector-tests) matches the
app's `signingBytes` field order exactly: `lp(DOMAIN_TAG) ‖ lp(raw_pubkey) ‖ lp(channel_id) ‖
lp(client_msg_id) ‖ u64_be(signed_at_ms) ‖ lp(body) ‖ lp(reply_to or "")`, where `lp` is a
big-endian u32 length prefix. **Raw-key rule:** signed bytes use the RAW 32 pubkey; the wire
carries the Multikey; verifier strips `z`+`0xed01` → raw-32 for field #2.

## D. App-side integration seams (from the read-only Explore map)

### Outbound (emit)
- **Signature is in-hand at send time.** `chat_repository.dart:339-351` calls
  `sign(_signingKey, SignedPayload(...))` and gets a `MessageSignature` immediately before
  building `OutgoingMessage` (`:354`). → thread the signature through, do NOT re-fetch from
  cache. (Dissolves the agent's "fetch-at-send" blocker.)
- **Frame construction site:** `transport/envelopes.dart:224-230` `SendFrame.toJson()` — a
  permissive map (`if (replyTo != null)`). Add the `origin` object here. No strict-shape
  assertion on outbound; the PR#7 "String-keyed bug" was an *inbound* error-code decode.
- **Plumbing:** add `origin` to `OutgoingMessage` (`message.dart`), carry into `SendFrame`
  (`gateway_transport.dart:114-125`), emit in `toJson()`.

### The `client_msg_id` binding — ALREADY IDENTICAL ✅
One `clientTempId` from `_newTempId()` flows unchanged to BOTH `SignedPayload.clientMsgId`
(`chat_repository.dart:345`) and `SendFrame.clientMsgId` (`gateway_transport.dart:115`, via
`OutgoingMessage.clientTempId`). Gateway constraint C satisfied by construction. No divergence.

### Signing surface (`domain/message_signing.dart`)
- `SignedPayload{rawPublicKey, channelId, clientMsgId, signedAtMs, body, replyTo}`.
- `MessageSignature{sig: raw-64, rawPublicKey: raw-32, signedAtMs, keyVersion}` — everything
  the wire envelope needs EXCEPT wire-encoding.
- `SovereignKey.keyVersion` is **hardcoded `1`** (`sovereign_key_store.dart`) — emit `1`, slot
  reserved for rotation. No dynamic source yet (fine).

### Inbound (persist)
- **Single parse boundary:** `envelopes.dart:76-136` `ServerFrame.parse` → `MessageFrame(msg)`
  → `Message.fromView(f.msg)` (`message.dart:171-185`). `fromView` currently **ignores**
  `v['origin']`. Domain `Message` has **no** origin/sig field.
- **Cache:** drift schema v3 (`drift_cache.dart:40-81`) already has `sig/senderPubkey/
  signedAtMs/keyVersion` columns (base64) for the LOCAL outbound signature — but NO place for
  an inbound echoed `origin` object. Needs a v3→v4 migration (add `origin TEXT NULLABLE`,
  storing the echoed JSON verbatim). `_toDomain`/`_fromDomain` are plain field maps — low
  re-serialization risk; store the echoed origin as an OPAQUE json string (never re-canonicalize
  → no byte drift).
- **Collapse invariant:** `reconcileAck` (`drift_cache.dart:240-287`) already CLEARS
  `sig/pubkey/signedAtMs/keyVersion` when a signed field (body/replyTo/channelId) diverges
  (the "clear-sig-iff-signed-field-diverges" invariant from the core). The echoed `origin`
  must join that clear-list for the SAME reason (a diverged echo is not verifiable).

### Multikey encoder — NET-NEW (the one real primitive)
No `multikey/multicodec/z6Mk` anywhere in the app; pubkey stored as raw base64. The wire needs
`sender_pubkey` = multibase-base58btc(`0xed01` ‖ raw-32) and `sig` = base64url-unpadded(raw-64).
Write `encodeMultikey(Uint8List raw32) -> String` (mirror of the gateway's `decode_multikey`,
reversed) + base64url-unpadded sig encode. **Golden-vector pin:** feed the SIGNING-SPEC fixture
pubkey through `encodeMultikey`, assert it decodes (via the gateway's rule) back to the raw-32 —
and assert the whole envelope re-verifies through `validate_origin`'s shape gate.

### Tests
`test/features/chat/message_signing_test.dart` golden vector tests `signingBytes` only (bytes,
not wire) — unaffected. New tests: multikey round-trip, envelope shape == the 7 keys, an
inbound echoed origin persists + survives a cache round-trip byte-identical.

## E. Open variables — RESOLVED

1. Multikey encoding: **absent → build `encodeMultikey` + base64url-unpadded sig encode** (§D).
2. `sig` is raw-64 in `MessageSignature` → base64url-unpadded on the wire (§D).
3. `key_version`: **constant `1`** from `SovereignKey` (§D). No dynamic source needed.
4. Inbound persist: **cache v3→v4 migration** (add `origin TEXT`), store echoed JSON verbatim,
   join the collapse clear-list. `_toDomain`/`_fromDomain` are plain maps → no byte drift if
   stored opaque (§D).
5. Frame `client_msg_id` == signed `clientMsgId`: **IDENTICAL by construction** (§D). ✅
