# Release-pass map — `app-screens-a`

**Subsystem:** `packages/skotiq_app/lib/screens/` — imaging, sequencer, guiding, equipment,
flat_wizard, polar_alignment, framing, dashboard, diagnostics, weather, shell, settings.

**Scale (measured, `wc -l`, all `.dart` under those 12 dirs):**

| dir | files | lines |
|---|---:|---:|
| sequencer | 188 | 76 687 |
| settings | 88 | 42 517 |
| imaging | 55 | 22 870 |
| equipment | 34 | 16 395 |
| dashboard | 42 | 16 105 |
| framing | 22 | 9 686 |
| polar_alignment | 15 | 4 685 |
| shell | 18 | 4 091 |
| flat_wizard | 9 | 2 867 |
| diagnostics | 10 | 2 393 |
| guiding | 4 | 2 189 |
| weather | 4 | 1 694 |
| **total** | **489** | **~202 000** |

29 non-generated files are ≥ 1000 lines. No generated file (`*.g.dart`, `*.freezed.dart`,
`frb_generated`) appears in the oversized list; `settings/settings_search_index.g.dart` is the only
generated file in these paths and is correctly excluded. **Nothing in the list that looks generated
is generated — every one of the 29 is hand-written.**

---

## 0. The split convention this repo already uses (read this before doing any split)

Prior splits in these paths use Dart `part` files in a sibling directory named after the parent:

- `equipment/widgets/connected_device_card.dart` (548) + `connected_device_card/{status_and_display,
  actions_and_telemetry, command_handlers, dialogs_and_settings, helper_widgets}.dart` — and the
  parts are `extension _ConnectedDeviceDialogsAndSettings on _ConnectedDeviceCardState` blocks
  (`connected_device_card/dialogs_and_settings.dart:3`). This is the pattern for splitting a giant
  `State` class.
- `sequencer/widgets/quick_start_wizard_dialog.dart:16-21`, `smart_night_dialog.dart:16-19`,
  `mosaic_wizard_dialog.dart:37-40`, `preflight_validation_dialog.dart:12-14`,
  `sequencer/widgets/sequence_tree.dart` → `sequence_tree/*.dart`.

**Why this matters for the work orders below:** `part` files share the library's private scope, so
moving a `_PrivateWidget` or a `State` method into a part is a pure text move — no new imports, no
visibility changes, no call-site edits, no test edits. Every plan below is written to that
convention and is therefore mechanically behaviour-preserving. Where a plan proposes a *new
top-level file* instead of a part, it says so explicitly and names the symbols that must become
public.

Two rules for implementers:
1. `part` files must not carry their own `import`s — hoist any new import to the parent library file.
2. Keep the parent's `part` directives in the order the plan lists them; several of these files have
   private top-level constants (e.g. `_kDefaultManualFilter`) whose declaration order does not
   matter to Dart but does matter to reviewers diffing the move.

---

## 1. Oversized files (29) and split plans

### 1.1 `guiding/guiding_screen_parts/desktop_sections.dart` — 1393 lines — **risk: medium**

**Why big:** a single `mixin _GuidingDesktopSections` (line 6) that is simultaneously (a) the whole
desktop layout tree, (b) the PHD2 state→colour/label mapping table, and (c) every mutating action
the guiding screen can perform (connect/disconnect, star select/deselect, clear/flip calibration,
and six settle/dither settings persisters with optimistic-set + rollback pairs).

**Split plan** (`guiding/guiding_screen_parts/` already exists; add parts to the same library that
`desktop_sections.dart` is a part of):

- `desktop_sections.dart` **keeps** the layout builders only: `_buildDesktopLayout` (8),
  `_buildStatusBar` (67), `_buildRmsChip` (301), `_buildLeftPanel` (344), `_buildGlassCard` (452),
  `_buildCenterPanel` (531), `_buildGraphCard` (542), `_buildCompactRms` (661), `_buildRightPanel`
  (692), `_buildNonPhd2GuiderInfo` (799), `_buildStatRow` (992). → ~700 lines.
- **new** `_guiding_brain_panel.dart` ← `_buildBrainPanel` (851), `_buildBrainUnavailable` (953),
  `_brainErrorMessage` (987). → ~140 lines. This is a self-contained feature panel with its own
  error surface; it is the cleanest seam in the file.
- **new** `_guiding_formatters.dart` ← `_rmsText` (295), `_getSnrColor` (1019), `_errorForDisplay`
  (1034), `_errorUnit` (1038), `_starViewIdleMessage` (1046), `_starMetricText` (1064),
  `_getStateColor` (1067), `_getStateLabel` (1091), `_mapPhd2State` (1114), plus the two statics
  `_ditherScaleToPixels` (1376) / `_pixelsToDitherScale` (1388). → ~200 lines. These are pure
  functions of their arguments — move them to a `mixin _GuidingFormatters` and have
  `_GuidingDesktopSections` `on` it, or make them top-level private functions (preferred: they are
  then unit-testable without pumping a widget).
- **new** `_guiding_actions.dart` ← `_showConnectionDialog` (1138), `_disconnectActiveGuider`
  (1142), `_selectStar` (1165), `_deselectStar` (1177), `_showActionError` (1182),
  `_clearCalibration` (1190), `_flipCalibration` (1214). → ~110 lines.
- **new** `_guiding_settle_settings.dart` ← `_hydrateGuidingSettings` (1234) and the six
  set/persist pairs `_setSettlePixels`/`_persistSettlePixels` (1244/1251),
  `_setSettleTimeout`/`_persistSettleTimeout` (1269/1276), `_setSettleTime`/`_persistSettleTime`
  (1296/1303), `_setDitherRaOnly`/`_persistDitherRaOnly` (1323/1329),
  `_setDitherAmount`/`_persistDitherScale` (1345/1352). → ~160 lines. These six pairs are
  copy-paste siblings (see §2.6) — landing them in one file is a prerequisite for collapsing them.

---

### 1.2 `settings/catalog_settings_screen.dart` — 1354 lines — **risk: medium**

**Why big:** one `ConsumerState` holding two independent catalogue subsystems (star/DSO catalogues
and annotation catalogues), each with its own download / import / delete triad, plus all their card
UI. A `catalog_settings_screen/card_builders.dart` part (286) already exists but only took the
generic card shells.

**Split plan** (extend the existing `catalog_settings_screen/` part dir):

- `catalog_settings_screen.dart` **keeps** the widget declaration (69), state fields, `initState`/
  `dispose`, `_recomputeDownloading` (168), `_onDownloadProgress` (173), `_loadCatalogStatus` (196),
  `_showError` (442), `_logOutcome` (452), `_rigStatusFor` (459), `_buildRigScopeNotice` (483),
  `_buildContent` (583), `_formatDate` (1349). → ~450 lines.
- **new** `catalog_settings_screen/star_dso_actions.dart` ← `_downloadCatalogs` (244),
  `_onDownloadCancelled` (303), `_requestCancelDownload` (311), `_importCatalog` (319),
  `_isCurrentImport` (367), `_deleteCatalogs` (371), `_confirmDeletion` (387), `_runDeletion` (409),
  and the file-scope helpers `_pickCatalogCsv` (31) + `catalogCsvImporterProvider` (45) +
  `enum _CatalogDeleteTarget` (1354). → ~280 lines.
- **new** `catalog_settings_screen/star_dso_sections.dart` ← `_buildDownloadProgress` (679),
  `_buildDownloadSection` (749), `_buildPackageOption` (794), `_buildActionsSection` (891).
  → ~270 lines.
- **new** `catalog_settings_screen/annotation_section.dart` ← `_buildAnnotationCatalogSection`
  (951), `_buildAnnotationPackageOption` (1149), `_downloadAnnotationCatalog` (1238),
  `_importAnnotationCatalog` (1285), `_deleteAnnotationCatalog` (1333). → ~380 lines. This is the
  highest-value seam: the annotation catalogue is an entirely separate data source that happens to
  share a screen.

---

### 1.3 `settings/pairing_screen.dart` — 1286 lines — **risk: medium**

**Why big:** the file is three things stacked: a state model + `StateNotifier` (19–428), a
`ConsumerWidget` screen (429–1064), and four support widgets (1065–end).

**Split plan** (new sibling files with real imports — the notifier must become importable):

- **new** `settings/pairing/pairing_notifier.dart` ← `class PairingState` (19),
  `class PairingNotifier` (75) and its provider, including `_initialize` (115), `_enqueue` (133),
  `_startCountdownTimers` (189), `_checkPairingCompleted` (222), `clearLastPairedDevice` (262).
  → ~420 lines. `PairingState`/`PairingNotifier` are already public; only the `import` in
  `pairing_screen.dart` is new. **Bonus:** this is the file that should own the countdown timer, and
  once it is alone it can be unit-tested without a widget pump.
