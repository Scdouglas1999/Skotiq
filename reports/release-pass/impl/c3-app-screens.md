# Wave C3 — mechanical file splits — batch `app-screens`

Scope: `packages/skotiq_app/lib/screens/**`, threshold 1000 lines (Dart).

## Result

At HEAD, 44 non-generated files under `screens/` were ≥ 1000 lines.
**After this batch: 0.** Largest remaining file under `screens/` is
`mosaic/mosaic_project_screen.dart` at 991 lines (already under threshold at HEAD,
not touched).

`dart analyze` on `packages/skotiq_app`: **0 errors, 0 warnings** (74 `info`
diagnostics, all pre-existing `deprecated_member_use` / one doc-comment info,
none introduced by this batch — they are the same diagnostics on the same code,
relocated).

Tests: `flutter test --exclude-tags golden` in `packages/skotiq_app` —
**3301 passed, 0 failed**. That is the exact command `melos run test` issues
(`melos.yaml:318`). No test file was edited; not even an import line needed
changing, because parts inherit the parent library's imports.

A bare `flutter test` (no tag filter) is *not* the gate and does not pass at HEAD
either: `test/screens/analytics/captures_landscape_test.dart` is `@Tags(['golden'])`,
hangs for its full 10-minute timeout, and then poisons every subsequent test in the
shard with `'!inTest': is not true` — 2 real failures plus a 40-test cascade. That
file is excluded by `--exclude-tags golden` by design (`packages/skotiq_app/dart_test.yaml`,
`docs/testing/golden-tests.md`). Confirmed unrelated to this batch: the cascade
victims (`test/widgets/**`, 289 tests) all pass when run as their own directory.

## Mechanism

Every split is a verbatim line-range move into a Dart `part` file, following the
convention already used in this package
(`planner_screen.dart` → `planner_screen_parts/*.dart`,
`science_analytics_tab.dart` → `science_analytics_tab/*.dart`).

Each part file opens with

```dart
// Part of ../<parent>.dart -- extracted for maintainability.
//
// <one line saying what lives here>
part of '../<parent>.dart';
```

Because parts share the library scope, **no import changed, no symbol was renamed,
and no member visibility was widened**. Private classes, private members and
library-private top-level functions stay exactly as visible as they were.

Three shapes were used:

1. **Top-level declarations** (most files): whole `class` / `enum` / `typedef` /
   provider / function declarations moved verbatim.
2. **Members of one giant `State` / `StateNotifier` class**: moved into
   `extension _X on _FooState { ... }` inside the part file — the idiom already
   present at `planetarium_screen/actions.dart:3` and
   `connected_device_card/dialogs_and_settings.dart:3`.
3. **Members of a mixin** (guiding screen only): moved into a sibling `mixin`,
   the idiom already present at `guiding_screen_parts/mobile_sections.dart:6`.

## Recorded deviations from a pure verbatim move

These are the only edits outside "cut lines, paste lines, add `part` directive":

| Where | Edit | Why |
|---|---|---|
| 14 new extension part files | added `// ignore_for_file: invalid_use_of_protected_member` (and, for the two `StateNotifier` parts, `invalid_use_of_visible_for_testing_member`) | `setState` / `StateNotifier.state` are `@protected`; the analyzer does not treat an extension as "inside the class" even in the same library. This is the repo's existing answer to the same problem — see `equipment/dialogs/profile_editor_dialog/*.dart:1`, four files that already carry this exact ignore for this exact reason. |
| `guiding/guiding_screen_parts/desktop_sections.dart:7` | `on ConsumerState<GuidingScreen>, _GuidingStateFields` → `..., _GuidingActions` | the extracted mixin must be a superclass constraint so the remaining desktop builders can still call the moved helpers |
| `guiding/guiding_screen.dart:52` | added `_GuidingActions,` to the `with` clause, before `_GuidingDesktopSections` | apply the new mixin; ordering matches the existing `_GuidingStateFields` → `_GuidingDesktopSections` → `_GuidingMobileSections` chain |

No logic edits, no renames, no signature changes, no test edits.

## Constraints discovered (they shaped several split boundaries)

