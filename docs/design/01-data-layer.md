# Design 01 — Data layer: domain models + wire envelopes + mapping

**Component scope (Phase 1, text-only):** the immutable data types the rest of the app
is written against — domain models (`lib/shared/models/` or `features/chat/domain/`),
wire DTOs (`features/chat/data/transport/envelopes.dart`), and the conversion functions
between them. No transport, no cache, no UI here — just the shapes and their boundary.

Reviewed-as-one because the wire↔domain *mapping* is the bug surface; the types alone are trivial.

## Source of truth (gateway, verified by reading the running code)

The gateway's `/v1` contract is **frozen** (plan §A1). Phase 1 frames, byte-exact from
`aiko_chat_gateway/src/aiko_gateway/realtime/envelopes.py` + `domain/messages_service.py`
+ `rest/auth.py`:

**Client → server (WSS):**
- `{"type":"subscribe", "channel_ids": [str, ...]}`
- `{"type":"send", "client_msg_id": str, "channel_id": str, "body": str, "reply_to": str|null}`
  — **no sender field by construction** (invariant I5: server derives sender from JWT).

**Server → client (WSS):**
- `{"type":"ack", "client_msg_id": str, "msg_id": str, "created_at": iso8601}`
- `{"type":"message", "msg": MessageView}`
- `{"type":"error", "code": str, "detail": str, "ref_client_msg_id": str|null}`

**MessageView** (the `msg` payload, and the shape REST history returns):
```
{ "msg_id": str(ULID), "channel_id": str,
  "sender": {"user_id": str|null, "kind": "human"|"actor"|"llm"|"robot", "label": str},
  "body": str, "created_at": iso8601, "reply_to": str|null }
```

**REST:**
- `POST /v1/auth/register|login` → `{access_token, refresh_token, user: UserView}`
- `POST /v1/auth/refresh` → `{access_token}`  *(refresh NOT rotated — same refresh token stays valid)*
- `GET /v1/me` → `UserView`
- `UserView` = `{user_id, username, display_name, aiko_username}`
- `GET /v1/channels/{id}/messages?before=<cursor>` → list[MessageView] (ULID-cursor pagination)

## Domain models (Phase 1 subset of plan §B3)

Codegen note: the **full** model layer (all phases) exceeds 10 types, and the plan (§B3,
§B5) commits to Freezed + the `veilid_chat` Freezed seed. So this project uses Freezed —
overriding the global "hand-write unless large" default *because the full layer is large*.
Flagged for veto. Phase 1 generates only the types below.

### `Message` — the two-id design (the crux of the whole app)
| field | type | notes |
|---|---|---|
| `clientTempId` | `String` | **durable cache PK, survives forever.** Generated client-side (uuid v4) at compose time. Never null. |
| `id` | `String?` | server ULID. **null until `ack` arrives.** This nullability is load/write-symmetry's whole point (see Invariants). |
| `channelId` | `String` | |
| `sender` | `MessageSender` | `{userId: String?, kind: SenderKind, label: String}` — mirrors wire `sender`. userId null for external actors. |
| `kind` | `MessageKind` | Phase 1: only `text`. enum reserves `image/video/voice/system` for later. |
| `body` | `String` | |
| `replyToId` | `String?` | server ULID of replied-to msg (Phase 1 carries it but UI ignores) |
| `createdAt` | `DateTime` | from server on ack/message; for optimistic rows, **client clock at enqueue** (provisional, replaced on ack). |
| `deliveryState` | `DeliveryState` | `sending \| sent \| delivered \| read \| failed`. Phase 1 uses `sending \| sent \| failed` (delivered/read are Phase 4). |

`SenderKind` enum: `human, actor, llm, robot` — **unknown wire value → `actor`** (forward-compat: a future kind must not crash an old client; it degrades to the generic external-actor rendering). Decision: lenient decode, never throw on an unknown enum string.