- `settings/pairing_screen.dart` **keeps** `class PairingScreen` (429) and its section builders
  `_buildPairingSection` (465), `_buildPairingCodeDisplay` (511), `_buildPairedDevicesSection`
  (598), `_buildDeviceListItem` (675). → ~420 lines.
- **new** `settings/pairing/pairing_device_presentation.dart` ← `_getDeviceIcon` (841),
  `_deviceTypeLabel` (862), `_deviceStatus` (891), `_deviceStatusColor` (908), `_formatDate` (924).
  These take `PairedDevice`/`SkotiqColors` and return presentation values — make them top-level
  **public** functions (`deviceIconFor`, `deviceTypeLabelFor`, …) so the file can be a plain import,
  not a part. → ~120 lines.
- **new** `settings/pairing/pairing_dialogs.dart` ← `_showRenameDialog` (953), `_showRevokeDialog`
  (966), `_showDeleteDialog` (981), `_showDeviceActionDialog` (996), and
  `class _RenameDeviceDialog` (1065). Requires making `_RenameDeviceDialog` → `RenameDeviceDialog`
  and the four `_show*` → public top-level functions taking `(BuildContext, WidgetRef, PairedDevice)`.
  → ~220 lines.
- **new** `settings/pairing/pairing_badges.dart` ← `_AccessBadge` (1155), `_PairedConfirmation`
  (1195), `_PairingErrorBanner` (1240) → made public. → ~130 lines.

---

### 1.4 `imaging/widgets/guiding_panel.dart` — 1286 lines — **risk: medium**

**Why big:** four unrelated concerns in one file: the imaging-tab guiding panel + its start/stop/
dither actions (12–420), a built-in-guider configuration form (421–930), a compact guide graph
widget + painter (931–1118), and the guide-star list + stat chip (1119–end).

**Split plan** (new sibling files; the graph and list are already **public** so no visibility work):

- `imaging/widgets/guiding_panel.dart` **keeps** `GuidingPanel` (12) + `_GuidingPanelState` with
  `_startGuiding` (51), `_stopGuiding` (75), `_dither` (89), `_isCurrentService` (113),
  `_cleanErrorText` (120), `_guideErrorText` (148). → ~420 lines.
- **new** `imaging/widgets/guiding/builtin_guider_config.dart` ← `_BuiltinGuiderConfigSection`
  (421), `_BuiltinGuiderConfigForm` (523), `_BuiltinGuiderConfigFormState` (537) with `_applyConfig`
  (609) and `_resetDefaults` (675), `_ConfigInputRow` (808). Promote
  `_BuiltinGuiderConfigSection` → `BuiltinGuiderConfigSection` (single call site, inside
  `guiding_panel.dart`); the rest stay private to the new file. → ~510 lines.
- **new** `imaging/widgets/guiding/compact_guiding_graph.dart` ← `CompactGuidingGraph` (931) +
  `_CompactGuidingGraphPainter` (1039). Already public, 2 external call sites
  (`guiding_panel.dart:257`, `sequencer/widgets/run_dashboard/guiding_panel_card.dart:100`) — both
  get an import line. → ~190 lines. **See §2.1: this file should not survive long-term.**
- **new** `imaging/widgets/guiding/guide_star_list.dart` ← `GuideStarList` (1119), `_GuideStarRow`
  (1192), `GuideStat` (1253). → ~170 lines.

---

### 1.5 `sequencer/widgets/run_dashboard/live_frame_panel.dart` — 1277 lines — **risk: medium**

**Why big:** the tile, the zoomable viewer with its own control cluster, the metadata badge, an HFR
sparkline painter, the history column with its own thumbnail-loading tile, and a frame-inspect
modal — six layers of widget in one file, all private.

**Split plan** (convert to a `part` library; `live_frame_panel.dart` becomes the parent):

- `live_frame_panel.dart` **keeps** `RunDashboardLiveFrame` (31) with its statics
  `_unboundedHeightFor` (114), `_hfrHistory` (123), `_resolveFilter` (136), plus `_FramePane` (155)
  and `_WaitingState` (200). Add `part` directives for the four files below. → ~230 lines.
- **new part** `live_frame_panel/viewer.dart` ← `_LiveFrameViewer` (226) + `_LiveFrameViewerState`
  (236) with `_reset` (261) / `_zoomBy` (273), `_ZoomReadout` (362), `_ViewerControls` (390),
  `_ControlDivider` (444), `_ControlButton` (458). → ~280 lines.
- **new part** `live_frame_panel/frame_badge.dart` ← `_FrameBadge` (507) with `_hfrColor` (522) /
  `_eccColor` (532), `_QualityChip` (649), `_HfrSparklinePainter` (694). → ~190 lines.
  **See §2.2 — the painter here is a second implementation of the one in `quality_panel.dart`; the
  merge should land before or with this move so only one copy travels.**
- **new part** `live_frame_panel/history_column.dart` ← `_HistoryColumn` (769) with
  `_matchesCurrent` (839), `_HistoryTile` (856) + state with `_loadBytes` (889), `_HistoryThumb`
  (986) with `_placeholder` (1041) / `_isImageLikePath` (1045). → ~290 lines.
- **new part** `live_frame_panel/inspect_dialog.dart` ← `_FrameInspectDialog` (1058) with
  `_fileName` (1133), `_InspectPreview` (1139) with `_fallback` (1181), `_MetaRow` (1200),
  `_MetaChip` (1247). → ~230 lines.

---

### 1.6 `settings/settings_screen.dart` — 1258 lines — **risk: low**

**Why big:** the search-ranking algorithm, the screen shell, and **two complete parallel navigation
trees** (desktop grouped list + mobile section list, each with its own header/item/search-results
widgets) all in one file.

**Split plan:**

- **new** `settings/settings_search.dart` ← `sectionMatchesToken` (47), `settingsMatchRank` (60),
  `class SettingsSearchResult` (78), `isRowShapedSettingsTerm` (102), `_startsWord` (120). All
  already public except `_startsWord`. → ~120 lines, and it becomes directly unit-testable.
- `settings/settings_screen.dart` **keeps** `SettingsScreen` (157) + `_SettingsScreenState` (170)
  with `_selectSection` (242), `_toggleGroup` (257), `_buildMobileLayout` (363),
  `_buildDesktopLayout` (436), plus `_SearchField` (523). → ~420 lines. Add two `part` directives.
- **new part** `settings_screen/desktop_nav.dart` ← `_DesktopGroupedList` (579), `_GroupHeader`
  (638) + state, `_DesktopSearchResults` (733), `_SearchRowResult` (791) + state, `_CategoryItem`
  (1159) + state. → ~380 lines.
- **new part** `settings_screen/mobile_nav.dart` ← `_MobileSectionList` (864),
  `_MobileSearchResults` (991), `_MobileGroupHeader` (1043), `_MobileSectionItem` (1101).
  → ~300 lines.

---

### 1.7 `sequencer/widgets/quick_start_wizard_dialog.dart` — 1247 lines — **risk: high**

**Why big:** already split into six step parts (`quick_start_wizard_dialog/_*.dart`, lines 16–21) —
what is left is a 1100-line `State` class that is the wizard's whole controller. `_finishWizard`
alone is lines 645–1073 (**428 lines in one method**), which is the single worst method in this
subsystem and the reason risk is "high".

**Split plan** (add `extension` parts, per the `connected_device_card` precedent):

- `quick_start_wizard_dialog.dart` **keeps** `_FilterExposureConfig` (55), `_ExposurePreset` (74) +
  its label extension (82), `QuickStartWizardDialog` (118), the state fields, `initState`/`dispose`,
  `_update` (1190), and the existing `part` list. → ~250 lines.
- **new part** `quick_start_wizard_dialog/_controllers.dart` — `extension _QsControllers on
  _QuickStartWizardDialogState` ← `_seedScalarControllers` (223), `_syncController` (235),
  `_syncFilterControllers` (243), `_initFilterConfigs` (378), `_rePreviewExposures` (1196),
  `_formatDuration` (1147). → ~150 lines.
- **new part** `quick_start_wizard_dialog/_init_and_defaults.dart` — `extension _QsInit` ←
  `_initializeWizard` (258), `_retryInitialization` (288), `_applyUserDefaults` (298),
  `_loadExposureContext` (354), `_persistChoicesAsDefaults` (1074). → ~180 lines.
- **new part** `quick_start_wizard_dialog/_target_search.dart` — `extension _QsTargets` ←
  `_onTargetSearch` (456), `_selectTarget` (523), `_applyPreset` (587). → ~180 lines.
