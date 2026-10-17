# Batch: dropdown-sweep (A11Y-STATE remainder)

Closes the item left open by `bfix-a11y-design-system.md` §"Left for other scopes":
the screen files that still built Material's dropdown directly and therefore
still published `[DISABLED]` menu entries with no `selected` mark.

## Inventory (the locator was stale)

The earlier log said **29 screen files**. At HEAD the real count is **42 call
sites across 35 files** (32 `DropdownButton<T>`, 10 `DropdownButtonFormField<T>`),
enumerated by the new contract test's own scan — the list is in the test failure
output, reproduced below in "Files changed". Nothing was hand-counted.

## Root cause (re-confirmed against HEAD, not assumed)

`_DropdownMenuItemContainer` (`flutter/lib/src/material/dropdown.dart:792`) is
the wrapper every `DropdownMenuItem` **and** every dropdown hint is built into.
It declares `button: true` and never an enabled state. AT-SPI derives "disabled"
from the ABSENCE of `SemanticsFlag.isEnabled`, so every entry of a live menu
announced itself as inoperable and none carried `selected`.

Two further framework details decide the shape of the fix, and both were read
out of the framework source rather than guessed:

- `dropdown.dart:1770` — `childHasButtonSemantic = hintIndex != null ||
  (_selectedIndex != null && selectedItemBuilder == null)`, and the control's
  outer node is `Semantics(button: !childHasButtonSemantic)`. So supplying a
  `selectedItemBuilder` moves the button role onto the outer node — **unless a
  hint is present**, in which case `hintIndex != null` keeps the role on the
  displayed child and the builder output has to declare it. Seven of the 42
  sites pass a `hint`; without that branch they would have lost the button role
  entirely whenever a value was selected.
- `dropdown.dart:819-825` — the container's layout is exactly
  `ConstrainedBox(minHeight: _kMenuItemHeight)` + `Align(alignment:)`, and
  `_kMenuItemHeight == kMinInteractiveDimension` (line 36). Reproducing that
  pair verbatim is what keeps the closed control pixel-identical once
  `selectedItemBuilder` replaces the container.

## Fix

New `packages/skotiq_app/lib/screens/accessible_dropdown.dart`:
`AccessibleDropdown<T>` and `AccessibleDropdownFormField<T>` — drop-in wrappers
that build the Material widget with the same parameters, and add only:

1. each item's child re-wrapped in `Semantics(enabled:, selected:)`
   (`annotateDropdownItems`), and
2. a `selectedItemBuilder` built from the **unannotated** children
   (`buildSelectedDropdownItems`) so the closed control does not inherit the
   chosen entry's `selected` state and announce itself as a menu entry. It
   declares `button:` only when a hint (or `decoration.hintText`) is present,
   per the branch above — declaring it in both places splits the node in two,
   which is the trap recorded in the earlier batch.

A wrapper rather than 42 hand-edited call sites: the per-site diff is then a
single identifier, the recipe cannot drift, and a new dropdown inherits it. The
call-site change really is one token — `dart analyze lib/screens` passing is
itself the proof that every parameter in use is forwarded.

## Verification

Failing test first, `packages/skotiq_app/test/screens/accessible_dropdown_test.dart`:

- at HEAD the contract test listed all 42 raw call sites, and both real-screen
  pins failed (`the element-refresh schedule menu is operable`, `the
  secondary-camera form field menu is operable`);
- after the sweep: **9/9 pass**.

The file holds four kinds of pin:

- the whole-tree walker from `skotiq_ui`'s `interactive_semantics_test.dart`
  (nothing tappable without a role or an enabled state) over the closed, hinted,
  hinted-with-selection and disabled control;
- menu entries: every entry enabled, exactly the chosen one selected;
- **pixel parity**: the same items rendered through a raw `DropdownButton` and
  through `AccessibleDropdown` must give an identical `tester.getSize` for the
  control and an identical `tester.getRect` for the label;
- a source scan of `lib/screens/**` that fails on any future raw
  `DropdownButton` / `DropdownButtonFormField`.

Regression run over every existing test that touches a migrated screen —
`mount_control_card`, `mount_jog_pad`, `capture_settings_card`,
`element_refresh_card`, `cloud_sync_settings`, `general_language_scope`,
`location_settings_truth`, `settings_dropdown_value_fit`, `secondary_rig_card`,
`recovery_properties`, `trigger_configuration_dialog`,
`integration_goals_editor_exposure`, `integration_goals_editor_unfiltered`,
`science_period_result_session_scope`, `projects_tab_content`,
`constellation_filter_picker`, `mount_tab_coordinates` — **93 passed**. Those
tests reach into `.value`, `.items`, `.onChanged` and `find.byType(DropdownButton<T>)`;
all still resolve because the wrapper builds the real Material widget.

`dart analyze packages/skotiq_app/lib/screens`: 0 errors, 0 warnings, 13
pre-existing infos (`clampPanelWidth` deprecations, one doc-comment lint) — the
same 13 as before the sweep. The new test file adds 22 more infos, all the
`SemanticsData.hasFlag` deprecation that `skotiq_ui`'s equivalent semantics
test already carries at baseline. `dart format` clean over every file touched (the
48 migrated files needed no reformatting; only the two new files did).

