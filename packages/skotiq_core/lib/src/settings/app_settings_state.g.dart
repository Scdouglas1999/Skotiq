// GENERATED from app_settings_table.dart by
// tool/generate_app_settings.dart. Do not edit: change the
// table and regenerate.

// dart format off

import '../models/settings/app_settings.dart' show SafetyFailMode;
import 'app_settings_table.dart';
import 'preflight_strictness.dart';
import 'setting.dart';

const Object _unset = Object();

/// The declared settings, by field name.
abstract final class AppSettingDefs {
  static final BoolSetting startMinimized = kAppSettingsTable[0] as BoolSetting;
  static final BoolSetting autoConnectEquipment = kAppSettingsTable[1] as BoolSetting;
  static final BoolSetting confirmBeforeClosing = kAppSettingsTable[2] as BoolSetting;
  static final BoolSetting autoDiscoverOnLaunch = kAppSettingsTable[3] as BoolSetting;
  static final TextSetting theme = kAppSettingsTable[4] as TextSetting;
  static final TextSetting language = kAppSettingsTable[5] as TextSetting;
  static final TextSetting accentColor = kAppSettingsTable[6] as TextSetting;
  static final TextSetting fontSize = kAppSettingsTable[7] as TextSetting;
  static final TextSetting uiScale = kAppSettingsTable[8] as TextSetting;
  static final BoolSetting sidebarCollapsed = kAppSettingsTable[9] as BoolSetting;
  static final DoubleSetting latitude = kAppSettingsTable[10] as DoubleSetting;
  static final DoubleSetting longitude = kAppSettingsTable[11] as DoubleSetting;
  static final DoubleSetting elevation = kAppSettingsTable[12] as DoubleSetting;
  static final TextSetting timezone = kAppSettingsTable[13] as TextSetting;
  static final BoolSetting useSystemTime = kAppSettingsTable[14] as BoolSetting;
  static final TextSetting imageFormat = kAppSettingsTable[15] as TextSetting;
  static final TextSetting xisfCompression = kAppSettingsTable[16] as TextSetting;
  static final BoolSetting xisfChecksums = kAppSettingsTable[17] as BoolSetting;
  static final TextSetting fileNamingPattern = kAppSettingsTable[18] as TextSetting;
  static final TextSetting bitDepth = kAppSettingsTable[19] as TextSetting;
  static final BoolSetting parkOnUnsafeWeather = kAppSettingsTable[20] as BoolSetting;
  static final BoolSetting parkBeforeDawn = kAppSettingsTable[21] as BoolSetting;
  static final BoolSetting stopRunOnQualityProblems = kAppSettingsTable[22] as BoolSetting;
  static final BoolSetting mountGuardAutoSyncResume = kAppSettingsTable[23] as BoolSetting;
  static final IntSetting meridianFlipMinutes = kAppSettingsTable[24] as IntSetting;
  static final BoolSetting autoFocusOnFilterChange = kAppSettingsTable[25] as BoolSetting;
  static final BoolSetting useFilterFocusOffsets = kAppSettingsTable[26] as BoolSetting;
  static final IntSetting autoFocusEveryMinutes = kAppSettingsTable[27] as IntSetting;
  static final BoolSetting ditherEnabled = kAppSettingsTable[28] as BoolSetting;
  static final IntSetting ditherEveryFrames = kAppSettingsTable[29] as IntSetting;
  static final IntSetting cameraRetries = kAppSettingsTable[30] as IntSetting;
  static final IntSetting filterWheelRetries = kAppSettingsTable[31] as IntSetting;
  static final EnumSetting<SafetyFailMode> safetyFailMode = kAppSettingsTable[32] as EnumSetting<SafetyFailMode>;
  static final OptionalBoolSetting sequencerToolboxCollapsed = kAppSettingsTable[33] as OptionalBoolSetting;
  static final OptionalBoolSetting sequencerPropertiesCollapsed = kAppSettingsTable[34] as OptionalBoolSetting;
  static final OptionalBoolSetting sequencerSnippetPaletteVisible = kAppSettingsTable[35] as OptionalBoolSetting;
  static final OptionalTextSetting sequencerToolboxTab = kAppSettingsTable[36] as OptionalTextSetting;
  static final OptionalIntSetting sequencerActiveTab = kAppSettingsTable[37] as OptionalIntSetting;
  static final OptionalDoubleSetting sequencerLeftPanelWidth = kAppSettingsTable[38] as OptionalDoubleSetting;
  static final OptionalDoubleSetting sequencerRightPanelWidth = kAppSettingsTable[39] as OptionalDoubleSetting;
  static final TextSetting plateSolver = kAppSettingsTable[40] as TextSetting;
  static final TextSetting astapPath = kAppSettingsTable[41] as TextSetting;
  static final TextSetting astrometryPath = kAppSettingsTable[42] as TextSetting;
  static final IntSetting plateSolveTimeout = kAppSettingsTable[43] as IntSetting;
  static final DoubleSetting plateSolveSearchRadius = kAppSettingsTable[44] as DoubleSetting;
  static final BoolSetting blindSolve = kAppSettingsTable[45] as BoolSetting;
  static final BoolSetting centeringSyncMount = kAppSettingsTable[46] as BoolSetting;
  static final TextSetting phd2Path = kAppSettingsTable[47] as TextSetting;
  static final TextSetting phd2Host = kAppSettingsTable[48] as TextSetting;
  static final IntSetting phd2Port = kAppSettingsTable[49] as IntSetting;
  static final BoolSetting notificationsEnabled = kAppSettingsTable[50] as BoolSetting;
  static final TextSetting discordWebhook = kAppSettingsTable[51] as TextSetting;
  static final TextSetting pushoverKey = kAppSettingsTable[52] as TextSetting;
  static final TextSetting pushoverUser = kAppSettingsTable[53] as TextSetting;
  static final BoolSetting notifyOnSequenceComplete = kAppSettingsTable[54] as BoolSetting;
  static final BoolSetting notifyOnError = kAppSettingsTable[55] as BoolSetting;
  static final BoolSetting notifyOnMeridianFlip = kAppSettingsTable[56] as BoolSetting;
  static final BoolSetting soundEnabled = kAppSettingsTable[57] as BoolSetting;
  static final TextSetting imageOutputPath = kAppSettingsTable[58] as TextSetting;
  static final TextSetting sequencesPath = kAppSettingsTable[59] as TextSetting;
  static final TextSetting databasePath = kAppSettingsTable[60] as TextSetting;
  static final TextSetting logsPath = kAppSettingsTable[61] as TextSetting;
  static final TextSetting indiServerHost = kAppSettingsTable[62] as TextSetting;
  static final IntSetting indiServerPort = kAppSettingsTable[63] as IntSetting;
  static final BoolSetting indiAutoConnect = kAppSettingsTable[64] as BoolSetting;
  static final TextSetting alpacaServerHost = kAppSettingsTable[65] as TextSetting;
  static final IntSetting alpacaServerPort = kAppSettingsTable[66] as IntSetting;
  static final BoolSetting alpacaAutoDiscover = kAppSettingsTable[67] as BoolSetting;
  static final BoolSetting qhyDiscoveryEnabled = kAppSettingsTable[68] as BoolSetting;
  static final TextSetting catalogBaseUrl = kAppSettingsTable[69] as TextSetting;
  static final BoolSetting webServerEnabled = kAppSettingsTable[70] as BoolSetting;
  static final IntSetting webServerPort = kAppSettingsTable[71] as IntSetting;
  static final IntSetting defaultGain = kAppSettingsTable[72] as IntSetting;
  static final IntSetting defaultOffset = kAppSettingsTable[73] as IntSetting;
  static final BoolSetting enableMeridianFlip = kAppSettingsTable[74] as BoolSetting;
  static final BoolSetting tempCompensation = kAppSettingsTable[75] as BoolSetting;
  static final DoubleSetting tempCoefficient = kAppSettingsTable[76] as DoubleSetting;
  static final IntSetting tempCompensationMinSteps = kAppSettingsTable[77] as IntSetting;
  static final IntSetting flatCalibrationAttempts = kAppSettingsTable[78] as IntSetting;
  static final IntSetting backlashCompensation = kAppSettingsTable[79] as IntSetting;
  static final TextSetting ditherScale = kAppSettingsTable[80] as TextSetting;
  static final DoubleSetting settleThreshold = kAppSettingsTable[81] as DoubleSetting;
  static final IntSetting settleTimeout = kAppSettingsTable[82] as IntSetting;
  static final IntSetting settleTime = kAppSettingsTable[83] as IntSetting;
  static final BoolSetting ditherRaOnly = kAppSettingsTable[84] as BoolSetting;
  static final IntSetting bortleClass = kAppSettingsTable[85] as IntSetting;
  static final TextSetting horizonProfileJson = kAppSettingsTable[86] as TextSetting;
  static final DoubleSetting effectiveHorizonDeg = kAppSettingsTable[87] as DoubleSetting;
  static final BoolSetting audibleAlertsOnCritical = kAppSettingsTable[88] as BoolSetting;
  static final TextSetting criticalAlertSound = kAppSettingsTable[89] as TextSetting;
  static final BoolSetting pushCriticalAlerts = kAppSettingsTable[90] as BoolSetting;
  static final DoubleSetting recoveryDefaultRetryIntervalMins = kAppSettingsTable[91] as DoubleSetting;
  static final DoubleSetting recoveryDefaultMaxDurationMins = kAppSettingsTable[92] as DoubleSetting;
  static final BoolSetting recoveryStopTrackingDuringRecovery = kAppSettingsTable[93] as BoolSetting;
  static final BoolSetting recoveryAbortOnMeridian = kAppSettingsTable[94] as BoolSetting;
  static final BoolSetting recoveryAudibleAlertWhenEntered = kAppSettingsTable[95] as BoolSetting;
  static final TextSetting afMethod = kAppSettingsTable[96] as TextSetting;
  static final TextSetting afCurveFitting = kAppSettingsTable[97] as TextSetting;
  static final IntSetting afStepSize = kAppSettingsTable[98] as IntSetting;
  static final DoubleSetting afExposureTime = kAppSettingsTable[99] as DoubleSetting;
  static final IntSetting afInitialOffsetSteps = kAppSettingsTable[100] as IntSetting;
  static final IntSetting afNumberOfAttempts = kAppSettingsTable[101] as IntSetting;
  static final IntSetting afUseBrightestNStars = kAppSettingsTable[102] as IntSetting;
  static final DoubleSetting afOuterCropRatio = kAppSettingsTable[103] as DoubleSetting;
  static final DoubleSetting afInnerCropRatio = kAppSettingsTable[104] as DoubleSetting;
  static final IntSetting afBinning = kAppSettingsTable[105] as IntSetting;
  static final DoubleSetting afRSquaredThreshold = kAppSettingsTable[106] as DoubleSetting;
  static final DoubleSetting afFailureHfrToleranceRatio = kAppSettingsTable[107] as DoubleSetting;
  static final BoolSetting afDisableGuidingDuringAf = kAppSettingsTable[108] as BoolSetting;
  static final IntSetting afFocuserSettleTimeMs = kAppSettingsTable[109] as IntSetting;
  static final IntSetting afExposuresPerPoint = kAppSettingsTable[110] as IntSetting;
  static final TextSetting afBacklashCompMethod = kAppSettingsTable[111] as TextSetting;
  static final IntSetting afBacklashIn = kAppSettingsTable[112] as IntSetting;
  static final TextSetting focuserBacklashOfferMode = kAppSettingsTable[113] as TextSetting;
  static final TextSetting focuserBacklashCalibrationJson = kAppSettingsTable[114] as TextSetting;
  static final TextSetting mountSiteSyncMode = kAppSettingsTable[115] as TextSetting;
  static final IntSetting afBacklashOut = kAppSettingsTable[116] as IntSetting;
  static final TextSetting afAutofocusFilterName = kAppSettingsTable[117] as TextSetting;
  static final TextSetting afFilterSettingsJson = kAppSettingsTable[118] as TextSetting;
  static final TextSetting observerName = kAppSettingsTable[119] as TextSetting;
  static final BoolSetting enableImageGrading = kAppSettingsTable[120] as BoolSetting;
  static final OptionalDoubleSetting imageGradingHfrThresholdPx = kAppSettingsTable[121] as OptionalDoubleSetting;
  static final OptionalDoubleSetting imageGradingHfrBaselinePercent = kAppSettingsTable[122] as OptionalDoubleSetting;
  static final OptionalDoubleSetting imageGradingEccentricityThreshold = kAppSettingsTable[123] as OptionalDoubleSetting;
  static final OptionalIntSetting imageGradingStarCountMin = kAppSettingsTable[124] as OptionalIntSetting;
  static final IntSetting imageGradingMaxConsecutiveRejects = kAppSettingsTable[125] as IntSetting;
  static final OptionalTextSetting imageGradingRejectFolderPath = kAppSettingsTable[126] as OptionalTextSetting;
  static final BoolSetting adaptiveExposureEnabled = kAppSettingsTable[127] as BoolSetting;
  static final DoubleSetting adaptiveExposureTargetSnr = kAppSettingsTable[128] as DoubleSetting;
  static final DoubleSetting adaptiveExposureReferenceMag = kAppSettingsTable[129] as DoubleSetting;
  static final DoubleSetting adaptiveExposureMinSecs = kAppSettingsTable[130] as DoubleSetting;
  static final DoubleSetting adaptiveExposureMaxSecs = kAppSettingsTable[131] as DoubleSetting;
  static final BoolMapSetting adaptiveExposurePerFilterEnabled = kAppSettingsTable[132] as BoolMapSetting;
  static final DoubleMapSetting adaptiveExposurePerFilterMinSecs = kAppSettingsTable[133] as DoubleMapSetting;
  static final DoubleMapSetting adaptiveExposurePerFilterMaxSecs = kAppSettingsTable[134] as DoubleMapSetting;
  static final EnumSetting<PreflightStrictness> preflightStrictness = kAppSettingsTable[135] as EnumSetting<PreflightStrictness>;
  static final IntSetting polarAlignmentMaxAgeDays = kAppSettingsTable[136] as IntSetting;
  static final IntSetting darkLibraryMinCoverage = kAppSettingsTable[137] as IntSetting;
  static final DoubleSetting opticalTrainDriftThreshold = kAppSettingsTable[138] as DoubleSetting;
  static final OptionalDoubleSetting smartNightMaxSessionHours = kAppSettingsTable[139] as OptionalDoubleSetting;
  static final IntSetting smartNightDefaultAfCadenceFrames = kAppSettingsTable[140] as IntSetting;
  static final IntSetting smartNightDefaultIntegrationBudgetMinsPerTarget = kAppSettingsTable[141] as IntSetting;
  static final BoolSetting smartNightIncludeFlatsAtEnd = kAppSettingsTable[142] as BoolSetting;
  static final BoolSetting smartNightUseSchedulerForMultiTarget = kAppSettingsTable[143] as BoolSetting;
  static final IntSetting smartNightSchedulerTargetThreshold = kAppSettingsTable[144] as IntSetting;
  static final TextSetting smartNightDefaultStrategy = kAppSettingsTable[145] as TextSetting;
  static final IntSetting smartNightPolarAlignmentStaleAfterDays = kAppSettingsTable[146] as IntSetting;
  static final DoubleSetting smartNightSubExposureFloorSecs = kAppSettingsTable[147] as DoubleSetting;
  static final DoubleSetting smartNightSubExposureCeilingSecs = kAppSettingsTable[148] as DoubleSetting;
  static final DoubleSetting smartNightTargetSnr = kAppSettingsTable[149] as DoubleSetting;
  static final BoolSetting smartNightAutoSelect = kAppSettingsTable[150] as BoolSetting;
  static final IntSetting smartNightAutoSelectCount = kAppSettingsTable[151] as IntSetting;
  static final TextSetting smartNightPromptDismissedDayKey = kAppSettingsTable[152] as TextSetting;
  static final BoolSetting promptForNotesAfterRun = kAppSettingsTable[153] as BoolSetting;
  static final BoolSetting sessionHandoffAutoPrompt = kAppSettingsTable[154] as BoolSetting;
  static final BoolSetting campaignRollupSurfaceTargetsTab = kAppSettingsTable[155] as BoolSetting;
  static final TextSetting campaignRollupGroupingMode = kAppSettingsTable[156] as TextSetting;
  static final BoolSetting adaptiveSwapEnabledByDefault = kAppSettingsTable[157] as BoolSetting;
  static final DoubleSetting adaptiveSwapDefaultThreshold = kAppSettingsTable[158] as DoubleSetting;
  static final DoubleSetting adaptiveSwapDefaultHysteresisSecs = kAppSettingsTable[159] as DoubleSetting;
  static final DoubleMapSetting conditionsScoreWeights = kAppSettingsTable[160] as DoubleMapSetting;
}

