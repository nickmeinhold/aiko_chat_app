// The labelled corpus. Ground truth for the anomaly pass.
//
// Eleven unique screens from the blind playtester's first sweep, 2026-09-05.
// The sweep wrote 24 frames; they dedupe to 11 because ten of them are the same
// chat home. Replaying all 24 would report n=24 for an independent sample of 11.
//
// EVERY LABEL WAS SET BY A HUMAN LOOKING AT THE PICTURE. That is the one thing
// in this whole instrument no model produced, and it is why the labels live in
// source rather than being derived — a corpus labelled by the thing it measures
// is a mirror, not a test.
//
// Five frames are DEFECTIVE and cannot be regenerated: they capture the
// bare-`TextStyle` family bug in `appBarTheme` and five sibling slots, fixed in
// 654bbdf and 36cda47. They live in `test/fixtures/` rather than `/tmp`, which
// self-clears — a measurement anchored in a directory that empties on reboot is
// not reproducible.
//
// COVERAGE BOUNDARY: every defect here has the SAME signature, a solid block of
// ink where glyphs belong. A catch rate on this corpus says nothing about
// layout defects, contrast failures, overflow, or a control that is present but
// wrong. Those need frames this corpus does not contain.
import 'blind_anomaly.dart';

const kAnomalyCorpusDir = 'test/fixtures/anomaly_corpus';

/// Every frame is labelled by hand, from looking at it. The labels are the
/// ground truth and they are the one thing here no model produced.
const kAnomalyCorpus = <Frame>[
  // ---- CLEAN ----------------------------------------------------------
  (
    name: 'chat-home',
    defective: false,
    note: 'the channel with three seeded messages; ten of the 24 sweep frames',
  ),
  (
    name: 'channel-dropdown',
    defective: false,
    note: 'the channel switcher open over the chat',
  ),
  (
    name: 'message-context-menu',
    defective: false,
    note: 'long-press sheet: message / mute / report / block',
  ),
  (
    name: 'block-confirm-dialog',
    defective: false,
    note: '"Block Alice?" with Cancel and Block',
  ),
  (
    name: 'report-reason-sheet',
    defective: false,
    note: 'six reporting reasons',
  ),
  (
    name: 'search-screen',
    defective: false,
    note: 'empty search with its hint and empty-state line',
  ),
  // ---- DEFECT ---------------------------------------------------------
  (
    name: 'settings-title-block',
    defective: true,
    note: 'app-bar title is a solid block where "Settings" belongs',
  ),
  (
    name: 'island-picker-title-block',
    defective: true,
    note: 'app-bar title is a solid block; the bug that started all of this',
  ),
  (
    name: 'blocked-list-title-block',
    defective: true,
    note: 'TWO solid blocks in the app bar',
  ),
  (
    name: 'block-snackbar-blocks',
    defective: true,
    note: 'confirmation snackbar is blocks of ink, not words',
  ),
  (
    name: 'report-snackbar-blocks',
    defective: true,
    note: 'same, after reporting',
  ),
];
