# Release-pass map — app-screens-b

Subsystem: `skotiq_app` discovery/science screens + shared app infra.

Paths in scope:
- `packages/skotiq_app/lib/screens/{analytics, collaborative_sky, constellation, first_light, mosaic, onboarding, planetarium, planner, scheduler, science, session_review, stack_result, suggestions, tonight, transients, tutorial, your_sky}`
- `packages/skotiq_app/lib/{router, services, widgets, mixins, models, utils, localization}`

Totals measured with `wc -l` (generated files excluded): 86,445 lines across the screen dirs, 37,318 across the shared-infra dirs.

## Repo convention that all split plans below follow

This package already has an established, uniform file-splitting convention: a parent
`foo.dart` declares `part 'foo_parts/_x.dart';` and each part begins with

```dart
// Part of ../foo.dart -- extracted for maintainability.
//
// <one line saying what lives here>
part of '../foo.dart';
```

Confirmed live at `packages/skotiq_app/lib/screens/planner/planner_screen.dart:33-43`
(11 parts) and `packages/skotiq_app/lib/screens/analytics/widgets/science_analytics_tab.dart:38-41`
(4 parts). **Every split below uses this same mechanism.** That matters because it makes
the splits genuinely behavior-preserving: private classes and private members stay
visible across a `part` boundary, so no member has to be widened from `_private` to
public, no import graph changes, and no test that reaches a private symbol breaks.

---

# 1. OVERSIZED FILES

All counts verified with `wc -l`. None of these are generated; all are hand-written.
`translations.dart` looks machine-produced but is a hand-maintained data map (see 1.17).

| # | File | Lines |
|---|------|-------|
| 1.1 | `screens/session_review/session_review_controller.dart` | 1940 |
| 1.2 | `localization/skotiq_localizations/translations.dart` | 1486 |
| 1.3 | `screens/analytics/widgets/science_export_hub.dart` | 1448 |
| 1.4 | `screens/onboarding/onboarding_screen.dart` | 1255 |
| 1.5 | `screens/analytics/widgets/science_analytics_tab.dart` | 1191 |
| 1.6 | `screens/mosaic/mosaic_project_controller.dart` | 1121 |
| 1.7 | `screens/planetarium/widgets/search_header.dart` | 1044 |
| 1.8 | `screens/planner/planner_screen_parts/_candidate_list.dart` | 1028 |
| 1.9 | `screens/analytics/widgets/science_analytics_tab/science_cards.dart` | 1028 |
| 1.10 | `screens/session_review/widgets/sub_cull_rail.dart` | 1026 |
| 1.11 | `screens/planner/planner_screen_parts/_filter_controls.dart` | 1022 |
| 1.12 | `screens/analytics/widgets/project_tracking_panel.dart` | 1017 |
| 1.13 | `screens/stack_result/stack_result_screen.dart` | 1014 |
| 1.14 | `screens/planetarium/planetarium_screen/actions.dart` | 1014 |
| 1.15 | `screens/analytics/widgets/image_grader_dialog.dart` | 1007 |
| 1.16 | `screens/analytics/widgets/image_thumbnail_strip.dart` | 1005 |
| 1.17 | `screens/suggestions/widgets/transient_alerts_panel.dart` | 1000 |

---

## 1.1 `screens/session_review/session_review_controller.dart` — 1940 lines — HIGH risk

**Why it is big.** Three unrelated concerns in one file: (a) ~535 lines of value/model
types with hand-written `==`/`hashCode` (lines 20-554), (b) a 1360-line `StateNotifier`
that owns *five* separate workflows — load/refresh, sub culling, integration, native
"finishing" image ops, and narrowband compositing (555-1912), (c) providers (1913-1940).
There is no `part` split at all today, unlike its sibling screens.

**Split plan** (create `screens/session_review/session_review_controller_parts/`, add
`part` directives to the head of `session_review_controller.dart`):

| New file | What moves in | Current lines |
|---|---|---|
| `_models.dart` | `SessionReviewScope`, `SessionReviewViewMode`, `CullOutcome`, `CullToRecommendedResult`, `CullOfferStatus`, `CullRecommendationOffer`, `GrowthPoint`, `BestNight`, `NarrowbandChannelRef`, `typedef CoreBestNight` | 16-270 |
| `_state.dart` | `SessionReviewState` incl. `copyWith`, `narrowbandChannels`, `busy`, `lights`/`acceptedLights`/`acceptedCount`/`rejectedCount`, `coverageMapPath` | 271-554 |
| `_load.dart` | `_load`, `_loadSubs`, `_resolveTarget`, `_resolveTargetHint`, `_resolveTitle`, `_two`, `_loadDefaultSettings`, `refresh`, `updateSettings`, `_reloadSubs`, `loadSmartData`, `_loadNightReport`, `_loadImprovementCurve`, `_loadGrowthAndBestNight`, `_loadAnnotationLayer`, `_resolveMasterWcs` | 674-1097 |
| `_cull.dart` | `setAccepted`, `bulkReject`, `setViewMode`, `cullRecommendationOffer`, `cullToRecommended`, `integrationShortfall` | 587-617, 798-845, 1514-1631 |
| `_integrate.dart` | `integrate`, `_integrate`, `reIntegrate`, `reIntegratePreview` | 846-923, 1098-1155 |
| `_finishing.dart` | `runColorCalibration`, `_runColorCalibration`, `runBackgroundExtraction`, `runDeconvolve`, `runStarReduction`, `_runFinishingStep` | 1156-1387 |
| `_narrowband.dart` | `runNarrowband`, `loadComposites`, `_masterById`, `narrowbandChannels()` | 1388-1513 |
| `_masters.dart` | `addToAccumulatingMaster`, `createAccumulatingMaster`, `finalizeMaster`, `deleteMaster`, `_bestReference`, `_refreshMasters`, `_publishMasters`, `_resolveReviewedMaster`, `_masterInListById`, `_outputDir`, `_filterMatches`, `_safeName`, `_suffixBeforeExtension`, `_swapExtension` | 1632-1911 |

**What stays in the parent** (target ~250 lines): imports, the `part` directives, the
class declaration + constructor (555-566), all fields, the DAO getters (618-622),
`_withLiveProgress` (636-649), `_bindProgress` (651-668), `dispose` (669-673) — i.e.
the lifetime/seam plumbing that every part depends on — plus
`FinishingPreviewRenderer`, `finishingPreviewRendererProvider` and
`sessionReviewControllerProvider` (1913-1940).

**Mechanism.** The five workflow parts each become an
`extension _SessionReviewLoad on SessionReviewController { ... }` inside their part file
(same technique already used at `screens/planetarium/planetarium_screen/actions.dart:3`).
`_models.dart` / `_state.dart` are plain top-level declarations. Nothing changes visibility.

---

## 1.2 `localization/skotiq_localizations/translations.dart` — 1486 lines — LOW risk

**Why it is big.** Pure data: one `Map<String, Map<String, String>> _localizedValues`
with an `'en'` block at line 7 and an `'es'` block at line 745. Hand-written despite
looking generated — it is already a `part of '../skotiq_localizations.dart'`.

