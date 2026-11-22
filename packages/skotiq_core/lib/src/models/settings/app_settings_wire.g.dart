// GENERATED from app_settings_table.dart by
// tool/generate_app_settings.dart. Do not edit: change the
// table and regenerate.

// dart format off

import 'package:freezed_annotation/freezed_annotation.dart'
    show DeepCollectionEquality, EqualUnmodifiableMapView, $enumDecodeNullable;

import 'app_settings_values.dart';

const Object _unset = Object();

final Map<SafetyFailMode, String> _safetyFailModeNames = {for (final value in SafetyFailMode.values) value: value.name};

/// The settings document a host and its linked clients
/// exchange: every setting the host keeps for them, by wire
/// name, and the fields no setting stands behind.
class AppSettings {
  const AppSettings({
    this.location,
    this.autoConnect = true,
    this.autoDiscoverOnLaunch = true,
    this.theme = 'dark',
    this.language = 'en',
    this.accentColor = '',
    this.fontSize = 'Medium',
    this.uiScale = 'Auto',
    this.latitude = 0.0,
    this.longitude = 0.0,
    this.elevation = 0.0,
    this.timezone = 'UTC',
    this.useSystemTime = true,
    this.imageFormat = 'FITS',
    this.cameraFileSaving = 'converted',
    this.xisfCompression = 'none',
    this.xisfChecksums = false,
    this.fileNamingPattern = '',
    this.bitDepth = '16-bit',
    this.parkOnUnsafeWeather = true,
    this.parkBeforeDawn = true,
    this.stopRunOnQualityProblems = false,
    this.mountGuardAutoSyncResume = true,
    this.meridianFlipMinutes = 5,
    this.autoFocusOnFilterChange = false,
    this.useFilterFocusOffsets = true,
    this.autoFocusEveryMinutes = 60,
    this.ditherEnabled = true,
    this.ditherEveryFrames = 3,
    this.cameraRetries = 3,
    this.filterWheelRetries = 3,
    this.safetyFailMode = SafetyFailMode.failClosed,
    this.plateSolver = 'ASTAP',
    this.astapPath = '',
    this.astrometryPath = '',
    this.plateSolveTimeout = 60,
    this.plateSolveSearchRadius = 30.0,
    this.blindSolve = false,
    this.centeringSyncMount = true,
    this.centeringToleranceArcsec = 5.0,
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
    this.indiServerHost = 'localhost',
    this.indiServerPort = 7624,
    this.indiAutoConnect = false,
    this.alpacaServerHost = 'localhost',
    this.alpacaServerPort = 11111,
    this.alpacaAutoDiscover = false,
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
    this.focuserBacklashCalibrationJson = '',
    this.afBacklashOut = 0,
    this.afAutofocusFilterName = '',
    this.afFilterSettingsJson = '{}',
    this.observerName = '',
    this.enableImageGrading = false,
    this.imageGradingHfrThresholdPx,
    this.imageGradingHfrBaselinePercent,
    this.imageGradingEccentricityThreshold,
    this.imageGradingEccentricityBaselinePercent,
    this.imageGradingStarCountMin,
    this.imageGradingStarCountDropPercent,
    this.imageGradingMaxConsecutiveRejects = 3,
    this.imageGradingRejectFolderPath,
    this.adaptiveExposureEnabled = false,
    this.adaptiveExposureTargetSnr = 30.0,
    this.adaptiveExposureReferenceMag = 21.5,
    this.adaptiveExposureMinSecs = 5.0,
    this.adaptiveExposureMaxSecs = 600.0,
    Map<String, bool> adaptiveExposurePerFilterEnabled = const <String, bool>{},
    Map<String, double> adaptiveExposurePerFilterMinSecs = const <String, double>{},
    Map<String, double> adaptiveExposurePerFilterMaxSecs = const <String, double>{},
    this.preflightStrictness = 'normal',
    this.polarAlignmentMaxAgeDays = 7,
    this.darkLibraryMinCoverage = 10,
    this.opticalTrainDriftThreshold = 8.0,
    this.smartNightMaxSessionHours,
    this.smartNightDefaultAfCadenceFrames = 25,
    this.smartNightDefaultIntegrationBudgetMinsPerTarget = 240,
    this.smartNightIncludeFlatsAtEnd = true,
    this.smartNightUseSchedulerForMultiTarget = true,
    this.smartNightSchedulerTargetThreshold = 3,
    this.smartNightDefaultStrategy = 'auto',
    this.smartNightPolarAlignmentStaleAfterDays = 7,
    this.smartNightSubExposureFloorSecs = 30.0,
    this.smartNightSubExposureCeilingSecs = 300.0,
    this.smartNightTargetSnr = 30.0,
    this.smartNightAutoSelect = true,
    this.smartNightAutoSelectCount = 2,
    this.promptForNotesAfterRun = true,
    this.sessionHandoffAutoPrompt = true,
    this.campaignRollupSurfaceTargetsTab = true,
    this.campaignRollupGroupingMode = 'by_target_name',
    this.adaptiveSwapEnabledByDefault = false,
    this.adaptiveSwapDefaultThreshold = 50.0,
    this.adaptiveSwapDefaultHysteresisSecs = 180.0,
    Map<String, double> conditionsScoreWeights = const <String, double>{'transparency': 0.4, 'seeing': 0.25, 'cloud': 0.25, 'wind': 0.1},
    this.useSimulationMode = false,
    this.observer = '',
    this.telescope = '',
    this.instrument = '',
    this.updateCheckEnabled = true,
    this.updateServerUrl = '',
    this.updateChannel = 'stable',
    this.updateCheckIntervalHours = 24,
    this.skippedUpdateVersion = '',
    this.mountSiteSyncMode = 'ask',
  }) : _adaptiveExposurePerFilterEnabled = adaptiveExposurePerFilterEnabled,
       _adaptiveExposurePerFilterMinSecs = adaptiveExposurePerFilterMinSecs,
       _adaptiveExposurePerFilterMaxSecs = adaptiveExposurePerFilterMaxSecs,
       _conditionsScoreWeights = conditionsScoreWeights;

