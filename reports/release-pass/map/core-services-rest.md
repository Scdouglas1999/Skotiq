# Release-pass map — `core-services-rest`

Subsystem: `packages/skotiq_core/lib/src/services/` **excluding** the device/hardware-control
slice owned by `core-services-devices` (`device_service/`, `device_service*.dart`,
`device_*.dart`, `imaging_service*`, `plate_solve_service.dart`, `centering_service.dart`,
`flat_wizard_service.dart`, `predictive_af_service.dart`, `phd2_*`, `polar_alignment_service.dart`,
`safe_rig_service.dart`, `calibration_service.dart`).

Everything else in that tree is mine: `scheduler/`, `constellation/`, `coimaging/`, `mosaic/`,
`sky_atlas/`, `science/`, `smart_night*`, `sequence_*`, `calibration_library_service.dart`,
`post_session_*`, `stack_and_share_service.dart`, `backup_service.dart`, `profile_service.dart`,
`quick_start_service.dart`, `night_analysis_service.dart`, `imaging_records_repository.dart`, etc.

Method: one orienting `graphify query`, then targeted grep/read. All line counts verified with
`wc -l`. All "no callers" claims verified with repo-wide `rg` across `packages/` + `apps/`
(including tests and headless handlers) — evidence quoted per finding.

---

## 1. OVERSIZED FILES

19 hand-written Dart files over 1000 lines. **None is generated** — no `*.g.dart`,
`*.freezed.dart`, `frb_generated`, and `rg -l 'GENERATED CODE|do not modify by hand'` over all of
them returns nothing. Verified counts:

| lines | file |
|------:|------|
| 1584 | `services/calibration_library_service.dart` |
| 1358 | `services/constellation/constellation_service.dart` |
| 1268 | `services/scheduler/scheduler_engine.dart` |
| 1204 | `services/backup_service.dart` |
| 1195 | `services/sequence_time_estimator.dart` |
| 1193 | `services/post_session_integration_service.dart` |
| 1192 | `services/profile_service.dart` |
| 1174 | `services/science/science_processing_service.dart` |
| 1159 | `services/coimaging/coimaging_session_service.dart` |
| 1145 | `services/constellation/constellation_client.dart` |
| 1131 | `services/sequence_repository.dart` |
| 1121 | `services/stack_and_share_service.dart` |
| 1094 | `services/mosaic_project_service.dart` |
| 1089 | `services/imaging_records_repository.dart` |
| 1076 | `services/sky_atlas/sky_atlas_service.dart` |
| 1068 | `services/night_analysis_service.dart` |
| 1066 | `services/sequence_diff_service.dart` |
| 1060 | `services/science/default_science_backend.dart` |
| 1028 | `services/quick_start_service.dart` |

`smart_night_service.dart` is 999 lines — under the bar, and already split via
`part 'smart_night_service/sequence_emitter.dart'`. Not listed.

### Split-plan conventions used below

Two mechanisms exist in this tree already and both should be reused rather than invented:

* **`part` / `part of`** — used by `scheduler/scheduler_engine.dart`
  (`part 'scheduler_engine/contracts.dart'`, `part 'scheduler_engine/astronomy_helpers.dart'`),
  `smart_night_service.dart`, `smart_night_models.dart`, `sequence_repository.dart`.
  A `part` file can access private members, so moving private methods out is **purely mechanical
  and behaviour-preserving** — no visibility changes, no new public API, no import churn at call
  sites. This is the default tool for every plan below.
* **Sibling library + explicit import** — used where the moved code is genuinely standalone and
  should get its own tests (e.g. pure model classes, pure math).

Where a plan says "move X to `foo/bar.dart` as a part", it means: create
`services/<dir>/<file>.dart` starting with `part of '../<parent>.dart';`, add
`part '<dir>/<file>.dart';` to the parent after its imports, cut/paste the members verbatim.
No signature changes.

---

### 1.1 `calibration_library_service.dart` — 1584 lines · risk **medium**

**Why it is big.** One class does five unrelated jobs, and the file already carries its own
section banners marking them (`// Listing + enrichment` L112, `// Matching` L238,
`// Shared calibration libraries (WS1)` L371, `// Tagging` L762, `// Deletion` L811,
`// Loading` L883, `// Per-type matchers` L1047, `// Scoring helpers` L1375). The four per-type
matchers alone (`_matchDark` L1050, `_matchBias` L1179, `_matchFlat` L1224, `_matchDefectMap`
L1329) are ~330 lines of pure, testable ranking logic with no I/O.

**Split plan** (parent keeps class declaration, ctor, fields, `retire()`, `_ensureAuthority`,
`_remote`, and the public surface):

| new file | moves (line range in current file) | notes |
|---|---|---|
| `calibration_library/matchers.dart` (part) | `_matchDark` 1050–1178, `_matchBias` 1179–1223, `_matchFlat` 1224–1327, `_matchDefectMap` 1329–1374, `_applyTempScore` 1378–1410, `_applyStaleness` 1411–1440, `_applyRemoteProvenance`, `_cameraCompatible` 1441–1446, `_expDelta` 1448, `_tempDelta` 1453, `_clampScore` 1458, `_fmtSecs` 1460, `_fmtDate` 1465, `_typeLabel` 1468 | ~400 lines. Pure functions of `(records, LightFrameContext, tolerances)`. The single highest-value extraction: this is where every "wrong master got subtracted" bug will live and it currently has no file of its own to test. |
| `calibration_library/sharing.dart` (part) | `acceptRemoteMaster` 397–472, `publishMaster` 473–520, `retractPublishedMaster` 521–549, `_acceptRefusal` 550–566, `_exactLocalDuplicate` 567–609, `_insertAcceptedMaster` 610–688, `_remoteCandidatePasses` 689–765 | ~370 lines. The whole WS1 hub-consent/quality-gate block, already fenced by the `// Shared calibration libraries (WS1)` banner. |
| `calibration_library/loading.dart` (part) | `_loadAll` 886–981, `_enrich` 986–1046, `_provenanceFromTag` 1484, `_licenseFromTag` 1490, `_deleteFileIfExists` 1477 | ~190 lines. DB→record projection + FITS-header enrichment. |
| stays in parent | ctor/fields 41–110, `listMasters` 123–208, `getRecord` 211–268, `match` 269–368, `setTags` 766, `setNotes` 788, `deleteMaster` 817–885, and the two public result types `RemoteMasterAcceptanceKind` 1498 / `RemoteMasterAcceptance` 1512 | ~620 lines |

Result: 620 + 400 + 370 + 190. No public API moves; `RemoteMasterAcceptance*` stays where importers
already find it.

---

### 1.2 `constellation/constellation_service.dart` — 1358 lines · risk **medium**

**Why it is big.** Five hub workflows plus their models plus a retention sweeper in one class.
The file already has `// --- <section> ---` banners at exactly the seams: Account/sign-in L264,
Browse/join L322, Contribute L472, Pull/blend L819, Follow-the-night L1051, Internals L1175,
Retention L1243. `contributeTarget` (489–691) and `contributeRawSubs` (692–798) are two ~200-line
methods on their own.

**Split plan:**

