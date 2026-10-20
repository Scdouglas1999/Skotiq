part of '../settings_provider.dart';

extension _AppSettingsRemoteMapping on AppSettingsNotifier {
  AppSettingsState _fromRemoteSettings(models.AppSettings remote) {
    final location = remote.location;
    return AppSettingsState(
      autoConnectEquipment: remote.autoConnect,
      autoDiscoverOnLaunch: remote.autoDiscoverOnLaunch,
      theme: remote.theme,
      language: remote.language,
      accentColor: remote.accentColor.isEmpty
          ? kDefaultAccentColorHex
          : remote.accentColor,
      fontSize: remote.fontSize,
      uiScale: remote.uiScale,
      latitude: location?.latitude ?? remote.latitude,
      longitude: location?.longitude ?? remote.longitude,
      elevation: location?.elevation ?? remote.elevation,
      fileNamingPattern: remote.fileNamingPattern.isEmpty
          ? r'$TARGET_$FILTER_$DATE_$SEQ'
          : remote.fileNamingPattern,
      meridianFlipMinutes: remote.meridianFlipMinutes,
      autoFocusEveryMinutes: remote.autoFocusEveryMinutes,
      ditherEveryFrames: remote.ditherEveryFrames,
      cameraRetries: remote.cameraRetries.clamp(0, kMaxDeviceRetries),
      filterWheelRetries: remote.filterWheelRetries.clamp(0, kMaxDeviceRetries),
      plateSolveTimeout: remote.plateSolveTimeout,
      plateSolveSearchRadius: remote.plateSolveSearchRadius,
      discordWebhook: remote.discordWebhook,
      pushoverKey: remote.pushoverKey,
      pushoverUser: remote.pushoverUser,
      astapPath: remote.astapPath,
      indiServerHost: remote.indiServerHost,
      indiServerPort: remote.indiServerPort,
      indiAutoConnect: remote.indiAutoConnect,
      alpacaServerHost: remote.alpacaServerHost,
      alpacaServerPort: remote.alpacaServerPort,
      alpacaAutoDiscover: remote.alpacaAutoDiscover,
      imageOutputPath: remote.imageOutputPath,
      safetyFailMode: remote.safetyFailMode,
      // Image Grading — carried by the wire model so an unattended
      // night driven from a phone keeps its Pass/Reject thresholds.
      enableImageGrading: remote.enableImageGrading,
      imageGradingHfrThresholdPx: remote.imageGradingHfrThresholdPx,
      imageGradingHfrBaselinePercent: remote.imageGradingHfrBaselinePercent,
      imageGradingEccentricityThreshold:
          remote.imageGradingEccentricityThreshold,
      imageGradingStarCountMin: remote.imageGradingStarCountMin,
      imageGradingMaxConsecutiveRejects:
          remote.imageGradingMaxConsecutiveRejects,
      imageGradingRejectFolderPath: remote.imageGradingRejectFolderPath,
      // Sky-brightness adaptive exposure — global defaults + per-filter
      // overrides round-trip so adaptive subs work when planned remotely.
      adaptiveExposureEnabled: remote.adaptiveExposureEnabled,
      adaptiveExposureTargetSnr: remote.adaptiveExposureTargetSnr,
      adaptiveExposureReferenceMag: remote.adaptiveExposureReferenceMag,
      adaptiveExposureMinSecs: remote.adaptiveExposureMinSecs,
      adaptiveExposureMaxSecs: remote.adaptiveExposureMaxSecs,
      adaptiveExposurePerFilterEnabled: Map<String, bool>.from(
        remote.adaptiveExposurePerFilterEnabled,
      ),
      adaptiveExposurePerFilterMinSecs: Map<String, double>.from(
        remote.adaptiveExposurePerFilterMinSecs,
      ),
      adaptiveExposurePerFilterMaxSecs: Map<String, double>.from(
        remote.adaptiveExposurePerFilterMaxSecs,
      ),
      // Full-night audit 2026-06-04 follow-up — high-value unattended-night
      // knobs (autofocus / dither / weather-safety / recovery) now carried by
      // the wire model so a phone-driven night keeps them.
      parkOnUnsafeWeather: remote.parkOnUnsafeWeather,
      autoFocusOnFilterChange: remote.autoFocusOnFilterChange,
      afDisableGuidingDuringAf: remote.afDisableGuidingDuringAf,
      ditherEnabled: remote.ditherEnabled,
      ditherScale: remote.ditherScale,
      recoveryDefaultRetryIntervalMins: remote.recoveryDefaultRetryIntervalMins,
      recoveryDefaultMaxDurationMins: remote.recoveryDefaultMaxDurationMins,
      recoveryStopTrackingDuringRecovery:
          remote.recoveryStopTrackingDuringRecovery,
      recoveryAbortOnMeridian: remote.recoveryAbortOnMeridian,
      recoveryAudibleAlertWhenEntered: remote.recoveryAudibleAlertWhenEntered,
      // Full-night audit 2026-06-04 follow-up (long tail).
      parkBeforeDawn: remote.parkBeforeDawn,
      stopRunOnQualityProblems: remote.stopRunOnQualityProblems,
      enableMeridianFlip: remote.enableMeridianFlip,
      tempCompensation: remote.tempCompensation,
      tempCoefficient: remote.tempCoefficient,
      backlashCompensation: remote.backlashCompensation,
      settleThreshold: remote.settleThreshold,
      settleTimeout: remote.settleTimeout,
      settleTime: remote.settleTime,
      ditherRaOnly: remote.ditherRaOnly,
      plateSolver: remote.plateSolver,
      blindSolve: remote.blindSolve,
      centeringSyncMount: remote.centeringSyncMount,
      bortleClass: remote.bortleClass,
      effectiveHorizonDeg: remote.effectiveHorizonDeg,
      preflightStrictness: _parsePreflightStrictness(
        remote.preflightStrictness,
      ),
      polarAlignmentMaxAgeDays: remote.polarAlignmentMaxAgeDays,
      opticalTrainDriftThreshold: remote.opticalTrainDriftThreshold,
      darkLibraryMinCoverage: remote.darkLibraryMinCoverage,
      smartNightMaxSessionHours: remote.smartNightMaxSessionHours,
      smartNightDefaultAfCadenceFrames: remote.smartNightDefaultAfCadenceFrames,
      smartNightDefaultIntegrationBudgetMinsPerTarget:
          remote.smartNightDefaultIntegrationBudgetMinsPerTarget,
      smartNightIncludeFlatsAtEnd: remote.smartNightIncludeFlatsAtEnd,
      smartNightUseSchedulerForMultiTarget:
          remote.smartNightUseSchedulerForMultiTarget,
      smartNightSchedulerTargetThreshold:
          remote.smartNightSchedulerTargetThreshold,
      smartNightDefaultStrategy: remote.smartNightDefaultStrategy,
      smartNightPolarAlignmentStaleAfterDays:
          remote.smartNightPolarAlignmentStaleAfterDays,
      smartNightSubExposureFloorSecs: remote.smartNightSubExposureFloorSecs,
      smartNightSubExposureCeilingSecs: remote.smartNightSubExposureCeilingSecs,
      smartNightTargetSnr: remote.smartNightTargetSnr,
      // Full remote-settings parity 2026-06-05 — remaining unattended-night
      // knobs (equipment defaults / web-server / PHD2 / notifications /
      // session-lifecycle + campaign-rollup / detailed autofocus sweep / misc
      // FITS+imaging config) now round-trip through the wire model.
      defaultGain: remote.defaultGain,
      defaultOffset: remote.defaultOffset,
      webServerEnabled: remote.webServerEnabled,
      webServerPort: remote.webServerPort,
      phd2Path: remote.phd2Path,
      phd2Host: remote.phd2Host,
      phd2Port: remote.phd2Port,
      notificationsEnabled: remote.notificationsEnabled,
      notifyOnSequenceComplete: remote.notifyOnSequenceComplete,
      notifyOnError: remote.notifyOnError,
      notifyOnMeridianFlip: remote.notifyOnMeridianFlip,
      soundEnabled: remote.soundEnabled,
      audibleAlertsOnCritical: remote.audibleAlertsOnCritical,
      criticalAlertSound: remote.criticalAlertSound,
      pushCriticalAlerts: remote.pushCriticalAlerts,
      promptForNotesAfterRun: remote.promptForNotesAfterRun,
      sessionHandoffAutoPrompt: remote.sessionHandoffAutoPrompt,
      campaignRollupSurfaceTargetsTab: remote.campaignRollupSurfaceTargetsTab,
      campaignRollupGroupingMode: remote.campaignRollupGroupingMode,
      afMethod: remote.afMethod,
      afCurveFitting: remote.afCurveFitting,
      afStepSize: remote.afStepSize,
      afExposureTime: remote.afExposureTime,
      afInitialOffsetSteps: remote.afInitialOffsetSteps,
      afNumberOfAttempts: remote.afNumberOfAttempts,
      afUseBrightestNStars: remote.afUseBrightestNStars,
      afOuterCropRatio: remote.afOuterCropRatio,
      afInnerCropRatio: remote.afInnerCropRatio,
      afBinning: remote.afBinning,
      afRSquaredThreshold: remote.afRSquaredThreshold,
      afFailureHfrToleranceRatio: remote.afFailureHfrToleranceRatio,
      afFocuserSettleTimeMs: remote.afFocuserSettleTimeMs,
      afExposuresPerPoint: remote.afExposuresPerPoint,
      afBacklashCompMethod: remote.afBacklashCompMethod,
      afBacklashIn: remote.afBacklashIn,
      afBacklashOut: remote.afBacklashOut,
      afAutofocusFilterName: remote.afAutofocusFilterName,
      afFilterSettingsJson: remote.afFilterSettingsJson,
      // The operator's tuned backlash-calibration settings round-trip so a
      // phone-driven night measures with the same geometry.
      focuserBacklashCalibrationJson: remote.focuserBacklashCalibrationJson,
      useFilterFocusOffsets: remote.useFilterFocusOffsets,
      astrometryPath: remote.astrometryPath,
      observerName: remote.observerName,
      imageFormat: _normalizeCaptureImageFormat(remote.imageFormat),
      bitDepth: _normalizeCaptureBitDepth(remote.bitDepth),
      timezone: remote.timezone,
      useSystemTime: remote.useSystemTime,
      // Settings round-trip gap closure (G5 / G7) — sequencer output path,
      // smart-night auto-select, and the adaptive-swap scheduler-seed
      // defaults now round-trip so they survive a phone-driven night.
      sequencesPath: remote.sequencesPath,
      smartNightAutoSelect: remote.smartNightAutoSelect,
      smartNightAutoSelectCount: remote.smartNightAutoSelectCount,
      adaptiveSwapEnabledByDefault: remote.adaptiveSwapEnabledByDefault,
      adaptiveSwapDefaultThreshold: remote.adaptiveSwapDefaultThreshold,
      adaptiveSwapDefaultHysteresisSecs:
          remote.adaptiveSwapDefaultHysteresisSecs,
      conditionsScoreWeights: Map<String, double>.from(
        remote.conditionsScoreWeights,
      ),
    );
  }

