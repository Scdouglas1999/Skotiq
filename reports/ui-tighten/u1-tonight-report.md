# u1-tonight: Tonight, Analytics, Darkroom, Weather header, Settings, command palette

Base: `058091ee7` (verified with `git rev-parse HEAD` before starting). Branch `ui-tighten/u1-tonight`.

How each finding was checked:
- **Real app.** `apps/desktop` release build plus the shared `libskotiq_bridge.so`, run under `xvfb-run` at 1920x1080 with a scratch `HOME` and `SKOTIQ_DATABASE_DIR`. Used for Weather, Settings and the palette, which need no rig state.
- **Widget renders at 1648x1080.** That is 1920 minus the nav rail. A scratch render test, not committed, seeded the rig's evening state: all devices connected, PHD2 looping, nothing loaded, a 4:3 frame, and a failed session with 3 rejected lights. Used for Tonight and Analytics.

Before and after PNGs are in `reports/ui-tighten/u1-tonight/`.

## Findings

| # | Finding | Reproduced? | Change | Where |
|---|---|---|---|---|
| 1 | Gap between the page header and the hero | Yes. A 20 px top gap under a 56 px header that already centres its title. | Top gap is now `spaceSm` (8). | `skotiq_app/lib/screens/dashboard/dashboard_screen.dart:38` |
| 2 | "New Sequence · 0 nodes · ~0 m" with nothing loaded | Yes, in code. A fresh sequence's `nodes` holds the invisible root, so `nodes.isNotEmpty` was true. | The sequence fact appears only when `visibleInstructionCount > 0`. The dark and moon facts are unchanged. With nothing loaded, the line falls back to the designed site-coordinates fact. | `tonight_hero.dart:250` |
| 3 | Preview card wider than its frame, with black bands | Yes. A 4:3 frame at 300 px in a c8 card left about 280 px of black on each side. | New `DashboardWidgetDefinition.preferredWidth`. The preview asks for its frame's width at 300 px, with a floor of 30% of its span. `TonightGrid` gives the unused width to the other tiles in the row in proportion to their spans, so Equipment gets it. Turned off while editing the layout and in the single-column layout. With no frame, the card keeps its full span. | `tonight_grid.dart:97`, `tonight_preview_panel.dart:37`, `dashboard_widget_registry.dart:146` |
| 4 | Progress with no sequence: 0% ring, "No per-filter plan", a row of dashes | Yes | When the hero state is `nothingRunning` and nothing has been integrated, the card shows one line, "No sequence loaded", plus a ghost **Open Sequencer** button. It is under 120 px tall. | `tonight_progress_panel.dart:69` |
| 5a | Guiding says "Idle" while PHD2 loops | Yes. The panel read only `isGuiding`. | The chip says **Looping** (with a dot) when `phd2StateProvider == looping`. When not guiding and there are no graph points, the card is one line ("Looping exposures, not guiding", "No guide data yet" or "Connect a guider…") with no empty chart and no row of dashes. | `tonight_guiding_panel.dart:34` |
| 5b | Equipment value columns offset between rows (EFW, PHD2) | Yes. Readouts were start-aligned while sitting at the row's right edge. | The equipment readouts are end-aligned, so every value shares the row's right edge. **Shared change:** `Readout` gains `alignment` (defaults to `start`, so existing callers are unchanged). | `skotiq_ui/lib/src/components/readout.dart:43`, `tonight_equipment_panel.dart` |
| 6 | Analytics "Reviewing" bar repeats the SESSION card | Yes | The review picker is now the session panel's header, placed inside the panel with no separate bar. The duplicated title and date subtitle are gone in picker mode, and the status moves to a chip in the panel head. Live sessions and the no-picker case keep their title and subtitle. | `session_tab.dart:341`, `_SessionReviewBar.framed` |
| 7 | Four empty chart cards of about 250 px each | Yes | If no accepted light frame has HFR, guiding RMS, focuser position or temperature, one line replaces the grid, for example "No accepted light frames to chart · 3 excluded (rejected or calibration)". A single value brings the four charts back. **Other tabs:** History, Projects, Equipment and Diagnostics don't have this pattern. In Science, the Night story with no events showed a count strip ("No events yet this session.") and filter chips above its empty state; it now shows the empty state alone. | `session_tab.dart:265`, `:476`; `night_story_timeline.dart:285` |
| 8 | Darkroom opens on "Recipes 0" | Yes, in code (the default was hard-coded to recipes) | Until the operator picks a tab, the landing shows the first tab with content (Recipes, then Sessions, then Masters), and falls back to Recipes when all are empty. Nothing was persisted before this change, so there was no stored choice to respect; a pick made on the current visit is kept. | `darkroom_screen_parts/_landing.dart:115` |
| 9 | Weather header actions float mid-header | Yes. In the app at 1920 the chip sat at about x = 1200. Cause: a `Flexible` chip shared free space with the title's `Expanded`. | The chip is `Flexible` only below the shell breakpoint, where it still needs to ellipsize. The new test fails on the old code (settings button right edge 1202 vs > 1856). | `header_and_radar_controls.dart:42` |
| 10 | Settings title block oversized and content x off | Partly. The content column's x is set by the 240 px nav column, which is intended. The real issue was a second page-scale title ("General" at 20/600 under "Settings") and a page that started one row below the nav's search field. | The `SettingsPage` title is now `sectionTitle`. Desktop padding is `settingsPagePadding` (32 horizontal, 12 top, matching the nav column), and the gap after the lead line is 16 instead of 20. Catalogs, Logs, the merged pages (Files & storage, Autofocus), Observing lists and Observation log use the same title style and padding. I checked Autofocus, Catalogs and Sequencer in the app: section spacing (24 between panels) looked reasonable, so I left it. | `settings_page_states.dart:42`, `:94`; `merged_sections.dart`; `catalog_settings_screen*.dart`; `log_viewer.dart` |
| 11 | Palette keeps a fixed height | Yes | The results `ListView` shrink-wraps inside the existing 420 px cap. | `command_palette.dart:316` |
| 12 | Near-duplicate settings results | Yes. "If the last polar alignment is older than" was the first literal of the row's `subtitle:`, which the index generator matches because `subtitle:` ends in `title:`. | The generator now records, per section, each indexed description's own row title (`kSettingsSearchRowTitles`). The palette lists a row once, under its title, whichever one matched; the description stays as a keyword so it still finds the row. Also fixed in the generator: `_enclosingCall` blanked string literals to `''`, so the offset it returned was wrong. Literals are now blanked to the same length. | `tools/production/settings_search_index_gen.dart`, `command_sources.dart:165` |