| new file | moves | notes |
|---|---|---|
| `constellation/constellation_types.dart` (plain library, not a part) | `ConstellationPrivacy` 50, `ConstellationCredentials` 53, `ConstellationClientFactory` 65, `SharedTargetBrowser` 72, `RawSubframe` 81, `RawSubframeResolver` 103, `ContributionOutcome` 106 | ~90 lines. These are **public** and imported by `coimaging/`, `calibration/shared_calibration_library.dart`, providers and headless handlers, so give them a real library and re-export from `constellation_service.dart` (`export 'constellation_types.dart';`) to keep every existing import working unchanged. |
| `constellation/constellation_service/contribute.dart` (part) | `contributeTarget` 489–691, `contributeRawSubs` 692–798, `_representativeTileId` 799–826 | ~340 lines |
| `constellation/constellation_service/pull.dart` (part) | `pullTarget` 827–940, `swarmTiles` 941, `retract` 944–963, `deleteSubframe` 964–981, `myContributions` 982–1007, `retractTile` 1008–1050 | ~225 lines |
| `constellation/constellation_service/retention.dart` (part) | `sweepSwarmBlobs` 1265–1345, `_deleteSwarmBlob` 1346–end, `_swarmDir` 1238 | ~120 lines. See §3.3 — this code is currently unreachable in production; extracting it makes that obvious. |
| stays in parent | ctor/fields 140–246, `_client`/`_requireClient` 247–268, sign-in/register 269–324, browse/join/rehydrate/`_persistJoin` 325–488, follow-the-night 1063–1155, handoff 1156–1212, `_localTilesInCone`/`_localTileIdsInCone` 1213–1237, `_hubKey` 1180 | ~590 lines |

---

### 1.3 `scheduler/scheduler_engine.dart` — 1268 lines · risk **high**

**Why it is big.** This is the autopilot brain — lifecycle (timer/lock/streams), the evaluation
state machine, and the whole scoring model in one class. `_evaluateOnce` runs 292→575 (283 lines)
and `_scoreCandidate` runs 737→973 (236 lines). Risk is high not because the split is hard (the
`part` scaffolding already exists) but because this file is what decides what the rig images all
night; every edit needs `scheduler_engine_test.dart` +
`decide_scoring_contract_parity_test.dart` green.

**Split plan** (extend the existing `part` set; `part 'scheduler_engine/contracts.dart'` and
`part 'scheduler_engine/astronomy_helpers.dart'` already exist at L17–18):

| new file | moves | notes |
|---|---|---|
| `scheduler/scheduler_engine/scoring.dart` (part) | `scoreCandidate` 734–736, `_scoreCandidate` 737–973, `_altitudeFactor` 974–984, `_meridianFactor` 985–1049, `_hoursUntilSettingBelowMin` 1050–1087, `_filterCoverageFactor` 1101–1128, `_userPriorityFactor` 1129–1150 | ~420 lines. All pure: `(SchedulerCandidate, DateTime) -> TargetScore`. `_localSiderealTime` (1088) stays in the parent because `astronomy_helpers.dart` also calls it. |
| `scheduler/scheduler_engine/evaluation.dart` (part) | `_evaluateWithReason` 259–291, `_evaluateOnce` 292–575, `_handleNoEligibleTarget` 627–660, `_hasActiveScheduledWindow` 661–674, `_buildRejection` 675–707, `_summarizeRejection` 708–733, `_isEndOfNight` 613–626 | ~430 lines. The tick body + rejection reporting. |
| `scheduler/scheduler_engine/sequence_emission.dart` (part) | `buildSequenceForCandidate` 1151–end, `_nodeFilter` (static, ~1092) | ~120 lines. Emits the `Sequence` handed to the executor. |
| stays in parent | ctor + trigger subscription 28–60, fields 61–97, getters 98–103, `updateConfig`/`start`/`pause`/`resume`/`stop`/`evaluateNow`/`dispose`/`_restartTimer` 104–258, `previewDecision` 576–591, `previewRanking` 592–612, `_localSiderealTime` 1088 | ~380 lines |

---

### 1.4 `backup_service.dart` — 1204 lines · risk **high**

**Why it is big.** `createBackup` (204–349) and `restoreBackup` (350–635) are two large
transactional routines, and the "extended coverage" table registry (`_exportExtendedTables` 815+,
`_extendedTableImporters` ~889+) is a hand-maintained per-table map that grows with every schema
version. Risk is high because `restoreBackup` is a destructive two-phase operation
(`// PHASE 1 — Validate & stage` L370, `// PHASE 2 — Apply` L393) and any reordering during the
move can turn a validation failure into a half-wiped database.

**Split plan:**

| new file | moves | notes |
|---|---|---|
| `backup_service/backup_models.dart` (plain library) | `BackupResult` 20, `RestoreResult` 37, `BackupMetadata` 54–129, `resolveDefaultBackupDirectory` 130–141 | ~120 lines, all public; re-export from `backup_service.dart`. |
| `backup_service/table_registry.dart` (part) | `_exportSettings` 751, `_exportProfiles` 762, `_exportSequences` 774, `_exportTargets` 782, `_exportExtendedTables` 815–~870, `_dumpTable` 872–884, `_extendedTableImporters` map, `_importRows` ~1036, `_importWeatherSettings` 998–1035 | ~430 lines. This is the part that churns per schema bump — isolating it means a schema PR touches one small file. |
| `backup_service/restore.dart` (part) | `restoreBackup` 350–635, `_validateNamedRows` 636–664, `_clearAllData` 1114–1124, `_BackupValidationException` 1161, `_ValidatedBackup` 1173 | ~380 lines. **Move as one block, unchanged, phase comments included.** |
| stays in parent | class decl/ctor/fields 142–203, `createBackup` 204–349, `readBackupMetadata` 665, `listBackups` 681, `_recordLastBackupTime` 720, `autoSaveBackup` 734, directory helpers 1063–1113, free functions `_stringOrNull` 1125 / `_doubleOrDefault` 1136 / `_intOrDefault` 1144 / `_dateTimeValue` 1148 | ~330 lines |

---

### 1.5 `sequence_time_estimator.dart` — 1195 lines · risk **medium**

**Why it is big.** Two public models (`NodeTiming` 19–77, `TargetWindow` 78–189) share the file
with the estimator, and the estimator itself carries three independent concerns: node-duration
arithmetic, visibility-window solving, and conflict reporting.

**Split plan:**

| new file | moves | notes |
|---|---|---|
| `sequence_time_estimator/timing_models.dart` (plain library) | `_LocationContext` 6–18, `NodeTiming` 19–77, `TargetWindow` 78–189 | ~185 lines. `NodeTiming`/`TargetWindow` are public and consumed by the planner UI — re-export from the parent. |
| `sequence_time_estimator/node_durations.dart` (part) | `nodeDuration` 535–538, `_estimateNodeDuration` 539–720, `_estimateWaitTimeDuration` 721–764, `injectedAutofocusSecs` 1049–1094, `estimateTotalDuration` 1095–1150, `_walkEndTime` 1151–end | ~430 lines |
| `sequence_time_estimator/target_windows.dart` (part) | `calculateTargetWindows` 765–819, `_effectiveStartAfter` 906, `_effectiveEndBefore` 911, `_effectiveMinAltitude` 916, `_startTimeAfter` 928, `_endTimeAfter` 944, `_fromUnixSeconds` 979, `_maxDate` 982, `_minDate` 988, and the window solver at ~1000 | ~230 lines |
| stays in parent | ctor + timing constants 190–251, `estimateSequenceTiming` 252–303, `_processNode` 304–415, `_getLoopIterationNote` 416–456, `_formatTime` 457 / `_formatTimeRelativeTo` 465, `_calculateTwilightWaitTime` 480–534, `findTimingConflicts` 820–904, `analyzeSequence` 1005–1028 | ~350 lines |

---

### 1.6 `post_session_integration_service.dart` — 1193 lines · risk **medium**

**Why it is big.** Models + typedefs (28–164) precede the service, and the service body is a
pipeline whose optional stages (`_runOptionalFinishing` 586–709, `_runDrizzle` 710–841) are each
100–130 lines. The provider at the bottom (1115–1193) inlines two large closures
(colour-calibration and plate-solve→CD-matrix conversion).

**Split plan:**