**Split plan.** Replace the single part with two, keeping the assembly in the parent:
- `translations_en.dart` — `const Map<String, String> _enStrings = { ... }` (current 8-744).
- `translations_es.dart` — `const Map<String, String> _esStrings = { ... }` (current 746-1485).
- Parent keeps `final Map<String, Map<String, String>> _localizedValues = {'en': _enStrings, 'es': _esStrings};`

This is mechanical and the lowest-value item on the list; do it only if a third locale
lands. Included for completeness because it is over the threshold.

---

## 1.3 `screens/analytics/widgets/science_export_hub.dart` — 1448 lines — HIGH risk

**Why it is big.** A widget file that also carries the entire CSV serialisation layer for
seven science datasets. Lines 1073-1448 are **seven near-identical row builders**
(`_buildPhotometryRows` 1073, `_buildFrameQualityRows` 1129, `_buildTransparencyRows`
1197, `_buildPsfTileRows` 1243, `_buildResidualRows` 1291, `_buildCalibrationRows` 1341,
`_buildMovingObjectRows` 1393) each repeating the same five steps: literal header row →
optionally append standalone rows via `_standaloneRows(...)` → append per-session rows
via `ref.read(session*Provider(id).future)` → filter with `_withinDateRange(m.timestamp)`
→ map each row to a `List<dynamic>`. It also owns a 600-line `build` (209-557).

**Split plan** (there is already one part, `science_export_hub/export_controls.dart`; add three more):

| New file | What moves in | Current lines |
|---|---|---|
| `science_export_hub/_seams.dart` | `scienceExportDirectoryProvider`, `ScienceExportSavePicker`, `_defaultScienceExportSavePicker`, `scienceExportSavePickerProvider`, `ScienceExportFileWriter`, `scienceExportFileWriterProvider`, `_utcStamp`, `_julianDate` | 42-110 |
| `science_export_hub/_dataset_rows.dart` | all seven `_build*Rows` + `_standaloneRows` + `_withinDateRange` | 1049-1448 |
| `science_export_hub/_actions.dart` | `_openMpcPanel`, `_openTransientPanel`, `_exportData`, `_generateReport`, `_sessionLabel`, `_pickDate`, `_newestSessionId` | 705-1048 |
| `science_export_hub/_filters.dart` | `_buildDateFilters`, `_buildSessionFilter` | 558-704 |

**What stays in the parent** (~560 lines): `ScienceExportDataset`, `ScienceExportHub`,
`_ScienceExportHubState` fields/`initState`/`dispose`/`_isCurrentAuthority`, and `build`.

**Additional de-duplication inside `_dataset_rows.dart`** (do this as the same work order —
it is what makes the file stop growing): introduce one descriptor and one generic builder.

```dart
class _ExportDataset<T> {
  final List<String> header;
  final ProviderListenable<Future<List<T>>> standaloneExport;
  final ProviderListenable<Future<List<T>>> Function(int sessionId) perSession;
  final DateTime Function(T row) timestampOf;
  final List<dynamic> Function(T row) toCsvRow;
}
```

with a single `Future<List<List<dynamic>>> _rowsFor<T>(_ExportDataset<T> d, List<int> sessionIds, {required bool includeStandalone})`.
Each of the seven builders then collapses to a `const`-shaped descriptor: the header list
and the `toCsvRow` closure are the only genuinely per-dataset code. Expected reduction:
~375 lines → ~180. Do **not** change the header strings or the column order — the CSVs
are a published output format and tests assert on them.

---

## 1.4 `screens/onboarding/onboarding_screen.dart` — 1255 lines — MEDIUM risk

**Why it is big.** Two things: a wizard *controller* (state machine: advance/back/skip/
exit/validate/create-profile/finish, lines 80-460) and a wizard *chrome kit* (six
presentational widgets, lines 679-1255) living in the same file as the three responsive
layout builders (461-678). The per-step bodies were already extracted to
`screens/onboarding/steps/` (14 files, 4718 lines) — the chrome was not.

**Split plan** (create `screens/onboarding/onboarding_screen_parts/`):

| New file | What moves in | Current lines |
|---|---|---|
| `_notice.dart` | `_WizardNotice`, `onboardingNoticeKey`, `_NoticeBand` | 43, 54-71, 679-708 |
| `_chrome.dart` | `_Header`, `_PhoneHeader`, `_PhoneFooter`, `_Footer`, `phonePrimaryActionKey` | 38, 709-981, 1181-1255 |
| `_sidebar.dart` | `_StepSidebar` incl. `labelFor`, `_stepLabels`, `_stepIcons` | 982-1134 |
| `_body.dart` | `_StepBody` (the step dispatcher) | 1135-1180 |
| `_flow.dart` | `_showNotice`, `_clearNotice`, `_resolveNotice`, `_runTransition`, `_onNext`, `_advance`, `_onBack`, `_goBack`, `_onSkipStep`, `_skipStep`, `_confirmRemoveGuider`, `_handleSystemBack`, `_onExitWizard`, `_exitWizard`, `_createProfileAndAdvance`, `_finishTo`, `_finishToInternal`, `_finishToFirstLight`, `_validate` | 92-460 |

`_flow.dart` becomes `extension _OnboardingFlow on _OnboardingScreenState`.
**Parent keeps** (~230 lines): `OnboardingScreen`, the state class fields, `build`,
`_buildWizard`, `_buildWideWizard`, `_buildPhoneWizard`.

`phonePrimaryActionKey` / `onboardingNoticeKey` are widget-test anchors; they must stay
top-level and reachable from `package:skotiq_app/screens/onboarding/onboarding_screen.dart`
— a `part` split preserves that exactly.

---

## 1.5 `screens/analytics/widgets/science_analytics_tab.dart` — 1191 lines — HIGH risk

**Why it is big.** A single `build` method spanning lines 298-977 (679 lines) that reads
~35 providers and then lays out nine science sections inline. This is also the source of
the worst perf finding in this subsystem (see 4.1) — the split and the perf fix are the
same work order.

**Split plan** (four parts already exist; add three, and restructure `build`):

| New file | What moves in | Current lines |
|---|---|---|
| `science_analytics_tab/_session_resolution.dart` | `latestScienceSessionProvider`, `latestScienceProductSessionProvider`, `_buildSessionIndexState`, `_buildScienceDataState`, `_buildScienceDataNotice`, `_retryScienceData`, `_sessionBar` | 62-96, 173-275, 978-1191 |
| `science_analytics_tab/_data_bundle.dart` | new: a `_ScienceTabData` record + a `_ScienceTabData _readData(WidgetRef, int? sessionId)` that performs *all* the `ref.watch` of session/sessionless dataset providers currently inlined at 355-430 and 507-524, plus the `track`/`resolvedRows` helpers | 330-430, 507-527 |
| `science_analytics_tab/_sections.dart` | the nine section layout blocks currently inline in `build` between ~530 and ~977, each becoming a `Widget _sectionX(_ScienceTabData d, ...)` | 530-977 |

**Parent keeps** (~180 lines): imports, part directives, `_ScienceSectionKeys`,
`ScienceAnalyticsTab`, state fields, `dispose`, `_jumpTo`, `_openExportHub`,
`_openCalibrationWizard`, `_goPickPhotometryTarget`, `_pairedCards`, and a `build` that
is a scroll view of section calls.

