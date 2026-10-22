part of '../settings_provider.dart';

/// Retries a failed camera exposure or filter-wheel move gets by default
/// ("Camera retries", "Filter wheel retries").
const int kDefaultDeviceRetries = 3;

/// Highest retry count the executor accepts for either device.
const int kMaxDeviceRetries = 10;

class AppSettingsState {
  // General
  final bool startMinimized;
  final bool autoConnectEquipment;
  final bool confirmBeforeClosing;
  final bool autoDiscoverOnLaunch;

  // Appearance
  final String theme; // 'dark' or 'light'
  final String language; // 'en', 'es'
  final String accentColor; // hex color
  final String fontSize; // 'Small', 'Medium', 'Large'
  final String
  uiScale; // 'Auto', 'Small (0.8x)', 'Normal (1.0x)', 'Large (1.2x)', 'Extra Large (1.4x)'
  final bool sidebarCollapsed;

  // Location
  final double latitude;
  final double longitude;
  final double elevation;
  final String timezone;
  final bool useSystemTime;

  // Imaging
  final String imageFormat; // 'FITS', 'XISF', 'TIFF'
  final String fileNamingPattern;
  final String bitDepth; // '16-bit', '32-bit'

  // Sequencer
  final bool parkOnUnsafeWeather;
  final bool parkBeforeDawn;

  /// Whether a quality problem the sequencer judges — guiding RMS over the
  /// limit, a Center that cannot solve, a dither that does not settle, a
  /// failed post-flip check — stops the run. Off: the operator is notified
  /// and the run keeps imaging (owner decision 2026-10-06). DB key
  /// `stop_run_on_quality_problems`.
  final bool stopRunOnQualityProblems;
  final int meridianFlipMinutes; // minutes before meridian
  final bool autoFocusOnFilterChange;
  final bool useFilterFocusOffsets; // Apply focus offsets when changing filters
  final int autoFocusEveryMinutes;
  final bool ditherEnabled;
  final int ditherEveryFrames;

  /// Times a failed camera exposure is retried before it counts as a failure
  /// (0 = one attempt). Only faults that can clear are retried.
  final int cameraRetries;

  /// Times a failed filter-wheel move is retried before it counts as a
  /// failure (0 = one attempt).
  final int filterWheelRetries;
  final SafetyFailMode
  safetyFailMode; // How to behave when safety data unavailable

  // Sequencer editor layout — cross-restart UI persistence.
  //
  // All nullable: `null` = "no stored preference, use the responsive
  // default". The sequencer screen seeds its in-session StateProviders from
  // these on first read and writes back through the matching setters on
  // change, so a dragged panel / collapsed toolbox / chosen tab survives an
  // app restart.
  /// Whether the sequencer's left toolbox panel is collapsed.
  final bool? sequencerToolboxCollapsed;

  /// Whether the sequencer's right properties panel is collapsed.
  final bool? sequencerPropertiesCollapsed;

  /// Whether the snippet palette is visible in the sequencer.
  final bool? sequencerSnippetPaletteVisible;

  /// Active toolbox tab id within the sequencer toolbox panel.
  final String? sequencerToolboxTab;

  /// Active editor tab index in the sequencer.
  final int? sequencerActiveTab;

  /// Persisted width (px) of the sequencer's left panel after a drag.
  final double? sequencerLeftPanelWidth;

  /// Persisted width (px) of the sequencer's right panel after a drag.
  final double? sequencerRightPanelWidth;

  // Plate Solving
  final String plateSolver; // 'ASTAP', 'Astrometry.net', 'PlateSolve2'
  final String astapPath;
  final String astrometryPath;
  final int plateSolveTimeout;
  final double plateSolveSearchRadius;
  final bool blindSolve;
  final bool centeringSyncMount;

  // PHD2 Guiding
  final String phd2Path;
  final String phd2Host;
  final int phd2Port;

  // Notifications
  final bool notificationsEnabled;
  final String discordWebhook;
  final String pushoverKey;
  final String pushoverUser;
  final bool notifyOnSequenceComplete;
  final bool notifyOnError;
  final bool notifyOnMeridianFlip;
  final bool soundEnabled;