| new file | moves | notes |
|---|---|---|
| `post_session/integration_models.dart` (plain library) | `ResolvedCalibration` 28–60, `MasterWcsSolution` 61–91, `MasterPlateSolver` 92–110, `MasterColorCalibrator` 111–119, `PostSessionIntegrationOutcome` 120–164 | ~135 lines, all public; re-export from parent. |
| `post_session/integration_stages.dart` (part) | `_analyzeAndStoreCurve` 437–510, `_solveAndStoreWcs` 511–554, `_overlayFromSolution` 555–585, `_runOptionalFinishing` 586–709, `_runDrizzle` 710–841, `_meanExposurePerSub` 842–849, `_softStep` 850–857, `_logSoftFailure` 858–868 | ~430 lines |
| `post_session/integration_provider.dart` (plain library) | `postSessionIntegrationServiceProvider` 1103–1193 including both closures | ~90 lines. Wiring, not logic; it is the only part of the file that imports `plateSolveServiceProvider` / `colorCalibrationServiceProvider`, so moving it also thins the parent's import list. |
| stays in parent | class 165–233, `integrate` 234–373, `previewIntegrate` 374–436, `_persist` 869–931, `_resolveCalibration` 932–1012, `_groupByFilter` 1014, `_filterBucket` 1023, `_chooseReferencePath` 1032, `_isBetterReference` 1047, `_masterName` 1065, `_statsJson` 1075, `_swapExtension` 1086, `_suffixBeforeExtension` 1095 | ~500 lines |

Do this split **after** §3.1 (deleting the dead legacy calibration branch), so `_resolveCalibration`
shrinks to ~50 lines first.

---

### 1.7 `profile_service.dart` — 1192 lines · risk **medium**

**Why it is big.** Every method re-implements the same local-vs-remote backend fork and re-asserts
`_requireAuthority(...)` after each await (44 `_requireAuthority` call sites). Sections are banner-
marked: Validation L272, Loading/auto-connect L332, Import/Export L491, Management L757.

**Split plan:**

| new file | moves | notes |
|---|---|---|
| `profile_service/profile_io.dart` (part) | `exportProfileToJson` 495, `exportProfileToFile` 511, `exportAllProfilesToJson` 518, `exportAllProfilesToFile` 547, `importProfileFromJson` 554, `importProfileFromFile` 568, `importAllProfilesFromJson` 575, `importAllProfilesFromFile` 605, `_createProfileFromExport` 612–756 | ~265 lines. Pairs naturally with the existing `profile_service/profile_export_data.dart` (667 lines) already in that directory. |
| `profile_service/profile_mutations.dart` (part) | `createProfile` 761, `duplicateProfile` 785, `deleteProfile` 801, `clearDevicesFromProfile` 819, `updateProfileDevices` 854, `updateProfileOptics` 893, `updateProfileCameraDefaults` 916, `saveConnectedDevicesToProfile` 946–1068, `updateProfileFilters` 1069, `syncFiltersFromHardware` 1091, `syncFiltersToProfile` 1153–1188 | ~430 lines |
| stays in parent | `_BackendAuthority` 27, `ProfileAutoConnectException` 38, `ProfileValidationResult` 54, class + `_requireAuthority` + the six `_get*Model`/`_persistProfileModel` accessors 82–279, `validateProfile` 280–331, `loadProfile` 336, `setDefaultProfile` 382, `_connectProfileDevicesFromModel` 401–464, `autoConnectOnStartup` 465–494, provider 1191 | ~490 lines |

---

### 1.8 `science/science_processing_service.dart` — 1174 lines · risk **medium**

**Why it is big.** `_processFrame` is a **665-line single method** (85–750) composed of eight
independently feature-gated lanes. Boundaries are unambiguous (each is an
`if (globalSettings.<x>Enabled && sessionConfig.<x>Enabled) { … } else { … }`):

* quality maps L129–161 · solve L162–190 · photometric calibration L191–261 ·
  transparency L262–369 · PSF map L370–502 · astrometric residuals L503–567 ·
  photometry L568–610 · moving objects L611–724 · writeback+grade L717–727

**Split plan.** Introduce a per-frame mutable `_FrameLanes` context object (private, in the new
part file) holding the values lanes hand to each other (`stars`, `wcs`, `calibration`,
`transparency`, `psfTiles`, `residuals`), then turn each lane into
`Future<void> _run<Name>Lane(_FrameLanes ctx)` **called in the same order** from `_processFrame`,
which drops to ~90 lines of orchestration + the existing try/catch/finally at 98/728/733.

| new file | moves |
|---|---|
| `science/science_processing_service/frame_lanes.dart` (part) | `_FrameLanes` (new), `_runQualityMapsLane`, `_runSolveLane`, `_runPhotometricCalibrationLane`, `_runTransparencyLane`, `_runPsfMapLane`, `_runResidualsLane`, `_runPhotometryLane`, `_runMovingObjectsLane` — cut verbatim from 129–724 |
| `science/science_processing_service/writeback.dart` (part) | `_runAutoGrade` 751–800, `_runFitsHeaderWriteback` 801–873, `buildScienceWritebackKeywords` 1056–1144 |
| stays in parent | `processCapturedFrame` 58–84, the slimmed `_processFrame`, `_candidateApparentMagnitude` 874–899, `magnitudeSigmaFromSnr` 900–946, `standardMagForFlux`/differential-photometry block 947–1055, `generateLineRatios` 1145–end |

A sibling `science_processing_service/private_helpers.dart` (702 lines) already exists in that
directory, so the `part` scaffolding is proven here.

---

### 1.9 `coimaging/coimaging_session_service.dart` — 1159 lines · risk **medium**

**Why it is big.** Models + typedefs 31–164, the service 165–1040, and a **second class**
(`CoImagingBatonScheduler`, 1057–1159) all in one file. Banners mark the seams: Create/join/leave
L246, Combined accounting L382, Framing-offset pointing L508, Capture-loop auto-contribute L650,
Longitude baton L765, Browse/live preview L857, Internals L917.

**Split plan:**

| new file | moves | notes |
|---|---|---|
| `coimaging/coimaging_baton_scheduler.dart` (plain library) | `CoImagingSiteResolver` 1042, `CoImagingBatonScheduler` 1057–1159, `CoImagingBatonReconciliation` 146–164 | ~140 lines. A separate class with its own timer lifecycle has no business sharing a file; it only needs the public `CoImagingSessionService` API. |
| `coimaging/coimaging_types.dart` (plain library) | `CoImagingFusionRequest` 31–70, `CoImagingFusionResult` 71–94, `CoImagingTileFuser` 95, `CoImagingContributionConsentResolver` 105, `CoImagingBatonDecision` 112–145 | ~120 lines, public; re-export from the service file. |
| `coimaging/coimaging_session_service/pointing.dart` (part) | framing-offset pointing block 508–649, `offsetDeltaDegrees` usage, `angularSeparationDegrees` 634–679, `observerAltitudeDegrees` 951–971, `_localSiderealTimeDegrees` 972–983, `_julianDate` 984–1006 | ~230 lines — and see §2.1: most of this should ultimately delegate to `AstronomyCalculations`. |
| `coimaging/coimaging_session_service/capture_loop.dart` (part) | `recordCompletedSub` 680–767, `tagTileSession` 492–507, `membershipsForPoint` 585–633 | ~180 lines |
| stays in parent | ctor/fields/`_requireClient`/`_hubKey` 165–245, create/join/leave/close 250–387, `recordContribution` 388–491, baton API 768–856, browse/preview 857–950, `_persistMembership` 1007–1040 | ~480 lines |

---

### 1.10 `constellation/constellation_client.dart` — 1145 lines · risk **low**

**Why it is big.** It is a flat REST client: one method per endpoint across five hub feature areas,
already banner-separated — Endpoints L275, Follow-the-night handoff L560, Attribution (WS4) L600,
Collaborative mosaics (WS2) L638, Live co-imaging sessions (WS3) L876. Nothing is tangled; it is
simply long. Low risk, low reward — do it only if the file is being touched anyway.

**Split plan** (all `part` files, transport stays in the parent so `_send`/`_sendFile`/`_download`/
`_throwForStatus`/`_decodeJson` remain the single choke point):