- **new part** `quick_start_wizard_dialog/_finish.dart` — `extension _QsFinish` ← `_createSequence`
  (639), `_saveAsTemplate` (643), `_finishWizard` (645–1073). → ~440 lines. **Do the file move
  first, then decompose `_finishWizard` inside its new home** into named private methods (candidate
  seams visible in the body: build target node → build filter/exposure children → attach automation
  triggers → attach safety guards → persist as sequence-or-template → navigate). Splitting the file
  and decomposing the method in the same commit makes the diff unreviewable.

---

### 1.8 `sequencer/widgets/preflight_validation_dialog.dart` — 1222 lines — **risk: medium**

**Why big:** already has three parts (12–14). What remains mixes the validation run, the simulation
run, the previous-run diff, three confirmation sub-dialogs, and seven `_build*` states.

**Split plan:**

- `preflight_validation_dialog.dart` **keeps** the widget (30) + state fields + `_buildHeader` (463),
  `_buildLoadingState` (510), `_buildPreparingState` (537), `_buildErrorState` (573),
  `_buildResults` (615), `_buildAllClearCard` (1117), `_buildActions` (1146), `_formatDuration`
  (1215). → ~450 lines.
- **new part** `preflight_validation_dialog/_validation_run.dart` — `extension` ← `_runValidation`
  (72), `_retryValidation` (112), `_simulateCurrentSequence` (121), `_computePreviousRunDiff` (165),
  `_buildPreviousRunDiffBanner` (1060). → ~230 lines.
- **new part** `preflight_validation_dialog/_start_flow.dart` — `extension` ← `_handleStartSequence`
  (221), `_authorizeStartWithoutHistory` (308), `_confirmStartWithoutHistory` (313),
  `_confirmRetrySettings` (367), `_openCalibrationCenter` (824). → ~270 lines. This is the
  gate-to-actually-starting-a-run path and deserves to be readable on its own.
- **new part** `preflight_validation_dialog/_results_sections.dart` — `extension` ←
  `_buildSimulationSection` (713), `_buildSummary` (832), `_buildIssueCard` (948). → ~230 lines.

---

### 1.9 `settings/widgets/log_viewer.dart` — 1214 lines — **risk: medium**

**Why big:** viewer + filter state + four heavyweight IO flows (export with scope picker, remote
file download with file picker, clear with confirmation, clipboard copy) + the row renderer.

**Split plan:**

- `settings/widgets/log_viewer.dart` **keeps** `enum LogExportScope` (17), `LogViewer` (63) +
  state lifecycle, `_startRefreshTimer` (126), `_refreshLogs` (158), `_applyFilters` (228),
  `_levelColor`/`_levelLabel`, `_buildFilterBar` (850), `_buildSourceDropdown` (931),
  `_buildActionBar` (982), `_buildLogEntry` (1034), `_formatTimestamp` (1106), and the two small
  widgets `_LevelFilterButton` (1115) / `_ActionToggle` (1161). → ~600 lines.
- **new part** `log_viewer/_export_flows.dart` — `extension` ← `_copyAllToClipboard` (274),
  `_retainedLogBytes` (292), `_askExportScope` (309), `_exportLogs` (404), `_downloadLogFile` (489),
  `_pickLogFile` (559). → ~380 lines.
- **new part** `log_viewer/_clear_flow.dart` — `extension` ← `_confirmClearLogs` (638),
  `_clearLogs` (726). → ~210 lines.

---

### 1.10 `equipment/widgets/connected_device_card/dialogs_and_settings.dart` — 1213 lines — **risk: low**

**Why big:** it is already a `part` (line 3: `extension _ConnectedDeviceDialogsAndSettings on
_ConnectedDeviceCardState`), but it accumulated **eight** independent device dialogs.

**Split plan** — split the one extension into four parts of the same library, keeping the same
`on _ConnectedDeviceCardState` receiver so every call site is unchanged:

- `dialogs_and_settings.dart` **keeps** `_showMoveDialog` (8), `_showRotateDialog` (176),
  `_showDomeSlewDialog` (366) → rename the file `motion_dialogs.dart`. → ~360 lines.
- **new part** `connected_device_card/mount_focuser_settings.dart` ← `_showMountSettingsDialog`
  (503), `_showFocuserSettingsDialog` (657). → ~330 lines.
- **new part** `connected_device_card/rotator_dome_settings.dart` ← `_showRotatorSettingsDialog`
  (827), `_showDomeSettingsDialog` (935). → ~200 lines.
- **new part** `connected_device_card/calibrator_settings.dart` ←
  `_showCoverCalibratorSettingsDialog` (1028), `_applyCalibratorBrightness` (1182). → ~190 lines.

Update the five `part` lines in `connected_device_card.dart:16-20` accordingly. Zero behaviour risk:
the extension name is the only thing that changes and it is never referenced.

---

### 1.11 `imaging/widgets/calibration_section.dart` — 1193 lines — **risk: medium**

**Why big:** defect-map status display, the "build a defect map" flow (three different file-source
pickers), the apply/clear toggles, and a full correction-settings sub-form, all in one file.

**Split plan:**

- `imaging/widgets/calibration_section.dart` **keeps** `CalibrationSection` (52), `_StatusBlock`
  (195), `_NoMapForBucketBlock` (278), `_AlternateBucketChip` (378), `_StatusLine` (460),
  `_MaybeTooltip` (869), `_formatThousands` (1152), `_relativeAge` (1167). → ~500 lines.
- **new part** `calibration_section/defect_map_build_button.dart` ← `DefectMapBuildButton` (499) +
  state with `_pickAndBuild` (537), `_pickLocalFilesAndBuild` (582), `_pickHostDirectoryAndBuild`
  (613), `_reportResult` (634). `DefectMapBuildButton` is public — keep it public. → ~190 lines.
- **new part** `calibration_section/toggles.dart` ← `_ApplyToggle` (687), `_ClearButton` (777) +
  `_confirmAndClear` (796). → ~180 lines.
- **new part** `calibration_section/correction_settings.dart` ← `_CorrectionSettings` (887) with
  `_runSettingsChange` (909) / `_pushIfActive` (926), `_ResponsiveDropdownSetting` (1091).
  → ~270 lines.

---

### 1.12 `settings/widgets/science_settings.dart` — 1188 lines — **risk: low (but see §2.5)**

**Why big:** the page (19–403) plus **seven** bespoke setting-row widgets, five of which are
near-identical re-implementations of commit-on-blur text entry.

**Split plan** — do §2.5 (collapse onto `SettingsTextInput`) *first*; it removes ~600 lines and the
file drops under the threshold without any file surgery. If §2.5 is deferred:

- `science_settings.dart` **keeps** `ScienceSettingsPage` (19). → ~400 lines.
- **new part** `science_settings/observer_code_rows.dart` ← `_AavsoObserverCodeRow` (404),
  `_MpcObservatoryCodeRow` (521), `_ScienceTextRow` (640). → ~380 lines.
- **new part** `science_settings/secret_and_toggle_rows.dart` ← `_TnsApiKeyRow` (775),
  `_TnsSandboxRow` (873), `_ScienceOnlineCatalogRow` (901). → ~190 lines.
- **new part** `science_settings/camera_rows.dart` ← `_ScienceCameraAutoRow` (964),
  `_ScienceCameraValueRow` (1027). → ~220 lines.

---

### 1.13 `framing/widgets/framing_controls.dart` — 1181 lines — **risk: low**

**Why big:** a grab-bag of 15 unrelated public control widgets that share nothing but the `Framing`
prefix. Each is self-contained; there is no state to untangle.

**Split plan** — four new *plain* files (all symbols already public, so each call site just gains an
import; or keep a barrel `framing_controls.dart` that re-exports the four, which makes the change a
**pure move with zero call-site edits** — prefer that):

- **new** `framing/widgets/controls/framing_fields.dart` ← `FramingSliderField` (15),
  `FramingRotationField` (102) + state + `_RotationStepButton` (319), `FramingToggleChip` (363),
  `FramingSmallIconButton` (409) + state. → ~450 lines.
- **new** `framing/widgets/controls/framing_fov_controls.dart` ← `FramingPreviewFovSlider` (464),
  `_FovPresetButton` (608), `FramingEquipmentFovOverlayControls` (656). → ~290 lines.
- **new** `framing/widgets/controls/framing_mosaic_controls.dart` ← `FramingMosaicSpinner` (757),
  `_SpinnerButton` (821), `FramingStartCornerSelector` (936), `_CornerOption` (996),
  `FramingExportMosaicButton` (1061) + state + `_createProject` (1083). → ~350 lines.
- **new** `framing/widgets/controls/framing_option_button.dart` ← `FramingOptionButton` (851) +
  state. → ~85 lines.
- `framing/widgets/framing_controls.dart` becomes 4 `export` lines.

