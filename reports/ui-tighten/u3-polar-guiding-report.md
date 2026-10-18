# u3-polar-guiding: Polar alignment and Guiding tightening

Base: `058091ee7` (verified with `git rev-parse HEAD` before any change).

Evidence came from widget-test renders of the real screens. Each render was
pumped at 1646x960, which is the screen's share of the owner's 1920x1080
window once the 274px navigation rail and the top bar are taken off. The
renders used the shipped fonts and seeded providers. Before/after PNGs are in
`reports/ui-tighten/u3-polar-guiding/`. I did not launch the desktop app.
A real simulator TPPA run cannot get past its first plate solve on this
machine, because no solver is installed (`astap`, `astap_cli` and
`solve-field` are all absent). The running states were instead driven through
the screen by backend events, the same `PolarAlignmentStatus` and
`PolarAlignment` events the native run emits. See the "simulated run" test.

## Polar alignment (a15)

| # | Finding | Reproduced? | Change | Where |
|---|---|---|---|---|
| 1 | Two header rows (tabs and chips on a second ~60px row) | Yes | The TPPA and All-sky tabs moved into the PageHeader tab slot, and the Camera and Mount chips lead the header actions. The redundant "Three-Point (TPPA)" context line is gone, because the selected tab already names the method. Below 1200px of header width, the tabs and chips share one strip under the header instead of overflowing. Phones keep PageHeader's own tab row. | `polar_alignment_screen_parts/_screen_shell.dart` `_buildHeader` / `_buildHeaderFor` |
| 2 | Bare back arrow between the title and History | Yes | Back is now a labeled ghost header action, the same shape the Darkroom editor uses. The shell has no back affordance and the route is pushed from Imaging and Sequencer, so I kept it. Under 1200px it becomes an icon button. | same |
| 3 | Bullseye 120" ring label clipped at the column edge | Yes. The radius was half the short side minus 20px, but the label is drawn 4px outside the ring and is wider than the 16px left over. | The outer radius now reserves the measured label width (`polarBullseyeOuterRadius`) and is capped at 300px. The painter is inset by `spaceLg`. | `_error_visualization.dart` |
| 4 | Az/Alt/Total readout clipped at the bottom; TOTAL label lower | Yes. The readouts were top-aligned in a centered Wrap, and Total is the larger value. | The row is bottom-aligned with fixed shares (3:3:4), so all three labels share a baseline and the values no longer slide sideways as they change width. It is capped at 560px. On narrow columns it falls back to an end-aligned Wrap. | `_right_panel.dart` `_buildErrorValues` |
| 5 | Two explanations (bullseye paragraph and center card) | Yes | Removed the idle bullseye paragraph. The checklist is now the only explanation, and its last step says "The bullseye then tracks the error while you adjust." | `_right_panel.dart`, `_center_panel.dart` |
| 6 | "Connect the camera and the mount" still open with both chips green | Yes | That step now uses `ChecklistStepState.done` when both devices are connected. The pointing steps cannot be verified, so they stay open. | `_center_panel.dart` `_buildSetupInstructions` |
| 7 | Three thin columns with empty bottom halves | Yes | At idle, the banners and checklist head the settings column (360px), and the error display takes the rest of the width (`PolarAlignmentBodyLayout` with a null center). Once a run starts, the center column holds the live frame. On compact layouts at idle, the empty "Guide" tab is dropped. The logical tab indices stay stable, so the History toggle still lands on Settings. | `polar_alignment_body_layout.dart`, `polar_alignment_screen.dart` |
| 8 | Running states | Yes, several (listed below) | See below. | |

Item 8, running states. Each was found in renders and then fixed:

- **The progress rail cut off its last step ("Adjust").** Its minimum width was the window's width, not the column's, so the rail was centered on a point off the column's right edge. It now uses the column's width. (`_center_panel.dart` `_buildProgressSteps`)
- **Live phases were always stacked inside a scroll view.** The scroll gave them unbounded height, so the side-by-side branch never ran. The result was a 560px frame with its card below it, scrolled, with empty bands either side. The live phases now fill the column: the frame is Expanded and a 220px card sits beside it. They stack and scroll only when the column is under 520px wide or 320px tall. (`_center_panel.dart`, `_measurement_panel.dart`)
- **The side cards were stretched to the frame's height**, leaving mostly empty space. They are now content-sized at the top and scroll if needed.
- **There were duplicates:**
  - a second, unscaled bullseye was drawn over the star frame (removed, along with its painter);
  - the error numbers appeared three times: the center card's Total, the right readouts, and a left-column guidance card with both directions. The center card keeps the directions plus the "1/4 turn" magnitude hint, the right column keeps the readouts, and the left guidance card is gone;
  - the measuring card repeated the rail's point list (removed). Its activity line now leads, with the status or solve timer as the detail.
- **The bullseye did not move for a typical first measurement.** The marker was clamped per axis to ±120", so every larger error sat on the same 45° corner, outside the outer ring. The ring scale now steps from 120" through 4', 10', 20', 40', 2°, 4°, 10° and 20° to the finest scale that contains the marker (`polarBullseyeOuterScaleArcsec`, `polarBullseyeRingLabel`). Rings are colored by their real value, and past the coarsest scale the marker clamps radially. This is the "graphics don't show or do anything" complaint: for any error over 2' the marker never moved. I'm flagging it because it goes slightly beyond pure layout.
- **In the wide idle all-sky view, the readout row was pushed ~500px off screen.** The error column sized from intrinsic heights, and the all-sky reticle reports its width as its height. The target now reports only its 160px floor (`_IntrinsicHeightFloor`).
- **The History toggle scrolled to the column's end on the first frame.** The guide now makes that column longer, so the toggle scrolls to the panel itself (`Scrollable.ensureVisible`) and retries while a compact tab is still sliding in.