| new file | moves |
|---|---|
| `constellation/constellation_client/mosaics.dart` (part) | 638–875 (`publishMosaic`…`pullMosaicOutput`) — ~240 lines |
| `constellation/constellation_client/coimaging.dart` (part) | 876–end (WS3 session endpoints) — ~270 lines |
| `constellation/constellation_client/handoff_attribution.dart` (part) | 560–637 — ~80 lines |
| stays in parent | fields/ctor/`close` 31–63, `_v1` 64–95, `_send` ~76–111, `_sendFile` 116–160, `_download` 168–208, `_throwForStatus` 210–246, `_decodeJson` 247–265, `_requireBool` 266–278, core target/tile/subframe endpoints 279–559 |

---

### 1.11 `sequence_repository.dart` — 1131 lines · risk **medium**

**Why it is big.** Roughly **300 lines (786–1085) are hand-written enum↔wire-string switch pairs** —
`_binningToString`/`_stringToBinning`, `_autofocusMethodToString`/`_stringToAutofocusMethod`,
`_twilightToString`/`_stringToTwilight`, `_notificationLevelToString`/`_stringToNotificationLevel`,
`_loopConditionToString`/`_stringToLoopCondition`, `_conditionalTypeToString`/
`_stringToConditionalType`, `_recoveryActionToString`/`_stringToRecoveryAction`, plus
`_stringToFrameType`, `_stringToMeridianTriggerMethod`, `_stringToFlipFailureAction`,
`_stringToTriggerType`, `_parseExplicitTransports`, `_parseDitherPattern`. See §2.4 — a second
family of these exists in the executor with **different casing**, so do NOT unify the strings.

**Split plan:**

| new file | moves | notes |
|---|---|---|
| `sequence_repository/enum_codecs.dart` (part) | everything 786–1085 verbatim, plus `_categoryWireString` 349–358 and `_getNodeCategory` 342 | ~310 lines. Keep names and string literals **byte-identical** — these are on-disk DB values; changing one silently breaks every saved sequence. |
| `sequence_repository/versions.dart` (part) | `snapshotVersionOnSave` 624–644, `listVersions` 645–678, `restoreVersion` 679–711, `SequenceVersionSummary` 51–65, `loadPreviousRunSnapshot` 521–548, `loadRunDiffContext` 549–580, `_nonEmptyRunSnapshot` 581, `SequenceRunDiffContext` 34–50 | ~200 lines |
| stays in parent | class/ctor/factory 66–122, the three `_require*` guards 123–158, remote map adapters 159–177, save/create/update/`_saveNodes` 178–341, load paths 359–520, `setTags` 587, `toggleFavorite` 602, `deleteSequence` 712, `duplicateSequence` 724–785, free helpers 1086–end | ~620 lines |

A sibling `sequence_repository/node_decoder.dart` (755 lines) already exists — same directory, same
`part` convention.

---

### 1.12 `stack_and_share_service.dart` — 1121 lines · risk **high**

**Why it is big.** `run()` spans 243–677 (**435 lines**) — a single method that emits ~14 distinct
progress phases and calls `_ensureAuthority()` **20+ times** inside itself (L248, 280, 301, 307,
326, 335, 347, 370, 434, 471, 533, 557, 585…). Risk is high because that `_ensureAuthority` /
`emit` interleaving *is* the host-switch-safety contract; a careless extraction that loses one
check reintroduces "stale host writes into the new host's stack".

**Split plan** — do this one conservatively:

| new file | moves | notes |
|---|---|---|
| `stack_and_share/stack_frame_io.dart` (part) | `_loadCalibrated` 786–826, `_buildCalibrationContext` 828–866, `_loadRawU16` 901–945, `_discoverBayerPattern` 984–1018, `_CalibrationContext` 1075–1087, `_RawFrame` 1088–end | ~200 lines. Pure I/O + pixel loading, no progress emission, no `emit` closure capture — the safest cut. |
| `stack_and_share/stack_results.dart` (plain library) | `StackResultPreviewPersister` 28–43, `LiveStackBusyException` 44–52, `StackAndShareAllFramesRejectedException` 62–82, `StackedRawResult` 1035–1060, `StackedRgbaResult` 1061–1074 | ~110 lines, public. |
| `stack_and_share/stack_run_helpers.dart` (part) | `_rejectionReason` 199–215, `_dominantReason` 216–228, `_startStack` 678–707, `_addStackFrame` 708–737, `_integratedIntegrationSecs` 738–759, `_averageIntegratedHfr` 760–785, `_resolveStackingConfig` 946–983, `_singleFilter` 1019–1034 | ~200 lines |
| stays in parent | class/fields/`retire`/`_ensureAuthority` 139–242, **`run()` 243–677 untouched** | ~540 lines |

Explicitly do **not** carve `run()` itself in this pass. Land the three extractions above, confirm
`stack_and_share_service_test.dart` is green, and treat decomposing `run()` into phase methods as a
separate change with its own review.

---

### 1.13 `mosaic_project_service.dart` — 1094 lines · risk **medium**

**Why it is big.** Four public result models (39–146) plus three big workflows: create (216–344),
integrate panels (447–755), stitch (756–958).

**Split plan:**

| new file | moves | notes |
|---|---|---|
| `mosaic/mosaic_project_models.dart` (plain library) | `MosaicCaptureLauncher` 33, `MosaicCaptureRequest` 39–61, `MosaicPanelIntegrationOutcome` 62–100, `MosaicPanelStitchSkip` 101–146, `MosaicStitchOutcome` 1055–1083 | ~150 lines, public; re-export. |
| `mosaic/mosaic_project_service/integration.dart` (part) | `integratePanels` 447–485, `_assertNoSharedPanelTargets` 486–508, `_integratePanel` 509–646, `_ownedOnDiskPaths` 647–678, `_supersedePreviousMaster` 679–698, `_deleteMasterArtifactsOnDisk` 699–725, `_clearPanelMaster` 726–755 | ~310 lines |
| `mosaic/mosaic_project_service/stitching.dart` (part) | `stitchProject` 756–921, `_safeFitsHasWcs` 922–937, `_safeFitsExists` 938–959, `_representativeMasterId` 960–979, `_acceptedSubsForTarget` 980–987, `_wcsArgs` 988–1001, `_stitchStatsJson` 1002–1012 | ~260 lines |
| stays in parent | class/fields 147–215, `createProject` 216–310, `_createPanelTarget` 311–344, `startCapture` 345–388, `_resolveDistinctPanelTargets` 389–446, path helpers 1013–1054, provider 1084–end | ~350 lines |

---

### 1.14 `imaging_records_repository.dart` — 1089 lines · risk **medium**

**Why it is big.** Every accessor is written twice — once against Drift DAOs, once against
`NetworkBackend` — and the file additionally carries the remote polling machinery (619–689,
`_thumbnailListsEqual` 692–721, `_producingThumbnailFromApiJson` 723+) and a large tail of
provider/hook wiring (`_runFirstLightScan` ~836, `_driveCoImagingAutoContribute` ~869,
`_pushTransientDiscoveries` ~1007, `TransientCandidate` mapping ~1065).

**Split plan:**

| new file | moves | notes |
|---|---|---|
| `imaging_records/remote_polling.dart` (part) | `_pollRemoteSessionImages` 619–627, `_fetchRemoteSessionImages` 629–~655, `_fetchRemoteProducingNodeThumbnails` 657–670, `_pollRemoteDistinct` 672–689, `_pollRemoteProducingNodeThumbnails`, `_thumbnailListsEqual` 692–721, `_producingThumbnailFromApiJson` 723–~760 | ~180 lines |
| `imaging_records/solved_frame_hooks.dart` (plain library) | the post-solve fan-out tail: `_runFirstLightScan`, `_driveCoImagingAutoContribute`, `_pushTransientDiscoveries`, the `TransientCandidate` builder — roughly 800–end | ~290 lines. This is provider/orchestration code that happens to live behind `SolvedFrameFoldHook`; it does not belong in a repository. |
| `imaging_records/companion_json.dart` (part) | `_dateTimeFromJson` 554–563, `_companionToCreateJson` 564–~610 | ~60 lines |
| stays in parent | ctor/factories 45–92, sessions 93–259, captured images 260–553 | ~500 lines |

