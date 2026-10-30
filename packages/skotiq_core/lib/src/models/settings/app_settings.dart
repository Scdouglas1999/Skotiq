import 'package:freezed_annotation/freezed_annotation.dart';

part 'app_settings.freezed.dart';
part 'app_settings.g.dart';

/// Default accent color hex — matches `SkotiqColors.dark.primary` (#E86A6A),
/// the red. Seeded into `app_settings` at install; migration v62
/// rewrites the old seed (#6EB3EC) to this on existing installs.
const kDefaultAccentColorHex = '#E86A6A';

/// Defines how the safety system behaves when weather/safety devices fail or are unavailable
enum SafetyFailMode {
  /// Treat unavailable safety data as safe; allow imaging to continue uninterrupted.
  failOpen,

  /// Treat unavailable safety data as unsafe; pause imaging and optionally park the mount.
  failClosed,

  /// Treat unavailable safety data as safe but emit a UI warning so the user is aware.
  warnOnly,
}

@freezed
abstract class ObserverLocation with _$ObserverLocation {
  const factory ObserverLocation({
    required double latitude,
    required double longitude,
    required double elevation,
  }) = _ObserverLocation;

  factory ObserverLocation.fromJson(Map<String, dynamic> json) =>
      _$ObserverLocationFromJson(json);
}