  factory AppSettings.fromJson(Map<String, dynamic> json) =>
      AppSettings(
        location: json['location'] == null ? null : ObserverLocation.fromJson(json['location'] as Map<String, dynamic>),
        autoConnect: json['autoConnect'] as bool? ?? true,
        autoDiscoverOnLaunch: json['autoDiscoverOnLaunch'] as bool? ?? true,
        theme: json['theme'] as String? ?? 'dark',
        language: json['language'] as String? ?? 'en',
        accentColor: json['accentColor'] as String? ?? '',
        fontSize: json['fontSize'] as String? ?? 'Medium',
        uiScale: json['uiScale'] as String? ?? 'Auto',
        latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
        longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
        elevation: (json['elevation'] as num?)?.toDouble() ?? 0.0,
        timezone: json['timezone'] as String? ?? 'UTC',
        useSystemTime: json['useSystemTime'] as bool? ?? true,
        imageFormat: json['imageFormat'] as String? ?? 'FITS',
        cameraFileSaving: json['cameraFileSaving'] as String? ?? 'converted',
        xisfCompression: json['xisfCompression'] as String? ?? 'none',
        xisfChecksums: json['xisfChecksums'] as bool? ?? false,
        fileNamingPattern: json['fileNamingPattern'] as String? ?? '',
        bitDepth: json['bitDepth'] as String? ?? '16-bit',
        parkOnUnsafeWeather: json['parkOnUnsafeWeather'] as bool? ?? true,
        parkBeforeDawn: json['parkBeforeDawn'] as bool? ?? true,
        stopRunOnQualityProblems: json['stopRunOnQualityProblems'] as bool? ?? false,
        mountGuardAutoSyncResume: json['mountGuardAutoSyncResume'] as bool? ?? true,
        meridianFlipMinutes: (json['meridianFlipMinutes'] as num?)?.toInt() ?? 5,
        autoFocusOnFilterChange: json['autoFocusOnFilterChange'] as bool? ?? false,
        useFilterFocusOffsets: json['useFilterFocusOffsets'] as bool? ?? true,
        autoFocusEveryMinutes: (json['autoFocusEveryMinutes'] as num?)?.toInt() ?? 60,
        ditherEnabled: json['ditherEnabled'] as bool? ?? true,
        ditherEveryFrames: (json['ditherEveryFrames'] as num?)?.toInt() ?? 3,
        cameraRetries: (json['cameraRetries'] as num?)?.toInt() ?? 3,
        filterWheelRetries: (json['filterWheelRetries'] as num?)?.toInt() ?? 3,
        safetyFailMode: $enumDecodeNullable(_safetyFailModeNames, json['safetyFailMode']) ?? SafetyFailMode.failClosed,
        plateSolver: json['plateSolver'] as String? ?? 'ASTAP',
        astapPath: json['astapPath'] as String? ?? '',
        astrometryPath: json['astrometryPath'] as String? ?? '',
        plateSolveTimeout: (json['plateSolveTimeout'] as num?)?.toInt() ?? 60,
        plateSolveSearchRadius: (json['plateSolveSearchRadius'] as num?)?.toDouble() ?? 30.0,
        blindSolve: json['blindSolve'] as bool? ?? false,
        centeringSyncMount: json['centeringSyncMount'] as bool? ?? true,
        centeringToleranceArcsec: (json['centeringToleranceArcsec'] as num?)?.toDouble() ?? 5.0,
        phd2Path: json['phd2Path'] as String? ?? '',
        phd2Host: json['phd2Host'] as String? ?? 'localhost',
        phd2Port: (json['phd2Port'] as num?)?.toInt() ?? 4400,
        notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
        discordWebhook: json['discordWebhook'] as String? ?? '',
        pushoverKey: json['pushoverKey'] as String? ?? '',
        pushoverUser: json['pushoverUser'] as String? ?? '',
        notifyOnSequenceComplete: json['notifyOnSequenceComplete'] as bool? ?? true,
        notifyOnError: json['notifyOnError'] as bool? ?? true,
        notifyOnMeridianFlip: json['notifyOnMeridianFlip'] as bool? ?? false,
        soundEnabled: json['soundEnabled'] as bool? ?? true,
        imageOutputPath: json['imageOutputPath'] as String? ?? '',
        sequencesPath: json['sequencesPath'] as String? ?? '',
        indiServerHost: json['indiServerHost'] as String? ?? 'localhost',
        indiServerPort: (json['indiServerPort'] as num?)?.toInt() ?? 7624,
        indiAutoConnect: json['indiAutoConnect'] as bool? ?? false,
        alpacaServerHost: json['alpacaServerHost'] as String? ?? 'localhost',
        alpacaServerPort: (json['alpacaServerPort'] as num?)?.toInt() ?? 11111,
        alpacaAutoDiscover: json['alpacaAutoDiscover'] as bool? ?? false,
        webServerEnabled: json['webServerEnabled'] as bool? ?? false,
        webServerPort: (json['webServerPort'] as num?)?.toInt() ?? 8080,
        defaultGain: (json['defaultGain'] as num?)?.toInt() ?? 100,
        defaultOffset: (json['defaultOffset'] as num?)?.toInt() ?? 50,
        enableMeridianFlip: json['enableMeridianFlip'] as bool? ?? true,
        tempCompensation: json['tempCompensation'] as bool? ?? false,
        tempCoefficient: (json['tempCoefficient'] as num?)?.toDouble() ?? -12.0,
        tempCompensationMinSteps: (json['tempCompensationMinSteps'] as num?)?.toInt() ?? 5,
        flatCalibrationAttempts: (json['flatCalibrationAttempts'] as num?)?.toInt() ?? 20,
        backlashCompensation: (json['backlashCompensation'] as num?)?.toInt() ?? 0,
        ditherScale: json['ditherScale'] as String? ?? 'Medium',
        settleThreshold: (json['settleThreshold'] as num?)?.toDouble() ?? 1.5,
        settleTimeout: (json['settleTimeout'] as num?)?.toInt() ?? 60,
        settleTime: (json['settleTime'] as num?)?.toInt() ?? 10,
        ditherRaOnly: json['ditherRaOnly'] as bool? ?? false,
        bortleClass: (json['bortleClass'] as num?)?.toInt() ?? 5,
        effectiveHorizonDeg: (json['effectiveHorizonDeg'] as num?)?.toDouble() ?? 0.0,
        audibleAlertsOnCritical: json['audibleAlertsOnCritical'] as bool? ?? false,
        criticalAlertSound: json['criticalAlertSound'] as String? ?? 'systemBell',
        pushCriticalAlerts: json['pushCriticalAlerts'] as bool? ?? true,
        recoveryDefaultRetryIntervalMins: (json['recoveryDefaultRetryIntervalMins'] as num?)?.toDouble() ?? 10.0,
        recoveryDefaultMaxDurationMins: (json['recoveryDefaultMaxDurationMins'] as num?)?.toDouble() ?? 90.0,
        recoveryStopTrackingDuringRecovery: json['recoveryStopTrackingDuringRecovery'] as bool? ?? false,
        recoveryAbortOnMeridian: json['recoveryAbortOnMeridian'] as bool? ?? true,
        recoveryAudibleAlertWhenEntered: json['recoveryAudibleAlertWhenEntered'] as bool? ?? true,
        afMethod: json['afMethod'] as String? ?? 'Star HFR',
        afCurveFitting: json['afCurveFitting'] as String? ?? 'Hyperbolic',
        afStepSize: (json['afStepSize'] as num?)?.toInt() ?? 50,
        afExposureTime: (json['afExposureTime'] as num?)?.toDouble() ?? 4.0,
        afInitialOffsetSteps: (json['afInitialOffsetSteps'] as num?)?.toInt() ?? 4,
        afNumberOfAttempts: (json['afNumberOfAttempts'] as num?)?.toInt() ?? 1,
        afUseBrightestNStars: (json['afUseBrightestNStars'] as num?)?.toInt() ?? 10,
        afOuterCropRatio: (json['afOuterCropRatio'] as num?)?.toDouble() ?? 1.0,
        afInnerCropRatio: (json['afInnerCropRatio'] as num?)?.toDouble() ?? 0.0,
        afBinning: (json['afBinning'] as num?)?.toInt() ?? 1,
        afRSquaredThreshold: (json['afRSquaredThreshold'] as num?)?.toDouble() ?? 0.7,
        afFailureHfrToleranceRatio: (json['afFailureHfrToleranceRatio'] as num?)?.toDouble() ?? 1.6,
        afDisableGuidingDuringAf: json['afDisableGuidingDuringAf'] as bool? ?? false,
        afFocuserSettleTimeMs: (json['afFocuserSettleTimeMs'] as num?)?.toInt() ?? 500,
        afExposuresPerPoint: (json['afExposuresPerPoint'] as num?)?.toInt() ?? 1,
        afBacklashCompMethod: json['afBacklashCompMethod'] as String? ?? 'Overshoot',
        afBacklashIn: (json['afBacklashIn'] as num?)?.toInt() ?? 0,
        focuserBacklashCalibrationJson: json['focuserBacklashCalibrationJson'] as String? ?? '',
        afBacklashOut: (json['afBacklashOut'] as num?)?.toInt() ?? 0,
        afAutofocusFilterName: json['afAutofocusFilterName'] as String? ?? '',
        afFilterSettingsJson: json['afFilterSettingsJson'] as String? ?? '{}',
        observerName: json['observerName'] as String? ?? '',
        enableImageGrading: json['enableImageGrading'] as bool? ?? false,
        imageGradingHfrThresholdPx: (json['imageGradingHfrThresholdPx'] as num?)?.toDouble(),
        imageGradingHfrBaselinePercent: (json['imageGradingHfrBaselinePercent'] as num?)?.toDouble(),
        imageGradingEccentricityThreshold: (json['imageGradingEccentricityThreshold'] as num?)?.toDouble(),
        imageGradingEccentricityBaselinePercent: (json['imageGradingEccentricityBaselinePercent'] as num?)?.toDouble(),
        imageGradingStarCountMin: (json['imageGradingStarCountMin'] as num?)?.toInt(),
        imageGradingStarCountDropPercent: (json['imageGradingStarCountDropPercent'] as num?)?.toDouble(),
        imageGradingMaxConsecutiveRejects: (json['imageGradingMaxConsecutiveRejects'] as num?)?.toInt() ?? 3,
        imageGradingRejectFolderPath: json['imageGradingRejectFolderPath'] as String?,
        adaptiveExposureEnabled: json['adaptiveExposureEnabled'] as bool? ?? false,
        adaptiveExposureTargetSnr: (json['adaptiveExposureTargetSnr'] as num?)?.toDouble() ?? 30.0,
        adaptiveExposureReferenceMag: (json['adaptiveExposureReferenceMag'] as num?)?.toDouble() ?? 21.5,
        adaptiveExposureMinSecs: (json['adaptiveExposureMinSecs'] as num?)?.toDouble() ?? 5.0,
        adaptiveExposureMaxSecs: (json['adaptiveExposureMaxSecs'] as num?)?.toDouble() ?? 600.0,
        adaptiveExposurePerFilterEnabled: (json['adaptiveExposurePerFilterEnabled'] as Map<String, dynamic>?)?.map((k, e) => MapEntry(k, e as bool)) ?? const <String, bool>{},
        adaptiveExposurePerFilterMinSecs: (json['adaptiveExposurePerFilterMinSecs'] as Map<String, dynamic>?)?.map((k, e) => MapEntry(k, (e as num).toDouble())) ?? const <String, double>{},
        adaptiveExposurePerFilterMaxSecs: (json['adaptiveExposurePerFilterMaxSecs'] as Map<String, dynamic>?)?.map((k, e) => MapEntry(k, (e as num).toDouble())) ?? const <String, double>{},
        preflightStrictness: json['preflightStrictness'] as String? ?? 'normal',
        polarAlignmentMaxAgeDays: (json['polarAlignmentMaxAgeDays'] as num?)?.toInt() ?? 7,
        darkLibraryMinCoverage: (json['darkLibraryMinCoverage'] as num?)?.toInt() ?? 10,
        opticalTrainDriftThreshold: (json['opticalTrainDriftThreshold'] as num?)?.toDouble() ?? 8.0,
        smartNightMaxSessionHours: (json['smartNightMaxSessionHours'] as num?)?.toDouble(),
        smartNightDefaultAfCadenceFrames: (json['smartNightDefaultAfCadenceFrames'] as num?)?.toInt() ?? 25,
        smartNightDefaultIntegrationBudgetMinsPerTarget: (json['smartNightDefaultIntegrationBudgetMinsPerTarget'] as num?)?.toInt() ?? 240,
        smartNightIncludeFlatsAtEnd: json['smartNightIncludeFlatsAtEnd'] as bool? ?? true,
        smartNightUseSchedulerForMultiTarget: json['smartNightUseSchedulerForMultiTarget'] as bool? ?? true,
        smartNightSchedulerTargetThreshold: (json['smartNightSchedulerTargetThreshold'] as num?)?.toInt() ?? 3,
        smartNightDefaultStrategy: json['smartNightDefaultStrategy'] as String? ?? 'auto',
        smartNightPolarAlignmentStaleAfterDays: (json['smartNightPolarAlignmentStaleAfterDays'] as num?)?.toInt() ?? 7,
        smartNightSubExposureFloorSecs: (json['smartNightSubExposureFloorSecs'] as num?)?.toDouble() ?? 30.0,
        smartNightSubExposureCeilingSecs: (json['smartNightSubExposureCeilingSecs'] as num?)?.toDouble() ?? 300.0,
        smartNightTargetSnr: (json['smartNightTargetSnr'] as num?)?.toDouble() ?? 30.0,
        smartNightAutoSelect: json['smartNightAutoSelect'] as bool? ?? true,
        smartNightAutoSelectCount: (json['smartNightAutoSelectCount'] as num?)?.toInt() ?? 2,
        promptForNotesAfterRun: json['promptForNotesAfterRun'] as bool? ?? true,
        sessionHandoffAutoPrompt: json['sessionHandoffAutoPrompt'] as bool? ?? true,
        campaignRollupSurfaceTargetsTab: json['campaignRollupSurfaceTargetsTab'] as bool? ?? true,
        campaignRollupGroupingMode: json['campaignRollupGroupingMode'] as String? ?? 'by_target_name',
        adaptiveSwapEnabledByDefault: json['adaptiveSwapEnabledByDefault'] as bool? ?? false,
        adaptiveSwapDefaultThreshold: (json['adaptiveSwapDefaultThreshold'] as num?)?.toDouble() ?? 50.0,
        adaptiveSwapDefaultHysteresisSecs: (json['adaptiveSwapDefaultHysteresisSecs'] as num?)?.toDouble() ?? 180.0,
        conditionsScoreWeights: (json['conditionsScoreWeights'] as Map<String, dynamic>?)?.map((k, e) => MapEntry(k, (e as num).toDouble())) ?? const <String, double>{'transparency': 0.4, 'seeing': 0.25, 'cloud': 0.25, 'wind': 0.1},
        useSimulationMode: json['useSimulationMode'] as bool? ?? false,
        observer: json['observer'] as String? ?? '',
        telescope: json['telescope'] as String? ?? '',
        instrument: json['instrument'] as String? ?? '',
        updateCheckEnabled: json['updateCheckEnabled'] as bool? ?? true,
        updateServerUrl: json['updateServerUrl'] as String? ?? '',
        updateChannel: json['updateChannel'] as String? ?? 'stable',
        updateCheckIntervalHours: (json['updateCheckIntervalHours'] as num?)?.toInt() ?? 24,
        skippedUpdateVersion: json['skippedUpdateVersion'] as String? ?? '',
        mountSiteSyncMode: json['mountSiteSyncMode'] as String? ?? 'ask',
      );