## Guiding (a05)

| # | Finding | Reproduced? | Change | Where |
|---|---|---|---|---|
| 9 | Nested scroll of full-width ~45px buttons, with Dither below the fold | Yes. The nested card padding left 234px, under the 260px pair threshold, so every pair stacked. | `GuideControlsPanel` lost its card chrome, its own scroll view and the "more below" fade. Buttons are rows of equal cells (`_buttonGrid`): Stop, Pause and Loop on one row, Auto select and Deselect on the next. Cells are 32px on desktop and the platform touch minimum on touch devices. The grid wraps to fewer columns below 80px per cell. The "Loop exposures" label shortened to "Loop", and the semantics label and tooltip keep the full name. | `lib/widgets/phd2/guide_controls_panel.dart` (used only by the Guiding screen) |
| 10 | Empty gap above Brain settings | Yes. Controls, calibration and the Brain button were 3:2 flex slots. | They are now one column at natural heights, scrolling as a whole and top-aligned. With Brain open, the column shares the panel with the editor, 2:3. The mobile Controls tab also dropped its fixed 60/40 boxes. | `guiding_screen_parts/desktop_sections.dart`, `mobile_sections.dart` |
| 11 | Guide star says "Waiting for image..." while PHD2 loops | Yes, as a data bug. | `StarImageNotifier` started polling only on a change of PHD2 state, and it is first created when the Guiding screen opens. Opening the screen onto a loop that was already running never polled. Fixed with `fireImmediately`. The provider is now also `autoDispose`, so it stops polling PHD2 twice a second once nothing shows the image. Tests that seed a looping or guiding PHD2 now close the screen and container before they end. Not checked against live PHD2. A provider test shows the poll starts, and it fails without the fix. | `packages/skotiq_core/lib/src/providers/guiding_provider/star_image_and_history.dart` |
| 12 | Fixed heights in the left cards | No | Guide star and Target display are square `AspectRatio` wells, and Star statistics sizes to its content. None of the three has a fixed height. The space under the column is the column's remaining height next to the full-height graph, not dead space inside a card. No change. | |

## Shared code touched

- `skotiq_core` `starImageProvider` is now `StateNotifierProvider.autoDispose`, and its state listener uses `fireImmediately`. Its only consumer is the Guiding screen. Call sites are unchanged.
- `skotiq_app/lib/widgets/phd2/guide_controls_panel.dart`: the public `GuideControlsPanel.moreBelowKey` was removed together with the nested scroll it marked. Its only consumer is the Guiding screen.
- No `skotiq_ui` changes.

## Tests

New:
- `test/screens/polar_alignment/polar_alignment_tight_layout_test.dart` covers:
  - the header row;
  - connect-step done and open states;
  - the instructions stated once;
  - the bullseye and labels fitting at 1920x1080 (including all-sky);
  - a simulated run driven by backend events, where the readouts, rail and scale follow every measurement;
  - the scale and label helpers.
- `test/widgets/phd2/guide_controls_panel_compact_grid_test.dart` replaces the overflow-affordance test, whose nested scroll no longer exists. It asserts no inner Scrollable, everything laid out, one row at 32px on desktop, the touch minimum on Android, wrapping at narrow width, and the full semantics label for Loop.
- `test/screens/guiding/guiding_side_panel_layout_test.dart` asserts no inner scroll in the controls, and that calibration and Brain settings follow without a gap.
- `skotiq_core/test/providers/backend_swap_event_rebind_test.dart` adds "a star image is polled when PHD2 is already looping". The late-image test now keeps the auto-disposed provider watched, and asserts it is the same notifier, so it cannot pass trivially.

Updated:
- `polar_alignment_solve_defaults_test.dart`: scrolls the collapsible into view first, because the checklist now heads that column.
- `guiding_loop_frame_count_test.dart` and `guiding_no_measurement_readouts_test.dart`: close the screen and container at the end, so the star-image poll stops.

## Commands

All commands ran with `TMPDIR=$HOME/.cache/ns-tmp/u3-polar-guiding`.

| Command | Exit | Result |
|---|---|---|
| `git rev-parse HEAD` | 0 | `058091ee7` |
| `melos bootstrap` | 0 | 11 packages |
| `melos run analyze` | 0 | SUCCESS, no errors or warnings |
| `dart format --output=none --set-exit-if-changed packages/skotiq_app packages/skotiq_core` | 0 | Clean |
| `cd packages/skotiq_app && flutter test --exclude-tags golden --concurrency=4` | 0 | 4544 passed |
| `cd packages/skotiq_core && flutter test --exclude-tags golden --concurrency=4` | 1 | 1 failure, unrelated and load-dependent (below) |
| `cd packages/skotiq_core && flutter test test/database/integrity_check_test.dart` | 0 | 22 passed in isolation |
| `cd packages/skotiq_app && flutter test --tags golden --concurrency=4` | 0 | 23 passed |
| `cd packages/skotiq_core && flutter test --tags golden --concurrency=4` | 0 | 1 passed |

The one full-suite core failure is in `test/database/integrity_check_test.dart` ("a hot rollback journal is replayed, not treated as corruption"). It touches no file I changed, and it passes on its own. It is load-dependent, not a regression from this branch.

**Goldens broken by this change: none.** Both packages' golden suites pass. The Guiding golden (`guiding_panel_builtin_golden_test.dart`) covers the Imaging guiding panel, which this branch does not touch.

## Left undone

- No live-app or on-sky check. A real TPPA simulator run needs a plate solver, which this machine lacks. The star-image fix is verified only at the provider level, not against PHD2.