---

### 1.15 `sky_atlas/sky_atlas_service.dart` — 1076 lines · risk **low**

**Why it is big.** Fold pipeline + region CRUD + swarm-overlay merge + cache retention + three
public export models, one class.

**Split plan:**

| new file | moves |
|---|---|
| `sky_atlas/sky_atlas_models.dart` (plain library) | `RegionCutoutExport` 1010–1028, `AtlasDeltaExport` 1029–1053, `AtlasTargetRef` 1054–end — ~90 lines, public, re-export |
| `sky_atlas/sky_atlas_service/regions.dart` (part) | 570–661: `regions`, `getRegion`, `getRegionForPoint`, `tilesForRegion`, `exportRegionCutout`, `watchRegions`, `ensureRegion`, `regionTimeline`, `watchRegionTimeline` — ~95 lines |
| `sky_atlas/sky_atlas_service/swarm_overlay.dart` (part) | `mergeSwarmDelta` 687–781, `_overlayTileInfo` 782–792, `_overlayDir` 999, `_overlayRoot` 1003 — ~120 lines |
| `sky_atlas/sky_atlas_service/retention.dart` (part) | `sweepCache` 892–949, `deleteExportedDelta` 954–958, `_deleteCacheFile` 961–973, `_cacheDir` 1005 — ~90 lines (see §3.3) |
| stays in parent | ctor/roots 27–90, fold pipeline 91–297, `finalizeTilePng` 298, `cutout` 316–369, coverage/tiles-in-cone 370–569, `_persistFold` 793–891, `_integrationDeltaFor` 979, `_tilesDir` 991 — ~640 lines |

---

### 1.16 `night_analysis_service.dart` — 1068 lines · risk **low**

**Why it is big.** Six independent detectors (353–781, ~430 lines) sit next to their data loaders
and a private Meeus moon ephemeris. Already banner-separated: Detector registry L178,
Data loading L191, Detectors L344, Scoring L770, Numeric helpers L816.

**Split plan:**

| new file | moves |
|---|---|
| `night_analysis/detectors.dart` (part) | `_detectFocusDrift` 353–419, `_detectCloudTransparencyLoss` 420–517, `_detectGuidingCorrelation` 518–572, `_detectDewHfrCollapse` 573–647, `_detectMoonGradientOnset` 648–711, `_detectTiltCollimation` 712–781 — ~430 lines. The `_detectors` list at 181 stays in the parent, so registration order is still visible at the top. |
| `night_analysis/night_data.dart` (plain library) | `NightSub` 871–913, `NightData` 914–935 — ~65 lines, public |
| `night_analysis/moon_ephemeris.dart` (part) | `_MoonEphemeris` 936–1062 — ~125 lines. See §2.1: this is a fourth copy of the moon/alt-az math. |
| stays in parent | class/ctor 39–63, `computeReport`/`analyze` 64–143, `ungradableReason` 144, `_hasAnyMetric` 167, `_detectors` 181, loaders 194–341, scoring 782–870, provider 1063–end — ~430 lines |

---

### 1.17 `sequence_diff_service.dart` — 1066 lines · risk **low**

**Why it is big.** Two giant exhaustive switches over the node union: `_diffNodes` (120–888,
one `case` per node type, each 6–10 `_addIfChanged` calls) and `_describeNode` (889–990).

**Split plan:**

| new file | moves |
|---|---|
| `sequence_diff/node_field_diff.dart` (part) | `_diffNodes` 120–888 and `_addIfChanged` 991–1011 — ~790 lines |
| `sequence_diff/node_describe.dart` (part) | `_describeNode` 889–990 — ~100 lines |
| stays in parent | `SequenceDiffService` decl + `diff` 34–119, `SequenceDiffResult` 1012–1041, `NodeDiffEntry` 1042–1056, `FieldChange` 1057–end — ~180 lines |

`node_field_diff.dart` is still large, but it is one exhaustive `switch` whose arms the compiler
checks — splitting it further by node family would break exhaustiveness checking and is not worth
it. Low priority overall.

---

### 1.18 `science/default_science_backend.dart` — 1060 lines · risk **low**

**Why it is big.** One `implements ScienceBackend` class with twelve `@override` methods, several
of them 100–160 lines: `calibrateFramePhotometry` 149–309, `estimateTransparency` 311–439,
`buildPsfFieldMap` 441–522, `detectMovingObjects` 588–748, `computeLineRatios` 880–end.

**Split plan** (all `part`; the interface stays whole so `implements ScienceBackend` still
type-checks in one place):

| new file | moves |
|---|---|
| `science/default_science_backend/photometry.dart` (part) | `measureStars` 96–147, `calibrateFramePhotometry` 149–309 — ~215 lines |
| `science/default_science_backend/field_maps.dart` (part) | `estimateTransparency` 311–439, `buildPsfFieldMap` 441–522, `computeAstrometricResiduals` 524–586 — ~275 lines |
| `science/default_science_backend/moving_objects.dart` (part) | `detectMovingObjects` 588–748 — ~160 lines |
| `science/default_science_backend/line_ratios.dart` (part) | `computeLineRatios` 880–end, `_robustMedian` — ~180 lines |
| stays in parent | class decl 23–31, `getSolverCapabilities` 32–44, `solveForScience` 46–94, the two frame-quality overrides 749–878, `_mapBridgeQualityResult` — ~230 lines |

A sibling `science/default_science_backend/helpers.dart` (803 lines) already exists — same `part`
convention.

---

### 1.19 `quick_start_service.dart` — 1028 lines · risk **low**

**Why it is big.** **430 of the 1028 lines are two model classes** before the service even starts:
`EquipmentSnapshot` 29–227 and `QuickStartContext` 228–454. The service itself is 455–842 and the
provider tail is 843–end.

**Split plan** (the cleanest in the set — near-zero risk):

| new file | moves |
|---|---|
| `quick_start/quick_start_models.dart` (plain library) | `EquipmentSnapshot` 29–227, `QuickStartContext` 228–454 — ~430 lines, both public; re-export from `quick_start_service.dart` so no import changes at call sites |
| `quick_start/quick_start_providers.dart` (plain library) | `_safeCheckpointInfo` 843–867, `_remoteQuickStartContexts` 868–952, `quickStartServiceProvider` 953–989, `quickStartContextProvider` 990–1005, `quickStartAvailableProvider` 1006–1015, `quickStartContextsProvider` 1016–end — ~185 lines |
| stays in parent | `QuickStartService` 455–842 — ~390 lines |

---

## 2. DUPLICATION (inside my paths)

### 2.1 Astronomy math re-implemented in five places · effort **medium** · **highest-value merge**

`AstronomyCalculations` in `packages/skotiq_planetarium/lib/src/astronomy/astronomy_calculations.dart`
already exports `julianDate` (L72), `localSiderealTime` (L154), `equatorialToHorizontal` (L219),
`moonPosition` (L838), `angularSeparation` (L1615), and
`services/scheduler/sky_calculations.dart` wraps `julianDate` (L46) + `localSiderealTimeHours` (L81)
as the in-core namespace. Despite that, the following private copies exist **inside my paths**:

