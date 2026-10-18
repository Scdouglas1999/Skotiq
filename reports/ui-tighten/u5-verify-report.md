# u5-verify: the tightening pass at the owner's 1536x864 window

Base: `63ed52883` on `rebrand/skotiq` (checked with `git rev-parse` before starting).

The owner's laptop is a 1920x1080 panel at 125%, so the app gets a 1536x864 logical window. The u1 to u4 agents checked their work at 1920x1080 logical. This pass rendered every tightened screen at 1536x864 and fixed what broke.

## How it was checked

- **Full desktop shell in widget tests.** A scratch harness (not committed) pumped the real `appRouterProvider` (the `ShellRoute` and `AppShell`) at 1536x864, DPR 1, with the rail expanded (220 px). It used the shipped fonts and seeded the rig: every device connected, PHD2 guiding or looping, the camera at -10 °C, a 4656x3520 frame, and a meridian flip armed 3 h 6 m out. 25 scenarios ran. Every FlutterError was collected per scenario, and each render was saved as a PNG and looked at. Polar alignment was driven through idle, measuring and adjusting by backend events. The centering dialog was driven through a run to its result.
- **Release app.** `flutter build linux --release`, with the shared `libskotiq_bridge.so` copied in, run under `xvfb-run -s "-screen 0 1536x864x24"` with a scratch `HOME`, `SKOTIQ_DATABASE_DIR` and `user-dirs.dirs`. The run skipped onboarding, expanded the rail, and visited Tonight, Imaging, Sequencer, Guiding, Plan, Equipment, Weather, Darkroom, Analytics and Settings. Nothing clipped, and `app.log` has no overflow or exception lines. Only my own pid was killed. This build predates the two clock fixes at the end; the layout fixes are all in it.
- About 30 downscaled images were viewed in total.

## Screens

| Screen | Result | Where |
|---|---|---|
| Tonight: hero line | Fine | |
| Tonight: night band legend | **Fixed.** The labels ran together ("21:14 sunset22:38 astro dark", and the same at dawn). A middle label is now dropped when it would come within 12 px of its neighbor. Astro dark and dawn stay drawn as dashed lines, and the hero line still states them. | `packages/skotiq_ui/lib/src/components/night_band.dart:433`, `:448` |
| Tonight: preview card sized to the frame | Fine. A 4656x3520 frame gets a 4:3 card, and Equipment takes the rest. | |
| Tonight: compact progress and guiding cards | Fine ("Looping exposures, not guiding" and "No sequence loaded" are each one line) | |
| Analytics: session header and the single empty state | Fine, both with no session and with a reviewed session that had 3 rejected frames | |
| Darkroom: default tab | Fine | |
| Weather header | Fine. The actions sit at the right edge. | |
| Settings page titles | Fine | |
| Command palette height | Fine. It shrinks to its results. | |
| Imaging: info pill, histogram toggle, flip chip, Focus and Mount tabs | Pill, toggle, chip and both tabs are fine | |
| Imaging: viewer toolbar | **Fixed.** The bar got 972 px and needed about 1000 with a flip armed and an exposure in flight, so Abort capture sat past the right edge of a scrolling bar. Below 1100 px, Annotate and Mark region show only their glyphs, with their names in tooltips and semantics. Mark region now uses a dashed selection box (`boxSelect`) instead of the crosshair that the Crosshair toggle also uses. The live-stack Mark region matches it. | `packages/skotiq_app/lib/screens/imaging/widgets/imaging_preview_toolbar.dart:79`, `:207`, `:394`; `live_stack_canvas.dart:222` |
| Imaging: bottom-left Guiding chip | **Fixed.** The centered capture bar drew over it ("Guiding RMS 0.", with the value hidden under Snapshot). The stack measures itself and steps up over the bar when the space beside the bar can't hold it, the same rule the histogram already followed. The scale bar and the compass clear a raised corner by the same amount. `MeasuredWidth` moved out of the capture bar into its own file so both can use it. | `packages/skotiq_app/lib/screens/imaging/widgets/live_preview_area.dart:108`, `:579`, `:827`; `widgets/measured_width.dart` |
| Polar alignment: tabs in the header | Fine. The content is 1308 px wide, which is above the 1200 px fallback. | |
| Polar alignment: idle (instructions, settings, bullseye) | Fine. The bullseye and its readouts fit. | |
| Polar alignment: measuring and adjusting | **Fixed.** The center column is about 496 px wide, under the 520 px side-by-side threshold, so the frame stacked as 4:3. That pushed the Adjust card's threshold bar and "Adjust to threshold" line below the fold. With a known column height, the card now keeps its natural height and the frame takes the rest, down to 200 px. Unbounded or short columns scroll as before. | `packages/skotiq_app/lib/screens/polar_alignment/polar_alignment_screen_parts/_measurement_panel.dart:47`, `:59` |
| Polar alignment: rescaling bullseye | Fine (10' scale for a 6' error) | |
| Guiding: compact control grid and side column | Fine, both guiding and looping | |
| Plan: Tonight list columns, 96 px preview, detail column | Fine. The list is about 890 px wide, so the fixed columns apply and line up. | |
| Plan: window column after midnight | **Fixed** (found by the gate, below) | `packages/skotiq_app/lib/screens/planner/planner_screen_parts/_candidate_list.dart:471` |
| Framing sidebar | Fine | |
| Centering dialog | Fine. Mid-run, the image pane takes the frame's aspect ratio inside the 864 px window. | |
| Equipment: right panel | Fine | |
| Equipment: device grid | **Fixed** (this predates the tightening pass). The filter wheel card's `SkotiqDropdown` measured itself through a bare `LayoutBuilder` inside the grid's `IntrinsicHeight` rows. In debug that raised 45 errors on Devices; in release it counted as zero height. The select now wraps its `LayoutBuilder` in a `SizedBox` of its fixed box height. | `packages/skotiq_ui/lib/src/components/skotiq_dropdown.dart:163` |
| Sequencer: dense palette and hidden step header | Fine, with a loaded sequence and with an empty one | |