  models.AppSettings _toRemoteSettings(AppSettingsState settings) {
    final previous = _remoteSettingsSnapshot;
    return models.AppSettings(
      location: models.ObserverLocation(
        latitude: settings.latitude,
        longitude: settings.longitude,
        elevation: settings.elevation,
      ),
      theme: settings.theme,
      language: settings.language,
      autoConnect: settings.autoConnectEquipment,
      latitude: settings.latitude,
      longitude: settings.longitude,
      elevation: settings.elevation,
      fileNamingPattern: settings.fileNamingPattern,
      meridianFlipMinutes: settings.meridianFlipMinutes,
      autoFocusEveryMinutes: settings.autoFocusEveryMinutes,
      ditherEveryFrames: settings.ditherEveryFrames,
      cameraRetries: settings.cameraRetries,
      filterWheelRetries: settings.filterWheelRetries,
      plateSolveTimeout: settings.plateSolveTimeout,
      plateSolveSearchRadius: settings.plateSolveSearchRadius,
      discordWebhook: settings.discordWebhook,
      pushoverKey: settings.pushoverKey,
      pushoverUser: settings.pushoverUser,
      astapPath: settings.astapPath,
      autoDiscoverOnLaunch: settings.autoDiscoverOnLaunch,
      accentColor: settings.accentColor,
      fontSize: settings.fontSize,
      uiScale: settings.uiScale,
      indiServerHost: settings.indiServerHost,
      indiServerPort: settings.indiServerPort,
      indiAutoConnect: settings.indiAutoConnect,
      alpacaServerHost: settings.alpacaServerHost,
      alpacaServerPort: settings.alpacaServerPort,
      alpacaAutoDiscover: settings.alpacaAutoDiscover,
      imageOutputPath: settings.imageOutputPath,
      observer: previous?.observer ?? '',
      telescope: previous?.telescope ?? '',
      instrument: previous?.instrument ?? '',
      updateCheckEnabled: previous?.updateCheckEnabled ?? true,
      updateServerUrl: previous?.updateServerUrl ?? '',
      updateChannel: previous?.updateChannel ?? 'stable',
      updateCheckIntervalHours: previous?.updateCheckIntervalHours ?? 24,
      skippedUpdateVersion: previous?.skippedUpdateVersion ?? '',
      safetyFailMode: settings.safetyFailMode,
      // Image Grading — push the live thresholds to the host so a
      // remote save doesn't silently revert them to model defaults.
      enableImageGrading: settings.enableImageGrading,
      imageGradingHfrThresholdPx: settings.imageGradingHfrThresholdPx,
      imageGradingHfrBaselinePercent: settings.imageGradingHfrBaselinePercent,
      imageGradingEccentricityThreshold:
          settings.imageGradingEccentricityThreshold,
      imageGradingStarCountMin: settings.imageGradingStarCountMin,
      imageGradingMaxConsecutiveRejects:
          settings.imageGradingMaxConsecutiveRejects,
      imageGradingRejectFolderPath: settings.imageGradingRejectFolderPath,
      // Sky-brightness adaptive exposure.
      adaptiveExposureEnabled: settings.adaptiveExposureEnabled,
      adaptiveExposureTargetSnr: settings.adaptiveExposureTargetSnr,
      adaptiveExposureReferenceMag: settings.adaptiveExposureReferenceMag,
      adaptiveExposureMinSecs: settings.adaptiveExposureMinSecs,
      adaptiveExposureMaxSecs: settings.adaptiveExposureMaxSecs,
      adaptiveExposurePerFilterEnabled: Map<String, bool>.from(
        settings.adaptiveExposurePerFilterEnabled,
      ),
      adaptiveExposurePerFilterMinSecs: Map<String, double>.from(
        settings.adaptiveExposurePerFilterMinSecs,
      ),
      adaptiveExposurePerFilterMaxSecs: Map<String, double>.from(
        settings.adaptiveExposurePerFilterMaxSecs,
      ),
      // Full-night audit 2026-06-04 follow-up — push the live unattended-night
      // knobs to the host so a remote save doesn't silently drop them.
      parkOnUnsafeWeather: settings.parkOnUnsafeWeather,
      autoFocusOnFilterChange: settings.autoFocusOnFilterChange,
      afDisableGuidingDuringAf: settings.afDisableGuidingDuringAf,
      ditherEnabled: settings.ditherEnabled,
      ditherScale: settings.ditherScale,
      recoveryDefaultRetryIntervalMins:
          settings.recoveryDefaultRetryIntervalMins,
      recoveryDefaultMaxDurationMins: settings.recoveryDefaultMaxDurationMins,
      recoveryStopTrackingDuringRecovery:
          settings.recoveryStopTrackingDuringRecovery,
      recoveryAbortOnMeridian: settings.recoveryAbortOnMeridian,
      recoveryAudibleAlertWhenEntered: settings.recoveryAudibleAlertWhenEntered,
      // Full-night audit 2026-06-04 follow-up (long tail) — push the remaining
      // unattended-night knobs to the host so a remote save keeps them.
      parkBeforeDawn: settings.parkBeforeDawn,
      stopRunOnQualityProblems: settings.stopRunOnQualityProblems,
      enableMeridianFlip: settings.enableMeridianFlip,
      tempCompensation: settings.tempCompensation,
      tempCoefficient: settings.tempCoefficient,
      backlashCompensation: settings.backlashCompensation,
      settleThreshold: settings.settleThreshold,
      settleTimeout: settings.settleTimeout,
      settleTime: settings.settleTime,
      ditherRaOnly: settings.ditherRaOnly,
      plateSolver: settings.plateSolver,
      blindSolve: settings.blindSolve,
      centeringSyncMount: settings.centeringSyncMount,
      bortleClass: settings.bortleClass,
      effectiveHorizonDeg: settings.effectiveHorizonDeg,
      // PreflightStrictness lives in the provider library; carry its `.name` so
      // the wire model stays free of that dependency.
      preflightStrictness: settings.preflightStrictness.name,
      polarAlignmentMaxAgeDays: settings.polarAlignmentMaxAgeDays,
      opticalTrainDriftThreshold: settings.opticalTrainDriftThreshold,
      darkLibraryMinCoverage: settings.darkLibraryMinCoverage,
      smartNightMaxSessionHours: settings.smartNightMaxSessionHours,
      smartNightDefaultAfCadenceFrames:
          settings.smartNightDefaultAfCadenceFrames,
      smartNightDefaultIntegrationBudgetMinsPerTarget:
          settings.smartNightDefaultIntegrationBudgetMinsPerTarget,
      smartNightIncludeFlatsAtEnd: settings.smartNightIncludeFlatsAtEnd,
      smartNightUseSchedulerForMultiTarget:
          settings.smartNightUseSchedulerForMultiTarget,
      smartNightSchedulerTargetThreshold:
          settings.smartNightSchedulerTargetThreshold,
      smartNightDefaultStrategy: settings.smartNightDefaultStrategy,
      smartNightPolarAlignmentStaleAfterDays:
          settings.smartNightPolarAlignmentStaleAfterDays,
      smartNightSubExposureFloorSecs: settings.smartNightSubExposureFloorSecs,
      smartNightSubExposureCeilingSecs:
          settings.smartNightSubExposureCeilingSecs,
      smartNightTargetSnr: settings.smartNightTargetSnr,
      // Full remote-settings parity 2026-06-05 — push the remaining live
      // unattended-night knobs to the host so a remote save doesn't silently
      // drop them.
      defaultGain: settings.defaultGain,
      defaultOffset: settings.defaultOffset,
      webServerEnabled: settings.webServerEnabled,
      webServerPort: settings.webServerPort,
      phd2Path: settings.phd2Path,
      phd2Host: settings.phd2Host,
      phd2Port: settings.phd2Port,
      notificationsEnabled: settings.notificationsEnabled,
      notifyOnSequenceComplete: settings.notifyOnSequenceComplete,
      notifyOnError: settings.notifyOnError,
      notifyOnMeridianFlip: settings.notifyOnMeridianFlip,
      soundEnabled: settings.soundEnabled,
      audibleAlertsOnCritical: settings.audibleAlertsOnCritical,
      criticalAlertSound: settings.criticalAlertSound,
      pushCriticalAlerts: settings.pushCriticalAlerts,
      promptForNotesAfterRun: settings.promptForNotesAfterRun,
      sessionHandoffAutoPrompt: settings.sessionHandoffAutoPrompt,
      campaignRollupSurfaceTargetsTab: settings.campaignRollupSurfaceTargetsTab,
      campaignRollupGroupingMode: settings.campaignRollupGroupingMode,
      afMethod: settings.afMethod,
      afCurveFitting: settings.afCurveFitting,
      afStepSize: settings.afStepSize,
      afExposureTime: settings.afExposureTime,
      afInitialOffsetSteps: settings.afInitialOffsetSteps,
      afNumberOfAttempts: settings.afNumberOfAttempts,
      afUseBrightestNStars: settings.afUseBrightestNStars,
      afOuterCropRatio: settings.afOuterCropRatio,
      afInnerCropRatio: settings.afInnerCropRatio,
      afBinning: settings.afBinning,
      afRSquaredThreshold: settings.afRSquaredThreshold,
      afFailureHfrToleranceRatio: settings.afFailureHfrToleranceRatio,
      afFocuserSettleTimeMs: settings.afFocuserSettleTimeMs,
      afExposuresPerPoint: settings.afExposuresPerPoint,
      afBacklashCompMethod: settings.afBacklashCompMethod,
      afBacklashIn: settings.afBacklashIn,
      afBacklashOut: settings.afBacklashOut,
      afAutofocusFilterName: settings.afAutofocusFilterName,
      afFilterSettingsJson: settings.afFilterSettingsJson,
      focuserBacklashCalibrationJson: settings.focuserBacklashCalibrationJson,
      useFilterFocusOffsets: settings.useFilterFocusOffsets,
      astrometryPath: settings.astrometryPath,
      observerName: settings.observerName,
      imageFormat: settings.imageFormat,
      bitDepth: settings.bitDepth,
      timezone: settings.timezone,
      useSystemTime: settings.useSystemTime,
      // Settings round-trip gap closure (G5 / G7) — push the live values to
      // the host so a remote save doesn't silently drop them.
      sequencesPath: settings.sequencesPath,
      smartNightAutoSelect: settings.smartNightAutoSelect,
      smartNightAutoSelectCount: settings.smartNightAutoSelectCount,
      adaptiveSwapEnabledByDefault: settings.adaptiveSwapEnabledByDefault,
      adaptiveSwapDefaultThreshold: settings.adaptiveSwapDefaultThreshold,
      adaptiveSwapDefaultHysteresisSecs:
          settings.adaptiveSwapDefaultHysteresisSecs,
      conditionsScoreWeights: Map<String, double>.from(
        settings.conditionsScoreWeights,
      ),
    );
  }