| copy | file:line |
|---|---|
| `_julianDate` | `night_analysis_service.dart:1039`, `scheduler_service.dart:140`, `coimaging/coimaging_session_service.dart:984`, `transients/transient_report_service.dart:426` (`_toJulianDate`), and inline inside `scheduler/scheduler_engine/astronomy_helpers.dart:_moonPosition` |
| `_localSiderealTime` | `night_analysis_service.dart:1019`, `coimaging/coimaging_session_service.dart:972` (`_localSiderealTimeDegrees`), `planning/forecast_planning_service.dart:397` (`_localSiderealTimeHours`) |
| angular separation | `coimaging/coimaging_session_service.dart:634` (`angularSeparationDegrees`), `sky_atlas/sky_atlas_service.dart:449` (`_coneSeparationDeg`), `scheduler/scheduler_engine/astronomy_helpers.dart:78` (`_angularSeparation`), `transients/first_light_service.dart:624` + `color_calibration_service.dart:346` (`_angularSeparationArcsec`), `catalog_target_resolver.dart:70` (`_angularSeparationArcmin`) |
| moon position (Meeus low-precision) | `scheduler/scheduler_engine/astronomy_helpers.dart:_moonPosition`, `night_analysis_service.dart:936` (`_MoonEphemeris`), `scheduler_service.dart` (`calculateMoonPosition`) |
| alt/az | `scheduler/scheduler_engine/astronomy_helpers.dart:_calculateAltAz`, `mosaic_service.dart:653` (`calculateAltitude`), `night_analysis_service.dart:1002` (`_MoonEphemeris._altitude`), `scheduler_service.dart` (`calculateAltAz`) |

The copies **advertise themselves**:
`astronomy_helpers.dart` — *"matching the established static scheduler (`scheduler_service.dart`) so
unit-tested moon-illumination behaviour stays in sync"*;
`night_analysis_service.dart:932` — *"`SchedulerService.calculateMoonPosition` + the scheduler's
alt/az conversion"*;
`planning/forecast_planning_service.dart:371` — *"same derivation as
[SchedulerService.calculateAltAz], reusing … is an instance method requiring a …"*.

That last comment names the actual root cause: `SchedulerService.calculateAltAz` is an **instance**
method on a Riverpod-scoped service, so pure callers copy it instead of calling it.

**Canonical survivor:** `SkyCalculations` (`services/scheduler/sky_calculations.dart`), promoted out
of `scheduler/` to `services/astronomy/sky_calculations.dart`, delegating to
`AstronomyCalculations` where the formula already matches. It must gain `moonPosition`,
`altAzFromEquatorial`, and `angularSeparationDegrees` as **statics**.

**Merge, one PR per copy, each guarded by a parity test** asserting old-vs-new agree to <1e-9 before
the old body is deleted (the codebase already has `decide_scoring_contract_parity_test.dart` as the
template for exactly this):

1. `night_analysis_service.dart` `_MoonEphemeris` → `SkyCalculations.moonPosition` + `.altAz`.
2. `coimaging_session_service.dart:634/972/984` → `SkyCalculations`.
3. `sky_atlas_service.dart:449` → `SkyCalculations.angularSeparationDegrees`.
4. `astronomy_helpers.dart` `_moonPosition`/`_angularSeparation`/`_calculateAltAz` → thin
   delegations (keep the extension methods as one-liners so the engine's call sites do not move).
5. `forecast_planning_service.dart:397` and `transient_report_service.dart:426` → `SkyCalculations`.
6. `mosaic_service.dart:653` → delete with §3.2 (it is dead).

The exposure here is real, not stylistic: `SkyCalculations.localSiderealTimeHours` (L81) carries a
comment recording that the meridian-flip monitor's copy had drifted (an extra millisecond term) and
had to be re-synchronised. That drift will recur in the other copies.

### 2.2 Two answers to "which master calibrates this light" · effort **small** · **self-documented**

`post_session_integration_service.dart:944-946` says it outright:

> *"Preferred path: the Calibration Library's transparent matcher (scored picks + operator-facing
> warnings). **The legacy DAO path below remains** for callers constructed without the library
> service."*

* Path A (canonical): `CalibrationLibraryService.match` — `calibration_library_service.dart:269`,
  scored, warning-emitting, remote-aware.
* Path B (legacy): `DarkLibraryService.findMatchingDark` (`dark_library_service.dart:80`) +
  `FlatLibraryService.findBestMatch` (`flat_library_service.dart:97`), both thin `_dao.findBestMatch`
  wrappers, invoked at `post_session_integration_service.dart:985-1002`.

**Canonical survivor:** `CalibrationLibraryService.match`. See §3.1 — path B is already unreachable
in production. `DarkLibraryService`/`FlatLibraryService` themselves stay (they own creation,
listing, deletion, and the dark-library headless routes at
`apps/desktop/lib/headless_api/handlers/calibration_handlers/dark_library_handlers.dart`); only
their *matching* wrappers and the legacy branch merge away.

### 2.3 `hubKey` copy-pasted three times · effort **small**

Byte-identical bodies, each with a comment pointing at the other two:

* `constellation/constellation_service.dart:1180` — `static String _hubKey(Uri)`
* `coimaging/coimaging_session_service.dart:241` — `static String _hubKey(Uri)`,
  *"matching [ConstellationService] so the co-imaging + tile receipts join"*
* `calibration/shared_calibration_library.dart:90` — `static String hubKey(Uri)`,
  *"(matches [ConstellationService])"*

```dart
final port = hubBaseUrl.hasPort ? ':${hubBaseUrl.port}' : '';
return '${hubBaseUrl.scheme}://${hubBaseUrl.host}$port';
```

This value is a **join key** across three tables (tile receipts, co-imaging memberships, folded
calibration records). Three implementations means one can drift and silently orphan rows in the
other two — exactly the failure the comments are trying to prevent by hand.

**Canonical survivor:** a top-level `String constellationHubKey(Uri hubBaseUrl)` in
`constellation/constellation_types.dart` (created in §1.2). All three call it; delete the copies.

### 2.4 Two enum↔wire codec families over the same 11 sequence enums · effort **medium**

* `services/sequence_repository.dart:786–1085` — lowerCamel vocabulary (`'one'`, `'count'`,
  `'untilTime'`), the **SQLite** wire.
* `providers/sequence/sequence_executor/serialization_operations.dart:925+` — PascalCase vocabulary
  (`'One'`, `'Count'`), the **Rust bridge** wire.

Verified different, e.g. `sequence_repository.dart:787-796` returns `'one'|'two'|'three'|'four'`
while `serialization_operations.dart:925-936` returns `'One'|'Two'|'Three'|'Four'`.

**These are two genuinely different contracts, so do NOT unify the strings** — that would corrupt
saved sequences or break the bridge. What duplicates is the ~300-line hand-written switch
*shape* over `BinningMode`, `FrameType`, `AutofocusMethod`, `TwilightType`, `NotificationLevel`,
`LoopConditionType`, `ConditionalType`, `RecoveryActionType`, `MeridianTriggerMethod`,
`FlipFailureAction`, `TriggerType`.

**Canonical survivor:** a new `models/sequence/sequence_enum_codecs.dart` exposing, per enum, an
explicit pair — `dbWire` (lowerCamel) and `bridgeWire` (PascalCase) — so both vocabularies are
declared side by side and a new enum value cannot be added to one and forgotten in the other. Both
current sites then delegate. Note: the executor side is outside my paths (`providers/`), so this
also appears in §2b.

### 2.5 `_logSoftFailure` / `_swapExtension` / `_suffixBeforeExtension` copied between the two
"integrate then persist" services · effort **small**

* `post_session_integration_service.dart` — `_swapExtension` L1086, `_suffixBeforeExtension` L1095,
  `_logSoftFailure` L858, `_softStep` L850
* `mosaic_project_service.dart` — `_suffixBeforeExtension` L1024, `_logSoftFailure` L1041

Same shapes, same purpose (derive a sibling artifact path; log a non-fatal pipeline step).
**Canonical survivor:** a shared `services/post_session/artifact_paths.dart` holding
`swapExtension` / `suffixBeforeExtension` as top-level functions, and a `SoftFailureLog` mixin (or a
top-level `logSoftFailure(Logger, String source, String step, Object e, StackTrace st)`) both
services use. Both files also need `_deleteFileIfExists` — which is a **fourth** copy of a helper
also present at `calibration_library_service.dart:1477` and `dark_library_service.dart:358`.

