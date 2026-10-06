// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_ObserverLocation _$ObserverLocationFromJson(Map<String, dynamic> json) =>
    _ObserverLocation(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      elevation: (json['elevation'] as num).toDouble(),
    );

Map<String, dynamic> _$ObserverLocationToJson(_ObserverLocation instance) =>
    <String, dynamic>{
      'latitude': instance.latitude,
      'longitude': instance.longitude,
      'elevation': instance.elevation,
    };

_AppSettings _$AppSettingsFromJson(Map<String, dynamic> json) => _AppSettings(
  location: json['location'] == null
      ? null
      : ObserverLocation.fromJson(json['location'] as Map<String, dynamic>),
  theme: json['theme'] as String? ?? 'dark',
  language: json['language'] as String? ?? 'en',
  autoConnect: json['autoConnect'] as bool? ?? true,
  latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
  longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
  elevation: (json['elevation'] as num?)?.toDouble() ?? 0.0,
  fileNamingPattern: json['fileNamingPattern'] as String? ?? '',
  meridianFlipMinutes: (json['meridianFlipMinutes'] as num?)?.toInt() ?? 5,
  autoFocusEveryMinutes: (json['autoFocusEveryMinutes'] as num?)?.toInt() ?? 60,
  ditherEveryFrames: (json['ditherEveryFrames'] as num?)?.toInt() ?? 3,
  plateSolveTimeout: (json['plateSolveTimeout'] as num?)?.toInt() ?? 60,
  plateSolveSearchRadius:
      (json['plateSolveSearchRadius'] as num?)?.toDouble() ?? 30.0,
  discordWebhook: json['discordWebhook'] as String? ?? '',
  pushoverKey: json['pushoverKey'] as String? ?? '',
  pushoverUser: json['pushoverUser'] as String? ?? '',
  astapPath: json['astapPath'] as String? ?? '',
  autoDiscoverOnLaunch: json['autoDiscoverOnLaunch'] as bool? ?? true,
  accentColor: json['accentColor'] as String? ?? '',
  fontSize: json['fontSize'] as String? ?? 'Medium',
  uiScale: json['uiScale'] as String? ?? 'Auto',
  indiServerHost: json['indiServerHost'] as String? ?? 'localhost',
  indiServerPort: (json['indiServerPort'] as num?)?.toInt() ?? 7624,
  indiAutoConnect: json['indiAutoConnect'] as bool? ?? false,
  alpacaServerHost: json['alpacaServerHost'] as String? ?? 'localhost',
  alpacaServerPort: (json['alpacaServerPort'] as num?)?.toInt() ?? 11111,
  alpacaAutoDiscover: json['alpacaAutoDiscover'] as bool? ?? false,
  useSimulationMode: json['useSimulationMode'] as bool? ?? false,
  imageOutputPath: json['imageOutputPath'] as String? ?? '',
  observer: json['observer'] as String? ?? '',
  telescope: json['telescope'] as String? ?? '',
  instrument: json['instrument'] as String? ?? '',
  updateCheckEnabled: json['updateCheckEnabled'] as bool? ?? true,
  updateServerUrl: json['updateServerUrl'] as String? ?? '',
  updateChannel: json['updateChannel'] as String? ?? 'stable',
  updateCheckIntervalHours:
      (json['updateCheckIntervalHours'] as num?)?.toInt() ?? 24,
  skippedUpdateVersion: json['skippedUpdateVersion'] as String? ?? '',
  safetyFailMode:
      $enumDecodeNullable(_$SafetyFailModeEnumMap, json['safetyFailMode']) ??
      SafetyFailMode.failClosed,
  enableImageGrading: json['enableImageGrading'] as bool? ?? false,
  imageGradingHfrThresholdPx: (json['imageGradingHfrThresholdPx'] as num?)
      ?.toDouble(),
  imageGradingHfrBaselinePercent:
      (json['imageGradingHfrBaselinePercent'] as num?)?.toDouble(),
  imageGradingEccentricityThreshold:
      (json['imageGradingEccentricityThreshold'] as num?)?.toDouble(),
  imageGradingStarCountMin: (json['imageGradingStarCountMin'] as num?)?.toInt(),
  imageGradingMaxConsecutiveRejects:
      (json['imageGradingMaxConsecutiveRejects'] as num?)?.toInt() ?? 3,
  imageGradingRejectFolderPath: json['imageGradingRejectFolderPath'] as String?,
  adaptiveExposureEnabled: json['adaptiveExposureEnabled'] as bool? ?? false,
  adaptiveExposureTargetSnr:
      (json['adaptiveExposureTargetSnr'] as num?)?.toDouble() ?? 30.0,
  adaptiveExposureReferenceMag:
      (json['adaptiveExposureReferenceMag'] as num?)?.toDouble() ?? 21.5,
  adaptiveExposureMinSecs:
      (json['adaptiveExposureMinSecs'] as num?)?.toDouble() ?? 5.0,
  adaptiveExposureMaxSecs:
      (json['adaptiveExposureMaxSecs'] as num?)?.toDouble() ?? 600.0,
  adaptiveExposurePerFilterEnabled:
      (json['adaptiveExposurePerFilterEnabled'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, e as bool),
      ) ??
      const <String, bool>{},
  adaptiveExposurePerFilterMinSecs:
      (json['adaptiveExposurePerFilterMinSecs'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, (e as num).toDouble()),
      ) ??
      const <String, double>{},
  adaptiveExposurePerFilterMaxSecs:
      (json['adaptiveExposurePerFilterMaxSecs'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, (e as num).toDouble()),
      ) ??
      const <String, double>{},
  parkOnUnsafeWeather: json['parkOnUnsafeWeather'] as bool? ?? true,
  autoFocusOnFilterChange: json['autoFocusOnFilterChange'] as bool? ?? false,
  afDisableGuidingDuringAf: json['afDisableGuidingDuringAf'] as bool? ?? false,
  ditherEnabled: json['ditherEnabled'] as bool? ?? true,
  ditherScale: json['ditherScale'] as String? ?? 'Medium',
  recoveryDefaultRetryIntervalMins:
      (json['recoveryDefaultRetryIntervalMins'] as num?)?.toDouble() ?? 10.0,
  recoveryDefaultMaxDurationMins:
      (json['recoveryDefaultMaxDurationMins'] as num?)?.toDouble() ?? 90.0,
  recoveryStopTrackingDuringRecovery:
      json['recoveryStopTrackingDuringRecovery'] as bool? ?? true,
  recoveryAbortOnMeridian: json['recoveryAbortOnMeridian'] as bool? ?? true,
  recoveryAudibleAlertWhenEntered:
      json['recoveryAudibleAlertWhenEntered'] as bool? ?? true,
  parkBeforeDawn: json['parkBeforeDawn'] as bool? ?? true,
  enableMeridianFlip: json['enableMeridianFlip'] as bool? ?? true,
  tempCompensation: json['tempCompensation'] as bool? ?? false,
  tempCoefficient: (json['tempCoefficient'] as num?)?.toDouble() ?? -12.0,
  backlashCompensation: (json['backlashCompensation'] as num?)?.toInt() ?? 0,
  settleThreshold: (json['settleThreshold'] as num?)?.toDouble() ?? 1.5,
  settleTimeout: (json['settleTimeout'] as num?)?.toInt() ?? 60,
  settleTime: (json['settleTime'] as num?)?.toInt() ?? 10,
  ditherRaOnly: json['ditherRaOnly'] as bool? ?? false,
  plateSolver: json['plateSolver'] as String? ?? 'ASTAP',
  blindSolve: json['blindSolve'] as bool? ?? false,
  centeringSyncMount: json['centeringSyncMount'] as bool? ?? true,
  bortleClass: (json['bortleClass'] as num?)?.toInt() ?? 5,
  effectiveHorizonDeg: (json['effectiveHorizonDeg'] as num?)?.toDouble() ?? 0.0,
  preflightStrictness: json['preflightStrictness'] as String? ?? 'normal',
  polarAlignmentMaxAgeDays:
      (json['polarAlignmentMaxAgeDays'] as num?)?.toInt() ?? 7,
  opticalTrainDriftThreshold:
      (json['opticalTrainDriftThreshold'] as num?)?.toDouble() ?? 8.0,
  darkLibraryMinCoverage:
      (json['darkLibraryMinCoverage'] as num?)?.toInt() ?? 10,
  smartNightMaxSessionHours: (json['smartNightMaxSessionHours'] as num?)
      ?.toDouble(),
  smartNightDefaultAfCadenceFrames:
      (json['smartNightDefaultAfCadenceFrames'] as num?)?.toInt() ?? 25,
  smartNightDefaultIntegrationBudgetMinsPerTarget:
      (json['smartNightDefaultIntegrationBudgetMinsPerTarget'] as num?)
          ?.toInt() ??
      240,
  smartNightIncludeFlatsAtEnd:
      json['smartNightIncludeFlatsAtEnd'] as bool? ?? true,
  smartNightUseSchedulerForMultiTarget:
      json['smartNightUseSchedulerForMultiTarget'] as bool? ?? true,
  smartNightSchedulerTargetThreshold:
      (json['smartNightSchedulerTargetThreshold'] as num?)?.toInt() ?? 3,
  smartNightDefaultStrategy:
      json['smartNightDefaultStrategy'] as String? ?? 'auto_lrgb',
  smartNightPolarAlignmentStaleAfterDays:
      (json['smartNightPolarAlignmentStaleAfterDays'] as num?)?.toInt() ?? 7,
  smartNightSubExposureFloorSecs:
      (json['smartNightSubExposureFloorSecs'] as num?)?.toDouble() ?? 30.0,
  smartNightSubExposureCeilingSecs:
      (json['smartNightSubExposureCeilingSecs'] as num?)?.toDouble() ?? 300.0,
  smartNightTargetSnr:
      (json['smartNightTargetSnr'] as num?)?.toDouble() ?? 30.0,
  defaultGain: (json['defaultGain'] as num?)?.toInt() ?? 100,
  defaultOffset: (json['defaultOffset'] as num?)?.toInt() ?? 50,
  webServerEnabled: json['webServerEnabled'] as bool? ?? false,
  webServerPort: (json['webServerPort'] as num?)?.toInt() ?? 8080,
  phd2Path: json['phd2Path'] as String? ?? '',
  phd2Host: json['phd2Host'] as String? ?? 'localhost',
  phd2Port: (json['phd2Port'] as num?)?.toInt() ?? 4400,
  notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
  notifyOnSequenceComplete: json['notifyOnSequenceComplete'] as bool? ?? true,
  notifyOnError: json['notifyOnError'] as bool? ?? true,
  notifyOnMeridianFlip: json['notifyOnMeridianFlip'] as bool? ?? false,
  soundEnabled: json['soundEnabled'] as bool? ?? true,
  audibleAlertsOnCritical: json['audibleAlertsOnCritical'] as bool? ?? false,
  criticalAlertSound: json['criticalAlertSound'] as String? ?? 'systemBell',
  pushCriticalAlerts: json['pushCriticalAlerts'] as bool? ?? true,
  smartNightAutoPromptEnabled:
      json['smartNightAutoPromptEnabled'] as bool? ?? true,
  promptForNotesAfterRun: json['promptForNotesAfterRun'] as bool? ?? true,
  sessionHandoffAutoPrompt: json['sessionHandoffAutoPrompt'] as bool? ?? true,
  campaignRollupSurfaceTargetsTab:
      json['campaignRollupSurfaceTargetsTab'] as bool? ?? true,
  campaignRollupGroupingMode:
      json['campaignRollupGroupingMode'] as String? ?? 'by_target_name',
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
  afFailureHfrToleranceRatio:
      (json['afFailureHfrToleranceRatio'] as num?)?.toDouble() ?? 1.6,
  afFocuserSettleTimeMs:
      (json['afFocuserSettleTimeMs'] as num?)?.toInt() ?? 500,
  afExposuresPerPoint: (json['afExposuresPerPoint'] as num?)?.toInt() ?? 1,
  afBacklashCompMethod: json['afBacklashCompMethod'] as String? ?? 'Overshoot',
  afBacklashIn: (json['afBacklashIn'] as num?)?.toInt() ?? 0,
  mountSiteSyncMode: json['mountSiteSyncMode'] as String? ?? 'ask',
  afBacklashOut: (json['afBacklashOut'] as num?)?.toInt() ?? 0,
  afAutofocusFilterName: json['afAutofocusFilterName'] as String? ?? '',
  afFilterSettingsJson: json['afFilterSettingsJson'] as String? ?? '{}',
  useFilterFocusOffsets: json['useFilterFocusOffsets'] as bool? ?? true,
  astrometryPath: json['astrometryPath'] as String? ?? '',
  observerName: json['observerName'] as String? ?? '',
  imageFormat: json['imageFormat'] as String? ?? 'FITS',
  bitDepth: json['bitDepth'] as String? ?? '16-bit',
  timezone: json['timezone'] as String? ?? 'UTC',
  useSystemTime: json['useSystemTime'] as bool? ?? true,
  sequencesPath: json['sequencesPath'] as String? ?? '',
  smartNightAutoSelect: json['smartNightAutoSelect'] as bool? ?? true,
  smartNightAutoSelectCount:
      (json['smartNightAutoSelectCount'] as num?)?.toInt() ?? 2,
  adaptiveSwapEnabledByDefault:
      json['adaptiveSwapEnabledByDefault'] as bool? ?? false,
  adaptiveSwapDefaultThreshold:
      (json['adaptiveSwapDefaultThreshold'] as num?)?.toDouble() ?? 50.0,
  adaptiveSwapDefaultHysteresisSecs:
      (json['adaptiveSwapDefaultHysteresisSecs'] as num?)?.toDouble() ?? 180.0,
  conditionsScoreWeights:
      (json['conditionsScoreWeights'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, (e as num).toDouble()),
      ) ??
      const <String, double>{
        'transparency': 0.40,
        'seeing': 0.25,
        'cloud': 0.25,
        'wind': 0.10,
      },
);