  // File Paths
  final String imageOutputPath;
  final String sequencesPath;
  final String databasePath;
  final String logsPath;

  // Protocol Settings
  final String indiServerHost;
  final int indiServerPort;
  final bool indiAutoConnect;
  final String alpacaServerHost;
  final int alpacaServerPort;
  final bool alpacaAutoDiscover;

  // Remote Access / Web Server Settings
  final bool webServerEnabled;
  final int webServerPort;

  // Equipment Settings - Camera
  final int defaultGain;
  final int defaultOffset;

  // Equipment Settings - Mount
  final bool enableMeridianFlip;

  // Equipment Settings - Focuser
  final bool tempCompensation;
  final double tempCoefficient;
  final int backlashCompensation;

  // Equipment Settings - Guider
  final String ditherScale; // 'Small', 'Medium', 'Large'
  final double settleThreshold;
  final int settleTimeout;
  final int settleTime;
  final bool ditherRaOnly;

  // Observing Environment
  final int bortleClass; // 1-9, Bortle dark-sky scale
  final String
  horizonProfileJson; // JSON: 8 altitude values at N/NE/E/SE/S/SW/W/NW

  /// Effective horizon in degrees used by the Run Dashboard, scheduler and
  /// planetarium when computing "time-to-set". 0° = mathematical horizon;
  /// a value like 20° models trees / structures the user can't see
  /// through. The same value is consumed by every "set" display in the
  /// app so the dashboard and the planetarium agree to the second.
  final double effectiveHorizonDeg;

  /// When true, critical-severity executor events trigger a system bell on
  /// top of the in-app banner / notification. Useful for unattended
  /// imaging where the user has walked away from the laptop.
  final bool audibleAlertsOnCritical;

  /// Which sound to play when [audibleAlertsOnCritical] fires.
  ///
  /// Allowed values:
  ///   * `systemBell` (default): Flutter's [SystemSound.alert] — works on
  ///     Windows / macOS / Linux / iOS / Android.
  ///   * `none`: silence even when [audibleAlertsOnCritical] is true, so the
  ///     operator can mute the audio without losing the banner.
  final String criticalAlertSound;

  /// When true, the headless server forwards critical-severity executor
  /// events to paired mobile clients as push notifications, on top of the
  /// in-app banner / notification. Default on — if the user has gone to the
  /// trouble of pairing a phone, they want to be alerted.
  final bool pushCriticalAlerts;

  // Recovery mode — user-tunable defaults
  /// Minutes between auto-retry attempts during a recovery loop. SGP
  /// default: 10 minutes. Persisted as a double-precision count of
  /// minutes so the bridge layer can multiply by 60 once.
  final double recoveryDefaultRetryIntervalMins;

  /// Total minutes before the recovery loop gives up. SGP default: 90.
  final double recoveryDefaultMaxDurationMins;

  /// When true, the executor stops the mount tracking on recovery entry.
  /// Default off, and never applied to a lost guide star or a weather hold,
  /// which are mostly cloud: a tracking mount is still on the target when the
  /// stars come back.
  final bool recoveryStopTrackingDuringRecovery;

  /// When true, an imminent meridian crossing inside the recovery window
  /// aborts the loop instead of trying to retry across the flip. SGP
  /// behaviour: a recovery loop that straddles a flip leaves the rig in
  /// an unpredictable state.
  final bool recoveryAbortOnMeridian;

  /// When true, ring the platform alert sound on recovery entry. Reuses
  /// the existing critical-alert path so the user setting is unified
  /// with [audibleAlertsOnCritical].
  final bool recoveryAudibleAlertWhenEntered;

  // Autofocus Settings
  final String afMethod; // 'Star HFR'
  final String afCurveFitting; // 'Hyperbolic', 'Parabolic', 'Trend Lines'
  final int afStepSize; // step size between measurement points
  final double afExposureTime; // default exposure for AF frames
  final int afInitialOffsetSteps; // how many steps out from center
  final int afNumberOfAttempts; // retry count on failure
  final int afUseBrightestNStars; // 0 = use all; default 10
  final double afOuterCropRatio;
  final double afInnerCropRatio;
  final int afBinning;
  final double afRSquaredThreshold;
  final double afFailureHfrToleranceRatio;
  final bool afDisableGuidingDuringAf;
  final int afFocuserSettleTimeMs;
  final int afExposuresPerPoint;
  final String afBacklashCompMethod; // 'None', 'Overshoot', 'Absolute'
  final int afBacklashIn;

