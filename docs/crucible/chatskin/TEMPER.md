# TEMPER — cross-family design strike (movement 5)

## Verdict: RECAST → the unified model is DISSOLVED as premature; the smaller gold (hardcoded Maritime) is validated

Panel: Maxwell (Claude) + Carnot (Codex) + Tesla (Grok) + Kelvin (Gemini).
Wu (Kimi) dark — 402 membership/billing error, not transient.

| Reviewer | Verdict | One line |
|---|---|---|
| Carnot | **DISSOLVE** | Hardcode Maritime; split keymaps to a separate feature; prove 3 presets with static mockups first |
| Tesla | **DISSOLVE** | Ship #2714 as hardcoded Maritime, ZERO ChatSkin types; reopen the model when a 2nd structural look has users asking by name |
| Kelvin | **RECAST** | Ship one beautiful configurable Maritime; make the abstraction earn itself at bubble-tail-grade distinctness |
| Maxwell | **CONCUR (RECAST)** | I counted flags, not choices — same-distribution blindness Fold couldn't see. The model is unearned at Increment 1 |

## The convergent fatal finding (3 families, independent)

**The model does not amortise on flag-only presets.** Maritime (aligned/serif/sea)
is one skin; Workspace (flat/sans/light) is a second look; Community is Workspace
with the lights off. That's **2 looks + dark**, not "≥3 skins a user chooses
between." The only presets that would feel like separate *products* (bubble tails,
wallpaper, hover-timestamp chrome) are all widget-swaps deferred to Increment 4 —
so Increment 1 ships the abstraction *before* anything that justifies it. Generic
trade-dress labels further erase the brand-affinity pull that makes people switch
skins in the wild. CRUCIBLE's own falsifier: *if only Maritime survives, hardcode
it and close #2863's model.* Fold's residual doubt was correct and terminal.

## Two more convergent findings that improve EVEN the hardcoded build

1. **`ThemeExtension` is leaky (Carnot + Tesla + Kelvin).** It skins only widgets
   you teach to read `extension<ChatSkinTokens>()`. Material/third-party chrome
   (AppBar, TextField, ListTile, Dialog, SnackBar, Switch, NavigationRail, emoji
   picker, markdown renderer) read `ColorScheme`/`TextTheme`/component subthemes
   only → a **half-skinned app**. The design named this (claim #4) but proposed no
   mitigation. **Carry-forward (survives into hardcoded Maritime):** map maritime
   into full `ColorScheme` + `TextTheme` + component subthemes (`appBarTheme`,
   `inputDecorationTheme`, `dialogTheme`, `snackBarTheme`, `navigationRailTheme`,
   `switchTheme`, …), and use `ThemeExtension` ONLY for genuinely chat-specific
   tokens. This is the single most valuable finding — it makes Maritime skin the
   WHOLE app, not just `MessageTile`.
2. **Emergency keymap path must be a physically separate `Shortcuts` layer
   (Tesla).** If the escape/reset chords live in the same resolved `Shortcuts` map
   `SkinSelection` rebuilds, a resolve failure or focus exile drops the safety net
   *with* the load. The reset surface must not share "matter" with the rebindable
   surface. **Moot if keymaps are deferred** (they are, in the recast).

## What held under load (genuinely sound, banked for later)

- Visual/keymap axis decoupling (Fold's catch) — correct.
- Persistence physics: sparse selection > resolved skin, per-user key mirroring
  `ChannelReadStore`, fail-soft/unknown-preset→Maritime, pre-login default.
- Generic preset labels under Apple 4.1 / Play impersonation — real, correctly forced.
- Token/layout-flag/widget-swap cost table — the clearest engineering in the pack.
- The **null hypothesis (hardcoded Maritime) is the true blade** — the design's own
  escape hatch is what ships.

## Outcome

**Candidate #2863 (unified ChatSkin model) — INVALIDATED AS PREMATURE.** Honest
negative result, per the crucible gate. **Sub-candidate #2714 (Maritime redesign,
hardcoded, mapped through full ThemeData) — VALIDATED and is the thing to build.**
The model reopens when a second *structural* look (bubble-tail-grade) has users
asking for it by name — not when a tracker unifies three tickets.

Decision fork owned by Nick (it's his escalated vision): accept the recast (ship
hardcoded Maritime now, close the model) or override (build the model anyway).
Maxwell recommends the recast.