**Behaviour-preserving constraint for the implementer:** move the `ref.watch` calls
verbatim into `_readData`. Do not convert any of them to `ref.read` in this step — the
rebuild-scoping fix in 4.1 is a separate, testable change on top of the split.

---

## 1.6 `screens/mosaic/mosaic_project_controller.dart` — 1121 lines — MEDIUM risk

**Why it is big.** Local project work (load/capture/integrate/stitch) and hub-collaborative
work (publish/claim/release/upload/assemble/join/download) in one `StateNotifier`, plus a
228-line state class with hand-written derived getters.

**Split plan** (create `screens/mosaic/mosaic_project_controller_parts/`):

| New file | What moves in | Current lines |
|---|---|---|
| `_state.dart` | `MosaicProjectState` and all its getters (`isBusy`, `hubMosaicId`, `isPublished`, `collabStatus`, `unclaimedPanels`, `heldPanelCount`, `isOwner`, `integratedNotUploaded`, `panelsUploaded`, `panelsWithMasters`, `canStitch`, `isComplete`, `countWithStatus`, `copyWith`), `_MosaicProjectSnapshot` | 19-245 |
| `_local_actions.dart` | `load`, `_readSnapshot`, `canStartCapture`, `startCapture`, `integratePanels`, `stitchProject`, `clearError` | 326-533, 895-900 |
| `_hub_actions.dart` | `canCollaborate`, `_reloadAfterHubMutation`, `publishToHub`, `participantBulkClaimLimit`, `bulkClaimCount`, `claimPanel`, `claimPendingBatch`, `_runClaim`, `releasePanel`, `forceReleasePanel`, `uploadPanelMaster`, `uploadAllIntegrated`, `_runUpload`, `assembleFromHub`, `discoverMosaics`, `joinAsParticipant`, `refreshStatus`, `downloadOutput` | 534-894 |
| `_wiring.dart` | `MosaicProjectControllerArgs`, `mosaicProjectControllerProvider`, `mosaicProjectsListProvider`, the default path builders at 902-932 | 902-1121 |

**Parent keeps** (~130 lines): the class declaration, constructor, all `final` fields with
their (excellent, load-bearing) doc comments, and `loadTimeout`.

---

## 1.7 `screens/planetarium/widgets/search_header.dart` — 1044 lines — MEDIUM risk

**Why it is big.** One 277-line method, `_showOverlay` (125-401), builds an entire
`OverlayEntry` result list inline; three result-tile builders follow (402-596); then a
252-line `_SearchFilterControls` (753-1005) that is a separate feature (facet filters)
sharing the file only because it renders under the search box.

**Split plan** (create `screens/planetarium/widgets/search_header_parts/`; parent takes
`part` directives):

| New file | What moves in | Current lines |
|---|---|---|
| `_overlay.dart` | `_showOverlay`, `_hideOverlay`, `_flyToBestMatch` | 125-401, 597-627 |
| `_result_tiles.dart` | `_buildDsoResultTile`, `_isSolarSystemBody`, `_buildSolarSystemResultTile`, `_buildStarResultTile`, `SearchCategoryHeader` | 402-596, 1006-1044 |
| `_filter_controls.dart` | `_SearchFilterControls` incl. `_typeFilterLabel` | 753-1005 |

`_overlay.dart` and `_result_tiles.dart` become `extension _SearchHeaderOverlay on _SearchHeaderState`
and `extension _SearchHeaderTiles on _SearchHeaderState`.
**Parent keeps** (~230 lines): `SearchHeader`, state fields, `_layerLink`, `_focusNode`,
`_onFocusChanged`, `initState`, `dispose`, `_parseCoordinates`, `_onTextChanged` (the
debounce, 98-124), `build`.

`SearchCategoryHeader` is public and imported by tests; keeping it in a `part` preserves
its import path.

---

## 1.8 `screens/planner/planner_screen_parts/_candidate_list.dart` — 1028 lines — MEDIUM risk

**Why it is big.** It is *already* a part file, but has accreted an entire modal dialog
(`_CandidateObservingListDialog`, 443-761 = 318 lines) plus five chip/badge primitives on
top of the actual list.

**Split plan** — replace the single `part` at `planner_screen.dart:37` with three:
- `_candidate_list.dart` (keep, ~330 lines): `_CandidateList`, `_CandidateRowInfo`,
  `_CandidateAltitudePanel`, `_CandidateRow` (10-442).
- `_observing_list_dialog.dart` (new, ~340 lines): `_CandidateObservingListDialog`,
  `_CandidateObservingListDialogState`, `_ObservingListRow` (443-841).
- `_candidate_chips.dart` (new, ~190 lines): `_ScoreBadge`, `_IntegrationEstimateChip`,
  `_StatChip`, `_CandidateSkeleton` (842-1028).

Register the two new parts in `planner_screen.dart` next to line 37. No symbol changes.

---

## 1.9 `screens/analytics/widgets/science_analytics_tab/science_cards.dart` — 1028 lines — LOW risk

**Why it is big.** Eight independent card widgets sharing one part file. Two of them are
stateful and large: `_AavsoExportButton` (3-163) and `_LineRatioCard` (693-992, 300 lines).

**Split plan** — replace the single `part` at `science_analytics_tab.dart:40` with four:
- `science_cards/_aavso_export_button.dart`: `_AavsoExportButton` + state (3-163).
- `science_cards/_light_curve_card.dart`: `_LightCurveChartCard` (164-382).
- `science_cards/_field_quality_cards.dart`: `_PsfHeatmapCard`, `_PsfHeatmapGrid`,
  `_ResidualCard`, `_MovingObjectCard` (383-692).
- `science_cards/_line_ratio_card.dart`: `_LineRatioCard` + state, `_MetricLine` (693-1028).

(`_MetricLine` is used by more than one card; keep it in the line-ratio file only if
grep confirms a single consumer — otherwise put it in `_field_quality_cards.dart` and
leave a one-line note. Verify before moving.)

---

## 1.10 `screens/session_review/widgets/sub_cull_rail.dart` — 1026 lines — MEDIUM risk

**Why it is big.** The rail state machine (lasso selection, blink comparison, keyboard
shortcuts) at 87-411, a 166-line toolbar at 412-578, and eight tile-level widgets at
605-1026.

**Split plan** (create `screens/session_review/widgets/sub_cull_rail_parts/`, convert
`sub_cull_rail.dart` into the parent):
- `_toolbar.dart`: `_CullToolbar`, `_SelectionPill` (412-604).
- `_lasso.dart`: `_LassoPainter` (605-628).
- `_tile.dart`: `_SubTile`, `_SelectMarker`, `_AcceptToggle`, `_Badge` (629-766, 833-856, 916-977).
- `_thumbnail.dart`: `_SubThumbnail` + state, `_SubDownloadButton` + state (767-832, 857-915).
- `_blink.dart`: `_BlinkView` (978-1026).

**Parent keeps** (~380 lines): `SubCullRail`, `_SubCullRailState` and the `GridView.builder`
at 339. Note that `_thumbnail.dart` is where the perf fix in 4.4 lands.

---

## 1.11 `screens/planner/planner_screen_parts/_filter_controls.dart` — 1022 lines — LOW risk

