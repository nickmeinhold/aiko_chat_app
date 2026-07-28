# DESIGN — The island-operator seat + takedown that reaches the runtime

> Movement 3 (Cast). The mold. Feeds Fold (author self-strike) then Temper (cross-family cage-match).
> Build order is core-first; each step independently ships value. Claims-to-falsify + rejected
> alternatives are explicit so the adversary strikes the design, not the polish.

## Problem

An island moderator can already take a reported message down server-side (`resolve_report` →
`take_down_message` soft-delete), but (a) there is **no app UI to do it** — reports pile up with no
operator destination, and the shipped ban arc (`AccountSuspended` + `/suspended`) has no trigger; and
(b) the takedown **does not reach clients that already synced the message** — the soft-delete flips a
server flag that a forward-only, monotonic-watermark client never re-observes. Two gaps, one seat:
**#35** (the operator UI) and **#33** (make the takedown observable at the client runtime).

## The shape

Three layers (A, B, C), built in order. **The atypical element [TEMPER-RECAST]** is the inverse of what
this design first proposed: *a retraction CAN ride a monotonic forward cursor — as a new, higher-ULID
event that references the taken-down id.* A forward-advancing event signalling a backward-looking action
serves live and offline clients with one mechanism. (The original design gave retractions a separate feed
with its own cursor; the cross-family Temper dissolved that — see TEMPER.md F1.)

### Layer A — the moderator flag (enabler, unblocks the seat)
- **[FOLD — OV1 RESOLVED]** Moderator is **island-global**, sourced from `settings.moderator_user_ids`
  (config lookup, not DB, not per-community). `moderation_service.is_moderator(user_id)` is the single
  predicate both `require_moderator` (the gate) and the `/me is_moderator` flag read — "one function,
  not two" (`deps.py:52-64`, `moderation_service.py:280-284`). So a single `is_moderator: bool` is
  correct (Claim 4 dissolved). **Check before building:** the island docstring says this predicate
  already "backs the /me `is_moderator` flag" — verify whether `GET /v1/me` already *emits* the field;
  if so, Layer A is **app-only** (parse an existing field), and the island half is zero.
