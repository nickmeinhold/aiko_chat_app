# CRUCIBLE — ChatSkin: sovereign presentation & interaction

> Movement 1 (Ore) artifact. The enthusiasm case, written for the adversary to
> strike at Temper. Target: `claude-tasks#2863` (unifies #2714 maritime port +
> #2715 skin picker + custom key bindings).

## The pick

One `ChatSkin` model — **design tokens + layout flags + a keymap** — that the
chat surface *reads from* instead of hardcoding. Maritime is the first/default
skin instance; a preset library (favourite-chat-app looks) sits beside it; a
custom editor lets a user author their own; selection persists per-user and is
later portable across islands.

## Why this one (the heat, stated plainly)

This is the **one visible thing** the product has been missing while nine
invisible capabilities shipped around it (responsive sidebar, Blockie avatars,
Carried Record, channel switcher, composer v2, emoji autocomplete, grep search,
A/V calling, handle-change). Nick's dogfooding verdict was blunt and correct:
"it kinda looks like dogshit, fucking flutter basic UI." It's stock
`ColorScheme.fromSeed(deepPurple)` — verified live at `main.dart:31`.

But the spark is **not** "restyle it." It's that **presentation becomes the
third sovereign axis.** aiko already made *identity* sovereign (your Ed25519
key) and *reputation* portable (the Carried Record). ChatSkin makes *how your
world looks and how you drive it* yours too — carry your skin and your
keybindings between islands the way you carry your key. Presentation stops being
the app's and becomes the **user's**. That's the *oh, of course*: it's the
federation thesis extended to the surface you actually touch every day.

## The one-line spark

> If true, this is the feature that makes a stranger say "wait, I can make it
> look like *my* Discord *and* it follows me to every island?" — the sovereignty
> story you can *see* in the first ten seconds, before you understand a word
> about keys.

## The falsifier (what would prove this ore is slag)

**If "sovereign presentation" is post-hoc romance and the real thing is just a
theme picker**, then the ChatSkin *model* is over-engineering and Nick should
just get the maritime `ThemeData` hardcoded and go home. The design must earn
the model over a one-off restyle. Specifically, the model is justified **only
if** at least two of these hold; the Temper strike should hunt whether they do:

1. There are genuinely ≥3 skins worth shipping (maritime + ≥2 presets people
   want), so the abstraction amortises.
2. The custom editor is real product, not a settings-page toy nobody opens.
3. Cross-island skin portability is a real future increment, not a slide.

If only "maritime looks nice" survives, the honest result is: **build #2714 as a
hardcoded theme, close #2715/#2863 as not-yet-ripe.** That is a valid negative
result, not a failure.

## What it changes (the impact axis, independent of the glow)

- Removes a real recurring complaint (the app looks unfinished) that is
  *actively costing* on 3 live app stores where first-impression = install/churn.
- Unblocks the "presentation sovereignty" narrative that strengthens the whole
  federation pitch.
- The keymap dimension removes a real task for power users (keyboard-first is
  already the composer's design language — no send button, `enterToSend`).

## Scores

- **Aliveness: 3** — Nick raised the redesign *unprompted* ("what happened to
  the redesign?") and escalated it himself from restyle → skin system → unified
  with keymaps. Three separate memory files reach for it. You'd drop other work.
- **Impact: 3** — changes what a user can do (own their presentation), fixes a
  live-store first-impression liability, extends the core product thesis.
- Product = 9. Peak of the melt.

## Grounding already verified (not assumed)

- `main.dart:30-35` — single `ThemeData`, `ColorScheme.fromSeed(deepPurple)`,
  `useMaterial3: true`. No `darkTheme`, no `themeMode`. The seam is 4 lines.
- `MessageTile` (`chat_screen.dart:382`) already reads
  `Theme.of(context).colorScheme`; everything else is a literal (`maxWidth 320`,
  `borderRadius 12`, avatar `size 20`, align-by-`isMine`). Half-wired already.
- `ChannelReadStore` (`channel_read_store.dart`) is the persistence template:
  per-user single JSON key, validate-on-load, fail-soft.
- Pure app-side presentation: no wire / identity / signing touched → no island
  cross-tab grounding required (skin-scout already rejected signing the skin).
