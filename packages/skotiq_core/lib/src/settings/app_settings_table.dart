/// Every application setting, declared once.
///
/// To add a setting, add one entry here and run
/// `SKOTIQ_REGENERATE=1 flutter test test/settings/app_settings_generated_test.dart`
/// in `packages/skotiq_core`. The entry gives `AppSettingsState` its field
/// (the `///` lines above the entry become the field's documentation), and
/// the stored row, the install seed, the host/client wire value and the push
/// to the executor all follow from it. A setting a linked client can change
/// also needs a field of the same wire name on the wire model
/// (`models/settings/app_settings.dart`); a test fails if one is missing.
library;

import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show kDefaultHeadlessPort;

import '../models/settings/app_settings.dart'
    show SafetyFailMode, kDefaultAccentColorHex;
import 'capture_format.dart';
import 'device_retries.dart';
import 'preflight_strictness.dart';
import 'setting.dart';

const List<Setting<Object?>> kAppSettingsTable = [
  BoolSetting(
    'startMinimized',
    'start_minimized',
    false,
    sync: SettingSync.thisComputer,
    seeded: true,
  ),
  BoolSetting(
    'autoConnectEquipment',
    'auto_connect_equipment',
    true,
    wireKey: 'autoConnect',
    seeded: true,
  ),
  BoolSetting(
    'confirmBeforeClosing',
    'confirm_before_closing',
    true,
    sync: SettingSync.thisComputer,
    seeded: true,
  ),
  BoolSetting(
    'autoDiscoverOnLaunch',
    'auto_discover_on_launch',
    true,
    seeded: true,
  ),
  /// `dark` or `light`.
  TextSetting('theme', 'theme', 'dark', clientKeepsOwn: true, seeded: true),

  /// `en` or `es`.
  TextSetting('language', 'language', 'en', seeded: true),
  TextSetting(
    'accentColor',
    'accent_color',
    kDefaultAccentColorHex,
    clientKeepsOwn: true,
    emptyWireIsFallback: true,
    seeded: true,
  ),

  /// `Small`, `Medium` or `Large`.
  TextSetting(
    'fontSize',
    'font_size',
    'Medium',
    clientKeepsOwn: true,
    seeded: true,
  ),

  /// `Auto`, `Small (0.8x)`, `Normal (1.0x)`, `Large (1.2x)` or
  /// `Extra Large (1.4x)`.
  TextSetting(
    'uiScale',
    'ui_scale',
    'Auto',
    clientKeepsOwn: true,
    seeded: true,
  ),
  BoolSetting(
    'sidebarCollapsed',
    'sidebar_collapsed',
    true,
    sync: SettingSync.thisComputer,
    clientKeepsOwn: true,
    seeded: true,
  ),
  DoubleSetting(
    'latitude',
    'observer_latitude',
    0.0,
    feeds: ExecutorConfig.location,
    seeded: true,
  ),
  DoubleSetting(
    'longitude',
    'observer_longitude',
    0.0,
    feeds: ExecutorConfig.location,
    seeded: true,
  ),
  DoubleSetting(
    'elevation',
    'observer_elevation',
    0.0,
    feeds: ExecutorConfig.observerProfile,
    seeded: true,
  ),
  TextSetting('timezone', 'timezone', 'UTC', seeded: true),
  BoolSetting('useSystemTime', 'use_system_time', true, seeded: true),
  TextSetting(
    'imageFormat',
    'image_format',
    kCaptureImageFormat,
    normalize: normalizeCaptureImageFormat,
    seeded: true,
  ),
  TextSetting(
    'fileNamingPattern',
    'file_naming_pattern',
    r'$TARGET_$FILTER_$DATE_$SEQ',
    emptyWireIsFallback: true,
    seeded: true,
  ),
  TextSetting(
    'bitDepth',
    'bit_depth',
    kCaptureBitDepth,
    normalize: normalizeCaptureBitDepth,
    seeded: true,
  ),
  BoolSetting(
    'parkOnUnsafeWeather',
    'park_on_unsafe_weather',
    true,
    feeds: ExecutorConfig.parkPolicy,
    seeded: true,
  ),
  BoolSetting(
    'parkBeforeDawn',
    'park_before_dawn',
    true,
    feeds: ExecutorConfig.parkPolicy,
    seeded: true,
  ),

  /// Whether a quality problem the sequencer judges — guiding RMS over the
  /// limit, a Center that cannot solve, a dither that does not settle, a
  /// failed post-flip check — stops the run. Off: the operator is notified
  /// and the run keeps imaging (owner decision 2026-10-06).
  BoolSetting(
    'stopRunOnQualityProblems',
    'stop_run_on_quality_problems',
    false,
    feeds: ExecutorConfig.qualityPolicy,
    seeded: true,
  ),

  /// A run held by a mount fault solves, syncs and resumes on its own. Off
  /// by default: the operator recovers the mount.
  BoolSetting(
    'mountGuardAutoSyncResume',
    'mount_guard_auto_sync_resume',
    false,
    seeded: true,
  ),

  /// Minutes before the meridian.
  IntSetting('meridianFlipMinutes', 'meridian_flip_minutes', 5, seeded: true),
  BoolSetting(
    'autoFocusOnFilterChange',
    'auto_focus_on_filter_change',
    false,
    seeded: true,
  ),

  BoolSetting(
    'useFilterFocusOffsets',
    'use_filter_focus_offsets',
    true,
    feeds: ExecutorConfig.filterOffsets,
    seeded: true,
  ),
  IntSetting(
    'autoFocusEveryMinutes',
    'auto_focus_every_minutes',
    60,
    seeded: true,
  ),
  BoolSetting('ditherEnabled', 'dither_enabled', true, seeded: true),
  IntSetting('ditherEveryFrames', 'dither_every_frames', 3, seeded: true),

  /// Times a failed camera exposure is retried before it counts as a failure
  /// (0 = one attempt). Only faults that can clear are retried.
  IntSetting(
    'cameraRetries',
    'camera_retries',
    kDefaultDeviceRetries,
    min: 0,
    max: kMaxDeviceRetries,
    feeds: ExecutorConfig.deviceRetries,
    seeded: true,
  ),

  /// Times a failed filter-wheel move is retried before it counts as a
  /// failure (0 = one attempt).
  IntSetting(
    'filterWheelRetries',
    'filter_wheel_retries',
    kDefaultDeviceRetries,
    min: 0,
    max: kMaxDeviceRetries,
    feeds: ExecutorConfig.deviceRetries,
    seeded: true,
  ),

  /// What a run does when safety data is unavailable.
  EnumSetting<SafetyFailMode>(
    'safetyFailMode',
    'safety_fail_mode',
    SafetyFailMode.failClosed,
    SafetyFailMode.values,
    feeds: ExecutorConfig.safetyFailMode,
    seeded: true,
  ),
  // Sequencer editor layout — cross-restart UI persistence.
  //
  // All nullable: `null` = "no stored preference, use the responsive
  // default". The sequencer screen seeds its in-session StateProviders from
  // these on first read and writes back through the matching setters on
  // change, so a dragged panel / collapsed toolbox / chosen tab survives an
  // app restart.
  /// Whether the sequencer's left toolbox panel is collapsed.
  OptionalBoolSetting(
    'sequencerToolboxCollapsed',
    'sequencer.toolbox_collapsed',
    sync: SettingSync.thisComputer,
  ),

  /// Whether the sequencer's right properties panel is collapsed.
  OptionalBoolSetting(
    'sequencerPropertiesCollapsed',
    'sequencer.properties_collapsed',
    sync: SettingSync.thisComputer,
  ),

  /// Whether the snippet palette is visible in the sequencer.
  OptionalBoolSetting(
    'sequencerSnippetPaletteVisible',
    'sequencer.snippet_palette_visible',
    sync: SettingSync.thisComputer,
  ),

  /// Active toolbox tab id within the sequencer toolbox panel.
  OptionalTextSetting(
    'sequencerToolboxTab',
    'sequencer.toolbox_tab',
    sync: SettingSync.thisComputer,
  ),

  /// Active editor tab index in the sequencer.
  OptionalIntSetting(
    'sequencerActiveTab',
    'sequencer.active_tab',
    null,
    sync: SettingSync.thisComputer,
  ),

  /// Persisted width (px) of the sequencer's left panel after a drag.
  OptionalDoubleSetting(
    'sequencerLeftPanelWidth',
    'sequencer.left_panel_width',
    null,
    sync: SettingSync.thisComputer,
  ),

  /// Persisted width (px) of the sequencer's right panel after a drag.
  OptionalDoubleSetting(
    'sequencerRightPanelWidth',
    'sequencer.right_panel_width',
    null,
    sync: SettingSync.thisComputer,
  ),
  /// The label of the native plate-solver preference, kept as a stored copy
  /// for export. The preference itself is the authority.
  TextSetting('plateSolver', 'plate_solver', 'ASTAP', seed: 'Auto'),
  TextSetting('astapPath', 'astap_path', '', seeded: true),
  TextSetting('astrometryPath', 'astrometry_path', '', seeded: true),
  IntSetting('plateSolveTimeout', 'plate_solve_timeout', 60, seeded: true),
  DoubleSetting(
    'plateSolveSearchRadius',
    'plate_solve_search_radius',
    30.0,
    seeded: true,
  ),
  BoolSetting('blindSolve', 'blind_solve', false, seeded: true),
  BoolSetting('centeringSyncMount', 'centering_sync_mount', true, seeded: true),
  TextSetting('phd2Path', 'phd2_path', '', seeded: true),
  TextSetting('phd2Host', 'phd2_host', 'localhost', seeded: true),
  IntSetting('phd2Port', 'phd2_port', 4400, seeded: true),
  BoolSetting(
    'notificationsEnabled',
    'notifications_enabled',
    true,
    seeded: true,
  ),
  TextSetting(
    'discordWebhook',
    'discord_webhook',
    '',
    seeded: true,
    credential: true,
  ),
  TextSetting(
    'pushoverKey',
    'pushover_key',
    '',
    seeded: true,
    credential: true,
  ),
  TextSetting(
    'pushoverUser',
    'pushover_user',
    '',
    seeded: true,
    credential: true,
  ),
  BoolSetting(
    'notifyOnSequenceComplete',
    'notify_on_sequence_complete',
    true,
    seeded: true,
  ),
  BoolSetting('notifyOnError', 'notify_on_error', true, seeded: true),
  BoolSetting(
    'notifyOnMeridianFlip',
    'notify_on_meridian_flip',
    false,
    seeded: true,
  ),
  BoolSetting('soundEnabled', 'sound_enabled', true, seeded: true),
  TextSetting(
    'imageOutputPath',
    'image_output_path',
    '',
    mirrorKey: 'default_image_directory',
    seeded: true,
  ),
  TextSetting('sequencesPath', 'sequences_path', '', seeded: true),
  TextSetting(
    'databasePath',
    'database_path',
    '',
    sync: SettingSync.thisComputer,
    seeded: true,
  ),
  TextSetting(
    'logsPath',
    'logs_path',
    '',
    sync: SettingSync.thisComputer,
    seeded: true,
  ),
  TextSetting('indiServerHost', 'indi_server_host', 'localhost', seeded: true),
  IntSetting('indiServerPort', 'indi_server_port', 7624, seeded: true),
  BoolSetting('indiAutoConnect', 'indi_auto_connect', false, seeded: true),
  TextSetting(
    'alpacaServerHost',
    'alpaca_server_host',
    'localhost',
    seeded: true,
  ),
  IntSetting('alpacaServerPort', 'alpaca_server_port', 11111, seeded: true),
  BoolSetting(
    'alpacaAutoDiscover',
    'alpaca_auto_discover',
    false,
    seeded: true,
  ),

  /// Whether device scans ask the QHY SDK for cameras and filter wheels. Off
  /// on a computer where the QHY SDK crashes or hangs while enumerating.
  /// Applied by the host at start-up and whenever it changes.
  BoolSetting(
    'qhyDiscoveryEnabled',
    'qhy_discovery_enabled',
    true,
    sync: SettingSync.hostStore,
  ),

  /// A self-hoster's mirror of the catalog release, asked before each
  /// catalog's own site. Empty: the Skotiq release.
  TextSetting(
    'catalogBaseUrl',
    'catalog_base_url',
    '',
    sync: SettingSync.hostStore,
  ),
  BoolSetting('webServerEnabled', 'web_server_enabled', false, seeded: true),
  IntSetting(
    'webServerPort',
    'web_server_port',
    kDefaultHeadlessPort,
    seeded: true,
  ),
  IntSetting('defaultGain', 'default_gain', 100, seeded: true),
  IntSetting('defaultOffset', 'default_offset', 50, seeded: true),
  BoolSetting('enableMeridianFlip', 'enable_meridian_flip', true, seeded: true),
  BoolSetting('tempCompensation', 'temp_compensation', false, seeded: true),
  DoubleSetting('tempCoefficient', 'temp_coefficient', -12.0, seeded: true),

  /// Temperature compensation waits until the correction it owes is at least
  /// this many steps, so probe noise and slow drift do not step the focuser
  /// by one every reading.
  IntSetting(
    'tempCompensationMinSteps',
    'temp_compensation_min_steps',
    5,
    seeded: true,
  ),

  /// "Exposure calibration attempts": test exposures every flat calibration
  /// path (sky, panel, the native flat wizard, API runs) may take to find a
  /// filter's flat exposure before it gives up on that filter.
  IntSetting(
    'flatCalibrationAttempts',
    'flat_calibration_attempts',
    20,
    inputMin: 1,
    inputMax: 100,
    seeded: true,
  ),
  IntSetting('backlashCompensation', 'backlash_compensation', 0, seeded: true),
  TextSetting('ditherScale', 'dither_scale', 'Medium', seeded: true),
  DoubleSetting('settleThreshold', 'settle_threshold', 1.5, seeded: true),
  IntSetting('settleTimeout', 'settle_timeout', 60, seeded: true),
  IntSetting('settleTime', 'settle_time', 10, seeded: true),
  BoolSetting('ditherRaOnly', 'dither_ra_only', false, seeded: true),
  IntSetting('bortleClass', 'bortle_class', 5, inputMin: 1, inputMax: 9),
  TextSetting(
    'horizonProfileJson',
    'horizon_profile_json',
    '{"N":0,"NE":0,"E":0,"SE":0,"S":0,"SW":0,"W":0,"NW":0}',
    sync: SettingSync.hostStore,
  ),

  /// Effective horizon in degrees used by the Run Dashboard, scheduler and
  /// planetarium when computing "time-to-set". 0° = mathematical horizon;
  /// a value like 20° models trees / structures the user can't see
  /// through. The same value is consumed by every "set" display in the
  /// app so the dashboard and the planetarium agree to the second.
  DoubleSetting(
    'effectiveHorizonDeg',
    'effective_horizon_deg',
    0.0,
    inputMin: 0.0,
    inputMax: 60.0,
  ),

  /// When true, critical-severity executor events trigger a system bell on
  /// top of the in-app banner / notification. Useful for unattended
  /// imaging where the user has walked away from the laptop.
  BoolSetting('audibleAlertsOnCritical', 'audible_alerts_on_critical', false),

  /// Which sound to play when [audibleAlertsOnCritical] fires.
  ///
  /// Allowed values:
  ///   * `systemBell` (default): Flutter's [SystemSound.alert] — works on
  ///     Windows / macOS / Linux / iOS / Android.
  ///   * `none`: silence even when [audibleAlertsOnCritical] is true, so the
  ///     operator can mute the audio without losing the banner.
  TextSetting(
    'criticalAlertSound',
    'critical_alert_sound',
    'systemBell',
    allowed: ['none', 'systemBell'],
  ),

  /// When true, the headless server forwards critical-severity executor
  /// events to paired mobile clients as push notifications, on top of the
  /// in-app banner / notification. Default on — if the user has gone to the
  /// trouble of pairing a phone, they want to be alerted.
  BoolSetting('pushCriticalAlerts', 'push_critical_alerts', true),
  // Recovery mode — user-tunable defaults
  /// Minutes between auto-retry attempts during a recovery loop. SGP
  /// default: 10 minutes. Persisted as a double-precision count of
  /// minutes so the bridge layer can multiply by 60 once.
  DoubleSetting(
    'recoveryDefaultRetryIntervalMins',
    'recovery_default_retry_interval_mins',
    10.0,
    min: 1.0,
    max: 240.0,
  ),

  /// Total minutes before the recovery loop gives up. SGP default: 90.
  DoubleSetting(
    'recoveryDefaultMaxDurationMins',
    'recovery_default_max_duration_mins',
    90.0,
    min: 1.0,
    max: 1440.0,
  ),

  /// When true, the executor stops the mount tracking on recovery entry.
  /// Default off, and never applied to a lost guide star or a weather hold,
  /// which are mostly cloud: a tracking mount is still on the target when the
  /// stars come back.
  BoolSetting(
    'recoveryStopTrackingDuringRecovery',
    'recovery_stop_tracking_during_recovery_v2',
    false,
  ),

  /// When true, an imminent meridian crossing inside the recovery window
  /// aborts the loop instead of trying to retry across the flip. SGP
  /// behaviour: a recovery loop that straddles a flip leaves the rig in
  /// an unpredictable state.
  BoolSetting('recoveryAbortOnMeridian', 'recovery_abort_on_meridian', true),

  /// When true, ring the platform alert sound on recovery entry. Reuses
  /// the existing critical-alert path so the user setting is unified
  /// with [audibleAlertsOnCritical].
  BoolSetting(
    'recoveryAudibleAlertWhenEntered',
    'recovery_audible_alert_when_entered',
    true,
  ),
  TextSetting('afMethod', 'af_method', 'Star HFR', seeded: true),
  TextSetting('afCurveFitting', 'af_curve_fitting', 'Hyperbolic', seeded: true),
  IntSetting('afStepSize', 'af_step_size', 50, seeded: true),
  DoubleSetting('afExposureTime', 'af_exposure_time', 4.0, seeded: true),
  IntSetting(
    'afInitialOffsetSteps',
    'af_initial_offset_steps',
    4,
    seeded: true,
  ),
  IntSetting('afNumberOfAttempts', 'af_number_of_attempts', 1, seed: '2'),
  IntSetting(
    'afUseBrightestNStars',
    'af_use_brightest_n_stars',
    10,
    seeded: true,
  ),
  DoubleSetting('afOuterCropRatio', 'af_outer_crop_ratio', 1.0, seeded: true),
  DoubleSetting('afInnerCropRatio', 'af_inner_crop_ratio', 0.0, seeded: true),
  IntSetting('afBinning', 'af_binning', 1, seeded: true),
  DoubleSetting(
    'afRSquaredThreshold',
    'af_r_squared_threshold',
    0.7,
    seeded: true,
  ),
  DoubleSetting(
    'afFailureHfrToleranceRatio',
    'af_failure_hfr_tolerance_ratio',
    1.6,
    seeded: true,
  ),
  BoolSetting(
    'afDisableGuidingDuringAf',
    'af_disable_guiding',
    false,
    seeded: true,
  ),
  IntSetting(
    'afFocuserSettleTimeMs',
    'af_focuser_settle_time_ms',
    500,
    seeded: true,
  ),
  IntSetting('afExposuresPerPoint', 'af_exposures_per_point', 1, seeded: true),
  TextSetting(
    'afBacklashCompMethod',
    'af_backlash_comp_method',
    'Overshoot',
    seeded: true,
  ),
  IntSetting('afBacklashIn', 'af_backlash_in', 0, seeded: true),

  /// Whether to offer to measure this focuser's backlash: `ask` or `never`.
  /// The operator can dismiss the offer for good — it must never become a
  /// prompt that reappears every cold start.
  TextSetting(
    'focuserBacklashOfferMode',
    'focuser_backlash_offer_mode',
    'ask',
    sync: SettingSync.hostStore,
    seeded: true,
  ),

  /// The operator's saved choices for a backlash calibration run, as a JSON
  /// blob of `FocuserBacklashCalibrationSettings.toJson`. Empty means no
  /// choices stored — the run seeds itself from the autofocus settings.
  TextSetting(
    'focuserBacklashCalibrationJson',
    'focuser_backlash_calibration_settings',
    '',
    seeded: true,
  ),
  TextSetting(
    'mountSiteSyncMode',
    'mount_site_sync_mode',
    'ask',
    sync: SettingSync.hostStore,
    seeded: true,
  ),
  IntSetting('afBacklashOut', 'af_backlash_out', 0, seeded: true),

  /// The filter autofocus runs use. Empty: the current filter.
  TextSetting(
    'afAutofocusFilterName',
    'af_autofocus_filter_name',
    '',
    seeded: true,
  ),
  TextSetting(
    'afFilterSettingsJson',
    'af_filter_settings',
    '{}',
    feeds: ExecutorConfig.filterOffsets,
    seeded: true,
  ),

  /// Observer name written into FITS `OBSERVER`. Empty string
  /// (the default) is treated as "no observer" and the keyword is omitted
  /// from FITS rather than emitted with a sentinel.
  TextSetting(
    'observerName',
    'observer_name',
    '',
    feeds: ExecutorConfig.observerProfile,
  ),
  // Image grading (live frame Pass/Reject)
  /// Master switch: when false, no grading runs and the executor's
  /// RuntimeConfig.default_quality_check is set to None at start.
  BoolSetting(
    'enableImageGrading',
    'image_grading_enabled',
    false,
    feeds: ExecutorConfig.qualityCheck,
  ),

  /// Reject if HFR exceeds this absolute pixel value. `null` => don't
  /// apply the absolute check.
  OptionalDoubleSetting(
    'imageGradingHfrThresholdPx',
    'image_grading_hfr_threshold_px',
    3.5,
    feeds: ExecutorConfig.qualityCheck,
  ),

  /// Reject if HFR exceeds `baseline * (1 + percent / 100)`. `null` =>
  /// don't apply the baseline-relative check.
  OptionalDoubleSetting(
    'imageGradingHfrBaselinePercent',
    'image_grading_hfr_baseline_percent',
    50.0,
    feeds: ExecutorConfig.qualityCheck,
  ),

  /// Reject if star eccentricity exceeds this value. `null` => don't apply.
  OptionalDoubleSetting(
    'imageGradingEccentricityThreshold',
    'image_grading_eccentricity_threshold',
    0.8,
    feeds: ExecutorConfig.qualityCheck,
  ),

  /// Reject if detected star count falls below this. `null` => don't apply.
  OptionalIntSetting(
    'imageGradingStarCountMin',
    'image_grading_star_count_min',
    10,
    feeds: ExecutorConfig.qualityCheck,
  ),

  /// Notify the operator once when this many frames in a row are rejected
  /// (default 3). The run carries on.
  IntSetting(
    'imageGradingMaxConsecutiveRejects',
    'image_grading_max_consecutive_rejects',
    3,
    feeds: ExecutorConfig.qualityCheck,
  ),

  /// Override for the reject folder. `null` => use `<save_path>/Reject/`.
  /// Relative paths resolve against the run save_path; absolute paths are
  /// used verbatim.
  OptionalTextSetting(
    'imageGradingRejectFolderPath',
    'image_grading_reject_folder_path',
    unsetText: '',
    feeds: ExecutorConfig.rejectFolder,
  ),
  // Sky-brightness adaptive exposure (global defaults)
  /// Master switch for the global default adaptive-exposure config.
  /// When false the global default is cleared in the executor and only
  /// per-node overrides apply.
  BoolSetting(
    'adaptiveExposureEnabled',
    'adaptive_exposure_enabled',
    false,
    feeds: ExecutorConfig.adaptiveExposure,
  ),

  /// Target SNR (informational; live math uses background flux ratio).
  DoubleSetting(
    'adaptiveExposureTargetSnr',
    'adaptive_exposure_target_snr',
    30.0,
    feeds: ExecutorConfig.adaptiveExposure,
    inputMin: 1.0,
  ),

  /// Reference sky brightness (mag/arcsec²) the nominal duration was
  /// calibrated for. Dark-site default 21.5.
  DoubleSetting(
    'adaptiveExposureReferenceMag',
    'adaptive_exposure_reference_mag',
    21.5,
    feeds: ExecutorConfig.adaptiveExposure,
    inputMin: 14.0,
    inputMax: 24.0,
  ),

  /// Global minimum exposure clamp (seconds).
  DoubleSetting(
    'adaptiveExposureMinSecs',
    'adaptive_exposure_min_secs',
    5.0,
    feeds: ExecutorConfig.adaptiveExposure,
  ),

  /// Global maximum exposure clamp (seconds).
  DoubleSetting(
    'adaptiveExposureMaxSecs',
    'adaptive_exposure_max_secs',
    600.0,
    feeds: ExecutorConfig.adaptiveExposure,
  ),

  /// Per-filter enable map. Empty => apply globally.
  BoolMapSetting(
    'adaptiveExposurePerFilterEnabled',
    'adaptive_exposure_per_filter_enabled',
    feeds: ExecutorConfig.adaptiveExposure,
  ),

  /// Per-filter minimum exposure overrides (seconds).
  DoubleMapSetting(
    'adaptiveExposurePerFilterMinSecs',
    'adaptive_exposure_per_filter_min_secs',
    feeds: ExecutorConfig.adaptiveExposure,
  ),

  /// Per-filter maximum exposure overrides (seconds).
  DoubleMapSetting(
    'adaptiveExposurePerFilterMaxSecs',
    'adaptive_exposure_per_filter_max_secs',
    feeds: ExecutorConfig.adaptiveExposure,
  ),
  // Pre-flight checks
  /// How aggressively the pre-flight dialog should warn or block on
  /// questionable conditions (missing darks, stale polar alignment, time
  /// drift, focuser at edge of travel, etc.). Default [PreflightStrictness.normal].
  EnumSetting<PreflightStrictness>(
    'preflightStrictness',
    'preflight_strictness',
    PreflightStrictness.normal,
    PreflightStrictness.values,
  ),

  /// Maximum age in days for the last polar alignment before pre-flight
  /// flags it as stale. Default 7 days (assuming a permanently-mounted
  /// rig). Portable rigs typically want 1 (every session).
  IntSetting(
    'polarAlignmentMaxAgeDays',
    'polar_alignment_max_age_days',
    7,
    min: 0,
    max: 365,
  ),

  /// Minimum number of dark frames required to consider a (gain, offset,
  /// temp, duration, binning) combination "covered". Below this the
  /// pre-flight rule emits a coverage warning. Default 10 (median-combine
  /// produces a master with usable read-noise reduction at N >= 10).
  IntSetting(
    'darkLibraryMinCoverage',
    'dark_library_min_coverage',
    10,
    min: 1,
    max: 1000,
  ),

  /// Threshold (mm or score units) above which the optical-train pre-flight
  /// comparison flags "your rig has shifted since last session". The
  /// comparison runs over the diagnostics `tiltScore` + `collimationScore`
  /// delta. Default 8 — picks up a meaningful spacer change without firing
  /// on noise.
  DoubleSetting(
    'opticalTrainDriftThreshold',
    'optical_train_drift_threshold',
    8.0,
    min: 0.1,
    max: 1000.0,
  ),
  // Smart Night auto-builder defaults
  /// Maximum session wall-clock duration (hours) the Smart Night wizard
  /// uses to cap the planning window. `null` => use the full dark window
  /// (astronomical dusk → dawn).
  OptionalDoubleSetting(
    'smartNightMaxSessionHours',
    'smart_night_max_session_hours',
    null,
  ),

  /// Default autofocus cadence (frames) for the Smart Night wizard when
  /// running the `everyNFrames` strategy.
  IntSetting(
    'smartNightDefaultAfCadenceFrames',
    'smart_night_default_af_cadence_frames',
    25,
    min: 1,
    max: 9999,
  ),

  /// Default integration budget per target (minutes) the wizard uses.
  /// Tweaks the per-target window cap when composing per-filter plans.
  IntSetting(
    'smartNightDefaultIntegrationBudgetMinsPerTarget',
    'smart_night_default_integration_budget_mins_per_target',
    240,
    min: 1,
    max: 24 * 60,
  ),

  /// Whether the wizard appends end-of-session flats when the active
  /// profile has a cover calibrator.
  BoolSetting(
    'smartNightIncludeFlatsAtEnd',
    'smart_night_include_flats_at_end',
    true,
  ),

  /// Whether the wizard wraps multi-target plans in a TargetSchedulerNode
  /// (rather than a linear chain) when the target count is at or above
  /// [smartNightSchedulerTargetThreshold].
  BoolSetting(
    'smartNightUseSchedulerForMultiTarget',
    'smart_night_use_scheduler_for_multi_target',
    true,
  ),

  /// Minimum target count before the wizard auto-picks scheduler mode.
  IntSetting(
    'smartNightSchedulerTargetThreshold',
    'smart_night_scheduler_target_threshold',
    3,
    min: 2,
    max: 20,
  ),

  /// Default Smart Night strategy persisted across sessions. One of
  /// `auto_lrgb`, `mono_lrgb`, `narrowband_hoo`, `narrowband_sho`,
  /// `osc_one_shot`.
  TextSetting(
    'smartNightDefaultStrategy',
    'smart_night_default_strategy',
    'auto_lrgb',
  ),

  /// Days after which a polar alignment is "stale" enough to warrant the
  /// Smart Night wizard prepending an alignment node. Distinct from the
  /// pre-flight rule's [polarAlignmentMaxAgeDays] knob because the wizard
  /// wants the freshness target to be configurable independently (e.g.
  /// pre-flight at 7 days, but Smart Night prepends only at 14 days).
  IntSetting(
    'smartNightPolarAlignmentStaleAfterDays',
    'smart_night_polar_alignment_stale_after_days',
    7,
    min: 1,
    max: 365,
  ),

  /// Smart Night exposure calculator floor (seconds). Separate from the
  /// runtime adaptive-exposure floor so one feature does not silently tune
  /// the other.
  DoubleSetting(
    'smartNightSubExposureFloorSecs',
    'smart_night_sub_exposure_floor_secs',
    30.0,
    min: 1.0,
    max: 3600.0,
  ),

  /// Smart Night exposure calculator ceiling (seconds).
  DoubleSetting(
    'smartNightSubExposureCeilingSecs',
    'smart_night_sub_exposure_ceiling_secs',
    300.0,
    min: 1.0,
    max: 7200.0,
  ),

  /// Smart Night planning SNR target used by the exposure calculator.
  DoubleSetting(
    'smartNightTargetSnr',
    'smart_night_target_snr',
    30.0,
    min: 1.0,
    max: 500.0,
  ),

  /// Whether the Smart Night wizard defaults to auto-picking the top N
  /// targets (vs. manual selection). Persisted so the choice survives
  /// across launches instead of resetting to true each time.
  BoolSetting('smartNightAutoSelect', 'smart_night.auto_select', true),

  /// How many targets the Smart Night wizard auto-picks when
  /// [smartNightAutoSelect] is true.
  IntSetting(
    'smartNightAutoSelectCount',
    'smart_night.auto_select_count',
    2,
    inputMin: 1,
  ),

  /// Astronomical-day key (yyyy-MM-dd) for which the dashboard Smart Night
  /// auto-prompt was dismissed via "Hide for tonight". Persisted so the
  /// dismissal survives a same-night restart. Empty when not dismissed.
  TextSetting(
    'smartNightPromptDismissedDayKey',
    'smart_night.prompt_dismissed_day_key',
    '',
    sync: SettingSync.thisComputer,
  ),
  // Notes / journal preferences
  /// Whether the auto-prompt note dialog appears after a sequence run
  /// completes. Defaults to true (opt-out, not opt-in: the session
  /// report is more useful when the user is in the habit of dropping
  /// a quick note at the end of every run).
  BoolSetting('promptForNotesAfterRun', 'notes.prompt_after_run', true),
  // Session lifecycle preferences

  /// Whether the multi-night carry-over banner auto-opens at pre-flight
  /// when an unfinished session is detected for one of the sequence's
  /// targets. Default true: the banner is informational only, the user
  /// still has to pick Resume / Restart / Continue New.
  BoolSetting('sessionHandoffAutoPrompt', 'session.handoff_auto_prompt', true),

  /// Whether the Targets tab in the sequencer surfaces a per-target
  /// campaign rollup column ("Total integration: 24h Lum, 8h Ha across
  /// 6 sessions"). Default true. Users with a clean targets table can
  /// flip this off for less visual noise.
  BoolSetting(
    'campaignRollupSurfaceTargetsTab',
    'campaign_rollup.surface_targets_tab',
    true,
  ),

  /// How the campaign rollup groups runs for a given target:
  ///   * `by_target_name` — case-insensitive name match (default; works
  ///     across sequences that re-name the same object).
  ///   * `by_target_id` — exact Drift `targets.id` match (stricter).
  ///   * `by_user_tag` — group by the `targets.tags` field when present.
  TextSetting(
    'campaignRollupGroupingMode',
    'campaign_rollup.grouping_mode',
    'by_target_name',
    allowed: ['by_target_name', 'by_target_id', 'by_user_tag'],
  ),
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
  BoolSetting(
    'adaptiveSwapEnabledByDefault',
    'adaptive_swap.enabled_by_default',
    false,
  ),

  /// Default conditions-score floor (0..=100) seeded into a new
  /// scheduler's `swapOnConditionsBelow`. Only consulted when
  /// [adaptiveSwapEnabledByDefault] is true.
  DoubleSetting(
    'adaptiveSwapDefaultThreshold',
    'adaptive_swap.default_threshold',
    50.0,
    min: 0.0,
    max: 100.0,
  ),

  /// Default `swapHysteresisSecs` (seconds between consecutive swaps)
  /// seeded into a new scheduler.
  DoubleSetting(
    'adaptiveSwapDefaultHysteresisSecs',
    'adaptive_swap.default_hysteresis_secs',
    180.0,
    min: 0.0,
    max: 3600.0,
  ),

  /// Per-axis composer weights for the live ConditionsScore. Keys:
  /// `transparency` / `seeing` / `cloud` / `wind`. Stored as a JSON object.
  DoubleMapSetting(
    'conditionsScoreWeights',
    'adaptive_swap.score_weights',
    entries: {
      'transparency': 0.40,
      'seeing': 0.25,
      'cloud': 0.25,
      'wind': 0.10,
    },
    fixedKeys: true,
  ),
];
