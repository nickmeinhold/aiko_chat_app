# The anomaly pass — longitudinal record

Ask a model, with no goal and no briefing, "is anything on this screen broken?"
This file is where the answer's number lives.

**It is a record, not a gate.** The reading is a property of a model on a given
day, not of this repo's code. A threshold asserted in CI would go red for a
reason no commit caused and be silenced inside a week. A series says things a
single run cannot; a single run pretending to be a gate says less than either.

The one thing that IS asserted, in
`test/walk/blind_anomaly_calibration_test.dart`: **a run with zero catches may
not be recorded at all.** An agent that answers OK to everything scores a
perfect 0% false-positive rate while being completely blind, so the clean arm's
number is meaningless unless the defect arm proves the instrument can go red.

## Method

`flutter test --run-skipped --tags playtest test/walk/blind_anomaly_calibration_test.dart`

Eleven hand-labelled frames in `test/fixtures/anomaly_corpus/` — six clean, five
defective — shown to a fresh `claude -p` per trial, isolated cwd, `Read` only,
copied to an opaque filename so the path cannot name the feature. Labels were
set by a human looking at the pictures; they are the one thing in this
instrument no model produced.

## Readings

| date | model | trials | false positives (clean) | catches (defect) | notes |
|---|---|---|---|---|---|
| 2026-09-06 | `claude -p` default | 3 × 11 | **2/18 · 11%** | **12/15 · 80%** | first reading; both FPs on one frame |

### 2026-09-06 — what the first number is made of

**Both false positives are the same frame and the same complaint.**
`channel-dropdown`, twice: *"a dropdown menu overlaps and cuts off the chat
message underneath it."* The context menu, report sheet and confirm dialog are
also overlays and scored 0/3 each. The discriminator appears to be the **scrim**
— those three dim what is behind them, the dropdown simply clips a message
bubble mid-height. The pass's false positives are not noise; they are one
identifiable confusable, which is the tractable kind.

**Catch rate varies enormously by frame**, and not in the direction that
flatters the plan:

    blocked-list-title-block   3/3
    block-snackbar-blocks      3/3
    report-snackbar-blocks     3/3
    settings-title-block       2/3
    island-picker-title-block  1/3

The original done-condition for this whole build was "re-plant the app-bar bug,
confirm the pass flags it", on the island picker. That frame reads 1/3. There
was a two-in-three chance the n=1 check would have reported total failure on an
instrument that in fact catches 80%.

**It catches the signature and misnames the cause.** On both snackbar frames it
flagged the right pixels and called them "the message input bar"; on the blocked
list it called two app-bar titles "tab labels". The pixels are right every time
and the noun is wrong often. A catch a human can act on needs both, so
**localisation accuracy is a second number, and it has not been measured.**

## Coverage boundary

Every defect in the corpus has ONE signature: a solid block of ink where glyphs
belong (the bare-`TextStyle` family bug, 654bbdf + 36cda47). The 80% says
nothing about layout defects, contrast failures, overflow, or a control that is
present but wrong. Those need frames this corpus does not contain, and until it
has them the honest claim is "80% on unrendered-glyph defects", never "80% on
defects".