  /// Whether to offer to measure this focuser's backlash: `ask` or `never`.
  /// The operator can dismiss the offer for good — it must never become a
  /// prompt that reappears every cold start.
  final String focuserBacklashOfferMode;

  /// The operator's saved choices for a backlash calibration run, as a JSON
  /// blob of `FocuserBacklashCalibrationSettings.toJson`. Empty means no
  /// choices stored — the run seeds itself from the autofocus settings.
  final String focuserBacklashCalibrationJson;
  final String mountSiteSyncMode;
  final int afBacklashOut;
  final String
  afAutofocusFilterName; // designated filter for AF runs (empty = use current)
  final String
  afFilterSettingsJson; // JSON map of filter name to FilterAutofocusConfig

  /// Observer name written into FITS `OBSERVER`. Empty string
  /// (the default) is treated as "no observer" and the keyword is omitted
  /// from FITS rather than emitted with a sentinel.
  final String observerName;

  // Image grading (live frame Pass/Reject)
  /// Master switch: when false, no grading runs and the executor's
  /// RuntimeConfig.default_quality_check is set to None at start.
  final bool enableImageGrading;

  /// Reject if HFR exceeds this absolute pixel value. `null` => don't
  /// apply the absolute check.
  final double? imageGradingHfrThresholdPx;

  /// Reject if HFR exceeds `baseline * (1 + percent / 100)`. `null` =>
  /// don't apply the baseline-relative check.
  final double? imageGradingHfrBaselinePercent;

  /// Reject if star eccentricity exceeds this value. `null` => don't apply.
  final double? imageGradingEccentricityThreshold;

  /// Reject if detected star count falls below this. `null` => don't apply.
  final int? imageGradingStarCountMin;

  /// Notify the operator once when this many frames in a row are rejected
  /// (default 3). The run carries on.
  final int imageGradingMaxConsecutiveRejects;

  /// Override for the reject folder. `null` => use `<save_path>/Reject/`.
  /// Relative paths resolve against the run save_path; absolute paths are
  /// used verbatim.
  final String? imageGradingRejectFolderPath;

  // Sky-brightness adaptive exposure (global defaults)
  /// Master switch for the global default adaptive-exposure config.
  /// When false the global default is cleared in the executor and only
  /// per-node overrides apply.
  final bool adaptiveExposureEnabled;

  /// Target SNR (informational; live math uses background flux ratio).
  final double adaptiveExposureTargetSnr;

  /// Reference sky brightness (mag/arcsecÂ²) the nominal duration was
  /// calibrated for. Dark-site default 21.5.
  final double adaptiveExposureReferenceMag;

  /// Global minimum exposure clamp (seconds).
  final double adaptiveExposureMinSecs;

  /// Global maximum exposure clamp (seconds).
  final double adaptiveExposureMaxSecs;

  /// Per-filter enable map. Empty => apply globally.
  final Map<String, bool> adaptiveExposurePerFilterEnabled;

  /// Per-filter minimum exposure overrides (seconds).
  final Map<String, double> adaptiveExposurePerFilterMinSecs;

  /// Per-filter maximum exposure overrides (seconds).
  final Map<String, double> adaptiveExposurePerFilterMaxSecs;

  // Pre-flight checks
  /// How aggressively the pre-flight dialog should warn or block on
  /// questionable conditions (missing darks, stale polar alignment, time
  /// drift, focuser at edge of travel, etc.). Default [PreflightStrictness.normal].
  final PreflightStrictness preflightStrictness;

  /// Maximum age in days for the last polar alignment before pre-flight
  /// flags it as stale. Default 7 days (assuming a permanently-mounted
  /// rig). Portable rigs typically want 1 (every session).
  final int polarAlignmentMaxAgeDays;

  /// Minimum number of dark frames required to consider a (gain, offset,
  /// temp, duration, binning) combination "covered". Below this the
  /// pre-flight rule emits a coverage warning. Default 10 (median-combine
  /// produces a master with usable read-noise reduction at N >= 10).
  final int darkLibraryMinCoverage;

