part of '../ffi_backend.dart';

mixin _FfiSequencerRecoveryOperations on _FfiBackendBase {
  // Sequencer control

  @override
  Future<void> sequencerStart() async {
    await bridge.NativeBridge.sequencerStart();
  }

  @override
  Future<void> sequencerStop({String? origin}) async {
    await bridge.NativeBridge.sequencerStop(origin: origin);
  }

  @override
  Future<void> sequencerPause() async {
    await bridge.NativeBridge.sequencerPause();
  }

  @override
  Future<void> sequencerResume() async {
    await bridge.NativeBridge.sequencerResume();
  }

  @override
  Future<void> sequencerSkip() async {
    await bridge.NativeBridge.sequencerSkip();
  }

  @override
  Future<void> sequencerSkipToNode(String nodeId) async {
    // Routes to the new `api_sequencer_skip_to_node` FRB
    // binding; preceding siblings of `nodeId` are marked Skipped and the
    // executor jumps forward on its next tree-walk step.
    await bridge.NativeBridge.sequencerSkipToNode(nodeId: nodeId);
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
    await bridge.NativeBridge.sequencerPluginNodeFinished(
      nodeId: nodeId,
      success: success,
      message: message,
      structuredDetailJson: structuredDetailJson,
    );
  }

  @override
  Future<void> sequencerReset() async {
    await bridge.NativeBridge.sequencerReset();
  }

  @override
  Future<void> sequencerLoadJson(String json) async {
    await bridge.NativeBridge.sequencerLoadJson(json);
  }

  @override
  Future<void> sequencerSetSimulationMode(bool enabled) async {
    await bridge.NativeBridge.sequencerSetSimulationMode(enabled);
  }

  @override
  Future<bool> sequencerIsSimulationMode() async {
    return bridge.NativeBridge.isSimulationMode();
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
    await bridge.NativeBridge.sequencerSetDevices(
      cameraId: cameraId,
      mountId: mountId,
      focuserId: focuserId,
      filterwheelId: filterwheelId,
      rotatorId: rotatorId,
      filterNames: filterNames,
      filterFocusOffsets: filterFocusOffsets,
    );
  }

  @override
  Future<void> sequencerSetSafetyFailMode(String mode) async {
    await bridge.NativeBridge.sequencerSetSafetyFailMode(mode);
  }

  @override
  Future<void> sequencerSetStopOnQualityProblems(bool stop) async {
    await bridge.NativeBridge.sequencerSetStopOnQualityProblems(stop);
  }

  @override
  Future<void> sequencerSetParkPolicy({
    required bool parkOnUnsafeWeather,
    required bool parkBeforeDawn,
  }) async {
    await bridge.NativeBridge.sequencerSetParkPolicy(
      parkOnUnsafeWeather: parkOnUnsafeWeather,
      parkBeforeDawn: parkBeforeDawn,
    );
  }

  @override
  Future<void> sequencerSetDeviceRetries({
    required int cameraRetries,
    required int filterWheelRetries,
  }) async {
    await bridge.NativeBridge.sequencerSetDeviceRetries(
      cameraRetries: cameraRetries,
      filterWheelRetries: filterWheelRetries,
    );
  }

  @override
  Future<void> sequencerSetSafetyCheckIntervalSeconds(int seconds) async {
    await bridge.NativeBridge.sequencerSetSafetyCheckIntervalSeconds(seconds);
  }

  @override
  Future<void> sequencerSetSavePath(String? path) async {
    await bridge.NativeBridge.sequencerSetSavePath(path: path);
  }

  @override
  Future<void> sequencerSetActiveSequenceRunId(int? sequenceRunId) async {
    await bridge.NativeBridge.sequencerSetActiveSequenceRunId(
      sequenceRunId: sequenceRunId,
    );
  }

  @override
  Future<void> sequencerSetDecisionLoggingEnabled(bool enabled) async {
    await bridge.NativeBridge.sequencerSetDecisionLoggingEnabled(
      enabled: enabled,
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
    await bridge.NativeBridge.sequencerUpdateDitherConfig(
      pixels: pixels,
      settlePixels: settlePixels,
      settleTime: settleTime,
      settleTimeout: settleTimeout,
      raOnly: raOnly,
    );
  }

  @override
  Future<void> sequencerUpdateMeridianFlipConfig(String configJson) async {
    await bridge.NativeBridge.sequencerUpdateMeridianFlipConfig(
      configJson: configJson,
    );
  }

  @override
  Future<void> sequencerUpdateLocation({
    required double latitude,
    required double longitude,
  }) async {
    await bridge.NativeBridge.sequencerUpdateLocation(
      latitude: latitude,
      longitude: longitude,
    );
  }

  @override
  Future<void> sequencerUpdateFilterOffsets(Map<String, int> offsets) async {
    await bridge.NativeBridge.sequencerUpdateFilterOffsets(offsets: offsets);
  }

  @override
  Future<void> sequencerUpdatePendingIntegrationCarryOver(
    Map<String, Map<String, double>> carryOver,
  ) async {
    // Staged on the executor's RuntimeConfig; consumed once
    // when the spawned executor task is created at the top of start().
    await bridge.NativeBridge.sequencerUpdatePendingIntegrationCarryOver(
      carryOver: carryOver,
    );
  }

  @override
  Future<void> sequencerUpdateAutofocusInterval(int everyNFrames) async {
    // Pushes the cadence into the live executor's
    // standard `AutofocusInterval` trigger via the new FRB binding.
    // The bridge rejects 0; pass >= 1.
    await bridge.NativeBridge.sequencerUpdateAutofocusInterval(
      everyNFrames: everyNFrames,
    );
  }

  @override
  Future<void> sequencerUpdateAutofocusConfig(String configJson) async {
    await bridge.NativeBridge.sequencerUpdateAutofocusConfig(
      configJson: configJson,
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
    await bridge.NativeBridge.sequencerUpdateDefaultQualityCheck(
      hfrThreshold: hfrThreshold,
      hfrBaselinePercent: hfrBaselinePercent,
      eccentricityThreshold: eccentricityThreshold,
      starCountMin: starCountMin,
      maxConsecutiveRejects: maxConsecutiveRejects,
      enabled: enabled,
    );
  }

  @override
  Future<void> sequencerUpdateRejectFolderPath(String? path) async {
    // Pushes the reject-folder override into the executor.
    // Empty / null => fall back to <save_path>/Reject/.
    await bridge.NativeBridge.sequencerUpdateRejectFolderPath(path: path);
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
    await bridge.NativeBridge.sequencerUpdateObserverProfile(
      observerName: observerName,
      siteElevationM: siteElevationM,
      cameraMake: cameraMake,
      cameraModel: cameraModel,
      telescopeName: telescopeName,
      telescopeFocalLengthMm: telescopeFocalLengthMm,
      telescopeApertureMm: telescopeApertureMm,
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
    await bridge_api.apiSequencerUpdateCloudMotion(
      currentCoverPercent: currentCoverPercent,
      predictedArrivalMinutes: predictedArrivalMinutes,
      predictedOpeningMinutes: predictedOpeningMinutes,
      predictedOpeningDurationSecs: predictedOpeningDurationSecs,
      predictedClearSkyAlt: predictedClearSkyAlt,
      predictedClearSkyAz: predictedClearSkyAz,
    );
  }

  @override
  Future<void> sequencerUpdateWeatherVerdict({bool? unsafeOverride}) async {
    // Full-night audit 2026-06-04 (defense-in-depth) — push the Dart-side
    // weather-safety verdict into the Rust trigger state so the in-sequencer
    // WeatherUnsafe trigger reacts even on rigs without a hardware safety
    // device. Folded OR-of-unsafe with the hardware reading (never less safe).
    await bridge_api.apiSequencerUpdateWeatherVerdict(
      unsafeOverride: unsafeOverride,
    );
  }

  @override
  Future<String?> sequencerGetCloudMotionJson() async {
    // JSON-serialised cloud-motion snapshot for the run
    // dashboard. Returns null until the first push has been received.
    return await bridge_api.apiSequencerGetCloudMotionJson();
  }

  @override
  Future<void> sequencerUpdateConditionsScore(ConditionsScore? score) async {
    final weights = score?.weights ?? const ConditionsScoreWeights();
    final generatedAt = score?.generatedAt.toUtc() ?? DateTime.now().toUtc();
    await bridge_api.apiSequencerUpdateConditionsScore(
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
    final raw = await bridge_api.apiSequencerGetAdaptiveSwapJson();
    return AdaptiveSwapDriver.decodeSnapshotJson(raw);
  }

  @override
  Future<void> sequencerUpdateSkyBrightness({required double? mag}) async {
    // Push the live SkyBrightnessTracker reading to the
    // executor.
    await bridge_api.apiSequencerUpdateSkyBrightness(mag: mag);
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
    await bridge_api.apiSequencerUpdateDefaultAdaptiveExposure(
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
    await bridge_api.apiSequencerClearDefaultAdaptiveExposure();
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
  // These are reachable via the typed FRB-generated `bridge_api.apiSequencer*`
  // wrappers (a later migration replaced the dynamic-dispatch shims).

  @override
  Future<void> recoveryTryNow() async {
    // Typed FRB binding (apiSequencerRecoveryTryNow) replaces the
    // Dynamic-dispatch shim that intercepted NoSuchMethodError while
    // bindings were pending.
    await bridge_api.apiSequencerRecoveryTryNow();
  }

  @override
  Future<void> recoveryAbort() async {
    await bridge_api.apiSequencerRecoveryAbort();
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
    await bridge_api.apiSequencerUpdateRecoveryConfig(
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
    return await bridge_api.apiSequencerGetCurrentRecoveryJson();
  }

  @override
  Future<String> getRecoveryHistoryJson() async {
    return await bridge_api.apiSequencerGetRecoveryHistoryJson();
  }

  @override
  Future<SequencerStatus> sequencerGetStatus() async {
    final dynamic status = await bridge.NativeBridge.sequencerGetStatus();

    // FRB returns SequencerState (no progress); bridge_stub returns
    // SequencerStatus (with progress). Both shapes are accepted so the mobile
    // stub keeps working.
    if (status is bridge.SequencerState) {
      final progress = status.state.toLowerCase() == 'completed'
          ? 1.0
          : status.totalExposures > 0
          ? status.completedExposures / status.totalExposures
          : (status.totalIntegrationSecs > 0
                ? status.elapsedSecs / status.totalIntegrationSecs
                : 0.0);

      return SequencerStatus(
        state: status.state,
        currentNodeId: status.currentNodeId,
        currentNodeName: status.currentNodeName,
        progress: progress.clamp(0.0, 1.0),
        message: status.message,
      );
    }

    if (status is bridge.SequencerStatus) {
      return SequencerStatus(
        state: status.state,
        currentNodeId: status.currentNodeId,
        currentNodeName: status.currentNodeName,
        progress: status.state.toLowerCase() == 'completed'
            ? 1.0
            : status.progress.clamp(0.0, 1.0),
        message: status.message,
      );
    }

    // Unknown shape; fall back to zero progress.
    return const SequencerStatus(
      state: 'unknown',
      currentNodeId: null,
      currentNodeName: null,
      progress: 0.0,
      message: null,
    );
  }

  // Checkpoint / Crash Recovery

  @override
  Future<void> sequencerSetCheckpointDir(String path) async {
    await bridge.NativeBridge.sequencerSetCheckpointDir(path);
  }

  @override
  Future<bool> hasCheckpoint() async {
    return await bridge.NativeBridge.sequencerHasCheckpoint();
  }

  @override
  Future<CheckpointInfo?> getCheckpointInfo() async {
    final info = await bridge.NativeBridge.sequencerGetCheckpointInfo();
    if (info == null) return null;

    return CheckpointInfo(
      sequenceName: info.sequenceName,
      timestamp: DateTime.parse(info.timestamp),
      completedExposures: info.completedExposures,
      completedIntegrationSecs: info.completedIntegrationSecs,
      canResume: info.canResume,
      ageSeconds: info.ageSeconds.toInt(),
    );
  }

  @override
  Future<void> resumeFromCheckpoint() async {
    await bridge.NativeBridge.sequencerResumeFromCheckpoint();
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
    await bridge.NativeBridge.performMeridianFlip(
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
    );
  }

  @override
  Future<void> discardCheckpoint() async {
    await bridge.NativeBridge.sequencerDiscardCheckpoint();
  }

  @override
  Future<void> saveCheckpoint() async {
    await bridge.NativeBridge.sequencerSaveCheckpoint();
  }

  @override
  // Shared TLS-only lookup for GUI and headless location discovery.
  Future<LocationSettings> getLocationFromInternet() => IpGeolocation.fetch();
}