---

### 1.14 `sequencer/widgets/node_properties_panel_parts/_motion_rich.dart` — 1170 lines — **risk: low**

**Why big:** it is already a part file, but it holds the property editors for **seven different node
types** (center, autofocus, rotator, slew, meridian flip, polar alignment) plus two shared readouts.
`_MeridianFlipProperties` (711–975) and `_AutofocusProperties` (161–435) are each ~270 lines.

**Split plan** — split the one part into three parts of the same parent library
(`node_properties_panel.dart`); nothing is exported, so this is a pure move:

- `_motion_rich.dart` **keeps** `_CenterProperties` (9), `_SlewProperties` (494),
  `_CoordinateReadout` (580), `_TargetResolutionPreview` (619) → rename `_slew_and_center_rich.dart`.
  → ~380 lines.
- **new part** `_autofocus_rich.dart` ← `_AutofocusProperties` (161), `_RotatorProperties` (436).
  → ~330 lines.
- **new part** `_flip_and_polar_rich.dart` ← `_MeridianFlipProperties` (711),
  `_PolarAlignmentProperties` (976). → ~460 lines.

---

### 1.15 `framing/widgets/framing_canvas.dart` — 1158 lines — **risk: medium**

**Why big:** a 545-line `_FramingCanvasState` (gesture handling, pan/zoom transform, survey-tile
loading) followed by six chrome widgets.

**Split plan:**

- `framing/widgets/framing_canvas.dart` **keeps** `FramingCanvas` (26) + `_FramingCanvasState` (58).
  Add `part` directives. → ~590 lines.
- **new part** `framing_canvas/canvas_controls.dart` ← `_CanvasControls` (659),
  `_SurveySourceSelector` (792), `_ControlChip` (861) + state. → ~280 lines.
- **new part** `framing_canvas/zoom_controls.dart` ← `_ZoomControls` (939), `_ZoomButton` (995) +
  state, `_ScaleIndicator` (1049). → ~220 lines.
- **new part** `framing_canvas/equipment_hint_card.dart` ← `_EquipmentHintCard` (603). → ~60 lines.

---

### 1.16 `settings/widgets/cloud_sync_settings.dart` — 1143 lines — **risk: medium**

**Why big:** **two** complete cards — `CloudSyncCard` (24–647, the local/FFI path) and
`RemoteCloudSyncCard` (648–910, the network path) — plus a remote browser dialog. The two cards are
partial siblings (both have `_load`, `_pushNow`) but are genuinely different backends, so this is a
file split, not a dedup.

**Split plan:**

- `settings/widgets/cloud_sync_settings.dart` **keeps** `CloudSyncCard` (24) + `_CloudSyncCardState`
  (31) with `_load` (88), `_validationError` (127), `_save` (159), `_testConnection` (223),
  `_pushNow` (249), `_browseRemote` (285), `_webdavFields` (510), `_s3Fields` (546), `_field` (622).
  → ~640 lines.
- **new** `settings/widgets/cloud_sync/remote_cloud_sync_card.dart` ← `RemoteCloudSyncCard` (648) +
  state with `_load` (683) / `_pushNow` (731), `_RemoteSyncStatusRow` (911). `RemoteCloudSyncCard` is
  public; promote `_RemoteSyncStatusRow` to file-private in the new file. → ~280 lines.
- **new** `settings/widgets/cloud_sync/remote_browser_dialog.dart` ← `_RemoteBrowserDialog` (956) +
  state with `_loadMachines` (978), `_loadBundles` (999), `_buildBody` (1061). Promote to
  `RemoteBrowserDialog` (one call site: `_browseRemote` at 285). → ~230 lines.

---

### 1.17 `settings/widgets/calibration_library_settings.dart` — 1138 lines — **risk: medium**

**Why big:** the library list plus the entire share/contribute lifecycle (tag edit, delete, publish,
retract, accept-remote, consent collection) plus a matching-preview simulator.

**Split plan:**

- `calibration_library_settings.dart` **keeps** `CalibrationLibrarySettings` (22) + state lifecycle,
  `_reload` (71), `_isCurrentLoad` (116), `_isCurrentAuthority` (121), `_showAuthorityChanged` (124),
  `build` (132), `_buildFilterBar` (171), `_buildList` (206), `_showMessage` (593). → ~350 lines.
- **new part** `calibration_library_settings/_share_actions.dart` — `extension` ← `_editTags` (254),
  `_confirmDelete` (335), `_publish` (411), `_retract` (444), `_accept` (490),
  `_acceptOutcomeMessage` (513), `_collectConsent` (528). → ~350 lines.
- **new part** `calibration_library_settings/_tiles.dart` ← `_MasterTile` (606), `_TypeBadge` (734),
  `_FreshnessChip` (760). → ~190 lines.
- **new part** `calibration_library_settings/_matching_preview.dart` ← `_MatchingPreview` (792) +
  state with `_run` (844), `_accept` (949), `_field` (1008), `_buildResult` (1023), `_matchCard`
  (1051). → ~250 lines.

---

### 1.18 `sequencer/widgets/mosaic_wizard_dialog.dart` — 1135 lines — **risk: medium**

**Why big:** already has four parts (37–40); the parent is a 1000-line `State` doing checkpoint
resume, panel geometry maths, time estimation, sequence generation, project persistence, and three
validation dialogs.

**Split plan:**

- `mosaic_wizard_dialog.dart` **keeps** the widget (42), `_PanelSizeSource` (57), state fields,
  `initState`/`dispose`, `_isCurrentAuthority` (172), `build` (761),
  `_buildUnknownPanelSizeBanner` (1011), `_buildResumeBanner` (1061). → ~420 lines.
- **new part** `mosaic_wizard_dialog/_checkpoint_resume.dart` — `extension` ←
  `_probeForInterruptedMosaic` (177), `_resumeInterruptedMosaic` (202), `_discardMosaicCheckpoint`
  (225). → ~90 lines.
- **new part** `mosaic_wizard_dialog/_estimation.dart` — `extension` ← `_calculatePanels` (266),
  `_seedFilterRowsIfNeeded` (329), `_exposureSecsPerPanel` (375), `_exposuresPerPanel` (384),
  `_perPanelOverheadSecs` (400), `_calculateTotalTime` (410). → ~160 lines. These are pure maths
  over the wizard's fields — the highest-value extraction here, since they are the numbers the
  operator plans a night on and are currently untestable.
- **new part** `mosaic_wizard_dialog/_generation.dart` — `extension` ← `_generateMosaic` (419),
  `_createSequence` (449), `_createMosaicProject` (551), `_persistProject` (581),
  `_showMosaicProjectHostOnlyMessage` (610), `_collectDescendants` (643), `_showValidationDialog`
  (657), `_showWarningsDialog` (706). → ~340 lines.

---

### 1.19 `imaging/widgets/science_hud.dart` — 1095 lines — **risk: medium**

**Why big:** a 700-line `_ScienceHudPanelState` (`build` alone is 75–570) plus six support widgets.

**Split plan:**

- `imaging/widgets/science_hud.dart` **keeps** `ScienceHudPanel` (13) + state with
  `_retireHostOperations` (62), `build` (75), `_saveSessionConfig` (571), `_runSelectionAction`
  (627), `_isCurrentConfigOperation` (672), `_isCurrentSelectionOperation` (685),
  `_retryAuthorities` (698). → ~710 lines. **Then** decompose `build` in place into
  `_buildAuthorityHeader` / `_buildFeatureToggles` / `_buildOverlayRow` / `_buildOffersRow` —
  the seams are visible as the top-level `Column` children.
- **new part** `science_hud/_notices_and_toggles.dart` ← `_ScienceHudAuthorityNotice` (708),
  `_FeatureToggle` (749), `_OverlayChip` (1051). → ~150 lines.
- **new part** `science_hud/_contextual_offers.dart` ← `_ContextualOffers` (803) with `_hasFilter`
  (876), `_OfferTile` (899), `_TransparencyUnlockProgress` (964). → ~250 lines.

---

### 1.20 `shell/app_shell.dart` — 1094 lines — **risk: high**

**Why big:** the shell is the app's root widget *and* the owner of every startup check (database
resolution, catalog check, checkpoint recovery) *and* the close-request/flush-edits handler *and*
the nav index mapping — plus a 290-line `build`.

**Risk is high because everything renders inside it**; keep the moves mechanical.

**Split plan:**

- **new** `shell/app_startup_checks.dart` ← `enum AppStartupCheckpointOutcome` (42),
  `enum AppCheckpointRecoveryChoice` (49), `class CheckpointAttemptFailure` (62), and the two
  injectable resolvers `databaseFileResolver` (116) / `legacyDirectoryResolver` (141) with the
  free functions they default to. All already public and already referenced by tests — this is
  the safest and most valuable extraction. → ~330 lines.
