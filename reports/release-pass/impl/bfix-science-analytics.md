# B-fix batch: science-analytics

Items: SCI-46, SCI-44, SCI-36, SCI-37, SCI-38, SCI-41, SCI-27, SCI-28, SCI-22, SCI-48,
SCI-34, SCI-42, SCI-43, SCI-47.

Scope: packages/skotiq_app/lib/screens/{analytics,science,session_review,stack_result}/**
plus named core services.

## Log

### Claimed files
- packages/skotiq_core/lib/src/services/frame_quality_assessment_service.dart
- packages/skotiq_app/lib/screens/analytics/widgets/{image_thumbnail_strip,frame_detail_dialog,science_solve_rate_card}.dart
- packages/skotiq_app/lib/screens/analytics/analytics_screen/{session_tab,history_tab,history_cards}.dart
- packages/skotiq_app/lib/screens/session_review/session_review_screen.dart

### SCI-37 + SCI-38 — DONE
Root: `FrameQualityAssessment.reasons` holds every observation, including ones
that never moved the verdict; both surfaces joined it onto the label with a dash
("Good — Low star count (39)"). And `advisoryScore` = recorded quality_score
minus review penalties (85 - 10 = 75), so the tile's "75 score" and the DB's
"85.38" were both "the score".
Fix: `summaryLine` + `scoreExplanation` + `recordedQualityScore` on the
assessment; tile now reads "Advisory 75"; inspector prints both scores as named
rows and the explanation under the verdict.
Tests: core/test/services/frame_quality_summary_line_test.dart (5),
app/test/screens/analytics/widgets/frame_score_labels_test.dart (2). Both failed
first. Thumbnail-rail regression suite green.

### SCI-41 — FALSE POSITIVE at HEAD
narrative_view already computes `_integrateBlockedReason`, prints it as the empty
state body, tooltips it on the button and passes `onPressed: null`. Existing test
test/screens/session_review/narrative_integrate_blocked_test.dart is green at HEAD.
The audit even quotes the FIXED copy ("This session captured no light frames, so
there is nothing to integrate"). The a11y half is a HARNESS artifact:
drive_linux.py only prints [DISABLED] for nodes that are focusable/selectable/
checkable, and a disabled SkotiqButton drops `focusable`
(FocusableActionDetector(enabled:false)) — so a correctly-disabled button can
never show [DISABLED] in that dump. SkotiqButton does emit
Semantics(button: true, enabled: false).

### SCI-22 — DONE
ScienceSolveRateCard is now a ConsumerWidget watching `plateSolverDetectionProvider`.
The zero-solve message branches on the probe: no solver -> "No plate solver is
installed…"; solver present -> "…a solver (ASTAP, catalog V17) is installed — so
it is running and failing, not missing. Check focal length and pixel scale
first…"; probe unanswered -> neutral, blames nothing.
Test: app/test/screens/analytics/widgets/science_solve_rate_reachable_test.dart (3),
failed first (old string present). Existing science_solve_rate_card_test.dart green.

### SCI-44 — DONE
ROOT CAUSE (not what the report guessed): the app theme sets
`hoverColor: colors.surfaceHover` — an OPAQUE tone — so the InkWell hover overlay
painted right over the selected chip's `colors.primary` fill. The pointer rests on
whichever chip was just clicked, which is exactly the symmetry the report saw.
Measured from w2-29a-tab-workbench.png: selected chip = (33,38,48) = #212630 =
surfaceHover, text = (10,12,15) = onPrimary; unselected = #181C22 surfaceAlt with
#9AA3AD text. Fixed in scope by giving the chip's InkWell a translucent
`hoverColor` (its own foreground at 8%), plus Semantics(button/selected/enabled)
so the tree stops reporting `panel: Workbench` with no state.
NOTE for the skotiq_ui / A11Y-STATE batch: `hoverColor: colors.surfaceHover`
in skotiq_theme.dart:205 is opaque and will erase the fill of EVERY
selection-coloured InkWell in the app. Out of my scope; recorded here.
Test: app/test/screens/session_review/view_toggle_selection_test.dart (3).
Whole session_review suite green (86).

### SCI-34 — DONE
Session tab's empty state was `analyticsNoSessionHistory` /
`analyticsNoSessionHistoryDesc` — History's copy verbatim. Now "Nothing captured
yet" / "Start a capture or a sequence and this tab fills in as the frames arrive."
Test: session_vocabulary_test.dart case 1 + updated assertion in the existing
session_tab_empty_state_test.dart (which had pinned the defect).

### SCI-46 — DONE (History half; Diagnostics half out of scope)
Loop captures land in captured_images with no session_id and no imaging_sessions
row, so History and the Diagnostics picker could not see them while
Analytics ▸ Session was displaying them. History now carries a
`_QuickCaptureHistoryCard` entry: frame count, integration, time span, and an
explicit statement that these frames have no run record (so no status/target/
per-run diagnostics) plus where to review them. It is suppressed by the time
filter only — it has no name or target to filter on — and the "No session
history" empty state now requires BOTH lists to be empty.
Also refactored the time predicate into `_matchesTimeFilter` so the card and the
session list can never disagree about "This Month".
Test: session_vocabulary_test.dart cases 2-4 (3 failed first).
OPEN, OUT OF MY SCOPE PATH: Analytics ▸ Diagnostics' "Select session" dropdown
(screens/diagnostics/**) still offers only imaging_sessions rows, so optical
diagnostics remains unreachable for a quick-capture night.

### SCI-43 / SCI-15 — PARTIAL (the one instance inside my scope)
Fixed: the Captured Images caption said "Science > Grade frames is what rejects
frames". The bulk grader is the "Grade N frames" button on
**Analytics ▸ Science ▸ Field Quality** (science_analytics_tab.dart:833). Caption
now names that. Rendered as a literal at the session_tab call site rather than
editing lib/localization (outside scope) — `analyticsQualityAdvisory` is now an
unused key in translations.dart (en + es); the localization owner should retire
or correct it.
Test: added assertions to session_tab_advisory_caption_test.dart.
OUT OF SCOPE: SCI-43's own two instances are in the Quick-Start Wizard
("Save targets from Sky or Planner") and Pre-Flight ("Open Calibration → Dark
Library"), both under screens/sequencer/**.

### SCI-36 — PARTIAL
- FIXED in scope: the Session Review Narrative/Workbench chips (`panel: … ` with
  no state) now carry Semantics(button/enabled/selected). See SCI-44.
- COVERED BY COMPONENT (A11Y-STATE batch): the History "All Time" / "All Targets"
  chips and their menu items are `SkotiqDropdown`
  (analytics_screen/history_tab.dart:93-104) — one component, both instances.
- OUT OF SCOPE PATH, same defect shape (a bare InkWell with no Semantics), exact
  locations for whoever owns them:
    * screens/mosaic/mosaic_projects_list_screen.dart:161 — the "‹ Back" InkWell.
    * screens/diagnostics/diagnostics_screen/header_widgets.dart:10 — the
      "Learn more about optical diagnostics" InkWell (_DocsInfoChip).
  Both need Semantics(button: true, enabled: true) around the InkWell, exactly
  like the toggle chip fix.

### BLOCKED — out of my scope paths, with root cause identified
- **SCI-27 (black stacked preview)** — ROOT CAUSE FOUND. The preview uses a
  LINEAR MIN/MAX stretch: `stackedPreviewGrayRgba` /
  `stackedPreviewColorRgba` in
  screens/imaging/widgets/stacking_panel/stacked_preview.dart:178,211. On a real
  star field max is a saturated star (65535) and min is ~0 sky, so every
  background pixel and every faint star maps to 0-3 — an almost entirely black
  rectangle with two or three bright dots, which is exactly what the report
  photographed. Fix = a percentile/midtone (STF-style) stretch: clip at ~the
  0.1st/99.5th percentile and apply the app's existing midtone transfer, or
  asinh. Both functions are already `@visibleForTesting`, so the fix is
  unit-testable directly (synthetic frame: sky 1000 ± 50 plus one 65535 star →
  assert the sky pixels land well above 0).
- **SCI-28 (Stop destroys the stack, nothing on disk)** — the stop path is
  stacking_panel.dart → liveStackingProvider → `LiveStackingService.stop()`
  (core/lib/src/services/live_stacking_service.dart:363), which calls
  `apiStackingStop()` and releases the native stacker without first reading the
  result. `getCurrentResult()` exists and would give it. Fix = snapshot the
  result before releasing, persist it (StackShareExportService already owns the
  PNG write path), surface the path in the panel, and make Stop distinct from the
  existing Reset Stack. I did NOT make stop() persist unilaterally: without the
  panel change the app would write files the user is never told about, which is
  the same class of defect.
- **SCI-47 (frames vs pixels in one Statistics list)** — stacking_panel.dart
  ~514-570. Needs unit suffixes ("frames" / "px") and a visual break between the
  frame-count rows and the pixel-count rows.
- **SCI-42 (Session Report prints one warning twice)** — ROOT CAUSE: 
  `_buildPostSessionHealthSummary` sets
  `noticedConcerns = stats.warningMessages`
  (core/lib/src/providers/sequence/sequence_executor/session_diagnostics_operations.dart:393)
  and postsession_rules.dart:146 turns every one of them into a "Noticed but Did
  Not Fire" diagnostic — the same list the report already renders under
  Warnings, so the duplication is structural, not a data accident. Fix = feed
  noticedConcerns only the triggers that were EVALUATED AND DID NOT FIRE, or
  de-dup against the warnings the dialog already shows.
- **SCI-48 (astap .ini debris in the capture folder)** — the scratch files are
  written by the native solver invocation
  (native/skotiq_native/imaging/src/platesolve.rs); ASTAP writes its .ini
  beside the input FITS. Fix = solve from a temp copy / -o into a scratch dir and
  clean up. Rust, outside my scope.

### Test status
- skotiq_core: frame_quality_score / frame_quality_assessment_service /
  frame_quality_summary_line — 26 green.
- skotiq_app: `flutter test test/screens/analytics/ test/screens/session_review/`
  — 320 pass, 1 fail: `captures_landscape_test.dart` golden, 74.98% pixel diff.
  PRE-EXISTING and ENVIRONMENTAL, not mine: sibling golden suites for screens I
  never touched fail the same way on this machine (weather 46.77/47.72/45.63%,
  guiding 13.71/11.77/17.74%). Repo goldens are Windows-captured; standing rule
  is not to regenerate them on Linux.
- dart analyze on lib+test for analytics/session_review and the two core files:
  0 issues. dart format applied to the 14 files I touched, nothing else.