## Other things I found and fixed
- The generated settings index was already stale at base. It also wasn't `dart format`-clean, so `dart format --set-exit-if-changed` on `skotiq_app` failed at base. The generator now formats its output for its own package before writing or comparing, so `--check` and the format gate agree.
- Science ▸ Night story: removed the double empty message (see #7).

## Shared or cross-area changes (worth checking at merge)
- `skotiq_ui` `Readout.alignment` (optional, defaults to start, backward compatible).
- `DashboardWidgetDefinition.preferredWidth` (optional) and `TonightGrid` is now a `ConsumerWidget`.
- `settings_search_index.g.dart` is regenerated and now formatted. If another branch adds a settings row, regenerate after the merge: `dart run tools/production/settings_search_index_gen.dart`.

## Not done or left alone
- The Science tab has a picker bar ("Analysing …") plus a "Reviewing stored results" banner, the same shape as #6. It is Science-screen territory and wasn't on my list, so I left it.
- Catalogs content has no 880 px max width, unlike other settings pages. I left it because this is a layout pass, not a re-layout.
- Pre-existing failure: `settings_search_index_gen_self_test.dart` fails "resolves labels past a closed nested call" ('Global minimum exposure (s)' is in neither the base index nor mine). It is unrelated to this change.
- On-sky or real-rig check of Tonight with PHD2 looping: verified only by widget render and tests.

## Golden tests
- `skotiq_app`: `flutter test --tags golden --concurrency=4` → exit 0, 23 passed. These are review captures, not pixel diffs, so none fail. The PNGs they write that are affected by this change are `desktop-dashboard.png` (Tonight) and `analytics.png`, `settings-equipment-profiles.png` (title style). They are only written with `SKOTIQ_CAPTURE_ASSETS=1`, and I did not regenerate them.
- `skotiq_ui`: `flutter test --tags golden` → exit 79, "No tests match the requested tag selectors". The package has no golden-tagged tests.

## Commands and exit codes
All commands ran with `TMPDIR=$HOME/.cache/ns-tmp/u1-tonight`.
- `git rev-parse HEAD` → `058091ee7` (0)
- `melos bootstrap` → 0
- `cd apps/desktop && flutter build linux --release` → 0 (twice: once before the changes, once after)
- `dart run tools/production/settings_search_index_gen.dart --check` → 1 at base (stale), 0 after regeneration
- `dart run tools/production/settings_search_index_gen_self_test.dart` → 1, with one pre-existing failure (see above)
- `melos run analyze` → 0
- `dart format --output=none --set-exit-if-changed lib test` in `skotiq_app` → 0 after the generator formats its output (at base, 1 because of the unformatted `.g.dart`); in `skotiq_ui` → 0; on the generator tool → 0
- `flutter test --exclude-tags golden --concurrency=4` in `skotiq_app` → 0 (4,546 passed)
- `flutter test --exclude-tags golden --concurrency=4` in `skotiq_ui` → 0 (576 passed)
- Golden runs as above.

## Tests added or updated
- `test/widgets/command_palette_results_test.dart` (new): the panel shrinks to its results, and a row is listed once whether its title or its description matched.
- `test/screens/weather/weather_screen_responsive_test.dart`: the header actions sit at the right edge at 1920. This test fails on the old code.
- `test/screens/darkroom/darkroom_screen_test.dart`: with no recipes the landing opens on the first tab with content, and an explicit pick is kept.
- `test/screens/dashboard/tonight_hero_facts_test.dart`: an empty sequence adds no sequence fact.
- `test/screens/dashboard/tonight_panels_tighten_test.dart` (new): the Looping chip and the one-line guiding state, the compact Progress state, the shared right edge for equipment values, and the preview sized to its frame with the rest going to Equipment.
- `test/screens/analytics/session_tab_tighten_test.dart` (new): one session header, one compact chart state, and the charts coming back for a single value.
- `test/screens/analytics/quick_capture_reachable_test.dart`: now asserts the picker's value rather than the title text the merged header removed.
- `test/screens/analytics/widgets/night_story_timeline_test.dart`: an empty feed shows the empty state alone.
- `test/screens/settings/settings_page_title_test.dart` (new): the page title is a section title, level with the search field.
