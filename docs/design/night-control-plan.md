# Skotiq Tonight night-control rework: build plan

Worktree: `~/.cache/ns-worktrees/skotiq` (rebrand/skotiq @ ce865087e). `graphify-out/graph.json` does not exist in this worktree, so every reference below was checked against source. No files were modified.

---

## 0. Findings that change the brief

1. **"Tonight" is the `/dashboard` route, not `/tonight`.** The rail item `navTonight` points to `/dashboard`, which renders `DashboardScreen` (`router/app_router.dart:78-86`, `screens/shell/shell_navigation.dart` first entry). `/tonight` is the separate "one-tap" beginner flow (`app_router.dart:501-509`), and the shell already treats it as part of `/dashboard`.
2. **Vertical space at the owner's window is 758 px for the body, not 852.** 1536x864 minus `ShellTopBand` (58 px, `skotiq_ui/.../shell_chrome_metrics.dart:22`) minus the new 48 px header leaves 758 px. With the rail expanded (220 px, the owner's setting per `reports/ui-tighten/u5-verify-report.md:9`) the content is 1316 px wide, so the center column gets 1316 − 272 − 300 = **744 px**.
3. **Pausing a run does not stop the current exposure.** Native pause lets the in-flight instruction finish (`native/.../sequencer/src/executor/lifecycle.rs:30-35`). An exposure burst checks the pause flag between frames (`node/context.rs:930`, `node/instructions/expose.rs:213`). So "pause, then act" waits up to one full sub (180 s on the board). The Dart side reports `paused` before the camera is idle (`sequence_executor.dart:1652-1682`).
4. **Snapshot and Loop only exist inside the Imaging screen's own state** (`imaging/imaging_screen/imaging_screen_actions.dart` `_takeSnapshot` / `_toggleLoop`). Nothing guards against manual device commands while a sequence runs, and nothing implements pause → act → resume.
5. **"Flip now" during a run is refused natively.** `api_perform_meridian_flip` errors whenever the executor is Running or Paused (`bridge/src/api/sequencer/lifecycle.rs:339-371`).
6. **The guide graph is in pixels, and the existing chart labels it as arcseconds.** `_guideAxisPixels` returns raw pixels and turns a missing field into 0 (`guiding_provider/stats_and_graph.dart:3-10`). The compact chart labels the same data "±4 arcsec" (`imaging/widgets/guiding_panel_parts/_guide_graph_and_stars.dart:141`). This bug already exists; the new chart must not copy it.

---

## 1. Inventory: where each element on the boards gets its data

Paths are relative to `packages/`. Key: **OK** = exists, **PARTIAL** = exists with limits, **MISSING** = needs new work.

### Header
| Element | Source | Status |
|---|---|---|
| Run-state pill (Running / Paused for autofocus / Ready) | `sequenceExecutionStateProvider` (core `sequence_provider`), `tonightHeroStateProvider` (`skotiq_app/.../dashboard/widgets/tonight/tonight_hero.dart:13`), plus the new manual-action state (P2) | OK, plus "paused for X" from P2 |
| Run duration "4 h 04 m" | `sessionStateProvider.startTime` (`core/providers/session_provider.dart:484`) | OK |
| Plan name | `currentSequenceProvider` | OK |
| "target 1 of 2 · step 7 of 12 · Ha 180 s · 44/60" | `sequenceProgressProvider` (`sequence/sequence_progress.dart:47`; fields at `sequence_state.dart:553-581`: currentTarget, currentFilter, nodeStatuses, nodeProgressStructuredDetail) plus target headers in the sequence tree | OK (derived) |
| Night timeline: sunset / dark / dawn / now | `tonightNightProvider` (`dashboard/widgets/tonight/tonight_night.dart` ~l.73) | OK |
| Planned target windows (M74 → 03:40, NGC 891 → 05:30) | `SequenceTimeEstimator.estimateSequenceTiming` (`core/services/sequence_time_estimator.dart:70`); `NodeTiming.targetHeaderId` and estimated start/end (`timing_models.dart:17-40`). Used the same way in `sequencer/widgets/sequence_timeline.dart:39-62` | PARTIAL: estimates, shown with "≈". A compact multi-window strip is MISSING; `NightBand` (`skotiq_ui/.../night_band.dart:36`) takes only one window |
| Pause / Resume / Skip step / Stop | `sequenceActionServiceProvider` (`skotiq_app/lib/services/sequence_action_service.dart:84,100,127,154`) | OK |
| Edit plan / Start now | Edit plan → `kSequencerRoutePath`; Start now → `sequenceActionService.start()` (l.70) | OK |
| Start at dark | No delayed or armed start exists anywhere | MISSING |

