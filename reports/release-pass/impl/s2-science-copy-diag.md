# Stage-2 batch: science-copy-diag

Items: SCI-42, SCI-46 (diagnostics half), SCI-43, SCI-36 (remainder).
Branch state: worked against HEAD with other Stage-2 agents live in the tree.

## SCI-42 — Session Report printed one warning twice — FIXED

Root cause held at HEAD. `_buildPostSessionHealthSummary`
(`skotiq_core/lib/src/providers/sequence/sequence_executor/session_diagnostics_operations.dart:388-394`)
copied `SequenceRunStats.warningMessages` into
`PostSessionHealthSummary.noticedConcerns`, and `postsession_rules.dart:146`
renders every entry as a "Noticed but Did Not Fire" diagnostic. The report
dialog renders BOTH: `report.warningMessages` under "Warnings"
(`session_report_dialog.dart:200,564`) and the post-session diagnostics block
below it (`session_report_dialog.dart:295`), so every warning appeared twice in
one dialog.

Fix at the source: the executor no longer feeds `noticedConcerns` at all, and
the doc comment now states the invariant (`noticedConcerns` is for concerns the
report does not already print; nothing added there may exist in
`warningMessages`). The rules-side rendering is untouched — it is correct for
any future non-warning concern. `postSessionHealthSummaryProvider` has exactly
one consumer (the report dialog), so nothing else loses information; the
warnings themselves are unaffected (they are persisted per run and still
rendered verbatim).

Test: `skotiq_core/test/providers/sequence/sequence_executor_lifecycle_test.dart`
— "post-session summary does not restate the run warnings". Failed at HEAD with
the two seeded warnings present in `noticedConcerns`; green after. It also
asserts `postSessionEquipmentHealthSummary` emits no "Noticed but Did Not Fire"
issue, so a re-introduction anywhere on that path fails the test.

## SCI-46 diagnostics half — quick captures were undiagnosable — FIXED

Loop/quick captures open no `imaging_sessions` row, so the science pipeline
writes their PSF tiles and residual vectors with a NULL `session_id`
(`science_processing_service.dart:381-398` passes the nullable `sessionId`
straight through). The Diagnostics picker listed `allSessionsProvider` rows
only, so that data was unreachable — with no sessions at all the header even
collapsed to "No sessions available".

The core already had the readers: `sessionlessPsfTilesProvider` /
`sessionlessResidualVectorsProvider` (used by the Science tab and live preview).
The fix is entirely in `screens/diagnostics/**`:

* `_kQuickCaptureSessionId = -1` sentinel (negative, cannot collide with an
  auto-increment session id) in `diagnostics_screen.dart`.
* The tab watches the two sessionless providers and offers a
  "Quick captures (no session)" entry — first in the list — only when one of
  them actually has rows; a bucket that empties clears the selection.
* `_SessionSelector` renders the dropdown when sessions are empty but quick
  captures exist, and accepts the sentinel as a value.
* `_DiagnosticsContent` switches PSF/residual sources on the sentinel and runs
  `OpticalTrainDiagnosticsService.analyze` with the same error → loading → data
  precedence as `opticalTrainDiagnosticsProvider`; Retry invalidates the
  sessionless streams.

Test: `test/screens/diagnostics/diagnostics_quick_capture_test.dart` (2 cases).
Case 1 failed at HEAD (no entry; the screen sat on "Select an imaging session to
analyze"), case 2 pins that the entry is NOT offered when there is nothing to
diagnose. Note for whoever drives this live: the picker renders only the
selected entry/hint while closed, so the menu must be opened to see the item.

Known limit, deliberate: quick-capture frames that produced no science products
(science disabled, or nothing solved) still get no entry — there is nothing to
analyze, and offering an empty bucket would be a second false promise.

## SCI-43 — wizard half FIXED, Pre-Flight half BLOCKED (out of scope)

`quick_start_wizard_dialog/_target_step.dart:236` told an operator with an empty
target library to "Save targets from Sky or Planner". Neither label exists:
`ShellNavigation` names the destination "Plan Tonight" (`navPlanner`), and Your
Sky / Constellation are tabs inside it. The control that actually writes a
library row is Add target on Plan Tonight ▸ Projects
(`planner/widgets/projects_tab_content/project_dialogs.dart:143` →
`targetLibraryService.ensureCatalogTarget`). Copy now reads "Add one from Plan
Tonight ▸ Projects, or enter RA/Dec below."

Test: `test/screens/sequencer/quick_start_wizard_target_destination_test.dart`
— drives the wizard with an empty library, fails at HEAD on "Sky or Planner".

BLOCKED — Pre-Flight's "create a master dark from Calibration → Dark Library"
lives in `skotiq_core/lib/src/providers/sequence/rules/preflight_rules.dart:246`
(a `resolutionHint`), outside this batch's SCOPE. It is wrong the same way:
there is no "Calibration" destination, and Dark Library is its own Settings
section — the dialog's own button goes to `/settings?section=dark-library`
(`preflight_validation_dialog.dart:830`). Suggested replacement:
"…then create a master dark from Settings ▸ Dark Library."

## SCI-36 remainder — bare InkWells — FIXED

* `mosaic_projects_list_screen.dart` "< Back" row — wrapped in
  `Semantics(button: true, enabled: true)` (same recipe as the verified
  session-review chip fix).
* `diagnostics_screen/header_widgets.dart` `_DocsInfoChip` "Learn more about
  optical diagnostics" — same.

Tests: a semantics case added to
`test/screens/mosaic/mosaic_projects_list_back_label_test.dart` and to
`test/screens/diagnostics/diagnostics_screen_test.dart`; both failed at HEAD on
the missing `isButton` flag. They assert role + tap action + enabled, matching
the existing `accessible_dropdown_test.dart` house style (`hasFlag`, which
carries a deprecation info repo-wide).

## Verification

* `skotiq_core`: `sequence_executor_lifecycle_test.dart` (19) +
  `postsession_rules_test.dart` — green.
* `skotiq_app`: `test/screens/diagnostics/` (minus goldens), full
  `test/screens/mosaic/` (60), quick-start-wizard + wizard-authority +
  session-report suites (22) — green.
* `dart analyze` on the touched lib/test dirs: no errors; only pre-existing
  infos plus the `hasFlag` deprecation infos noted above.
* `dart format` applied to the one file it changed
  (`diagnostics_screen/content_layout.dart`); nothing else reformatted.

PRE-EXISTING, not mine: `test/screens/diagnostics/captures_landscape_test.dart`
golden failures (1.49% / 1.40% pixel diff). Verified by restoring the three HEAD
versions of the diagnostics files, re-running, and getting the identical
failures, then restoring the working-tree versions.
NOT MINE, seen in the tree while working:
`skotiq_core/test/providers/sequence/sequence_executor_live_stacking_autofeed_test.dart`
fails to compile against another agent's in-flight `LiveStackingService`
(`autoStretchPreview` / `saveMaster`), and `framing_provider/support.dart`
briefly referenced a not-yet-existing `RememberedSensorSpec`.
