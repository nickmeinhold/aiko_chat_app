# RESEARCH — island-operator seat + takedown propagation (Heat)

> Movement 2 (Heat). Two parallel researchers (island propagation path · app reconcile/UI seam),
> synthesized. Citations are file:line at HEAD on 2026-07-28.

## Falsifier verdict: HELD — no propagation exists (crux is real)

`take_down_message` (island `domain/moderation_service.py:321-358`) sets `Message.deleted_at` and
`session.commit()`s — **emits nothing**: no WS frame, no bus publish, no hub call. The `resolve_report`
route (`rest/moderation.py:162-175`) doesn't even take a `gw`/hub handle (contrast `ban_user:194`,
which reaches `gw.hub.disconnect_user`). The soft-delete takes effect ONLY through the shared read
filter `Message.deleted_at IS NULL` (`messages_service.py:236`), applied at fetch time.

Forward catch-up is `WHERE Message.id > after` (strictly greater, `messages_service.py:241`); `id` is a
**ULID** (`String(26)`, monotonic total order, `models.py:343`). An already-synced message has
`id <= last_id`, so the catch-up query never revisits it. **The client holds a row it will never be
told is gone.** The service docstring claims it "propagates to the read paths" — true for a cold reload
/ backward page, false for the already-synced forward-only client. (Record vs runtime, again.)

## The two client populations (the load-bearing constraint — both researchers agree)

A takedown must reach two disjoint populations, and they need **different mechanisms**:

1. **Live-connected** (message on screen now): needs a **new WS `remove` frame** fanned out via
   `gw.hub.fanout(channel_id, frame)` (`hub.py:63-92`).
2. **Offline-then-reconnect** (synced the row, then disconnected before the takedown): the forward
   `after` cursor structurally **cannot** carry deletion of an older id. Needs a **separate tombstone
   read path with its own cursor** (e.g. `GET /v1/channels/{id}/deletions?after=<sep-watermark>`), swept
   on reconnect independently of the message cursor. **A WS frame alone is insufficient.**

## Island side (peer-owned: aiko-chat-island)

- **Soft-delete:** `Message.deleted_at` nullable timestamp (`models.py:363`; baseline migration
  `0001_baseline.py:69`). Row KEPT (silent tombstone); body/sender stay; only the read filter hides it.
  First-writer-wins idempotent (`moderation_service.py:353-354`).
- **History wire (`message_view`, `messages_service.py:21-39`):** fields = `msg_id, channel_id,
  sender{user_id,kind,label}, body, created_at, reply_to, origin?`. **No `deleted`/`tombstone` field.**
  `deleted_at`/`edited_at` are on the model but NOT serialized. `get_history` EXCLUDES deleted rows.
- **WS vocabulary (`envelopes.py`):** server→client = `ack`, `message` (new/echo only), `suback`,
  `error`. client→server = `subscribe`, `send`. **No remove/delete frame exists.**
- **Moderator backend ALREADY BUILT (`rest/moderation.py`):** `GET /v1/reports?status=pending`
  (queue, `ModeratorUser`-gated, limit 1..500), `POST /reports/{id}/resolve` → `take_down_message`
  (soft-delete + mark `taken_down`), `POST /reports/{id}/dismiss`, `POST /users/{id}/ban` (+ active
  socket-disconnect via `gw.hub.disconnect_user`), `DELETE /users/{id}/ban`. Authz server-side; app
  `is_moderator` only shows/hides UI.
- **Smallest island change for #33:** (a) `take_down_message` returns `(channel_id, msg_id)`;
  (b) new `envelopes.remove_frame`; (c) `resolve_report` gets the hub handle (mirror ban) and calls
  `hub.fanout(channel_id, remove_frame)`; (d) a tombstone read path for offline clients (the harder half).
- **Gotchas:** single-worker hub → WS fanout reaches one worker only (redis-fanout is the named
  multi-worker path); fence/history visibility-shrink race already documented at
  `messages_service.py:187-198` (soft-delete between fence-read and paging → empty-page-before-fence,
  interacts with B4 reconnect); echo-suppression #2279 needs a message-id on the bus (no delete-event
  path contemplated today); GH #1441 — `deleted_at` conflates moderator-takedown vs user-delete; blocks
  are a SEPARATE per-viewer dimension (`not_blocked_predicate`), not `deleted_at`.

