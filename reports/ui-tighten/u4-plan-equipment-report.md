# u4-plan-equipment: UI tightening report

Area: Plan (Tonight list, Framing, Target Centering dialog), Equipment > Devices, Sequencer > Builder.
Base: `058091ee7`. Before/after images are in `reports/ui-tighten/u4-plan-equipment/`. The "before" images are crops of the owner's shots (a00, a04, a06, a07). The "after" images are 1920x1080 widget-test renders on the Windows platform (Plan, Centering, Framing, Sequencer) or captures from the release desktop app with simulators on a private Xvfb display (Equipment).

## Findings

| # | Finding | Reproduced? | What changed | Where |
|---|---|---|---|---|
| 1 | Tonight column headers off their values; the selected row's wider button shifts its columns | Yes. In a widget render at 1920x1080, TRANSIT's header sat about 100px right of its values, and the selected row's readouts sat 54px left of the other rows' | `Candidate` takes optional `CandidateColumns` (a fixed readout width and action-slot width). In that mode it reserves the window slot even on rows without a window. The new `CandidateHeader` lays its labels out on the same grid. The planner uses 96px readouts and a 120px action slot. Below a 720px list it falls back to the old content-sized layout and hides the column names | `skotiq_ui/lib/src/components/candidate_row.dart:205,231`; `skotiq_app/lib/screens/planner/planner_screen_parts/_candidate_list.dart:18,193` |
| 2 | Rows about 80px tall | Yes (70px on desktop at 1x; the owner's shot is larger) | `Candidate(dense: true)` uses 8px vertical padding. Rows are now 62px on desktop and stay two lines | `candidate_row.dart` (`dense`, `densePadding`); `_candidate_list.dart` |
| 3 | Detail preview is a large dark box; the facts list is cut off at the footer | Partly. The list was not under the footer: it scrolls inside an `Expanded` above it, but the 150px preview pushed the last facts below the fold | Preview well 150 -> 96px, so the facts list clears the Frame it / Build sequence footer at 1080p. The well still shows only the target's extent; there is no survey image to load here | `_primary_target_card.dart:28` |
| 4 | Framing button stuck on "Working..." after an aborted centering run | Yes, in a widget test (Slew & Center, Start, Abort, then the result shows and the button still reads Working... and is disabled). It could not be run live because no plate solver is installed on this host (no ASTAP or astrometry.net), so the preflight refuses centering | Cause: `SlewDropdownButton` awaited the centering dialog's close, and the dialog stays open on its result. `CenteringDialog` now reports each run's end (`onRunEnded`, fired from a `finally` around the run). `showCenteringDialog` forwards it, including to a caller that reopens an existing dialog. The button releases on run end or dialog close, whichever comes first | `skotiq_app/lib/widgets/slew_dropdown_button.dart:293`; `screens/imaging/centering_dialog.dart:32,534`; `centering_dialog/presentation.dart:12` |
| 5 | "Framing checks and manual solve" wraps onto two lines in a large font | Yes | Renamed to "Checks and manual solve". The title uses the eyebrow style like "Utilities", with zero tile padding, a dense/compact tile, and a 48px minimum height | `screens/framing/widgets/framing_sidebar/mosaic_and_actions.dart:345` |
| 6 | Centering dialog: letterboxed image, floating size badge, empty right column | Yes (the image box was 400px tall over a 314px frame, and the dialog stood taller than its status column) | The image pane is an `AspectRatio` of the frame's width and height, top-aligned with `heightFactor: 1`, under the same 200-400px height cap. The overlays (crosshair, size badge, crosshair toggle) now sit on the image, and the dialog hugs its content | `screens/imaging/centering_dialog/section_builders.dart:69` |
| 7 | About 90px of dead space above the profile card | Yes, live in the simulator once the readiness list is short. Cause: `SidePanel`'s `Row` centers its child on the cross axis, and a `SingleChildScrollView` shorter than the panel shrinks to its content | Local fix: the Equipment side panel wraps its scroll view in `Align(topCenter)`. The shared `SidePanel` is unchanged | `screens/equipment/equipment_screen/layout_rail.dart:142` |
| 8 | Device-card action rows at slightly different heights | No. With the simulator camera, mount and focuser, all three action rows render at the same y. The owner's shot differs by about 2px and comes from real-hardware readout content (the camera's readouts sit 2px higher, not the focuser's) | No change | — |
| 9 | Dead space in the discovery footer, Profiles and Optical train tabs | Discovery footer and Profiles tab: nothing worth changing. Optical train: the Save button sat in the window's bottom-right corner, about 1100px from the 720px form above it | The Optical train page puts Save under the form, right-aligned to it. Profiles keeps its pinned footer, since its form is long | `screens/equipment/dialogs/profile_editor_dialog.dart:393` |
| 10 | Node palette cards about 70px tall with two-line descriptions | Yes | One-line description with an ellipsis, wrapped in `SkotiqTooltip` carrying the full text. Vertical padding 8 -> 6, top margin 6 -> 4. Row pitch is now about 52px, so roughly twice as many nodes fit | `screens/sequencer/sequencer_screen_parts/node_palette.dart:304` |
| 11 | Inspector column with nothing selected | Checked. The empty state is centered in the column. Below `breakpointDesktop`, `autoCollapseEmptyProperties` already collapses the empty column to its strip | No change (as the brief asked, the selected-node behavior is untouched) | — |
| 12 | Step table header shown over an empty sequence | Yes | `_LedgerColumnHeader` renders only when the root has children | `screens/sequencer/widgets/sequence_tree.dart:962` |

## Shared-component change (please note for the merge)

`Candidate` in `skotiq_ui` gained two optional, backward-compatible parameters, `columns` and `dense`, plus public constants (`padding`, `densePadding`, `outlineWidth`, `windowBarWidth`) and two new types, `CandidateColumns` and `CandidateHeader`. With the defaults, the Darkroom landing and the design-system gallery render exactly as before; the old private `_windowBarWidth` is now `Candidate.windowBarWidth` with the same value.

## Tests added or updated

- `skotiq_app/test/screens/planner/candidate_columns_alignment_test.dart`: for every row, each column's x equals its header label's x (transit, imageable, window), and the action slot's right edge is the same on every row, including the selected "Image tonight" row. A second test checks that rows are 56-64px on Windows and keep two lines.
- `skotiq_ui/test/components/observatory_surfaces_test.dart`: shared `CandidateColumns` line a `CandidateHeader` and three rows up, with different buttons and one row without a window.
- `skotiq_app/test/widgets/slew_dropdown_button_test.dart`: "an aborted centering run gives the button back while its result stays on screen". It fails on the old code (Working... still found) and passes now.
- `skotiq_app/test/screens/sequencer/builder_palette_density_test.dart`: one-line description, a tooltip with the full text, a row pitch of 56px or less, and no column header until the first step.

## Commands and exit codes

| Command | Exit |
|---|---|
| `melos bootstrap` | 0 |
| `flutter build linux --release` (apps/desktop, twice) | 0 |
| `melos run analyze` | 0 |
| `dart format --output=none --set-exit-if-changed packages/skotiq_app packages/skotiq_ui` | 0 (2109 files, 0 changed) |
| `flutter test --exclude-tags golden --concurrency=4` in `packages/skotiq_ui` | 0 (577 passed) |
| `flutter test --exclude-tags golden --concurrency=4` in `packages/skotiq_app` | 0 (4537 passed) |
| `flutter test --tags golden --concurrency=4` in `packages/skotiq_ui` | 79 (no tests carry the golden tag) |
| `flutter test --tags golden --concurrency=4` in `packages/skotiq_app` | 1 (see below) |

## Golden failures caused by this branch

- `skotiq_app/test/screens/framing/framing_registration_test.dart`: "framing_canvas_golden: the composed survey background + co-registered FOV reticle renders pixel-stably under rotation" (`goldens/framing_canvas_registered.png`, 4.84% diff). It passes with the Framing sidebar and slew button files reverted to the base, so the shorter sidebar expander changes this capture. No golden was regenerated.

## Left undone or out of scope

- Finding 4 was verified by widget test only. A live repro needs a plate solver, and this host has none.
- Finding 8 did not reproduce, so the device cards are unchanged.
- In the Plan detail column, the "Why ... was chosen" rationale list leaves a blank band above its first row in the widget render. I did not investigate it, because it depends on the optimizer's rationale strings and is not a spacing change.