/// The application settings as one immutable value.
class AppSettingsState {
  final bool startMinimized;
  final bool autoConnectEquipment;
  final bool confirmBeforeClosing;
  final bool autoDiscoverOnLaunch;
  /// `dark` or `light`.
  final String theme;
  /// `en` or `es`.
  final String language;
  final String accentColor;
  /// `Small`, `Medium` or `Large`.
  final String fontSize;
  /// `Auto`, `Small (0.8x)`, `Normal (1.0x)`, `Large (1.2x)` or
  /// `Extra Large (1.4x)`.
  final String uiScale;
  final bool sidebarCollapsed;
  final double latitude;
  final double longitude;
  final double elevation;
  final String timezone;
  final bool useSystemTime;
  final String imageFormat;
  final String xisfCompression;
  final bool xisfChecksums;
  final String fileNamingPattern;
  final String bitDepth;
  final bool parkOnUnsafeWeather;
  final bool parkBeforeDawn;
  /// Whether a quality problem the sequencer judges — guiding RMS over the
  /// limit, a Center that cannot solve, a dither that does not settle, a
  /// failed post-flip check — stops the run. Off: the operator is notified
  /// and the run keeps imaging (owner decision 2026-10-06).
  final bool stopRunOnQualityProblems;
  /// A run held by a mount fault solves, syncs and resumes on its own. Off
  /// by default: the operator recovers the mount.
  final bool mountGuardAutoSyncResume;
  /// Minutes before the meridian.
  final int meridianFlipMinutes;
  final bool autoFocusOnFilterChange;
  final bool useFilterFocusOffsets;
  final int autoFocusEveryMinutes;
  final bool ditherEnabled;
  final int ditherEveryFrames;
  /// Times a failed camera exposure is retried before it counts as a failure
  /// (0 = one attempt). Only faults that can clear are retried.
  final int cameraRetries;
  /// Times a failed filter-wheel move is retried before it counts as a
  /// failure (0 = one attempt).
  final int filterWheelRetries;
  /// What a run does when safety data is unavailable.
  final SafetyFailMode safetyFailMode;
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
  /// The label of the native plate-solver preference, kept as a stored copy
  /// for export. The preference itself is the authority.
  final String plateSolver;
  final String astapPath;
  final String astrometryPath;
  final int plateSolveTimeout;
  final double plateSolveSearchRadius;
  final bool blindSolve;
  final bool centeringSyncMount;
  final String phd2Path;
  final String phd2Host;
  final int phd2Port;
  final bool notificationsEnabled;
  final String discordWebhook;
  final String pushoverKey;
  final String pushoverUser;
  final bool notifyOnSequenceComplete;
  final bool notifyOnError;
  final bool notifyOnMeridianFlip;
  final bool soundEnabled;
  final String imageOutputPath;
  final String sequencesPath;
  final String databasePath;
  final String logsPath;
  final String indiServerHost;
  final int indiServerPort;
  final bool indiAutoConnect;
  final String alpacaServerHost;
  final int alpacaServerPort;
  final bool alpacaAutoDiscover;
  /// Whether device scans ask the QHY SDK for cameras and filter wheels. Off
  /// on a computer where the QHY SDK crashes or hangs while enumerating.
  /// Applied by the host at start-up and whenever it changes.
  final bool qhyDiscoveryEnabled;
  /// A self-hoster's mirror of the catalog release, asked before each
  /// catalog's own site. Empty: the Skotiq release.
  final String catalogBaseUrl;
  final bool webServerEnabled;
  final int webServerPort;
  final int defaultGain;
  final int defaultOffset;
  final bool enableMeridianFlip;
  final bool tempCompensation;
  final double tempCoefficient;
  /// Temperature compensation waits until the correction it owes is at least
  /// this many steps, so probe noise and slow drift do not step the focuser
  /// by one every reading.
  final int tempCompensationMinSteps;
  /// "Exposure calibration attempts": test exposures every flat calibration
  /// path (sky, panel, the native flat wizard, API runs) may take to find a
  /// filter's flat exposure before it gives up on that filter.
  final int flatCalibrationAttempts;
  final int backlashCompensation;
  final String ditherScale;
  final double settleThreshold;
  final int settleTimeout;
  final int settleTime;
  final bool ditherRaOnly;
  final int bortleClass;
  final String horizonProfileJson;
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
  final String afMethod;
  final String afCurveFitting;
  final int afStepSize;
  final double afExposureTime;
  final int afInitialOffsetSteps;
  final int afNumberOfAttempts;
  final int afUseBrightestNStars;
  final double afOuterCropRatio;
  final double afInnerCropRatio;
  final int afBinning;
  final double afRSquaredThreshold;
  final double afFailureHfrToleranceRatio;
  final bool afDisableGuidingDuringAf;
  final int afFocuserSettleTimeMs;
  final int afExposuresPerPoint;
  final String afBacklashCompMethod;
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
  /// The filter autofocus runs use. Empty: the current filter.
  final String afAutofocusFilterName;
  final String afFilterSettingsJson;
  /// Observer name written into FITS `OBSERVER`. Empty string
  /// (the default) is treated as "no observer" and the keyword is omitted
  /// from FITS rather than emitted with a sentinel.
  final String observerName;
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
  /// Master switch for the global default adaptive-exposure config.
  /// When false the global default is cleared in the executor and only
  /// per-node overrides apply.
  final bool adaptiveExposureEnabled;
  /// Target SNR (informational; live math uses background flux ratio).
  final double adaptiveExposureTargetSnr;
  /// Reference sky brightness (mag/arcsec²) the nominal duration was
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
  /// Whether the auto-prompt note dialog appears after a sequence run
  /// completes. Defaults to true (opt-out, not opt-in: the session
  /// report is more useful when the user is in the habit of dropping
  /// a quick note at the end of every run).
  final bool promptForNotesAfterRun;
  /// Whether the multi-night carry-over banner auto-opens at pre-flight
  /// when an unfinished session is detected for one of the sequence's
  /// targets. Default true: the banner is informational only, the user
  /// still has to pick Resume / Restart / Continue New.
  final bool sessionHandoffAutoPrompt;
  /// Whether the Targets tab in the sequencer surfaces a per-target
  /// campaign rollup column ("Total integration: 24h Lum, 8h Ha across
  /// 6 sessions"). Default true. Users with a clean targets table can
  /// flip this off for less visual noise.
  final bool campaignRollupSurfaceTargetsTab;
  /// How the campaign rollup groups runs for a given target:
  ///   * `by_target_name` — case-insensitive name match (default; works
  ///     across sequences that re-name the same object).
  ///   * `by_target_id` — exact Drift `targets.id` match (stricter).
  ///   * `by_user_tag` — group by the `targets.tags` field when present.
  final String campaignRollupGroupingMode;
  /// When true, new [TargetSchedulerNode]s are created with
  /// [TargetSchedulerNode.swapOnConditionsBelow] set to
  /// [adaptiveSwapDefaultThreshold]. When false, new schedulers ship
  /// with adaptive swap *disabled* (`swapOnConditionsBelow = null`) so
  /// the user has to opt in explicitly.
  final bool adaptiveSwapEnabledByDefault;
  /// Default conditions-score floor (0..=100) seeded into a new
  /// scheduler's `swapOnConditionsBelow`. Only consulted when
  /// [adaptiveSwapEnabledByDefault] is true.
  final double adaptiveSwapDefaultThreshold;
  /// Default `swapHysteresisSecs` (seconds between consecutive swaps)
  /// seeded into a new scheduler.
  final double adaptiveSwapDefaultHysteresisSecs;
  /// Per-axis composer weights for the live ConditionsScore. Keys:
  /// `transparency` / `seeing` / `cloud` / `wind`. Stored as a JSON object.
  final Map<String, double> conditionsScoreWeights;

