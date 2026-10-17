# Batch: a11y-design-system (A11Y-STATE class)

Scope: `packages/skotiq_ui/**`, `packages/skotiq_app/lib/widgets/**` + owning test dirs.

## Root cause established (measured, not read)

A scratch probe (`test/components/interactive_semantics_probe_test.dart`, since deleted and
replaced by the pinned contract test) dumped the real semantics tree for every shared component.

- The harness prints `[DISABLED]` when a node is focusable/selectable/checkable **and** lacks
  the AT-SPI `enabled` state. Flutter publishes `SemanticsFlag.isEnabled` **only when a widget
  passes `enabled:` explicitly**, so any control whose semantics come from a bare `InkWell` /
  `GestureDetector` (tap action, no flags) is announced as a disabled panel while working.
- Flutter's `_DropdownMenuItemContainer` (dropdown.dart:821) declares `button: true` and never
  an enabled state — the framework source of every `[DISABLED]` dropdown entry and of the closed
  control that renders the chosen item.
- `SemanticsConfiguration.isCompatibleWith` splits two fragments that set the SAME flag into two
  nodes. That is why an outer `Semantics(button: true)` around Material's dropdown produced a
  second, empty `push button` node — the wrapper must supply only the flags the framework does
  not.
- `PopupMenuItem` already declares `role: menuItem, enabled:, button:` — popup menus are NOT part
  of this family.

## Fixed in skotiq_ui