  /// Threshold (mm or score units) above which the optical-train pre-flight
  /// comparison flags "your rig has shifted since last session". The
  /// comparison runs over the diagnostics `tiltScore` + `collimationScore`
  /// delta. Default 8 — picks up a meaningful spacer change without firing
  /// on noise.
  final double opticalTrainDriftThreshold;

  // Smart Night auto-builder defaults
  /// Maximum session wall-clock duration (hours) the Smart Night wizard
  /// uses to cap the planning window. `null` => use the full dark window
  /// (astronomical dusk → dawn).
  final double? smartNightMaxSessionHours;

  /// Default autofocus cadence (frames) for the Smart Night wizard when
  /// running the `everyNFrames` strategy.
  final int smartNightDefaultAfCadenceFrames;

  /// Default integration budget per target (minutes) the wizard uses.
  /// Tweaks the per-target window cap when composing per-filter plans.
  final int smartNightDefaultIntegrationBudgetMinsPerTarget;

  /// Whether the wizard appends end-of-session flats when the active
  /// profile has a cover calibrator.
  final bool smartNightIncludeFlatsAtEnd;

  /// Whether the wizard wraps multi-target plans in a TargetSchedulerNode
  /// (rather than a linear chain) when the target count is at or above
  /// [smartNightSchedulerTargetThreshold].
  final bool smartNightUseSchedulerForMultiTarget;

  /// Minimum target count before the wizard auto-picks scheduler mode.
  final int smartNightSchedulerTargetThreshold;

  /// Default Smart Night strategy persisted across sessions. One of
  /// `auto_lrgb`, `mono_lrgb`, `narrowband_hoo`, `narrowband_sho`,
  /// `osc_one_shot`.
  final String smartNightDefaultStrategy;

  /// Days after which a polar alignment is "stale" enough to warrant the
  /// Smart Night wizard prepending an alignment node. Distinct from the
  /// pre-flight rule's [polarAlignmentMaxAgeDays] knob because the wizard
  /// wants the freshness target to be configurable independently (e.g.
  /// pre-flight at 7 days, but Smart Night prepends only at 14 days).
  final int smartNightPolarAlignmentStaleAfterDays;

  /// Smart Night exposure calculator floor (seconds). Separate from the
  /// runtime adaptive-exposure floor so one feature does not silently tune
  /// the other.
  final double smartNightSubExposureFloorSecs;

  /// Smart Night exposure calculator ceiling (seconds).
  final double smartNightSubExposureCeilingSecs;

  /// Smart Night planning SNR target used by the exposure calculator.
  final double smartNightTargetSnr;

  /// Whether the Smart Night wizard defaults to auto-picking the top N
  /// targets (vs. manual selection). Persisted so the choice survives
  /// across launches instead of resetting to true each time.
  final bool smartNightAutoSelect;

  /// How many targets the Smart Night wizard auto-picks when
  /// [smartNightAutoSelect] is true.
  final int smartNightAutoSelectCount;

  /// Astronomical-day key (yyyy-MM-dd) for which the dashboard Smart Night
  /// auto-prompt was dismissed via "Hide for tonight". Persisted so the
  /// dismissal survives a same-night restart. Empty when not dismissed.
  final String smartNightPromptDismissedDayKey;

  // Notes / journal preferences
  /// Whether the auto-prompt note dialog appears after a sequence run
  /// completes. Defaults to true (opt-out, not opt-in: the session
  /// report is more useful when the user is in the habit of dropping
  /// a quick note at the end of every run).
  ///
  /// Mirrored in the database app_settings table under the
  /// `notes.prompt_after_run` key (see [kPromptForNotesAfterRunKey]).
  final bool promptForNotesAfterRun;

  // Session lifecycle preferences

  /// Whether the multi-night carry-over banner auto-opens at pre-flight
  /// when an unfinished session is detected for one of the sequence's
  /// targets. Default true: the banner is informational only, the user
  /// still has to pick Resume / Restart / Continue New.
  ///
  /// Mirrored in the database under `session.handoff_auto_prompt`.
  final bool sessionHandoffAutoPrompt;