  final ObserverLocation? location;
  final bool autoConnect;
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
  final double latitude;
  final double longitude;
  final double elevation;
  final String timezone;
  final bool useSystemTime;
  final String imageFormat;
  /// What a frame from a camera that delivers its own raw file is saved as
  /// (see [CameraFileSaving]), by sequences and manual captures alike.
  final String cameraFileSaving;
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
  /// A run held by a mount fault solves, syncs and resumes on its own. On
  /// by default: the app recovers without anyone watching (owner decision
  /// 2026-11-17).
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
  /// The label of the native plate-solver preference, kept as a stored copy
  /// for export. The preference itself is the authority.
  final String plateSolver;
  final String astapPath;
  final String astrometryPath;
  final int plateSolveTimeout;
  final double plateSolveSearchRadius;
  final bool blindSolve;
  final bool centeringSyncMount;
  /// How close to the target, in arcseconds, counts as centered: the Center
  /// step, every recenter of a run and centering started by hand all read it.
  final double centeringToleranceArcsec;
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
  final String indiServerHost;
  final int indiServerPort;
  final bool indiAutoConnect;
  final String alpacaServerHost;
  final int alpacaServerPort;
  final bool alpacaAutoDiscover;
  final bool webServerEnabled;
  final int webServerPort;
  /// A camera's gain, or a DSLR or mirrorless body's ISO. The connected
  /// camera's own gain range or ISO list bounds what Equipment settings
  /// accepts, since bodies differ widely (a Nikon D6 reaches ISO 3,280,000).
  final int defaultGain;
  /// The black-level pedestal, in ADU of a 16-bit frame.
  final int defaultOffset;
  final bool enableMeridianFlip;
  final bool tempCompensation;
  /// Focuser steps per degree Celsius. Negative is common and zero tracks the
  /// temperature without moving; a degree never asks for more than the
  /// focuser step limit.
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
  /// A flat horizon in degrees from before the site's altitude floor had one
  /// rule. Kept stored so no value is lost; nothing reads it: every "how high
  /// must a target be" asks `altitudeFloorProvider` (the horizon mask when
  /// set, otherwise the scheduler's minimum altitude).
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
  /// The operator's saved choices for a backlash calibration run, as a JSON
  /// blob of `FocuserBacklashCalibrationSettings.toJson`. Empty means no
  /// choices stored — the run seeds itself from the autofocus settings.
  final String focuserBacklashCalibrationJson;
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
  /// apply the absolute check (the default).
  final double? imageGradingHfrThresholdPx;
  /// Reject if HFR exceeds `baseline * (1 + percent / 100)`. `null` =>
  /// don't apply the baseline-relative check.
  final double? imageGradingHfrBaselinePercent;
  /// Reject if star eccentricity exceeds this absolute value. `null` =>
  /// don't apply (the default).
  final double? imageGradingEccentricityThreshold;
  /// Reject if star eccentricity exceeds `baseline * (1 + percent / 100)`.
  /// `null` => don't apply.
  final double? imageGradingEccentricityBaselinePercent;
  /// Reject if detected star count falls below this absolute floor. `null`
  /// => don't apply (the default).
  final int? imageGradingStarCountMin;
  /// Reject if the star count falls more than this percent below the
  /// baseline (50 => fewer than half the baseline's stars). `null` => don't
  /// apply.
  final double? imageGradingStarCountDropPercent;
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
  final Map<String, bool> _adaptiveExposurePerFilterEnabled;
  Map<String, bool> get adaptiveExposurePerFilterEnabled {
    final value = _adaptiveExposurePerFilterEnabled;
    if (value is EqualUnmodifiableMapView) return value;
    return EqualUnmodifiableMapView(value);
  }
  /// Per-filter minimum exposure overrides (seconds).
  final Map<String, double> _adaptiveExposurePerFilterMinSecs;
  Map<String, double> get adaptiveExposurePerFilterMinSecs {
    final value = _adaptiveExposurePerFilterMinSecs;
    if (value is EqualUnmodifiableMapView) return value;
    return EqualUnmodifiableMapView(value);
  }
  /// Per-filter maximum exposure overrides (seconds).
  final Map<String, double> _adaptiveExposurePerFilterMaxSecs;
  Map<String, double> get adaptiveExposurePerFilterMaxSecs {
    final value = _adaptiveExposurePerFilterMaxSecs;
    if (value is EqualUnmodifiableMapView) return value;
    return EqualUnmodifiableMapView(value);
  }
  /// How aggressively the pre-flight dialog should warn or block on
  /// questionable conditions (missing darks, stale polar alignment, time
  /// drift, focuser at edge of travel, etc.). Default [PreflightStrictness.normal].
  final String preflightStrictness;
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
  /// Default Smart Night filter set persisted across sessions: `auto` (each
  /// target its own) or one of `auto_lrgb`, `mono_lrgb`, `ha_lrgb`,
  /// `narrowband_ha`, `narrowband_hoo`, `narrowband_sho`, `osc_one_shot`.
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
  final Map<String, double> _conditionsScoreWeights;
  Map<String, double> get conditionsScoreWeights {
    final value = _conditionsScoreWeights;
    if (value is EqualUnmodifiableMapView) return value;
    return EqualUnmodifiableMapView(value);
  }
  /// Retired: simulation mode is not a shippable runtime state (the
  /// bundled native library is always a release build and refuses it).
  /// The field stays so stored and remote payloads that still carry it
  /// decode; nothing reads it.
  final bool useSimulationMode;
  final String observer;
  final String telescope;
  final String instrument;
  final bool updateCheckEnabled;
  final String updateServerUrl;
  final String updateChannel;
  final int updateCheckIntervalHours;
  final String skippedUpdateVersion;
  /// Always `ask` here: the setting travels through the host key/value
  /// store.
  final String mountSiteSyncMode;

