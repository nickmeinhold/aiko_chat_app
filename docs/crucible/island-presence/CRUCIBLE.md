# Ore — island presence: who is aboard right now

> Movement 1 artifact. The pick, the case, the falsifier. Written at the consent gate,
> 2026-09-04. Seed named by Nick ("Presence! Yes!"), so the gate was already crossed.

## The pick

**Presence on an aiko island** — who is connected right now — rendered as the crown of
the wide sidebar, beneath the `IslandMark` that landed tonight (PR #184).

## Scoring (aliveness x impact)

| candidate | A | I | product | evidence |
|---|---|---|---|---|
| **Presence** | 3 | 3 | **9** | Nick picked it unprompted and with heat; it changes whether you bother typing at all |
| #26 drawer + conversation details | 2 | 2 | 4 | decided and designed, not built |
| #22 undiscoverable long-press mute | 1 | 2 | 2 | a real defect, but a gesture, not a design |
| #32 fold the two ASC drivers | 1 | 2 | 2 | inward scan; real drift, zero glow |

Rejected as slag: docs-guard window (#28), base_url taxonomy (#29 — Nick's call plus the
island tab, not a forge candidate).

## Verified substrate (measured tonight, not assumed)

- Live `/openapi.json`: **57 paths, none presence-shaped**. Nearest is
  `/v1/channels/{channel_id}/members` — a ROSTER (who belongs), not who is connected.
- **No presence implementation** in `src/aiko_gateway/`; every `grep -i presence` hit is
  unrelated (config presence-checks, ACL row-presence, the A5 gate).
- `src/aiko_gateway/realtime/envelopes.py:5` — *"typing/presence/edits extend it later."*
  The WSS envelope is the designed seam.
- Island half filed as claude-tasks#3885.

## Scout memory — three prior verdicts bind on this candidate

1. **`sovereign-message-signing/TEMPER.md`** — reforged because *"the app conflated 'sign a
   message' (app-local, easy) with 'provable federated origin' (a system property needing
   the gateway + a trust root)."* Presence walks into the identical trap: "am I connected"
   is app-local and trivial; **"who is aboard" is a claim about OTHER PEOPLE and needs a
   trust root.** This is a prescribed shape, not just a warning.
2. **`federated-identity-anchor/TEMPER.md`** — *"Self-certifying relocates authority, it
   does not dissolve it."* A signed presence claim still needs someone to bound its
   lifetime and refuse forgery; do not claim the signature dissolves the island's role.
3. **`chatskin/TEMPER.md`** — DISSOLVE the unified model, ship the smaller gold, make the
   abstraction earn itself. Do NOT build a general presence framework. Build the one
   concrete thing Nick asked to see.

## Why this is alive (the heat, stated as heat)

Every chat app has presence and every one of them is lying. A green dot means "a socket is
open" and is read as "this person is available" — and it gets away with it because the
server asserts it and the client just draws it.

This island cannot do that even if it wanted to. **In an app where every message is signed
at birth, presence would be the ONE claim rendered on the island's unverified word** — and
task #17 already ruled on exactly this shape: an evidence viewer must verify signatures
itself and never render the island's attribution. The naive build is already forbidden by
this repo's own law.

So the interesting object is not "presence". It is **what a presence claim looks like when
the subject signs it themselves**: a self-issued, expiring assertion — *"I, this key,
declare myself aboard until T"*.

That flips the disclosure problem inside out. Privacy stops being a server setting you must
trust and becomes structural: **you cannot be shown as present unless you signed a statement
saying so.** Invisible mode is not a flag the island honours; it is not signing.

And the robots arrive correctly and for free: Dreamfinder signs its own aboard-claim with
its own key and is present in precisely the same sense a human is. No personhood check,
because there was never a personhood question — a key and a signature.

## The falsifier (what would make this ore slag)

**If Nick looks at a plain green-dot mock and says "yeah, that's all I wanted."** Then
there is no design problem here, only a two-hour feature, and the forge is theatre. Signed
presence earns its complexity only if the unverifiable version actually bothers him.

Second, weaker falsifier: if the island cannot bound a signed claim's lifetime without a
server-side clock anyway, the signature may buy less than it costs.

## Open variables at Ore (not silently rounded to ready)

- Scope: island-wide ("who's aboard") vs per-channel. Nick asked for island-wide; the
  conventional answer is per-channel. Not yet decided.
- Whether presence and call-occupancy (claude-tasks#3159) are one mechanism or two.
- Whether the app renders presence for keys it cannot verify, and what it shows if so.