  const AppSettingsState({
    this.startMinimized = false,
    this.autoConnectEquipment = true,
    this.confirmBeforeClosing = true,
    this.autoDiscoverOnLaunch = true,
    this.theme = 'dark',
    this.language = 'en',
    this.accentColor = '#E86A6A',
    this.fontSize = 'Medium',
    this.uiScale = 'Auto',
    this.sidebarCollapsed = true,
    this.latitude = 0.0,
    this.longitude = 0.0,
    this.elevation = 0.0,
    this.timezone = 'UTC',
    this.useSystemTime = true,
    this.imageFormat = 'FITS',
    this.xisfCompression = 'none',
    this.xisfChecksums = false,
    this.fileNamingPattern = '\$TARGET_\$FILTER_\$DATE_\$SEQ',
    this.bitDepth = '16-bit',
    this.parkOnUnsafeWeather = true,
    this.parkBeforeDawn = true,
    this.stopRunOnQualityProblems = false,
    this.mountGuardAutoSyncResume = false,
    this.meridianFlipMinutes = 5,
    this.autoFocusOnFilterChange = false,
    this.useFilterFocusOffsets = true,
    this.autoFocusEveryMinutes = 60,
    this.ditherEnabled = true,
    this.ditherEveryFrames = 3,
    this.cameraRetries = 3,
    this.filterWheelRetries = 3,
    this.safetyFailMode = SafetyFailMode.failClosed,
    this.sequencerToolboxCollapsed,
    this.sequencerPropertiesCollapsed,
    this.sequencerSnippetPaletteVisible,
    this.sequencerToolboxTab,
    this.sequencerActiveTab,
    this.sequencerLeftPanelWidth,
    this.sequencerRightPanelWidth,
    this.plateSolver = 'ASTAP',
    this.astapPath = '',
    this.astrometryPath = '',
    this.plateSolveTimeout = 60,
    this.plateSolveSearchRadius = 30.0,
    this.blindSolve = false,
    this.centeringSyncMount = true,
    this.phd2Path = '',
    this.phd2Host = 'localhost',
    this.phd2Port = 4400,
    this.notificationsEnabled = true,
    this.discordWebhook = '',
    this.pushoverKey = '',
    this.pushoverUser = '',
    this.notifyOnSequenceComplete = true,
    this.notifyOnError = true,
    this.notifyOnMeridianFlip = false,
    this.soundEnabled = true,
    this.imageOutputPath = '',
    this.sequencesPath = '',
    this.databasePath = '',
    this.logsPath = '',
    this.indiServerHost = 'localhost',
    this.indiServerPort = 7624,
    this.indiAutoConnect = false,
    this.alpacaServerHost = 'localhost',
    this.alpacaServerPort = 11111,
    this.alpacaAutoDiscover = false,
    this.qhyDiscoveryEnabled = true,
    this.catalogBaseUrl = '',
    this.webServerEnabled = false,
    this.webServerPort = 8080,
    this.defaultGain = 100,
    this.defaultOffset = 50,
    this.enableMeridianFlip = true,
    this.tempCompensation = false,
    this.tempCoefficient = -12.0,
    this.tempCompensationMinSteps = 5,
    this.flatCalibrationAttempts = 20,
    this.backlashCompensation = 0,
    this.ditherScale = 'Medium',
    this.settleThreshold = 1.5,
    this.settleTimeout = 60,
    this.settleTime = 10,
    this.ditherRaOnly = false,
    this.bortleClass = 5,
    this.horizonProfileJson = '{"N":0,"NE":0,"E":0,"SE":0,"S":0,"SW":0,"W":0,"NW":0}',
    this.effectiveHorizonDeg = 0.0,
    this.audibleAlertsOnCritical = false,
    this.criticalAlertSound = 'systemBell',
    this.pushCriticalAlerts = true,
    this.recoveryDefaultRetryIntervalMins = 10.0,
    this.recoveryDefaultMaxDurationMins = 90.0,
    this.recoveryStopTrackingDuringRecovery = false,
    this.recoveryAbortOnMeridian = true,
    this.recoveryAudibleAlertWhenEntered = true,
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
    this.conditionsScoreWeights = const {'transparency': 0.4, 'seeing': 0.25, 'cloud': 0.25, 'wind': 0.1},
  });