  /// Whether the Targets tab in the sequencer surfaces a per-target
  /// campaign rollup column ("Total integration: 24h Lum, 8h Ha across
  /// 6 sessions"). Default true. Users with a clean targets table can
  /// flip this off for less visual noise.
  ///
  /// Mirrored in the database under `campaign_rollup.surface_targets_tab`.
  final bool campaignRollupSurfaceTargetsTab;

  /// How the campaign rollup groups runs for a given target:
  ///   * `by_target_name` — case-insensitive name match (default; works
  ///     across sequences that re-name the same object).
  ///   * `by_target_id` — exact Drift `targets.id` match (stricter).
  ///   * `by_user_tag` — group by the `targets.tags` field when present.
  ///
  /// Mirrored in the database under `campaign_rollup.grouping_mode`.
  final String campaignRollupGroupingMode;

  // Adaptive sky-conditions target swap defaults
  //
  // These knobs pre-fill the matching fields on a newly-created
  // [TargetSchedulerNode]. Changing them never mutates an existing node
  // — they're "what should the next scheduler I drop in look like?".
  // Persisted as raw strings in `app_settings`; the map is JSON-encoded.

  /// When true, new [TargetSchedulerNode]s are created with
  /// [TargetSchedulerNode.swapOnConditionsBelow] set to
  /// [adaptiveSwapDefaultThreshold]. When false, new schedulers ship
  /// with adaptive swap *disabled* (`swapOnConditionsBelow = null`) so
  /// the user has to opt in explicitly.
  ///
  /// Mirrored under `adaptive_swap.enabled_by_default`.
  final bool adaptiveSwapEnabledByDefault;

  /// Default conditions-score floor (0..=100) seeded into a new
  /// scheduler's `swapOnConditionsBelow`. Only consulted when
  /// [adaptiveSwapEnabledByDefault] is true.
  ///
  /// Mirrored under `adaptive_swap.default_threshold`.
  final double adaptiveSwapDefaultThreshold;

  /// Default `swapHysteresisSecs` (seconds between consecutive swaps)
  /// seeded into a new scheduler. Mirrored under
  /// `adaptive_swap.default_hysteresis_secs`.
  final double adaptiveSwapDefaultHysteresisSecs;

  /// Per-axis composer weights for the live ConditionsScore. Keys:
  /// `transparency` / `seeing` / `cloud` / `wind`. Mirrored under
  /// `adaptive_swap.score_weights` as a JSON object.
  final Map<String, double> conditionsScoreWeights;

