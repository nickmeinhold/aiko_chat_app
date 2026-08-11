# FOLD — author's self-pass (movement 4)

Pre-adversary hammering of `DESIGN.md`. Six folds, all applied back into the
design. Recorded so Temper strikes fresh metal, not slag already skimmed.

## Degenerate/failure states enumerated

| State | Handling (folded into design) |
|---|---|
| First run / no persisted selection (n=0) | resolve → Maritime default |
| Multi-account user switch | resolved-skin provider watches `currentUserProvider`, re-resolves per-user |
| Pre-login (no user) | Maritime default until a user resolves |
| Persisted `visualPresetId` removed in a later version | full Maritime fallback + **discard overrides** (meaningless without base) |
| Override key references a token that no longer exists | drop just that key (per-key validate-on-load) |
| Corrupt keymap with a duplicate chord | resolve-time conflict → later binding drops to default |
| Keymap binds an OS/browser-reserved chord (Cmd-W…) | capture UI denylist rejects it; platform intercepts anyway |
| Intent with no binding | action simply unavailable via keyboard; UI affordance remains |

## Claims stressed by the author

- **#2 (presentation+interaction one model)** — FOUND A COUPLING: keymap was
  bundled into the visual preset → switching theme silently remaps keys. **Fixed:**
  two independent axes under one container.
- **#3 (sparse overrides)** — the complexity doesn't land until the editor
  (Increment 2). **Fixed:** Increment 1 store is `{visualPresetId}` only.
- **#5 (flat-vs-aligned coverage)** — dropped the 6-preset promise; **Increment 1
  ships 3 flag-achievable, structurally-distinct presets** (Maritime/Workspace/
  Community); bubble-tail family deferred to Increment 4. (Residual doubt whether
  3 flag-presets are *distinct enough* → handed to Temper, overlaps #1.)

## Simplest rejected alternative, tried against my own problem

Could hardcoding maritime + a light/dark toggle dissolve the whole thing? It
would ship the visible win now — but Increment 0 **already is** essentially that
(maritime, skin-model-shaped, no picker). The build order de-risks the falsifier:
if Increment 1's second/third preset feels forced, we stop with a beautiful
maritime app and lose nothing. So the null hypothesis isn't rejected — it's the
**floor we ship first**, and the model only gets built if Increment 1 earns it.

## What Fold could NOT self-verify (same-distribution blindness → Temper)

- Whether flag-only preset differences read as "3 skins" or "one skin, a knob" (#1/#5).
- Whether `ThemeExtension` is honored by every widget on the surface (#4).
- Whether the keyboard-lock-out defence is airtight across 3 platforms' focus
  models (#6).