| Component | Before | After |
| --- | --- | --- |
| `SkotiqDropdown` closed control | `"Light" [button,tap]` → DISABLED | `[button,ENABLED,tap]`, no inherited `selected` (via `selectedItemBuilder` mirroring DropdownMenuItem's 48px/start-aligned layout) |
| `SkotiqDropdown` menu entries | `[button,tap]` | `[button,ENABLED,selected?]` |
| `ScienceInfoButton` | `"" [tap]` (no name, no role) | `[button,ENABLED,tap]` named "What is this? <title>" |
| `StatusPill` (tappable) | button node + a duplicate role-less node carrying the same text | one node (`ExcludeSemantics` over the inner pill) |
| `SkotiqSwitch` / `SkotiqCheckbox` | toggle node + a second unnamed tap node | one node (`excludeFromSemantics` on the inner detector) |
| `SkotiqSwitchRow` | `"" [toggled]` — label was a sibling | `"Regulated cooling" [toggled,ENABLED]` |
| `SkotiqTextField` | `"" [textfield]` — label was a sibling | label carried on the field node |
| `AccessibleIconButton` | two nodes: named-but-inert + operable-but-anonymous | one named, enabled, tappable node |
| `SkotiqAlert` dismiss | unnamed close button | `semanticLabel: 'Dismiss'` |
| `phd2/brain_settings_panel` action button | bare InkWell | `button + enabled` |
| `phd2/calibration_panel` action button | bare InkWell | `button + enabled` |
| `adaptive_panel_layout` sheet handle | bare InkWell | `button + enabled` |

Already correct at HEAD (verified by probe, no edit): `SkotiqButton`, `SkotiqChip`,
`NavItem`, `SubTabButton`, `SkotiqCard`, `AdaptiveTabBar`, `SkotiqStepper`.

## Fixed in skotiq_app/lib/widgets

`filter_wheel_selector` (`_FilterButton` chips — IMG-6 — now `button/enabled/selected`; the
dropdown style's menu entries now carry enabled + selected), plus 22 bare tap targets wrapped
with role + enabled state: `annotation_overlay/object_info_tooltip` ×2,
`autofocus_progress_overlay` ×2, `catalog_setup_dialog`, `focus_model_curve_card/filter_offsets`,
`focuser_controls`, `notification_toast_overlay` ×2, `operation_status_bar`,
`remote_connection_indicator`, `running_sequence_mini_bar` ×2, `sequence/variable_picker`,
`transient_alert_badge`, `troubleshooter/connection_troubleshooter_dialog`,
`weather/dashboard_weather_widget`, `weather/weather_alert_banner` ×2, `weather/weather_radar_map`,
`phd2/guide_controls_panel` ×2 (+ the dither checkbox: detector excluded, `semanticLabel: 'RA Only'`).

## Tests

`packages/skotiq_ui/test/components/interactive_semantics_test.dart` — walks the whole
semantics tree and fails any node that is tappable without a role or without an enabled state,
across 15 components; plus targeted pins for the dropdown (closed/disabled/open), chip selection,
switch-row naming, field naming, and icon-button activation through the semantics action.

## Verification

- Failing-test-first proven in both directions by temporarily reverting the fix and re-running:
  the dropdown pins fail with `"Light" has no enabled state` / no menu entry carries a selected
  state; the filter-chip pin fails with `L chip declares no role`. Both restored and green.
- `flutter test` in `packages/skotiq_ui`: **303 passed** (includes the design-gallery golden,
  so the dropdown's `selectedItemBuilder` changed no pixels).
- `packages/skotiq_app`: the new pins plus `capture_settings_panel_filter`, `focuser_controls`,
  `catalog_setup_dialog`, `notification_toast_overlay_lifecycle`, `phd2/*`, `capture_settings_card`,
  `mount_tab_coordinates`, `cloud_sync_settings`, `integration_goals_editor_exposure` — 61 passed.
- `dart format` clean over every touched file; `dart analyze` on skotiq_ui: 0 errors,
  0 warnings (24 infos, 21 of them the pre-existing `SemanticsData.hasFlag` deprecation that
  `test/components/skotiq_button_disabled_semantics_test.dart` already used at baseline).

One existing pin was amended, not weakened: `skotiq_switch_test.dart` asserted the switch
node was NOT focusable, because focusability sat on the detector's separate node. Collapsing the
duplicate node moves it onto the switch, so the pin now requires `isFocusable` + `hasFocusAction`
on the single node.

### Blocked / not mine

`test/widgets/tutorial_tour_navigation_test.dart` (×2) and
`test/widgets/tutorial_overlay_persistence_test.dart` (×1) fail in the shared tree. They trace to
another agent's in-flight `tutorial_overlay.dart` change (a new
`tutorialStepIndexPastMissingTarget` step-skipping helper) plus a rewritten
`equipment_status_indicator.dart` — neither file is in this batch and neither was touched here.
Retried three times over ~20 minutes; still failing.

## Left for other scopes / notes

- Title bar (`screens/shell/widgets/title_bar.dart`) and nav rail (`screens/shell/widgets/
  side_navigation.dart`) are outside this batch's SCOPE. `NavItem` itself is correct at HEAD
  (probe-verified), so EQP-5/CON-61's "rail absent from the tree" needs a live re-check.
- `SkotiqSlider` still publishes an unnamed slider node; `MergeSemantics` makes it worse
  (Slider is its own semantics boundary, so the merge adds a node instead of naming one).
- `HoldToConfirmButton` exposes no activation action at all (long-press only) — a screen reader
  cannot operate it. Behaviour change, not in the reported family; left alone deliberately.
- **29 screen files under `packages/skotiq_app/lib/screens/` still use Material's raw
  `DropdownButton`** and therefore still publish `[DISABLED]` menu entries with no selected mark
  (this is the remaining half of SCI-36 / COL2-9 / CON-47's theme menu / SEQ-10). The recipe is
  in `SkotiqDropdown`: wrap each item's child in `Semantics(enabled:, selected:)` and give a
  `selectedItemBuilder` so the closed control does not inherit `selected`. Migrating those call
  sites to `SkotiqDropdown` closes them all at once. Feature batches own those files. The
  worst offenders named by the clusters: `diagnostics_screen/header_widgets.dart` (CON-47's
  "Learn more" is a bare `InkWell` + `Tooltip`), `analytics_screen/*` History filter chips
  (SCI-36), the Plan Tonight sort control (COL2-9), the Transient "Types to Monitor" chips
  (COL2-12), the planetarium Layers rows (SKY-17), Sequencer History filter chips (SEQ-10),
  the Autofocus settings leaf (SET-19) and the onboarding wizard switches (SET-6) — those last
  two will be fixed by the `SkotiqSwitchRow` / `SkotiqTextField` changes here IF the
  leaves use those components; if they hand-roll, they need the same one-line treatment.