- `shell/app_shell.dart` **keeps** `AppShell` (395) + `_AppShellState` (404) and gains `part`
  directives. → ~450 lines.
- **new part** `app_shell/_startup.dart` — `extension` ← `_runStartupChecks` (426),
  `_checkCatalogsIfNeeded` (553), `_checkCheckpointIfNeeded` (598), `_performCheckpointCheck` (602).
  → ~170 lines.
- **new part** `app_shell/_close_flow.dart` — `extension` ← `_onCloseRequested` (434),
  `_flushEditsBeforeClose` (508). → ~110 lines.
- **new part** `app_shell/_navigation.dart` — `extension` ← `_getCurrentLocation` (681),
  `_getCurrentIndex` (694), `_onTabSelected` (718); plus `_MobileSettingsBar` (1018). → ~130 lines.

---

### 1.21 `sequencer/widgets/sequence_tree/support_widgets.dart` — 1087 lines — **risk: low**

**Why big:** already a part of `sequence_tree.dart` (line 1), but it is the dumping ground for 13
unrelated tree-chrome widgets.

**Split plan** — three parts of the same library (pure move, all private):

- `support_widgets.dart` **keeps** `_WatchdogBadge` (11), `_SpinningIcon` (49) + state,
  `_NodeActionButton` (108) + state, `_MiniCountBadge` (651). → ~230 lines.
- **new part** `sequence_tree/drop_zone.dart` ← `_DropZone` (191), `_DashedLinePainter` (341).
  → ~200 lines.
- **new part** `sequence_tree/validation_chrome.dart` ← `_NodeColorLegend` (388),
  `_NodeValidationWrapper` (489), `_ValidationBadges` (595). → ~260 lines.
- **new part** `sequence_tree/tree_toolbar.dart` ← `_TreeSearchField` (695) + state,
  `_CollapseAllToggle` (898), `_MinimapToggle` (971), `_TimelineToggle` (1030). → ~390 lines.

---

### 1.22 `sequencer/widgets/smart_night_dialog.dart` — 1073 lines — **risk: medium**

**Why big:** already has four parts (16–19); the parent is a 960-line `State` holding settings
seeding/persistence, four validators, the preview builder, and the plan-start/save flows.

**Split plan:**

- `smart_night_dialog.dart` **keeps** the widget (37) + state fields, `initState`/`dispose`,
  `_update` (131), `_isCurrentAuthority` (140), `build` (177), `_buildSettingsGate` (225),
  `_onPrimaryPressed` (462), `_pickDateTime` (1034), `_formatDateTime` (1059), `_formatDuration`
  (1067). → ~430 lines.
- **new part** `smart_night_dialog/_settings_seed.dart` — `extension` ← `_ensureWindowInitialised`
  (319), `_ensureSettingsSeeded` (349), `_persistedNameForStrategy` (399), `_persistSettings` (423).
  → ~150 lines.
- **new part** `smart_night_dialog/_validators.dart` — `extension` ← `_validateWindow` (500),
  `_validateEquipment` (537), `_validateTargets` (563), `_validateStrategy` (591),
  `_strategyFitsProfile` (608). → ~140 lines.
- **new part** `smart_night_dialog/_preview_and_start.dart` — `extension` ← `_buildPreview` (635),
  `_shouldPromptForCameraSpecs` (804), `_adjustFilterCount` (815), `_startPlan` (980),
  `_savePlanAsTemplate` (1012). → ~370 lines.

---

### 1.23 `settings/widgets/location_settings.dart` — 1047 lines — **risk: medium**

**Why big:** a **430-line `build`** (93–523) followed by the whole custom-horizon subsystem
(import/reduce/reset/update) and timezone migration.

**Split plan:**

- `settings/widgets/location_settings.dart` **keeps** `LocationSettingsPage` (55) + state lifecycle
  + `build` (93) + `_detectLocation` (524) + `_timezoneSubtitle` (841) + `_migrateLegacyTimezone`
  (866). → ~560 lines. **Then** decompose `build` in place into `_buildSiteCard`,
  `_buildTimezoneCard`, `_buildHorizonCard` — the section boundaries are the `SettingsSection`
  children.
- **new part** `location_settings/_horizon_profile.dart` — `extension` ← `_importHorizonFile` (597),
  `_confirmHorizonReduction` (676), `_resetHorizon` (765), `_isCurrentHorizonImport` (801),
  `_updateHorizonProfile` (810). → ~250 lines.

---

### 1.24 `sequencer/widgets/sequence_tree/node_item.dart` — 1042 lines — **risk: medium**

**Why big:** a single `_NodeItemState` where `build` is 457–601 and `_buildRowBody` is 602–end
(~440 lines), plus a 230-line `_showSaveAsSnippetDialog` (128).

**Split plan** (parts of `sequence_tree.dart`):

- `node_item.dart` **keeps** `_NodeItem` (3) + `_NodeItemState` lifecycle, `build` (457),
  `_buildRowBody` (602). → ~640 lines.
- **new part** `sequence_tree/node_item_snippet_dialog.dart` — `extension _NodeItemSnippet on
  _NodeItemState` ← `_showSaveAsSnippetDialog` (128). → ~240 lines.
- **new part** `sequence_tree/node_item_appearance.dart` — `extension _NodeItemAppearance on
  _NodeItemState` ← `_getIcon` (359), `_getCategoryColor` (411), `_getStatusColor` (424),
  `_summaryA11yText` (446). → ~110 lines. Note `_getIcon`/`_getCategoryColor` are switch tables over
  node type that do not touch state — they should become top-level private functions taking the node
  type, which makes them testable and is a prerequisite for §2.7.

---

### 1.25 `sequencer/tabs/sequence_library_tab/sequence_card.dart` — 1040 lines — **risk: low**

**Why big:** already a part of `sequence_library_tab.dart`; it holds the card (12–898), a delete
dialog (899–1011), and a favourite toggle (1012–end).

**Split plan:**

- `sequence_card.dart` **keeps** `_SequenceCard` (12) + `_SequenceCardState` (25) with
  `_formatDuration` (64) / `_formatDate` (679). → ~890 lines. Then, inside its new smaller
  footprint, split the state's `build` (the card has three visual zones: header, stats strip, action
  row) into `_buildHeader` / `_buildStats` / `_buildActions`.
- **new part** `sequence_library_tab/delete_sequence_dialog.dart` ← `_DeleteSequenceDialog` (899) +
  state. → ~115 lines.
- **new part** `sequence_library_tab/favorite_toggle.dart` ← `_FavoriteToggle` (1012). → ~30 lines.

*(This is the weakest split in the set — the card really is one widget. Effort small, payoff small;
schedule it last.)*

---

### 1.26 `settings/widgets/dark_library_settings.dart` — 1033 lines — **risk: medium**

**Why big:** a 410-line `build` (33–444) plus five dialogs plus four tile widgets.

**Split plan:**

- `dark_library_settings.dart` **keeps** `DarkLibrarySettings` (14) + state with `build` (33),
  `_isCurrentAuthority` (756), `_cancelForAuthorityChange` (759). → ~470 lines.
- **new part** `dark_library_settings/_dialogs.dart` — `extension` ← `_showClearDialog` (445),
  `_showCreateMasterDialog` (495), `_showDeleteGroupDialog` (576), `_showDeleteEntryDialog` (669),
  `_downloadEntry` (728). → ~310 lines.
- **new part** `dark_library_settings/_tiles.dart` ← `_StatCard` (769), `_ActionButton` (816),
  `_DarkGroupTile` (848), `_DarkEntryTile` (920). → ~260 lines.

---

### 1.27 `settings/widgets/autofocus_settings.dart` — 1014 lines — **risk: low**

**Why big:** **two full parallel layouts** — `_buildDesktopTwoColumnLayout` (174–463, 290 lines) and
`_buildMobileLayout` (464–754, 290 lines) — rendering the same settings twice, plus a per-filter
settings table that itself has desktop (864) and mobile (948) variants.

**Split plan:**

- `autofocus_settings.dart` **keeps** `AutofocusSettingsPage` (14) + state with `_afNumberInput`
  (71), `build` (130), `_buildAfSettingRow` (755), `_tableHeader` (1000). → ~250 lines.
- **new part** `autofocus_settings/_desktop_layout.dart` — `extension` ←
  `_buildDesktopTwoColumnLayout` (174). → ~295 lines.
- **new part** `autofocus_settings/_mobile_layout.dart` — `extension` ← `_buildMobileLayout` (464).
  → ~295 lines.
- **new part** `autofocus_settings/_filter_table.dart` — `extension` ← `_buildFilterSettingsSection`
  (818), `_buildFilterSettingsTable` (864), `_buildFilterSettingsMobile` (948). → ~190 lines.

