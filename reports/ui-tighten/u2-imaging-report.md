# u2-imaging: Imaging screen tightening pass

Base: `058091ee7` (verified with `git rev-parse HEAD` before starting).

Area: `packages/skotiq_app/lib/screens/imaging/` (live view, its overlays, the
viewer toolbar, the right-hand panel tabs), from shots a03, a16 and a17. One
small data fix sits outside the screen, in `skotiq_core` (finding 12).

## How the findings were checked

Every finding was reproduced in a widget-test render of the real
`ImagingScreen` at the owner's canvas size (1646 × 1000 logical px: the
1920 px window minus the navigation rail), with the owner's state seeded: a
connected ASI1600 at −10 °C, a tracking NYX-101, an EAF at 45484 / 600000 and
10.7 °C, a meridian flip armed 3 h 6 m out, and a frame with HFR 16.29, ECC
0.15, 105 stars, median 528 and mean 534. The render harness lived in an
uncommitted scratch test. Before and after crops are in
`reports/ui-tighten/u2-imaging/`.

One caveat on the shots: the owner's side panel measures about 398 px, while
this code's `ShellChromeMetrics.sidePanelWidth` is 320. The ratio, about 1.24,
holds across the whole window, so the owner's display is most likely scaled
by about 125%. Layout decisions here are made against the 320 px panel (244 px
of content, 216 px inside a section card), which is what the code lays out.
They scale unchanged.

## Findings

