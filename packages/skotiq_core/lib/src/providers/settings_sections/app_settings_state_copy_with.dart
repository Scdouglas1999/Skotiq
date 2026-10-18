part of '../settings_provider.dart';

/// [AppSettingsState.copyWith], split verbatim out of `app_settings_state.dart`.
extension AppSettingsStateCopyWith on AppSettingsState {
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
    String? fileNamingPattern,
    String? bitDepth,
    bool? parkOnUnsafeWeather,
    bool? parkBeforeDawn,
    bool? stopRunOnQualityProblems,
    int? meridianFlipMinutes,
    bool? autoFocusOnFilterChange,
    bool? useFilterFocusOffsets,
    int? autoFocusEveryMinutes,
    bool? ditherEnabled,
    int? ditherEveryFrames,
    int? cameraRetries,
    int? filterWheelRetries,
    SafetyFailMode? safetyFailMode,
    // Sequencer editor layout. Nullable fields use the `_unset` sentinel so
    // a caller can deliberately clear a stored preference back to null
    // ("use the responsive default") vs. leaving it unchanged.
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
    // Remote Access / Web Server
    bool? webServerEnabled,
    int? webServerPort,
    // Equipment Settings
    int? defaultGain,
    int? defaultOffset,
    bool? enableMeridianFlip,
    bool? tempCompensation,
    double? tempCoefficient,
    int? backlashCompensation,
    String? ditherScale,
    double? settleThreshold,
    int? settleTimeout,
    int? settleTime,
    bool? ditherRaOnly,
    // Observing Environment
    int? bortleClass,
    String? horizonProfileJson,
    double? effectiveHorizonDeg,
    bool? audibleAlertsOnCritical,
    String? criticalAlertSound,
    bool? pushCriticalAlerts,
    // Recovery Mode
    double? recoveryDefaultRetryIntervalMins,
    double? recoveryDefaultMaxDurationMins,
    bool? recoveryStopTrackingDuringRecovery,
    bool? recoveryAbortOnMeridian,
    bool? recoveryAudibleAlertWhenEntered,
    // Autofocus Settings
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
    // Observer name (FITS OBSERVER)
    String? observerName,
    // Image Grading
    bool? enableImageGrading,
    // Wrap nullable fields with Object() sentinels so callers can set them
    // back to null. We use a private `_unset` sentinel to distinguish
    // "no change" from "set to null". Dart doesn't have a built-in
    // optional-but-nullable pattern; this is the canonical workaround.
    Object? imageGradingHfrThresholdPx = _unset,
    Object? imageGradingHfrBaselinePercent = _unset,
    Object? imageGradingEccentricityThreshold = _unset,
    Object? imageGradingStarCountMin = _unset,
    int? imageGradingMaxConsecutiveRejects,
    Object? imageGradingRejectFolderPath = _unset,
    // Sky-brightness adaptive exposure
    bool? adaptiveExposureEnabled,
    double? adaptiveExposureTargetSnr,
    double? adaptiveExposureReferenceMag,
    double? adaptiveExposureMinSecs,
    double? adaptiveExposureMaxSecs,
    Map<String, bool>? adaptiveExposurePerFilterEnabled,
    Map<String, double>? adaptiveExposurePerFilterMinSecs,
    Map<String, double>? adaptiveExposurePerFilterMaxSecs,
    // Pre-flight
    PreflightStrictness? preflightStrictness,
    int? polarAlignmentMaxAgeDays,
    int? darkLibraryMinCoverage,
    double? opticalTrainDriftThreshold,
    // Smart Night defaults. `smartNightMaxSessionHours`
    // uses the same `_unset` sentinel pattern as the nullable Image
    // Grading thresholds so callers can deliberately clear it back to
    // "use the full dark window".
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
    bool? smartNightAutoPromptEnabled,
    bool? smartNightAutoSelect,
    int? smartNightAutoSelectCount,
    String? smartNightPromptDismissedDayKey,
    // Notes prompt toggle.
    bool? promptForNotesAfterRun,
    // Session lifecycle.
    bool? sessionHandoffAutoPrompt,
    bool? campaignRollupSurfaceTargetsTab,
    String? campaignRollupGroupingMode,
    // Adaptive sky-conditions defaults.
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
      fileNamingPattern: fileNamingPattern ?? this.fileNamingPattern,
      bitDepth: bitDepth ?? this.bitDepth,
      parkOnUnsafeWeather: parkOnUnsafeWeather ?? this.parkOnUnsafeWeather,
      parkBeforeDawn: parkBeforeDawn ?? this.parkBeforeDawn,
      stopRunOnQualityProblems:
          stopRunOnQualityProblems ?? this.stopRunOnQualityProblems,
      meridianFlipMinutes: meridianFlipMinutes ?? this.meridianFlipMinutes,
      autoFocusOnFilterChange:
          autoFocusOnFilterChange ?? this.autoFocusOnFilterChange,
      useFilterFocusOffsets:
          useFilterFocusOffsets ?? this.useFilterFocusOffsets,
      autoFocusEveryMinutes:
          autoFocusEveryMinutes ?? this.autoFocusEveryMinutes,
      ditherEnabled: ditherEnabled ?? this.ditherEnabled,
      ditherEveryFrames: ditherEveryFrames ?? this.ditherEveryFrames,
      cameraRetries: cameraRetries ?? this.cameraRetries,
      filterWheelRetries: filterWheelRetries ?? this.filterWheelRetries,
      safetyFailMode: safetyFailMode ?? this.safetyFailMode,
      // Sequencer editor layout.
      sequencerToolboxCollapsed: identical(sequencerToolboxCollapsed, _unset)
          ? this.sequencerToolboxCollapsed
          : sequencerToolboxCollapsed as bool?,
      sequencerPropertiesCollapsed:
          identical(sequencerPropertiesCollapsed, _unset)
          ? this.sequencerPropertiesCollapsed
          : sequencerPropertiesCollapsed as bool?,
      sequencerSnippetPaletteVisible:
          identical(sequencerSnippetPaletteVisible, _unset)
          ? this.sequencerSnippetPaletteVisible
          : sequencerSnippetPaletteVisible as bool?,
      sequencerToolboxTab: identical(sequencerToolboxTab, _unset)
          ? this.sequencerToolboxTab
          : sequencerToolboxTab as String?,
      sequencerActiveTab: identical(sequencerActiveTab, _unset)
          ? this.sequencerActiveTab
          : sequencerActiveTab as int?,
      sequencerLeftPanelWidth: identical(sequencerLeftPanelWidth, _unset)
          ? this.sequencerLeftPanelWidth
          : sequencerLeftPanelWidth as double?,
      sequencerRightPanelWidth: identical(sequencerRightPanelWidth, _unset)
          ? this.sequencerRightPanelWidth
          : sequencerRightPanelWidth as double?,
      plateSolver: plateSolver ?? this.plateSolver,
      astapPath: astapPath ?? this.astapPath,
      astrometryPath: astrometryPath ?? this.astrometryPath,
      plateSolveTimeout: plateSolveTimeout ?? this.plateSolveTimeout,
      plateSolveSearchRadius:
          plateSolveSearchRadius ?? this.plateSolveSearchRadius,
      blindSolve: blindSolve ?? this.blindSolve,
      centeringSyncMount: centeringSyncMount ?? this.centeringSyncMount,
      phd2Path: phd2Path ?? this.phd2Path,
      phd2Host: phd2Host ?? this.phd2Host,
      phd2Port: phd2Port ?? this.phd2Port,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      discordWebhook: discordWebhook ?? this.discordWebhook,
      pushoverKey: pushoverKey ?? this.pushoverKey,
      pushoverUser: pushoverUser ?? this.pushoverUser,
      notifyOnSequenceComplete:
          notifyOnSequenceComplete ?? this.notifyOnSequenceComplete,
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
      // Remote Access / Web Server
      webServerEnabled: webServerEnabled ?? this.webServerEnabled,
      webServerPort: webServerPort ?? this.webServerPort,
      // Equipment Settings
      defaultGain: defaultGain ?? this.defaultGain,
      defaultOffset: defaultOffset ?? this.defaultOffset,
      enableMeridianFlip: enableMeridianFlip ?? this.enableMeridianFlip,
      tempCompensation: tempCompensation ?? this.tempCompensation,
      tempCoefficient: tempCoefficient ?? this.tempCoefficient,
      backlashCompensation: backlashCompensation ?? this.backlashCompensation,
      ditherScale: ditherScale ?? this.ditherScale,
      settleThreshold: settleThreshold ?? this.settleThreshold,
      settleTimeout: settleTimeout ?? this.settleTimeout,
      settleTime: settleTime ?? this.settleTime,
      ditherRaOnly: ditherRaOnly ?? this.ditherRaOnly,
      // Observing Environment
      bortleClass: bortleClass ?? this.bortleClass,
      horizonProfileJson: horizonProfileJson ?? this.horizonProfileJson,
      effectiveHorizonDeg: effectiveHorizonDeg ?? this.effectiveHorizonDeg,
      audibleAlertsOnCritical:
          audibleAlertsOnCritical ?? this.audibleAlertsOnCritical,
      criticalAlertSound: criticalAlertSound ?? this.criticalAlertSound,
      pushCriticalAlerts: pushCriticalAlerts ?? this.pushCriticalAlerts,
      // Recovery Mode
      recoveryDefaultRetryIntervalMins:
          recoveryDefaultRetryIntervalMins ??
          this.recoveryDefaultRetryIntervalMins,
      recoveryDefaultMaxDurationMins:
          recoveryDefaultMaxDurationMins ?? this.recoveryDefaultMaxDurationMins,
      recoveryStopTrackingDuringRecovery:
          recoveryStopTrackingDuringRecovery ??
          this.recoveryStopTrackingDuringRecovery,
      recoveryAbortOnMeridian:
          recoveryAbortOnMeridian ?? this.recoveryAbortOnMeridian,
      recoveryAudibleAlertWhenEntered:
          recoveryAudibleAlertWhenEntered ??
          this.recoveryAudibleAlertWhenEntered,
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
      afFailureHfrToleranceRatio:
          afFailureHfrToleranceRatio ?? this.afFailureHfrToleranceRatio,
      afDisableGuidingDuringAf:
          afDisableGuidingDuringAf ?? this.afDisableGuidingDuringAf,
      afFocuserSettleTimeMs:
          afFocuserSettleTimeMs ?? this.afFocuserSettleTimeMs,
      afExposuresPerPoint: afExposuresPerPoint ?? this.afExposuresPerPoint,
      afBacklashCompMethod: afBacklashCompMethod ?? this.afBacklashCompMethod,
      afBacklashIn: afBacklashIn ?? this.afBacklashIn,
      focuserBacklashOfferMode:
          focuserBacklashOfferMode ?? this.focuserBacklashOfferMode,
      focuserBacklashCalibrationJson:
          focuserBacklashCalibrationJson ?? this.focuserBacklashCalibrationJson,
      mountSiteSyncMode: mountSiteSyncMode ?? this.mountSiteSyncMode,
      afBacklashOut: afBacklashOut ?? this.afBacklashOut,
      afAutofocusFilterName:
          afAutofocusFilterName ?? this.afAutofocusFilterName,
      afFilterSettingsJson: afFilterSettingsJson ?? this.afFilterSettingsJson,
      // Observer name (FITS OBSERVER)
      observerName: observerName ?? this.observerName,
      // Image Grading
      enableImageGrading: enableImageGrading ?? this.enableImageGrading,
      imageGradingHfrThresholdPx: identical(imageGradingHfrThresholdPx, _unset)
          ? this.imageGradingHfrThresholdPx
          : imageGradingHfrThresholdPx as double?,
      imageGradingHfrBaselinePercent:
          identical(imageGradingHfrBaselinePercent, _unset)
          ? this.imageGradingHfrBaselinePercent
          : imageGradingHfrBaselinePercent as double?,
      imageGradingEccentricityThreshold:
          identical(imageGradingEccentricityThreshold, _unset)
          ? this.imageGradingEccentricityThreshold
          : imageGradingEccentricityThreshold as double?,
      imageGradingStarCountMin: identical(imageGradingStarCountMin, _unset)
          ? this.imageGradingStarCountMin
          : imageGradingStarCountMin as int?,
      imageGradingMaxConsecutiveRejects:
          imageGradingMaxConsecutiveRejects ??
          this.imageGradingMaxConsecutiveRejects,
      imageGradingRejectFolderPath:
          identical(imageGradingRejectFolderPath, _unset)
          ? this.imageGradingRejectFolderPath
          : imageGradingRejectFolderPath as String?,
      // Sky-brightness adaptive exposure
      adaptiveExposureEnabled:
          adaptiveExposureEnabled ?? this.adaptiveExposureEnabled,
      adaptiveExposureTargetSnr:
          adaptiveExposureTargetSnr ?? this.adaptiveExposureTargetSnr,
      adaptiveExposureReferenceMag:
          adaptiveExposureReferenceMag ?? this.adaptiveExposureReferenceMag,
      adaptiveExposureMinSecs:
          adaptiveExposureMinSecs ?? this.adaptiveExposureMinSecs,
      adaptiveExposureMaxSecs:
          adaptiveExposureMaxSecs ?? this.adaptiveExposureMaxSecs,
      adaptiveExposurePerFilterEnabled:
          adaptiveExposurePerFilterEnabled ??
          this.adaptiveExposurePerFilterEnabled,
      adaptiveExposurePerFilterMinSecs:
          adaptiveExposurePerFilterMinSecs ??
          this.adaptiveExposurePerFilterMinSecs,
      adaptiveExposurePerFilterMaxSecs:
          adaptiveExposurePerFilterMaxSecs ??
          this.adaptiveExposurePerFilterMaxSecs,
      // Pre-flight
      preflightStrictness: preflightStrictness ?? this.preflightStrictness,
      polarAlignmentMaxAgeDays:
          polarAlignmentMaxAgeDays ?? this.polarAlignmentMaxAgeDays,
      darkLibraryMinCoverage:
          darkLibraryMinCoverage ?? this.darkLibraryMinCoverage,
      opticalTrainDriftThreshold:
          opticalTrainDriftThreshold ?? this.opticalTrainDriftThreshold,
      // Smart Night defaults.
      smartNightMaxSessionHours: identical(smartNightMaxSessionHours, _unset)
          ? this.smartNightMaxSessionHours
          : smartNightMaxSessionHours as double?,
      smartNightDefaultAfCadenceFrames:
          smartNightDefaultAfCadenceFrames ??
          this.smartNightDefaultAfCadenceFrames,
      smartNightDefaultIntegrationBudgetMinsPerTarget:
          smartNightDefaultIntegrationBudgetMinsPerTarget ??
          this.smartNightDefaultIntegrationBudgetMinsPerTarget,
      smartNightIncludeFlatsAtEnd:
          smartNightIncludeFlatsAtEnd ?? this.smartNightIncludeFlatsAtEnd,
      smartNightUseSchedulerForMultiTarget:
          smartNightUseSchedulerForMultiTarget ??
          this.smartNightUseSchedulerForMultiTarget,
      smartNightSchedulerTargetThreshold:
          smartNightSchedulerTargetThreshold ??
          this.smartNightSchedulerTargetThreshold,
      smartNightDefaultStrategy:
          smartNightDefaultStrategy ?? this.smartNightDefaultStrategy,
      smartNightPolarAlignmentStaleAfterDays:
          smartNightPolarAlignmentStaleAfterDays ??
          this.smartNightPolarAlignmentStaleAfterDays,
      smartNightSubExposureFloorSecs:
          smartNightSubExposureFloorSecs ?? this.smartNightSubExposureFloorSecs,
      smartNightSubExposureCeilingSecs:
          smartNightSubExposureCeilingSecs ??
          this.smartNightSubExposureCeilingSecs,
      smartNightTargetSnr: smartNightTargetSnr ?? this.smartNightTargetSnr,
      smartNightAutoPromptEnabled:
          smartNightAutoPromptEnabled ?? this.smartNightAutoPromptEnabled,
      smartNightAutoSelect: smartNightAutoSelect ?? this.smartNightAutoSelect,
      smartNightAutoSelectCount:
          smartNightAutoSelectCount ?? this.smartNightAutoSelectCount,
      smartNightPromptDismissedDayKey:
          smartNightPromptDismissedDayKey ??
          this.smartNightPromptDismissedDayKey,
      // Notes prompt toggle.
      promptForNotesAfterRun:
          promptForNotesAfterRun ?? this.promptForNotesAfterRun,
      // Session lifecycle.
      sessionHandoffAutoPrompt:
          sessionHandoffAutoPrompt ?? this.sessionHandoffAutoPrompt,
      campaignRollupSurfaceTargetsTab:
          campaignRollupSurfaceTargetsTab ??
          this.campaignRollupSurfaceTargetsTab,
      campaignRollupGroupingMode:
          campaignRollupGroupingMode ?? this.campaignRollupGroupingMode,
      // Adaptive sky-conditions defaults.
      adaptiveSwapEnabledByDefault:
          adaptiveSwapEnabledByDefault ?? this.adaptiveSwapEnabledByDefault,
      adaptiveSwapDefaultThreshold:
          adaptiveSwapDefaultThreshold ?? this.adaptiveSwapDefaultThreshold,
      adaptiveSwapDefaultHysteresisSecs:
          adaptiveSwapDefaultHysteresisSecs ??
          this.adaptiveSwapDefaultHysteresisSecs,
      conditionsScoreWeights:
          conditionsScoreWeights ?? this.conditionsScoreWeights,
    );
  }
}