## App side (this repo: aiko_chat_app)

- **No removal path today.** DriftCache writer census (`cache/drift_cache.dart:9-12`) names
  `W6 delete (Phase 2, unsupported here)` — **unbuilt.** `Messages` table (`drift_cache.dart:42-97`)
  has **no tombstone column.** A soft-tombstone needs a **schema v6 migration** (nullable `deletedAt`,
  `onUpgrade` branch at `drift_cache.dart:147-169` following the v3/v4 `addColumn` pattern). Reactive
  `watchChannel` (`drift_cache.dart:630-640`) would add `..where(t.deletedAt.isNull())`.
- **Watermark:** per-channel `historyContiguousThrough` in `SyncMeta` (`drift_cache.dart:122-135`),
  **single-writer, strictly monotonic — "never rewind"** (`:685-688`). Paging forward-only from
  `cursor = historyContiguousThrough` while `cursor < fence`, `getHistory(after: cursor)`
  (`chat_repository.dart:632-721`). **A delete of id ≤ watermark is structurally invisible via history.**
- **Reconcile insertion points:** cache primitive `removeByServerUlid(serverUlid)` beside
  `upsertInbound` (`drift_cache.dart:491`); policy `_onRemove` beside `_persistInbound`
  (`chat_repository.dart:492`), funneled through the `_enqueueInbound` FIFO (`:204-212`) so removal is
  ordered against a concurrent insert of the same ULID. Must key on **serverUlid**.
- **`_fetchDeltaHistory` already reasons about the hide:** treats empty-page-before-fence as a benign
  visibility shrink from "a moderation block (#7) **or a soft-delete**" (`chat_repository.dart:648-690`)
  — the gateway hide is anticipated; the app just can't apply a removal to an already-synced row.
- **WS frame extension (clean, additive, backward-compatible):** parse at `ServerFrame.parse` switch
  (`envelopes.dart:82-135`; unknown → `UnknownFrame`, never throws → old clients safe); dispatch at
  `GatewayTransport._onFrame` sealed switch (`gateway_transport.dart:319-339`) + new `_removals`
  broadcast controller (mirror `_messages:51`); consume via 4th subscription in `ChatRepository.start()`.
  Sealed + exhaustive switch → compiler flags every site to touch.
- **Operator UI:** reporter side exists (`message_actions.dart` report/block sheet; `blocked_users_screen`;
  `moderation_controller.dart` `BlockedUsersController`; `moderation_models.dart` `ReportReason`).
  Controller→REST template in `gateway_rest_api.dart` (`reportMessage:437`, `blockUser:420`, all via
  `_authedCall:452`). **NO operator UI, NO operator REST methods, NO moderator flag.** New work:
  `GET /v1/reports`, `POST /reports/{id}/resolve|dismiss`, `POST /users/{id}/ban` methods; a
  `ReportQueueController` (`AsyncNotifier<List<ReportItem>>`); a `ReportItem` model; a `ReportQueueScreen`.
- **⚠ Auth trap:** `_authedCall` maps terminal 401/403 → `Unauthorized`/`AccountSuspended` → **logs the
  user out** (`gateway_rest_api.dart:245-247` comment already flags "a moderator-only endpoint" 403).
  An operator call that 403s would EJECT the user. Must gate behind a known-moderator flag (so it never
  403s) OR carve out operator-endpoint 403 in `_authedCall`.
- **Moderator flag — CONFIRMED GAP:** `AppUser` (`auth_models.dart:10-50`) carries only
  `userId/username/displayName/aikoUsername`; `fromJson` parses no role. `me()` → `GET /v1/me`
  (`gateway_rest_api.dart:327-332`) EXISTS but carries no flag. Fix: gateway UserView adds
  `is_moderator: bool`; `AppUser` + `fromJson` + `toJson` (keep round-trip symmetric for offline
  restore) add it; expose `Provider<bool> isModeratorProvider`. Clean additive change; nothing reads it today.
- **Router:** go_router with a pure-function redirect guard (`router.dart:35-166`). New `/moderation`
  (or `/settings/moderation`) route mirrors `/settings/blocked` (`:158`); guard branch mirrors the
  `/suspended` zoning (`:107-110`) reading `isModeratorProvider`; entry point conditionally rendered in
  `settings_screen.dart` behind the flag. Defense-in-depth only — server `ModeratorUser` is the boundary.