  /// Each field by wire name. [location] stays its model.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'location': location,
    'autoConnect': autoConnect,
    'autoDiscoverOnLaunch': autoDiscoverOnLaunch,
    'theme': theme,
    'language': language,
    'accentColor': accentColor,
    'fontSize': fontSize,
    'uiScale': uiScale,
    'latitude': latitude,
    'longitude': longitude,
    'elevation': elevation,
    'timezone': timezone,
    'useSystemTime': useSystemTime,
    'imageFormat': imageFormat,
    'cameraFileSaving': cameraFileSaving,
    'xisfCompression': xisfCompression,
    'xisfChecksums': xisfChecksums,
    'fileNamingPattern': fileNamingPattern,
    'bitDepth': bitDepth,
    'parkOnUnsafeWeather': parkOnUnsafeWeather,
    'parkBeforeDawn': parkBeforeDawn,
    'stopRunOnQualityProblems': stopRunOnQualityProblems,
    'mountGuardAutoSyncResume': mountGuardAutoSyncResume,
    'meridianFlipMinutes': meridianFlipMinutes,
    'autoFocusOnFilterChange': autoFocusOnFilterChange,
    'useFilterFocusOffsets': useFilterFocusOffsets,
    'autoFocusEveryMinutes': autoFocusEveryMinutes,
    'ditherEnabled': ditherEnabled,
    'ditherEveryFrames': ditherEveryFrames,
    'cameraRetries': cameraRetries,
    'filterWheelRetries': filterWheelRetries,
    'safetyFailMode': _safetyFailModeNames[safetyFailMode]!,
    'plateSolver': plateSolver,
    'astapPath': astapPath,
    'astrometryPath': astrometryPath,
    'plateSolveTimeout': plateSolveTimeout,
    'plateSolveSearchRadius': plateSolveSearchRadius,
    'blindSolve': blindSolve,
    'centeringSyncMount': centeringSyncMount,
    'centeringToleranceArcsec': centeringToleranceArcsec,
    'phd2Path': phd2Path,
    'phd2Host': phd2Host,
    'phd2Port': phd2Port,
    'notificationsEnabled': notificationsEnabled,
    'discordWebhook': discordWebhook,
    'pushoverKey': pushoverKey,
    'pushoverUser': pushoverUser,
    'notifyOnSequenceComplete': notifyOnSequenceComplete,
    'notifyOnError': notifyOnError,
    'notifyOnMeridianFlip': notifyOnMeridianFlip,
    'soundEnabled': soundEnabled,
    'imageOutputPath': imageOutputPath,
    'sequencesPath': sequencesPath,
    'indiServerHost': indiServerHost,
    'indiServerPort': indiServerPort,
    'indiAutoConnect': indiAutoConnect,
    'alpacaServerHost': alpacaServerHost,
    'alpacaServerPort': alpacaServerPort,
    'alpacaAutoDiscover': alpacaAutoDiscover,
    'webServerEnabled': webServerEnabled,
    'webServerPort': webServerPort,
    'defaultGain': defaultGain,
    'defaultOffset': defaultOffset,
    'enableMeridianFlip': enableMeridianFlip,
    'tempCompensation': tempCompensation,
    'tempCoefficient': tempCoefficient,
    'tempCompensationMinSteps': tempCompensationMinSteps,
    'flatCalibrationAttempts': flatCalibrationAttempts,
    'backlashCompensation': backlashCompensation,
    'ditherScale': ditherScale,
    'settleThreshold': settleThreshold,
    'settleTimeout': settleTimeout,
    'settleTime': settleTime,
    'ditherRaOnly': ditherRaOnly,
    'bortleClass': bortleClass,
    'effectiveHorizonDeg': effectiveHorizonDeg,
    'audibleAlertsOnCritical': audibleAlertsOnCritical,
    'criticalAlertSound': criticalAlertSound,
    'pushCriticalAlerts': pushCriticalAlerts,
    'recoveryDefaultRetryIntervalMins': recoveryDefaultRetryIntervalMins,
    'recoveryDefaultMaxDurationMins': recoveryDefaultMaxDurationMins,
    'recoveryStopTrackingDuringRecovery': recoveryStopTrackingDuringRecovery,
    'recoveryAbortOnMeridian': recoveryAbortOnMeridian,
    'recoveryAudibleAlertWhenEntered': recoveryAudibleAlertWhenEntered,
    'afMethod': afMethod,
    'afCurveFitting': afCurveFitting,
    'afStepSize': afStepSize,
    'afExposureTime': afExposureTime,
    'afInitialOffsetSteps': afInitialOffsetSteps,
    'afNumberOfAttempts': afNumberOfAttempts,
    'afUseBrightestNStars': afUseBrightestNStars,
    'afOuterCropRatio': afOuterCropRatio,
    'afInnerCropRatio': afInnerCropRatio,
    'afBinning': afBinning,
    'afRSquaredThreshold': afRSquaredThreshold,
    'afFailureHfrToleranceRatio': afFailureHfrToleranceRatio,
    'afDisableGuidingDuringAf': afDisableGuidingDuringAf,
    'afFocuserSettleTimeMs': afFocuserSettleTimeMs,
    'afExposuresPerPoint': afExposuresPerPoint,
    'afBacklashCompMethod': afBacklashCompMethod,
    'afBacklashIn': afBacklashIn,
    'focuserBacklashCalibrationJson': focuserBacklashCalibrationJson,
    'afBacklashOut': afBacklashOut,
    'afAutofocusFilterName': afAutofocusFilterName,
    'afFilterSettingsJson': afFilterSettingsJson,
    'observerName': observerName,
    'enableImageGrading': enableImageGrading,
    'imageGradingHfrThresholdPx': imageGradingHfrThresholdPx,
    'imageGradingHfrBaselinePercent': imageGradingHfrBaselinePercent,
    'imageGradingEccentricityThreshold': imageGradingEccentricityThreshold,
    'imageGradingEccentricityBaselinePercent': imageGradingEccentricityBaselinePercent,
    'imageGradingStarCountMin': imageGradingStarCountMin,
    'imageGradingStarCountDropPercent': imageGradingStarCountDropPercent,
    'imageGradingMaxConsecutiveRejects': imageGradingMaxConsecutiveRejects,
    'imageGradingRejectFolderPath': imageGradingRejectFolderPath,
    'adaptiveExposureEnabled': adaptiveExposureEnabled,
    'adaptiveExposureTargetSnr': adaptiveExposureTargetSnr,
    'adaptiveExposureReferenceMag': adaptiveExposureReferenceMag,
    'adaptiveExposureMinSecs': adaptiveExposureMinSecs,
    'adaptiveExposureMaxSecs': adaptiveExposureMaxSecs,
    'adaptiveExposurePerFilterEnabled': adaptiveExposurePerFilterEnabled,
    'adaptiveExposurePerFilterMinSecs': adaptiveExposurePerFilterMinSecs,
    'adaptiveExposurePerFilterMaxSecs': adaptiveExposurePerFilterMaxSecs,
    'preflightStrictness': preflightStrictness,
    'polarAlignmentMaxAgeDays': polarAlignmentMaxAgeDays,
    'darkLibraryMinCoverage': darkLibraryMinCoverage,
    'opticalTrainDriftThreshold': opticalTrainDriftThreshold,
    'smartNightMaxSessionHours': smartNightMaxSessionHours,
    'smartNightDefaultAfCadenceFrames': smartNightDefaultAfCadenceFrames,
    'smartNightDefaultIntegrationBudgetMinsPerTarget': smartNightDefaultIntegrationBudgetMinsPerTarget,
    'smartNightIncludeFlatsAtEnd': smartNightIncludeFlatsAtEnd,
    'smartNightUseSchedulerForMultiTarget': smartNightUseSchedulerForMultiTarget,
    'smartNightSchedulerTargetThreshold': smartNightSchedulerTargetThreshold,
    'smartNightDefaultStrategy': smartNightDefaultStrategy,
    'smartNightPolarAlignmentStaleAfterDays': smartNightPolarAlignmentStaleAfterDays,
    'smartNightSubExposureFloorSecs': smartNightSubExposureFloorSecs,
    'smartNightSubExposureCeilingSecs': smartNightSubExposureCeilingSecs,
    'smartNightTargetSnr': smartNightTargetSnr,
    'smartNightAutoSelect': smartNightAutoSelect,
    'smartNightAutoSelectCount': smartNightAutoSelectCount,
    'promptForNotesAfterRun': promptForNotesAfterRun,
    'sessionHandoffAutoPrompt': sessionHandoffAutoPrompt,
    'campaignRollupSurfaceTargetsTab': campaignRollupSurfaceTargetsTab,
    'campaignRollupGroupingMode': campaignRollupGroupingMode,
    'adaptiveSwapEnabledByDefault': adaptiveSwapEnabledByDefault,
    'adaptiveSwapDefaultThreshold': adaptiveSwapDefaultThreshold,
    'adaptiveSwapDefaultHysteresisSecs': adaptiveSwapDefaultHysteresisSecs,
    'conditionsScoreWeights': conditionsScoreWeights,
    'useSimulationMode': useSimulationMode,
    'observer': observer,
    'telescope': telescope,
    'instrument': instrument,
    'updateCheckEnabled': updateCheckEnabled,
    'updateServerUrl': updateServerUrl,
    'updateChannel': updateChannel,
    'updateCheckIntervalHours': updateCheckIntervalHours,
    'skippedUpdateVersion': skippedUpdateVersion,
    'mountSiteSyncMode': mountSiteSyncMode,
  };

  /// A copy with the given fields replaced. A nullable field is
  /// cleared by passing null and kept by leaving it out.
  AppSettings copyWith({
    Object? location = _unset,
    bool? autoConnect,
    bool? autoDiscoverOnLaunch,
    String? theme,
    String? language,
    String? accentColor,
    String? fontSize,
    String? uiScale,
    double? latitude,
    double? longitude,
    double? elevation,
    String? timezone,
    bool? useSystemTime,
    String? imageFormat,
    String? cameraFileSaving,
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
    String? plateSolver,
    String? astapPath,
    String? astrometryPath,
    int? plateSolveTimeout,
    double? plateSolveSearchRadius,
    bool? blindSolve,
    bool? centeringSyncMount,
    double? centeringToleranceArcsec,
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
    String? indiServerHost,
    int? indiServerPort,
    bool? indiAutoConnect,
    String? alpacaServerHost,
    int? alpacaServerPort,
    bool? alpacaAutoDiscover,
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
    String? focuserBacklashCalibrationJson,
    int? afBacklashOut,
    String? afAutofocusFilterName,
    String? afFilterSettingsJson,
    String? observerName,
    bool? enableImageGrading,
    Object? imageGradingHfrThresholdPx = _unset,
    Object? imageGradingHfrBaselinePercent = _unset,
    Object? imageGradingEccentricityThreshold = _unset,
    Object? imageGradingEccentricityBaselinePercent = _unset,
    Object? imageGradingStarCountMin = _unset,
    Object? imageGradingStarCountDropPercent = _unset,
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
    String? preflightStrictness,
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
    bool? promptForNotesAfterRun,
    bool? sessionHandoffAutoPrompt,
    bool? campaignRollupSurfaceTargetsTab,
    String? campaignRollupGroupingMode,
    bool? adaptiveSwapEnabledByDefault,
    double? adaptiveSwapDefaultThreshold,
    double? adaptiveSwapDefaultHysteresisSecs,
    Map<String, double>? conditionsScoreWeights,
    bool? useSimulationMode,
    String? observer,
    String? telescope,
    String? instrument,
    bool? updateCheckEnabled,
    String? updateServerUrl,
    String? updateChannel,
    int? updateCheckIntervalHours,
    String? skippedUpdateVersion,
    String? mountSiteSyncMode,
  }) {
    return AppSettings(
      location: identical(location, _unset) ? this.location : location as ObserverLocation?,
      autoConnect: autoConnect ?? this.autoConnect,
      autoDiscoverOnLaunch: autoDiscoverOnLaunch ?? this.autoDiscoverOnLaunch,
      theme: theme ?? this.theme,
      language: language ?? this.language,
      accentColor: accentColor ?? this.accentColor,
      fontSize: fontSize ?? this.fontSize,
      uiScale: uiScale ?? this.uiScale,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      elevation: elevation ?? this.elevation,
      timezone: timezone ?? this.timezone,
      useSystemTime: useSystemTime ?? this.useSystemTime,
      imageFormat: imageFormat ?? this.imageFormat,
      cameraFileSaving: cameraFileSaving ?? this.cameraFileSaving,
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
      plateSolver: plateSolver ?? this.plateSolver,
      astapPath: astapPath ?? this.astapPath,
      astrometryPath: astrometryPath ?? this.astrometryPath,
      plateSolveTimeout: plateSolveTimeout ?? this.plateSolveTimeout,
      plateSolveSearchRadius: plateSolveSearchRadius ?? this.plateSolveSearchRadius,
      blindSolve: blindSolve ?? this.blindSolve,
      centeringSyncMount: centeringSyncMount ?? this.centeringSyncMount,
      centeringToleranceArcsec: centeringToleranceArcsec ?? this.centeringToleranceArcsec,
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
      indiServerHost: indiServerHost ?? this.indiServerHost,
      indiServerPort: indiServerPort ?? this.indiServerPort,
      indiAutoConnect: indiAutoConnect ?? this.indiAutoConnect,
      alpacaServerHost: alpacaServerHost ?? this.alpacaServerHost,
      alpacaServerPort: alpacaServerPort ?? this.alpacaServerPort,
      alpacaAutoDiscover: alpacaAutoDiscover ?? this.alpacaAutoDiscover,
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
      focuserBacklashCalibrationJson: focuserBacklashCalibrationJson ?? this.focuserBacklashCalibrationJson,
      afBacklashOut: afBacklashOut ?? this.afBacklashOut,
      afAutofocusFilterName: afAutofocusFilterName ?? this.afAutofocusFilterName,
      afFilterSettingsJson: afFilterSettingsJson ?? this.afFilterSettingsJson,
      observerName: observerName ?? this.observerName,
      enableImageGrading: enableImageGrading ?? this.enableImageGrading,
      imageGradingHfrThresholdPx: identical(imageGradingHfrThresholdPx, _unset) ? this.imageGradingHfrThresholdPx : imageGradingHfrThresholdPx as double?,
      imageGradingHfrBaselinePercent: identical(imageGradingHfrBaselinePercent, _unset) ? this.imageGradingHfrBaselinePercent : imageGradingHfrBaselinePercent as double?,
      imageGradingEccentricityThreshold: identical(imageGradingEccentricityThreshold, _unset) ? this.imageGradingEccentricityThreshold : imageGradingEccentricityThreshold as double?,
      imageGradingEccentricityBaselinePercent: identical(imageGradingEccentricityBaselinePercent, _unset) ? this.imageGradingEccentricityBaselinePercent : imageGradingEccentricityBaselinePercent as double?,
      imageGradingStarCountMin: identical(imageGradingStarCountMin, _unset) ? this.imageGradingStarCountMin : imageGradingStarCountMin as int?,
      imageGradingStarCountDropPercent: identical(imageGradingStarCountDropPercent, _unset) ? this.imageGradingStarCountDropPercent : imageGradingStarCountDropPercent as double?,
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
      promptForNotesAfterRun: promptForNotesAfterRun ?? this.promptForNotesAfterRun,
      sessionHandoffAutoPrompt: sessionHandoffAutoPrompt ?? this.sessionHandoffAutoPrompt,
      campaignRollupSurfaceTargetsTab: campaignRollupSurfaceTargetsTab ?? this.campaignRollupSurfaceTargetsTab,
      campaignRollupGroupingMode: campaignRollupGroupingMode ?? this.campaignRollupGroupingMode,
      adaptiveSwapEnabledByDefault: adaptiveSwapEnabledByDefault ?? this.adaptiveSwapEnabledByDefault,
      adaptiveSwapDefaultThreshold: adaptiveSwapDefaultThreshold ?? this.adaptiveSwapDefaultThreshold,
      adaptiveSwapDefaultHysteresisSecs: adaptiveSwapDefaultHysteresisSecs ?? this.adaptiveSwapDefaultHysteresisSecs,
      conditionsScoreWeights: conditionsScoreWeights ?? this.conditionsScoreWeights,
      useSimulationMode: useSimulationMode ?? this.useSimulationMode,
      observer: observer ?? this.observer,
      telescope: telescope ?? this.telescope,
      instrument: instrument ?? this.instrument,
      updateCheckEnabled: updateCheckEnabled ?? this.updateCheckEnabled,
      updateServerUrl: updateServerUrl ?? this.updateServerUrl,
      updateChannel: updateChannel ?? this.updateChannel,
      updateCheckIntervalHours: updateCheckIntervalHours ?? this.updateCheckIntervalHours,
      skippedUpdateVersion: skippedUpdateVersion ?? this.skippedUpdateVersion,
      mountSiteSyncMode: mountSiteSyncMode ?? this.mountSiteSyncMode,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other.runtimeType == runtimeType &&
          other is AppSettings &&
          other.location == location &&
          other.autoConnect == autoConnect &&
          other.autoDiscoverOnLaunch == autoDiscoverOnLaunch &&
          other.theme == theme &&
          other.language == language &&
          other.accentColor == accentColor &&
          other.fontSize == fontSize &&
          other.uiScale == uiScale &&
          other.latitude == latitude &&
          other.longitude == longitude &&
          other.elevation == elevation &&
          other.timezone == timezone &&
          other.useSystemTime == useSystemTime &&
          other.imageFormat == imageFormat &&
          other.cameraFileSaving == cameraFileSaving &&
          other.xisfCompression == xisfCompression &&
          other.xisfChecksums == xisfChecksums &&
          other.fileNamingPattern == fileNamingPattern &&
          other.bitDepth == bitDepth &&
          other.parkOnUnsafeWeather == parkOnUnsafeWeather &&
          other.parkBeforeDawn == parkBeforeDawn &&
          other.stopRunOnQualityProblems == stopRunOnQualityProblems &&
          other.mountGuardAutoSyncResume == mountGuardAutoSyncResume &&
          other.meridianFlipMinutes == meridianFlipMinutes &&
          other.autoFocusOnFilterChange == autoFocusOnFilterChange &&
          other.useFilterFocusOffsets == useFilterFocusOffsets &&
          other.autoFocusEveryMinutes == autoFocusEveryMinutes &&
          other.ditherEnabled == ditherEnabled &&
          other.ditherEveryFrames == ditherEveryFrames &&
          other.cameraRetries == cameraRetries &&
          other.filterWheelRetries == filterWheelRetries &&
          other.safetyFailMode == safetyFailMode &&
          other.plateSolver == plateSolver &&
          other.astapPath == astapPath &&
          other.astrometryPath == astrometryPath &&
          other.plateSolveTimeout == plateSolveTimeout &&
          other.plateSolveSearchRadius == plateSolveSearchRadius &&
          other.blindSolve == blindSolve &&
          other.centeringSyncMount == centeringSyncMount &&
          other.centeringToleranceArcsec == centeringToleranceArcsec &&
          other.phd2Path == phd2Path &&
          other.phd2Host == phd2Host &&
          other.phd2Port == phd2Port &&
          other.notificationsEnabled == notificationsEnabled &&
          other.discordWebhook == discordWebhook &&
          other.pushoverKey == pushoverKey &&
          other.pushoverUser == pushoverUser &&
          other.notifyOnSequenceComplete == notifyOnSequenceComplete &&
          other.notifyOnError == notifyOnError &&
          other.notifyOnMeridianFlip == notifyOnMeridianFlip &&
          other.soundEnabled == soundEnabled &&
          other.imageOutputPath == imageOutputPath &&
          other.sequencesPath == sequencesPath &&
          other.indiServerHost == indiServerHost &&
          other.indiServerPort == indiServerPort &&
          other.indiAutoConnect == indiAutoConnect &&
          other.alpacaServerHost == alpacaServerHost &&
          other.alpacaServerPort == alpacaServerPort &&
          other.alpacaAutoDiscover == alpacaAutoDiscover &&
          other.webServerEnabled == webServerEnabled &&
          other.webServerPort == webServerPort &&
          other.defaultGain == defaultGain &&
          other.defaultOffset == defaultOffset &&
          other.enableMeridianFlip == enableMeridianFlip &&
          other.tempCompensation == tempCompensation &&
          other.tempCoefficient == tempCoefficient &&
          other.tempCompensationMinSteps == tempCompensationMinSteps &&
          other.flatCalibrationAttempts == flatCalibrationAttempts &&
          other.backlashCompensation == backlashCompensation &&
          other.ditherScale == ditherScale &&
          other.settleThreshold == settleThreshold &&
          other.settleTimeout == settleTimeout &&
          other.settleTime == settleTime &&
          other.ditherRaOnly == ditherRaOnly &&
          other.bortleClass == bortleClass &&
          other.effectiveHorizonDeg == effectiveHorizonDeg &&
          other.audibleAlertsOnCritical == audibleAlertsOnCritical &&
          other.criticalAlertSound == criticalAlertSound &&
          other.pushCriticalAlerts == pushCriticalAlerts &&
          other.recoveryDefaultRetryIntervalMins == recoveryDefaultRetryIntervalMins &&
          other.recoveryDefaultMaxDurationMins == recoveryDefaultMaxDurationMins &&
          other.recoveryStopTrackingDuringRecovery == recoveryStopTrackingDuringRecovery &&
          other.recoveryAbortOnMeridian == recoveryAbortOnMeridian &&
          other.recoveryAudibleAlertWhenEntered == recoveryAudibleAlertWhenEntered &&
          other.afMethod == afMethod &&
          other.afCurveFitting == afCurveFitting &&
          other.afStepSize == afStepSize &&
          other.afExposureTime == afExposureTime &&
          other.afInitialOffsetSteps == afInitialOffsetSteps &&
          other.afNumberOfAttempts == afNumberOfAttempts &&
          other.afUseBrightestNStars == afUseBrightestNStars &&
          other.afOuterCropRatio == afOuterCropRatio &&
          other.afInnerCropRatio == afInnerCropRatio &&
          other.afBinning == afBinning &&
          other.afRSquaredThreshold == afRSquaredThreshold &&
          other.afFailureHfrToleranceRatio == afFailureHfrToleranceRatio &&
          other.afDisableGuidingDuringAf == afDisableGuidingDuringAf &&
          other.afFocuserSettleTimeMs == afFocuserSettleTimeMs &&
          other.afExposuresPerPoint == afExposuresPerPoint &&
          other.afBacklashCompMethod == afBacklashCompMethod &&
          other.afBacklashIn == afBacklashIn &&
          other.focuserBacklashCalibrationJson == focuserBacklashCalibrationJson &&
          other.afBacklashOut == afBacklashOut &&
          other.afAutofocusFilterName == afAutofocusFilterName &&
          other.afFilterSettingsJson == afFilterSettingsJson &&
          other.observerName == observerName &&
          other.enableImageGrading == enableImageGrading &&
          other.imageGradingHfrThresholdPx == imageGradingHfrThresholdPx &&
          other.imageGradingHfrBaselinePercent == imageGradingHfrBaselinePercent &&
          other.imageGradingEccentricityThreshold == imageGradingEccentricityThreshold &&
          other.imageGradingEccentricityBaselinePercent == imageGradingEccentricityBaselinePercent &&
          other.imageGradingStarCountMin == imageGradingStarCountMin &&
          other.imageGradingStarCountDropPercent == imageGradingStarCountDropPercent &&
          other.imageGradingMaxConsecutiveRejects == imageGradingMaxConsecutiveRejects &&
          other.imageGradingRejectFolderPath == imageGradingRejectFolderPath &&
          other.adaptiveExposureEnabled == adaptiveExposureEnabled &&
          other.adaptiveExposureTargetSnr == adaptiveExposureTargetSnr &&
          other.adaptiveExposureReferenceMag == adaptiveExposureReferenceMag &&
          other.adaptiveExposureMinSecs == adaptiveExposureMinSecs &&
          other.adaptiveExposureMaxSecs == adaptiveExposureMaxSecs &&
          const DeepCollectionEquality().equals(other._adaptiveExposurePerFilterEnabled, _adaptiveExposurePerFilterEnabled) &&
          const DeepCollectionEquality().equals(other._adaptiveExposurePerFilterMinSecs, _adaptiveExposurePerFilterMinSecs) &&
          const DeepCollectionEquality().equals(other._adaptiveExposurePerFilterMaxSecs, _adaptiveExposurePerFilterMaxSecs) &&
          other.preflightStrictness == preflightStrictness &&
          other.polarAlignmentMaxAgeDays == polarAlignmentMaxAgeDays &&
          other.darkLibraryMinCoverage == darkLibraryMinCoverage &&
          other.opticalTrainDriftThreshold == opticalTrainDriftThreshold &&
          other.smartNightMaxSessionHours == smartNightMaxSessionHours &&
          other.smartNightDefaultAfCadenceFrames == smartNightDefaultAfCadenceFrames &&
          other.smartNightDefaultIntegrationBudgetMinsPerTarget == smartNightDefaultIntegrationBudgetMinsPerTarget &&
          other.smartNightIncludeFlatsAtEnd == smartNightIncludeFlatsAtEnd &&
          other.smartNightUseSchedulerForMultiTarget == smartNightUseSchedulerForMultiTarget &&
          other.smartNightSchedulerTargetThreshold == smartNightSchedulerTargetThreshold &&
          other.smartNightDefaultStrategy == smartNightDefaultStrategy &&
          other.smartNightPolarAlignmentStaleAfterDays == smartNightPolarAlignmentStaleAfterDays &&
          other.smartNightSubExposureFloorSecs == smartNightSubExposureFloorSecs &&
          other.smartNightSubExposureCeilingSecs == smartNightSubExposureCeilingSecs &&
          other.smartNightTargetSnr == smartNightTargetSnr &&
          other.smartNightAutoSelect == smartNightAutoSelect &&
          other.smartNightAutoSelectCount == smartNightAutoSelectCount &&
          other.promptForNotesAfterRun == promptForNotesAfterRun &&
          other.sessionHandoffAutoPrompt == sessionHandoffAutoPrompt &&
          other.campaignRollupSurfaceTargetsTab == campaignRollupSurfaceTargetsTab &&
          other.campaignRollupGroupingMode == campaignRollupGroupingMode &&
          other.adaptiveSwapEnabledByDefault == adaptiveSwapEnabledByDefault &&
          other.adaptiveSwapDefaultThreshold == adaptiveSwapDefaultThreshold &&
          other.adaptiveSwapDefaultHysteresisSecs == adaptiveSwapDefaultHysteresisSecs &&
          const DeepCollectionEquality().equals(other._conditionsScoreWeights, _conditionsScoreWeights) &&
          other.useSimulationMode == useSimulationMode &&
          other.observer == observer &&
          other.telescope == telescope &&
          other.instrument == instrument &&
          other.updateCheckEnabled == updateCheckEnabled &&
          other.updateServerUrl == updateServerUrl &&
          other.updateChannel == updateChannel &&
          other.updateCheckIntervalHours == updateCheckIntervalHours &&
          other.skippedUpdateVersion == skippedUpdateVersion &&
          other.mountSiteSyncMode == mountSiteSyncMode);

  @override
  int get hashCode => Object.hashAll([
    runtimeType,
    location,
    autoConnect,
    autoDiscoverOnLaunch,
    theme,
    language,
    accentColor,
    fontSize,
    uiScale,
    latitude,
    longitude,
    elevation,
    timezone,
    useSystemTime,
    imageFormat,
    cameraFileSaving,
    xisfCompression,
    xisfChecksums,
    fileNamingPattern,
    bitDepth,
    parkOnUnsafeWeather,
    parkBeforeDawn,
    stopRunOnQualityProblems,
    mountGuardAutoSyncResume,
    meridianFlipMinutes,
    autoFocusOnFilterChange,
    useFilterFocusOffsets,
    autoFocusEveryMinutes,
    ditherEnabled,
    ditherEveryFrames,
    cameraRetries,
    filterWheelRetries,
    safetyFailMode,
    plateSolver,
    astapPath,
    astrometryPath,
    plateSolveTimeout,
    plateSolveSearchRadius,
    blindSolve,
    centeringSyncMount,
    centeringToleranceArcsec,
    phd2Path,
    phd2Host,
    phd2Port,
    notificationsEnabled,
    discordWebhook,
    pushoverKey,
    pushoverUser,
    notifyOnSequenceComplete,
    notifyOnError,
    notifyOnMeridianFlip,
    soundEnabled,
    imageOutputPath,
    sequencesPath,
    indiServerHost,
    indiServerPort,
    indiAutoConnect,
    alpacaServerHost,
    alpacaServerPort,
    alpacaAutoDiscover,
    webServerEnabled,
    webServerPort,
    defaultGain,
    defaultOffset,
    enableMeridianFlip,
    tempCompensation,
    tempCoefficient,
    tempCompensationMinSteps,
    flatCalibrationAttempts,
    backlashCompensation,
    ditherScale,
    settleThreshold,
    settleTimeout,
    settleTime,
    ditherRaOnly,
    bortleClass,
    effectiveHorizonDeg,
    audibleAlertsOnCritical,
    criticalAlertSound,
    pushCriticalAlerts,
    recoveryDefaultRetryIntervalMins,
    recoveryDefaultMaxDurationMins,
    recoveryStopTrackingDuringRecovery,
    recoveryAbortOnMeridian,
    recoveryAudibleAlertWhenEntered,
    afMethod,
    afCurveFitting,
    afStepSize,
    afExposureTime,
    afInitialOffsetSteps,
    afNumberOfAttempts,
    afUseBrightestNStars,
    afOuterCropRatio,
    afInnerCropRatio,
    afBinning,
    afRSquaredThreshold,
    afFailureHfrToleranceRatio,
    afDisableGuidingDuringAf,
    afFocuserSettleTimeMs,
    afExposuresPerPoint,
    afBacklashCompMethod,
    afBacklashIn,
    focuserBacklashCalibrationJson,
    afBacklashOut,
    afAutofocusFilterName,
    afFilterSettingsJson,
    observerName,
    enableImageGrading,
    imageGradingHfrThresholdPx,
    imageGradingHfrBaselinePercent,
    imageGradingEccentricityThreshold,
    imageGradingEccentricityBaselinePercent,
    imageGradingStarCountMin,
    imageGradingStarCountDropPercent,
    imageGradingMaxConsecutiveRejects,
    imageGradingRejectFolderPath,
    adaptiveExposureEnabled,
    adaptiveExposureTargetSnr,
    adaptiveExposureReferenceMag,
    adaptiveExposureMinSecs,
    adaptiveExposureMaxSecs,
    const DeepCollectionEquality().hash(_adaptiveExposurePerFilterEnabled),
    const DeepCollectionEquality().hash(_adaptiveExposurePerFilterMinSecs),
    const DeepCollectionEquality().hash(_adaptiveExposurePerFilterMaxSecs),
    preflightStrictness,
    polarAlignmentMaxAgeDays,
    darkLibraryMinCoverage,
    opticalTrainDriftThreshold,
    smartNightMaxSessionHours,
    smartNightDefaultAfCadenceFrames,
    smartNightDefaultIntegrationBudgetMinsPerTarget,
    smartNightIncludeFlatsAtEnd,
    smartNightUseSchedulerForMultiTarget,
    smartNightSchedulerTargetThreshold,
    smartNightDefaultStrategy,
    smartNightPolarAlignmentStaleAfterDays,
    smartNightSubExposureFloorSecs,
    smartNightSubExposureCeilingSecs,
    smartNightTargetSnr,
    smartNightAutoSelect,
    smartNightAutoSelectCount,
    promptForNotesAfterRun,
    sessionHandoffAutoPrompt,
    campaignRollupSurfaceTargetsTab,
    campaignRollupGroupingMode,
    adaptiveSwapEnabledByDefault,
    adaptiveSwapDefaultThreshold,
    adaptiveSwapDefaultHysteresisSecs,
    const DeepCollectionEquality().hash(_conditionsScoreWeights),
    useSimulationMode,
    observer,
    telescope,
    instrument,
    updateCheckEnabled,
    updateServerUrl,
    updateChannel,
    updateCheckIntervalHours,
    skippedUpdateVersion,
    mountSiteSyncMode,
  ]);

  @override
  String toString() =>
      'AppSettings('
      'location: $location, '
      'autoConnect: $autoConnect, '
      'autoDiscoverOnLaunch: $autoDiscoverOnLaunch, '
      'theme: $theme, '
      'language: $language, '
      'accentColor: $accentColor, '
      'fontSize: $fontSize, '
      'uiScale: $uiScale, '
      'latitude: $latitude, '
      'longitude: $longitude, '
      'elevation: $elevation, '
      'timezone: $timezone, '
      'useSystemTime: $useSystemTime, '
      'imageFormat: $imageFormat, '
      'cameraFileSaving: $cameraFileSaving, '
      'xisfCompression: $xisfCompression, '
      'xisfChecksums: $xisfChecksums, '
      'fileNamingPattern: $fileNamingPattern, '
      'bitDepth: $bitDepth, '
      'parkOnUnsafeWeather: $parkOnUnsafeWeather, '
      'parkBeforeDawn: $parkBeforeDawn, '
      'stopRunOnQualityProblems: $stopRunOnQualityProblems, '
      'mountGuardAutoSyncResume: $mountGuardAutoSyncResume, '
      'meridianFlipMinutes: $meridianFlipMinutes, '
      'autoFocusOnFilterChange: $autoFocusOnFilterChange, '
      'useFilterFocusOffsets: $useFilterFocusOffsets, '
      'autoFocusEveryMinutes: $autoFocusEveryMinutes, '
      'ditherEnabled: $ditherEnabled, '
      'ditherEveryFrames: $ditherEveryFrames, '
      'cameraRetries: $cameraRetries, '
      'filterWheelRetries: $filterWheelRetries, '
      'safetyFailMode: $safetyFailMode, '
      'plateSolver: $plateSolver, '
      'astapPath: $astapPath, '
      'astrometryPath: $astrometryPath, '
      'plateSolveTimeout: $plateSolveTimeout, '
      'plateSolveSearchRadius: $plateSolveSearchRadius, '
      'blindSolve: $blindSolve, '
      'centeringSyncMount: $centeringSyncMount, '
      'centeringToleranceArcsec: $centeringToleranceArcsec, '
      'phd2Path: $phd2Path, '
      'phd2Host: $phd2Host, '
      'phd2Port: $phd2Port, '
      'notificationsEnabled: $notificationsEnabled, '
      'discordWebhook: $discordWebhook, '
      'pushoverKey: $pushoverKey, '
      'pushoverUser: $pushoverUser, '
      'notifyOnSequenceComplete: $notifyOnSequenceComplete, '
      'notifyOnError: $notifyOnError, '
      'notifyOnMeridianFlip: $notifyOnMeridianFlip, '
      'soundEnabled: $soundEnabled, '
      'imageOutputPath: $imageOutputPath, '
      'sequencesPath: $sequencesPath, '
      'indiServerHost: $indiServerHost, '
      'indiServerPort: $indiServerPort, '
      'indiAutoConnect: $indiAutoConnect, '
      'alpacaServerHost: $alpacaServerHost, '
      'alpacaServerPort: $alpacaServerPort, '
      'alpacaAutoDiscover: $alpacaAutoDiscover, '
      'webServerEnabled: $webServerEnabled, '
      'webServerPort: $webServerPort, '
      'defaultGain: $defaultGain, '
      'defaultOffset: $defaultOffset, '
      'enableMeridianFlip: $enableMeridianFlip, '
      'tempCompensation: $tempCompensation, '
      'tempCoefficient: $tempCoefficient, '
      'tempCompensationMinSteps: $tempCompensationMinSteps, '
      'flatCalibrationAttempts: $flatCalibrationAttempts, '
      'backlashCompensation: $backlashCompensation, '
      'ditherScale: $ditherScale, '
      'settleThreshold: $settleThreshold, '
      'settleTimeout: $settleTimeout, '
      'settleTime: $settleTime, '
      'ditherRaOnly: $ditherRaOnly, '
      'bortleClass: $bortleClass, '
      'effectiveHorizonDeg: $effectiveHorizonDeg, '
      'audibleAlertsOnCritical: $audibleAlertsOnCritical, '
      'criticalAlertSound: $criticalAlertSound, '
      'pushCriticalAlerts: $pushCriticalAlerts, '
      'recoveryDefaultRetryIntervalMins: $recoveryDefaultRetryIntervalMins, '
      'recoveryDefaultMaxDurationMins: $recoveryDefaultMaxDurationMins, '
      'recoveryStopTrackingDuringRecovery: $recoveryStopTrackingDuringRecovery, '
      'recoveryAbortOnMeridian: $recoveryAbortOnMeridian, '
      'recoveryAudibleAlertWhenEntered: $recoveryAudibleAlertWhenEntered, '
      'afMethod: $afMethod, '
      'afCurveFitting: $afCurveFitting, '
      'afStepSize: $afStepSize, '
      'afExposureTime: $afExposureTime, '
      'afInitialOffsetSteps: $afInitialOffsetSteps, '
      'afNumberOfAttempts: $afNumberOfAttempts, '
      'afUseBrightestNStars: $afUseBrightestNStars, '
      'afOuterCropRatio: $afOuterCropRatio, '
      'afInnerCropRatio: $afInnerCropRatio, '
      'afBinning: $afBinning, '
      'afRSquaredThreshold: $afRSquaredThreshold, '
      'afFailureHfrToleranceRatio: $afFailureHfrToleranceRatio, '
      'afDisableGuidingDuringAf: $afDisableGuidingDuringAf, '
      'afFocuserSettleTimeMs: $afFocuserSettleTimeMs, '
      'afExposuresPerPoint: $afExposuresPerPoint, '
      'afBacklashCompMethod: $afBacklashCompMethod, '
      'afBacklashIn: $afBacklashIn, '
      'focuserBacklashCalibrationJson: $focuserBacklashCalibrationJson, '
      'afBacklashOut: $afBacklashOut, '
      'afAutofocusFilterName: $afAutofocusFilterName, '
      'afFilterSettingsJson: $afFilterSettingsJson, '
      'observerName: $observerName, '
      'enableImageGrading: $enableImageGrading, '
      'imageGradingHfrThresholdPx: $imageGradingHfrThresholdPx, '
      'imageGradingHfrBaselinePercent: $imageGradingHfrBaselinePercent, '
      'imageGradingEccentricityThreshold: $imageGradingEccentricityThreshold, '
      'imageGradingEccentricityBaselinePercent: $imageGradingEccentricityBaselinePercent, '
      'imageGradingStarCountMin: $imageGradingStarCountMin, '
      'imageGradingStarCountDropPercent: $imageGradingStarCountDropPercent, '
      'imageGradingMaxConsecutiveRejects: $imageGradingMaxConsecutiveRejects, '
      'imageGradingRejectFolderPath: $imageGradingRejectFolderPath, '
      'adaptiveExposureEnabled: $adaptiveExposureEnabled, '
      'adaptiveExposureTargetSnr: $adaptiveExposureTargetSnr, '
      'adaptiveExposureReferenceMag: $adaptiveExposureReferenceMag, '
      'adaptiveExposureMinSecs: $adaptiveExposureMinSecs, '
      'adaptiveExposureMaxSecs: $adaptiveExposureMaxSecs, '
      'adaptiveExposurePerFilterEnabled: $adaptiveExposurePerFilterEnabled, '
      'adaptiveExposurePerFilterMinSecs: $adaptiveExposurePerFilterMinSecs, '
      'adaptiveExposurePerFilterMaxSecs: $adaptiveExposurePerFilterMaxSecs, '
      'preflightStrictness: $preflightStrictness, '
      'polarAlignmentMaxAgeDays: $polarAlignmentMaxAgeDays, '
      'darkLibraryMinCoverage: $darkLibraryMinCoverage, '
      'opticalTrainDriftThreshold: $opticalTrainDriftThreshold, '
      'smartNightMaxSessionHours: $smartNightMaxSessionHours, '
      'smartNightDefaultAfCadenceFrames: $smartNightDefaultAfCadenceFrames, '
      'smartNightDefaultIntegrationBudgetMinsPerTarget: $smartNightDefaultIntegrationBudgetMinsPerTarget, '
      'smartNightIncludeFlatsAtEnd: $smartNightIncludeFlatsAtEnd, '
      'smartNightUseSchedulerForMultiTarget: $smartNightUseSchedulerForMultiTarget, '
      'smartNightSchedulerTargetThreshold: $smartNightSchedulerTargetThreshold, '
      'smartNightDefaultStrategy: $smartNightDefaultStrategy, '
      'smartNightPolarAlignmentStaleAfterDays: $smartNightPolarAlignmentStaleAfterDays, '
      'smartNightSubExposureFloorSecs: $smartNightSubExposureFloorSecs, '
      'smartNightSubExposureCeilingSecs: $smartNightSubExposureCeilingSecs, '
      'smartNightTargetSnr: $smartNightTargetSnr, '
      'smartNightAutoSelect: $smartNightAutoSelect, '
      'smartNightAutoSelectCount: $smartNightAutoSelectCount, '
      'promptForNotesAfterRun: $promptForNotesAfterRun, '
      'sessionHandoffAutoPrompt: $sessionHandoffAutoPrompt, '
      'campaignRollupSurfaceTargetsTab: $campaignRollupSurfaceTargetsTab, '
      'campaignRollupGroupingMode: $campaignRollupGroupingMode, '
      'adaptiveSwapEnabledByDefault: $adaptiveSwapEnabledByDefault, '
      'adaptiveSwapDefaultThreshold: $adaptiveSwapDefaultThreshold, '
      'adaptiveSwapDefaultHysteresisSecs: $adaptiveSwapDefaultHysteresisSecs, '
      'conditionsScoreWeights: $conditionsScoreWeights, '
      'useSimulationMode: $useSimulationMode, '
      'observer: $observer, '
      'telescope: $telescope, '
      'instrument: $instrument, '
      'updateCheckEnabled: $updateCheckEnabled, '
      'updateServerUrl: $updateServerUrl, '
      'updateChannel: $updateChannel, '
      'updateCheckIntervalHours: $updateCheckIntervalHours, '
      'skippedUpdateVersion: $skippedUpdateVersion, '
      'mountSiteSyncMode: $mountSiteSyncMode)';
}
