# RESEARCH — ChatSkin

> Movement 2 (Heat). Ground truth on the mechanisms. Two sections are pre-baked
> from Flutter expertise (verified against live code); two (trade-dress IP,
> keymap package landscape) are being filled by background researcher
> `a9c9…` and marked ⏳ until it returns.

## 1. The token mechanism — `ThemeExtension`, not a parallel theme (pre-baked)

The canonical Flutter mechanism for *custom* design tokens that outgrow
`ColorScheme` is **`ThemeExtension<T>`**. You subclass it, register instances on
`ThemeData(extensions: [...])`, and read them with
`Theme.of(context).extension<ChatSkinTokens>()!`. It gives you two things a bare
data class doesn't:

- **`lerp()`** — Flutter tweens the whole extension across theme changes, so a
  skin switch animates instead of hard-cutting.
- **In-tree access** — every widget already under `MaterialApp` reads it with no
  provider plumbing, exactly like `Theme.of(context).colorScheme` does today.

**Design consequence:** maritime's palette that *fits* `ColorScheme`
(primary/surface/onSurface) goes into a `ColorScheme`; the parts that DON'T fit
the Material model — beacon-amber accent, sea-panel hairline color, the
serif/mono type pairing, bubble radius, message max-width, avatar size, density
— go into a `ChatSkinTokens extends ThemeExtension`. Both are built from the one
resolved `ChatSkin` at `main.dart`. This is why the seam is small: **the surface
already reads `Theme.of(context)`; we're widening what lives there, not
rewiring how it's read.**

## 2. Token vs layout-flag vs widget-swap (pre-baked, refines skin-scout)

Three distinct kinds of skin variation, each with a different implementation cost.
The discriminator matters because conflating them is how a "just a theme" scope
balloons:

| Kind | Example | Mechanism | Cost |
|---|---|---|---|
| **Token** | bubble color, radius, accent, font, density, max-width | `ChatSkinTokens` field read in `build()` | cheap — promote a literal to a read |
| **Layout flag** | align-mine-right vs all-left, avatar shown?, which composer buttons, timestamp-inline vs hover | `bool`/`enum` field branching layout | medium — a conditional in `build()` |
| **Widget swap** | bubble *tails* (iMessage/WhatsApp), background pattern, flat-vs-bubble container, Slack hover-only timestamp | a different widget/`ShapeBorder`/`CustomPainter` chosen by skin | expensive — real new widgets |

The skin-scout's four widget-swaps hold up against live code:
1. **Bubble tails** need run-position context (is this the last message in a run
   from this sender?) that `ListView.builder`'s `itemBuilder` at
   `chat_screen.dart:366` does NOT compute today — it passes only `message`,
   `isMine`, `channelId`. Adding run-grouping is a real sub-task, not a flag.
2. **Background pattern** — a `Stack`/`DecorationImage` behind the `ListView`.
3. **Flat-vs-bubble** — swaps the `Container` decoration + alignment wholesale
   (Slack/Discord are flat left-aligned rows; iMessage/WhatsApp are aligned
   bubbles). This is the biggest single fork.
4. **Slack hover-timestamp** — desktop/web only; a `MouseRegion` reveal.

**Build-order lever:** tokens + layout-flags cover maritime AND a flat
"workspace" preset AND an aligned "bubbles" preset with ZERO widget-swaps. Bubble
tails + background patterns are a *later* increment. So the core ships without
the expensive column.

## 3. Keybindings — `Shortcuts`/`Actions`/`Intent` (pre-baked architecture; package landscape ⏳)

Flutter's first-party keybinding stack is `Shortcuts` (maps a
`ShortcutActivator` → `Intent`) + `Actions` (maps `Intent` → `Action`
callback). A user-configurable keymap is a **persisted
`Map<ShortcutActivator, Intent>`** rebuilt at app root from `SkinSelection`. The
`Intent` set is a *fixed app vocabulary* (SendMessage, NextChannel, PrevChannel,
FocusComposer, ToggleSidebar, …); the user only rebinds *which keys* fire each —
they can't invent new actions. That bounds the whole feature: **a keymap is a
`Map<serialized-chord, intent-id>`, both from a closed enum.**

**Package landscape (researched): hand-roll.** No production-grade pub.dev
package edits/persists a keymap — `keyboard_shortcut_mapping` is desktop-only, 10
likes, no conflict detection, no JSON. So: hand-roll capture (a transient `Focus`
+ `onKeyEvent` reading `HardwareKeyboard.instance.logicalKeysPressed`), conflict
detection (dupe-key check against the active map), and persistence.

**Serialization shape (researched):** serialize `SingleActivator` (NOT
`LogicalKeySet` — it has no modifier semantics) as its fields, keyed by intent id:
```json
{ "sendMessage": { "trigger": 107, "control": false, "meta": true, "shift": false, "alt": false } }
```
`trigger` = `LogicalKeyboardKey.keyId` (int, round-trips stably). Rebuild via
`SingleActivator(LogicalKeyboardKey(json['trigger']), control:…, meta:…, …)` —
const-constructible, so rebuilding the `Map<ShortcutActivator, Intent>` at
startup is trivial. Source: [Actions & Shortcuts](https://docs.flutter.dev/ui/interactivity/actions-and-shortcuts),
[SingleActivator API](https://api.flutter.dev/flutter/widgets/SingleActivator-class.html).

## 4. Trade-dress / IP risk of named presets — HARD CONSTRAINT (researched)

**The trademarked NAME is the sharp risk; the visual imitation is soft.** Two
separable things:

1. **Using the mark as a preset label** ("Slack", "Discord", "iMessage",
   "WhatsApp", "Telegram") — this is the tripwire. **Apple Guideline 4.1
   (Copycats)** — *tightened Nov 2025* — forbids using another developer's brand
   or product name; repeated hits → account termination. **Google Play
   Impersonation + IP** policies forbid displaying another app's brand/title to
   imply affiliation → app suspension + account termination. Both stores scan
   **metadata AND in-app strings**, not just the app name. iMessage/WhatsApp are
   *first-party Apple/Meta* marks → highest sensitivity.
2. **Evoking the visual feel under a generic name** — materially lower risk.
   Trade dress protects source-identifying look-and-feel, but store review keys
   on *confusion/misrepresentation*. A maritime-branded app whose preset merely
   evokes a familiar layout isn't passing itself off as that product.

**Safe pattern (what theme/icon-pack/keyboard apps do):** generic *descriptive*
preset names; keep the brand only as optional "inspired by" prose, never the
label/icon/screenshot/store-metadata. Nominative fair use lets you *describe*
("layout inspired by popular team-chat apps") but not use the mark as a feature
name.

**Design decision forced by this:** preset labels are generic. Working map:

| Feel | Ship as |
|---|---|
| Slack | **Workspace** (flat, left-aligned, sidebar-dense) |
| Discord | **Community** (flat, dark, role-color accents) |
| iMessage | **Bubbles** (aligned bubbles, tails) |
| WhatsApp | **Classic Green** (aligned bubbles, wallpaper) |
| Telegram | **Sky** (aligned bubbles, cloud accent) |
| — | **Maritime** (the bespoke default, name is ours) |

Sources: [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) ·
[Apple 4.1 tightening, Nov 2025](https://9to5mac.com/2025/11/13/apple-tightens-app-review-guidelines-to-crack-down-on-copycat-apps/) ·
[Google Play Impersonation](https://support.google.com/googleplay/android-developer/answer/16341334) ·
[Play IP policy](https://support.google.com/googleplay/android-developer/answer/9888072).