Four Dart rules forced some members to stay in the parent class. Each was found by
`dart analyze`, not by guessing:

1. **`static` members cannot move into an extension** — a `static` member of an
   extension must always be qualified, so both moved and unmoved call sites break.
   Statics stayed in the class, and any method that referenced a static
   *unqualified* stayed with them.
   - `session_review_controller.dart`: `_filterMatches`, `_safeName`,
     `_suffixBeforeExtension`, `_swapExtension` and `_integrate`,
     `_loadDefaultSettings` stayed.
   - `science_export_hub.dart`: `_buildSessionFilter` stayed.
   - `centering_dialog.dart`: `_buildStatusSection` stayed (`_formatRa`/`_formatDec`).
2. **Two extensions on the same type cannot see each other's private members.**
   All private helpers of one class therefore go into *one* extension.
3. **Extensions cannot declare instance fields** — `mosaic_wizard_dialog.dart`'s
   `_cachedGeometry` / `_cachedGeometryKey` stayed in the class.
4. **`@override` members cannot move** (`super` is illegal in an extension) —
   `dispose` stayed in `_QuickStartWizardDialogState`.

## Files split

`parent — HEAD lines → now (parts created)`

### Pure top-level moves
- `settings/settings_screen.dart` — 1286 → 415 (`settings_screen_parts/`: `_search_index`, `_desktop_layout`, `_mobile_layout`)
- `imaging/widgets/guiding_panel.dart` — 1286 → 419 (`guiding_panel_parts/`: `_builtin_guider_config`, `_guide_graph_and_stars`)
- `imaging/widgets/calibration_section.dart` — 1193 → 196 (`calibration_section_parts/`: `_status_blocks`, `_build_controls`, `_correction_settings`)
- `framing/widgets/framing_controls.dart` — 1181 → 185 (`framing_controls_parts/`: `_rotation_fields`, `_fov_controls`, `_mosaic_controls`)
- `sequencer/widgets/run_dashboard/live_frame_panel.dart` — 1140 → 228 (`live_frame_panel_parts/`: `_viewer`, `_badges`, `_history`, `_inspect_dialog`)
- `shell/app_shell.dart` — 1106 → 677 (`app_shell_parts/`: `_startup_checkpoint`, `_mobile_settings_bar`)
- `settings/pairing_screen.dart` — 1372 → 698 (`pairing_screen_parts/`: `_notifier`, `_dialogs_and_banners`)
- `onboarding/onboarding_screen.dart` — 1255 → 667 (`onboarding_screen_parts/_chrome`)
- `stack_result/stack_result_screen.dart` — 1084 → 866 (`stack_result_screen_parts/`: `_export_seams`, `_support_widgets`)
- `session_review/widgets/sub_cull_rail.dart` — 1063 → 413 (`sub_cull_rail_parts/`: `_toolbar`, `_tiles`, `_thumbnails`)
- `settings/widgets/location_settings.dart` — 1047 → 885 (`location_settings_parts/_timezone_data`)
- `settings/widgets/cloud_sync_settings.dart` — 1144 → 642 (`cloud_sync_settings_parts/_remote_sync`)
- `settings/widgets/calibration_library_settings.dart` — 1139 → 605 (`calibration_library_settings_parts/_tiles_and_preview`)
- `settings/widgets/dark_library_settings.dart` — 1033 → 768 (`dark_library_settings_parts/_tiles`)
- `framing/widgets/framing_canvas.dart` — 1158 → 597 (`framing_canvas_parts/_canvas_controls`)
- `imaging/widgets/science_hud.dart` — 1095 → 707 (`science_hud_parts/_offers_and_chips`)
- `flat_wizard/widgets/flat_preview_panel.dart` — 1076 → 391 (`flat_preview_panel_parts/`: `_stats_and_status`, `_convergence_and_filters`)
- `suggestions/widgets/transient_alerts_panel.dart` — 1017 → 395 (`transient_alerts_panel_parts/`: `_alert_tiles`, `_settings_dialog`)
- `analytics/widgets/project_tracking_panel.dart` — 1017 → 229 (`project_tracking_panel_parts/`: `_headers`, `_project_card`)
- `analytics/widgets/image_grader_dialog.dart` — 1007 → 463 (`image_grader_dialog_parts/_threshold_controls`)
- `analytics/widgets/image_thumbnail_strip.dart` — 1008 → 291 (`image_thumbnail_strip_parts/`: `_chips`, `_thumbnail`)
- `planetarium/widgets/search_header.dart` — 1055 → 762 (`search_header_parts/_filter_controls`)
- `mosaic/mosaic_project_controller.dart` — 1226 → 782 (`mosaic_project_controller_parts/`: `_state`, `_providers`)