  /// A copy with the given fields replaced. A nullable field is
  /// cleared by passing null and kept by leaving it out.
  AppSettingsState copyWith({
    bool? startMinimized,
    bool? autoConnectEquipment,
    bool? confirmBeforeClosing,
    bool? autoDiscoverOnLaunch,
    String? theme,
    String? language,
    String? accentColor,
    String? fontSize,
    String? uiScale,
    bool? sidebarCollapsed,
    double? latitude,
    double? longitude,
    double? elevation,
    String? timezone,
    bool? useSystemTime,
    String? imageFormat,
    String? xisfCompression,
    bool? xisfChecksums,
    String? fileNamingPattern,
    String? bitDepth,
    bool? parkOnUnsafeWeather,
    bool? parkBeforeDawn,
    bool? stopRunOnQualityProblems,
    bool? mountGuardAutoSyncResume,
    int? meridianFlipMinutes,
    bool? autoFocusOnFilterChange,
    bool? useFilterFocusOffsets,
    int? autoFocusEveryMinutes,
    bool? ditherEnabled,
    int? ditherEveryFrames,
    int? cameraRetries,
    int? filterWheelRetries,
    SafetyFailMode? safetyFailMode,
    Object? sequencerToolboxCollapsed = _unset,
    Object? sequencerPropertiesCollapsed = _unset,
    Object? sequencerSnippetPaletteVisible = _unset,
    Object? sequencerToolboxTab = _unset,
    Object? sequencerActiveTab = _unset,
    Object? sequencerLeftPanelWidth = _unset,
    Object? sequencerRightPanelWidth = _unset,
    String? plateSolver,
    String? astapPath,
    String? astrometryPath,
    int? plateSolveTimeout,
    double? plateSolveSearchRadius,
    bool? blindSolve,
    bool? centeringSyncMount,
    String? phd2Path,
    String? phd2Host,
    int? phd2Port,
    bool? notificationsEnabled,
    String? discordWebhook,
    String? pushoverKey,
    String? pushoverUser,
    bool? notifyOnSequenceComplete,
    bool? notifyOnError,
    bool? notifyOnMeridianFlip,
    bool? soundEnabled,
    String? imageOutputPath,
    String? sequencesPath,
    String? databasePath,
    String? logsPath,
    String? indiServerHost,
    int? indiServerPort,
    bool? indiAutoConnect,
    String? alpacaServerHost,
    int? alpacaServerPort,
    bool? alpacaAutoDiscover,
    bool? qhyDiscoveryEnabled,
    String? catalogBaseUrl,
    bool? webServerEnabled,
    int? webServerPort,
    int? defaultGain,
    int? defaultOffset,
    bool? enableMeridianFlip,
    bool? tempCompensation,
    double? tempCoefficient,
    int? tempCompensationMinSteps,
    int? flatCalibrationAttempts,
    int? backlashCompensation,
    String? ditherScale,
    double? settleThreshold,
    int? settleTimeout,
    int? settleTime,
    bool? ditherRaOnly,
    int? bortleClass,
    String? horizonProfileJson,
    double? effectiveHorizonDeg,
    bool? audibleAlertsOnCritical,
    String? criticalAlertSound,
    bool? pushCriticalAlerts,
    double? recoveryDefaultRetryIntervalMins,
    double? recoveryDefaultMaxDurationMins,
    bool? recoveryStopTrackingDuringRecovery,
    bool? recoveryAbortOnMeridian,
    bool? recoveryAudibleAlertWhenEntered,
    String? afMethod,
    String? afCurveFitting,
    int? afStepSize,
    double? afExposureTime,
    int? afInitialOffsetSteps,
    int? afNumberOfAttempts,
    int? afUseBrightestNStars,
    double? afOuterCropRatio,
    double? afInnerCropRatio,
    int? afBinning,
    double? afRSquaredThreshold,
    double? afFailureHfrToleranceRatio,
    bool? afDisableGuidingDuringAf,
    int? afFocuserSettleTimeMs,
    int? afExposuresPerPoint,
    String? afBacklashCompMethod,
    int? afBacklashIn,
    String? focuserBacklashOfferMode,
    String? focuserBacklashCalibrationJson,
    String? mountSiteSyncMode,
    int? afBacklashOut,
    String? afAutofocusFilterName,
    String? afFilterSettingsJson,
    String? observerName,
    bool? enableImageGrading,
    Object? imageGradingHfrThresholdPx = _unset,
    Object? imageGradingHfrBaselinePercent = _unset,
    Object? imageGradingEccentricityThreshold = _unset,
    Object? imageGradingStarCountMin = _unset,
    int? imageGradingMaxConsecutiveRejects,
    Object? imageGradingRejectFolderPath = _unset,
    bool? adaptiveExposureEnabled,
    double? adaptiveExposureTargetSnr,
    double? adaptiveExposureReferenceMag,
    double? adaptiveExposureMinSecs,
    double? adaptiveExposureMaxSecs,
    Map<String, bool>? adaptiveExposurePerFilterEnabled,
    Map<String, double>? adaptiveExposurePerFilterMinSecs,
    Map<String, double>? adaptiveExposurePerFilterMaxSecs,
    PreflightStrictness? preflightStrictness,
    int? polarAlignmentMaxAgeDays,
    int? darkLibraryMinCoverage,
    double? opticalTrainDriftThreshold,
    Object? smartNightMaxSessionHours = _unset,
    int? smartNightDefaultAfCadenceFrames,
    int? smartNightDefaultIntegrationBudgetMinsPerTarget,
    bool? smartNightIncludeFlatsAtEnd,
    bool? smartNightUseSchedulerForMultiTarget,
    int? smartNightSchedulerTargetThreshold,
    String? smartNightDefaultStrategy,
    int? smartNightPolarAlignmentStaleAfterDays,
    double? smartNightSubExposureFloorSecs,
    double? smartNightSubExposureCeilingSecs,
    double? smartNightTargetSnr,
    bool? smartNightAutoSelect,
    int? smartNightAutoSelectCount,
    String? smartNightPromptDismissedDayKey,
    bool? promptForNotesAfterRun,
    bool? sessionHandoffAutoPrompt,
    bool? campaignRollupSurfaceTargetsTab,
    String? campaignRollupGroupingMode,
    bool? adaptiveSwapEnabledByDefault,
    double? adaptiveSwapDefaultThreshold,
    double? adaptiveSwapDefaultHysteresisSecs,
    Map<String, double>? conditionsScoreWeights,
  }) {
    return AppSettingsState(
      startMinimized: startMinimized ?? this.startMinimized,
      autoConnectEquipment: autoConnectEquipment ?? this.autoConnectEquipment,
      confirmBeforeClosing: confirmBeforeClosing ?? this.confirmBeforeClosing,
      autoDiscoverOnLaunch: autoDiscoverOnLaunch ?? this.autoDiscoverOnLaunch,
      theme: theme ?? this.theme,
      language: language ?? this.language,
      accentColor: accentColor ?? this.accentColor,
      fontSize: fontSize ?? this.fontSize,
      uiScale: uiScale ?? this.uiScale,
      sidebarCollapsed: sidebarCollapsed ?? this.sidebarCollapsed,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      elevation: elevation ?? this.elevation,
      timezone: timezone ?? this.timezone,
      useSystemTime: useSystemTime ?? this.useSystemTime,
      imageFormat: imageFormat ?? this.imageFormat,
      xisfCompression: xisfCompression ?? this.xisfCompression,
      xisfChecksums: xisfChecksums ?? this.xisfChecksums,
      fileNamingPattern: fileNamingPattern ?? this.fileNamingPattern,
      bitDepth: bitDepth ?? this.bitDepth,
      parkOnUnsafeWeather: parkOnUnsafeWeather ?? this.parkOnUnsafeWeather,
      parkBeforeDawn: parkBeforeDawn ?? this.parkBeforeDawn,
      stopRunOnQualityProblems: stopRunOnQualityProblems ?? this.stopRunOnQualityProblems,
      mountGuardAutoSyncResume: mountGuardAutoSyncResume ?? this.mountGuardAutoSyncResume,
      meridianFlipMinutes: meridianFlipMinutes ?? this.meridianFlipMinutes,
      autoFocusOnFilterChange: autoFocusOnFilterChange ?? this.autoFocusOnFilterChange,
      useFilterFocusOffsets: useFilterFocusOffsets ?? this.useFilterFocusOffsets,
      autoFocusEveryMinutes: autoFocusEveryMinutes ?? this.autoFocusEveryMinutes,
      ditherEnabled: ditherEnabled ?? this.ditherEnabled,
      ditherEveryFrames: ditherEveryFrames ?? this.ditherEveryFrames,
      cameraRetries: cameraRetries ?? this.cameraRetries,
      filterWheelRetries: filterWheelRetries ?? this.filterWheelRetries,
      safetyFailMode: safetyFailMode ?? this.safetyFailMode,
      sequencerToolboxCollapsed: identical(sequencerToolboxCollapsed, _unset) ? this.sequencerToolboxCollapsed : sequencerToolboxCollapsed as bool?,
      sequencerPropertiesCollapsed: identical(sequencerPropertiesCollapsed, _unset) ? this.sequencerPropertiesCollapsed : sequencerPropertiesCollapsed as bool?,
      sequencerSnippetPaletteVisible: identical(sequencerSnippetPaletteVisible, _unset) ? this.sequencerSnippetPaletteVisible : sequencerSnippetPaletteVisible as bool?,
      sequencerToolboxTab: identical(sequencerToolboxTab, _unset) ? this.sequencerToolboxTab : sequencerToolboxTab as String?,
      sequencerActiveTab: identical(sequencerActiveTab, _unset) ? this.sequencerActiveTab : sequencerActiveTab as int?,
      sequencerLeftPanelWidth: identical(sequencerLeftPanelWidth, _unset) ? this.sequencerLeftPanelWidth : sequencerLeftPanelWidth as double?,
      sequencerRightPanelWidth: identical(sequencerRightPanelWidth, _unset) ? this.sequencerRightPanelWidth : sequencerRightPanelWidth as double?,
      plateSolver: plateSolver ?? this.plateSolver,
      astapPath: astapPath ?? this.astapPath,
      astrometryPath: astrometryPath ?? this.astrometryPath,
      plateSolveTimeout: plateSolveTimeout ?? this.plateSolveTimeout,
      plateSolveSearchRadius: plateSolveSearchRadius ?? this.plateSolveSearchRadius,
      blindSolve: blindSolve ?? this.blindSolve,
      centeringSyncMount: centeringSyncMount ?? this.centeringSyncMount,
      phd2Path: phd2Path ?? this.phd2Path,
      phd2Host: phd2Host ?? this.phd2Host,
      phd2Port: phd2Port ?? this.phd2Port,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      discordWebhook: discordWebhook ?? this.discordWebhook,
      pushoverKey: pushoverKey ?? this.pushoverKey,
      pushoverUser: pushoverUser ?? this.pushoverUser,
      notifyOnSequenceComplete: notifyOnSequenceComplete ?? this.notifyOnSequenceComplete,
      notifyOnError: notifyOnError ?? this.notifyOnError,
      notifyOnMeridianFlip: notifyOnMeridianFlip ?? this.notifyOnMeridianFlip,
      soundEnabled: soundEnabled ?? this.soundEnabled,
      imageOutputPath: imageOutputPath ?? this.imageOutputPath,
      sequencesPath: sequencesPath ?? this.sequencesPath,
      databasePath: databasePath ?? this.databasePath,
      logsPath: logsPath ?? this.logsPath,
      indiServerHost: indiServerHost ?? this.indiServerHost,
      indiServerPort: indiServerPort ?? this.indiServerPort,
      indiAutoConnect: indiAutoConnect ?? this.indiAutoConnect,
      alpacaServerHost: alpacaServerHost ?? this.alpacaServerHost,
      alpacaServerPort: alpacaServerPort ?? this.alpacaServerPort,
      alpacaAutoDiscover: alpacaAutoDiscover ?? this.alpacaAutoDiscover,
      qhyDiscoveryEnabled: qhyDiscoveryEnabled ?? this.qhyDiscoveryEnabled,
      catalogBaseUrl: catalogBaseUrl ?? this.catalogBaseUrl,
      webServerEnabled: webServerEnabled ?? this.webServerEnabled,
      webServerPort: webServerPort ?? this.webServerPort,
      defaultGain: defaultGain ?? this.defaultGain,
      defaultOffset: defaultOffset ?? this.defaultOffset,
      enableMeridianFlip: enableMeridianFlip ?? this.enableMeridianFlip,
      tempCompensation: tempCompensation ?? this.tempCompensation,
      tempCoefficient: tempCoefficient ?? this.tempCoefficient,
      tempCompensationMinSteps: tempCompensationMinSteps ?? this.tempCompensationMinSteps,
      flatCalibrationAttempts: flatCalibrationAttempts ?? this.flatCalibrationAttempts,
      backlashCompensation: backlashCompensation ?? this.backlashCompensation,
      ditherScale: ditherScale ?? this.ditherScale,
      settleThreshold: settleThreshold ?? this.settleThreshold,
      settleTimeout: settleTimeout ?? this.settleTimeout,
      settleTime: settleTime ?? this.settleTime,
      ditherRaOnly: ditherRaOnly ?? this.ditherRaOnly,
      bortleClass: bortleClass ?? this.bortleClass,
      horizonProfileJson: horizonProfileJson ?? this.horizonProfileJson,
      effectiveHorizonDeg: effectiveHorizonDeg ?? this.effectiveHorizonDeg,
      audibleAlertsOnCritical: audibleAlertsOnCritical ?? this.audibleAlertsOnCritical,
      criticalAlertSound: criticalAlertSound ?? this.criticalAlertSound,
      pushCriticalAlerts: pushCriticalAlerts ?? this.pushCriticalAlerts,
      recoveryDefaultRetryIntervalMins: recoveryDefaultRetryIntervalMins ?? this.recoveryDefaultRetryIntervalMins,
      recoveryDefaultMaxDurationMins: recoveryDefaultMaxDurationMins ?? this.recoveryDefaultMaxDurationMins,
      recoveryStopTrackingDuringRecovery: recoveryStopTrackingDuringRecovery ?? this.recoveryStopTrackingDuringRecovery,
      recoveryAbortOnMeridian: recoveryAbortOnMeridian ?? this.recoveryAbortOnMeridian,
      recoveryAudibleAlertWhenEntered: recoveryAudibleAlertWhenEntered ?? this.recoveryAudibleAlertWhenEntered,
      afMethod: afMethod ?? this.afMethod,
      afCurveFitting: afCurveFitting ?? this.afCurveFitting,
      afStepSize: afStepSize ?? this.afStepSize,
      afExposureTime: afExposureTime ?? this.afExposureTime,
      afInitialOffsetSteps: afInitialOffsetSteps ?? this.afInitialOffsetSteps,
      afNumberOfAttempts: afNumberOfAttempts ?? this.afNumberOfAttempts,
      afUseBrightestNStars: afUseBrightestNStars ?? this.afUseBrightestNStars,
      afOuterCropRatio: afOuterCropRatio ?? this.afOuterCropRatio,
      afInnerCropRatio: afInnerCropRatio ?? this.afInnerCropRatio,
      afBinning: afBinning ?? this.afBinning,
      afRSquaredThreshold: afRSquaredThreshold ?? this.afRSquaredThreshold,
      afFailureHfrToleranceRatio: afFailureHfrToleranceRatio ?? this.afFailureHfrToleranceRatio,
      afDisableGuidingDuringAf: afDisableGuidingDuringAf ?? this.afDisableGuidingDuringAf,
      afFocuserSettleTimeMs: afFocuserSettleTimeMs ?? this.afFocuserSettleTimeMs,
      afExposuresPerPoint: afExposuresPerPoint ?? this.afExposuresPerPoint,
      afBacklashCompMethod: afBacklashCompMethod ?? this.afBacklashCompMethod,
      afBacklashIn: afBacklashIn ?? this.afBacklashIn,
      focuserBacklashOfferMode: focuserBacklashOfferMode ?? this.focuserBacklashOfferMode,
      focuserBacklashCalibrationJson: focuserBacklashCalibrationJson ?? this.focuserBacklashCalibrationJson,
      mountSiteSyncMode: mountSiteSyncMode ?? this.mountSiteSyncMode,
      afBacklashOut: afBacklashOut ?? this.afBacklashOut,
      afAutofocusFilterName: afAutofocusFilterName ?? this.afAutofocusFilterName,
      afFilterSettingsJson: afFilterSettingsJson ?? this.afFilterSettingsJson,
      observerName: observerName ?? this.observerName,
      enableImageGrading: enableImageGrading ?? this.enableImageGrading,
      imageGradingHfrThresholdPx: identical(imageGradingHfrThresholdPx, _unset) ? this.imageGradingHfrThresholdPx : imageGradingHfrThresholdPx as double?,
      imageGradingHfrBaselinePercent: identical(imageGradingHfrBaselinePercent, _unset) ? this.imageGradingHfrBaselinePercent : imageGradingHfrBaselinePercent as double?,
      imageGradingEccentricityThreshold: identical(imageGradingEccentricityThreshold, _unset) ? this.imageGradingEccentricityThreshold : imageGradingEccentricityThreshold as double?,
      imageGradingStarCountMin: identical(imageGradingStarCountMin, _unset) ? this.imageGradingStarCountMin : imageGradingStarCountMin as int?,
      imageGradingMaxConsecutiveRejects: imageGradingMaxConsecutiveRejects ?? this.imageGradingMaxConsecutiveRejects,
      imageGradingRejectFolderPath: identical(imageGradingRejectFolderPath, _unset) ? this.imageGradingRejectFolderPath : imageGradingRejectFolderPath as String?,
      adaptiveExposureEnabled: adaptiveExposureEnabled ?? this.adaptiveExposureEnabled,
      adaptiveExposureTargetSnr: adaptiveExposureTargetSnr ?? this.adaptiveExposureTargetSnr,
      adaptiveExposureReferenceMag: adaptiveExposureReferenceMag ?? this.adaptiveExposureReferenceMag,
      adaptiveExposureMinSecs: adaptiveExposureMinSecs ?? this.adaptiveExposureMinSecs,
      adaptiveExposureMaxSecs: adaptiveExposureMaxSecs ?? this.adaptiveExposureMaxSecs,
      adaptiveExposurePerFilterEnabled: adaptiveExposurePerFilterEnabled ?? this.adaptiveExposurePerFilterEnabled,
      adaptiveExposurePerFilterMinSecs: adaptiveExposurePerFilterMinSecs ?? this.adaptiveExposurePerFilterMinSecs,
      adaptiveExposurePerFilterMaxSecs: adaptiveExposurePerFilterMaxSecs ?? this.adaptiveExposurePerFilterMaxSecs,
      preflightStrictness: preflightStrictness ?? this.preflightStrictness,
      polarAlignmentMaxAgeDays: polarAlignmentMaxAgeDays ?? this.polarAlignmentMaxAgeDays,
      darkLibraryMinCoverage: darkLibraryMinCoverage ?? this.darkLibraryMinCoverage,
      opticalTrainDriftThreshold: opticalTrainDriftThreshold ?? this.opticalTrainDriftThreshold,
      smartNightMaxSessionHours: identical(smartNightMaxSessionHours, _unset) ? this.smartNightMaxSessionHours : smartNightMaxSessionHours as double?,
      smartNightDefaultAfCadenceFrames: smartNightDefaultAfCadenceFrames ?? this.smartNightDefaultAfCadenceFrames,
      smartNightDefaultIntegrationBudgetMinsPerTarget: smartNightDefaultIntegrationBudgetMinsPerTarget ?? this.smartNightDefaultIntegrationBudgetMinsPerTarget,
      smartNightIncludeFlatsAtEnd: smartNightIncludeFlatsAtEnd ?? this.smartNightIncludeFlatsAtEnd,
      smartNightUseSchedulerForMultiTarget: smartNightUseSchedulerForMultiTarget ?? this.smartNightUseSchedulerForMultiTarget,
      smartNightSchedulerTargetThreshold: smartNightSchedulerTargetThreshold ?? this.smartNightSchedulerTargetThreshold,
      smartNightDefaultStrategy: smartNightDefaultStrategy ?? this.smartNightDefaultStrategy,
      smartNightPolarAlignmentStaleAfterDays: smartNightPolarAlignmentStaleAfterDays ?? this.smartNightPolarAlignmentStaleAfterDays,
      smartNightSubExposureFloorSecs: smartNightSubExposureFloorSecs ?? this.smartNightSubExposureFloorSecs,
      smartNightSubExposureCeilingSecs: smartNightSubExposureCeilingSecs ?? this.smartNightSubExposureCeilingSecs,
      smartNightTargetSnr: smartNightTargetSnr ?? this.smartNightTargetSnr,
      smartNightAutoSelect: smartNightAutoSelect ?? this.smartNightAutoSelect,
      smartNightAutoSelectCount: smartNightAutoSelectCount ?? this.smartNightAutoSelectCount,
      smartNightPromptDismissedDayKey: smartNightPromptDismissedDayKey ?? this.smartNightPromptDismissedDayKey,
      promptForNotesAfterRun: promptForNotesAfterRun ?? this.promptForNotesAfterRun,
      sessionHandoffAutoPrompt: sessionHandoffAutoPrompt ?? this.sessionHandoffAutoPrompt,
      campaignRollupSurfaceTargetsTab: campaignRollupSurfaceTargetsTab ?? this.campaignRollupSurfaceTargetsTab,
      campaignRollupGroupingMode: campaignRollupGroupingMode ?? this.campaignRollupGroupingMode,
      adaptiveSwapEnabledByDefault: adaptiveSwapEnabledByDefault ?? this.adaptiveSwapEnabledByDefault,
      adaptiveSwapDefaultThreshold: adaptiveSwapDefaultThreshold ?? this.adaptiveSwapDefaultThreshold,
      adaptiveSwapDefaultHysteresisSecs: adaptiveSwapDefaultHysteresisSecs ?? this.adaptiveSwapDefaultHysteresisSecs,
      conditionsScoreWeights: conditionsScoreWeights ?? this.conditionsScoreWeights,
    );
  }

