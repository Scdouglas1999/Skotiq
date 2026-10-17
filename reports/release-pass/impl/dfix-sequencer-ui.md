# D-fix — batch `sequencer-ui`

Wave D items: SEQ-18, SEQ-19, SEQ-20 (residual), WD-SEQ-N1, WD-SEQ-N2, WD-SEQ-N3,
SCI-43 (pre-flight instance), NEW-C1.

Scope honoured: `packages/skotiq_app/lib/screens/sequencer/**` +
`packages/skotiq_core/lib/src/providers/sequence/rules/preflight_rules.dart`
+ the owning packages' test dirs. No git writes, no melos, no formatter runs, no
generated files, no FRB.

## SEQ-18 — a successful run left the node reading 0 / N (REFUTATION)

The previous fix keyed "this node finished" off `nodeStatus == NodeStatus.success`
and its test pumped exactly that. Wave D showed the live card at "0 / 4 frames"
with four EMPTY boxes, i.e. neither the status nor the structured detail was
present by the time the operator read it — the per-node progress entries are gone
while the panel is still inside its deliberate 20s persistence window. A run
stopped at frame 1 kept its detail and read "1 / 4", which is what made the
zeroing look specific to the success path.

Fix: `_NodeItemState` now remembers the last non-null progress it was handed
(status, percent, string detail, structured detail, run filter) and renders from
that when the live values disappear; the memory is dropped when the node starts
running again so one run can never show the previous run's frames. This makes the
card independent of WHEN (or by which of the three `reset()` call sites / id
churn) the maps are cleared.

Pin: `test/screens/sequencer/widgets/exposure_card_after_run_test.dart` drives the
REAL `SequenceTree`, runs the node to frame 4 of 4, then clears the progress maps
under it and asserts `0 / 4 frames` is absent and `4 / 4 frames` present.
Verified failing at HEAD behaviour (retention removed → `Found 1 widget with text
"0 / 4 frames"`).

## SEQ-19 — "R 180s" two rows above "Exposure: No Filter"

An exposure node with no filter of its own does not image unfiltered; it images
through whatever is in the wheel, and the run said `R` on the telemetry strip,
the thumbnails, the FITS filenames and the session report. The card's header was
the one surface still saying "No Filter".

Fix: the exposure progress panel takes the run's `SequenceProgress.currentFilter`
(threaded through `_NodeTreeView` → `_NodeItem` → `getProgressPanelForNode`) and
renders `Exposure: R (current)` when the node names none — marked as inherited
rather than presented as the node's own choice. With neither, the header now
reads `Exposure: No filter set` instead of the ambiguous "No Filter".

Pins: three cases in the same new test file (run filter used, node filter wins,
neither present).

## SEQ-20 residual — elapsed rendered in whole minutes

`target_header_card.dart` rendered the live readout as
`${(secs/60).round()}m / ${(secs/60).round()}m`, so a 4x3s target read
"0m / 1m" at 7s and "1m / 1m" at 40s while the panel above it said "~34s". Now
uses the same `DurationFormat` compact style as the planned line beside it.

Pin: `test/screens/sequencer/widgets/target_header_elapsed_units_test.dart` —
2 of 4 frames of 3s done ⇒ `6s / 12s`, never `0m / 0m`.

## WD-SEQ-N1 — operator Stop reported as an error

In scope, fixed: the Session Report titled itself "Stopped (resumable)" and
carried a red "Errors — Sequence cancelled" section. `run_status_presentation.dart`
gains `runWasStoppedByOperator` / `isRunCancellationNotice` /
`runErrorMessagesFor`; the dialog drops the cancellation notice from Errors ONLY
for an operator stop (a failed/aborted run keeps every message) and states the
stop plainly instead.