**Why it is big.** Nine independent filter controls plus three modal sheets plus three
`*ForTest` entry points, in one part.

**Split plan** — replace the `part` at `planner_screen.dart:36` with three:
- `_filter_controls.dart` (keep, ~330 lines): `_SearchField`, `_MagnitudeRangeControl`,
  `_SizeRangeControl`, `_formatSizeLabel`, `_MinAltitudeControl`, `_MoonSeparationControl`,
  `_SortDropdown` (6-81, 411-806).
- `_filter_dialogs.dart` (new, ~420 lines): `_ObjectTypeMultiSelect`, `_showObjectTypeDialog`,
  `showConstellationPickerForTest`, `showObjectTypeDialogForTest`, `_ConstellationDropdown`,
  `_ConstellationPickerDialog(+State)`, `_showAngleSlider`, `showAngleSliderForTest`
  (82-410, 912-1022).
- `_filter_chips.dart` (new, ~120 lines): `_ResetChip`, `_ControlChip`, and the two size
  constants `_kSizeFilterMinArcmin` / `_kSizeFilterMaxArcmin` (521-523, 807-911).

**Do not delete the three `*ForTest` wrappers.** They are live: `showConstellationPickerForTest`
is called from `test/screens/planner/constellation_filter_picker_test.dart:26`,
`showObjectTypeDialogForTest` from `test/screens/planner/object_type_dialog_stable_layout_test.dart:29`,
`showAngleSliderForTest` from `test/screens/planner/moon_filter_no_silent_apply_test.dart:45`.

---

## 1.12 `screens/analytics/widgets/project_tracking_panel.dart` — 1017 lines — MEDIUM risk

**Why it is big.** Two providers with real aggregation logic (16-94), the panel shell
(95-237), three header/sort widgets (238-555), and a 300-line project card (556-853) plus
its three sub-widgets.

**Split plan** (create `screens/analytics/widgets/project_tracking_panel_parts/`):
- `_providers.dart`: `ProjectSortMode`, `perFilterIntegrationProvider`,
  `untrackedTargetsCountProvider` (16-94).
- `_header.dart`: `_CleanupHeaderRow`, `_SummaryStatsHeader`, `_SummaryStat`, `_SortBar`
  (238-555).
- `_project_card.dart`: `_EnhancedProjectCard`, `_MetricChip`, `_FilterBreakdownRow` (556-983).
- `_skeleton.dart`: `_ProjectsLoadingSkeleton` (984-1017).

**Parent keeps** (~145 lines): `ProjectTrackingPanel` + `_ProjectTrackingPanelState`.

---

## 1.13 `screens/stack_result/stack_result_screen.dart` — 1014 lines — HIGH risk

**Why it is big.** A screen file that also contains the display-stretch pixel pipeline
(`_renderStretch` 658, `_linearGray` 686, `_linearColor` 709 — 135 lines of raw
`Uint16List`/`Uint8List` loops) and four export flows (`_export` 760, `_buildShareCardSpec`
852, `_acquisitionDate` 880, `_exportAstroBin` 893).

**Split plan** (create `screens/stack_result/stack_result_screen_parts/`):

| New file | What moves in | Current lines |
|---|---|---|
| `_seams.dart` | `StackResultSavePicker`, `_defaultSavePicker`, `StackResultShare`, `_defaultShare`, `stackResultSavePickerProvider`, `stackResultShareProvider`, `stackResultStretchEngineProvider`, `StackViewerStretch` | 24-125 |
| `_stretch.dart` | `_resolveDisplayRgba`, `_renderStretch`, `_linearGray`, `_linearColor`, `_stretchLabel`, `_buildStretchControl` | 548-750 |
| `_layouts.dart` | `_buildLoaded`, `_buildActions`, `_buildDesktopLayout`, `_buildMobileLayout`, `_buildViewer`, `_buildSidePanel`, `_ActionMenuRow`, `_StatRow`, `_StackResultAction` | 203-547, 952-1014 |
| `_export.dart` | `_suggestedFileName`, `_export`, `_buildShareCardSpec`, `_acquisitionDate`, `_exportAstroBin`, `_previewErrorMessage`, `_cleanErrorMessage`, `_resultLoadErrorMessage` | 195-202, 626-657, 751-951 |

**Parent keeps** (~110 lines): `StackResultScreen`, state fields, `build`, `_buildNotFound`.

Once `_stretch.dart` exists, the perf work in 4.2 is confined to one small file.

---

## 1.14 `screens/planetarium/planetarium_screen/actions.dart` — 1014 lines — MEDIUM risk

**Why it is big.** A single `extension _PlanetariumScreenActions on _PlanetariumScreenState`
(line 3) carrying 25 methods across five unrelated domains: mount sync, finder-chart export,
target routing, slew orchestration, keyboard handling, view transforms, and five modal
sheets.

**Split plan** — replace the one `part` in `planetarium_screen.dart` with five, each its
own extension on `_PlanetariumScreenState`:
- `planetarium_screen/actions/_sync_and_selection.dart`: `_performInitialSync`,
  `_applySkyTargetQuery`, `_handleObjectTapped`, `_dismissPopup` (4-118).
- `planetarium_screen/actions/_export.dart`: `_exportFinderChart` (119-241).
- `planetarium_screen/actions/_targets.dart`: `_sendToFraming`, `_addToSequencer`,
  `_addToTargetQueue`, `_addPopupObjectToTargetQueue` (242-325).
- `planetarium_screen/actions/_slew.dart`: `_handleSlewToTarget`, `_handleSlewAndCenter`,
  `_handleSlewCenterRotate`, `_handleSlewToCoordinates`, `_toggleSlewMode`, `_handleStopSlew`
  (326-506).
- `planetarium_screen/actions/_input_and_view.dart`: `_handleKeyEvent`, `_panView`, `_zoomIn`,
  `_zoomOut`, `_resetView` (507-659).
- `planetarium_screen/actions/_sheets.dart`: `_showFilterBottomSheet`, `_showContextMenu`,
  `_showObjectInfoBottomSheet`, `_showSidebarPanelSheet`, `_showMobileSearchDialog` (660-1014).

Six extensions on the same state class is legal and idiomatic; the existing single
extension is already proof the mechanism works here.

---

## 1.15 `screens/analytics/widgets/image_grader_dialog.dart` — 1007 lines — LOW risk

**Why it is big.** A data loader (24-106), the dialog (107-463), a 460-line slider kit
(464-923), and a rejection list (924-1007).

**Split plan** (create `screens/analytics/widgets/image_grader_dialog_parts/`):
- `_metrics.dart`: `ImageGraderPsfMetric`, `loadImageGraderPsfMetrics` (24-106).
- `_sliders.dart`: `_ThresholdSliders`, `thresholdSliderMax`, `maxRuleThumbValue`,
  `minRuleThumbValue`, `_DoubleRow`, `_IntRow` (464-813).
- `_preview.dart`: `_PreviewSummary`, `_Chip`, `_RejectionList` + state (814-1007).

**Parent keeps** (~360 lines): `ImageGraderDialog` + `_ImageGraderDialogState`.

`thresholdSliderMax` / `maxRuleThumbValue` / `minRuleThumbValue` are public and referenced
outside the file — a `part` preserves the import path.