  /// Translate a single JSON-shaped `(key, value)` from the server into
  /// a copyWith on the in-memory [AppSettingsState]. Unknown keys are a
  /// no-op (a newer host may carry settings this build does not yet
  /// know about — silent skipping preserves forward-compatibility).
  ///
  /// Returns null when the value parses to something the current state
  /// already has — caller checks for that to avoid pointless rebuilds.
  AppSettingsState? _applyJsonSettingChange(
    AppSettingsState current,
    String key,
    dynamic value,
  ) {
    // The keys mirror `models.AppSettings.toJson()` — which is the freezed
    // JSON projection — NOT the database column names. The settings provider
    // already has `_applySettingsMap` for the db-column form; here we only
    // need to handle the remote-JSON form for the keys that round-trip.
    switch (key) {
      case 'theme':
        return value is String ? current.copyWith(theme: value) : null;
      case 'language':
        return value is String ? current.copyWith(language: value) : null;
      case 'autoConnect':
        return value is bool
            ? current.copyWith(autoConnectEquipment: value)
            : null;
      case 'autoDiscoverOnLaunch':
        return value is bool
            ? current.copyWith(autoDiscoverOnLaunch: value)
            : null;
      case 'latitude':
        return value is num
            ? current.copyWith(latitude: value.toDouble())
            : null;
      case 'longitude':
        return value is num
            ? current.copyWith(longitude: value.toDouble())
            : null;
      case 'elevation':
        return value is num
            ? current.copyWith(elevation: value.toDouble())
            : null;
      case 'fileNamingPattern':
        return value is String
            ? current.copyWith(fileNamingPattern: value)
            : null;
      case 'meridianFlipMinutes':
        return value is num
            ? current.copyWith(meridianFlipMinutes: value.toInt())
            : null;
      case 'autoFocusEveryMinutes':
        return value is num
            ? current.copyWith(autoFocusEveryMinutes: value.toInt())
            : null;
      case 'ditherEveryFrames':
        return value is num
            ? current.copyWith(ditherEveryFrames: value.toInt())
            : null;
      case 'cameraRetries':
        return value is num
            ? current.copyWith(
                cameraRetries: value.toInt().clamp(0, kMaxDeviceRetries),
              )
            : null;
      case 'filterWheelRetries':
        return value is num
            ? current.copyWith(
                filterWheelRetries: value.toInt().clamp(0, kMaxDeviceRetries),
              )
            : null;
      case 'plateSolveTimeout':
        return value is num
            ? current.copyWith(plateSolveTimeout: value.toInt())
            : null;
      case 'plateSolveSearchRadius':
        return value is num
            ? current.copyWith(plateSolveSearchRadius: value.toDouble())
            : null;
      case 'accentColor':
        return value is String ? current.copyWith(accentColor: value) : null;
      case 'fontSize':
        return value is String ? current.copyWith(fontSize: value) : null;
      case 'uiScale':
        return value is String ? current.copyWith(uiScale: value) : null;
      // Not a wire key: `_overlayDeviceLocalDisplayPrefs` replays the
      // device-local DAO value (stored as its 'true'/'false' string) under
      // the DB column name after a remote (re)connect.
      case 'sidebar_collapsed':
        return value is String
            ? current.copyWith(sidebarCollapsed: value == 'true')
            : null;
      case 'discordWebhook':
        return value is String ? current.copyWith(discordWebhook: value) : null;
      case 'pushoverKey':
        return value is String ? current.copyWith(pushoverKey: value) : null;
      case 'pushoverUser':
        return value is String ? current.copyWith(pushoverUser: value) : null;
      case 'astapPath':
        return value is String ? current.copyWith(astapPath: value) : null;
      case 'indiServerHost':
        return value is String ? current.copyWith(indiServerHost: value) : null;
      case 'indiServerPort':
        return value is num
            ? current.copyWith(indiServerPort: value.toInt())
            : null;
      case 'indiAutoConnect':
        return value is bool ? current.copyWith(indiAutoConnect: value) : null;
      case 'alpacaServerHost':
        return value is String
            ? current.copyWith(alpacaServerHost: value)
            : null;
      case 'alpacaServerPort':
        return value is num
            ? current.copyWith(alpacaServerPort: value.toInt())
            : null;
      case 'alpacaAutoDiscover':
        return value is bool
            ? current.copyWith(alpacaAutoDiscover: value)
            : null;
      case 'imageOutputPath':
        return value is String
            ? current.copyWith(imageOutputPath: value)
            : null;
      case 'safetyFailMode':
        if (value is String) {
          return current.copyWith(safetyFailMode: _parseSafetyFailMode(value));
        }
        return null;
      // Image Grading — keys mirror models.AppSettings.toJson().
      // The nullable threshold fields accept `null` explicitly (user cleared
      // the field) which copyWith honours via its `_unset` sentinel pattern.
      case 'enableImageGrading':
        return value is bool
            ? current.copyWith(enableImageGrading: value)
            : null;
      case 'imageGradingHfrThresholdPx':
        if (value == null) {
          return current.copyWith(imageGradingHfrThresholdPx: null);
        }
        return value is num
            ? current.copyWith(imageGradingHfrThresholdPx: value.toDouble())
            : null;
      case 'imageGradingHfrBaselinePercent':
        if (value == null) {
          return current.copyWith(imageGradingHfrBaselinePercent: null);
        }
        return value is num
            ? current.copyWith(imageGradingHfrBaselinePercent: value.toDouble())
            : null;
      case 'imageGradingEccentricityThreshold':
        if (value == null) {
          return current.copyWith(imageGradingEccentricityThreshold: null);
        }
        return value is num
            ? current.copyWith(
                imageGradingEccentricityThreshold: value.toDouble(),
              )
            : null;
      case 'imageGradingStarCountMin':
        if (value == null) {
          return current.copyWith(imageGradingStarCountMin: null);
        }
        return value is num
            ? current.copyWith(imageGradingStarCountMin: value.toInt())
            : null;
      case 'imageGradingMaxConsecutiveRejects':
        return value is num
            ? current.copyWith(imageGradingMaxConsecutiveRejects: value.toInt())
            : null;
      case 'imageGradingRejectFolderPath':
        if (value == null) {
          return current.copyWith(imageGradingRejectFolderPath: null);
        }
        return value is String
            ? current.copyWith(imageGradingRejectFolderPath: value)
            : null;
      // Sky-brightness adaptive exposure.
      case 'adaptiveExposureEnabled':
        return value is bool
            ? current.copyWith(adaptiveExposureEnabled: value)
            : null;
      case 'adaptiveExposureTargetSnr':
        return value is num
            ? current.copyWith(adaptiveExposureTargetSnr: value.toDouble())
            : null;
      case 'adaptiveExposureReferenceMag':
        return value is num
            ? current.copyWith(adaptiveExposureReferenceMag: value.toDouble())
            : null;
      case 'adaptiveExposureMinSecs':
        return value is num
            ? current.copyWith(adaptiveExposureMinSecs: value.toDouble())
            : null;
      case 'adaptiveExposureMaxSecs':
        return value is num
            ? current.copyWith(adaptiveExposureMaxSecs: value.toDouble())
            : null;
      case 'adaptiveExposurePerFilterEnabled':
        return value is Map
            ? current.copyWith(
                adaptiveExposurePerFilterEnabled: value.map(
                  (k, v) => MapEntry(k.toString(), v == true),
                ),
              )
            : null;
      case 'adaptiveExposurePerFilterMinSecs':
        return value is Map
            ? current.copyWith(
                adaptiveExposurePerFilterMinSecs: value.map(
                  (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
                ),
              )
            : null;
      case 'adaptiveExposurePerFilterMaxSecs':
        return value is Map
            ? current.copyWith(
                adaptiveExposurePerFilterMaxSecs: value.map(
                  (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
                ),
              )
            : null;
      // Full-night audit 2026-06-04 follow-up — keys mirror
      // models.AppSettings.toJson() (camelCase). High-value unattended-night
      // knobs pushed live from the host via the settings.changed event.
      case 'parkOnUnsafeWeather':
        return value is bool
            ? current.copyWith(parkOnUnsafeWeather: value)
            : null;
      case 'autoFocusOnFilterChange':
        return value is bool
            ? current.copyWith(autoFocusOnFilterChange: value)
            : null;
      case 'afDisableGuidingDuringAf':
        return value is bool
            ? current.copyWith(afDisableGuidingDuringAf: value)
            : null;
      case 'ditherEnabled':
        return value is bool ? current.copyWith(ditherEnabled: value) : null;
      case 'ditherScale':
        return value is String ? current.copyWith(ditherScale: value) : null;
      case 'recoveryDefaultRetryIntervalMins':
        return value is num
            ? current.copyWith(
                recoveryDefaultRetryIntervalMins: value.toDouble(),
              )
            : null;
      case 'recoveryDefaultMaxDurationMins':
        return value is num
            ? current.copyWith(recoveryDefaultMaxDurationMins: value.toDouble())
            : null;
      case 'recoveryStopTrackingDuringRecovery':
        return value is bool
            ? current.copyWith(recoveryStopTrackingDuringRecovery: value)
            : null;
      case 'recoveryAbortOnMeridian':
        return value is bool
            ? current.copyWith(recoveryAbortOnMeridian: value)
            : null;
      case 'recoveryAudibleAlertWhenEntered':
        return value is bool
            ? current.copyWith(recoveryAudibleAlertWhenEntered: value)
            : null;
      // Full-night audit 2026-06-04 follow-up (long tail). Keys mirror
      // models.AppSettings.toJson() (camelCase).
      case 'parkBeforeDawn':
        return value is bool ? current.copyWith(parkBeforeDawn: value) : null;
      case 'stopRunOnQualityProblems':
        return value is bool
            ? current.copyWith(stopRunOnQualityProblems: value)
            : null;
      case 'enableMeridianFlip':
        return value is bool
            ? current.copyWith(enableMeridianFlip: value)
            : null;
      case 'tempCompensation':
        return value is bool ? current.copyWith(tempCompensation: value) : null;
      case 'tempCoefficient':
        return value is num
            ? current.copyWith(tempCoefficient: value.toDouble())
            : null;
      case 'backlashCompensation':
        return value is num
            ? current.copyWith(backlashCompensation: value.toInt())
            : null;
      case 'settleThreshold':
        return value is num
            ? current.copyWith(settleThreshold: value.toDouble())
            : null;
      case 'settleTimeout':
        return value is num
            ? current.copyWith(settleTimeout: value.toInt())
            : null;
      case 'settleTime':
        return value is num
            ? current.copyWith(settleTime: value.toInt())
            : null;
      case 'ditherRaOnly':
        return value is bool ? current.copyWith(ditherRaOnly: value) : null;
      case 'plateSolver':
        return value is String ? current.copyWith(plateSolver: value) : null;
      case 'blindSolve':
        return value is bool ? current.copyWith(blindSolve: value) : null;
      case 'centeringSyncMount':
        return value is bool
            ? current.copyWith(centeringSyncMount: value)
            : null;
      case 'bortleClass':
        return value is num
            ? current.copyWith(bortleClass: value.toInt())
            : null;
      case 'effectiveHorizonDeg':
        return value is num
            ? current.copyWith(effectiveHorizonDeg: value.toDouble())
            : null;
      case 'preflightStrictness':
        return value is String
            ? current.copyWith(
                preflightStrictness: _parsePreflightStrictness(value),
              )
            : null;
      case 'polarAlignmentMaxAgeDays':
        return value is num
            ? current.copyWith(polarAlignmentMaxAgeDays: value.toInt())
            : null;
      case 'opticalTrainDriftThreshold':
        return value is num
            ? current.copyWith(opticalTrainDriftThreshold: value.toDouble())
            : null;
      case 'darkLibraryMinCoverage':
        return value is num
            ? current.copyWith(darkLibraryMinCoverage: value.toInt())
            : null;
      case 'smartNightMaxSessionHours':
        if (value == null) {
          return current.copyWith(smartNightMaxSessionHours: null);
        }
        return value is num
            ? current.copyWith(smartNightMaxSessionHours: value.toDouble())
            : null;
      case 'smartNightDefaultAfCadenceFrames':
        return value is num
            ? current.copyWith(smartNightDefaultAfCadenceFrames: value.toInt())
            : null;
      case 'smartNightDefaultIntegrationBudgetMinsPerTarget':
        return value is num
            ? current.copyWith(
                smartNightDefaultIntegrationBudgetMinsPerTarget: value.toInt(),
              )
            : null;
      case 'smartNightIncludeFlatsAtEnd':
        return value is bool
            ? current.copyWith(smartNightIncludeFlatsAtEnd: value)
            : null;
      case 'smartNightUseSchedulerForMultiTarget':
        return value is bool
            ? current.copyWith(smartNightUseSchedulerForMultiTarget: value)
            : null;
      case 'smartNightSchedulerTargetThreshold':
        return value is num
            ? current.copyWith(
                smartNightSchedulerTargetThreshold: value.toInt(),
              )
            : null;
      case 'smartNightDefaultStrategy':
        return value is String
            ? current.copyWith(smartNightDefaultStrategy: value)
            : null;
      case 'smartNightPolarAlignmentStaleAfterDays':
        return value is num
            ? current.copyWith(
                smartNightPolarAlignmentStaleAfterDays: value.toInt(),
              )
            : null;
      case 'smartNightSubExposureFloorSecs':
        return value is num
            ? current.copyWith(smartNightSubExposureFloorSecs: value.toDouble())
            : null;
      case 'smartNightSubExposureCeilingSecs':
        return value is num
            ? current.copyWith(
                smartNightSubExposureCeilingSecs: value.toDouble(),
              )
            : null;
      case 'smartNightTargetSnr':
        return value is num
            ? current.copyWith(smartNightTargetSnr: value.toDouble())
            : null;
      // Full remote-settings parity 2026-06-05 — keys mirror
      // models.AppSettings.toJson() (camelCase). Remaining unattended-night
      // knobs pushed live from the host via the settings.changed event.
      case 'defaultGain':
        return value is num
            ? current.copyWith(defaultGain: value.toInt())
            : null;
      case 'defaultOffset':
        return value is num
            ? current.copyWith(defaultOffset: value.toInt())
            : null;
      case 'webServerEnabled':
        return value is bool ? current.copyWith(webServerEnabled: value) : null;
      case 'webServerPort':
        return value is num
            ? current.copyWith(webServerPort: value.toInt())
            : null;
      case 'phd2Path':
        return value is String ? current.copyWith(phd2Path: value) : null;
      case 'phd2Host':
        return value is String ? current.copyWith(phd2Host: value) : null;
      case 'phd2Port':
        return value is num ? current.copyWith(phd2Port: value.toInt()) : null;
      case 'notificationsEnabled':
        return value is bool
            ? current.copyWith(notificationsEnabled: value)
            : null;
      case 'notifyOnSequenceComplete':
        return value is bool
            ? current.copyWith(notifyOnSequenceComplete: value)
            : null;
      case 'notifyOnError':
        return value is bool ? current.copyWith(notifyOnError: value) : null;
      case 'notifyOnMeridianFlip':
        return value is bool
            ? current.copyWith(notifyOnMeridianFlip: value)
            : null;
      case 'soundEnabled':
        return value is bool ? current.copyWith(soundEnabled: value) : null;
      case 'audibleAlertsOnCritical':
        return value is bool
            ? current.copyWith(audibleAlertsOnCritical: value)
            : null;
      case 'criticalAlertSound':
        return value is String
            ? current.copyWith(criticalAlertSound: value)
            : null;
      case 'pushCriticalAlerts':
        return value is bool
            ? current.copyWith(pushCriticalAlerts: value)
            : null;
      case 'promptForNotesAfterRun':
        return value is bool
            ? current.copyWith(promptForNotesAfterRun: value)
            : null;
      case 'sessionHandoffAutoPrompt':
        return value is bool
            ? current.copyWith(sessionHandoffAutoPrompt: value)
            : null;
      case 'campaignRollupSurfaceTargetsTab':
        return value is bool
            ? current.copyWith(campaignRollupSurfaceTargetsTab: value)
            : null;
      case 'campaignRollupGroupingMode':
        return value is String
            ? current.copyWith(campaignRollupGroupingMode: value)
            : null;
      case 'afMethod':
        return value is String ? current.copyWith(afMethod: value) : null;
      case 'afCurveFitting':
        return value is String ? current.copyWith(afCurveFitting: value) : null;
      case 'afStepSize':
        return value is num
            ? current.copyWith(afStepSize: value.toInt())
            : null;
      case 'afExposureTime':
        return value is num
            ? current.copyWith(afExposureTime: value.toDouble())
            : null;
      case 'afInitialOffsetSteps':
        return value is num
            ? current.copyWith(afInitialOffsetSteps: value.toInt())
            : null;
      case 'afNumberOfAttempts':
        return value is num
            ? current.copyWith(afNumberOfAttempts: value.toInt())
            : null;
      case 'afUseBrightestNStars':
        return value is num
            ? current.copyWith(afUseBrightestNStars: value.toInt())
            : null;
      case 'afOuterCropRatio':
        return value is num
            ? current.copyWith(afOuterCropRatio: value.toDouble())
            : null;
      case 'afInnerCropRatio':
        return value is num
            ? current.copyWith(afInnerCropRatio: value.toDouble())
            : null;
      case 'afBinning':
        return value is num ? current.copyWith(afBinning: value.toInt()) : null;
      case 'afRSquaredThreshold':
        return value is num
            ? current.copyWith(afRSquaredThreshold: value.toDouble())
            : null;
      case 'afFailureHfrToleranceRatio':
        return value is num
            ? current.copyWith(afFailureHfrToleranceRatio: value.toDouble())
            : null;
      case 'afFocuserSettleTimeMs':
        return value is num
            ? current.copyWith(afFocuserSettleTimeMs: value.toInt())
            : null;
      case 'afExposuresPerPoint':
        return value is num
            ? current.copyWith(afExposuresPerPoint: value.toInt())
            : null;
      case 'afBacklashCompMethod':
        return value is String
            ? current.copyWith(afBacklashCompMethod: value)
            : null;
      case 'afBacklashIn':
        return value is num
            ? current.copyWith(afBacklashIn: value.toInt())
            : null;
      case 'afBacklashOut':
        return value is num
            ? current.copyWith(afBacklashOut: value.toInt())
            : null;
      case 'afAutofocusFilterName':
        return value is String
            ? current.copyWith(afAutofocusFilterName: value)
            : null;
      case 'afFilterSettingsJson':
        return value is String
            ? current.copyWith(afFilterSettingsJson: value)
            : null;
      case 'focuserBacklashCalibrationJson':
        return value is String
            ? current.copyWith(focuserBacklashCalibrationJson: value)
            : null;
      case 'useFilterFocusOffsets':
        return value is bool
            ? current.copyWith(useFilterFocusOffsets: value)
            : null;
      case 'astrometryPath':
        return value is String ? current.copyWith(astrometryPath: value) : null;
      case 'observerName':
        return value is String ? current.copyWith(observerName: value) : null;
      case 'imageFormat':
        return value is String
            ? current.copyWith(imageFormat: _normalizeCaptureImageFormat(value))
            : null;
      case 'bitDepth':
        return value is String
            ? current.copyWith(bitDepth: _normalizeCaptureBitDepth(value))
            : null;
      case 'timezone':
        return value is String ? current.copyWith(timezone: value) : null;
      case 'useSystemTime':
        return value is bool ? current.copyWith(useSystemTime: value) : null;
      // Settings round-trip gap closure (G5 / G7) — keys mirror
      // models.AppSettings.toJson() (camelCase). Pushed live from the host
      // via the settings.changed event.
      case 'sequencesPath':
        return value is String ? current.copyWith(sequencesPath: value) : null;
      case 'smartNightAutoSelect':
        return value is bool
            ? current.copyWith(smartNightAutoSelect: value)
            : null;
      case 'smartNightAutoSelectCount':
        return value is num
            ? current.copyWith(smartNightAutoSelectCount: value.toInt())
            : null;
      case 'adaptiveSwapEnabledByDefault':
        return value is bool
            ? current.copyWith(adaptiveSwapEnabledByDefault: value)
            : null;
      case 'adaptiveSwapDefaultThreshold':
        return value is num
            ? current.copyWith(adaptiveSwapDefaultThreshold: value.toDouble())
            : null;
      case 'adaptiveSwapDefaultHysteresisSecs':
        return value is num
            ? current.copyWith(
                adaptiveSwapDefaultHysteresisSecs: value.toDouble(),
              )
            : null;
      case 'conditionsScoreWeights':
        return value is Map
            ? current.copyWith(
                conditionsScoreWeights: value.map(
                  (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
                ),
              )
            : null;
      default:
        // Forward-compat: a newer host may emit settings this build
        // does not yet have a copyWith for. The persisted snapshot
        // captures the value (above) so a subsequent rebuild still
        // sees it via `_fromRemoteSettings`.
        return null;
    }
  }
}