### Left column
| Element | Source | Status |
|---|---|---|
| Target name, RA, Dec, rotation | `runDashboardActiveTargetProvider` (`sequencer/widgets/run_dashboard/run_dashboard_providers.dart:21`) → `TargetHeaderNode` (raHours, decDegrees, rotation, catalogTargetId) | OK |
| Altitude, hour angle, airmass | `runDashboardSkyStatsProvider` (l.72) gives alt/az/transit/set. HA and airmass are computed from the site, and LST is computed there too | OK (derived) |
| "Psc · galaxy 9.9′" | Catalog lookup via `catalogTargetId` | PARTIAL (leave out if absent) |
| Altitude curve, 30° limit | `tonightArcProvider` (`tonight_night_band.dart:33`), `effectiveHorizonDegProvider` (`core/providers/settings_provider.dart:165`) | OK |
| Moon curve, illumination, moon set | `tonightNightProvider` gives illumination and moonset. A moon altitude curve is MISSING (planetarium `calc/moon.dart` has the math) | PARTIAL |
| Flip marker | `meridianCountdownProvider` (`core/providers/meridian_countdown_provider.dart:272`, timeToFlip) | OK |
| Plan per filter (count, time, %), ETA | `runDashboardFilterTotalsProvider` (l.279), `sequenceProgressProvider.estimatedRemainingSecs` | OK |
| Steps list with status | Sequence tree plus `SequenceProgress.nodeStatuses` | OK |
| Step "when", planned | `NodeTiming.estimatedStart` | OK (estimate) |
| Step "when", actual time a step finished | No per-node timestamps. Could be rebuilt from `eventHistoryProvider` (`core/providers/event_provider.dart:107`), but only for the current session in memory | PARTIAL |
| Coming up: flip, target switch, dawn | meridian countdown, estimator, `tonightNightProvider` | OK |
| Coming up: "Dither after #45", "Autofocus 6 frames or Δ1 °C" | Derived from dither and trigger node config in the sequence plus the current frame count | PARTIAL (derived text; omit a row if its config can't be read) |

### Center
| Element | Source | Status |
|---|---|---|
| Latest frame | `currentImageProvider` (`core/services/imaging_service.dart:580`); `ImageDisplayWidget` (`imaging/widgets/image_display.dart`). Autofocus frames are fed in by `autofocus_preview_feeder.dart` | OK |
| Overlay pill: "#43 · Ha 180 s · time · Accepted" | Frame data plus `runDashboardQualitySummaryProvider.recent` (`run_dashboard/quality_panel.dart:450`, `FrameGradeEvent`) or the DB `isAccepted` column | OK |
| "#44 exposing 72/180 s" | `exposureProgressProvider` (`imaging_service.dart:627`) | OK |
| View buttons: Stretch / Stars / Annotate / Zoom 1:1 | `imagingViewerStateProvider` (`core/providers/imaging_viewer_state_provider.dart:150`), auto-stretch, `starDetectionResultProvider` (`imaging_provider.dart:412`), `annotationServiceProvider`, overlay painters in `imaging/widgets/overlay_painters/` | OK (reuse) |
| Action bar: Snapshot, Loop | Imaging-screen-local code only | MISSING as a shared controller (P2) |
| Action bar: Autofocus | `DeviceService.runAutofocus` / `cancelAutofocus` (`core/services/device_service.dart:515,532`). Guiding is paused per setting (`device_service/autofocus_controls.dart:208-240`) | OK; orchestration is MISSING |
| Action bar: Solve & sync | `PlateSolveService.solve` / `solveWithFallback` (`plate_solve_service.dart:153,757`) + `MountCommandService.sync` (`skotiq_app/lib/services/mount_command_service.dart:297`) | MISSING as a combined action |
| Action bar: Center | `CenteringService.centerOnTarget` (`core/services/centering_service.dart:117`) | OK |
| Action bar: Dither | `phd2ControllerProvider.dither` (`guiding_provider/controller.dart:662`) | OK |
| Action bar: Flip now | Standalone flip path (`meridian_flip_provider.dart` ~776); refused during a run (finding 5) | PARTIAL |
| Thumbnail strip with per-frame HFR | `recentSessionFramesProvider` (`imaging_provider.dart:466`), works on host and remote; DB rows carry hfr, starCount and isAccepted (`core/database/tables/captured_images.dart:59-60`) | OK |
| HFR · stars session chart | DB rows for the session (`allDbImagesProvider`, `database_provider.dart:146`) persist; `FrameGradeRunSummary.hfrSparkline` only covers the run while the app is open | OK via DB |
| Autofocus markers on the HFR chart | Autofocus events from `eventHistoryProvider`, current session only | PARTIAL |
| Guiding RA/Dec chart | `guideGraphProvider` (`stats_and_graph.dart:377`) holds **400 samples in pixels**. RMS in arcsec comes from `guiderStateProvider` and `guideStatsProvider` (l.61) | PARTIAL: the axis must say "px" because PHD2's pixel scale isn't exposed |
| Dither markers on the guiding chart | Not tagged in the graph data. Could be matched by timestamp to sequencer dither events | PARTIAL |
| Temperature · focus chart | Per-frame `sensorTemp`, `focuserPosition` and `focuserTemp` in captured_images rows | OK, one point per frame |
| Ambient temperature series | `weatherStateProvider` has the current value only | MISSING (use focuser temperature, labelled honestly, or add a sampler) |

### Right panel: Overview tab
| Element | Source | Status |
|---|---|---|
| Last-frame HFR, FWHM, Ecc, Stars, Median, SNR, Bg σ | `currentImageProvider.stats` (`ImageStats`, `frame_analysis_models.dart:59`) | OK |
| Deltas vs night median | HFR and stars from DB rows. FWHM, Ecc and SNR only from in-memory `sessionImagesProvider` stats (host only) | PARTIAL (omit a delta when there's no data) |
| "Solve 0.8″ off" | captured_images `solvedRa` / `solvedDec` vs the target | OK, only when the frame was solved |
| Histogram | `CapturedImageData.histogram` | OK |
| Session: accepted, rejected, integration, autofocus runs, dithers | `liveSequenceStatsProvider` (`sequence_stats_provider.dart:454`) | OK |
| Session: remaining | `estimatedRemainingSecs` | OK |
| Session: disk | `captureDirDiskSpaceProvider` (`disk_space_provider.dart:39`) | OK |
| Session: dropouts | `usbDisconnectLogProvider` | OK |
| Equipment: camera, filter, focuser, mount, guider, rotator | `cameraStateProvider`, `filterWheelStateProvider`, `focuserStateProvider`, `mountStateProvider`, `guiderStateProvider`, `rotatorStateProvider` | OK |
| Equipment: guider star size / mass | `guideStatsProvider` gives mass | PARTIAL (star HFD MISSING) |
| Equipment: power (V / A / dew) | No power telemetry anywhere | MISSING (leave the row out) |
| Conditions: clouds, humidity, dew point, wind, SQM, ambient | `weatherStateProvider` (`WeatherState`, only with an ObservingConditions device); `cloudCoverPercentageProvider` is an Open-Meteo **forecast** (`weather_providers.dart:262`) | PARTIAL |
| Conditions: seeing | Not available | MISSING |
| Conditions: Safe pill | `weatherSafetyProvider` (`weather_safety_provider.dart:669`) | OK |
| Log | `runDashboardRecentEventsProvider(limit)` (l.931) | OK |
| "Before you start" checklist | `readinessReportProvider` (`core/providers/readiness_provider.dart:27`), the device states above, `sequenceDiskProjectionProvider` (`disk_space_provider.dart:89`), safety config, and the setup steps from `tonight_checklist_panel.dart` | OK (compose) |

### Right panel: Camera tab
| Element | Source | Status |
|---|---|---|
| Cooler readouts, setpoint, warm-up, off | `cameraStateProvider` (temperature, coolerPower, targetTemp); `camera_warmup_controller.dart`; `CameraPanel` cooler controls | OK |
| Cooler history graph "since 19:20" | `temperatureHistoryProvider` (`imaging_provider.dart:589`) keeps only **120 points (10 min)** | PARTIAL: label it "last 10 min" or extend the buffer in core |
| Capture: exposure, gain, offset, frame type, binning, ROI | `exposureSettingsProvider` + `manualExposureSettingsUpdaterProvider` (`imaging_provider.dart:15,75`) | OK for manual capture |
| "While the run is going these values belong to step 7 · edits apply from #44" | Live edits to a running sequence are not possible: `canEditSequenceProvider` returns false while running or paused (`sequence/sequence_editor.dart:43-56`) | MISSING. During a run, show the step's values read-only with "Edit in Sequencer" |
| Filter slots, focus offset | `filterWheelStateProvider`, `DeviceService.setFilterWheelPosition`, `filterOffsetProvider` (`filter_offset_provider.dart:345`) | OK (disable filter changes during a run) |
| Readout: sensor specs | `activeCameraSensorSpecsProvider` | PARTIAL |
| Readout: saves to | settings `imageOutputPath` + naming pattern | OK |
| Readout: disk and "~11 nights" | `sequenceDiskProjectionProvider` | OK |
| Readout: USB bandwidth | Not exposed | MISSING (leave out) |

### Right panel: Focus tab
| Element | Source | Status |
|---|---|---|
| Live V-curve, point n/N | `autofocusOverlayProvider` (`autofocus_progress_provider.dart:321`; `VCurvePoint` has position and hfr) and `VCurveChart` (skotiq_ui) | OK |
| Stars per point | Only the current point's `starCount` | PARTIAL (MISSING per point) |
| Fit R² | `AutofocusResult.curveFitQuality`, available only after the run finishes | PARTIAL |
| Focuser position / max, ±steps, go to, halt | `focuserStateProvider`, `moveFocuserRelative`, `moveFocuserTo`, `haltFocuser` (`device_service.dart:501-505`) | OK |
| Cancel autofocus / Settings… | `cancelAutofocus`; Settings is a route | OK |
| Temperature compensation coefficient, "AF at", "moved since" | `focus_models` table `temperatureCompensationSlope`, `focusModelProfileDataProvider`; the TC on/off state comes from the predictive autofocus service | PARTIAL |
| Recent runs | No persisted autofocus history; autofocus events are only in memory for the session | MISSING (show this session only) |

### Right panel: Mount tab
| Element | Source | Status |
|---|---|---|
| Position: RA/Dec, pier, alt/az, slewing, tracking | `mountStateProvider` | OK |
| HA, LST | Computed from the site | OK |
| Flip in | meridian countdown | OK |
| Sidereal / Lunar / Solar / Stop | `MountCommandService.setTrackingRate` / `setTracking` (l.241-297); `canSetTrackingRate` | OK |
| Move pad N/S/E/W with rates | `backend.mountMoveAxis` with a watchdog, in `dashboard/widgets/mount_control_card.dart:609-650` and `mount_jog.dart` | OK (move it out) |
| "Swap E/W after flip" | No such setting | MISSING |
| Go to: name, RA/Dec, Slew, Slew & center, Sync here | `catalog_target_resolver`; `MountCommandService.slewTo` / `sync`; `CenteringService` | OK |
| Home, Unpark, Park | `findHome` / `unpark` / `park` (l.366, 159, 139) | OK |
| Set park | No `mount_set_park` in `bridge/src/api/devices/mount.rs` | MISSING (native) |
| Flip now | See finding 5 | PARTIAL |
| Limits… | Settings route | OK |
| Flip settings line | `effectiveMeridianFlipSettingsProvider` (`meridian_flip_provider.dart:332`) | OK |

### Right panel: Guide tab
| Element | Source | Status |
|---|---|---|
| PHD2 state, SNR, mass, RMS | `phd2StateProvider`, `guideStatsProvider`, `guiderStateProvider` | OK |
| Star HFD | Not available | MISSING |
| Loop / Stop / Dither now / Find star / Flip calibration / Clear calibration | `Phd2Controller` (`controller.dart:607-701`); `GuidingBackend.phd2FindStar` / `phd2FlipCalibration` / `phd2ClearCalibration` (`backend/roles/guiding_backend.dart:98-123`); `calibrationStateProvider` | OK |
| Guide star image | `starImageProvider` + `GuideStarView` (skotiq_ui) | OK |
| Scatter plot | `guideGraphProvider` (pixels) | OK (label px) |
| Calibration angle and rates | `phd2GetCalibrationData` | OK |
| Dither & settle values | `ditherSettingsProvider` (`imaging_provider.dart:367`), appSettings dither scale and RA-only | OK |
| "Lost: 1 (4 s)" | `starLostEventProvider` keeps only the last timestamp | PARTIAL (count from events) |

### Right panel: Solve tab
| Element | Source | Status |
|---|---|---|
| Last solve: RA, Dec, rotation, scale | `plateSolveStateProvider.lastResult` (`plate_solve_service.dart:937`) | OK |
| Field of view, off target | Computed | OK |
| Solve duration | Not stored | MISSING (time it in P2) |
| Solve / Solve & sync / Center buttons | P2 | MISSING (P2) |
| Reslew after sync, center tolerance, attempts | `CenteringConfig` (`centering_service/centering_models.dart:126`) | OK |
| Solver name and settings | `plateSolverSettingsNotifierProvider` | OK |
| Rotation advice | Solved rotation vs `TargetHeaderNode.rotation`; `rotatorStateProvider` | OK (derived) |
| Recent solves | `lastCenteringResultProvider` (`centering_service.dart:221`) plus solved DB rows | PARTIAL |

---

## 2. Architecture

**Where it lives.** A new directory, `packages/skotiq_app/lib/screens/night_control/`. The `/dashboard` route, its name and the `navTonight` label stay as they are; only the page builder switches to `NightControlScreen`. `/tonight` stays as the one-tap flow and is linked from the empty state ("Pick a target for tonight"). Keeping the path avoids touching deep links, the mobile notification routes (`apps/mobile/lib/services/notification_service.dart:177-191`), tests, the tutorial route and the `_routeAliases` table.

**What happens to the old dashboard.** It gets deleted in P8, after everything else lands:
- Files: `dashboard_screen.dart`, `dashboard_layout*.dart`, `widgets/dashboard_widget_registry.dart`, `widget_picker_dialog.dart`, `dashboard_tile.dart`, `zone_layout.dart`, the `cockpit_*` widgets, the tonight and standby cards, `tonight_card.dart`, `quick_actions_card.dart`, `capture_settings_card.dart`, `mount_control_card.dart` and the related tests.
- Kept, moved into `night_control/data/` by P8: `tonight_night.dart` and `tonightArcProvider`.
- Kept, moved by P7: `mount_jog.dart`.
- `dashboardStandbyProvider` (`dashboard_layout_provider.dart:229`) is replaced by the run-phase provider from P1.
- The persisted layout setting simply stops being read. No migration is needed, but grep for its key before deleting.
- Also update: the `skotiq_app.dart:19` export, `tutorial/first_night_wizard_route.dart:5,58`, and `test/golden/public_screenshots_test.dart:14,912` (desktop-dashboard.png).

**Layout.** `NightControlLayout` takes four slots: header, left, center, panel.
- **Width ≥ 1180 px:** three columns, left 272 | center flexible | right 300. The owner's window is 1316 (rail expanded) or 1480 (rail collapsed).
- **Center column under 900 px:** the "Manual actions pause the run…" hint becomes an info icon with a tooltip, and the button sub-labels hide below 820 px.
- **Body height under 720 px:** the chart row shrinks from 120 to 96 px. The frame never drops below 280 px; the chart row collapses into a toggle before that happens.
- **Left column:** scrolls on its own. Header stays fixed.
- **Width 900–1180 px:** the left column becomes a drawer opened by a "Plan" button in the header; the right panel stays.
- **Width under 900 px (including the bottom-nav shell under 768):** one scrolling column in this order: compact header (pill, controls, timeline on a second row), frame (fit by aspect, 240–360 px), horizontally scrolling action bar, strip, charts as a horizontal pager, then a tab chooser (`SegmentedControl`) with its body, then the left-column sections. Phones keep a working Tonight.
- **Shell changes (P8):** `RunningSequenceMiniBar` hides on `/dashboard` as well (`widgets/running_sequence_mini_bar.dart:48`) because the header already has the run controls. `AutofocusProgressOverlay` (`app_shell.dart:586`) is suppressed on `/dashboard` because the Focus tab and the frame overlay replace it.

**Right-panel tabs.** `nightPanelTabProvider = StateProvider<NightPanelTab>` (in memory, so it survives navigation, like `selectedImagingPanelProvider` at `imaging_provider.dart:378`).
- Bodies live in an `IndexedStack`, as `ImagingSectionBody` does, so a half-typed field survives a tab switch.
- Pressing an action-bar button selects its tab: Autofocus → Focus, Solve & sync / Center → Solve, Dither → Guide, Flip → Mount, Snapshot / Loop → Camera.
- **Automatic events never switch tabs.** Instead the tab shows a status dot (autofocus running, guider alert).

**Reuse policy.** Reuse services, providers and leaf widgets: `VCurveChart`, `GuideStarView`, `CalibrationPanel`, `FilterWheelSelector`, the jog pad, `ImageDisplayWidget`, overlay painters, `Readout` / `ReadoutRow`, `SidePanel`, `HoldToConfirmButton`, `Checklist`. **Do not** embed the whole Imaging panels (`CapturePanel` 712 lines, `FocusPanel` 765, `MountTab` 841, `GuidingPanel` 432). They bring their own headers, scroll views, density and screen-local action logic, which would fight a 300 px dense layout. Their action logic moves into the P2 controller. Migrating Imaging onto that controller is a follow-up, not part of this plan.

**Copy and theme.** All strings go into both the `en` and `es` maps in `skotiq_app/lib/localization/skotiq_localizations/translations.dart`; `test/localization/translation_completeness_test.dart` enforces this. Colors come only from `SkotiqColors` and `SkotiqChartColors`. The board's #0A0910 background maps to `colors.background` (#0B0D12) and its #121119 panels to `surface`. The red-night and light themes must work. Do not add new hex literals (the design-token audit flags them).

**Accessibility.**
- `Semantics(header: true)` on the screen title and each section title.
- The run pill is a `liveRegion`. The exposure countdown is **not** a live region; announce only state changes.
- Every chart gets a `Semantics(label:)` sentence generated from data, matching the board's aria-labels.
- Panel tabs expose `selected` and a button role; arrow keys move between them.
- Disabled actions carry their reason in the tooltip and the semantics hint.
- Stop is `HoldToConfirmButton`.
- Jog buttons are labelled North / South / East / West / Stop all motion. Keyboard activation sends one pulse, never an unreleased MoveAxis.
- Focus order: header → left → center action bar → panel.
- Lay out cleanly at 1.3× text scale.

---

## 3. Work packages

Waves: **P0** first → **P1a, P1b, P2, P3** in parallel → **P4, P5, P6, P7** in parallel → **P8**. Every package owns its files exclusively. All new app code goes under `packages/skotiq_app/lib/screens/night_control/` (abbreviated `nc/`) and tests under `packages/skotiq_app/test/screens/night_control/` (abbreviated `t/`).

### P0: contracts and scaffold (one agent, short)
**Creates:**
- `nc/night_control_contracts.dart`, containing:
  - `enum NightPanelTab { overview, camera, focus, mount, guide, solve }`
  - `enum NightRunPhase { notSetUp, ready, armed, running, pausedByUser, pausedForAction, stopping, finished }`
  - Immutable view models: `NightHeaderVm`, `NightTimelineVm` (+ `TimelineWindowVm` {name, start, end, estimated, state}), `NightTargetVm`, `PlanFilterRowVm`, `PlanStepVm` (+ `StepWhen` = actual | planned | progress), `UpcomingItemVm`, `StripFrameVm`, `SeriesPoint` {DateTime t, double? y, bool accepted}, `SeriesMarker` {t, kind: autofocus | dither | flip | reject}, `NightSeriesVm`, `MetricVm` {label, value?, delta?, deltaTone}, `EquipmentRowVm`, `ChecklistItemVm` {state, title, detail, actionLabel?, route?}, `ManualActionVm` {id, label, sub?, enabled, disabledReason?, running}
  - `enum ManualActionId { snapshot, loop, autofocus, solveSync, center, dither, flip }`
  - The abstract `NightActionApi` interface that P2 implements
  - `nightPanelTabProvider`
- `nc/night_control_layout.dart`: the responsive four-slot scaffold described above.
- `t/fixtures/night_fixtures.dart`: VM builders for tests only.
- `t/night_control_layout_test.dart`.
- The API signatures of the P3 kit widgets, in a doc comment in the contracts file.

**Rule for value models:** any field the UI can't honestly know is nullable. Never default to 0. This also matters for the behavioral audit, which flags literal null-coalesce defaults.

**Acceptance:** the layout renders the correct column set at 1480x806, 1316x806, 1000x806, 700x800 and 390x844 with no `takeException()`. Analyze is clean.

### P1a: night, plan and step data (`nc/data/plan/`)
**Files:** `night_timeline_provider.dart` (the estimator anchored at now, or at session start while running; target windows; "now" marker), `night_target_provider.dart` (target, HA, airmass, LST, altitude curve via `tonightArcProvider`, moon curve computed with the planetarium moon calc, flip time), `plan_progress_provider.dart` (wraps `runDashboardFilterTotalsProvider`), `plan_steps_provider.dart` (flattens the tree, statuses, planned times, actual times from session events when present), `upcoming_provider.dart`, `night_run_phase_provider.dart` (replaces `dashboardStandbyProvider` and `tonightHeroStateProvider` logic).
**Tests:** `t/data/plan/*_test.dart` using `ProviderContainer` with overrides. Cover: no site → timeline null; no sequence → empty steps; two targets → two windows; running → "progress" step; past-midnight night.
**Depends on:** P0.

### P1b: frame, session and environment data (`nc/data/session/`)
**Files:** `session_frames_provider.dart` (DB rows for the active session; remote-aware like `recentSessionFramesProvider`), `session_series_provider.dart` (HFR / stars / sensor temp / focuser position / focuser temp series, autofocus / dither / reject markers from `eventHistoryProvider`), `last_frame_metrics_provider.dart` (stats plus deltas against the medians; null delta when unavailable), `session_stats_provider.dart`, `equipment_summary_provider.dart`, `conditions_provider.dart` (device first; forecast cloud cover labelled "forecast"; nothing at all when there is no source), `night_log_provider.dart`, `before_you_start_provider.dart` (merges readiness, devices, disk projection, weather source and the configured dawn policy; folds in the setup steps from `tonight_checklist_panel.dart`), `guide_series_provider.dart` (pixel series, RMS, dither marks).
**Optional core change, owned only by P1b:** add a 12 h downsampled buffer to `temperatureHistoryProvider` in `skotiq_core/lib/src/providers/imaging_provider.dart`. If skipped, the UI labels the graph "last 10 min".
**Tests:** a seeded in-memory DB (`test/harness/mock_database.dart`). Cover: medians, missing FWHM → null delta, rejected frames flagged, no weather device → "no source" state, guide series units are px.
**Depends on:** P0.

### P2: manual action and run orchestration (`nc/actions/` and `skotiq_app/lib/services/manual_capture_controller.dart`)
**Files:**
- `nc/actions/night_action_controller.dart`: a Riverpod Notifier implementing `NightActionApi`, exposing `ManualActionState` {active id, phase: idle | pausingRun | waitingForFrame | running | resuming, startedRunPause, message}.
- `nc/actions/run_pause_guard.dart`
- `nc/actions/solve_and_sync.dart`
- `nc/actions/armed_start_provider.dart` ("Start at dark")
- `services/manual_capture_controller.dart`: Snapshot and Loop lifted out of `imaging_screen_actions.dart`, which itself stays untouched.

**`RunPauseGuard` algorithm:**
1. If the run is `running`, call `SequenceActionService.pause()` and record `weStartedPause = true`. If the user had already paused, record `false`.
2. Wait for `paused` **and** the camera to be idle (`cameraStateProvider.isExposing == false` and `exposureProgressProvider` idle). Expose the remaining exposure time to the UI so it can show "Pausing after #44 · 108 s".
3. Run the action under single-flight. Every other manual action is disabled meanwhile; Cancel is available.
4. In a `finally`: resume only if `weStartedPause` is true and the state is still `paused`. If resume fails, leave the run paused, surface an error banner and log it. **Never stop, never park.**

**Per-action rules:**
- **Autofocus:** relies on the existing guiding pause (`autofocus_controls.dart:208-240`). On failure: notify, log, resume the run at the previous focus. Never park.
- **Center / Slew & center:** stop guiding before the slew. Afterwards start guiding and wait for settle before resuming, because a resumed run assumes guiding is active.
- **Solve & sync:** solve the last saved frame if it was taken at the current pointing; otherwise take a short exposure with the solve settings. Then `MountCommandService.sync`. Record solve duration in the controller state for the Solve tab.
- **Dither:** `phd2Controller.dither`, then wait for settle.
- **Flip:** disabled while running or paused, with the reason "the run's meridian trigger owns flips"; uses the standalone path when idle.
- **Loop during a run:** the phase becomes `pausedForAction` with the message "Stop loop to resume".
- **Gating:** every action is gated on `backendCanCommandProvider` and device connection, each with an explicit `disabledReason`.

**Armed start:** a Dart timer that calls `start()` at astronomical dark. Visible "Starts at 19:48 · Cancel". Cleared when the app restarts. The UI states that the app must stay open.

**Tests:** `t/actions/*_test.dart` with a fake executor and MockBackend. Cover: we-paused → resumed; user-paused → not resumed; resume failure → stays paused, no stop call; autofocus throws → resume called, `parkMount` never called (verify on mock); waits for the camera to go idle; double tap joins the in-flight action; remote read-only → disabled.

**Depends on:** P0.

### P3: UI kit additions (`skotiq_ui`, sole owner of `skotiq_ui/lib/skotiq_ui.dart` exports)
**Files:**
- `skotiq_ui/lib/src/components/night_timeline_strip.dart`: 14 px strip, several windows, done/active fill, now marker, labels row, semantics sentence.
- `skotiq_ui/lib/src/components/series_chart.dart`: up to three line series, gaps for null points, vertical markers, highlighted points, optional second axis, no axis chrome, theme-aware.
- `skotiq_ui/lib/src/components/metric_grid.dart`: dense value/label/delta grid built on `Readout`.
- `skotiq_ui/lib/src/components/panel_tab_strip.dart`: the six text tabs with a dot badge.
- Tests in `skotiq_ui/test/components/`.

**Acceptance:** contrast passes in dark, light and red night (follow `skotiq_ui/test/dark_contrast_test.dart`). No hardcoded colors.

**Depends on:** P0's API notes. Land this early; wave 2 needs it.

### P4: header and left column (`nc/header/`, `nc/left/`)
**Files:** `night_header_bar.dart` (title, pill, plan name, progress text, `NightTimelineStrip`; Pause/Resume, Skip step, Stop (hold to confirm), or Edit plan / Start at dark / Start now; disabled reasons), `left/target_section.dart`, `left/plan_section.dart`, `left/steps_section.dart` ("open in Sequencer" sets `selectedNodeIdProvider` and navigates to `kSequencerRoutePath`), `left/coming_up_section.dart` (the "The night" variant before a run), `left/night_left_column.dart`.
**Tests:** a widget test for each, using P0 fixtures. Cover: header switches controls by `NightRunPhase`; long target names ellipsize; steps auto-scroll to the active step.
**Depends on:** P0, P1a, P2 (header buttons), P3.

### P5: center column (`nc/center/`)
**Files:** `frame_stage.dart` (ImageDisplayWidget, overlay pills, view buttons wired to `imagingViewerStateProvider` and star/annotation overlays, a top progress bar for the current exposure, empty states: "Nothing captured yet" before a run, and the Ready board's snapshot state "not saved"), `manual_action_bar.dart` (VMs from P2; pressing a button selects its panel tab; pausing state shown on the button), `frame_strip.dart` (thumbnail sidecar, per-frame HFR, rejected frames dimmed with an error-tone HFR, newest ringed, tap shows the frame; Ready state shows last night's summary or nothing), `session_charts_row.dart` (three `SeriesChart`s; Ready variants: last autofocus curve, guiding idle card with Start looping / Open PHD2 (`phd2_launcher.dart`), cooling ramp), `night_center.dart`.
**Tests:** frame present/absent; autofocus running shows "Autofocus · point n of N"; action disabled reasons; the guide chart legend reads "px"; layout at 744x758 with no overflow.
**Depends on:** P0, P1b, P2, P3.

### P6: right panel Overview, Camera and Focus (`nc/panel/overview/`, `nc/panel/camera/`, `nc/panel/focus/`, `nc/panel/night_right_panel.dart`)
**Overview:** last frame, histogram, session, equipment, conditions, log; before a run, Before you start.
**Camera:** cooler with history, setpoint, warm-up/off. Capture fields drive manual exposure settings; during a run they are read-only and show the active step with "Edit in Sequencer". Filter slots (disabled during a run), readout.
**Focus:** live V-curve (`VCurveChart`), points table without a stars column unless data exists, Cancel and Settings…, focuser jog and go-to, temperature compensation block (hidden if there's no model), recent runs for this session.
`night_right_panel.dart` holds the `PanelTabStrip` and an `IndexedStack`; P7's tab bodies plug into it through constructor-injected widgets to avoid import cycles.
**Tests:** one per tab, plus "no weather source", "camera disconnected" and "panel at 300x758 scrolls without overflow".
**Depends on:** P0, P1b, P2, P3.

### P7: right panel Mount, Guide and Solve (`nc/panel/mount/`, `nc/panel/guide/`, `nc/panel/solve/`)
**Mount:** position block, tracking rates, a move pad built on `mount_jog.dart`. P7 **moves** `dashboard/widgets/mount_jog.dart`, the MoveAxis/watchdog logic from `mount_control_card.dart:600-660`, and `test/screens/dashboard/mount_jog_pad_test.dart` into `nc/panel/mount/`. Go to, Home, Unpark, Park (explicit confirm dialog, never automatic), Limits…, flip settings line. Leave out "Set park" and "Swap E/W" until native or settings support exists.
**Guide:** state, metrics, loop / find star / stop / clear and recalibrate / dither now / flip calibration, star view, scatter in px, calibration data, dither & settle values with Edit opening the Guiding settings.
**Solve:** last solve, Solve / Solve & sync / Center (through P2), reslew toggle, settings, rotation advice, recent solves.
**Tests:** jog release-on-dispose watchdog (moved test); Park needs confirmation; Flip disabled during a run with its reason; guide "no PHD2" state.
**Depends on:** P0, P1b, P2, P3.

### P8: integration (one agent, last)
- Create `nc/night_control_screen.dart`, which composes all slots and keeps the side effects the old screen kept: watching `phd2ControllerProvider`, `runDashboardCriticalEventsBridgeProvider`, and the Recovery / Critical banners (`dashboard_screen.dart:80-84,213-214`).
- Switch the `/dashboard` builder in `app_router.dart`. Update `first_night_wizard_route.dart`, the `skotiq_app.dart` export, and the hide rules in `running_sequence_mini_bar.dart` and `app_shell.dart`.
- Move `tonight_night.dart` and `tonightArcProvider` into `nc/data/`, then delete the old dashboard files and tests listed in section 2.
- Update `test/golden/public_screenshots_test.dart` and the dashboard references in `test/harness/pump_app_screen.dart` and `test/screens/mobile_tap_target_test.dart`.
- Add `t/night_control_owner_window_test.dart` (pattern: `test/screens/imaging/imaging_owner_window_layout_test.dart`): the real shell at 1536x864, DPR 1, rail expanded and collapsed, every state on the boards (Ready, Running, autofocus running, each tab), with `takeException()` null and the action bar not overflowing.
- Add `test/golden/night_control_golden_test.dart`, a **capture golden** (not pixel-diff) writing `docs/design/goldens/night-control-{ready,running,focus,mount,guide,solve,camera}.png` via `surface_golden_harness.dart`.

**Goldens:** regenerate on Linux only, with `SKOTIQ_CAPTURE_ASSETS=1`, for preview. Also regenerate `assets/screenshots/desktop-dashboard.png` through `public_screenshots_test.dart`. Don't commit a regenerated PNG unless the owner asks. The pixel-diff (`matchesGoldenFile`) suites are unaffected.

---

## 4. Risks and safety rules

**Native or bridge work.** None of this is needed for the plan above; each item is shown as missing or disabled until approved.
- **N1:** `mount_set_park` (bridge `devices/mount.rs` + `DeviceService`) for "Set park".
- **N2:** an in-run "request flip now" command into the meridian trigger. Until then "Flip now" is disabled during runs.
- **N3:** per-point star count in autofocus progress events.
- **N4:** PHD2 pixel scale, to label the guide chart in arcseconds.
- **N5:** optionally, a native "abort current frame and pause". Cancelling a sequencer exposure from Dart (`imagingService.cancelExposure`) has not been checked against the executor's failure and recovery handling, so the default is to wait for the frame to finish.

**Manual actions during a run.** All of them go through `RunPauseGuard` (P2): resume only what this controller paused; on failure leave the run paused and visible, and never stop it. Slews (center) must stop and restart guiding, or the resumed run images with guiding lost. Filter changes and capture-setting edits are disabled during a run, because the running sequence owns them and `canEditSequenceProvider` is false.

**Safety rules, each enforced by a test:**
- No code path on this screen calls `parkMount` except the Mount tab's Park button after explicit confirmation.
- A failed autofocus never parks and never stops the run.
- Rejected frames and quality limits only notify (red marks, log lines). They never pause, stop or park.
- The "Dawn" checklist item states the configured safety policy exactly. If there's no site or the policy is off, it says so (see commits `196685ed0` and `ce865087e`).
- Stop uses hold-to-confirm with `preserveCheckpoint: true` (`sequence_action_service.dart:127`).

**Data honesty: what the UI shows instead of a made-up number:**
- Seeing, power, USB bandwidth, star HFD: leave the field out.
- No weather device: Conditions header reads "no weather source". Show forecast cloud cover only labelled "forecast".
- Night-median deltas: no delta when the metric isn't in the DB.
- Ambient series: use focuser temperature labelled as such, or nothing.
- Cooler history: "last 10 min" unless P1b extends the buffer.
- Planned times and timeline windows: prefix with "≈" (estimator output).
- Actual step times: show only when session events exist; otherwise show the planned time.
- Autofocus recent runs and recent solves: "this session"; no history before an app restart.
- Guide chart: "px" axis.

Also fix, inside P1b's new provider, the existing `?? 0` pixel defaulting: a sample with no axis data is dropped, not plotted at 0.

**Start at dark** is Dart-side only. It doesn't survive an app restart and doesn't cover the headless host. The UI says this.

**Remote / slave viewers** (NetworkBackend): data works through `recentSessionFramesProvider` and the DB mirror. Actions are gated by `backendCanCommandProvider`.

**File size:** keep every new file under 1000 lines (the oversized-file audit warns at 1000, `tools/production/oversized_file_audit.dart:9`).

---

## 5. Verification gates (real commands, run from the worktree root)

- Format: `dart run melos run format -- --set-exit-if-changed` (CI gate)
- Analyze: `dart run melos run analyze` and `dart run melos run analyze:production` (zero errors and criticals)
- Tests: `dart run melos run test` (excludes the `golden` tag). Targeted: `cd packages/skotiq_app && flutter test test/screens/night_control test/localization test/screens/shell test/router`; `cd packages/skotiq_ui && flutter test`
- Placeholder: `dart run melos run audit:placeholders`, or the direct command with `--min-files 797` from `docs/ci-gates.md`
- Fail-closed: `dart run melos run audit:fail-closed` (`--min-files 1337`)
- Behavioral: `dart run tools/production/behavioral_audit.dart --register docs/production-readiness/behavioral-audit-register.md --fail-on-unregistered --fail-on-open --report .behavioral_audit_hits.txt --min-files 796`
- Dependency hygiene: `dart run tools/production/dependency_hygiene.dart`
- Informational, review before merge: `melos run audit:design-tokens`, `audit:narrative-comments`, `audit:stale-comments`, `audit:oversized-files`
- Capture goldens (Linux, preview only): `cd packages/skotiq_app && SKOTIQ_CAPTURE_ASSETS=1 flutter test test/golden/night_control_golden_test.dart test/golden/public_screenshots_test.dart`
- Release check at the owner's size (as in the u5 report): `cd apps/desktop && flutter build linux --release`, copy in `libskotiq_bridge.so`, run under `xvfb-run -s "-screen 0 1536x864x24"` with a scratch `HOME` and `SKOTIQ_DATABASE_DIR`, visit Tonight in every state, confirm `app.log` has no overflow or exception lines.
- Rust gates (`cargo test/clippy/fmt` in `native/skotiq_native`) only if N1–N5 are approved.

### Critical Files for Implementation
- /home/scdouglas/.cache/ns-worktrees/skotiq/packages/skotiq_app/lib/screens/dashboard/dashboard_screen.dart
- /home/scdouglas/.cache/ns-worktrees/skotiq/packages/skotiq_app/lib/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart
- /home/scdouglas/.cache/ns-worktrees/skotiq/packages/skotiq_app/lib/services/sequence_action_service.dart
- /home/scdouglas/.cache/ns-worktrees/skotiq/packages/skotiq_core/lib/src/services/device_service.dart
- /home/scdouglas/.cache/ns-worktrees/skotiq/packages/skotiq_app/lib/router/app_router.dart