---

## 1.16 `screens/analytics/widgets/image_thumbnail_strip.dart` — 1005 lines — MEDIUM risk

**Why it is big.** `_ImageThumbnail` (351-935) is 584 lines for one grid cell, of which
`build` alone is 403-716 (313 lines) and the rest is a context menu + a calibration-details
dialog.

**Split plan** (create `screens/analytics/widgets/image_thumbnail_strip_parts/`):
- `_filters.dart`: `_QualityFilter`, `_SummaryChip`, `_QualityFilterChip`,
  `kAnalyticsThumbnailRailHeight` (26-41, 291-350).
- `_thumbnail.dart`: `_ImageThumbnail`, `_ImageThumbnailState` fields/`initState`/`dispose`/
  `didUpdateWidget`/`build` (351-716).
- `_thumbnail_actions.dart`: `extension` carrying `_handleTap`, `_qualityTooltip`,
  `_getQualityColor`, `_getHfrColor`, `_showFrameMenu`, `_setAccepted`, `_menuPosition`,
  `_showCalibrationDetails`, `_FrameMenuAction` (717-929).
- `_badges.dart`: `_ScienceBadge`, `_DetailRow` (930-1005).

**Parent keeps** (~250 lines): `ImageThumbnailStrip` + `_ImageThumbnailStripState`.

---

## 1.17 `screens/suggestions/widgets/transient_alerts_panel.dart` — 1000 lines — MEDIUM risk

**Why it is big.** A panel (41-330), a badge (331-362), a 282-line alert tile (363-644),
a type badge (645-699), and a 300-line settings dialog (700-1000) — five features in one file.

**Split plan** (create `screens/suggestions/widgets/transient_alerts_panel_parts/`):
- `_alert_tile.dart`: `_TransientAlertTile` + state, `_TypeBadge` (363-699).
- `_settings_dialog.dart`: `_TransientSettingsDialog` + state (700-1000).
- `_badge.dart`: `_UnacknowledgedBadge`, `_runAlertStateAction` (9-32, 331-362).

**Parent keeps** (~290 lines): `transientPanelTnsCredentialsReadyProvider`,
`TransientAlertsPanel` + state.

While in `_alert_tile.dart`, apply finding 2.1 (delete `_typeLabel` at 604 and `_TypeBadge`'s
inline switch in favour of the shared style helper) — same work order.

---

# 2. DUPLICATION

## 2.1 Four independent, mutually-inconsistent `TransientType` → icon/colour/label maps — HIGH value

Same enum, four renderers, **and they disagree**. This is a user-visible correctness
problem, not just tidiness: the same alert renders in a different severity colour and
under a different name depending on which screen you are on.

Sites (all inside my paths):

| File:line | What it maps |
|---|---|
| `screens/transients/widgets/transient_card.dart:383` | icon |
| `screens/transients/widgets/transient_card.dart:404` | colour |
| `screens/transients/widgets/transient_card.dart:425` | label |
| `screens/suggestions/widgets/transient_alerts_panel.dart:657` (`_TypeBadge`) | icon + colour |
| `screens/suggestions/widgets/transient_alerts_panel.dart:604` | label |
| `screens/suggestions/widgets/transient_alerts_panel.dart:980` | label (again, in the settings dialog of the *same file*) |
| `screens/transients/transients_screen.dart:753` | label |
| `widgets/transient_alert_badge.dart:529` | icon |
| `widgets/transient_alert_badge.dart:550` | colour |
| `widgets/transient_alert_badge.dart:671` | label |

Concrete disagreements:
- `supernova` colour: `colors.error` (`transient_card.dart:408`, `transient_alert_badge.dart:552`)
  vs `colors.warning` (`transient_alerts_panel.dart:659`).
- `variableStar` colour: `colors.success` (`transient_card.dart`) vs `colors.warning`
  (`_TypeBadge`) vs `colors.accent` (`transient_alert_badge.dart`).
- `gammaRayBurst` colour: `colors.error` vs `colors.accent` vs `colors.warning` — all three.
- `gammaRayBurst` label: `'Gamma-Ray Burst'` (`transient_card.dart:425`,
  `transient_alert_badge.dart:671`) vs `'GRB'` (`transients_screen.dart:753`,
  `transient_alerts_panel.dart:980`) vs `'GRB Afterglow'` (`transient_alerts_panel.dart:604`).
- `cataclysmic` label: `'Cataclysmic Variable'` vs `'Cataclysmic'`.
- `variableStar` label: `'Variable Star'` vs `'Variable'`.
- `supernova` icon: `SkotiqIcons.sparkle` vs `LucideIcons.sparkles`.

**Canonical survivor:** a new `packages/skotiq_app/lib/utils/transient_type_style.dart`
exposing

```dart
class TransientTypeStyle {
  static IconData icon(TransientType t);
  static Color color(TransientType t, SkotiqColors colors);
  static String label(TransientType t);       // full, e.g. 'Gamma-Ray Burst'
  static String shortLabel(TransientType t);  // chip/filter, e.g. 'GRB'
}
```

All ten sites above delete their switch and call it. **A product decision is needed on the
severity palette before the merge** (which of `error`/`warning`/`accent` is correct per
type) — record the chosen mapping in the file's doc comment so the next screen cannot
re-diverge. Effort: medium.

## 2.2 The TNS-credentials-ready provider exists twice — MEDIUM value

- `screens/transients/transients_screen.dart:44` — `_tnsCredentialsReadyProvider`
  (`FutureProvider.autoDispose<bool>`)
- `screens/suggestions/widgets/transient_alerts_panel.dart:33` —
  `transientPanelTnsCredentialsReadyProvider` (`FutureProvider<bool>`)

Bodies are line-for-line identical except the panel version short-circuits
`if (ref.watch(isRemoteModeProvider)) return true;` first, and the two differ in
`autoDispose`. Net effect: the transients **screen** applies the remote-mode exemption and
the transients **panel** does not — on a paired remote client one surface offers TNS
submission and the other refuses it, for the same rig.

**Canonical survivor:** the panel's version (it handles remote mode), promoted to
`packages/skotiq_app/lib/utils/` or beside the science settings provider, keeping the
`autoDispose` from the screen version. Delete `transients_screen.dart:44-50` and point
`transients_screen.dart:402` at it. Effort: small.

## 2.3 `CoordinateFormatUtils` exists and is ignored by most of the package — MEDIUM value