| # | Finding | Reproduced? | What changed | Where |
|---|---|---|---|---|
| 1 | Stats card (top-left) and frame-info pill (top-right) are two glass panels | Yes | Both are replaced by one `FrameInfoPill` at the top left: status dot, frame identity ("L · 2.0 s", or the frame type for non-light or unfiltered frames), time, `HFR 16.29`, `105 stars`, then the frame's badges (raw-load state, Calibrated, verdict). Eccentricity, median and mean are in the pill's tooltip. A value the frame did not measure is left out rather than dashed. The top-right corner is now free, so the Narrator / Science HUD column moves up to the canvas inset. The annotation mini chips moved below the pill; before, they overlapped the old stats card. | `widgets/imaging_hud.dart:25`, `widgets/live_preview_area.dart:722` |
| 2 | Histogram covers the bottom right of the image by default | Yes | The histogram is off by default and opt-in under Overlays → Histogram. The choice is stored in SharedPreferences (`imaging.previewHistogramVisible`) and restored on launch. "Readouts" now covers only the pill and the bottom-left chips. The compass and scale-bar clearances follow each corner separately. | `widgets/preview_histogram_visibility.dart`, `widgets/imaging_preview_toolbar.dart:563`, `widgets/live_preview_area.dart:780`, `widgets/live_preview_area/preview_overlays.dart` |
| 3 | REJECT is a floating chip at bottom left | Yes | The verdict renders inside the pill as `SubQualityVerdict`, graded by the same extracted `_grade` function the badge uses. `SubQualityBadge` is no longer placed on the canvas. | `widgets/sub_quality_badge.dart`, `widgets/live_preview_area.dart:753` |
| 4 | "Stretch: off" appears in both the histogram and the capture bar | Yes | The histogram's stretch caption is removed. The capture bar's Stretch toggle is the one place it is shown. | `widgets/imaging_hud.dart` (`HistogramHud`) |
| 5 | The calm meridian-flip banner is about 85 px tall and pushes the view down | Yes | First checked how the banner's states are modeled. `MeridianCountdownState` has: not armed, armed against a tracking limit (no countdown), a countdown of 10 min or more (info), under 10 min (warning), and imminent (warning). There is no manual or failed state; a failed flip is reported by the flip itself (progress dialog and notifications). The info states now render as a compact `MeridianFlipChip` in the toolbar row ("Flip in 3h 6m" or "Flip armed"), and the full explanation plus pier side are in its tooltip and semantics label. The banner renders only the warning states (under 10 min and imminent), and its dismissal logic is unchanged. Both widgets own their own 15 s ticker through a shared mixin. | `widgets/meridian_flip_countdown_banner.dart:207, 382, 565`, `widgets/imaging_preview_toolbar.dart:209` |
| 6 | "Sky —" shows in the toolbar with no value | Yes | The Sky segment is omitted while there is no sky reading. | `widgets/imaging_preview_toolbar.dart:292` |
| 7 | Step size chips wrap as 10 / 50 / 100 with 500 alone on a second row | Yes | Replaced by `_StepSizeSegments`, one row of four equal-width segments with button and selected semantics. The label is "Step size" (sentence case, no colon). | `widgets/focus_panel.dart:286, 698` |
| 8 | Go To Position and Run Autofocus are both filled primary buttons | Yes | Go To Position is now the outline (secondary) variant. Run Autofocus is the tab's one primary action. | `widgets/focus_panel.dart:305` |
| 9 | Label and field alignment, and section spacing, on the Focus tab | Yes: the step-size label sat outside the label column, gaps were 20 / 16 / 12 / 4 in raw numbers, and the heading read "Temperature Compensation" while the others are sentence case | The step-size row uses the same `panelRowLabelFlex` / `panelRowControlFlex` split as the Autofocus rows, so the two "Step size" labels share one column. Section gaps are `SidePanel.sectionGap`, matching the Camera and Mount tabs. Inner gaps are tokens. The heading is now "Temperature compensation". | `widgets/focus_panel.dart` |
| 10 | Mount actions stack as Park, Stop tracking, Abort slew, with Park first | Yes | Actions is now two compact rows of small buttons: [Stop / Start tracking · Abort slew] then [Park / Unpark · Polar alignment]. The new `_ActionPairs` gives a pair equal halves when each label fits half the row, proportional widths when only the pair fits, and stacks otherwise. At 216 px every pair shares a row; at the 160 px floor the pairs stack. Abort slew keeps its destructive face. | `tabs/mount_tab.dart:226, 451` |
| 11 | The Alignment card holds a single Polar alignment button | Yes | The card is removed. Polar alignment is the fourth cell of the Actions grid. | `tabs/mount_tab.dart` |
| 12 | Pier shows "—" while the mount tracks | Yes, and it was a data bug | `MountStateNotifier._pollPosition` read `status.sideOfPier` on every poll and never copied it into `MountState`, so `sideOfPier` was null for every mount. That also blanked the flip banner's pier chip and stopped its "pier side changed, new cycle" dismissal reset from ever firing. The poll now maps East / West, or clears the value on Unknown (new `MountState.copyWith(clearSideOfPier:)`, mirroring `clearHorizonFrame`). The Mount tab leaves the Pier readout out entirely when the side is unknown. | `skotiq_core/lib/src/providers/equipment/mount_state_provider.dart:280-293`, `skotiq_core/.../camera_and_mount_states.dart`, `tabs/mount_tab.dart:578` |
| 13 | Camera tab: the "Save to" path is truncated with no tooltip; empty space at the bottom; vertical rhythm | Partly | `ReadOnlyField` gained `showFullValueOnHover`, set for the save folder and the file-name pattern, which was truncated the same way ("$TARGET_$FILTE…"). The rhythm was already consistent (`SidePanel.sectionGap` between sections, `FormRow.rowGap` between rows), so it is unchanged. The space at the bottom is where the scrolling panel's content ends. Filling it would mean adding content, which this pass rules out. | `widgets/panel_widgets.dart` (`ReadOnlyField`), `widgets/capture_panel.dart:265, 283` |

### Kept on purpose

- The bottom-left corner still holds `FrameScienceChip` (it appears only for
  photometrically calibrated frames and links to Science) and
  `GuidingActiveChip` (it appears only while PHD2 is guiding, settling, or has
  lost lock). Both hide themselves when they have nothing to show, so most
  frames leave the corner empty. Folding guiding into the pill as well is a
  possible next step if the owner wants the corner always clear.
- The imaging tour's "Histogram" step targets the histogram's tutorial key.
  With the histogram off, the tour's existing missing-target logic skips the
  step instead of pointing at nothing. The "Image statistics" step now
  highlights the pill, which exists once a frame is on screen.

