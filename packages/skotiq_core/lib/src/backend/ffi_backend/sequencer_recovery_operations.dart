part of '../ffi_backend.dart';

mixin _FfiSequencerRecoveryOperations on _FfiBackendBase {
  @override
  Future<void> sequencerStart() async {
    bridge.NativeBridge.requireNative('sequencerStart');
    if (!_NativeProcessState.sequencerEventsSubscribed) {
      await _native(
        'sequencerSubscribeEvents',
        () => bridge.apiSequencerSubscribeEvents(),
      );
      _NativeProcessState.sequencerEventsSubscribed = true;
    }
    await _native('sequencerStart', () => bridge.apiSequencerStart());
  }

  @override
  Future<void> sequencerStop({String? origin}) async {
    await _native(
      'sequencerStop',
      () => bridge.apiSequencerStop(origin: origin),
    );
  }

  @override
  Future<void> sequencerPause() async {
    await _native('sequencerPause', () => bridge.apiSequencerPause());
  }

  @override
  Future<void> sequencerResume() async {
    await _native('sequencerResume', () => bridge.apiSequencerResume());
  }

  @override
  Future<void> sequencerSkip() async {
    await _native('sequencerSkip', () => bridge.apiSequencerSkip());
  }

  @override
  Future<void> sequencerSkipToNode(String nodeId) async {
    // Routes to the new `api_sequencer_skip_to_node` FRB
    // binding; preceding siblings of `nodeId` are marked Skipped and the
    // executor jumps forward on its next tree-walk step.
    await _native(
      'sequencerSkipToNode',
      () => bridge.apiSequencerSkipToNode(nodeId: nodeId),
    );
  }

  @override
  Future<void> sequencerPluginNodeFinished({
    required String nodeId,
    required bool success,
    String? message,
    String? structuredDetailJson,
  }) async {
    // Routes to `api_sequencer_plugin_node_finished`,
    // which resolves the matching pending oneshot inside the Rust
    // executor. The awaiting `PluginNodeInstruction::execute` returns
    // Success / Failure based on `success`.
    await _native(
      'sequencerPluginNodeFinished',
      () => bridge.apiSequencerPluginNodeFinished(
        nodeId: nodeId,
        success: success,
        message: message,
        structuredDetailJson: structuredDetailJson,
      ),
    );
  }

  @override
  Future<void> sequencerReset() async {
    await _native('sequencerReset', () => bridge.apiSequencerReset());
  }

  @override
  Future<void> sequencerLoadJson(String json) async {
    await _native(
      'sequencerLoadJson',
      () => bridge.apiSequencerLoadJson(json: json),
    );
  }

  @override
  Future<void> sequencerSetSimulationMode(bool enabled) async {
    await _native(
      'sequencerSetSimulationMode',
      () => bridge.apiSequencerSetSimulationMode(enabled: enabled),
    );
    _NativeProcessState.simulationMode = enabled;
  }

  @override
  Future<bool> sequencerIsSimulationMode() async {
    return _NativeProcessState.simulationMode;
  }

  @override
  Future<void> sequencerSetDevices({
    String? cameraId,
    String? mountId,
    String? focuserId,
    String? filterwheelId,
    String? rotatorId,
    List<String>? filterNames,
    Map<String, int>? filterFocusOffsets,
  }) async {
    await _native(
      'sequencerSetDevices',
      () => bridge.apiSequencerSetDevices(
        cameraId: cameraId,
        mountId: mountId,
        focuserId: focuserId,
        filterwheelId: filterwheelId,
        rotatorId: rotatorId,
        filterNames: filterNames,
        filterFocusOffsets: filterFocusOffsets,
      ),
    );
  }

  @override
  Future<void> sequencerSetSafetyFailMode(String mode) async {
    await _native(
      'sequencerSetSafetyFailMode',
      () => bridge.apiSequencerSetSafetyFailMode(mode: mode),
    );
  }

  @override
  Future<void> sequencerSetStopOnQualityProblems(bool stop) async {
    await _native(
      'sequencerSetStopOnQualityProblems',
      () => bridge.apiSequencerSetStopOnQualityProblems(
        stopOnQualityProblems: stop,
      ),
    );
  }

  @override
  Future<void> sequencerSetParkPolicy({
    required bool parkOnUnsafeWeather,
    required bool parkBeforeDawn,
  }) async {
    await _native(
      'sequencerSetParkPolicy',
      () => bridge.apiSequencerSetParkPolicy(
        parkOnUnsafeWeather: parkOnUnsafeWeather,
        parkBeforeDawn: parkBeforeDawn,
      ),
    );
  }

  @override
  Future<void> sequencerSetDeviceRetries({
    required int cameraRetries,
    required int filterWheelRetries,
  }) async {
    await _native(
      'sequencerSetDeviceRetries',
      () => bridge.apiSequencerSetDeviceRetries(
        cameraRetries: cameraRetries,
        filterWheelRetries: filterWheelRetries,
      ),
    );
  }

  @override
  Future<void> sequencerSetSafetyCheckIntervalSeconds(int seconds) async {
    await _native(
      'sequencerSetSafetyCheckIntervalSeconds',
      () => bridge.apiSequencerSetSafetyCheckIntervalSeconds(seconds: seconds),
    );
  }

  @override
  Future<void> sequencerSetSavePath(String? path) async {
    await _native(
      'sequencerSetSavePath',
      () => bridge.apiSequencerSetSavePath(path: path),
    );
  }

  @override
  Future<void> sequencerSetActiveSequenceRunId(int? sequenceRunId) async {
    await _native(
      'sequencerSetActiveSequenceRunId',
      () => bridge.apiSequencerSetActiveSequenceRunId(
        sequenceRunId: sequenceRunId,
      ),
    );
  }

  @override
  Future<void> sequencerSetDecisionLoggingEnabled(bool enabled) async {
    await _native(
      'sequencerSetDecisionLoggingEnabled',
      () => bridge.apiSequencerSetDecisionLoggingEnabled(enabled: enabled),
    );
  }

  @override
  Future<void> sequencerUpdateDitherConfig({
    required double pixels,
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
    required bool raOnly,
  }) async {
    await _native(
      'sequencerUpdateDitherConfig',
      () => bridge.apiSequencerUpdateDitherConfig(
        pixels: pixels,
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: settleTimeout,
        raOnly: raOnly,
      ),
    );
  }

  @override
  Future<void> sequencerUpdateMeridianFlipConfig(String configJson) async {
    await _native(
      'sequencerUpdateMeridianFlipConfig',
      () => bridge.apiSequencerUpdateMeridianFlipConfig(configJson: configJson),
    );
  }

  @override
  Future<void> sequencerUpdateLocation({
    required double latitude,
    required double longitude,
  }) async {
    await _native(
      'sequencerUpdateLocation',
      () => bridge.apiSequencerUpdateLocation(
        latitude: latitude,
        longitude: longitude,
      ),
    );
  }

  @override
  Future<void> sequencerUpdateFilterOffsets(Map<String, int> offsets) async {
    await _native(
      'sequencerUpdateFilterOffsets',
      () => bridge.apiSequencerUpdateFilterOffsets(offsets: offsets),
    );
  }

  @override
  Future<void> sequencerUpdatePendingIntegrationCarryOver(
    Map<String, Map<String, double>> carryOver,
  ) async {
    // Staged on the executor's RuntimeConfig; consumed once
    // when the spawned executor task is created at the top of start().
    await _native(
      'sequencerUpdatePendingIntegrationCarryOver',
      () => bridge.apiSequencerUpdatePendingIntegrationCarryOver(
        carryOver: carryOver,
      ),
    );
  }

  @override
  Future<void> sequencerUpdateAutofocusInterval(int everyNFrames) async {
    // Pushes the cadence into the live executor's
    // standard `AutofocusInterval` trigger via the new FRB binding.
    // The bridge rejects 0; pass >= 1.
    await _native(
      'sequencerUpdateAutofocusInterval',
      () => bridge.apiSequencerUpdateAutofocusInterval(
        everyNFrames: everyNFrames,
      ),
    );
  }

  @override
  Future<void> sequencerUpdateAutofocusConfig(String configJson) async {
    await _native(
      'sequencerUpdateAutofocusConfig',
      () => bridge.apiSequencerUpdateAutofocusConfig(configJson: configJson),
    );
  }

  @override
  Future<void> sequencerUpdateDefaultQualityCheck({
    double? hfrThreshold,
    double? hfrBaselinePercent,
    double? eccentricityThreshold,
    int? starCountMin,
    required int maxConsecutiveRejects,
    required bool enabled,
  }) async {
    // Pushes the global image-grading thresholds into the
    // executor's RuntimeConfig.default_quality_check so the next
    // exposure honours the user's choices. Disabled => None pushed.
    await _native(
      'sequencerUpdateDefaultQualityCheck',
      () => bridge.apiSequencerUpdateDefaultQualityCheck(
        hfrThreshold: hfrThreshold,
        hfrBaselinePercent: hfrBaselinePercent,
        eccentricityThreshold: eccentricityThreshold,
        starCountMin: starCountMin,
        maxConsecutiveRejects: maxConsecutiveRejects,
        enabled: enabled,
      ),
    );
  }

  @override
  Future<void> sequencerSetCameraFileSaving(String saving) async {
    await _native(
      'sequencerSetCameraFileSaving',
      () => bridge.apiSequencerSetCameraFileSaving(saving: saving),
    );
  }

  @override
  Future<void> sequencerUpdateRejectFolderPath(String? path) async {
    // Pushes the reject-folder override into the executor.
    // Empty / null => fall back to <save_path>/Reject/.
    await _native(
      'sequencerUpdateRejectFolderPath',
      () => bridge.apiSequencerUpdateRejectFolderPath(path: path),
    );
  }

  @override
  Future<void> sequencerUpdateObserverProfile({
    String? observerName,
    double? siteElevationM,
    String? cameraMake,
    String? cameraModel,
    String? telescopeName,
    double? telescopeFocalLengthMm,
    double? telescopeApertureMm,
  }) async {
    // Pushes observer / equipment identification into the
    // executor so the next FITS save stamps OBSERVER, TELESCOP, FOCALLEN,
    // APTDIA, INSTRUME, SITEELEV with real values.
    await _native(
      'sequencerUpdateObserverProfile',
      () => bridge.apiSequencerUpdateObserverProfile(
        observerName: observerName,
        siteElevationM: siteElevationM,
        cameraMake: cameraMake,
        cameraModel: cameraModel,
        telescopeName: telescopeName,
        telescopeFocalLengthMm: telescopeFocalLengthMm,
        telescopeApertureMm: telescopeApertureMm,
      ),
    );
  }

  @override
  Future<void> sequencerUpdateCloudMotion({
    double? currentCoverPercent,
    double? predictedArrivalMinutes,
    double? predictedOpeningMinutes,
    double? predictedOpeningDurationSecs,
    double? predictedClearSkyAlt,
    double? predictedClearSkyAz,
  }) async {
    // Push the cloud-motion analyzer reading into the
    // Rust trigger state. Drives the CloudArrivingIn / CloudOpeningIn /
    // CloudCoverThreshold triggers in the live executor.
    await bridge.apiSequencerUpdateCloudMotion(
      currentCoverPercent: currentCoverPercent,
      predictedArrivalMinutes: predictedArrivalMinutes,
      predictedOpeningMinutes: predictedOpeningMinutes,
      predictedOpeningDurationSecs: predictedOpeningDurationSecs,
      predictedClearSkyAlt: predictedClearSkyAlt,
      predictedClearSkyAz: predictedClearSkyAz,
    );
  }

  @override
  Future<void> sequencerUpdateWeatherVerdict({
    bool? unsafeOverride,
    bool advisory = false,
  }) async {
    // The in-sequencer WeatherUnsafe trigger folds this OR-of-unsafe with the
    // hardware reading, so a rig without a safety device still reacts.
    await bridge.apiSequencerUpdateWeatherVerdict(
      unsafeOverride: unsafeOverride,
      advisory: advisory,
    );
  }

  @override
  Future<void> sequencerSetWeatherOperatorClear({
    required int durationSecs,
    required String reason,
  }) async {
    await bridge.apiSequencerSetWeatherOperatorClear(
      durationSecs: durationSecs,
      reason: reason,
    );
  }

  @override
  Future<void> sequencerSetWeatherResumeAfterSafeSecs(int seconds) async {
    await bridge.apiSequencerSetWeatherResumeAfterSafeSecs(seconds: seconds);
  }

  @override
  Future<String?> sequencerGetCloudMotionJson() async {
    // JSON-serialised cloud-motion snapshot for the run
    // dashboard. Returns null until the first push has been received.
    return await bridge.apiSequencerGetCloudMotionJson();
  }

  @override
  Future<void> sequencerUpdateConditionsScore(ConditionsScore? score) async {
    final weights = score?.weights ?? const ConditionsScoreWeights();
    final generatedAt = score?.generatedAt.toUtc() ?? DateTime.now().toUtc();
    await bridge.apiSequencerUpdateConditionsScore(
      score: score?.score,
      transparencyScore: score?.transparencyScore,
      seeingScore: score?.seeingScore,
      cloudScore: score?.cloudScore,
      windScore: score?.windScore,
      transparencyWeight: weights.transparencyWeight,
      seeingWeight: weights.seeingWeight,
      cloudWeight: weights.cloudWeight,
      windWeight: weights.windWeight,
      generatedUnixSecs: generatedAt.millisecondsSinceEpoch ~/ 1000,
    );
  }

  @override
  Future<AdaptiveSwapSnapshot?> sequencerGetAdaptiveSwapSnapshot() async {
    final raw = await bridge.apiSequencerGetAdaptiveSwapJson();
    return AdaptiveSwapDriver.decodeSnapshotJson(raw);
  }

  @override
  Future<void> sequencerUpdateSkyBrightness({required double? mag}) async {
    // Push the live SkyBrightnessTracker reading to the
    // executor.
    await bridge.apiSequencerUpdateSkyBrightness(mag: mag);
  }

  @override
  Future<void> sequencerUpdateDefaultAdaptiveExposure({
    required bool enabled,
    required double targetSnr,
    required double referenceSkyBrightnessMag,
    required double minExposureSecs,
    required double maxExposureSecs,
    required Map<String, bool> perFilterEnabled,
    required Map<String, double> perFilterMinSecs,
    required Map<String, double> perFilterMaxSecs,
  }) async {
    // Push the global default adaptive exposure config.
    // FRB cannot bridge `Map<String, T>` directly, so we flatten to
    // parallel (keys, values) lists matching the Rust API.
    await bridge.apiSequencerUpdateDefaultAdaptiveExposure(
      enabled: enabled,
      targetSnr: targetSnr,
      referenceSkyBrightnessMag: referenceSkyBrightnessMag,
      minExposureSecs: minExposureSecs,
      maxExposureSecs: maxExposureSecs,
      perFilterEnabledKeys: perFilterEnabled.keys.toList(),
      perFilterEnabledValues: perFilterEnabled.values.toList(),
      perFilterMinKeys: perFilterMinSecs.keys.toList(),
      perFilterMinValues: perFilterMinSecs.values.toList(),
      perFilterMaxKeys: perFilterMaxSecs.keys.toList(),
      perFilterMaxValues: perFilterMaxSecs.values.toList(),
    );
  }

  @override
  Future<void> sequencerClearDefaultAdaptiveExposure() async {
    await bridge.apiSequencerClearDefaultAdaptiveExposure();
  }

  // Recovery mode
  //
  // The Rust bridge exposes:
  //   * `sequencer_recovery_try_now()` -> Result<(), SkotiqError>
  //   * `sequencer_recovery_abort()`   -> Result<(), SkotiqError>
  //   * `sequencer_update_recovery_config(update)` -> Result<(), …>
  //   * `sequencer_get_current_recovery_json()` -> Result<Option<String>, …>
  //   * `sequencer_get_recovery_history_json()` -> Result<String, …>
  //
  // These are reachable via the typed FRB-generated `bridge.apiSequencer*`
  // wrappers (a later migration replaced the dynamic-dispatch shims).

  @override
  Future<void> recoveryTryNow() async {
    await bridge.apiSequencerRecoveryTryNow();
  }

  @override
  Future<void> recoveryAbort() async {
    await bridge.apiSequencerRecoveryAbort();
  }

  @override
  Future<void> updateRecoveryConfig({
    required double retryIntervalSecs,
    required double maxDurationSecs,
    required bool stopTrackingDuringRecovery,
    required bool abortOnMeridian,
    required bool audibleAlertWhenEntered,
    required bool parkAndCloseWhenRecoveryGivesUp,
  }) async {
    await bridge.apiSequencerUpdateRecoveryConfig(
      update: bridge.RecoveryConfigUpdate(
        retryIntervalSecs: retryIntervalSecs,
        maxDurationSecs: maxDurationSecs,
        stopTrackingDuringRecovery: stopTrackingDuringRecovery,
        abortOnMeridian: abortOnMeridian,
        audibleAlertWhenEntered: audibleAlertWhenEntered,
        parkAndCloseWhenRecoveryGivesUp: parkAndCloseWhenRecoveryGivesUp,
      ),
    );
  }

  @override
  Future<String?> getCurrentRecoveryJson() async {
    return await bridge.apiSequencerGetCurrentRecoveryJson();
  }

  @override
  Future<String> getRecoveryHistoryJson() async {
    return await bridge.apiSequencerGetRecoveryHistoryJson();
  }

  @override
  Future<SequencerStatus> sequencerGetStatus() async {
    final status = await _native(
      'sequencerGetStatus',
      () => bridge.apiSequencerGetState(),
    );
    return SequencerStatus(
      state: status.state,
      currentNodeId: status.currentNodeId,
      currentNodeName: status.currentNodeName,
      progress: sequencerProgressFraction(
        state: status.state,
        completedExposures: status.completedExposures,
        totalExposures: status.totalExposures,
      ),
      message: status.message,
    );
  }

  @override
  Future<void> sequencerSetCheckpointDir(String path) async {
    await _native(
      'sequencerSetCheckpointDir',
      () => bridge.apiSequencerSetCheckpointDir(path: path),
    );
  }

  @override
  Future<bool> hasCheckpoint() async {
    return await _native(
      'sequencerHasCheckpoint',
      () => bridge.apiSequencerHasCheckpoint(),
    );
  }

  @override
  Future<CheckpointInfo?> getCheckpointInfo() async {
    final info = await _native(
      'sequencerGetCheckpointInfo',
      () => bridge.apiSequencerGetCheckpointInfo(),
    );
    if (info == null) return null;

    return CheckpointInfo(
      sequenceName: info.sequenceName,
      timestamp: DateTime.parse(info.timestamp),
      completedExposures: info.completedExposures,
      completedIntegrationSecs: info.completedIntegrationSecs,
      canResume: info.canResume,
      ageSeconds: info.ageSeconds.toInt(),
      ended: info.ended,
      framesDoneByStep: info.framesDoneByStep,
    );
  }

  @override
  Future<void> resumeFromCheckpoint() async {
    await _native(
      'sequencerResumeFromCheckpoint',
      () => bridge.apiSequencerResumeFromCheckpoint(),
    );
  }

  @override
  Future<void> sequencerRequestMeridianFlip() async {
    await _native(
      'sequencerRequestMeridianFlip',
      () => bridge.apiSequencerRequestMeridianFlip(),
    );
  }

  @override
  Future<void> performMeridianFlip({
    required String mountId,
    String? cameraId,
    String? focuserId,
    String? coverCalibratorId,
    required String targetName,
    required double targetRaHours,
    required double targetDecDegrees,
    required bool pauseGuiding,
    required bool autoCenter,
    required bool refocusAfter,
    required bool resumeGuiding,
    required double settleTimeSecs,
  }) async {
    await _native(
      'performMeridianFlip',
      () => bridge.apiPerformMeridianFlip(
        mountId: mountId,
        cameraId: cameraId,
        focuserId: focuserId,
        coverCalibratorId: coverCalibratorId,
        targetName: targetName,
        targetRaHours: targetRaHours,
        targetDecDegrees: targetDecDegrees,
        pauseGuiding: pauseGuiding,
        autoCenter: autoCenter,
        refocusAfter: refocusAfter,
        resumeGuiding: resumeGuiding,
        settleTimeSecs: settleTimeSecs,
      ),
    );
  }

  @override
  Future<void> discardCheckpoint() async {
    await _native(
      'sequencerDiscardCheckpoint',
      () => bridge.apiSequencerClearCheckpoint(),
    );
  }

  @override
  Future<void> saveCheckpoint() async {
    await _native(
      'sequencerSaveCheckpoint',
      () => bridge.apiSequencerSaveCheckpoint(),
    );
  }

  @override
  // Shared TLS-only lookup for GUI and headless location discovery.
  Future<LocationSettings> getLocationFromInternet() => IpGeolocation.fetch();
}