`packages/skotiq_app/lib/utils/coordinate_format_utils.dart` is the declared canonical
RA/Dec/alt/az formatter ("Provides consistent formatting … across all planetarium and
sky-related UI components"). It is imported by exactly five files, all planetarium:
`mobile_widgets.dart:11`, `bottom_info_bar.dart:7`, `top_overlay.dart:8`,
`search_header.dart:9`, `view_controls.dart:11`.

Meanwhile these files inside my paths hand-roll their own, each with a different output shape:
- `screens/suggestions/widgets/transient_alerts_panel.dart:625,632` — `12h20m42s` / `+45°45'`
- `widgets/first_light/first_light_flow_dialog.dart:746,755` — `12h 20m` / `+45° 45′` (U+2032 prime)
- `widgets/annotation_overlay/object_info_tooltip.dart:228,234` — `12h 20m 42.0s` / `+45° 45' 30.0"`
- `widgets/catalog_overlay_widget/details_panel.dart:164`
- `services/finder_chart_service.dart:657`
- `screens/analytics/widgets/mpc_export_panel.dart:512,523`

**Canonical survivor:** `CoordinateFormatUtils`, extended with the two shapes it is
currently missing (`formatRaHmsFull` with fractional seconds, and a degrees-input RA
overload — several callers hold degrees, not hours, which is exactly the class of unit
bug this repo has hit before). Then convert the six sites.

**Two exclusions the implementer must respect:** `mpc_export_panel.dart` and
`finder_chart_service.dart` may be producing fixed-width strings for a *file format*
(MPC 80-column / chart annotation), not for display. Read those two before converting;
if they are format-bound, leave them and add a one-line comment saying so. Effort: medium.

## 2.4 `_formatHours` duplicated byte-for-byte between the two planetarium top overlays — LOW value

`screens/planetarium/widgets/top_overlay.dart:152` and
`screens/planetarium/widgets/mobile_widgets/top_overlay.dart:95` are identical
(`HH:MM` from a decimal-hours double), and both files already import
`CoordinateFormatUtils`. **Canonical survivor:** add `CoordinateFormatUtils.formatHoursHm`
and delete both. Effort: small.

## 2.5 Three parallel projections of the same seven science datasets — MEDIUM value

The same DAO row sets (`PhotometryMeasurementRow`, `ScienceFrameQualityMetricsRow`,
`TransparencySampleRow`, `PsfFieldTileRow`, residual vectors, calibrations,
`MovingObjectCandidateRow`) are turned into output three separate times:

1. CSV — `screens/analytics/widgets/science_export_hub.dart:1073-1448` (seven builders).
2. PDF — `services/observation_report_service.dart:457,503,568,611,682,726,762`
   (`_buildFrameQualityMetricsSection`, `_buildPhotometricCalibrationSection`,
   `_buildTransparencySection`, `_buildPhotometrySection`, `_buildPsfSection`,
   `_buildResidualsSection`, `_buildMovingObjectsSection`).
3. Markdown — `skotiq_core/.../science/science_report_exporter.dart:192,238,319,347,398`
   (`_photometrySnapshot`, `_lightCurveSnapshot`, `_transparencySnapshot`, `_fieldQuality`,
   `_movingObjectCandidates`).

The *formatting* legitimately differs (CSV / PDF widget / markdown). What is duplicated is
the **selection and summary logic**: which rows count, how they are grouped by filter, what
"latest" means, and the derived statistics. Today a change to one report's definition of a
statistic silently does not reach the other two.

**Canonical survivor:** extract the row-selection/summary step into a shared
`ScienceReportModel` in `skotiq_core` (a plain data object: per-filter breakdown,
photometry summary, transparency summary, field-quality summary, moving-object list). All
three renderers then format that one model. This is the largest item in this section and
crosses into `skotiq_core`, so it is listed again in §3 for the cross-cutting agent.
Effort: large.

## 2.6 Export-save-picker wrappers — LOW value

`chooseExportTarget` (`skotiq_core/lib/src/utils/export_target.dart:54`) is already the
canonical helper and is correctly used everywhere. What repeats is the four-line
`XTypeGroup(label: allowedExtensions.map((e) => e.toUpperCase()).join(' / '), extensions: …)`
construction — `screens/stack_result/stack_result_screen.dart:47`,
`screens/analytics/widgets/science_export_hub.dart:67`, plus ~6 sites outside my paths.
**Canonical survivor:** an optional `extensions:` convenience parameter on
`chooseExportTarget` itself. Effort: small. Low priority — the duplication is inert.

---

# 3. SUSPECTED CROSS-PACKAGE DUPLICATION (one line each, for the cross-cutting agent)

- RA/Dec formatting: `skotiq_app/lib/utils/coordinate_format_utils.dart` vs `skotiq_core/lib/src/utils/coordinate_parser.dart:178,189` (`formatRaHms`/`formatDecDms`) vs `skotiq_core/lib/src/providers/framing_provider/support.dart:428` vs `skotiq_core/lib/src/services/device_service/mount_controls.dart:61` vs `skotiq_core/lib/src/services/science/narrator/detectors/first_light_detectors.dart:216,226` — five canonical-looking implementations.
- Duration/hours formatting: `skotiq_core/.../sequence_stats_provider.dart:343` (`formatIntegrationSeconds`) and `conversational_builder_service.dart:619` (`formatHours`) are the two core candidates, against 20+ private `_formatDuration`/`_formatHours`/`_fmtDuration` in `skotiq_app` (incl. `screens/analytics/widgets/campaign_rollup_dialog.dart:95`, `screens/analytics/widgets/project_tracking_panel.dart:565`, `screens/planner/widgets/progress_tab_content.dart:445`, `screens/planner/widgets/projects_tab_content/terminal_states.dart:106`, `screens/planner/widgets/scheduler_tab_content/decision_panel.dart:270`).
- Science report content: `ScienceReportExporter` (core, markdown) vs `ObservationReportService` (app, PDF) vs `science_export_hub` (app, CSV) — see 2.5.
- `TransientType` presentation: the four app sites in 2.1 plus enum switches in `skotiq_core/lib/src/providers/transient_alert_provider.dart:1103` and `skotiq_core/lib/src/services/transient_alert_service.dart:202` — check whether core already owns a priority/label notion the UI should be reading.
- Thumbnail fetch + placeholder: `screens/analytics/widgets/frame_thumbnail_loader.dart` (`loadFrameThumbnail`, does existence-checking and returns a payload) vs `screens/session_review/widgets/sub_cull_rail.dart:867` (raw `imagingBackendProvider.getImageThumbnail`) vs `screens/mosaic/widgets/mosaic_panel_grid.dart:144` (`File.existsSync` + `Image.file`) — three thumbnail strategies for the same underlying artefact, none of them cached.
- `File.existsSync()`-in-`build` idiom: six copies of an identical `bool _exists(String?)` try/catch helper (see 4.3) — a shared `skotiq_ui` "file-backed image or placeholder" widget would delete all six.
- Command bars: `screens/planetarium/widgets/redesign/command_bar.dart` vs `screens/dashboard/widgets/command_bar.dart` (`DashboardCommandBar`/`CompactDashboardCommandBar`) — same name, different packages-of-concern; worth one look to see whether the chrome is shareable.

---

# 4. PERF RISKS

## 4.1 The whole science analytics tab rebuilds on every device-state tick — HIGH

`packages/skotiq_app/lib/screens/analytics/widgets/science_analytics_tab.dart:464-466`

```dart
final cameraState = ref.watch(cameraStateProvider);
final guiderState = ref.watch(guiderStateProvider);
final mountState  = ref.watch(mountStateProvider);
```

These three are hot device-state providers (they tick with mount position polling, cooler
temperature, and guider RMS — roughly 1 Hz while connected). They are watched at the top of
a `build` that spans lines 298-977 and contains ~35 `ref.watch` calls total, and they are
consumed for exactly one thing: `EquipmentHealthService().analyze(...)` at line 468, whose
result feeds a single health widget.

Consequence: while any device is connected, the entire 679-line tab — every chart, the PSF
heatmap grid, the residual painter, the light-curve card, the timeline — is torn down and
rebuilt about once a second, on the screen most likely to be open while a run is going.

Worse, `analyze` is fed `lastSuccessfulTimestampMs: DateTime.now().millisecondsSinceEpoch`
at lines 480 and 487, so its input differs on every rebuild by construction and no
memoization upstream can help.

**Fix shape:** move lines 464-497 into a small `ConsumerWidget` (`_EquipmentHealthSection`)
that watches the three device providers itself, and stop `DateTime.now()` from being part
of the analysis input (use the actual last-communication timestamp, or a coarse clock).
This is the same work order as the split in 1.5.

## 4.2 Full-resolution pixel stretch runs synchronously on the UI isolate inside `build` — HIGH

`packages/skotiq_app/lib/screens/stack_result/stack_result_screen.dart:613`

`_resolveDisplayRgba` is called from the build path (`_buildViewer`, line 453) and, when
the cache is cold, calls `_renderStretch` (line 658) inline. Two of its three branches are
pure Dart loops over the whole image:

- `_linearGray` (line 686): one pass over `mono` for min/max, then `mono.length` iterations
  writing 4 bytes each.
- `_linearColor` (line 709): one pass over `pixelCount` computing six extrema, then
  `pixelCount` iterations writing RGBA.

The third branch (`StackViewerStretch.autoStf`) calls
`ref.read(imagingBackendProvider).autoStretchImage(...)` at line 671 and assigns the result
directly to a `Uint8List?` — i.e. it is a *synchronous* FFI call over the same buffer.

For a stacked master (commonly 6000×4000 = 24 M pixels) that is tens of millions of
iterations plus a 96 MB allocation on the UI thread. The cache invalidation itself is
correct (`_renderedFrom = null` at line 577 when the stretch changes), so this fires
once per stretch toggle and once per new result — but each firing is a multi-hundred-
millisecond frame stall with no progress indication.

**Fix shape:** move `_linearGray`/`_linearColor` behind `Isolate.run` (or `compute`) and
render from a `FutureBuilder`/`AsyncValue`; make the `autoStretchImage` seam async. Confine
to `_stretch.dart` from split 1.13.

## 4.3 `File.existsSync()` called from `build()` in six widgets — MEDIUM

Every one of these performs a blocking `stat(2)` on the UI isolate during layout:

| File:line (helper) | Called from |
|---|---|
| `screens/session_review/widgets/master_overlay_view.dart:149` | `build` at 161, 162, 163 — **three** stats per build |
| `screens/session_review/widgets/master_preview_view.dart:62` | `build` at 74, 75 |
| `screens/session_review/workbench_view.dart:652` | `build` at 666 |
| `screens/session_review/widgets/master_library_panel.dart:253` | inside a preview-thumbnail builder |
| `screens/your_sky/widgets/atlas_region_cutout.dart:76` | directly inside `build` |
| `screens/mosaic/widgets/mosaic_panel_grid.dart:144` (helper at 320) | **per panel** in the grid — an N-panel mosaic does N stats per rebuild |

`master_overlay_view.dart` is the worst single case: it has four `setState` toggles
(lines 204, 211, 218, 228) and each one re-stats three files.

**Fix shape:** resolve existence once (in `initState` / `didUpdateWidget`, or by returning
it from the provider that already produced the path) and cache it in state; or use
`Image.file` with `errorBuilder` and drop the pre-check entirely — `errorBuilder` is
already wired at `atlas_region_cutout.dart:72,82`, which makes the `existsSync` there
redundant. Impact is medium, not high: these are toggle-driven rebuilds, not animation
frames.

## 4.4 The sub-cull rail re-fetches every thumbnail on every scroll-back — MEDIUM

`packages/skotiq_app/lib/screens/session_review/widgets/sub_cull_rail.dart:339` is a
`GridView.builder`; each cell mounts `_SubThumbnail`, whose state does the fetch in
`initState`:

```dart
// sub_cull_rail.dart:871-874
_future = ref.read(imagingBackendProvider).getImageThumbnail(widget.imageId);
```

There is no cache anywhere on this path:
- FFI backend (`skotiq_core/.../ffi_backend/session_heartbeat_operations.dart:53`) does
  a DAO read + a file existence check + a decode, every call.
- Network backend (`skotiq_core/.../network_backend/imaging_profile_operations.dart:533`)
  does a full HTTP GET of `images/$imageId/thumbnail`, every call.

Because `GridView.builder` recycles cells, scrolling a night's worth of subs down and back
re-issues one decode (or one HTTP round-trip) per tile, indefinitely. On a paired tablet
reviewing a 300-sub night this is the dominant cost of the screen.

**Fix shape:** route through a keyed provider (`thumbnailProvider(imageId)`, a
`FutureProvider.family` with a bounded cache) so Riverpod memoizes, or add an LRU in
`frame_thumbnail_loader.dart` and use it here too (see the §3 thumbnail entry). Confine to
`_thumbnail.dart` from split 1.10.

## 4.5 Whole-table image aggregation on three analytics surfaces — MEDIUM

`allDbImagesProvider` (`skotiq_core/lib/src/providers/database_provider.dart:148`) is a
`StreamProvider<List<CapturedImage>>` over the entire `captured_images` table. Three
consumers in my paths each run an O(N) pass over it:

- `screens/analytics/widgets/project_tracking_panel.dart:32-59` — full scan building a
  per-target/per-filter map.
- `screens/analytics/session_elapsed.dart:114` — full scan.
- `screens/analytics/analytics_screen/equipment_stats.dart:31` — full scan.

Riverpod memoizes each of these until the stream re-emits, so this is not per-frame. But
the stream re-emits on **every** row insert, i.e. once per captured frame during a run, and
the whole table is materialised in memory each time. For a multi-year library (tens of
thousands of rows) this is a repeated large allocation plus three full scans, on the UI
isolate, in the middle of an imaging run.

**Fix shape:** push the aggregations into Drift queries (a `GROUP BY target_id, filter`
returns tens of rows instead of tens of thousands). The provider itself lives in
`skotiq_core`, so this is a joint work order with the core mapper.

## 4.6 `EquipmentHealthService().analyze(sessions: allSessions, …)` runs in `build` — LOW/MEDIUM

`science_analytics_tab.dart:468` passes the complete session list to a synchronous analysis
on every build. Its cost is proportional to the user's session count, and per 4.1 it
currently runs ~1 Hz. Fixing 4.1 mostly removes this; if it stays hot after that, memoize
on the session list identity.

---

# 5. RELIABILITY RISKS

Calibration note: this subsystem is in noticeably good shape on the classic reliability
axes, and I am reporting that rather than padding. Specifically, I checked and found **no**
defect in:

- **Timer disposal** — all six `Timer.periodic` sites in my paths cancel in `dispose`:
  `sub_cull_rail.dart:172`/`161`, `planner/widgets/scheduler_tab_content.dart:65`/`94`,
  `widgets/operation_status_bar.dart:54,76`/`69`, `widgets/weather/radar_timeline_scrubber.dart:172`/`148`,
  `widgets/narrator/narrator_feed.dart:84`/`100`.
- **Stream subscription disposal** — `session_review_controller.dart:669-673` cancels
  `_progressSub`; its `onError` at 662-667 degrades rather than sinking the screen.
- **`catch (_)` sites** — the ones I sampled are deliberate and documented, not swallowed
  errors: `planner_screen_parts/_candidate_list.dart:517` ("Membership is an affordance,
  not a gate"), `analytics/widgets/photometric_calibration_wizard/star_matching.dart:572`
  ("Camera offline / driver exposes no capabilities").
- **Authority/generation guards after `await`** — present and correct in the places that
  need them (`science_export_hub.dart:203`, `_candidate_list.dart:500`,
  `star_matching.dart:564`).

The two items below are what I can actually evidence.

## 5.1 Every hub network action in the mosaic controller is unbounded — MEDIUM

`screens/mosaic/mosaic_project_controller.dart:319` declares
`static const Duration loadTimeout = Duration(seconds: 20)` and applies it correctly to the
local database read (`.timeout(loadTimeout)` at line 330, with an explicit
`on TimeoutException` handler at 366 producing an actionable message).

No equivalent bound exists on any of the *hub* actions, which are the ones that actually
cross a network: `publishToHub` (550), `_runClaim` (612), `releasePanel` (653),
`forceReleasePanel` (688), `uploadPanelMaster` (713), `uploadAllIntegrated` (730),
`assembleFromHub` (773), `discoverMosaics` (798), `joinAsParticipant` (818),
`refreshStatus` (847), `downloadOutput` (872). Each sets a busy flag
(`isPublishing`/`isClaiming`/…) before the `await` and clears it only in the
success/`catch` paths — so a hub that accepts the connection and never answers leaves the
screen's action buttons disabled with a spinner, with no way back except leaving the screen.

Caveat on scope: the underlying `ConstellationClient` (in `skotiq_core`) may impose its
own HTTP timeout — I did not verify that, and if it does, the exposure is bounded by
whatever that is rather than infinite. The finding stands as "the screen states no bound of
its own while it does state one for the cheaper, local operation".

**Fix shape:** a `hubTimeout` constant applied uniformly in `_runClaim`/`_runUpload` and the
standalone hub actions, with the same `on TimeoutException` → actionable-message treatment
already used at line 366.

## 5.2 `unawaited(load())` from the controller constructor — LOW

`screens/mosaic/mosaic_project_controller.dart:275` fires `load()` from the constructor
body. It is correctly commented ("errors land on state.error rather than throwing into the
constructor") and `load` is fully guarded, so this is not a live defect. It is listed only
because it is the one place in the file where a failure cannot be observed by the caller —
if `_readSnapshot` ever gains a synchronous throw before its first `await`, it would
surface as an unhandled zone error rather than on `state.error`. Worth a one-line
`// ignore:` rationale or a `.catchError` at the call site if anyone touches `_readSnapshot`.

---

# 6. DEAD CODE

Method: (a) enumerated every public type/top-level function/top-level variable declared in
my paths and counted whole-word occurrences across `packages/` + `apps/` — **zero** came
back with a single occurrence, so there are no orphaned public symbols; (b) enumerated
every non-generated file in my paths and counted files referencing its basename anywhere in
`packages/` + `apps/`. Four files came back with zero. All four verified individually below.

## 6.1 `screens/planetarium/widgets/selected_object_hud.dart` (114 lines) — CONFIRMED DEAD

Declares `SelectedObjectHud` (line 9). Grep for `SelectedObjectHud` across `packages` +
`apps` returns exactly three hits: the declaration (line 9), its constructor (line 13), and
a comment at `screens/planetarium/planetarium_screen/layouts.dart:532` that reads
"`SelectedObjectHud removed: the ObjectInfoPopup (shown on click)…`". The replacement
landed; the file did not get deleted. Delete the file.

## 6.2 `screens/planetarium/widgets/mosaic_planner_sky_view.dart` (67 lines) — CONFIRMED DEAD

Declares `MosaicPlannerSkyView` (line 8). Grep for the class name returns only
self-references inside the file plus one doc-comment mention at
`widgets/planetarium/adaptive_interactive_sky_view.dart:8` listing it as an example call
site. No import of the file exists anywhere. The mosaic wizard uses a different sky widget
today. Delete the file and drop the stale example from the doc comment at
`adaptive_interactive_sky_view.dart:8`.

## 6.3 `screens/planetarium/widgets/target_picker_sky_view.dart` (13 lines) — CONFIRMED DEAD

Declares `TargetPickerSkyView extends AdaptiveInteractiveSkyView` (line 4). Same evidence
shape: no importer, and the only external mention is the doc comment at
`widgets/planetarium/adaptive_interactive_sky_view.dart:7` naming it as an example
subclass. Delete the file and the doc mention.

## 6.4 `widgets/weather/weather_widgets.dart` (13 lines) — CONFIRMED DEAD

A barrel (`export 'dashboard_weather_widget.dart';` etc.). Grep for `weather_widgets`
across `packages` + `apps` returns **nothing** outside the file itself — every consumer
imports the concrete widget files directly. Delete the barrel; it does not re-export
anything that would lose its path.

## Non-findings deliberately excluded

- The three `*ForTest` helpers in `planner_screen_parts/_filter_controls.dart` (lines 206,
  228, 1002) look dead by naming convention but are live test entry points (1.11 above
  lists the three test files). Do not remove.
- `screens/planetarium/widgets/search_tab.dart` shows up in naive "unused class" scans
  because `SearchResultsTab` is reached through the `sidebar_tabs.dart` barrel; it is used
  at `planetarium_screen/layouts.dart:672`. Not dead.
- I did not attempt to prove headless-route handlers, FRB-exported functions, or
  registry-resolved symbols dead; nothing in my paths reached that class of claim anyway.
  `services/observation_report_service.dart` in particular is reached from
  `apps/desktop/lib/headless_api/handlers/science_handlers.dart:382` as well as from the
  UI — it is emphatically alive.

---

# 7. TOP PRIORITIES (ordered)

1. **4.1** — stop the science analytics tab rebuilding at ~1 Hz off `cameraState`/`guiderState`/`mountState` (`science_analytics_tab.dart:464-466`). Highest user-visible cost, smallest diff.
2. **2.1** — unify the four disagreeing `TransientType` icon/colour/label maps behind one `TransientTypeStyle`. The disagreement is user-visible and this codebase treats "the app stating something untrue" as a defect class.
3. **4.2** — move the full-resolution stretch off the UI isolate (`stack_result_screen.dart:613/658/686/709`).
4. **1.1** — split `session_review_controller.dart` (1940 lines, five workflows, no part split). The largest structural risk in the subsystem.
5. **4.4** — cache sub-rail thumbnails (`sub_cull_rail.dart:871`); worst on the remote/tablet path this release is meant to make good.
6. **1.3 + the generic `_ExportDataset` collapse** — split `science_export_hub.dart` and fold seven near-identical row builders into one descriptor-driven builder.
7. **6.1-6.4** — delete the four confirmed-dead files (194 lines) and the two stale doc mentions. Trivial and unblocks accurate future scans.
8. **5.1** — bound the eleven hub actions in `mosaic_project_controller.dart` with a `hubTimeout`, matching the treatment the local read already gets.