  /// The value of [setting].
  T valueOf<T>(Setting<T> setting) => _read(setting.field) as T;

  Object? _read(String field) => switch (field) {
    'startMinimized' => startMinimized,
    'autoConnectEquipment' => autoConnectEquipment,
    'confirmBeforeClosing' => confirmBeforeClosing,
    'autoDiscoverOnLaunch' => autoDiscoverOnLaunch,
    'theme' => theme,
    'language' => language,
    'accentColor' => accentColor,
    'fontSize' => fontSize,
    'uiScale' => uiScale,
    'sidebarCollapsed' => sidebarCollapsed,
    'latitude' => latitude,
    'longitude' => longitude,
    'elevation' => elevation,
    'timezone' => timezone,
    'useSystemTime' => useSystemTime,
    'imageFormat' => imageFormat,
    'xisfCompression' => xisfCompression,
    'xisfChecksums' => xisfChecksums,
    'fileNamingPattern' => fileNamingPattern,
    'bitDepth' => bitDepth,
    'parkOnUnsafeWeather' => parkOnUnsafeWeather,
    'parkBeforeDawn' => parkBeforeDawn,
    'stopRunOnQualityProblems' => stopRunOnQualityProblems,
    'mountGuardAutoSyncResume' => mountGuardAutoSyncResume,
    'meridianFlipMinutes' => meridianFlipMinutes,
    'autoFocusOnFilterChange' => autoFocusOnFilterChange,
    'useFilterFocusOffsets' => useFilterFocusOffsets,
    'autoFocusEveryMinutes' => autoFocusEveryMinutes,
    'ditherEnabled' => ditherEnabled,
    'ditherEveryFrames' => ditherEveryFrames,
    'cameraRetries' => cameraRetries,
    'filterWheelRetries' => filterWheelRetries,
    'safetyFailMode' => safetyFailMode,
    'sequencerToolboxCollapsed' => sequencerToolboxCollapsed,
    'sequencerPropertiesCollapsed' => sequencerPropertiesCollapsed,
    'sequencerSnippetPaletteVisible' => sequencerSnippetPaletteVisible,
    'sequencerToolboxTab' => sequencerToolboxTab,
    'sequencerActiveTab' => sequencerActiveTab,
    'sequencerLeftPanelWidth' => sequencerLeftPanelWidth,
    'sequencerRightPanelWidth' => sequencerRightPanelWidth,
    'plateSolver' => plateSolver,
    'astapPath' => astapPath,
    'astrometryPath' => astrometryPath,
    'plateSolveTimeout' => plateSolveTimeout,
    'plateSolveSearchRadius' => plateSolveSearchRadius,
    'blindSolve' => blindSolve,
    'centeringSyncMount' => centeringSyncMount,
    'phd2Path' => phd2Path,
    'phd2Host' => phd2Host,
    'phd2Port' => phd2Port,
    'notificationsEnabled' => notificationsEnabled,
    'discordWebhook' => discordWebhook,
    'pushoverKey' => pushoverKey,
    'pushoverUser' => pushoverUser,
    'notifyOnSequenceComplete' => notifyOnSequenceComplete,
    'notifyOnError' => notifyOnError,
    'notifyOnMeridianFlip' => notifyOnMeridianFlip,
    'soundEnabled' => soundEnabled,
    'imageOutputPath' => imageOutputPath,
    'sequencesPath' => sequencesPath,
    'databasePath' => databasePath,
    'logsPath' => logsPath,
    'indiServerHost' => indiServerHost,
    'indiServerPort' => indiServerPort,
    'indiAutoConnect' => indiAutoConnect,
    'alpacaServerHost' => alpacaServerHost,
    'alpacaServerPort' => alpacaServerPort,
    'alpacaAutoDiscover' => alpacaAutoDiscover,
    'qhyDiscoveryEnabled' => qhyDiscoveryEnabled,
    'catalogBaseUrl' => catalogBaseUrl,
    'webServerEnabled' => webServerEnabled,
    'webServerPort' => webServerPort,
    'defaultGain' => defaultGain,
    'defaultOffset' => defaultOffset,
    'enableMeridianFlip' => enableMeridianFlip,
    'tempCompensation' => tempCompensation,
    'tempCoefficient' => tempCoefficient,
    'tempCompensationMinSteps' => tempCompensationMinSteps,
    'flatCalibrationAttempts' => flatCalibrationAttempts,
    'backlashCompensation' => backlashCompensation,
    'ditherScale' => ditherScale,
    'settleThreshold' => settleThreshold,
    'settleTimeout' => settleTimeout,
    'settleTime' => settleTime,
    'ditherRaOnly' => ditherRaOnly,
    'bortleClass' => bortleClass,
    'horizonProfileJson' => horizonProfileJson,
    'effectiveHorizonDeg' => effectiveHorizonDeg,
    'audibleAlertsOnCritical' => audibleAlertsOnCritical,
    'criticalAlertSound' => criticalAlertSound,
    'pushCriticalAlerts' => pushCriticalAlerts,
    'recoveryDefaultRetryIntervalMins' => recoveryDefaultRetryIntervalMins,
    'recoveryDefaultMaxDurationMins' => recoveryDefaultMaxDurationMins,
    'recoveryStopTrackingDuringRecovery' => recoveryStopTrackingDuringRecovery,
    'recoveryAbortOnMeridian' => recoveryAbortOnMeridian,
    'recoveryAudibleAlertWhenEntered' => recoveryAudibleAlertWhenEntered,
    'afMethod' => afMethod,
    'afCurveFitting' => afCurveFitting,
    'afStepSize' => afStepSize,
    'afExposureTime' => afExposureTime,
    'afInitialOffsetSteps' => afInitialOffsetSteps,
    'afNumberOfAttempts' => afNumberOfAttempts,
    'afUseBrightestNStars' => afUseBrightestNStars,
    'afOuterCropRatio' => afOuterCropRatio,
    'afInnerCropRatio' => afInnerCropRatio,
    'afBinning' => afBinning,
    'afRSquaredThreshold' => afRSquaredThreshold,
    'afFailureHfrToleranceRatio' => afFailureHfrToleranceRatio,
    'afDisableGuidingDuringAf' => afDisableGuidingDuringAf,
    'afFocuserSettleTimeMs' => afFocuserSettleTimeMs,
    'afExposuresPerPoint' => afExposuresPerPoint,
    'afBacklashCompMethod' => afBacklashCompMethod,
    'afBacklashIn' => afBacklashIn,
    'focuserBacklashOfferMode' => focuserBacklashOfferMode,
    'focuserBacklashCalibrationJson' => focuserBacklashCalibrationJson,
    'mountSiteSyncMode' => mountSiteSyncMode,
    'afBacklashOut' => afBacklashOut,
    'afAutofocusFilterName' => afAutofocusFilterName,
    'afFilterSettingsJson' => afFilterSettingsJson,
    'observerName' => observerName,
    'enableImageGrading' => enableImageGrading,
    'imageGradingHfrThresholdPx' => imageGradingHfrThresholdPx,
    'imageGradingHfrBaselinePercent' => imageGradingHfrBaselinePercent,
    'imageGradingEccentricityThreshold' => imageGradingEccentricityThreshold,
    'imageGradingStarCountMin' => imageGradingStarCountMin,
    'imageGradingMaxConsecutiveRejects' => imageGradingMaxConsecutiveRejects,
    'imageGradingRejectFolderPath' => imageGradingRejectFolderPath,
    'adaptiveExposureEnabled' => adaptiveExposureEnabled,
    'adaptiveExposureTargetSnr' => adaptiveExposureTargetSnr,
    'adaptiveExposureReferenceMag' => adaptiveExposureReferenceMag,
    'adaptiveExposureMinSecs' => adaptiveExposureMinSecs,
    'adaptiveExposureMaxSecs' => adaptiveExposureMaxSecs,
    'adaptiveExposurePerFilterEnabled' => adaptiveExposurePerFilterEnabled,
    'adaptiveExposurePerFilterMinSecs' => adaptiveExposurePerFilterMinSecs,
    'adaptiveExposurePerFilterMaxSecs' => adaptiveExposurePerFilterMaxSecs,
    'preflightStrictness' => preflightStrictness,
    'polarAlignmentMaxAgeDays' => polarAlignmentMaxAgeDays,
    'darkLibraryMinCoverage' => darkLibraryMinCoverage,
    'opticalTrainDriftThreshold' => opticalTrainDriftThreshold,
    'smartNightMaxSessionHours' => smartNightMaxSessionHours,
    'smartNightDefaultAfCadenceFrames' => smartNightDefaultAfCadenceFrames,
    'smartNightDefaultIntegrationBudgetMinsPerTarget' => smartNightDefaultIntegrationBudgetMinsPerTarget,
    'smartNightIncludeFlatsAtEnd' => smartNightIncludeFlatsAtEnd,
    'smartNightUseSchedulerForMultiTarget' => smartNightUseSchedulerForMultiTarget,
    'smartNightSchedulerTargetThreshold' => smartNightSchedulerTargetThreshold,
    'smartNightDefaultStrategy' => smartNightDefaultStrategy,
    'smartNightPolarAlignmentStaleAfterDays' => smartNightPolarAlignmentStaleAfterDays,
    'smartNightSubExposureFloorSecs' => smartNightSubExposureFloorSecs,
    'smartNightSubExposureCeilingSecs' => smartNightSubExposureCeilingSecs,
    'smartNightTargetSnr' => smartNightTargetSnr,
    'smartNightAutoSelect' => smartNightAutoSelect,
    'smartNightAutoSelectCount' => smartNightAutoSelectCount,
    'smartNightPromptDismissedDayKey' => smartNightPromptDismissedDayKey,
    'promptForNotesAfterRun' => promptForNotesAfterRun,
    'sessionHandoffAutoPrompt' => sessionHandoffAutoPrompt,
    'campaignRollupSurfaceTargetsTab' => campaignRollupSurfaceTargetsTab,
    'campaignRollupGroupingMode' => campaignRollupGroupingMode,
    'adaptiveSwapEnabledByDefault' => adaptiveSwapEnabledByDefault,
    'adaptiveSwapDefaultThreshold' => adaptiveSwapDefaultThreshold,
    'adaptiveSwapDefaultHysteresisSecs' => adaptiveSwapDefaultHysteresisSecs,
    'conditionsScoreWeights' => conditionsScoreWeights,
    _ => throw ArgumentError.value(field, 'field', 'not a setting'),
  };