## Tests

Updated to the new layout (no assertions weakened):

- `test/screens/imaging/frame_stats_hud_identity_test.dart` was moved with
  `git mv` to `frame_info_pill_test.dart` and rewritten for the pill. It
  covers stale-stat clearing, the identity format, values left out rather
  than dashed, and the verdict inside the pill with no floating badge.
- `imaging_capture_truthfulness_test.dart`: the readouts that never self-hide
  are now the pill.
- `imaging_screen_test.dart`: with no frame, the stats tutorial key is absent.
- `imaging_preview_toolbar_test.dart`: the new Readouts description, plus a
  new test that Sky is hidden without a reading.
- `tabs/mount_tab_label_fit_test.dart`: the action-order and pair layout
  tests replace the old stack-at-220 and share-at-430 tests.
- `widgets/focus_panel_temp_comp_test.dart`: the sentence-case heading.
- `widgets/meridian_flip_countdown_banner_test.dart`: banner content tests
  now use attention-grade countdowns. A calm countdown and a tracking-limit
  arm now assert an empty banner. A new `MeridianFlipChip` group covers the
  chip-versus-banner choice: far-off shows the chip, under 10 min shows the
  banner, imminent shows the banner, tracking-limit shows "Flip armed", and
  not armed shows neither.

New:

- `test/screens/imaging/preview_histogram_toggle_test.dart`: off by default,
  persistence across instances, a choice made during hydration is not
  overwritten, the Overlays → Histogram row turns it on and stores it, and the
  histogram does not repeat the stretch state.
- `test/screens/imaging/tabs/mount_tab_pier_side_test.dart`
- `test/screens/imaging/widgets/focus_panel_layout_test.dart`
- `test/screens/imaging/capture_panel_path_tooltip_test.dart`
- `skotiq_core/test/providers/mount_side_of_pier_poll_test.dart`

## Commands run

All runs used `TMPDIR=$HOME/.cache/ns-tmp/u2-imaging`.

| Command | Exit | Result |
|---|---|---|
| `git rev-parse HEAD` | 0 | `058091ee7` |
| `melos bootstrap` | 0 | |
| `flutter test --exclude-tags golden --concurrency=4 test/screens/imaging test/widgets/go_to_position_dialog_test.dart` (baseline, before any change) | 0 | 399 passed |
| `flutter test --exclude-tags golden --concurrency=4` in `packages/skotiq_app` | 1 | 4554 passed. The only 3 failures were the uncommitted scratch render harness (`test/u2_scratch`, a pending-timer teardown assertion after the PNG was written). It was deleted before committing, and no committed test failed. |
| `flutter test --exclude-tags golden --concurrency=4` in `packages/skotiq_core` | 0 | 6885 passed, 4 skipped |
| `melos run analyze` | 0 | No errors or warnings. Pre-existing infos only. |
| `dart format --output=none --set-exit-if-changed packages/skotiq_app packages/skotiq_core` | 0 | |
| `flutter test --tags golden --concurrency=4` in `packages/skotiq_app` | 0 | 23 passed |
| `flutter test --tags golden` in `packages/skotiq_core` | 0 | 1 passed |

### Golden tests broken by this change

None. No golden PNG was created, deleted or regenerated.

### Shared components touched

None in `skotiq_ui`. Everything changed is inside `screens/imaging/`, except
the `skotiq_core` side-of-pier fix (finding 12). That fix is backward
compatible: `MountState.copyWith` gained an optional `clearSideOfPier`
flag. `sideOfPier` now actually carries "East" or "West", and it also feeds
the dashboard mount card, the equipment device card and the sequencer
telemetry strip, which until now always showed their unknown state.

## Left undone

- Finding 13: the empty space at the bottom of the Camera tab is where the
  panel's content ends, so it is left as is. Filling it would mean adding
  content.
- Copy that is shared with other widgets was left alone: "Run Autofocus"
  (shared with `FocuserControls` and its tests) and "Go To Position..."
  (which matches the dialog title).