NOT in scope, still open: the two banner instances ("Sequence failed / Sequence
aborted at <ts>", "Critical - Sequencer / Sequence cancelled") come from
`packages/skotiq_core/lib/src/services/notification/notification_router.dart`
(lines 527 / 590), outside this batch's SCOPE. Recorded for the next wave.

Pins: three cases added to `session_report_dialog_test.dart` (stop ⇒ no Errors
section; stop + real fault ⇒ the fault survives; failed run ⇒ everything kept).

## WD-SEQ-N2 — the builder was unusable at 900px

`_DesktopBuilderLayout` only fell back to the rail layout below
`48 + 300 + 48 = 396px`, so at a 900px window (≈630-740px of pane area after the
nav rail) both side panels kept their min widths and the CANVAS took the
remainder — ~180px. Added `comfortableCenterWidth = 380` and a derived
collapse: toolbox first, then properties, never writing the user-pref providers
so widening restores their saved state.

Pin: `test/screens/sequencer/builder_narrow_desktop_test.dart` — at 900x900 the
`SequenceTree` is ≥ 360px wide; at 1600x900 all three panes stay open.

## WD-SEQ-N3 / NEW-C1 — the palette tab strip

* a11y: each tab label is wrapped in `Semantics(enabled: true, selected: …)`,
  which merges into the tab's own node (Flutter wraps each tab in
  `MergeSemantics`), so the three live tabs stop announcing `[DISABLED]`. Same
  shape as the planner filter-chip fix (a95a1d500). The History rows' status
  badge got the same treatment (`Run status: …`).
* geometry: the strip is now width-aware. Below 240px of strip the scrollable
  TabBar (which HIDES labels rather than resizing — the "\odes" / "Queu" clip at
  a 1000px window) switches to three equal shares with 11px type and 4px label
  padding, and every label is `maxLines: 1` + ellipsis.

Pins: semantics test asserts `SemanticsFlag.isEnabled` on all three labels; a
geometry test asserts each label's rect lies inside the strip's rect at the
1000px repro width.

## SCI-43 — the pre-flight hint named a screen that does not exist

`preflight_rules.dart` sent the operator to "Calibration → Dark Library". The
navigation is Dashboard / Equipment / Imaging / Sequencer / Guiding / Weather /
Plan Tonight / Analytics, and the dark library lives at
Settings → Equipment → Dark Library (`settings_catalog.dart`, group "Equipment",
section key `dark-library`). Both instances (Missing Dark Frames, Low Dark
Library Coverage) reworded.

Pin: added to
`packages/skotiq_core/test/providers/sequence/rules/dark_library_uncooled_camera_test.dart`
— no pre-flight hint may contain `Calibration →`, and any hint naming the Dark
Library must name Settings. Verified RED against the old wording and GREEN after.

## Extra defect found while pinning WD-SEQ-N2

The 900px pin failed on an uncaught `RenderFlex overflowed by 41 pixels`
(69px in the 700px pane) from `target_header_card.dart:352` — the coordinates
row: two monospace chips, an optional rotation chip, a `Spacer` and a priority
badge in one rigid `Row`. Proved pre-existing (identical pixel-for-pixel
overflow with the HEAD copy of the file) and fixed in place: the chips now sit
in a `Wrap` inside an `Expanded`, so they run onto a second line instead of
painting the striped overflow bar over the pointing.

## Verification ladder (every item RED at HEAD, GREEN after)

| item | red-at-HEAD evidence |
|---|---|
| SEQ-18 | retention removed ⇒ `Found 1 widget with text "0 / 4 frames"` |
| SEQ-19 | header string `Exposure: R (current)` does not exist at HEAD |
| SEQ-20 | minutes restored ⇒ `Found 1 widget with text "0m / 0m"` |
| WD-SEQ-N1 | filter removed ⇒ `Found 1 widget with text "Errors"` + `"Sequence cancelled"` |
| WD-SEQ-N2 | `comfortableCenterWidth` 0 ⇒ canvas `Actual: <210.0>` vs `>= 360.0` |
| WD-SEQ-N3 | `enabled: true` removed ⇒ `isEnabled` `Actual: <false>` |
| NEW-C1 | compact mode disabled ⇒ tab-label rect outside the strip rect at 1000px |
| SCI-43 | old wording restored ⇒ hint contains `Calibration →` |

Suites: `packages/skotiq_app` `test/screens/sequencer` — **433 passed, 2
failed**; both failures are `captures_landscape_test.dart` goldens, reproduced
byte-identically (9.44% / 7.17% diff) with the HEAD copy of every file this
batch touched, i.e. the known Windows-captured-goldens-on-Linux debt.
`packages/skotiq_core` `test/providers/sequence/rules` +
`preflight_rules_test.dart` — 124 passed. `flutter analyze` clean on every file
touched.

## Test-run note

The skotiq_app suite could not be compiled for long stretches of this batch:
other agents were mid-edit in shared packages, producing transient compile errors
in files this batch never touched (`skotiq_core/.../annotation_pipeline.dart`,
`.../sequence_editor/tree_editing.dart`, `.../target_catalog_coordinate_sync.dart`,
`skotiq_planetarium/.../time_control_panel.dart`). Results recorded in the
structured output reflect the runs that completed.