---

## 2b. SUSPECTED CROSS-PACKAGE DUPLICATION (one line each — for the cross-cutting agent)

1. `services/scheduler/sky_calculations.dart` + the six private copies in §2.1 vs
   `packages/skotiq_planetarium/.../astronomy/astronomy_calculations.dart`
   (`julianDate` L72, `localSiderealTime` L154, `equatorialToHorizontal` L219, `moonPosition` L838,
   `angularSeparation` L1615) — the planetarium already owns all of it.
2. `services/sequence_repository.dart:786–1085` vs
   `providers/sequence/sequence_executor/serialization_operations.dart:925+` — parallel enum codec
   families, different casings (§2.4).
3. `services/sequence_repository.dart` node decode vs
   `services/sequence_file_service/sequence_decoder.dart` (842 lines) vs
   `services/sequence_repository/node_decoder.dart` (755 lines) vs
   `services/import/canonical_node_mapper.dart` (662 lines) — four node-shaped decoders; likely one
   canonical mapper is owed.
4. `services/dark_library_service.dart:397 _parseFitsPixels` (a full FITS header/pixel parser) vs
   `services/calibration/fits_header_reader.dart` vs the Rust FITS reader behind the bridge —
   a hand-rolled FITS parser in Dart is a duplicate of native capability.
5. `services/mosaic_service.dart` panel geometry vs `mosaicPanelCenters` imported from
   `skotiq_planetarium` (already imported at `mosaic_service.dart:4`) — check whether
   `generatePanels` L261 duplicates what it imports.
6. `services/backup_service.dart` extended-table export/import registry vs the headless
   backup handlers in `apps/desktop/lib/headless_api/handlers/backup_handlers.dart` — verify the
   handler is not re-listing tables.
7. `services/calibration_library_service.dart` `_matchFlat`/`_matchDark` scoring vs the Drift DAO
   `findBestMatch` implementations in `lib/src/database/daos/dark_library_dao.dart` and
   `flat_library_dao.dart` (`_matchFlat` L1245 literally says *"Mirror FlatLibraryDao"*).
8. `services/coimaging/coimaging_session_service.dart` membership/receipt persistence vs
   `services/constellation/constellation_service.dart` `_persistJoin` — two hub-membership
   persistence layers over the same contributions table (join rows are keyed at negative `tileId`).

---

## 3. DEAD CODE

### 3.1 The legacy dark/flat calibration branch is unreachable in production
**Location:** `packages/skotiq_core/lib/src/services/post_session_integration_service.dart:985-1011`

**Evidence.** The branch is guarded by `if (library != null)` returning at L971-982
(`_resolveCalibration`). The only production construction site is the provider at
`post_session_integration_service.dart:1115-1192`, which **always** passes
`calibrationLibrary: ref.watch(calibrationLibraryServiceProvider)` (L1127). That provider is
declared `Provider<CalibrationLibraryService>` — **non-nullable** — in
`calibration_library_service.dart`. So `_calibrationLibrary` is never null in the running app and
lines 985-1011 are only reached from tests that construct the service without the argument
(`packages/skotiq_core/test/services/post_session_integration_service_test.dart`).

**Consequence beyond dead lines:** the legacy branch produces `ResolvedCalibration` with an **empty
`warnings` list** (no `warnings:` argument at L1004-1011), while the live branch propagates
`matchSet.allWarnings` (L981). Any test exercising the legacy branch is testing a calibration path
the user can never hit — and is silently exempt from the warning contract.

**Action:** delete 985-1011, drop the `darkLibrary`/`flatLibrary`/`darkTolerances` constructor
parameters if nothing else in the class uses them, make `calibrationLibrary` required, and retarget
the tests at the live path.

### 3.2 `MosaicService.checkVisibilityConstraints` + `calculateAltitude` have no callers at all
**Location:** `packages/skotiq_core/lib/src/services/mosaic_service.dart:683` and `:653`

**Evidence.** `rg -rn 'checkVisibilityConstraints' .` (excluding `build/` and `graphify-out/`)
returns **exactly one line** — the definition. No app code, no headless handler, no test.
`calculateAltitude` (L653) is called only from `checkVisibilityConstraints` (L699) and nowhere else
(`rg -rn '\.calculateAltitude\(' packages/ apps/` matches only `scheduler_service_test.dart`, which
is calling `SchedulerService.calculateAltitude`, a different class). Contrast the neighbouring
methods, which do have callers:
`calculateMosaicArea` and `estimateMosaicTime` are both used by
`apps/desktop/lib/headless_api/handlers/mosaic_handlers.dart`.

**Action:** delete `mosaic_service.dart:653–737` (~85 lines). This also removes one alt/az copy
from §2.1.

### 3.3 Two cache-retention sweepers are written, tested, documented — and never called
**Locations:**
* `packages/skotiq_core/lib/src/services/sky_atlas/sky_atlas_service.dart:892` — `sweepCache`
* `packages/skotiq_core/lib/src/services/constellation/constellation_service.dart:1265` —
  `sweepSwarmBlobs`

**Evidence.** `rg -rn '\bsweepCache\b' packages/ apps/` → the definition plus
`packages/skotiq_core/test/services/sky_atlas_service_test.dart` only.
`rg -rn 'sweepSwarmBlobs' .` → the definition plus
`packages/skotiq_core/test/services/constellation_swarm_scale_test.dart` only.
No provider, no startup path, no headless maintenance route, no timer
(`rg -rn 'sweep[A-Z]' packages/ apps/ --glob '!**/test/**'` outside these two files returns only
unrelated identifiers).

Both doc comments assert they *are* scheduled. `sky_atlas_service.dart:883-890`:
> *"Left unmanaged it grows without bound (a 2048² PNG+FITS pair per distinct region browse),
> silently filling a long-running host or a constrained appliance. … Cheap to call on startup / the
> maintenance schedule."*

**This is dead code that documents a live disk-exhaustion risk.** Classify as a wiring gap, not a
deletion: the correct fix is to call both from app/headless startup (and, for the appliance, on a
daily timer), not to delete them. Whichever way it is resolved, the doc comment must stop claiming a
schedule that does not exist.

---

## 4. PERF RISKS

### 4.1 Whole-database pretty-printed JSON built in memory on the calling isolate · impact **high**
**Location:** `packages/skotiq_core/lib/src/services/backup_service.dart:271`

```dart
final jsonString = const JsonEncoder.withIndent('  ').convert(backup);
```

`backup` (built at L230-253) contains every row of every table: the four core sets plus
`_exportExtendedTables()` (L815+), which `_dumpTable` (L872) fills with an unbounded
`SELECT * FROM <table>` per table — including `photometryMeasurements` and `guideRmsHistory`.
`PhotometryMeasurements` (`lib/src/database/tables/science.dart:51`) has a `capturedImageId`
foreign key, i.e. it is **per-star, per-frame** — hundreds of thousands of rows over a season.

Three multipliers stack: (a) every row is materialised as a Dart `Map` via `toJson()`;
(b) `JsonEncoder.withIndent` roughly doubles the output vs compact; (c) the entire result is held as
one `String` before `writeAsString` at L280.

This is not an occasional manual action: `autoSaveBackup()` (L734) is invoked from
`auto_save_service.dart` on the auto-backup timer (`auto_save_service.dart:207`,
`unawaited(_checkAndPerformBackup())`). On a Pi appliance mid-session this is a multi-second
isolate stall and a plausible OOM.

**Direction:** stream the archive (`JsonUtf8Encoder` into an `IOSink`, or per-table chunks), drop
`withIndent` for auto-saves, and page `_dumpTable` for the per-frame science tables.

### 4.2 Remote companions re-fetch and re-decode the entire session image list every 10 s · impact **medium**
**Location:** `packages/skotiq_core/lib/src/services/imaging_records_repository.dart:304-313`,
`:619-627`, `:629`; interval default `:58` / `:84` (`Duration(seconds: 10)`).