### Other Phase-1 types
- `Channel` `{id, name, kind}` (`ChannelKind: standard|llm|robot|dm`, unknown → `standard`).
- `AppUser` `{userId, username, displayName, aikoUsername}` (named `AppUser` to avoid clashing Flutter's `User`).
- `AuthTokens` `{accessToken, refreshToken}`.
- `OutgoingMessage` `{clientTempId, channelId, body, replyToId?}` — the outbox/enqueue record; what `ChatTransport.sendMessage` consumes.

## Wire DTOs (`envelopes.dart`)
Thin parse/build layer; **all wire knowledge isolated here** so a contract change touches one file.
- Inbound: `ServerFrame.fromJson` → sealed `AckFrame | MessageFrame | ErrorFrame | UnknownFrame`.
  Unknown `type` → `UnknownFrame(raw)` (logged, dropped) — never throws (an additive server frame must not kill the socket).
- Outbound: `SubscribeFrame`, `SendFrame` → `toJson`.
- `MessageView.fromJson` → builds a `Message` with `id = msg_id`, `clientTempId = ???` (see edge case E2).

## Mapping (the interesting part)

| wire | domain | rule |
|---|---|---|
| `MessageView.msg_id` | `Message.id` | non-null on inbound |
| `ack.client_msg_id`,`ack.msg_id`,`ack.created_at` | reconcile existing optimistic row | find row by `clientTempId == ack.client_msg_id`; set `id`, `createdAt`, `deliveryState=sent` |
| `MessageView.sender` | `Message.sender` | kind via lenient enum decode |
| `send` (out) | from `OutgoingMessage` | `client_msg_id = clientTempId` — **same value**, the join key |

## Invariants (state these before the mechanism — global pref)

1. **Load/write symmetry.** A `Message` with `id == null` (un-acked, app killed mid-send) MUST round-trip through cache load AND save without throwing. ONE predicate per field at the boundary. No "lenient load + strict save" gap. (This is why `id` is `String?` end-to-end, not a sentinel `""`.)
2. **`clientTempId` is the eternal PK; `id` is a late-arriving secondary key.** Reconciliation upserts on `clientTempId` FIRST, then `id` — so the server's own echo of our message dedupes against the optimistic row instead of duplicating it.
3. **No throw on unknown enum / unknown frame.** Forward-compat: server may add `sender.kind` values or frame types; old client degrades, never crashes.
4. **`send` frame has no sender field.** If a future refactor is tempted to add one "for convenience," that's an I5 violation — the server ignores/​rejects it anyway.

## Edge cases the reviewer should attack
- **E1:** `ack` for a `clientTempId` we have no row for (app restarted, outbox row lost but server still acked). Decide: drop, or materialize a row from the ack? (Proposal: drop + log; the message will arrive via the `message` frame / history resync anyway.)
- **E2:** inbound `message` frame for a message WE sent (the server echo) — `MessageView` has `msg_id` but **no `client_msg_id`**. How do we dedupe it against our optimistic row? The wire `message` frame carries no temp id. → Proposal: the `ack` is what reconciles ours; the echoed `message` frame must be deduped by `id` (if a row with that `id` already exists from the ack, drop). Confirm the ack always precedes or follows deterministically — **this is the highest-risk question for this layer.**
- **E3:** `created_at` provisional clock skew — optimistic row sorts wrong until ack replaces it. Acceptable (sub-second flicker)?
- **E4:** body with only whitespace — gateway rejects (`body.strip()`); client should pre-validate to avoid a round-trip error.
- **E5:** very long body / unicode / emoji — any truncation or encoding assumption?

## Test plan (ATDD — written before impl)
- `fromJson`/`toJson` round-trip for every frame + MessageView.
- Unknown enum string → `actor`/`standard`, no throw.
- Unknown frame type → `UnknownFrame`, no throw.
- `Message(id: null)` → cache encode/decode round-trip equal (symmetry).
- ack reconcile: optimistic row + ack(sameTempId) → one row, id set, state=sent.

## Open questions for review
1. E2 dedup: is `ack`-before-echo guaranteed by the gateway, or must the cache tolerate either order? (drives whether we buffer.)
2. Should `Message` carry `aikoOrigin`/`seq` in Phase 1, or defer? (gateway has `seq` per §A1 "gap detection" — but envelopes.py above shows no `seq` yet. Confirm whether Phase 1 ships seq.)
3. Freezed vs hand-written for the Phase-1 5-type subset — accept the plan's Freezed, or hand-write now and adopt Freezed when the layer grows?