**Follow-up (not part of the split):** the desktop and mobile layouts are the same settings list
twice — see §2.8. The split above is the prerequisite for diffing them.

---

### 1.28 `imaging/centering_dialog.dart` — 1009 lines — **risk: medium**

**Why big:** one `_CenteringDialogState` with eight `_build*` sections and the centering run
control. A `centering_dialog/image_canvas.dart` part already exists.

**Split plan:**

- `imaging/centering_dialog.dart` **keeps** `CenteringDialog` (18) + state lifecycle,
  `_parseValidExposureSeconds` (102), `_setExposureError` (122), `_resolvedAppSettings` (134),
  `_buildCenteringConfig` (142), `build` (162), `_formatRa` (994), `_formatDec` (1001). → ~330 lines.
- **new part** `centering_dialog/sections.dart` ← `_buildHeader` (321), `_buildImagePreview` (357),
  `_buildCoordinatesCompact` (429), `_buildExposureSettings` (488), `_buildCoordInfo` (587).
  → ~300 lines.
- **new part** `centering_dialog/status_sections.dart` ← `_buildStatusSection` (622),
  `_buildResultSection` (737), `_buildIterationHistory` (791). → ~250 lines.
- **new part** `centering_dialog/run_control.dart` — `extension` ← `_abortCentering` (868),
  `_startCentering` (886). → ~130 lines.

---

### 1.29 `flat_wizard/widgets/flat_preview_panel.dart` — 1008 lines — **risk: low**

**Why big:** twelve small-to-medium widgets, cleanly separable; no shared state.

**Split plan** (parts of a new `flat_preview_panel.dart` library):

- `flat_preview_panel.dart` **keeps** `FlatPreviewPanel` (14), `_ImagePreview` (66),
  `_StatusIndicator` (476), `_ExposureCountdown` (544) + state. → ~330 lines.
- **new part** `flat_preview_panel/_histogram.dart` ← `_HistogramChart` (265), `_HistogramPainter`
  (307). → ~130 lines.
- **new part** `flat_preview_panel/_stats_and_visualisations.dart` ← `_StatsBar` (391),
  `_VisualizationsSection` (628), `_ToggleButton` (719), `_AduConvergenceGraph` (763). → ~330 lines.
- **new part** `flat_preview_panel/_filter_progress.dart` ← `_FilterProgressCards` (919),
  `_FilterCard` (946). → ~90 lines.

---

## 2. Duplication inside these paths

### 2.1 Three separate RA/Dec guide-graph renderers — **canonical: `skotiq_ui`'s `GuideGraphAdvanced`**

| impl | file:line | consumers |
|---|---|---|
| `GuideGraphAdvanced` (canonical, has 2 UI tests) | `packages/skotiq_ui/lib/src/widgets/phd2/guide_graph_advanced.dart:60` | `guiding/guiding_screen_parts/desktop_sections.dart:625` |
| `CompactGuidingGraph` + `_CompactGuidingGraphPainter` | `imaging/widgets/guiding_panel.dart:931`, `:1039` | `imaging/widgets/guiding_panel.dart:257`, `sequencer/widgets/run_dashboard/guiding_panel_card.dart:100` |
| `_DashboardGuidingGraphPainter` | `dashboard/widgets/guiding_card.dart:192` | `dashboard/widgets/guiding_card.dart` only |

All three plot the same `GuideGraphPoint` RA/Dec series with the same
`SkotiqChartColors.seriesRed`/`seriesBlue` convention, and each has its own scaling rule — so
the same guiding night renders with three different y-scales depending on which surface the operator
is looking at.

**Merge:** add a `compact: true` (or `height`/`showLegend`/`showAxisLabels`) mode to
`GuideGraphAdvanced`, then delete `_CompactGuidingGraphPainter` and `_DashboardGuidingGraphPainter`
and re-point the three call sites. `CompactGuidingGraph` can stay as a thin, still-public wrapper
that maps `GuideGraphPoint` → `GuideDataPoint` and sets the compact flags (that mapping already
exists inline at `desktop_sections.dart:628`). **Effort: medium.**

### 2.2 Two `_HfrSparklinePainter` classes in the *same* run-dashboard package

`sequencer/widgets/run_dashboard/live_frame_panel.dart:694` and
`sequencer/widgets/run_dashboard/quality_panel.dart:351`. Same name, same purpose (HFR trend
sparkline on the run dashboard), different implementations — I diffed them: one draws a filled area
+ latest-point marker and clamps a flat series at `1e-6`; the other draws a stroke-only line with
optional reject dots and clamps at `1e-3`. Two tiles on one dashboard therefore draw the same data
differently.

**Merge:** promote the `quality_panel.dart` version (it is the superset — it carries the
`accepted`/`rejectColor` reject markers) into a shared
`sequencer/widgets/run_dashboard/hfr_sparkline.dart` with the fill + latest-marker options added as
flags, and delete the `live_frame_panel.dart` copy. **Effort: small.**

### 2.3 Five re-implementations of "load a frame thumbnail" — **canonical exists and is unused by four of them**

`analytics/widgets/frame_thumbnail_loader.dart:49` defines `loadFrameThumbnail(ref, image)` +
`FrameThumbnailPayload` + `isFitsLikePath`, documented as the shared path. Independent
re-implementations of the same backend-thumbnail → local-file → placeholder ladder:

- `sequencer/widgets/run_dashboard/live_frame_panel.dart:889` (`_HistoryTileState._loadBytes`) and
  again at `:1152` (`_InspectPreview`) — **two in one file**
- `dashboard/widgets/cockpit_recent_frames.dart:270` (`_FrameTileState`)
- `sequencer/widgets/exposure_node_thumbnail_strip.dart:269`
- `settings/widgets/captured_images_settings.dart:151`
- `sequencer/widgets/run_dashboard/frame_detail_dialog.dart:235`

They have already drifted: the canonical uses a **denylist** (`isFitsLikePath`, rejecting
`.fits/.fit/.fts/.xisf`), while `live_frame_panel.dart:1045 _isImageLikePath` uses an **allowlist**
(`.png/.jpg/.jpeg/.tif/.tiff`). They disagree on every other extension and on extension-less paths,
so the same frame shows a preview in one surface and a placeholder icon in another.

**Merge:** move `frame_thumbnail_loader.dart` to a neutral home
(`packages/skotiq_app/lib/widgets/frame_thumbnail_loader.dart`), add a `FrameThumbnail` widget
that wraps the ladder + spinner + placeholder, and re-point all six sites. **Effort: medium.**

### 2.4 Two flat-calibration orchestrators

`flat_wizard/flat_wizard_screen.dart` (route `/flat-wizard`,
`app_router.dart:315`) drives calibration through `FlatWizardNotifier.runCapture`
(`flat_wizard/flat_wizard_screen/action_buttons.dart:185`) — the hardened path with a
`FlatCancelToken`, event-correlated exposure waits and a persisted outcome.
`sequencer/widgets/flat_wizard_dialog.dart` (opened from `sequencer/widgets/sequence_toolbar.dart:128`)
re-implements the same per-filter loop **in widget state** at lines 302–404: its own
`_runGeneration`, its own `FlatCancelToken`, its own `Map<String, FlatResult> _results`, its own
filter-wheel move + `calibrateFilter` loop, its own cancellation and snapshot-invalidation rules.
It reaches into the notifier only for `moveFilterWheelAndWait` (line 312).

**Canonical survivor:** `FlatWizardNotifier`. Move the dialog's loop body (302–404) into a notifier
method that takes the snapshot/config and returns the per-filter results, and let the dialog render
notifier state. The dialog's `_generateFlatSequence` (405+) is genuinely dialog-only (it emits
sequence nodes) and stays. **Effort: large** — two independently hardened cancellation models have
to be reconciled; do not do this in the same pass as a file split.

### 2.5 Five bespoke commit-on-blur settings rows vs. the canonical `SettingsTextInput`

`settings/widgets/settings_widgets/settings_text_and_number_inputs.dart:3` defines
`SettingsTextInput`, which already implements: authoritative-value sync, an `authorityKey` so a
backend switch discards the previous host's pending edit, a serialised write tail, dirty-edit
preservation, and rollback on failed save.

`settings/widgets/science_settings.dart` re-implements a weaker version of the same thing five
times: `_AavsoObserverCodeRow` (404), `_MpcObservatoryCodeRow` (521), `_ScienceTextRow` (640),
`_TnsApiKeyRow` (775), `_ScienceCameraValueRow` (1027). Each has its own
`_onFocusChange`/`_loadValue`/`_commit` triple with the same shape. None of the first three has an
authority key, and all three read the provider **once** in `initState` via
`ref.read(scienceSettingsProvider).valueOrNull` (e.g. `:431`, `:549`, `:690`) — if the async
provider has not resolved yet the field renders empty and never refills.