`watchImagesForSession` on the `NetworkBackend` path polls `getSessionImageRows(sessionId)` — the
**full** list — every 10 s and rebuilds every `db.CapturedImage` from JSON, then discards the result
if `listEquals` says nothing changed. On a 400-frame night that is 400 rows decoded every 10 s for
the whole session on a phone.

Worse, `getRecentImagesForSession` (L288-302) does the same on the remote path for what is
explicitly a `limit: 5` query — it fetches everything, sorts client-side (L294-295), then
`sublist(0, limit)` (L299).

**Direction:** add a server-side `since`/`limit` parameter to the images endpoint and poll the delta;
at minimum route `getRecentImagesForSession` to a limited endpoint.

### 4.3 `listMasters` enriches serially, one FITS header read per record · impact **medium**
**Location:** `packages/skotiq_core/lib/src/services/calibration_library_service.dart:195-198`

```dart
if (enrichFromHeaders && remote == null) {
  records = [for (final r in records) await _enrich(r)];
```

`_enrich` (L986) opens and parses the FITS primary header of the master file whenever the DB row is
missing camera id / temperature / filter. This is a **sequential** await per record with default
`enrichFromHeaders = true` (L125), so opening the Calibration Library settings page with 60 masters
does 60 serial disk reads before the list renders. The camera id is cached back into
`calibration_tags`, so steady state is better than cold start — but the cold path is the one the
user meets after a restore or a library import.

**Direction:** batch with `Future.wait` over a bounded pool, or enrich lazily per visible row.

### 4.4 `listMasters` allocates up to nine intermediate filtered lists · impact **low**
**Location:** `calibration_library_service.dart:141-203` — nine consecutive
`records = records.where(...).toList();` blocks (L142, 145, 148, 151, 154, 157, 167, 176, 186)
plus a tenth at L202. Trivially collapsible into one predicate. Low impact (list sizes are small);
listed only because it is in the same method as 4.3 and costs nothing to fix while there.

### 4.5 Directory sweeps call `statSync` inside an async `await for` · impact **low**
**Locations:** `sky_atlas/sky_atlas_service.dart:908` (inside `await for (final entity in dir.list(...))`),
`constellation/constellation_service.dart:1290` (same shape).

Each iteration performs a **blocking** `stat` on the calling isolate while otherwise streaming
asynchronously. Impact is low today precisely because §3.3 shows neither sweeper is ever called; it
becomes real the moment they are wired up, so fix it as part of that wiring (`await entity.stat()`).

---

## 5. RELIABILITY RISKS

### 5.1 `_download` has no timeout on the response body — an unbounded hang on the largest transfers
**Location:** `packages/skotiq_core/lib/src/services/constellation/constellation_client.dart:185`

```dart
final streamed = await _client.send(request).timeout(_timeout);   // L177 — bounded
...
await sink.addStream(streamed.stream);                            // L185 — UNBOUNDED
```

The two sibling helpers explicitly close this hole and say why —
`_send` L137-141 and `_sendFile` L137-141 both carry:
> *"Bound body collection too: `.timeout` on send() only covers receiving the response headers, so a
> hub that sends headers then stalls mid-body would hang here forever."*

`_download` is the one that omits it, and it is used for **the largest artifacts in the system** —
its own doc comment (L162-167) says *"panel masters and the stitched mosaic output … where buffering
`response.bodyBytes` could approach a gigabyte"*. Callers: `pullTile` (L468), `pullPanelMaster`
(L826), `pullMosaicOutput` (L867). A hub that stalls mid-body leaves an automated mosaic pull awaiting
forever with no error and no timeout.

Secondary: on any throw after L183 the partially-written file at `outPath` is left on disk with no
cleanup, so a retry may see a truncated artifact.

**Fix:** wrap the sink pump in an idle/total timeout and delete the partial file in a `catch`.

### 5.2 The calibration matcher and the calibration list disagree about a master's filter
**Locations:** `calibration_library_service.dart:283` (`match` → `_loadAll()`, **no enrichment**)
vs `:195-198` (`listMasters` → `_enrich`), and `_matchFlat:1240-1243`:

```dart
if (wantFilter != null && wantFilter.isNotEmpty) {
  pool = pool.where((r) => r.filter != null && r.filter!.trim() == wantFilter).toList();
}
```

`_enrich` (L992-993) exists precisely because flats can have a null `filter` column
(`needsFilter = record.type == flat && record.filter == null`). `listMasters` fills that in from the
FITS header; `match` does not. So a master flat whose filter lives only in its FITS header is
**visible and correctly labelled in the Calibration Library UI but invisible to the matcher** —
`match` returns `flat == null` and emits *"No matching master flat for filter X — flat-field
correction will be skipped"* (L348-352) while the screen right next to it shows that exact flat.
Silent loss of flat correction, plus a warning that contradicts the UI.

**Fix:** either enrich inside `match` (accepting 4.3's cost on that path) or backfill `filter` into
the DB row at registration so both paths read the same value.

### 5.3 Metric loaders swallow every exception with no log, permanently disabling detectors
**Location:** `night_analysis_service.dart:229-231`, `:290-292`, `:313-315`, `:338-340`

Four `catch (_) { return const {}; }` / `return null;` blocks with **no logging**.
`_loadEccentricity` (L273) is the sharpest case: it runs a **raw SQL string** against a column not
on the Drift table class —

```dart
'SELECT id, eccentricity FROM captured_images WHERE id IN ($placeholders)'
```

A schema rename would make this throw on every call, forever, and the only observable effect is that
the eccentricity-dependent findings stop appearing. The night report would still render, still say
"looks good", and nobody would learn the detector had been dark for months.

The fail-soft *behaviour* is right (the doc comments justify it well). What is missing is a
`_logger.debug`/`warning` on the swallow path so a persistent failure is discoverable — the same
pattern `rehydrateJoined` (`constellation_service.dart:430-435`) already applies correctly.

### 5.4 Two documented retention sweepers never run → unbounded disk growth
Same evidence as §3.3. Called out again here because the failure mode is a reliability one on the
appliance: `sky_atlas` cache (2048² PNG + FITS per region browse) and swarm `.nst`/`.fits` blobs both
accumulate with no upper bound on a host that runs for months. The code to stop it exists and is
tested; only the call site is missing.

### 5.5 `scheduler_service.dart` ships with analyzer suppressions for dead members
**Location:** `packages/skotiq_core/lib/src/services/scheduler_service.dart:1`

```dart
// ignore_for_file: unused_field, unused_local_variable
```

A file-wide suppression of exactly the two lints that find dead state. This file is live
(`schedulerServiceProvider` is read by `skotiq_app/lib/widgets/slew_dropdown_button.dart`,
`screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart`, and
`apps/desktop/lib/headless_api/handlers/run_watch_handlers.dart`), so the suppression is hiding real
findings in production code rather than in a scratch file. Removing the ignore and fixing what the
analyzer reports is a bounded, mechanical task that will likely surface more of §3.

---

## 6. RECOMMENDED ORDER

1. §3.1 delete the dead legacy calibration branch (small, unblocks §1.6).
2. §5.1 bound `_download`'s body read (small, closes an unbounded hang on automated pulls).
3. §5.2 make `match` and `listMasters` agree on a flat's filter.
4. §3.3 / §5.4 wire `sweepCache` + `sweepSwarmBlobs` into startup + a maintenance timer.
5. §4.1 stop building the whole DB as one indented JSON string on the calling isolate.
6. §2.1 collapse the astronomy copies onto `SkyCalculations`, one parity-tested PR at a time.
7. §1.19 + §1.1 the two cheapest/highest-value splits (`quick_start_service`, then
   `calibration_library_service`'s matchers).
8. §2.3 single `constellationHubKey`; §3.2 delete dead `MosaicService` visibility code.
