# CRUCIBLE — The island-operator seat (report→takedown, made to reach the runtime)

> Movement 1 (Ore) output. Anchor pre-selected by Nick (Path A, 2026-07-28). Consent gate crossed
> by his explicit pick. This file is the *enthusiasm case + the falsifier* — the hot-phase artifact
> the Temper adversary strikes alongside RESEARCH.md and DESIGN.md.

## The pick

**Build the first real island-*operator* seat: a moderator UI in the app that renders the report
queue and fires takedown / dismiss / ban — AND close the propagation gap (#33) so a takedown
actually reaches every synced client, not just the server row.**

Two live issues, one keystone:
- **#2330 (app #35)** — island-owner / admin section: close the report→takedown loop. *The seat.*
- **#2328 (app #33)** — server-side deletion doesn't propagate to already-synced clients
  (DriftCache is forward-only `Message.id > after`, no tombstone). *The crux #35 sits on.*

## Why this is alive (aliveness evidence — reasons, not affect)

- It's the moment the **federation thesis becomes a thing a human's hands touch** — the first
  island-*operator* seat, not another end-user feature. `project_identity_personhood_vs_reputation`
  ("each island sets its own reputation bar") has been prose + crucibles; this is where per-island
  policy becomes operable UI.
- It **braids three threads that each already have a body waiting**: (1) the `message_reports`
  table fills up with nowhere to go in the app; (2) the shipped ban arc (`AccountSuspended` +
  `/suspended` screen, PR #94/#95) has a landing pad with **no trigger** — this is that trigger;
  (3) the moderation backend (block/report/resolve/dismiss/ban) is *already built server-side*.
- Nick's own words when asked if this was a narrow "somewhere to action reports" pull or a
  structural move: **"get excited dawag."**

## Why it matters (impact evidence)

- Removes a **real recurring operational gap**: reports are accumulating with no way to action
  them in-app; the EULA carries a 24h-action commitment the product currently can't honor through
  its own UI.
- Unblocks a **stuck** thing: the ban arc is dead weight without a trigger.
- It's on the **critical path of the north star** (federation → per-island governance), not a side quest.

**Scores:** aliveness **3** (Nick would drop other work; three threads independently reach for it) ×
impact **3** (operational gap + unblocks shipped-but-inert work + north-star path) = **9**. Peak of the melt.

## The premise-correction Ore-grounding already found (READ THIS before designing)

The consolidation framed this as "nothing actions reports, no owner UI — build the loop." **Live code
says the backend loop mostly exists:**
- `island rest/moderation.py`: `GET /v1/reports?status=pending` (triage queue, `ModeratorUser`-gated,
  limit-paginated), `POST /reports/{id}/resolve` → `take_down_message` (**soft-delete** + mark
  `taken_down`), `POST /reports/{id}/dismiss`, `POST /users/{id}/ban` (+ active socket-disconnect),
  `DELETE /users/{id}/ban`. Authz is server-trusted (`require_moderator`); the app `/me is_moderator`
  flag only shows/hides UI.

So the real remaining shape is **thinner on the backend, sharper on the seam**:
1. **App:** an operator UI over endpoints that already exist (render `GET /v1/reports`; wire
   resolve/dismiss/ban; gate on `is_moderator`).
2. **#33 (the crux):** `resolve` does a **soft-delete**. The app's forward-only sync never re-pulls a
   seen id, so the takedown flips a server flag the runtime never sees → the reported message stays
   visible on every device that already pulled it. **A takedown must reach the runtime, not the record.**

## The falsifier (the one thing that, if true, shrinks this to slag)

**"If the island already emits a removal/tombstone over the WS/sync path on `take_down_message`, and
the app's DriftCache just isn't consuming it, then #33 is a ~10-line app-side consumer, not a
cross-repo design problem — and this whole crucible is over-forged for a small wiring task."**

Heat must resolve this by reading the actual propagation path:
- Does `get_history` (the `after` catch-up) expose the soft-delete transition at all, or filter it out?
- Does the WS/hub fanout (`realtime/hub.py`, `realtime/ws.py`, `domain/echo.py`) emit anything on
  takedown today? (Note: issue #2279 = "thread a message_id through the bus → delete echo
  suppression" — a hint the delete-event path is contemplated but maybe unbuilt.)
- Does the DB model carry a `deleted_at`/tombstone column, and does `message_view` surface it?

If the falsifier fires → report "ore smaller than forged; here's the small wiring task" (honest result).
If it holds (no propagation exists) → #33 is a genuine cross-repo design: emit a removal event +
reconcile it at the DriftCache layer. Design proceeds from there.

## Blast-radius / consent spine (named up front, per cage-before-monster)

- **Cross-repo:** app UI (this repo) + island removal-event/endpoint (peer repo
  `aiko-chat-island`, `/Users/nick/git/orgs/aiko/aiko-chat-island`). Island half is **peer-owned** —
  its build/PR is handed off, not done here (standing rule: island tasks hand off, don't linger).
- **Trust boundary:** moderator authz is already server-enforced (`ModeratorUser`). The app UI must
  NOT be the gate — it only reflects `is_moderator`. Any new app write path goes through the existing
  authenticated REST surface; no new trust decision moves client-side.
- **Runtime-reach invariant (the through-line):** the acceptance gate for #33 is *the message
  disappears from a client that already synced it*, observed on a real device — not "server row
  flagged", not "endpoint returns 204."