Package suite, run the way the gate runs it
(`flutter test --exclude-tags golden`, matching `melos.yaml:318`): **3301
passed, 0 failed**. A first run WITHOUT the exclusion reported 45 failures; every
one of them traces to a `@Tags(['golden'])` render-capture file
(`screens/*/captures_landscape_test.dart`, `golden/public_screenshots_test.dart`,
`imaging/stacking_panel_preview_stretch_test.dart`), whose baselines are
host-specific and gitignored — `melos run test` excludes that tag deliberately
(`docs/testing/golden-tests.md`). Their diffs are 40-44 % of the whole screen,
i.e. font rasterisation, not a 20 px control; and the pixel-parity pin above
measures the control itself.

## Files changed

`lib/screens/accessible_dropdown.dart` (new) plus, under
`packages/skotiq_app/lib/screens/`:

analytics/analytics_screen.dart · analytics/analytics_screen/session_tab.dart ·
analytics/widgets/science_analytics_tab.dart ·
analytics/widgets/science_surface_explorer.dart ·
dashboard/widgets/capture_settings_card.dart ·
dashboard/widgets/mount_control_card.dart (×2) ·
diagnostics/diagnostics_screen.dart ·
diagnostics/diagnostics_screen/header_widgets.dart ·
equipment/dialogs/profile_editor_dialog.dart ·
equipment/dialogs/profile_editor_dialog/filters_and_camera_defaults.dart ·
equipment/widgets/connected_device_card.dart ·
equipment/widgets/connected_device_card/helper_widgets.dart ·
framing/widgets/framing_sidebar.dart ·
framing/widgets/framing_sidebar/controls_and_status.dart ·
imaging/widgets/stretch_controls.dart ·
planetarium/widgets/fov_presets_panel.dart (×3) · planner/planner_screen.dart ·
planner/planner_screen_parts/_filter_controls.dart ·
planner/widgets/progress_tab_content.dart ·
scheduler/widgets/integration_goals_editor.dart ·
scheduler/widgets/target_constraints_editor.dart ·
scheduler/widgets/target_constraints_editor/constraint_fields.dart ·
sequencer/widgets/live_stacking_properties.dart (×2) ·
sequencer/widgets/node_properties_panel.dart ·
sequencer/widgets/node_properties_panel_parts/_capture_rich.dart ·
sequencer/widgets/node_properties_panel_parts/_exposure_rich.dart ·
sequencer/widgets/node_properties_panel_parts/_flow_properties.dart ·
sequencer/widgets/node_property_widgets.dart ·
sequencer/widgets/quick_start_wizard_dialog.dart ·
sequencer/widgets/quick_start_wizard_dialog/_filter_step.dart ·
sequencer/widgets/secondary_rig_card.dart (×2) ·
sequencer/widgets/sequence_tree.dart · sequencer/widgets/sequence_tree/node_item.dart ·
sequencer/widgets/smart_exposure_properties.dart ·
sequencer/widgets/snippet_palette.dart · sequencer/widgets/snippet_palette/actions.dart ·
sequencer/widgets/target_node_properties.dart ·
sequencer/widgets/target_node_properties/trigger_section.dart ·
sequencer/widgets/target_queue_panel.dart ·
sequencer/widgets/trigger_configuration_dialog.dart (×2) ·
settings/widgets/calibration_library_settings.dart (×2) ·
settings/widgets/cloud_sync_settings.dart · settings/widgets/element_refresh_card.dart ·
settings/widgets/log_viewer.dart · settings/widgets/notification_routing_settings.dart ·
settings/widgets/notification_routing_settings/category_editor_dialog.dart ·
settings/widgets/notification_routing_settings/mqtt_transport_section.dart ·
settings/widgets/observation_log_settings.dart

Sixteen of the 42 sites live in `part of` files, which cannot carry an import;
those imports were added to the owning library file instead (the eight
`*_screen.dart` / `*_panel.dart` / `*_dialog.dart` entries above that have no
dropdown of their own).

## Notes / not done here

- The wrapper lives under `lib/screens/` to stay inside this batch's SCOPE. Its
  natural long-term home is `lib/widgets/` beside the other cross-screen
  widgets, or `skotiq_ui` beside `SkotiqDropdown`, whose
  `selectedItemBuilder` this now duplicates. `SkotiqDropdown` could be
  reimplemented on top of `AccessibleDropdown` once the two land in one package;
  that is a cross-package move and belongs to a consolidation batch.
- `AccessibleDropdownFormField` computes `selected:` against the `initialValue`
  it is handed, not the `FormField`'s private state. Those agree because
  `_DropdownButtonFormFieldState.didUpdateWidget` re-syncs on every
  `initialValue` change and all ten call sites write the new value back from
  `onChanged`. A future call site that does NOT write back would announce the
  wrong entry as selected.
- Live-drive confirmation (an actual screen reader over the migrated screens)
  belongs to Wave D; this batch proves the semantics tree, not the AT.