  /// A copy with [setting] set to [value].
  AppSettingsState withValue<T>(Setting<T> setting, T value) =>
      switch (setting.field) {
        'startMinimized' => copyWith(startMinimized: value as bool),
        'autoConnectEquipment' => copyWith(autoConnectEquipment: value as bool),
        'confirmBeforeClosing' => copyWith(confirmBeforeClosing: value as bool),
        'autoDiscoverOnLaunch' => copyWith(autoDiscoverOnLaunch: value as bool),
        'theme' => copyWith(theme: value as String),
        'language' => copyWith(language: value as String),
        'accentColor' => copyWith(accentColor: value as String),
        'fontSize' => copyWith(fontSize: value as String),
        'uiScale' => copyWith(uiScale: value as String),
        'sidebarCollapsed' => copyWith(sidebarCollapsed: value as bool),
        'latitude' => copyWith(latitude: value as double),
        'longitude' => copyWith(longitude: value as double),
        'elevation' => copyWith(elevation: value as double),
        'timezone' => copyWith(timezone: value as String),
        'useSystemTime' => copyWith(useSystemTime: value as bool),
        'imageFormat' => copyWith(imageFormat: value as String),
        'xisfCompression' => copyWith(xisfCompression: value as String),
        'xisfChecksums' => copyWith(xisfChecksums: value as bool),
        'fileNamingPattern' => copyWith(fileNamingPattern: value as String),
        'bitDepth' => copyWith(bitDepth: value as String),
        'parkOnUnsafeWeather' => copyWith(parkOnUnsafeWeather: value as bool),
        'parkBeforeDawn' => copyWith(parkBeforeDawn: value as bool),
        'stopRunOnQualityProblems' => copyWith(stopRunOnQualityProblems: value as bool),
        'mountGuardAutoSyncResume' => copyWith(mountGuardAutoSyncResume: value as bool),
        'meridianFlipMinutes' => copyWith(meridianFlipMinutes: value as int),
        'autoFocusOnFilterChange' => copyWith(autoFocusOnFilterChange: value as bool),
        'useFilterFocusOffsets' => copyWith(useFilterFocusOffsets: value as bool),
        'autoFocusEveryMinutes' => copyWith(autoFocusEveryMinutes: value as int),
        'ditherEnabled' => copyWith(ditherEnabled: value as bool),
        'ditherEveryFrames' => copyWith(ditherEveryFrames: value as int),
        'cameraRetries' => copyWith(cameraRetries: value as int),
        'filterWheelRetries' => copyWith(filterWheelRetries: value as int),
        'safetyFailMode' => copyWith(safetyFailMode: value as SafetyFailMode),
        'sequencerToolboxCollapsed' => copyWith(sequencerToolboxCollapsed: value as bool?),
        'sequencerPropertiesCollapsed' => copyWith(sequencerPropertiesCollapsed: value as bool?),
        'sequencerSnippetPaletteVisible' => copyWith(sequencerSnippetPaletteVisible: value as bool?),
        'sequencerToolboxTab' => copyWith(sequencerToolboxTab: value as String?),
        'sequencerActiveTab' => copyWith(sequencerActiveTab: value as int?),
        'sequencerLeftPanelWidth' => copyWith(sequencerLeftPanelWidth: value as double?),
        'sequencerRightPanelWidth' => copyWith(sequencerRightPanelWidth: value as double?),
        'plateSolver' => copyWith(plateSolver: value as String),
        'astapPath' => copyWith(astapPath: value as String),
        'astrometryPath' => copyWith(astrometryPath: value as String),
        'plateSolveTimeout' => copyWith(plateSolveTimeout: value as int),
        'plateSolveSearchRadius' => copyWith(plateSolveSearchRadius: value as double),
        'blindSolve' => copyWith(blindSolve: value as bool),
        'centeringSyncMount' => copyWith(centeringSyncMount: value as bool),
        'phd2Path' => copyWith(phd2Path: value as String),
        'phd2Host' => copyWith(phd2Host: value as String),
        'phd2Port' => copyWith(phd2Port: value as int),
        'notificationsEnabled' => copyWith(notificationsEnabled: value as bool),
        'discordWebhook' => copyWith(discordWebhook: value as String),
        'pushoverKey' => copyWith(pushoverKey: value as String),
        'pushoverUser' => copyWith(pushoverUser: value as String),
        'notifyOnSequenceComplete' => copyWith(notifyOnSequenceComplete: value as bool),
        'notifyOnError' => copyWith(notifyOnError: value as bool),
        'notifyOnMeridianFlip' => copyWith(notifyOnMeridianFlip: value as bool),
        'soundEnabled' => copyWith(soundEnabled: value as bool),
        'imageOutputPath' => copyWith(imageOutputPath: value as String),
        'sequencesPath' => copyWith(sequencesPath: value as String),
        'databasePath' => copyWith(databasePath: value as String),
        'logsPath' => copyWith(logsPath: value as String),
        'indiServerHost' => copyWith(indiServerHost: value as String),
        'indiServerPort' => copyWith(indiServerPort: value as int),
        'indiAutoConnect' => copyWith(indiAutoConnect: value as bool),
        'alpacaServerHost' => copyWith(alpacaServerHost: value as String),
        'alpacaServerPort' => copyWith(alpacaServerPort: value as int),
        'alpacaAutoDiscover' => copyWith(alpacaAutoDiscover: value as bool),
        'qhyDiscoveryEnabled' => copyWith(qhyDiscoveryEnabled: value as bool),
        'catalogBaseUrl' => copyWith(catalogBaseUrl: value as String),
        'webServerEnabled' => copyWith(webServerEnabled: value as bool),
        'webServerPort' => copyWith(webServerPort: value as int),
        'defaultGain' => copyWith(defaultGain: value as int),
        'defaultOffset' => copyWith(defaultOffset: value as int),
        'enableMeridianFlip' => copyWith(enableMeridianFlip: value as bool),
        'tempCompensation' => copyWith(tempCompensation: value as bool),
        'tempCoefficient' => copyWith(tempCoefficient: value as double),
        'tempCompensationMinSteps' => copyWith(tempCompensationMinSteps: value as int),
        'flatCalibrationAttempts' => copyWith(flatCalibrationAttempts: value as int),
        'backlashCompensation' => copyWith(backlashCompensation: value as int),
        'ditherScale' => copyWith(ditherScale: value as String),
        'settleThreshold' => copyWith(settleThreshold: value as double),
        'settleTimeout' => copyWith(settleTimeout: value as int),
        'settleTime' => copyWith(settleTime: value as int),
        'ditherRaOnly' => copyWith(ditherRaOnly: value as bool),
        'bortleClass' => copyWith(bortleClass: value as int),
        'horizonProfileJson' => copyWith(horizonProfileJson: value as String),
        'effectiveHorizonDeg' => copyWith(effectiveHorizonDeg: value as double),
        'audibleAlertsOnCritical' => copyWith(audibleAlertsOnCritical: value as bool),
        'criticalAlertSound' => copyWith(criticalAlertSound: value as String),
        'pushCriticalAlerts' => copyWith(pushCriticalAlerts: value as bool),
        'recoveryDefaultRetryIntervalMins' => copyWith(recoveryDefaultRetryIntervalMins: value as double),
        'recoveryDefaultMaxDurationMins' => copyWith(recoveryDefaultMaxDurationMins: value as double),
        'recoveryStopTrackingDuringRecovery' => copyWith(recoveryStopTrackingDuringRecovery: value as bool),
        'recoveryAbortOnMeridian' => copyWith(recoveryAbortOnMeridian: value as bool),
        'recoveryAudibleAlertWhenEntered' => copyWith(recoveryAudibleAlertWhenEntered: value as bool),
        'afMethod' => copyWith(afMethod: value as String),
        'afCurveFitting' => copyWith(afCurveFitting: value as String),
        'afStepSize' => copyWith(afStepSize: value as int),
        'afExposureTime' => copyWith(afExposureTime: value as double),
        'afInitialOffsetSteps' => copyWith(afInitialOffsetSteps: value as int),
        'afNumberOfAttempts' => copyWith(afNumberOfAttempts: value as int),
        'afUseBrightestNStars' => copyWith(afUseBrightestNStars: value as int),
        'afOuterCropRatio' => copyWith(afOuterCropRatio: value as double),
        'afInnerCropRatio' => copyWith(afInnerCropRatio: value as double),
        'afBinning' => copyWith(afBinning: value as int),
        'afRSquaredThreshold' => copyWith(afRSquaredThreshold: value as double),
        'afFailureHfrToleranceRatio' => copyWith(afFailureHfrToleranceRatio: value as double),
        'afDisableGuidingDuringAf' => copyWith(afDisableGuidingDuringAf: value as bool),
        'afFocuserSettleTimeMs' => copyWith(afFocuserSettleTimeMs: value as int),
        'afExposuresPerPoint' => copyWith(afExposuresPerPoint: value as int),
        'afBacklashCompMethod' => copyWith(afBacklashCompMethod: value as String),
        'afBacklashIn' => copyWith(afBacklashIn: value as int),
        'focuserBacklashOfferMode' => copyWith(focuserBacklashOfferMode: value as String),
        'focuserBacklashCalibrationJson' => copyWith(focuserBacklashCalibrationJson: value as String),
        'mountSiteSyncMode' => copyWith(mountSiteSyncMode: value as String),
        'afBacklashOut' => copyWith(afBacklashOut: value as int),
        'afAutofocusFilterName' => copyWith(afAutofocusFilterName: value as String),
        'afFilterSettingsJson' => copyWith(afFilterSettingsJson: value as String),
        'observerName' => copyWith(observerName: value as String),
        'enableImageGrading' => copyWith(enableImageGrading: value as bool),
        'imageGradingHfrThresholdPx' => copyWith(imageGradingHfrThresholdPx: value as double?),
        'imageGradingHfrBaselinePercent' => copyWith(imageGradingHfrBaselinePercent: value as double?),
        'imageGradingEccentricityThreshold' => copyWith(imageGradingEccentricityThreshold: value as double?),
        'imageGradingStarCountMin' => copyWith(imageGradingStarCountMin: value as int?),
        'imageGradingMaxConsecutiveRejects' => copyWith(imageGradingMaxConsecutiveRejects: value as int),
        'imageGradingRejectFolderPath' => copyWith(imageGradingRejectFolderPath: value as String?),
        'adaptiveExposureEnabled' => copyWith(adaptiveExposureEnabled: value as bool),
        'adaptiveExposureTargetSnr' => copyWith(adaptiveExposureTargetSnr: value as double),
        'adaptiveExposureReferenceMag' => copyWith(adaptiveExposureReferenceMag: value as double),
        'adaptiveExposureMinSecs' => copyWith(adaptiveExposureMinSecs: value as double),
        'adaptiveExposureMaxSecs' => copyWith(adaptiveExposureMaxSecs: value as double),
        'adaptiveExposurePerFilterEnabled' => copyWith(adaptiveExposurePerFilterEnabled: value as Map<String, bool>),
        'adaptiveExposurePerFilterMinSecs' => copyWith(adaptiveExposurePerFilterMinSecs: value as Map<String, double>),
        'adaptiveExposurePerFilterMaxSecs' => copyWith(adaptiveExposurePerFilterMaxSecs: value as Map<String, double>),
        'preflightStrictness' => copyWith(preflightStrictness: value as PreflightStrictness),
        'polarAlignmentMaxAgeDays' => copyWith(polarAlignmentMaxAgeDays: value as int),
        'darkLibraryMinCoverage' => copyWith(darkLibraryMinCoverage: value as int),
        'opticalTrainDriftThreshold' => copyWith(opticalTrainDriftThreshold: value as double),
        'smartNightMaxSessionHours' => copyWith(smartNightMaxSessionHours: value as double?),
        'smartNightDefaultAfCadenceFrames' => copyWith(smartNightDefaultAfCadenceFrames: value as int),
        'smartNightDefaultIntegrationBudgetMinsPerTarget' => copyWith(smartNightDefaultIntegrationBudgetMinsPerTarget: value as int),
        'smartNightIncludeFlatsAtEnd' => copyWith(smartNightIncludeFlatsAtEnd: value as bool),
        'smartNightUseSchedulerForMultiTarget' => copyWith(smartNightUseSchedulerForMultiTarget: value as bool),
        'smartNightSchedulerTargetThreshold' => copyWith(smartNightSchedulerTargetThreshold: value as int),
        'smartNightDefaultStrategy' => copyWith(smartNightDefaultStrategy: value as String),
        'smartNightPolarAlignmentStaleAfterDays' => copyWith(smartNightPolarAlignmentStaleAfterDays: value as int),
        'smartNightSubExposureFloorSecs' => copyWith(smartNightSubExposureFloorSecs: value as double),
        'smartNightSubExposureCeilingSecs' => copyWith(smartNightSubExposureCeilingSecs: value as double),
        'smartNightTargetSnr' => copyWith(smartNightTargetSnr: value as double),
        'smartNightAutoSelect' => copyWith(smartNightAutoSelect: value as bool),
        'smartNightAutoSelectCount' => copyWith(smartNightAutoSelectCount: value as int),
        'smartNightPromptDismissedDayKey' => copyWith(smartNightPromptDismissedDayKey: value as String),
        'promptForNotesAfterRun' => copyWith(promptForNotesAfterRun: value as bool),
        'sessionHandoffAutoPrompt' => copyWith(sessionHandoffAutoPrompt: value as bool),
        'campaignRollupSurfaceTargetsTab' => copyWith(campaignRollupSurfaceTargetsTab: value as bool),
        'campaignRollupGroupingMode' => copyWith(campaignRollupGroupingMode: value as String),
        'adaptiveSwapEnabledByDefault' => copyWith(adaptiveSwapEnabledByDefault: value as bool),
        'adaptiveSwapDefaultThreshold' => copyWith(adaptiveSwapDefaultThreshold: value as double),
        'adaptiveSwapDefaultHysteresisSecs' => copyWith(adaptiveSwapDefaultHysteresisSecs: value as double),
        'conditionsScoreWeights' => copyWith(conditionsScoreWeights: value as Map<String, double>),
        _ => throw ArgumentError.value(setting.field, 'setting'),
      };