Map<String, dynamic> _$AppSettingsToJson(
  _AppSettings instance,
) => <String, dynamic>{
  'location': instance.location,
  'theme': instance.theme,
  'language': instance.language,
  'autoConnect': instance.autoConnect,
  'latitude': instance.latitude,
  'longitude': instance.longitude,
  'elevation': instance.elevation,
  'fileNamingPattern': instance.fileNamingPattern,
  'meridianFlipMinutes': instance.meridianFlipMinutes,
  'autoFocusEveryMinutes': instance.autoFocusEveryMinutes,
  'ditherEveryFrames': instance.ditherEveryFrames,
  'plateSolveTimeout': instance.plateSolveTimeout,
  'plateSolveSearchRadius': instance.plateSolveSearchRadius,
  'discordWebhook': instance.discordWebhook,
  'pushoverKey': instance.pushoverKey,
  'pushoverUser': instance.pushoverUser,
  'astapPath': instance.astapPath,
  'autoDiscoverOnLaunch': instance.autoDiscoverOnLaunch,
  'accentColor': instance.accentColor,
  'fontSize': instance.fontSize,
  'uiScale': instance.uiScale,
  'indiServerHost': instance.indiServerHost,
  'indiServerPort': instance.indiServerPort,
  'indiAutoConnect': instance.indiAutoConnect,
  'alpacaServerHost': instance.alpacaServerHost,
  'alpacaServerPort': instance.alpacaServerPort,
  'alpacaAutoDiscover': instance.alpacaAutoDiscover,
  'useSimulationMode': instance.useSimulationMode,
  'imageOutputPath': instance.imageOutputPath,
  'observer': instance.observer,
  'telescope': instance.telescope,
  'instrument': instance.instrument,
  'updateCheckEnabled': instance.updateCheckEnabled,
  'updateServerUrl': instance.updateServerUrl,
  'updateChannel': instance.updateChannel,
  'updateCheckIntervalHours': instance.updateCheckIntervalHours,
  'skippedUpdateVersion': instance.skippedUpdateVersion,
  'safetyFailMode': _$SafetyFailModeEnumMap[instance.safetyFailMode]!,
  'enableImageGrading': instance.enableImageGrading,
  'imageGradingHfrThresholdPx': instance.imageGradingHfrThresholdPx,
  'imageGradingHfrBaselinePercent': instance.imageGradingHfrBaselinePercent,
  'imageGradingEccentricityThreshold':
      instance.imageGradingEccentricityThreshold,
  'imageGradingStarCountMin': instance.imageGradingStarCountMin,
  'imageGradingMaxConsecutiveRejects':
      instance.imageGradingMaxConsecutiveRejects,
  'imageGradingRejectFolderPath': instance.imageGradingRejectFolderPath,
  'adaptiveExposureEnabled': instance.adaptiveExposureEnabled,
  'adaptiveExposureTargetSnr': instance.adaptiveExposureTargetSnr,
  'adaptiveExposureReferenceMag': instance.adaptiveExposureReferenceMag,
  'adaptiveExposureMinSecs': instance.adaptiveExposureMinSecs,
  'adaptiveExposureMaxSecs': instance.adaptiveExposureMaxSecs,
  'adaptiveExposurePerFilterEnabled': instance.adaptiveExposurePerFilterEnabled,
  'adaptiveExposurePerFilterMinSecs': instance.adaptiveExposurePerFilterMinSecs,
  'adaptiveExposurePerFilterMaxSecs': instance.adaptiveExposurePerFilterMaxSecs,
  'parkOnUnsafeWeather': instance.parkOnUnsafeWeather,
  'autoFocusOnFilterChange': instance.autoFocusOnFilterChange,
  'afDisableGuidingDuringAf': instance.afDisableGuidingDuringAf,
  'ditherEnabled': instance.ditherEnabled,
  'ditherScale': instance.ditherScale,
  'recoveryDefaultRetryIntervalMins': instance.recoveryDefaultRetryIntervalMins,
  'recoveryDefaultMaxDurationMins': instance.recoveryDefaultMaxDurationMins,
  'recoveryStopTrackingDuringRecovery':
      instance.recoveryStopTrackingDuringRecovery,
  'recoveryAbortOnMeridian': instance.recoveryAbortOnMeridian,
  'recoveryAudibleAlertWhenEntered': instance.recoveryAudibleAlertWhenEntered,
  'parkBeforeDawn': instance.parkBeforeDawn,
  'enableMeridianFlip': instance.enableMeridianFlip,
  'tempCompensation': instance.tempCompensation,
  'tempCoefficient': instance.tempCoefficient,
  'backlashCompensation': instance.backlashCompensation,
  'settleThreshold': instance.settleThreshold,
  'settleTimeout': instance.settleTimeout,
  'settleTime': instance.settleTime,
  'ditherRaOnly': instance.ditherRaOnly,
  'plateSolver': instance.plateSolver,
  'blindSolve': instance.blindSolve,
  'centeringSyncMount': instance.centeringSyncMount,
  'bortleClass': instance.bortleClass,
  'effectiveHorizonDeg': instance.effectiveHorizonDeg,
  'preflightStrictness': instance.preflightStrictness,
  'polarAlignmentMaxAgeDays': instance.polarAlignmentMaxAgeDays,
  'opticalTrainDriftThreshold': instance.opticalTrainDriftThreshold,
  'darkLibraryMinCoverage': instance.darkLibraryMinCoverage,
  'smartNightMaxSessionHours': instance.smartNightMaxSessionHours,
  'smartNightDefaultAfCadenceFrames': instance.smartNightDefaultAfCadenceFrames,
  'smartNightDefaultIntegrationBudgetMinsPerTarget':
      instance.smartNightDefaultIntegrationBudgetMinsPerTarget,
  'smartNightIncludeFlatsAtEnd': instance.smartNightIncludeFlatsAtEnd,
  'smartNightUseSchedulerForMultiTarget':
      instance.smartNightUseSchedulerForMultiTarget,
  'smartNightSchedulerTargetThreshold':
      instance.smartNightSchedulerTargetThreshold,
  'smartNightDefaultStrategy': instance.smartNightDefaultStrategy,
  'smartNightPolarAlignmentStaleAfterDays':
      instance.smartNightPolarAlignmentStaleAfterDays,
  'smartNightSubExposureFloorSecs': instance.smartNightSubExposureFloorSecs,
  'smartNightSubExposureCeilingSecs': instance.smartNightSubExposureCeilingSecs,
  'smartNightTargetSnr': instance.smartNightTargetSnr,
  'defaultGain': instance.defaultGain,
  'defaultOffset': instance.defaultOffset,
  'webServerEnabled': instance.webServerEnabled,
  'webServerPort': instance.webServerPort,
  'phd2Path': instance.phd2Path,
  'phd2Host': instance.phd2Host,
  'phd2Port': instance.phd2Port,
  'notificationsEnabled': instance.notificationsEnabled,
  'notifyOnSequenceComplete': instance.notifyOnSequenceComplete,
  'notifyOnError': instance.notifyOnError,
  'notifyOnMeridianFlip': instance.notifyOnMeridianFlip,
  'soundEnabled': instance.soundEnabled,
  'audibleAlertsOnCritical': instance.audibleAlertsOnCritical,
  'criticalAlertSound': instance.criticalAlertSound,
  'pushCriticalAlerts': instance.pushCriticalAlerts,
  'smartNightAutoPromptEnabled': instance.smartNightAutoPromptEnabled,
  'promptForNotesAfterRun': instance.promptForNotesAfterRun,
  'sessionHandoffAutoPrompt': instance.sessionHandoffAutoPrompt,
  'campaignRollupSurfaceTargetsTab': instance.campaignRollupSurfaceTargetsTab,
  'campaignRollupGroupingMode': instance.campaignRollupGroupingMode,
  'afMethod': instance.afMethod,
  'afCurveFitting': instance.afCurveFitting,
  'afStepSize': instance.afStepSize,
  'afExposureTime': instance.afExposureTime,
  'afInitialOffsetSteps': instance.afInitialOffsetSteps,
  'afNumberOfAttempts': instance.afNumberOfAttempts,
  'afUseBrightestNStars': instance.afUseBrightestNStars,
  'afOuterCropRatio': instance.afOuterCropRatio,
  'afInnerCropRatio': instance.afInnerCropRatio,
  'afBinning': instance.afBinning,
  'afRSquaredThreshold': instance.afRSquaredThreshold,
  'afFailureHfrToleranceRatio': instance.afFailureHfrToleranceRatio,
  'afFocuserSettleTimeMs': instance.afFocuserSettleTimeMs,
  'afExposuresPerPoint': instance.afExposuresPerPoint,
  'afBacklashCompMethod': instance.afBacklashCompMethod,
  'afBacklashIn': instance.afBacklashIn,
  'mountSiteSyncMode': instance.mountSiteSyncMode,
  'afBacklashOut': instance.afBacklashOut,
  'afAutofocusFilterName': instance.afAutofocusFilterName,
  'afFilterSettingsJson': instance.afFilterSettingsJson,
  'useFilterFocusOffsets': instance.useFilterFocusOffsets,
  'astrometryPath': instance.astrometryPath,
  'observerName': instance.observerName,
  'imageFormat': instance.imageFormat,
  'bitDepth': instance.bitDepth,
  'timezone': instance.timezone,
  'useSystemTime': instance.useSystemTime,
  'sequencesPath': instance.sequencesPath,
  'smartNightAutoSelect': instance.smartNightAutoSelect,
  'smartNightAutoSelectCount': instance.smartNightAutoSelectCount,
  'adaptiveSwapEnabledByDefault': instance.adaptiveSwapEnabledByDefault,
  'adaptiveSwapDefaultThreshold': instance.adaptiveSwapDefaultThreshold,
  'adaptiveSwapDefaultHysteresisSecs':
      instance.adaptiveSwapDefaultHysteresisSecs,
  'conditionsScoreWeights': instance.conditionsScoreWeights,
};

const _$SafetyFailModeEnumMap = {
  SafetyFailMode.failOpen: 'failOpen',
  SafetyFailMode.failClosed: 'failClosed',
  SafetyFailMode.warnOnly: 'warnOnly',
};