## Found by the gates, not by layout

The suites were first run after midnight, and two clock-dependent failures showed up. Both were real bugs, so I fixed them rather than waiting for the clock to move past them:

- **Plan ▸ Tonight window column** (`candidate_columns_alignment_test` failed at 00:06). The night window was computed from today's date, so after midnight every row was placed on the next night and a target setting at 08:00 drew no window. It now uses yesterday's night while that night's dawn is still ahead, which is the rule the twilight provider behind Tonight already follows. The test's targets now span any night, so it no longer depends on the hour it runs.
- **Weather: park before dawn with no site** (6 tests in `weather_source_unreachable_test` and `weather_auto_resume_authority_test` failed at about 00:20). With no observing site the settings read 0°, 0°, and the check measured dawn on Null Island. The release app on its fresh scratch profile showed the toast "Astronomical dawn is approaching". The check now does nothing until a site is set. `packages/skotiq_core/lib/src/providers/weather_safety/weather_safety_executor_push.dart:267`

## Regression tests

Each fix has a test that fails on the old code (checked by reverting the fix and rerunning the test):

- `packages/skotiq_app/test/screens/imaging/imaging_owner_window_layout_test.dart` (new): pumps Imaging at 1308x774 with the shipped fonts, a flip armed, an exposure in flight and PHD2 guiding. It checks that the toolbar has no scroll extent and Abort capture is present, that the Guiding chip doesn't overlap the capture bar, and that `takeException()` is null.
- `packages/skotiq_app/test/screens/polar_alignment/polar_alignment_tight_layout_test.dart`: a 1308x774 run through measuring and adjusting, where "Adjust to threshold" stays on screen and `takeException()` is null.
- `packages/skotiq_app/test/screens/equipment/equipment_card_grid_height_test.dart`: a filter wheel card with its select in an `IntrinsicHeight` grid row at 1308x774, where `takeException()` is null.
- `packages/skotiq_ui/test/components/kit_gaps_test.dart`: an October night where the colliding middle labels are dropped. The existing "wide band names every event" test was widened to 1900 px, because the test font's square glyphs collide at 1200.
- `packages/skotiq_core/test/providers/weather_park_before_dawn_test.dart`: with no site, 20 minutes before Null Island dawn, the verdict stays safe.
- `packages/skotiq_app/test/screens/planner/candidate_columns_alignment_test.dart`: now independent of the hour it runs.

## Shared code touched

- `skotiq_ui` `NightBand`: its legend measures the labels and drops a middle one that would collide. The existing under-800 px rule is unchanged.
- `skotiq_ui` `SkotiqDropdown`: a fixed-height `SizedBox` around its `LayoutBuilder`. Layout is the same under every constraint; it now also reports an intrinsic height.
- `skotiq_core` weather safety: park before dawn needs a site.

## Gates (final, at HEAD)

All commands ran with `TMPDIR=$HOME/.cache/ns-tmp/u5-verify`.

| Command | Exit | Result |
|---|---|---|
| `melos run analyze` | 0 | SUCCESS |
| `dart format --output=none --set-exit-if-changed packages/skotiq_app packages/skotiq_core packages/skotiq_ui` | 0 | 3968 files, 0 changed |
| `flutter test --exclude-tags golden --concurrency=6` in `skotiq_ui` | 0 | 578 passed |
| `flutter test --exclude-tags golden --concurrency=6` in `skotiq_core` | 0 | 6887 passed, 4 skipped |
| `flutter test --exclude-tags golden --concurrency=6` in `skotiq_app` | 0 | 4588 passed |
| `flutter test --tags golden` in `skotiq_app` | 0 | 23 passed |
| `flutter build linux --release` (apps/desktop) | 0 | |

No golden changed, and none was regenerated.

## Not done

- `test/golden/public_screenshots_test.dart` still captures Equipment on the Profiles tab. Its comment blames the `IntrinsicHeight` error that the select fix removes. I left it alone, because switching tabs would change a published screenshot.
- The scratch render harness was not committed. It is in `$HOME/.cache/ns-tmp/u5-verify/u5_scratch_bak/`.