  /// A state built by asking [valueOf] for every setting.
  static AppSettingsState fromValues(
    Object? Function(Setting<Object?> setting) valueOf,
  ) {
    const t = kAppSettingsTable;
    return AppSettingsState(
      startMinimized: valueOf(t[0]) as bool,
      autoConnectEquipment: valueOf(t[1]) as bool,
      confirmBeforeClosing: valueOf(t[2]) as bool,
      autoDiscoverOnLaunch: valueOf(t[3]) as bool,
      theme: valueOf(t[4]) as String,
      language: valueOf(t[5]) as String,
      accentColor: valueOf(t[6]) as String,
      fontSize: valueOf(t[7]) as String,
      uiScale: valueOf(t[8]) as String,
      sidebarCollapsed: valueOf(t[9]) as bool,
      latitude: valueOf(t[10]) as double,
      longitude: valueOf(t[11]) as double,
      elevation: valueOf(t[12]) as double,
      timezone: valueOf(t[13]) as String,
      useSystemTime: valueOf(t[14]) as bool,
      imageFormat: valueOf(t[15]) as String,
      xisfCompression: valueOf(t[16]) as String,
      xisfChecksums: valueOf(t[17]) as bool,
      fileNamingPattern: valueOf(t[18]) as String,
      bitDepth: valueOf(t[19]) as String,
      parkOnUnsafeWeather: valueOf(t[20]) as bool,
      parkBeforeDawn: valueOf(t[21]) as bool,
      stopRunOnQualityProblems: valueOf(t[22]) as bool,
      mountGuardAutoSyncResume: valueOf(t[23]) as bool,
      meridianFlipMinutes: valueOf(t[24]) as int,
      autoFocusOnFilterChange: valueOf(t[25]) as bool,
      useFilterFocusOffsets: valueOf(t[26]) as bool,
      autoFocusEveryMinutes: valueOf(t[27]) as int,
      ditherEnabled: valueOf(t[28]) as bool,
      ditherEveryFrames: valueOf(t[29]) as int,
      cameraRetries: valueOf(t[30]) as int,
      filterWheelRetries: valueOf(t[31]) as int,
      safetyFailMode: valueOf(t[32]) as SafetyFailMode,
      sequencerToolboxCollapsed: valueOf(t[33]) as bool?,
      sequencerPropertiesCollapsed: valueOf(t[34]) as bool?,
      sequencerSnippetPaletteVisible: valueOf(t[35]) as bool?,
      sequencerToolboxTab: valueOf(t[36]) as String?,
      sequencerActiveTab: valueOf(t[37]) as int?,
      sequencerLeftPanelWidth: valueOf(t[38]) as double?,
      sequencerRightPanelWidth: valueOf(t[39]) as double?,
      plateSolver: valueOf(t[40]) as String,
      astapPath: valueOf(t[41]) as String,
      astrometryPath: valueOf(t[42]) as String,
      plateSolveTimeout: valueOf(t[43]) as int,
      plateSolveSearchRadius: valueOf(t[44]) as double,
      blindSolve: valueOf(t[45]) as bool,
      centeringSyncMount: valueOf(t[46]) as bool,
      phd2Path: valueOf(t[47]) as String,
      phd2Host: valueOf(t[48]) as String,
      phd2Port: valueOf(t[49]) as int,
      notificationsEnabled: valueOf(t[50]) as bool,
      discordWebhook: valueOf(t[51]) as String,
      pushoverKey: valueOf(t[52]) as String,
      pushoverUser: valueOf(t[53]) as String,
      notifyOnSequenceComplete: valueOf(t[54]) as bool,
      notifyOnError: valueOf(t[55]) as bool,
      notifyOnMeridianFlip: valueOf(t[56]) as bool,
      soundEnabled: valueOf(t[57]) as bool,
      imageOutputPath: valueOf(t[58]) as String,
      sequencesPath: valueOf(t[59]) as String,
      databasePath: valueOf(t[60]) as String,
      logsPath: valueOf(t[61]) as String,
      indiServerHost: valueOf(t[62]) as String,
      indiServerPort: valueOf(t[63]) as int,
      indiAutoConnect: valueOf(t[64]) as bool,
      alpacaServerHost: valueOf(t[65]) as String,
      alpacaServerPort: valueOf(t[66]) as int,
      alpacaAutoDiscover: valueOf(t[67]) as bool,
      qhyDiscoveryEnabled: valueOf(t[68]) as bool,
      catalogBaseUrl: valueOf(t[69]) as String,
      webServerEnabled: valueOf(t[70]) as bool,
      webServerPort: valueOf(t[71]) as int,
      defaultGain: valueOf(t[72]) as int,
      defaultOffset: valueOf(t[73]) as int,
      enableMeridianFlip: valueOf(t[74]) as bool,
      tempCompensation: valueOf(t[75]) as bool,
      tempCoefficient: valueOf(t[76]) as double,
      tempCompensationMinSteps: valueOf(t[77]) as int,
      flatCalibrationAttempts: valueOf(t[78]) as int,
      backlashCompensation: valueOf(t[79]) as int,
      ditherScale: valueOf(t[80]) as String,
      settleThreshold: valueOf(t[81]) as double,
      settleTimeout: valueOf(t[82]) as int,
      settleTime: valueOf(t[83]) as int,
      ditherRaOnly: valueOf(t[84]) as bool,
      bortleClass: valueOf(t[85]) as int,
      horizonProfileJson: valueOf(t[86]) as String,
      effectiveHorizonDeg: valueOf(t[87]) as double,
      audibleAlertsOnCritical: valueOf(t[88]) as bool,
      criticalAlertSound: valueOf(t[89]) as String,
      pushCriticalAlerts: valueOf(t[90]) as bool,
      recoveryDefaultRetryIntervalMins: valueOf(t[91]) as double,
      recoveryDefaultMaxDurationMins: valueOf(t[92]) as double,
      recoveryStopTrackingDuringRecovery: valueOf(t[93]) as bool,
      recoveryAbortOnMeridian: valueOf(t[94]) as bool,
      recoveryAudibleAlertWhenEntered: valueOf(t[95]) as bool,
      afMethod: valueOf(t[96]) as String,
      afCurveFitting: valueOf(t[97]) as String,
      afStepSize: valueOf(t[98]) as int,
      afExposureTime: valueOf(t[99]) as double,
      afInitialOffsetSteps: valueOf(t[100]) as int,
      afNumberOfAttempts: valueOf(t[101]) as int,
      afUseBrightestNStars: valueOf(t[102]) as int,
      afOuterCropRatio: valueOf(t[103]) as double,
      afInnerCropRatio: valueOf(t[104]) as double,
      afBinning: valueOf(t[105]) as int,
      afRSquaredThreshold: valueOf(t[106]) as double,
      afFailureHfrToleranceRatio: valueOf(t[107]) as double,
      afDisableGuidingDuringAf: valueOf(t[108]) as bool,
      afFocuserSettleTimeMs: valueOf(t[109]) as int,
      afExposuresPerPoint: valueOf(t[110]) as int,
      afBacklashCompMethod: valueOf(t[111]) as String,
      afBacklashIn: valueOf(t[112]) as int,
      focuserBacklashOfferMode: valueOf(t[113]) as String,
      focuserBacklashCalibrationJson: valueOf(t[114]) as String,
      mountSiteSyncMode: valueOf(t[115]) as String,
      afBacklashOut: valueOf(t[116]) as int,
      afAutofocusFilterName: valueOf(t[117]) as String,
      afFilterSettingsJson: valueOf(t[118]) as String,
      observerName: valueOf(t[119]) as String,
      enableImageGrading: valueOf(t[120]) as bool,
      imageGradingHfrThresholdPx: valueOf(t[121]) as double?,
      imageGradingHfrBaselinePercent: valueOf(t[122]) as double?,
      imageGradingEccentricityThreshold: valueOf(t[123]) as double?,
      imageGradingStarCountMin: valueOf(t[124]) as int?,
      imageGradingMaxConsecutiveRejects: valueOf(t[125]) as int,
      imageGradingRejectFolderPath: valueOf(t[126]) as String?,
      adaptiveExposureEnabled: valueOf(t[127]) as bool,
      adaptiveExposureTargetSnr: valueOf(t[128]) as double,
      adaptiveExposureReferenceMag: valueOf(t[129]) as double,
      adaptiveExposureMinSecs: valueOf(t[130]) as double,
      adaptiveExposureMaxSecs: valueOf(t[131]) as double,
      adaptiveExposurePerFilterEnabled: valueOf(t[132]) as Map<String, bool>,
      adaptiveExposurePerFilterMinSecs: valueOf(t[133]) as Map<String, double>,
      adaptiveExposurePerFilterMaxSecs: valueOf(t[134]) as Map<String, double>,
      preflightStrictness: valueOf(t[135]) as PreflightStrictness,
      polarAlignmentMaxAgeDays: valueOf(t[136]) as int,
      darkLibraryMinCoverage: valueOf(t[137]) as int,
      opticalTrainDriftThreshold: valueOf(t[138]) as double,
      smartNightMaxSessionHours: valueOf(t[139]) as double?,
      smartNightDefaultAfCadenceFrames: valueOf(t[140]) as int,
      smartNightDefaultIntegrationBudgetMinsPerTarget: valueOf(t[141]) as int,
      smartNightIncludeFlatsAtEnd: valueOf(t[142]) as bool,
      smartNightUseSchedulerForMultiTarget: valueOf(t[143]) as bool,
      smartNightSchedulerTargetThreshold: valueOf(t[144]) as int,
      smartNightDefaultStrategy: valueOf(t[145]) as String,
      smartNightPolarAlignmentStaleAfterDays: valueOf(t[146]) as int,
      smartNightSubExposureFloorSecs: valueOf(t[147]) as double,
      smartNightSubExposureCeilingSecs: valueOf(t[148]) as double,
      smartNightTargetSnr: valueOf(t[149]) as double,
      smartNightAutoSelect: valueOf(t[150]) as bool,
      smartNightAutoSelectCount: valueOf(t[151]) as int,
      smartNightPromptDismissedDayKey: valueOf(t[152]) as String,
      promptForNotesAfterRun: valueOf(t[153]) as bool,
      sessionHandoffAutoPrompt: valueOf(t[154]) as bool,
      campaignRollupSurfaceTargetsTab: valueOf(t[155]) as bool,
      campaignRollupGroupingMode: valueOf(t[156]) as String,
      adaptiveSwapEnabledByDefault: valueOf(t[157]) as bool,
      adaptiveSwapDefaultThreshold: valueOf(t[158]) as double,
      adaptiveSwapDefaultHysteresisSecs: valueOf(t[159]) as double,
      conditionsScoreWeights: valueOf(t[160]) as Map<String, double>,
    );
  }
}