/// Remote settings wire model. Every field here must also appear in
/// `_remotableSettingKeys` (settings_sections/app_settings_partial_persistence
/// _mapping.dart) under its DB key, or a remote save of that key throws through
/// the `_assertKeysRemotable` guard instead of round-tripping.
@freezed
abstract class AppSettings with _$AppSettings {
  const factory AppSettings({
    ObserverLocation? location,
    @Default('dark') String theme,
    @Default('en') String language,
    @Default(true) bool autoConnect,
    // Additional fields for compatibility with provider AppSettings
    @Default(0.0) double latitude,
    @Default(0.0) double longitude,
    @Default(0.0) double elevation,
    @Default('') String fileNamingPattern,
    @Default(5) int meridianFlipMinutes,
    @Default(60) int autoFocusEveryMinutes,
    @Default(3) int ditherEveryFrames,
    @Default(60) int plateSolveTimeout,
    @Default(30.0) double plateSolveSearchRadius,
    @Default('') String discordWebhook,
    @Default('') String pushoverKey,
    @Default('') String pushoverUser,
    @Default('') String astapPath,
    // Discovery settings
    @Default(true) bool autoDiscoverOnLaunch,
    @Default('') String accentColor,
    @Default('Medium') String fontSize,
    @Default('Auto')
    String
    uiScale, // Auto, Small (0.8x), Normal (1.0x), Large (1.2x), Extra Large (1.4x)
    // Protocol settings
    @Default('localhost') String indiServerHost,
    @Default(7624) int indiServerPort,
    @Default(false) bool indiAutoConnect,
    @Default('localhost') String alpacaServerHost,
    @Default(11111) int alpacaServerPort,
    @Default(false) bool alpacaAutoDiscover,
    // Retired: simulation mode is not a shippable runtime state (the bundled
    // native library is always a release build and refuses it). The field
    // stays so stored and remote payloads that still carry it decode; nothing
    // reads it.
    @Default(false) bool useSimulationMode,
    // Image capture settings
    @Default('') String imageOutputPath,
    @Default('') String observer,
    @Default('') String telescope,
    @Default('') String instrument,
    // Update settings
    @Default(true) bool updateCheckEnabled,
    @Default('') String updateServerUrl,
    @Default('stable') String updateChannel,
    @Default(24) int updateCheckIntervalHours,
    @Default('') String skippedUpdateVersion,
    // Safety settings
    @Default(SafetyFailMode.failClosed) SafetyFailMode safetyFailMode,
    // Image grading: live frame Pass/Reject thresholds. Opt-in — disabled by
    // default, so every captured frame is saved and none auto-rejected.
    /// Master switch: when false, no grading runs at all.
    @Default(false) bool enableImageGrading,

    /// Reject if HFR exceeds this absolute pixel value. `null` => don't
    /// apply the absolute check.
    double? imageGradingHfrThresholdPx,

    /// Reject if HFR exceeds `baseline * (1 + percent / 100)`. `null` =>
    /// don't apply the baseline-relative check.
    double? imageGradingHfrBaselinePercent,

    /// Reject if star eccentricity exceeds this value. `null` => don't apply.
    double? imageGradingEccentricityThreshold,

    /// Reject if detected star count falls below this. `null` => don't apply.
    int? imageGradingStarCountMin,

    /// Notify the operator once when this many frames in a row are rejected
    /// (default 3). The run carries on.
    @Default(3) int imageGradingMaxConsecutiveRejects,

    /// Override for the reject folder. `null` => use `<save_path>/Reject/`.
    /// Relative paths resolve against the run save_path; absolute paths
    /// are used verbatim.
    String? imageGradingRejectFolderPath,
    // Sky-brightness adaptive exposures: global defaults, pushed into the
    // executor via `sequencerUpdateDefaultAdaptiveExposure` when no active
    // node carries its own block. Per-ExposureNode overrides win at runtime.
    /// Master switch — when false, the global default adaptive-exposure
    /// is cleared and the executor falls back to nominal duration for
    /// any node without an explicit per-node override.
    @Default(false) bool adaptiveExposureEnabled,

    /// Target SNR for the SNR-based scaling (informational; the live
    /// math uses background flux ratio).
    @Default(30.0) double adaptiveExposureTargetSnr,

    /// Reference sky brightness in mag/arcsec² the nominal exposure
    /// duration was calibrated for. Dark-site default is 21.5.
    @Default(21.5) double adaptiveExposureReferenceMag,

    /// Global minimum exposure clamp in seconds.
    @Default(5.0) double adaptiveExposureMinSecs,

    /// Global maximum exposure clamp in seconds.
    @Default(600.0) double adaptiveExposureMaxSecs,

    /// Per-filter enable map (filter name -> bool). Empty => apply
    /// globally (matches the Rust `is_enabled_for_filter` semantics).
    @Default(<String, bool>{})
    Map<String, bool> adaptiveExposurePerFilterEnabled,

    /// Per-filter minimum exposure overrides (seconds).
    @Default(<String, double>{})
    Map<String, double> adaptiveExposurePerFilterMinSecs,

    /// Per-filter maximum exposure overrides (seconds).
    @Default(<String, double>{})
    Map<String, double> adaptiveExposurePerFilterMaxSecs,
    // Autofocus / dither / weather-safety / recovery knobs an operator tunes
    // for an unattended night.
    /// Weather-safety: when true, the rig parks (not just pauses) when weather
    /// turns unsafe. Mirrors `app_settings` DB key `park_on_unsafe_weather`.
    @Default(true) bool parkOnUnsafeWeather,

    /// Autofocus: run an autofocus pass on every filter change.
    /// DB key `auto_focus_on_filter_change`.
    @Default(false) bool autoFocusOnFilterChange,

    /// Autofocus: disable the guider while an autofocus sweep runs (avoids the
    /// guide star wandering out of frame during the focuser sweep).
    /// DB key `af_disable_guiding`.
    @Default(false) bool afDisableGuidingDuringAf,

    /// Dither: master enable for between-frame dithering.
    /// DB key `dither_enabled`.
    @Default(true) bool ditherEnabled,

    /// Dither: dither step size — 'Small', 'Medium', or 'Large'.
    /// DB key `dither_scale`.
    @Default('Medium') String ditherScale,

    /// Recovery: minutes between auto-retry attempts during a recovery loop.
    /// DB key `recovery_default_retry_interval_mins`.
    @Default(10.0) double recoveryDefaultRetryIntervalMins,

    /// Recovery: total minutes before the recovery loop gives up.
    /// DB key `recovery_default_max_duration_mins`.
    @Default(90.0) double recoveryDefaultMaxDurationMins,

    /// Recovery: stop tracking while recovering; never for a lost guide star
    /// or a weather hold.
    /// DB key `recovery_stop_tracking_during_recovery_v2`.
    @Default(false) bool recoveryStopTrackingDuringRecovery,

    /// Recovery: abort the recovery loop if a meridian crossing falls inside
    /// the recovery window. DB key `recovery_abort_on_meridian`.
    @Default(true) bool recoveryAbortOnMeridian,

    /// Recovery: ring the platform alert sound on recovery entry.
    /// DB key `recovery_audible_alert_when_entered`.
    @Default(true) bool recoveryAudibleAlertWhenEntered,
    // Weather-safety / dawn.
    /// Park the mount before astronomical dawn at the end of the night.
    /// DB key `park_before_dawn`.
    @Default(true) bool parkBeforeDawn,
    // Device retries.
    /// Times a failed camera exposure is retried before it counts as a
    /// failure (0 = one attempt). DB key `camera_retries`.
    @Default(3) int cameraRetries,

    /// Times a failed filter-wheel move is retried before it counts as a
    /// failure (0 = one attempt). DB key `filter_wheel_retries`.
    @Default(3) int filterWheelRetries,

    /// Stop the run for quality problems the sequencer judges (guiding RMS,
    /// centering, settling). Off: notify and keep imaging.
    /// DB key `stop_run_on_quality_problems`.
    @Default(false) bool stopRunOnQualityProblems,
    // Meridian flip detail.
    /// Master enable for automatic meridian flips. DB key `enable_meridian_flip`.
    @Default(true) bool enableMeridianFlip,
    // Focuser temperature compensation + backlash (calibration).
    /// Enable focuser temperature compensation. DB key `temp_compensation`.
    @Default(false) bool tempCompensation,

    /// Temp-comp coefficient (steps per °C). DB key `temp_coefficient`.
    @Default(-12.0) double tempCoefficient,

    /// Focuser backlash compensation (steps). DB key `backlash_compensation`.
    @Default(0) int backlashCompensation,
    // Guider settle (calibration).
    /// Guider settle pixel threshold. DB key `settle_threshold`. Default mirrors
    /// the NINA/PHD2 community convention (~1.5 px); 0.5 px at typical guide
    /// scales makes every dither settle slowly or time out.
    @Default(1.5) double settleThreshold,

    /// Guider settle timeout in seconds. DB key `settle_timeout`. Generous so
    /// a legitimate settle is not aborted early.
    @Default(60) int settleTimeout,

    /// Guider settle stabilisation time in seconds — how long the guide error
    /// must stay within [settleThreshold] before a settle is declared done.
    /// DB key `settle_time`.
    @Default(10) int settleTime,

    /// Dither on the RA axis only, leaving Dec fixed. DB key `dither_ra_only`.
    @Default(false) bool ditherRaOnly,
    // Plate-solving extra.
    /// Selected plate solver ('ASTAP', 'Astrometry.net', 'PlateSolve2').
    /// DB key `plate_solver`.
    @Default('ASTAP') String plateSolver,

    /// Allow a blind (no-hint) solve fallback. DB key `blind_solve`.
    @Default(false) bool blindSolve,

    /// Sync the mount to the plate-solved position between centering
    /// iterations. Without the sync the correction re-issues the slew that
    /// produced the mis-pointed frame, so centering cannot converge.
    /// DB key `centering_sync_mount`.
    @Default(true) bool centeringSyncMount,
    // Site / horizon.
    /// Bortle dark-sky class (1-9). DB key `bortle_class`.
    @Default(5) int bortleClass,

    /// Effective horizon altitude floor in degrees. DB key `effective_horizon_deg`.
    @Default(0.0) double effectiveHorizonDeg,
    // Pre-flight checklist strictness + freshness gates.
    /// Pre-flight strictness as the enum name ('lax' / 'normal' / 'strict').
    /// Carried as a String to avoid the wire model depending on the provider
    /// library that owns the `PreflightStrictness` enum. DB key
    /// `preflight_strictness`.
    @Default('normal') String preflightStrictness,

    /// Polar-alignment max age (days) before pre-flight flags it.
    /// DB key `polar_alignment_max_age_days`.
    @Default(7) int polarAlignmentMaxAgeDays,

    /// Optical-train drift threshold (arcmin) before pre-flight flags it.
    /// DB key `optical_train_drift_threshold`.
    @Default(8.0) double opticalTrainDriftThreshold,
    // Dark library.
    /// Minimum matching dark frames before the dark library is "covered".
    /// DB key `dark_library_min_coverage`.
    @Default(10) int darkLibraryMinCoverage,
    // Smart Night defaults — the one-click "plan tonight" builder reads these
    // when assembling a sequence.
    /// Cap a planned session to this many hours. `null` => use the full dark
    /// window. DB key `smart_night_max_session_hours`.
    double? smartNightMaxSessionHours,

    /// Default autofocus cadence (frames) for built sequences.
    /// DB key `smart_night_default_af_cadence_frames`.
    @Default(25) int smartNightDefaultAfCadenceFrames,

    /// Default per-target integration budget (minutes).
    /// DB key `smart_night_default_integration_budget_mins_per_target`.
    @Default(240) int smartNightDefaultIntegrationBudgetMinsPerTarget,

    /// Append flats at the end of the planned night.
    /// DB key `smart_night_include_flats_at_end`.
    @Default(true) bool smartNightIncludeFlatsAtEnd,

    /// Use the scheduler (vs a single linear sequence) for multi-target nights.
    /// DB key `smart_night_use_scheduler_for_multi_target`.
    @Default(true) bool smartNightUseSchedulerForMultiTarget,

    /// Target count at/above which the scheduler is used.
    /// DB key `smart_night_scheduler_target_threshold`.
    @Default(3) int smartNightSchedulerTargetThreshold,

    /// Default capture strategy id (e.g. 'auto_lrgb').
    /// DB key `smart_night_default_strategy`.
    @Default('auto_lrgb') String smartNightDefaultStrategy,

    /// Days after which polar alignment is considered stale for the wizard.
    /// DB key `smart_night_polar_alignment_stale_after_days`.
    @Default(7) int smartNightPolarAlignmentStaleAfterDays,

    /// Sub-exposure floor (seconds) for the planner.
    /// DB key `smart_night_sub_exposure_floor_secs`.
    @Default(30.0) double smartNightSubExposureFloorSecs,

    /// Sub-exposure ceiling (seconds) for the planner.
    /// DB key `smart_night_sub_exposure_ceiling_secs`.
    @Default(300.0) double smartNightSubExposureCeilingSecs,

    /// Target SNR the planner sizes sub-exposures toward.
    /// DB key `smart_night_target_snr`.
    @Default(30.0) double smartNightTargetSnr,
    // Defaults from here down mirror AppSettingsState's constructor defaults,
    // so the wire model never injects a different value than local state.
    // Equipment defaults (camera).
    /// Default camera gain. DB `default_gain`.
    @Default(100) int defaultGain,

    /// Default camera offset. DB `default_offset`.
    @Default(50) int defaultOffset,
    // Remote access / web server.
    /// Headless web server enabled. DB `web_server_enabled`.
    @Default(false) bool webServerEnabled,

    /// Headless web server port. DB `web_server_port`.
    @Default(8080) int webServerPort,
    // PHD2 connection.
    /// PHD2 executable path. DB `phd2_path`.
    @Default('') String phd2Path,

    /// PHD2 host. DB `phd2_host`.
    @Default('localhost') String phd2Host,

    /// PHD2 port. DB `phd2_port`.
    @Default(4400) int phd2Port,
    // Notification toggles.
    /// Master notifications switch. DB `notifications_enabled`.
    @Default(true) bool notificationsEnabled,

    /// Notify when a sequence completes. DB `notify_on_sequence_complete`.
    @Default(true) bool notifyOnSequenceComplete,

    /// Notify on error. DB `notify_on_error`.
    @Default(true) bool notifyOnError,

    /// Notify on meridian flip. DB `notify_on_meridian_flip`.
    @Default(false) bool notifyOnMeridianFlip,

    /// In-app notification sound. DB `sound_enabled`.
    @Default(true) bool soundEnabled,

    /// Ring the platform alert on critical-severity events. DB
    /// `audible_alerts_on_critical`.
    @Default(false) bool audibleAlertsOnCritical,

    /// Which sound for critical alerts ('systemBell' / 'none'). DB
    /// `critical_alert_sound`.
    @Default('systemBell') String criticalAlertSound,

    /// Forward critical alerts to paired phones as push. DB `push_critical_alerts`.
    @Default(true) bool pushCriticalAlerts,
    // Session-lifecycle + campaign-rollup prefs.
    /// Prompt for notes after a run. DB `notes.prompt_after_run`.
    @Default(true) bool promptForNotesAfterRun,

    /// Auto-open the multi-night carry-over banner. DB
    /// `session.handoff_auto_prompt`.
    @Default(true) bool sessionHandoffAutoPrompt,

    /// Surface the campaign-rollup column on the Targets tab. DB
    /// `campaign_rollup.surface_targets_tab`.
    @Default(true) bool campaignRollupSurfaceTargetsTab,

    /// Campaign-rollup grouping mode. DB `campaign_rollup.grouping_mode`.
    @Default('by_target_name') String campaignRollupGroupingMode,
    // Autofocus detailed sweep params.
    /// AF method. DB `af_method`.
    @Default('Star HFR') String afMethod,

    /// AF curve fitting. DB `af_curve_fitting`.
    @Default('Hyperbolic') String afCurveFitting,

    /// AF step size between measurement points. DB `af_step_size`.
    @Default(50) int afStepSize,

    /// AF exposure time (seconds). DB `af_exposure_time`.
    @Default(4.0) double afExposureTime,

    /// AF initial offset steps out from center. DB `af_initial_offset_steps`.
    @Default(4) int afInitialOffsetSteps,

    /// AF retry count on failure. DB `af_number_of_attempts`.
    @Default(1) int afNumberOfAttempts,

    /// AF brightest-N stars (0 = all). DB `af_use_brightest_n_stars`.
    /// On by default: counting every detection lets faint, noisy sources
    /// swamp the measurement.
    @Default(10) int afUseBrightestNStars,

    /// AF outer crop ratio. DB `af_outer_crop_ratio`.
    @Default(1.0) double afOuterCropRatio,

    /// AF inner crop ratio. DB `af_inner_crop_ratio`.
    @Default(0.0) double afInnerCropRatio,

    /// AF binning. DB `af_binning`.
    @Default(1) int afBinning,

    /// AF R² fit-quality threshold. DB `af_r_squared_threshold`.
    @Default(0.7) double afRSquaredThreshold,

    /// How far above the reference HFR the frames may sit, as a multiple, and
    /// still be worth capturing after autofocus has failed.
    /// DB `af_failure_hfr_tolerance_ratio`.
    ///
    /// A failed autofocus never parks the rig or ends the run: the focuser
    /// goes back where it was, the operator is notified and imaging carries
    /// on. This ratio decides what the notice says about the frames: at 1.6
    /// a run whose good HFR is 2.5 is told frames at 3.8 are slightly soft
    /// and frames at 10 are past the limit.
    @Default(1.6) double afFailureHfrToleranceRatio,

    /// AF focuser settle time (ms). DB `af_focuser_settle_time_ms`.
    @Default(500) int afFocuserSettleTimeMs,

    /// AF exposures per measurement point. DB `af_exposures_per_point`.
    @Default(1) int afExposuresPerPoint,

    /// AF backlash compensation method. DB `af_backlash_comp_method`.
    @Default('Overshoot') String afBacklashCompMethod,

    /// AF backlash-in steps. DB `af_backlash_in`.
    @Default(0) int afBacklashIn,

    /// What to do when a connected mount's site/time disagrees with this
    /// computer's. DB `mount_site_sync_mode`.
    @Default('ask') String mountSiteSyncMode,

    /// AF backlash-out steps. DB `af_backlash_out`.
    @Default(0) int afBacklashOut,

    /// Designated AF filter (empty = current). DB `af_autofocus_filter_name`.
    @Default('') String afAutofocusFilterName,

    /// Per-filter AF config JSON map. DB `af_filter_settings`.
    @Default('{}') String afFilterSettingsJson,

    /// Saved backlash-calibration choices as a JSON blob. DB
    /// `focuser_backlash_calibration_settings`.
    @Default('') String focuserBacklashCalibrationJson,

    /// Apply focus offsets on filter change. DB `use_filter_focus_offsets`.
    @Default(true) bool useFilterFocusOffsets,
    // Misc imaging / FITS / plate-solve config relevant to an unattended night.
    /// Astrometry.net solver path. DB `astrometry_path`.
    @Default('') String astrometryPath,

    /// FITS OBSERVER keyword. DB `observer_name`.
    @Default('') String observerName,

    /// Image format ('FITS' / 'XISF' / 'TIFF'). DB `image_format`.
    @Default('FITS') String imageFormat,

    /// Bit depth ('16-bit' / '32-bit'). DB `bit_depth`.
    @Default('16-bit') String bitDepth,

    /// Observing timezone. DB `timezone`.
    @Default('UTC') String timezone,

    /// Use system time vs a fixed observing time. DB `use_system_time`.
    @Default(true) bool useSystemTime,
    // Sequencer output path default.
    /// User-facing default output directory for saved sequence files. DB
    /// key `sequences_path`.
    @Default('') String sequencesPath,
    // Smart Night target auto-select (the rest of the smart_night.* group
    // is already remoted).
    /// Auto-select the top-N targets when building a Smart Night plan. DB
    /// key `smart_night.auto_select`.
    @Default(true) bool smartNightAutoSelect,

    /// How many targets to auto-select when [smartNightAutoSelect] is true.
    /// DB key `smart_night.auto_select_count`.
    @Default(2) int smartNightAutoSelectCount,
    // Adaptive sky-conditions target-swap scheduler-SEED defaults. These
    // pre-fill a new TargetSchedulerNode; the score weights feed the live
    // ConditionsScore composer (weather_safety_provider). DB keys under
    // `adaptive_swap.*`.
    /// New schedulers ship with adaptive swap enabled by default. DB key
    /// `adaptive_swap.enabled_by_default`.
    @Default(false) bool adaptiveSwapEnabledByDefault,

    /// Default conditions-score floor (0..=100) seeded into a new scheduler.
    /// DB key `adaptive_swap.default_threshold`.
    @Default(50.0) double adaptiveSwapDefaultThreshold,

    /// Default seconds between consecutive swaps seeded into a new scheduler.
    /// DB key `adaptive_swap.default_hysteresis_secs`.
    @Default(180.0) double adaptiveSwapDefaultHysteresisSecs,

    /// Per-axis composer weights for the live ConditionsScore. Keys:
    /// `transparency` / `seeing` / `cloud` / `wind`. DB key
    /// `adaptive_swap.score_weights` (a JSON object).
    @Default(<String, double>{
      'transparency': 0.40,
      'seeing': 0.25,
      'cloud': 0.25,
      'wind': 0.10,
    })
    Map<String, double> conditionsScoreWeights,
  }) = _AppSettings;

  factory AppSettings.fromJson(Map<String, dynamic> json) =>
      _$AppSettingsFromJson(json);
}

// Extension to provide compatibility getters
extension AppSettingsExtension on AppSettings {
  /// Get latitude from location or direct field
  double get effectiveLatitude => location?.latitude ?? latitude;

  /// Get longitude from location or direct field
  double get effectiveLongitude => location?.longitude ?? longitude;

  /// Get elevation from location or direct field
  double get effectiveElevation => location?.elevation ?? elevation;
}