- **Island (peer, only if /me doesn't already emit it):** `UserView` / `GET /v1/me` grows
  `is_moderator: bool` from `moderation_service.is_moderator`.
- **App:** `AppUser` + `fromJson` + `toJson` add `isModerator` (keep the round-trip symmetric — offline
  restore depends on it, `auth_models.dart:30-38`); expose `Provider<bool> isModeratorProvider` off
  `authControllerProvider.value?.isModerator`.
- **App — the auth taxonomy fix [TEMPER-RECAST, F4]:** `_authedCall` (`gateway_rest_api.dart:452`)
  currently maps *any* terminal 403 → `Unauthorized`/`AccountSuspended` → logs the user out. The recast
  is NOT an endpoint allowlist (a forever-drift exception list — the wrong option-frame). Instead
  **unbundle authn from authz once**: only `401` and the existing suspended-body `403` are
  session-terminal; every other terminal `403` → a domain `Forbidden` result, never eviction. An
  operator `403` additionally means the app's `isModerator=true` belief is **stale** → refresh `/v1/me`
  and clear the flag (correct the state, don't just mask it). UI gating on `isModeratorProvider` stays
  defense-in-depth, not the safety rail.

### Layer B — the operator seat (#35), ships real moderation on its own
- **App REST methods** on `ChatRestApi` + `GatewayRestApi` (mirror the `reportMessage`/`blockUser`
  template): `listReports()` → `GET /v1/reports?status=pending`; `resolveReport(id)` →
  `POST /v1/reports/{id}/resolve`; `dismissReport(id)` → `POST /reports/{id}/dismiss`;
  `banUser(id)` → `POST /users/{id}/ban`.
- **`ReportItem` model** + **`ReportQueueController`** (`AsyncNotifier<List<ReportItem>>`, auth-gated
  like `BlockedUsersController`).
- **`ReportQueueScreen`**: the queue with per-report actions (take down / dismiss / ban author). Reuses
  the bottom-sheet + confirm-dialog idioms.
- **Router:** `/settings/moderation` (mirrors `/settings/blocked`), guard branch reading
  `isModeratorProvider` (mirrors `/suspended` zoning), entry point in `settings_screen.dart` behind the
  flag so non-moderators never see the door. Server `ModeratorUser` remains the real boundary.
- **What B delivers alone [FOLD-CORRECTED]:** takedowns work only for **genuinely new readers** (never
  synced the channel) and **cleared-cache / fresh-install** clients — the `deleted_at IS NULL` read
  filter hides the row on a first fetch. It does **NOT** fix an **already-synced** client: DriftCache is
  durable SQLite and `_fetchDeltaHistory` walks *forward only* from a monotonic watermark, so the
  taken-down row **persists in the local cache across app restarts, permanently**, until an explicit
  removal (C or D). Cold reload does not fix it. **So B alone lets a moderator take a message down and
  watch it stay visible to essentially every currently-engaged user, indefinitely — that is close to
  theater.** Therefore **B and C ship together** (C is what makes the seat honest, not an optional
  follow-on); D closes the offline tail. See Claim 1 (now load-bearing, not cosmetic).

### Layer C — unified propagation via a forward-ULID tombstone event [TEMPER-RECAST, F1/F2/F5]
**The recast mechanism (all three adversaries converged on this; it eliminates the old Layer D).** A
retraction *can* ride the forward cursor — as a NEW event with its own higher ULID that *references* the
taken-down `msg_id`. One mechanism serves both populations.
- **Island (peer):** in the SAME transaction as the soft-delete, `take_down_message` appends a
  **tombstone event** — a row with its own new monotonic ULID (`tombstone_id > any live message id`) and
  a `target_msg_id`. It surfaces on the existing forward paths:
  - **`get_history(after: cursor)`** returns tombstone events inline (a `{type:"tombstone", id,
    target_msg_id}` wire item), ordered by `id` alongside messages — so a reconnecting/offline client
    picks it up on normal forward catch-up, no second cursor.
  - **WS fanout** emits the same tombstone event live (`hub.fanout(channel_id, tombstone_frame)`) for
    connected clients — a latency optimization delivering the *same* event, not a separate semantic.
  - Fanout is best-effort; the durable history path is the system of record, so a commit-then-crash
    (F5) or a missed/unsubscribed socket self-heals on the next forward catch-up.
- **App:** a `TombstoneFrame` (WS) and a tombstone case in the history-page parser share one handler.
  Parsed at `ServerFrame.parse` (`envelopes.dart:93`, unknown-tolerant → backward-compatible),
  dispatched at `GatewayTransport._onFrame` (`gateway_transport.dart:322`); history tombstones applied
  in the `_fetchDeltaHistory` page loop (`chat_repository.dart:691`). Both routes funnel through
  `_enqueueInbound` → `_onTombstone`. The tombstone's ULID advances the SINGLE `historyContiguousThrough`
  watermark naturally (forward-advancing event, backward-looking action) — no `deletionsThrough`.
- **Cache primitive `W6` [F3]:** `applyTombstone(String targetServerUlid)` = **soft-tombstone** (schema
  v6: nullable `tombstonedAt`, `watchChannel` adds `..where(t.tombstonedAt.isNull())`), NOT hard-delete.
  The tombstone row is a **dead-id record**: `upsertInbound` SUPPRESSES any later insert of a tombstoned
  `serverUlid`, closing every resurrection path (edit-after-takedown, buffered-frame-after-remove,
  reconnect overlap, out-of-order streams). Hard-delete is rejected — it has no memory that an id is dead.
- **Single mutator door [F3]:** only transport/history `MessageView`s may `upsertInbound`;
  **report-queue DTOs are display-only and NEVER ingested into `Messages`** (`list_pending_reports`
  returns the full `message_body`, a resurrection vector if upserted).
- Interacts cleanly with the documented B4 fence race (`messages_service.py:187-198`,
  `chat_repository.dart:648-690`): the empty-page-before-fence guard already treats a soft-delete-hidden
  fenced row as benign; a tombstone event in the same forward stream reconciles it explicitly rather than
  leaving it to the guard.

*(Old Layer D — a separate deletions feed with its own `SyncMeta` cursor — is ELIMINATED, not deferred.
The forward-ULID tombstone is durable in the message stream by construction, so offline reconcile is the
same mechanism as live delivery, not a second plane. This was the design's over-engineered "atypical
element"; Temper replaced it with the simpler unified event.)*

## Build order (each step independently useful, no big-bang) [TEMPER-REVISED]

1. **A** (moderator flag + auth taxonomy fix) — **app-only**: Temper confirmed `/v1/me` already emits
   `is_moderator` (`auth.py:873-879`), so the island half is done. App parses the field (default-false)
   and fixes the `_authedCall` 403 taxonomy (F4). Small, unblocks B, de-risks the eviction footgun.
2. **B + C together** (operator seat + unified tombstone propagation) — the honest MVP, and **durable by
   construction** (Temper F1/F2 collapsed the old "defer D" into this). B = operator UI over the existing
   island backend (app-heavy). C = the forward-ULID tombstone event (cross-repo: island appends+fans the
   tombstone; app consumes it on both WS and history catch-up via one `W6` soft-tombstone primitive).
   Because the tombstone rides the durable forward stream, offline/reconnect clients reconcile on normal
   catch-up — no separate release, no permanent stale row. **This is the whole of #33.**

There is no Layer D. Island-owned halves (C-island: the tombstone event + fanout) are **handed off**
(peer repo, standing rule), not built here. Layer A island half is already shipped.

## Tradeoffs taken (named, with owner + cost)

- **T1 [TEMPER-DISSOLVED] — ~~the offline tail lands after B+C~~.** Gone. The forward-ULID tombstone
  (F1) makes offline reconcile the *same* mechanism as live delivery, so there is no deferred population
  and no durable stale row. What remains is a latency distinction only: connected clients see the removal
  instantly (WS), offline clients on their next catch-up — both durable, both correct.
- **T2 [TEMPER-RESOLVED] — soft-tombstone chosen over hard-delete** (owner: eng). Temper F3: hard-delete
  has no memory that an id is dead, so any later insert path resurrects it. Soft-tombstone + dead-id
  suppression on `upsertInbound` is the robust choice and also buys an optional "message removed"
  placeholder. Cost: a schema v6 migration (cheap, follows the existing `onUpgrade` pattern).
- **T3 — single-worker WS fanout** (owner: eng, inherited). Cost: the `remove` frame reaches only the
  emitting worker; multi-worker needs the redis-fanout path. Mitigation: identical to the existing ban
  active-disconnect limitation — single uvicorn worker today; not a regression.

## Claims to falsify (Fold + Temper strike these)

1. **[FOLD-RESOLVED → folded into build order]** ~~"#35-before-#33 is acceptable, not theater."~~ Fold
   killed the reassuring version: the durable forward-only cache means an already-synced client keeps a
   taken-down row **permanently** (not "until reload"), so B-alone IS theater. Resolution: **B+C ship
   together** (not #35-then-#33, not #33-then-#35 — they're one honest increment). The residual open
   question for Temper is narrower: *is the offline-at-takedown tail (D) acceptable to defer behind B+C,
   or must D land in the same release?* (OV2 — legal/product.)
2. **"Offline clients need a dedicated deletions feed."** *Falsifier:* a **channel-dirty-flag** (island
   marks the channel `has_deletions_since=<ulid>`; on reconnect, if the client's cursor predates it, the
   client drops the channel's cache and does one full resync) may be simpler than a deletions cursor and
   sufficient at current message volumes. If so, D shrinks to a flag + resync, no new feed.
3. **"Hard-delete in the app cache is sufficient."** *Falsifier:* if we want a "removed by moderator"
   placeholder, undo, or local audit, we need the soft-tombstone (schema v6 `deletedAt` +
   `watchChannel` filter) instead.
4. **[FOLD-RESOLVED — dissolved]** ~~"A single `is_moderator: bool` is the right flag."~~ OV1 read:
   moderator is **island-global** (`settings.moderator_user_ids`, config lookup), one predicate for both
   gate and flag (`deps.py:52-64`). A bool is correct; no per-community scoping needed.
5. **"take_down + fanout is a safe sequence."** *Falsifier:* a fanout that runs before the DB commit
   settles, or a partial failure between commit and fanout, could desync. Mirror `ban_user`'s ordering
   (commit → then hub) and treat fanout as best-effort (D is the durable backstop).

## Rejected alternatives

- **Cram deletion into the message stream** (a "delete marker" as a new message with id > watermark):
  rejected — the target row is *below* the watermark; a forward marker must still carry the target id and
  the client still needs a removal primitive, so it doesn't dodge the two-population split; it just
  pollutes the message channel with retractions.
- **Always full-resync on reconnect:** rejected as an always-on policy (defeats the incremental cache);
  revived only as the dirty-flag-*triggered* variant in Claim 2.
- **Client-side authz as the boundary** (hide UI = security): rejected — server `ModeratorUser` is the
  boundary; the app flag is presentation-only (matches the existing block-filter philosophy: client
  hide is fail-open, gateway authoritative).
- **Hard prerequisite #33→#35 (consolidation framing):** rejected as the *build order* because B ships
  real value alone — but preserved live as Claim 1; if it survives the strike, the order flips.

## Open variables (enumerated, not silent)

- **OV1 [RESOLVED]** — moderator is island-global config (`settings.moderator_user_ids`). Bool flag correct.
- **OV2** — does EULA/legal require removal from live-synced clients, or is server-hidden enough? (Sets whether C/D are compliance-blocking or UX. Nick/legal.)
- **OV3** — Layer D mechanism: dedicated deletions feed vs channel-dirty-flag + resync. (Temper/island.)
- **OV4** — app cache: hard-delete vs soft-tombstone v6. (Product: placeholder UX wanted?)
- **OV5** — is a message ever in >1 channel (multi-fanout) or strictly one? (`message_view` has one
  `channel_id` → likely single; confirm to bound C's fanout.)

## Fold — degenerate-state sweep (author self-strike, pre-adversary)

Enumerated failure/degenerate states and their handling; unresolved ones are flagged for Temper.
- **Empty queue (n=0):** `ReportQueueScreen` renders an empty state. Trivial.
- **Report on an already-user-deleted or missing message:** `take_down_message` handles it —
  `if message is not None and message.deleted_at is None` skips the re-delete but STILL stamps the report
  `taken_down` (`moderation_service.py:351-357`). Resolves cleanly; no error. The "report-a-tombstone"
  flow is intended.
- **Double-resolve race (two moderators, same report):** island read-then-write; single-writer SQLite
  safe today, named Postgres-future race (`moderation_service.py:338-346`). App handles the loser's
  outcome: a 409 `ReportAlreadyResolved` → controller refreshes the queue. Not app's bug to fix.
- **Idempotent re-resolve:** TAKEN_DOWN re-run is a no-op (204); DISMISSED→takedown is 409. App treats
  both as "already handled, refresh."
- **⚠ Insert/remove reordering (C):** a `remove` frame that reaches the app *before* the message's
  insert would `removeByServerUlid` → 0 rows (no-op), then the insert **re-creates** the row. Fold
  verdict: **safe TODAY** only because (a) in the live path a message is inserted-and-fanned at post
  time, long before takedown, and `_enqueueInbound` preserves that causal order; and (b) island
  `get_history` EXCLUDES deleted rows, so a reconnect catch-up never re-delivers a taken-down row.
  **Invariant to protect (hand to island + guard in tests): a taken-down row must never reappear in ANY
  read path** — if it could, hard-delete would silently resurrect it. If that invariant is ever at risk,
  switch to a soft-tombstone + dead-id suppression (Claim 3).
- **`remove` for an unknown/never-had message:** `removeByServerUlid` → 0 rows, clean no-op. Safe.
- **Layer A island flag absent when app ships:** `AppUser.fromJson` must default `isModerator=false`
  (fail-closed → no operator UI) so an old island that doesn't emit the field can't accidentally expose
  the seat. Additive + default-false.
- **Auth carve-out scope (trust boundary — flag for Temper):** the `_authedCall` 403 carve-out must be
  scoped to **403 on the operator-endpoint allowlist ONLY** — a 401 (re-auth) and a 403 on any
  non-operator endpoint must STILL evict. Getting this wrong masks a real auth failure. Cage-match focus.
- **Simplest-alternative self-check (dissolve my own problem):** Can D be skipped? No — Fold showed the
  stale row is durable (survives restart), so without D the offline-at-takedown subset never reconciles.
  D (or the dirty-flag variant, Claim 2) is load-bearing for eventual consistency, not just live UX.

**Fold boundary honored:** this pass worked the metal (drove out the cold-reload slag, resolved OV1/OV4
degenerates, named the reorder invariant) — it did NOT re-grade the ore (the operator seat stays the
candidate) and does NOT substitute for Temper (same-distribution blindness: the cross-family strike
still owns unstated-assumption + simpler-alternative + blast-radius findings my own bias can't see).

## Fold-2 — self-pass on the TEMPER-recast mechanism (forward-ULID tombstone)

The recast survives a second self-strike with two refinements (neither dissolves it):
- **R1 — dead-id suppression is presence-independent.** A tombstone can arrive for a message the client
  never synced, so `W6` cannot be a column-flip on an existing row. The dead-id is a **standalone set
  keyed by `serverUlid`** that `upsertInbound` consults regardless of row presence. **Prunable lifetime:**
  once `historyContiguousThrough` passes the tombstone's ULID, the island no longer re-delivers the
  message (read-filtered), so the dead-id can be GC'd — it need not grow unboundedly.
- **R2 — the island `get_history` becomes heterogeneous.** Returning tombstone items alongside messages
  turns the shared `message_view` response into a **mixed list** (messages + tombstones), and
  `next_after`/`next_before` advance over tombstone ids too. This is the **main island-side cost** and
  the core of the C-island handoff — bigger than "add a WS frame." The app's `HistoryPage` parser must
  handle mixed item types.
- **Cursor-position correctness (verified):** a forward catch-up from below the target delivers
  target-then-tombstone; from between target and tombstone delivers only the tombstone (removes the
  already-synced row); from above the tombstone delivers neither (both already applied). One cursor,
  all three positions correct — because `tombstone_id > target_msg_id` always.