**Merge:** rebuild all five on `SettingRow` + `SettingsTextInput`, passing `authoritativeValue`
from a `ref.watch` of the science provider and `authorityKey` from `backendProvider`. Removes
~600 lines and closes the reliability defect in §5.1. **Effort: medium.**

### 2.6 Six copy-pasted optimistic-set/persist/rollback pairs in the guiding screen

`guiding/guiding_screen_parts/desktop_sections.dart` — `_setSettlePixels`/`_persistSettlePixels`
(1244/1251), `_setSettleTimeout`/`_persistSettleTimeout` (1269/1276),
`_setSettleTime`/`_persistSettleTime` (1296/1303), `_setDitherRaOnly`/`_persistDitherRaOnly`
(1323/1329), `_setDitherAmount`/`_persistDitherScale` (1345/1352). Every pair is: set local state →
call a distinct `AppSettings` setter → on error restore the rollback value and show the same error
banner. ~140 lines of the same six-line body.

**Merge:** one generic `Future<void> _persistGuidingSetting<T>({required T value, required T
rollback, required void Function(T) apply, required Future<void> Function(T) write, required String
label})`. **Effort: small.**

### 2.7 Dashboard "classic" cards vs. "cockpit" tiles — *deliberate, do not delete*

`dashboard/widgets/dashboard_widget_registry.dart` registers 24 `cockpit*` tiles (119–334) and then
13 `classic` tiles (347+) under an explicit comment "Legacy control/info cards (disabled by default;
retained for power users)", with `DashboardWidgetGroup.classic` and titles already disambiguated
("Guiding (classic)" at :378, "Equipment (classic)" at :390). Several pairs render the same data
twice: `guiding`↔`cockpitGuiding`, `livePreview`↔`cockpitLiveFrame`,
`equipmentStatus`↔`cockpitEquipmentTelemetry`, and the frames tiles.

**This is a product decision already made and documented — a mapper should not propose deleting
it.** The actionable part is only that the two generations must not carry *independent
implementations of the same rendering*: fold §2.1 and §2.3 so the classic and cockpit cards call the
same graph and the same thumbnail loader. **Effort: covered by 2.1/2.3.**

### 2.8 Autofocus settings: desktop and mobile layouts are the same list twice

`settings/widgets/autofocus_settings.dart:174` (`_buildDesktopTwoColumnLayout`, 290 lines) and
`:464` (`_buildMobileLayout`, 290 lines) render the same setting rows with different containers, and
`_buildFilterSettingsTable` (864) / `_buildFilterSettingsMobile` (948) do it again for the filter
table. Divergence here is a live risk (a setting added to one layout and not the other is invisible
on the other form factor).

**Merge:** define the rows once as a `List<Widget> _rows(...)` (they all already go through
`_buildAfSettingRow` at :755 and `_afNumberInput` at :71) and let the two layout methods only choose
the container. **Effort: medium.** Do §1.27's split first.

---

## 3. Suspected cross-package duplication (for the cross-cutting agent)

- ~25 private `_formatDuration` / `_formatTime` / `_formatDateTime` helpers across these paths (e.g.
  `sequencer/widgets/target_header_card.dart:691`, `sequencer/tabs/history_tab.dart:870`,
  `sequencer/widgets/preflight_validation_dialog.dart:1215`, `dashboard/widgets/session_progress_card.dart:15`)
  while `skotiq_core` already exports `formatHms`
  (`skotiq_core/lib/src/models/imaging/stack_and_share_models.dart:999`) and
  `formatIntegrationSeconds` (used at `skotiq_core/lib/src/providers/sequence_stats_provider.dart:343`).
- `_formatBytes` in `diagnostics/diagnostic_dump_screen.dart:381` and
  `settings/catalog_settings_screen/card_builders.dart:243` — two byte formatters; a third probably
  lives in the backup/storage code in `skotiq_core`.
- The guide-graph renderers (§2.1) span `skotiq_app` and `skotiq_ui` — the canonical is
  already in `skotiq_ui`.
- `flat_wizard/widgets/flat_preview_panel.dart:307 _HistogramPainter` vs
  `imaging/widgets/overlay_widgets.dart:187 HistogramPainter` vs the analytics histogram — three
  histogram painters; likely a fourth in `skotiq_ui`'s design gallery.
- `sequencer/widgets/mosaic_wizard_dialog/painters.dart:3 _StarFieldPainter` vs
  `imaging/widgets/overlay_painters/basic_overlays.dart:3 StarFieldPainter` — two decorative
  star-field painters; the planetarium package almost certainly has a real one.
- The flat-calibration loop (§2.4) is orchestrated in the Dart widget layer in one place and in
  `FlatWizardNotifier` in another; a third orchestration may exist in the headless/native sequencer
  flat instruction — worth checking against the Rust `flat` instruction executor.
- `settings/pairing_screen.dart`'s `PairingNotifier` talks to a `PairingDatabase` instance separate
  from the HTTP pairing endpoint's own instance (documented at `pairing_screen.dart:200-204`) —
  two independent readers of one database file; likely mirrored in the headless host.
- The device icon / device-type-label switch tables (`settings/pairing_screen.dart:841`, `:862`)
  smell like duplicates of the equipment-package device-type presentation
  (`equipment/utils/`, `skotiq_ui`).

---

## 4. Dead code (evidence: `grep -rnw --include="*.dart" <symbol> packages apps` returned only the definition site)

### 4.1 Three entirely unreferenced files — **1267 lines**

| file | lines | evidence |
|---|---:|---|
| `sequencer/widgets/sequence_enhancements.dart` | 544 | Its four public classes `EstimatedCompletionWidget` (:8), `LoopIterationBadge` (:406), `NodeProgressIndicator` (:457), `ActiveBranchHighlight` (:513) each have exactly **2** repo-wide occurrences (the `class` line and the constructor). The file is re-exported by `packages/skotiq_app/lib/skotiq_app.dart:62` — **that barrel export is the only reason the analyzer stays quiet**; no `apps/` or `packages/` file imports the symbols. |
| `sequencer/widgets/run_dashboard/playback_footer.dart` | 334 | `RunDashboardPlaybackFooter` (:19) has 2 occurrences; `grep -rn "playback_footer" --include="*.dart" packages/` → no hits. Not imported by anything, not in the barrel. |
| `sequencer/widgets/session_report_forensics_section.dart` | 389 | `ForensicsRunSection` (:23) has 2 occurrences; `grep -rn "session_report_forensics_section"` → no hits. Note the run dashboard *does* have a forensics panel (`run_dashboard/forensics_panel.dart` + `DashboardWidgetId.cockpitForensics`) — this file is the superseded second version. |

**Action:** delete all three plus the barrel export line at `skotiq_app.dart:62`.

### 4.2 Individually unreferenced public widgets

| symbol | file:line | evidence |
|---|---|---|
| `CompactBackendSelector` | `equipment/widgets/backend_selector_chips.dart:227` | 2 occurrences (class + ctor). The file's other selector is used; this compact variant never was. |
| `ControlSection` | `imaging/widgets/panel_widgets.dart:183` | 2 occurrences. |
| `AddProfileChip` | `equipment/widgets/profile_chip.dart:272` | 4 occurrences, all inside the declaration (class, ctor, `createState`, `_AddProfileChipState`). Its sibling `ProfileChip` **is** used — only the "+" variant is dead. |

**Care taken / explicitly NOT claimed dead:** headless API routes, FRB exports and registry lookups
are outside these paths. Within these paths I ruled out `DashboardTileFrame`,
`DashboardGlassCardInline`, `GuideStarList`, `OverlaysMenuButton`, `HistogramPainter`,
`ThumbnailStripPrefsNotifier`, `RunDashboardBudgetProgress`, `SchedulerDecisionView`,
`SmartNightWatchdog`, `MountJogControls` and ~20 others — each has a real same-file call site, which
a naive cross-file grep reports as dead. `dashboard_widget_registry.dart` is a registry: every
`_build*` function in it is reached only through a `DashboardWidgetDefinition.builder` field, so
none of those are dead either.

---

## 5. Reliability risks

### 5.1 Failed science-settings writes throw into an unawaited future — three sites

`settings/widgets/science_settings.dart`:
- `_AavsoObserverCodeRowState`: `_onFocusChange` (:427) calls `_commit()` **without awaiting**;
  `_commit` (:440) does `try { await notifier.setAavsoObserverCode(trimmed); } catch (_) {
  _lastCommitted = previous; rethrow; }` — the `rethrow` is at **:458**.