  const AppSettingsState({
    // General
    this.startMinimized = false,
    this.autoConnectEquipment = true,
    this.confirmBeforeClosing = true,
    this.autoDiscoverOnLaunch = true,

    // Appearance
    this.theme = 'dark',
    this.language = 'en',
    this.accentColor = kDefaultAccentColorHex,
    this.fontSize = 'Medium',
    this.uiScale = 'Auto',
    this.sidebarCollapsed = true,

    // Location
    this.latitude = 0.0,
    this.longitude = 0.0,
    this.elevation = 0.0,
    this.timezone = 'UTC',
    this.useSystemTime = true,

    // Imaging
    this.imageFormat = 'FITS',
    this.fileNamingPattern = r'$TARGET_$FILTER_$DATE_$SEQ',
    this.bitDepth = '16-bit',

    // Sequencer
    this.parkOnUnsafeWeather = true,
    this.parkBeforeDawn = true,
    this.stopRunOnQualityProblems = false,
    this.meridianFlipMinutes = 5,
    this.autoFocusOnFilterChange = false,
    this.useFilterFocusOffsets = true,
    this.autoFocusEveryMinutes = 60,
    this.ditherEnabled = true,
    this.ditherEveryFrames = 3,
    this.cameraRetries = kDefaultDeviceRetries,
    this.filterWheelRetries = kDefaultDeviceRetries,
    this.safetyFailMode = SafetyFailMode.failClosed,

    // Sequencer editor layout (null = use responsive default).
    this.sequencerToolboxCollapsed,
    this.sequencerPropertiesCollapsed,
    this.sequencerSnippetPaletteVisible,
    this.sequencerToolboxTab,
    this.sequencerActiveTab,
    this.sequencerLeftPanelWidth,
    this.sequencerRightPanelWidth,

    // Plate Solving
    this.plateSolver = 'ASTAP',
    this.astapPath = '',
    this.astrometryPath = '',
    this.plateSolveTimeout = 60,
    this.plateSolveSearchRadius = 30.0,
    this.blindSolve = false,
    this.centeringSyncMount = true,

    // PHD2 Guiding
    this.phd2Path = '',
    this.phd2Host = 'localhost',
    this.phd2Port = 4400,

    // Notifications
    this.notificationsEnabled = true,
    this.discordWebhook = '',
    this.pushoverKey = '',
    this.pushoverUser = '',
    this.notifyOnSequenceComplete = true,
    this.notifyOnError = true,
    this.notifyOnMeridianFlip = false,
    this.soundEnabled = true,

    // File Paths
    this.imageOutputPath = '',
    this.sequencesPath = '',
    this.databasePath = '',
    this.logsPath = '',

    // Protocol Settings
    this.indiServerHost = 'localhost',
    this.indiServerPort = 7624,
    this.indiAutoConnect = false,
    this.alpacaServerHost = 'localhost',
    this.alpacaServerPort = 11111,
    this.alpacaAutoDiscover = false,

    // Remote Access / Web Server
    this.webServerEnabled = false,
    this.webServerPort = 8080,

    // Equipment Settings - Camera
    this.defaultGain = 100,
    this.defaultOffset = 50,

    // Equipment Settings - Mount
    this.enableMeridianFlip = true,

    // Equipment Settings - Focuser
    this.tempCompensation = false,
    this.tempCoefficient = -12.0,
    this.backlashCompensation = 0,

    // Equipment Settings - Guider
    this.ditherScale = 'Medium',
    this.settleThreshold = 1.5,
    this.settleTimeout = 60,
    this.settleTime = 10,
    this.ditherRaOnly = false,

    // Observing Environment
    this.bortleClass = 5,
    this.horizonProfileJson =
        '{"N":0,"NE":0,"E":0,"SE":0,"S":0,"SW":0,"W":0,"NW":0}',
    this.effectiveHorizonDeg = 0.0,
    this.audibleAlertsOnCritical = false,
    this.criticalAlertSound = 'systemBell',
    this.pushCriticalAlerts = true,
    // Recovery Mode — SGP-matching defaults.
    this.recoveryDefaultRetryIntervalMins = 10.0,
    this.recoveryDefaultMaxDurationMins = 90.0,
    this.recoveryStopTrackingDuringRecovery = false,
    this.recoveryAbortOnMeridian = true,
    this.recoveryAudibleAlertWhenEntered = true,

    // Autofocus Settings
    this.afMethod = 'Star HFR',
    this.afCurveFitting = 'Hyperbolic',
    this.afStepSize = 50,
    this.afExposureTime = 4.0,
    this.afInitialOffsetSteps = 4,
    this.afNumberOfAttempts = 1,
    this.afUseBrightestNStars = 10,
    this.afOuterCropRatio = 1.0,
    this.afInnerCropRatio = 0.0,
    this.afBinning = 1,
    this.afRSquaredThreshold = 0.7,
    this.afFailureHfrToleranceRatio = 1.6,
    this.afDisableGuidingDuringAf = false,
    this.afFocuserSettleTimeMs = 500,
    this.afExposuresPerPoint = 1,
    this.afBacklashCompMethod = 'Overshoot',
    this.afBacklashIn = 0,
    this.focuserBacklashOfferMode = 'ask',
    this.focuserBacklashCalibrationJson = '',
    this.mountSiteSyncMode = 'ask',
    this.afBacklashOut = 0,
    this.afAutofocusFilterName = '',
    this.afFilterSettingsJson = '{}',

    // Observer name (FITS OBSERVER keyword).
    this.observerName = '',
    this.enableImageGrading = false,
    this.imageGradingHfrThresholdPx = 3.5,
    this.imageGradingHfrBaselinePercent = 50.0,
    this.imageGradingEccentricityThreshold = 0.8,
    this.imageGradingStarCountMin = 10,
    this.imageGradingMaxConsecutiveRejects = 3,
    this.imageGradingRejectFolderPath,
    this.adaptiveExposureEnabled = false,
    this.adaptiveExposureTargetSnr = 30.0,
    this.adaptiveExposureReferenceMag = 21.5,
    this.adaptiveExposureMinSecs = 5.0,
    this.adaptiveExposureMaxSecs = 600.0,
    this.adaptiveExposurePerFilterEnabled = const {},
    this.adaptiveExposurePerFilterMinSecs = const {},
    this.adaptiveExposurePerFilterMaxSecs = const {},
    this.preflightStrictness = PreflightStrictness.normal,
    this.polarAlignmentMaxAgeDays = 7,
    this.darkLibraryMinCoverage = 10,
    this.opticalTrainDriftThreshold = 8.0,
    this.smartNightMaxSessionHours,
    this.smartNightDefaultAfCadenceFrames = 25,
    this.smartNightDefaultIntegrationBudgetMinsPerTarget = 240,
    this.smartNightIncludeFlatsAtEnd = true,
    this.smartNightUseSchedulerForMultiTarget = true,
    this.smartNightSchedulerTargetThreshold = 3,
    this.smartNightDefaultStrategy = 'auto_lrgb',
    this.smartNightPolarAlignmentStaleAfterDays = 7,
    this.smartNightSubExposureFloorSecs = 30.0,
    this.smartNightSubExposureCeilingSecs = 300.0,
    this.smartNightTargetSnr = 30.0,
    this.smartNightAutoSelect = true,
    this.smartNightAutoSelectCount = 2,
    this.smartNightPromptDismissedDayKey = '',
    this.promptForNotesAfterRun = true,
    this.sessionHandoffAutoPrompt = true,
    this.campaignRollupSurfaceTargetsTab = true,
    this.campaignRollupGroupingMode = 'by_target_name',
    this.adaptiveSwapEnabledByDefault = false,
    this.adaptiveSwapDefaultThreshold = 50.0,
    this.adaptiveSwapDefaultHysteresisSecs = 180.0,
    this.conditionsScoreWeights = const {
      'transparency': 0.40,
      'seeing': 0.25,
      'cloud': 0.25,
      'wind': 0.10,
    },
  });

