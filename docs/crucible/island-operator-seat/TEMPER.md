# TEMPER — cross-family strike on the design (Movement 5)

> Design cage-match (not a PR — the docs, not a diff). Cross-family: Kelvin (Gemini 3 Pro),
> Carnot (Codex/GPT), Tesla (Grok, which ground-truthed against the live repos). Wu (Kimi) returned
> no usable verdict (exploration preamble only) → 3 adversaries + Maxwell. Calibrated: 1 round, ~0 users.

## Verdict: NEEDS-REVISION (ore HOLDS, mechanism RECAST)

Unanimous: **keep the operator seat.** The backend loop is largely built, the ban arc + report queue is
the right keystone, the falsifier held (#33 is a real cross-repo seam). What dies is the propagation
*mechanism*. This is a Cast-level recast (round 1 of ≤3), not a dissolved candidate.

## Consensus findings (all 3 families independently) — folded into DESIGN.md

**F1 — The two-population "separate mechanisms" model is wrong; a retraction CAN ride the forward cursor.**
(Kelvin FATAL, Carnot, Tesla — all three, independently.) The premise "a retraction can't ride a
monotonic forward cursor" is false. The fix all three named: a **forward-advancing tombstone EVENT with
its own NEW, higher ULID** that *references* the taken-down `msg_id`. It rides the existing history/WS
path — live clients via `hub.fanout`, offline clients via normal `get_history(after: cursor)` catch-up —
advancing the single `historyContiguousThrough` watermark naturally. **One mechanism, one cursor, one
`W6` primitive. Layer D (separate deletions feed + second cursor) is ELIMINATED, not deferred.** My
"rejected alternative: cram deletion into the message stream" refuted rewriting the old row's id, not a
new forward event — the laundered assumption Temper exists to catch. → **Fold: replace Layers C+D with a
single forward-ULID tombstone event.**

**F2 — Deferring durable reconcile is the same theater Fold killed for B-alone.** (Carnot, Tesla, Kelvin.)
I sized the offline population as a "near-zero tail." Tesla (live-repo read): `hub.fanout` filters on
`conn.subscribed`, and on mobile backgrounded/locked/flaky-network is the *majority* state — "offline/
reconnect is the majority path; live fanout is the lucky path." So B+C (live-only) leaves most engaged
devices with durable stale rows across restarts — noncompliant with the same EULA-24h/UGC obligation.
→ **Fold: durable reconcile CO-SHIPS in the first operator release (dissolved by F1's unified mechanism —
the tombstone is durable in the forward stream by construction).**

**F3 — Hard-delete without local dead-id suppression is fragile; the resurrection surface is bigger.**
(All 3.) Beyond the island read-filter, resurrection paths: (a) a message **edited after takedown**
(`edited_at` column exists, no writer yet) → re-upsert; (b) a buffered `message` frame processed after
`remove`; (c) reconnect overlap where a history response started before the delete committed; (d)
out-of-order Dart streams (`_enqueueInbound` orders listener-callback order, NOT server causality —
Tesla); (e) **`list_pending_reports` returns the full `message_body`** (privileged, unfiltered) → if the
app ever upserts a report-queue preview into `Messages`, hard-delete dies; (f) multi-device (one device
clears, another re-syncs stale). → **Fold: app cache = soft-tombstone keyed by `serverUlid` +
`upsertInbound` SUPPRESSES tombstoned ids. Single mutator door: only transport/history MessageViews may
`upsertInbound`; report-queue DTOs are DISPLAY-ONLY, never ingested.**

**F4 — The `_authedCall` 403 allowlist guards the wrong coupling.** (All 3; Tesla named the bad
option-frame.) An endpoint allowlist is a forever-drift exception list. Wrong frame: A=allowlist operator
paths, B=UI-gate so 403 "never happens." Real answer: **unbundle authn from authz** — only `401` and the
existing suspended-body `403` are session-terminal; a plain `403` → domain `Forbidden`, never eviction.
Kelvin adds: an operator `403` means the app's `isModerator=true` belief is stale → **refresh `/me` +
clear the flag** (correct the state, don't just mask it). → **Fold: fix the `_authedCall` status taxonomy
once; delete the operator carve-out; operator-403 triggers a role refresh.**

**F5 — commit-then-fanout crash window.** (Carnot, Tesla.) If the island commits `deleted_at` then dies
before WS fanout, a live client is indistinguishable from an offline-missed one → permanent stale with D
deferred. → **Fold: write the tombstone event transactionally WITH the soft-delete; fanout FROM the log;
reconnect catch-up repairs any missed fanout. (Dissolved by F1's durable forward event.)**

## Ground truth Tesla surfaced (live-repo reads)

- **`/v1/me` ALREADY emits `is_moderator`** (`auth.py:873-879`, tests green). → **Layer A island half is
  DONE**; app work = parse the field + default-false. (Confirms the DESIGN "check first" note.)
- `list_pending_reports` returns full `message_body` + `message_deleted_at` (privileged, unfiltered) —
  drives the display-only discipline in F3.
- `_enqueueInbound` orders listener-callback order across independent streams, not server causality —
  so insert-before-remove safety rests on "remove never precedes the first insert in practice," not the
  FIFO alone. Under the unified forward-tombstone the tombstone's ULID > the message's ULID, so ordering
  is monotonic by construction — another reason F1's mechanism is safer.

## Missed degenerate states (added to DESIGN Fold sweep)

commit-then-crash (F5); edit-after-takedown; report-preview ingested as a Message; connected-but-not-yet-
subscribed (channel added after the subscribe set was fixed at ChatRepository construction); multi-device
(each device its own population); moderator's OWN cache not cleared on their successful resolve if not
subscribed; reply-to a taken-down parent (server allows replies to soft-deleted targets); dual-cursor must
not advance the message watermark over unreconciled removals (moot once cursors unify under F1).

## What held (survived the strike)

Falsifier held; #33 is a real seam. Server `ModeratorUser` as the boundary + app flag presentation-only.
Island-global `is_moderator` bool. Fold's kill of "B-alone is fine" (durable cache + never-rewind ⇒ cold
reload doesn't heal). A client removal primitive (`W6`) is required regardless of feed shape. The operator
seat is the right keystone; the seam is propagation + UI, and the backend is largely built.

## Recast status (honest)

The recast (F1 unified forward-tombstone + F3 soft-tombstone + F4 taxonomy) is applying CONVERGENT
adversary consensus, not novel author architecture — all three demanded this exact shape. Per
`feedback_post_temper_recast_needs_own_strike`, a substantial recast wants a confirming re-strike; given
the convergence + ~0-user stakes, the honest close is: **recast folded, ONE confirming re-strike (or a
Fold-2 self-pass) remains before "battle-tested."** Not claimed as fully tempered until that lands.