### Files that were themselves `part of` another library
New siblings are `part of` the same root library; the `part` directive was added to
the root library file.
- `sequencer/widgets/sequence_tree/support_widgets.dart` — 1087 → 385 (+ `sequence_tree/tree_controls.dart`)
- `planner/planner_screen_parts/_candidate_list.dart` — 1028 → 436 (+ `_candidate_observing_list.dart`)
- `planner/planner_screen_parts/_filter_controls.dart` — 1022 → 410 (+ `_range_controls.dart`)
- `analytics/widgets/science_analytics_tab/science_cards.dart` — 1028 → 609 (+ `line_ratio_card.dart`)
- `sequencer/widgets/node_properties_panel_parts/_motion_rich.dart` — 1155 → 695 (+ `_motion_flip_and_polar.dart`)
- `sequencer/tabs/sequence_library_tab/sequence_card.dart` — 1037 → 895 (+ `sequence_card_dialogs.dart`)
- `sequencer/widgets/sequence_tree/node_item.dart` — 1043 → 716 (+ `node_item_helpers.dart`, extension)
- `equipment/widgets/connected_device_card/dialogs_and_settings.dart` — 1213 → 721 (+ `motion_dialogs.dart`, extension)
- `planetarium/planetarium_screen/actions.dart` — 1016 → 660 (+ `sheets.dart`, extension)
- `guiding/guiding_screen_parts/desktop_sections.dart` — 1399 → 927 (+ `actions.dart`, mixin)

### State / StateNotifier member extractions
- `session_review/session_review_controller.dart` — 1940 → 931 (`session_review_controller_parts/`: `_models`, `_state`, `_helpers`)
- `analytics/widgets/science_export_hub.dart` — 1368 → 676 (`science_export_hub/`: `datasets`, `hub_state_helpers`)
- `settings/catalog_settings_screen.dart` — 1354 → 702 (`catalog_settings_screen/view_builders`)
- `settings/widgets/log_viewer.dart` — 1215 → 552 (`log_viewer_parts/`: `_export_seams`, `_actions`, `_controls`)
- `settings/widgets/autofocus_settings.dart` — 1014 → 534 (`autofocus_settings/`: `mobile_layout`, `filter_settings_builders`)
- `imaging/centering_dialog.dart` — 1001 → 577 (`centering_dialog/section_builders`)
- `sequencer/widgets/smart_night_dialog.dart` — 1069 → 555 (`smart_night_dialog/plan_helpers`)
- `sequencer/widgets/preflight_validation_dialog.dart` — 1215 → 469 (`preflight_validation_dialog/section_builders`)
- `sequencer/widgets/mosaic_wizard_dialog.dart` — 1193 → 598 (`mosaic_wizard_dialog/wizard_logic`)
- `sequencer/widgets/quick_start_wizard_dialog.dart` — 1239 → 740 (`quick_start_wizard_dialog/_wizard_helpers`)
- `analytics/widgets/science_analytics_tab.dart` — 1242 → 859 (`science_analytics_tab/tab_sections`)

(Line counts above are pre-`dart format`; the formatter changed 14 files by a line
or two of blank-line normalisation.)

## Out of scope / untouched
- `localization/skotiq_localizations/translations.dart` (1486) — map report
  `app-screens-b` §1.2 lists it, but it is under `lib/localization/`, not
  `lib/screens/`, so it belongs to another batch.
- Headless API handlers — belong to the `apps-shells` batch.
- No generated file, FRB binding or pending-deletion file was touched.