  /// Whether the operator has actually given Skotiq an observing site.
  ///
  /// See [siteLocationIsSet] for why the origin is the sentinel. Prefer this
  /// (or [observerSite]) over re-testing [latitude] and [longitude] at the call
  /// site: the hand-rolled copies of that comparison drifted, which is how
  /// Settings → Location came to print `0 °` as a settled coordinate while the
  /// Dashboard beside it said "Set an observing location".
  bool get hasObserverLocation => siteLocationIsSet(latitude, longitude);

  /// The configured site, or null when none has been set.
  ///
  /// This is the null-vs-zero seam: [latitude] and [longitude] are
  /// non-nullable doubles that a fresh profile fills with 0.0, so they cannot
  /// themselves express "the user never chose". Anything that renders a
  /// position, or derives an altitude / azimuth / twilight from one, should
  /// take it from here and show an honest empty state for null.
  ObserverLocation? get observerSite => hasObserverLocation
      ? ObserverLocation(
          latitude: latitude,
          longitude: longitude,
          elevation: elevation,
        )
      : null;
}

/// Canonical "is there an observing site?" test.
///
/// A fresh profile seeds `observer_latitude` / `observer_longitude` /
/// `observer_elevation` at 0.0 before the user has been asked anything, so the
/// stored coordinates always parse to a *valid* position — 0°, 0° is a real
/// point, in the Gulf of Guinea, about 600 km off Ghana. Nothing observes from
/// there, so the origin is the app's documented "not set" sentinel, exactly as
/// `targetCoordinatesUnset` treats a Target node's 0h/+0° birth coordinates.
///
/// The cost is that an operator genuinely at 0°, 0° reads as unset; nudging
/// either value by a millionth of a degree (the precision the Location editor
/// already exposes) claims it back.
bool siteLocationIsSet(double latitude, double longitude) =>
    latitude != 0.0 || longitude != 0.0;
