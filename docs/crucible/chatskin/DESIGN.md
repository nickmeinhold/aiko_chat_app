# DESIGN — ChatSkin: user-owned presentation & interaction

> Movement 3 (Cast). The mold. Problem → shape → build order → blast-radius →
> claims-to-falsify → rejected alternatives. Grounded on `RESEARCH.md` +
> verified live code. Target `claude-tasks#2863` (unifies #2714 + #2715 + keymaps).

## Problem

The chat surface hardcodes its look (`ColorScheme.fromSeed(deepPurple)`, literal
bubble geometry) and its interaction (fixed shortcuts). Nick's verdict: it looks
unfinished, and it's the one *visible* gap on a 3-store live app. The deeper aim:
make **presentation the third sovereign axis** — after identity (your key) and
reputation (the Carried Record), *how your world looks and how you drive it*
should be the user's, and eventually portable across islands.

## Shape

One container, but **two INDEPENDENTLY-SELECTED axes** (Fold correction) — so
"presentation + interaction" is coherent as *the surface the user owns* while the
visual look and the keymap never move together:

```
ChatSkin
├── VISUAL axis (chosen by visualPresetId + visualOverrides)
│   ├── SkinTokens   — colors beyond ColorScheme, type, geometry, density → ThemeExtension
│   └── SkinLayout   — enum/bool structural flags (aligned-vs-flat, avatars, timestamp) → build() branches
└── KEYMAP axis (chosen INDEPENDENTLY — switching visual preset never touches it)
    └── SkinKeymap   — Map<IntentId, SingleActivator> over a CLOSED intent vocabulary
```

**Fold rationale:** bundling the keymap into the visual preset means picking a
prettier theme silently remaps your keybindings — a coupling nobody wants. The
two axes share the "user-owned surface" anchor (Nick's #2863 unification) but are
selected and persisted separately. One keymap, independent of which look is active.

### Resolution & wiring (the seam)

At `main.dart`, one resolved `ChatSkin` builds three things the tree already
knows how to read:

1. **`ColorScheme`** — the maritime palette that fits Material's model.
2. **`ChatSkinTokens extends ThemeExtension<ChatSkinTokens>`** on
   `ThemeData(extensions: [...])` — everything that *doesn't* fit ColorScheme
   (beacon-amber accent, sea-panel hairline, serif/mono pairing, bubble radius,
   message max-width, avatar size, density). Read via
   `Theme.of(context).extension<ChatSkinTokens>()!`. `lerp()` animates skin swaps.
3. **A `Shortcuts` map** at app root from `SkinKeymap`, over `Actions` whose
   `Intent` vocabulary is fixed (SendMessage, NextChannel, PrevChannel,
   FocusComposer, ToggleSidebar, …). The user rebinds *which keys*, never invents
   actions.

**Why the seam is small (verified):** `MessageTile` already reads
`Theme.of(context).colorScheme`. Increment 0 promotes its literals (`maxWidth
320`, `radius 12`, avatar `size 20`, align-by-`isMine`) to token/flag reads —
widening what lives in the theme, not rewiring how it's read.

### Persistence — `SkinSelection`, sparse (mirrors `ChannelReadStore`)

Store **`SkinSelection(visualPresetId, visualOverrides, keymapOverrides)`**, NOT
a resolved `ChatSkin`. `resolve(...)` merges preset defaults with the user's
sparse overrides. Rationale: a later preset improvement (e.g. we tune "Bubbles")
**reaches existing users**; storing the resolved skin would freeze them on the
old version. Store shape copies `ChannelReadStore` exactly:

- Per-user single key `aiko_skin_selection_<userId>` → JSON.
- **Validate-on-load, fail-soft PER-KEY** (Fold): a corrupt payload → Maritime
  default; an **unknown `visualPresetId` → full Maritime fallback AND discard
  visualOverrides** (overrides are meaningless without their base); an **unknown
  override/token key → drop just that key** (like `ChannelReadStore`'s per-value
  validate-on-load). Never a broken UI. This is also the lock-out defence (below).
- Last-write-wins (no monotonic CAS — a skin choice isn't ordered).
- **Login lifecycle (Fold):** resolves to Maritime **pre-login** (gateway picker,
  auth screens have no user yet); per-user **post-login**; **re-resolves on user
  switch** (the resolved-skin provider watches `currentUserProvider`, mirroring
  how `channelRosterProvider` is scoped). Per-user keying (not per-device) is
  deliberate — it sets up Increment 5 portability (your skin follows your key).
- **Increment sequencing (Fold):** Increment 1's store is just `{visualPresetId}`
  — the `*Overrides` maps arrive with the editor (Increment 2), so the
  sparse-merge complexity doesn't ship before anything writes to it.

### Presets — code-defined, GENERIC names (IP constraint from research)

Presets are `ChatSkin` constants keyed by `presetId`. **Labels are generic** —
using a trademarked name as a feature label trips Apple 4.1 / Play impersonation
(both scan in-app strings). Ship: **Maritime** (default, ours), **Workspace**
(Slack-feel, flat), **Community** (Discord-feel, flat/dark), **Bubbles**
(iMessage-feel, aligned), **Classic Green** (WhatsApp-feel), **Sky**
(Telegram-feel). Brand names appear only as optional "inspired by" prose, never
labels/icons/screenshots/store metadata.

## Build order (core-first, each step independently useful)

- **Increment 0 — the seam + Maritime (`#2714`, VISIBLE WIN).** `ChatSkin` model
  + `ChatSkinTokens` extension + resolve ONE hardcoded Maritime skin at root.
  Promote `MessageTile`/composer literals to token/flag reads. No picker, no
  persistence. Ships the redesign Nick keeps asking for, skin-model-shaped.
- **Increment 1 — persistence + picker (`#2715` core).** `SkinSelectionStore` +
  a settings picker. Ships **exactly 3 structurally-distinct presets achievable
  with flags alone** (Fold — don't over-promise 6): **Maritime** (aligned, serif,
  sea palette), **Workspace** (flat rows, sans, light, dense sidebar),
  **Community** (flat, dark, accent). Three genuinely different looks, ZERO
  widget-swaps — this is what proves claim 1 (the model amortises) *before* any
  expensive work. The bubble-tail family (Bubbles/Classic Green/Sky) is NOT
  promised here — it lands properly at Increment 4 when tails exist.
- **Increment 2 — custom editor.** Token/flag editor producing sparse overrides
  on a chosen base preset. Advisory contrast warning (see a11y risk).
- **Increment 3 — keymap.** Fixed Intent vocabulary + rebindable `SkinKeymap` +
  hand-rolled capture/conflict UI (no viable package). Desktop/web primary.
  **Fold — conflict + OS-reserved detection runs at RESOLVE time, not just in the
  editor:** a hand-edited/corrupt blob can carry a duplicate chord, so on load a
  conflict drops the later binding to its default; the capture UI also **rejects
  OS/browser-reserved chords** (Cmd-W/Q/T, etc. — a denylist) since the platform
  intercepts them before Flutter sees them.
- **Increment 4 — widget-swaps.** Bubble tails (needs run-grouping added to the
  `ListView.builder` `itemBuilder`, which passes only `message/isMine/channelId`
  today) + background patterns. The expensive column, deferred out of core.
- **Increment 5 — portability (design-only for now).** Carry `SkinSelection`
  across islands — the federation tie-in. NOT built here; named so the model
  doesn't foreclose it.

## Blast-radius & consent spine (cage before monster)

Pure app-side presentation — **no wire, identity, or signing** (skin-scout
rejected signing the skin; no threat model — nobody lies about their own
wallpaper). But four real hazards, mitigations IN the design:

1. **UI lock-out (highest).** A corrupt/hostile skin (bad persisted blob or a
   custom-editor mistake) could render an unusable surface — invisible text,
   same-color-on-same-color, or a keymap with no path back to settings.
   **Mitigations:** (a) fail-soft to Maritime on any resolve error; (b) a "reset
   to default skin" affordance that is **always reachable and never rebindable**;
   (c) the settings route is reachable by a fixed UI affordance, not only a
   keychord.
2. **#12 enter-to-send footgun on mobile.** A preset/keymap that binds send to
   Enter on a touch soft-keyboard leaves NO send path. **Mitigation:** a visible
   send affordance is non-negotiable on touch regardless of skin; keymap
   rebinding is a desktop/web capability; the SendMessage intent always retains a
   tap fallback.
3. **IP / trade dress.** Generic preset names only (see above). Owner: whoever
   writes the preset table. Enforced by: no trademarked string in preset labels
   or store metadata.
4. **a11y / contrast.** The custom editor can produce unreadable combos.
   **Mitigation:** advisory contrast warning (fail-OPEN — warn, don't block; a
   user may want low contrast, but they should be told). Not a hard gate.

## Claims to falsify (hand these to Temper)

> Fold already worked #2/#3/#5 (see `FOLD.md`); they're re-aimed here at what
> Fold *couldn't* self-verify. #1/#4/#6 are the sharpest and largely untouched —
> strike those hardest.

1. **[SHARP] The model amortises.** ChatSkin is justified only if ≥3 skins people
   actually want ship. Fold argues Increment 1's 3 flag-only presets
   (Maritime/Workspace/Community) prove it — but is a *flat-vs-aligned + palette*
   difference enough to count as 3 skins people'd choose between, or is it one
   skin with a color knob? If the latter, hardcode maritime and close #2863.
   *(The CRUCIBLE falsifier.)*
2. **[FOLDED → verify] Presentation + interaction decoupled correctly.** Fold
   split them into independent axes under one container. Does that hold, or does
   the shared `SkinSelection` blob + one picker still leak coupling (e.g. "reset
   skin" nuking the keymap)?
3. **[FOLDED → verify] Sparse overrides deferred to Increment 2.** Fold made
   Increment 1's store just `{visualPresetId}`. Confirm that doesn't paint us
   into a migration when overrides arrive.
4. **[SHARP] `ThemeExtension` carries everything non-ColorScheme cleanly** with no
   widget needing a second read path. Risk: a Material/third-party widget ignores
   the extension and reads ColorScheme only, so a skin looks half-applied.
5. **[FOLDED → verify] 3 distinct presets without widget-swaps.** Fold dropped the
   6-preset promise to 3 flag-achievable ones. Is "Workspace/Community" actually
   distinguishable from Maritime by structure, or do they need tails to read as
   different? (Overlaps #1.)
6. **[SHARP] The keymap can't strand a user** — is "always-reachable settings +
   non-rebindable reset + OS-reserved denylist + resolve-time conflict-drop"
   actually airtight across macOS/web/mobile focus models, or is there a path to
   a keyboard-only lock-out?

## Rejected alternatives

- **Hardcode maritime `ThemeData`** — the null hypothesis. Rejected *if* claims
  1–2 hold; kept as the honest fallback if they don't.
- **A full parallel `ThemeData` per skin** — rejected; `ThemeExtension` is the
  Flutter idiom and gives lerp-able transitions + single read path.
- **A keybinding package** — none production-grade (research); hand-roll.
- **Sign/verify the skin like the Carried Record** — rejected; no threat model,
  it's a shape-inheritance (subject-owned, portable, versioned), not crypto.
- **Store the resolved `ChatSkin`** — rejected; freezes users on old preset
  versions, blocks preset improvement propagation.

## Open variables (enumerated, not rounded to "ready")

- **V1** — Exact `SkinTokens` field set (which literals become tokens vs stay
  fixed). Resolved during Increment 0 against the real widgets.
- **V2** — The closed `Intent` vocabulary list (which actions are rebindable).
  Drafted at Increment 3.
- **V3** — Does the custom editor edit a *live copy* or commit-on-save? (UX call,
  Increment 2.)
- **V4** — Dark-mode: is a "dark" a separate skin, or a mode within each skin?
  (Leaning: a skin declares its own brightness; no global `themeMode`. Confirm.)
- **V5** — Do presets get a small preview thumbnail in the picker, and is that
  a static asset or a live mini-render? (Increment 1.)