- `_MpcObservatoryCodeRowState`: same shape at `:545` / `:558`, `rethrow` at **:577**.
- `_ScienceTextRowState`: same shape at `:686` / `:702`, `rethrow` at **:719**.

The rethrow lands on a future nobody holds, so a failed write becomes an uncaught async error: the
operator sees **no** error, the text stays on screen, and the value was not saved. Contrast
`_ScienceCameraValueRowState._commit` (:1091), which is the correct sibling — it catches, invalidates
the provider, restores the previous text (`_lastCommitted = previous` at :1113) and shows a
`SnackBar` (:1120). **Fixing this is a side-effect of §2.5.**

### 5.2 `_TnsApiKeyRow` keyring write has no error path at all

`settings/widgets/science_settings.dart:803-818`: `_commit` `await`s
`secretsStore.write(SecretField.tnsApiKey, trimmed)` (:809-811) inside a
`try { … } finally { _saving = false; }` with **no `catch`**, called unawaited from `_onFocusChange`
(:794). A keyring failure (locked
keyring, no D-Bus secret service — a real condition on a headless Linux host) clears nothing, shows
nothing, and the operator believes the TNS bot key is stored. Same fix vehicle as §5.1.

### 5.3 `_HistoryTile` refetches every visible thumbnail whenever a frame lands

`sequencer/widgets/run_dashboard/live_frame_panel.dart:824-830`: the `ListView.separated`
`itemBuilder` constructs `_HistoryTile(...)` **with no `key`**. The list is
`tail.reversed.toList()` (:789), so a newly-captured frame shifts every index by one; Flutter reuses elements
by position, `didUpdateWidget` (:881-887) sees a different `image.id` on *every* visible tile and
re-runs `_loadBytes()` (:889) → up to 24 `getImageThumbnail` calls per captured frame, over HTTP in
remote mode. Fix: `key: ValueKey(image.id)` on the tile. (Also listed under perf; the reliability
edge is that a burst of 24 concurrent backend calls per frame is exactly the shape that trips
request timeouts on a Pi host.)

### 5.4 `_ScienceTextRow` and siblings read their value once, synchronously, from an async provider

`science_settings.dart:432`, `:550`, `:691`: `ref.read(scienceSettingsProvider).valueOrNull` inside
`_loadValue`, called from `initState`, then `_loading = false` (`:437`, `:555`, `:699`)
unconditionally. If the provider is still loading at mount, the
field renders blank forever and `_lastCommitted` stays `''`. Not a crash, but the row lies about the
stored value. Closed by §2.5 (`authoritativeValue` is a `watch`).

### 5.5 `_ScienceTextRow._loadValue` sets `_loading = false` outside a mounted check

`science_settings.dart:690-700` — the `mounted` guard covers only the assignment branch (`:692`);
the `_loading = false` at `:699` runs regardless. Harmless today (no `setState`), but it is the kind of
line that becomes a `setState after dispose` the moment someone adds one. Low severity; note it in
the same edit.

**Explicitly checked and clean** (so a verifier does not re-derive it): every `StreamSubscription`
in these 12 directories is cancelled/closed (`grep -rl StreamSubscription | grep -L 'cancel()|close()'`
→ empty); `TextEditingController`s in the wizard dialogs are disposed
(`quick_start_wizard_dialog.dart:431-445`, `mosaic_wizard_dialog/config_controls.dart:501,678`); the
periodic timers all cancel in `dispose` and most also handle `AppLifecycleState.paused`
(`log_viewer.dart:134-155`); there is no `readAsStringSync`/`readAsBytesSync` on the UI isolate in
these paths (only two `existsSync()` calls, `frame_detail_dialog.dart:303` and
`diagnostic_dump_screen.dart:45`, both cheap and off the hot path).

---

## 6. Performance risks

### 6.1 `AppShell` watches all of `appSettingsProvider` to read one bool — **impact: medium**

`shell/app_shell.dart:731` `final appSettingsAsync = ref.watch(appSettingsProvider);`. In the whole
290-line `build` (729–1020) the value is used exactly **once**, at :759:
`final isSideNavExpanded = settings != null ? !settings.sidebarCollapsed : _fallbackSideNavExpanded;`
(verified by scanning lines 729–1020 for `settings.` — one hit). `AppShell` is the root of every
routed screen, so *any* `AppSettings` write — every settings toggle, every autosave, every remote
settings push — rebuilds the shell chrome, the nav, the status bar, the mini-player and the routed
child's element tree.
**Fix:** `ref.watch(appSettingsProvider.select((a) => a.valueOrNull?.sidebarCollapsed))`.

### 6.2 `AppShell` registers a post-frame callback on every build — **impact: low**

`shell/app_shell.dart:781-790`: `WidgetsBinding.instance.addPostFrameCallback((_) { … immersive.enabled
= useBottomNav; … })` inside `build`. One closure allocation + one callback per shell rebuild;
compounding with 6.1 this fires on every settings write. **Fix:** hoist the `immersive.enabled`
assignment into `didChangeDependencies`/a listener, or guard on a changed value.

### 6.3 Run-dashboard history column refetches N thumbnails per frame — **impact: medium**

See §5.3. `live_frame_panel.dart:824-830` (missing key) → `:881` (`didUpdateWidget`) → `:894`
(`backend.getImageThumbnail`). Worst on a remote/Pi session where each fetch is an HTTP round-trip.

### 6.4 Log viewer polls 500 entries over HTTP at 1 Hz and rebuilds unconditionally — **impact: medium**

`settings/widgets/log_viewer.dart:129` `Timer.periodic(const Duration(seconds: 1), (_) =>
_refreshLogs())`. `_refreshLogs` (:158) issues `backend.fetchRecentServerLogs(limit: 500)` (:172)
against a `NetworkBackend`, then on every response does `setState` with a fresh
`_availableSources` `Set` (:182) and a full `_applyFilters()` re-scan of 500 entries (:228) — with
**no equality check against the previous tail**, so an idle host still costs a 500-entry payload, a
full re-filter and a full subtree rebuild every second for as long as the panel is open.
**Fix:** compare against the last payload (cheapest: last entry timestamp + length) and skip the
`setState` when unchanged; back the poll off to 2–3 s when the tail has not moved.

### 6.5 Pairing screen rebuilds its whole tree once a second for a countdown — **impact: low**

`settings/pairing_screen.dart:199-206`: `Timer.periodic(1s)` whose body is
`state = state.copyWith(); // Trigger rebuild for countdown`. `PairingScreen.build` (:429+) is the
whole 600-line screen including the paired-device list, so the entire tree rebuilds each second
while a code is outstanding (bounded to the 5-minute code lifetime). It also fires a DB query per
tick via `unawaited(_checkPairingCompleted())` (:220) — that one is documented and justified.
**Fix:** move the countdown text into its own small `Consumer`/`ValueListenableBuilder` so only the
timer chip rebuilds.

**Explicitly checked and clean:** the long lists in these paths all use builders
(`log_viewer.dart:834`, `live_frame_panel.dart:820`); `_HistoryColumn` caps itself at 24 frames
(`live_frame_panel.dart:776`) and `_hfrHistory` caps at 40 points (`:124`); the framing altitude
ticker is 1/min (`framing/altitude_chart.dart:88`) and documents why; no repeated `jsonDecode` on a
build path was found in these directories.

---

## 7. Suggested order of work

1. **Delete the 1267 dead lines** (§4.1) + the three dead widgets (§4.2) and the barrel export at
   `skotiq_app.dart:62`. Zero-risk, and it shrinks the surface every later step has to touch.
2. **§6.1 + §6.2** — one-line `select` on the app root; the single highest-leverage perf change here.
3. **§5.1/§5.2 via §2.5** — rebuild the five science rows on `SettingsTextInput`. Fixes three
   silent-failure sites, one un-caught keyring write, and drops `science_settings.dart` under 1000
   lines without any file surgery.
4. **§2.2** — merge the two `_HfrSparklinePainter`s (small, and it must land before §1.5 so only one
   copy moves).
5. **§5.3/§6.3** — add `key: ValueKey(image.id)` to `_HistoryTile`.
6. **§1.7 `quick_start_wizard_dialog.dart`** — extract `_finishWizard` (428 lines) to its own part,
   then decompose it there. Highest-risk file in the set; do it while the tree is otherwise quiet.
7. **§1.20 `app_shell.dart`** — extract `app_startup_checks.dart` (already-public, already-tested
   symbols) and the three `extension` parts.
8. **§2.3** — one `FrameThumbnail` widget for all six frame-preview sites; closes the
   allowlist-vs-denylist divergence.

Everything else in §1 is mechanical and can be parallelised across implementers, one file per
change, as long as each keeps to the `part`-file convention described in §0.
