part of '../bridge_stub.dart';

/// Stable static API for the native bridge implementation.
///
/// The operational code is split by domain behind a single shared instance so
/// existing callers keep the original static API and process-wide state.
abstract final class NativeBridge {
  static Future<void> init({String? logDirectory}) =>
      _nativeBridge.init(logDirectory: logDirectory);
  static bool get isNativeAvailable => _nativeBridge.isNativeAvailable;
  static void invalidateDiscoveryCache() =>
      _nativeBridge.invalidateDiscoveryCache();
  static Stream<NightshadeEvent> eventStream() => _nativeBridge.eventStream();
  static Future<List<DeviceInfo>> discoverDevices(DeviceType deviceType) =>
      _nativeBridge.discoverDevices(deviceType);
  static Future<void> connectDevice(DeviceType deviceType, String deviceId) =>
      _nativeBridge.connectDevice(deviceType, deviceId);
  static Future<void> disconnectDevice(
    DeviceType deviceType,
    String deviceId,
  ) => _nativeBridge.disconnectDevice(deviceType, deviceId);
  static Future<List<DeviceInfo>> getConnectedDevices() =>
      _nativeBridge.getConnectedDevices();
  static Future<CameraStatus> getCameraStatus(String deviceId) =>
      _nativeBridge.getCameraStatus(deviceId);
  static Future<void> setCameraCooler(
    String deviceId,
    bool enabled,
    double? targetTemp,
  ) => _nativeBridge.setCameraCooler(deviceId, enabled, targetTemp);
  static Future<void> setCameraGain(String deviceId, int gain) =>
      _nativeBridge.setCameraGain(deviceId, gain);
  static Future<void> setCameraOffset(String deviceId, int offset) =>
      _nativeBridge.setCameraOffset(deviceId, offset);
  static Future<void> setReadoutMode({
    required String deviceId,
    required int modeIndex,
  }) => _nativeBridge.setReadoutMode(deviceId: deviceId, modeIndex: modeIndex);
  static Future<void> cancelExposure(String deviceId) =>
      _nativeBridge.cancelExposure(deviceId);
  static Future<MountStatus> getMountStatus(String deviceId) =>
      _nativeBridge.getMountStatus(deviceId);
  static Future<void> mountSlewToCoordinates(
    String deviceId,
    double ra,
    double dec,
  ) => _nativeBridge.mountSlewToCoordinates(deviceId, ra, dec);
  static Future<void> mountSync(String deviceId, double ra, double dec) =>
      _nativeBridge.mountSync(deviceId, ra, dec);
  static Future<void> mountPark(String deviceId) =>
      _nativeBridge.mountPark(deviceId);
  static Future<void> mountUnpark(String deviceId) =>
      _nativeBridge.mountUnpark(deviceId);
  static Future<void> mountSetTracking(String deviceId, bool enabled) =>
      _nativeBridge.mountSetTracking(deviceId, enabled);
  static Future<void> mountPulseGuide(
    String deviceId,
    String direction,
    int durationMs,
  ) => _nativeBridge.mountPulseGuide(deviceId, direction, durationMs);
  static Future<FocuserStatus> getFocuserStatus(String deviceId) =>
      _nativeBridge.getFocuserStatus(deviceId);
  static Future<void> focuserMoveTo(String deviceId, int position) =>
      _nativeBridge.focuserMoveTo(deviceId, position);
  static Future<void> focuserMoveRelative(String deviceId, int delta) =>
      _nativeBridge.focuserMoveRelative(deviceId, delta);
  static Future<void> apiFocuserHalt({required String deviceId}) =>
      _nativeBridge.apiFocuserHalt(deviceId: deviceId);
  static Future<FilterWheelStatus> getFilterWheelStatus(String deviceId) =>
      _nativeBridge.getFilterWheelStatus(deviceId);
  static Future<void> apiFilterwheelSetPosition({
    required String deviceId,
    required int position,
  }) => _nativeBridge.apiFilterwheelSetPosition(
    deviceId: deviceId,
    position: position,
  );
  static Future<List<String>> apiFilterwheelGetNames({
    required String deviceId,
  }) => _nativeBridge.apiFilterwheelGetNames(deviceId: deviceId);
  static Future<void> apiFilterwheelSetByName({
    required String deviceId,
    required String name,
  }) => _nativeBridge.apiFilterwheelSetByName(deviceId: deviceId, name: name);
  static Future<PlateSolveResult> plateSolveBlind(
    String filePath, [
    int? timeoutSeconds,
  ]) => _nativeBridge.plateSolveBlind(filePath, timeoutSeconds);
  static Future<PlateSolveResult> plateSolveNear(
    String filePath,
    double hintRa,
    double hintDec,
    double searchRadius, [
    int? timeoutSeconds,
  ]) => _nativeBridge.plateSolveNear(
    filePath,
    hintRa,
    hintDec,
    searchRadius,
    timeoutSeconds,
  );
  static Future<bool> isPhd2Running({
    String host = 'localhost',
    int port = 4400,
  }) => _nativeBridge.isPhd2Running(host: host, port: port);
  static Future<void> phd2Connect({String? host, int? port}) =>
      _nativeBridge.phd2Connect(host: host, port: port);
  static Future<void> phd2Disconnect() => _nativeBridge.phd2Disconnect();
  static Future<void> phd2StartGuiding({
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
  }) => _nativeBridge.phd2StartGuiding(
    settlePixels: settlePixels,
    settleTime: settleTime,
    settleTimeout: settleTimeout,
  );
  static Future<void> phd2StopGuiding() => _nativeBridge.phd2StopGuiding();
  static Future<void> phd2Dither({
    required double amount,
    required bool raOnly,
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
  }) => _nativeBridge.phd2Dither(
    amount: amount,
    raOnly: raOnly,
    settlePixels: settlePixels,
    settleTime: settleTime,
    settleTimeout: settleTimeout,
  );
  static Future<Phd2Status> phd2GetStatus() => _nativeBridge.phd2GetStatus();
  static Future<void> guiderStartGuiding({
    required String deviceId,
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
  }) => _nativeBridge.guiderStartGuiding(
    deviceId: deviceId,
    settlePixels: settlePixels,
    settleTime: settleTime,
    settleTimeout: settleTimeout,
  );
  static Future<void> guiderStop({required String deviceId}) =>
      _nativeBridge.guiderStop(deviceId: deviceId);
  static Future<void> guiderDither({
    required String deviceId,
    required double amount,
    required bool raOnly,
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
  }) => _nativeBridge.guiderDither(
    deviceId: deviceId,
    amount: amount,
    raOnly: raOnly,
    settlePixels: settlePixels,
    settleTime: settleTime,
    settleTimeout: settleTimeout,
  );
  static Future<void> guiderLoop({required String deviceId}) =>
      _nativeBridge.guiderLoop(deviceId: deviceId);
  static Future<(double, double)> guiderFindStar({required String deviceId}) =>
      _nativeBridge.guiderFindStar(deviceId: deviceId);
  static Future<void> guiderSetLockPosition({
    required String deviceId,
    required double x,
    required double y,
    bool exact = false,
  }) => _nativeBridge.guiderSetLockPosition(
    deviceId: deviceId,
    x: x,
    y: y,
    exact: exact,
  );
  static Future<(double, double)> guiderGetLockPosition({
    required String deviceId,
  }) => _nativeBridge.guiderGetLockPosition(deviceId: deviceId);
  static Future<void> guiderDeselectStar({required String deviceId}) =>
      _nativeBridge.guiderDeselectStar(deviceId: deviceId);
  static Future<Phd2StarImage> guiderGetStarImage({
    required String deviceId,
    int size = 50,
  }) => _nativeBridge.guiderGetStarImage(deviceId: deviceId, size: size);
  static Future<Map<String, dynamic>> builtinGuiderGetConfigRaw() =>
      _nativeBridge.builtinGuiderGetConfigRaw();
  static Future<String> builtinGuiderGetTrackedStarsJson() =>
      _nativeBridge.builtinGuiderGetTrackedStarsJson();
  static Future<void> builtinGuiderSetConfigRaw({
    required double exposureSecs,
    required int gain,
    required int offset,
    required int binning,
    required int calibrationMs,
    required int settleSleepMs,
    required double minPulseMs,
    required double maxPulseMs,
  }) => _nativeBridge.builtinGuiderSetConfigRaw(
    exposureSecs: exposureSecs,
    gain: gain,
    offset: offset,
    binning: binning,
    calibrationMs: calibrationMs,
    settleSleepMs: settleSleepMs,
    minPulseMs: minPulseMs,
    maxPulseMs: maxPulseMs,
  );
  static Future<void> phd2Loop() => _nativeBridge.phd2Loop();
  static Future<List<String>> phd2GetAlgoParamNames({required String axis}) =>
      _nativeBridge.phd2GetAlgoParamNames(axis: axis);
  static Future<double> phd2GetAlgoParam({
    required String axis,
    required String name,
  }) => _nativeBridge.phd2GetAlgoParam(axis: axis, name: name);
  static Future<void> phd2SetAlgoParam({
    required String axis,
    required String name,
    required double value,
  }) => _nativeBridge.phd2SetAlgoParam(axis: axis, name: name, value: value);
  static Future<void> phd2SetPaused({required bool paused}) =>
      _nativeBridge.phd2SetPaused(paused: paused);
  static Future<void> phd2ClearCalibration({String which = 'both'}) =>
      _nativeBridge.phd2ClearCalibration(which: which);
  static Future<void> phd2FlipCalibration() =>
      _nativeBridge.phd2FlipCalibration();
  static Future<gen_api.Phd2CalibrationData> phd2GetCalibrationData() =>
      _nativeBridge.phd2GetCalibrationData();
  static Future<(double, double)> phd2FindStar() =>
      _nativeBridge.phd2FindStar();
  static Future<void> phd2SetLockPosition({
    required double x,
    required double y,
    bool exact = false,
  }) => _nativeBridge.phd2SetLockPosition(x: x, y: y, exact: exact);
  static Future<(double, double)> phd2GetLockPosition() =>
      _nativeBridge.phd2GetLockPosition();
  static Future<void> phd2DeselectStar() => _nativeBridge.phd2DeselectStar();
  static Future<void> sequencerSubscribeEvents() =>
      _nativeBridge.sequencerSubscribeEvents();
  // Retained: the sole reader of `_loadedSequenceJson`, which the sequencer
  // lifecycle methods maintain.
  static String? get loadedSequenceJson => _nativeBridge.loadedSequenceJson;
  static Future<void> sequencerLoadJson(String json) =>
      _nativeBridge.sequencerLoadJson(json);
  static Future<void> sequencerSetDevices({
    String? cameraId,
    String? mountId,
    String? focuserId,
    String? filterwheelId,
    String? rotatorId,
    List<String>? filterNames,
    Map<String, int>? filterFocusOffsets,
  }) => _nativeBridge.sequencerSetDevices(
    cameraId: cameraId,
    mountId: mountId,
    focuserId: focuserId,
    filterwheelId: filterwheelId,
    rotatorId: rotatorId,
    filterNames: filterNames,
    filterFocusOffsets: filterFocusOffsets,
  );
  static Future<void> sequencerSetSafetyFailMode(String mode) =>
      _nativeBridge.sequencerSetSafetyFailMode(mode);
  static Future<void> sequencerSetParkPolicy({
    required bool parkOnUnsafeWeather,
    required bool parkBeforeDawn,
  }) => _nativeBridge.sequencerSetParkPolicy(
    parkOnUnsafeWeather: parkOnUnsafeWeather,
    parkBeforeDawn: parkBeforeDawn,
  );
  static Future<void> sequencerSetDeviceRetries({
    required int cameraRetries,
    required int filterWheelRetries,
  }) => _nativeBridge.sequencerSetDeviceRetries(
    cameraRetries: cameraRetries,
    filterWheelRetries: filterWheelRetries,
  );
  static Future<void> sequencerSetSafetyCheckIntervalSeconds(int seconds) =>
      _nativeBridge.sequencerSetSafetyCheckIntervalSeconds(seconds);
  static Future<void> sequencerSetSavePath({String? path}) =>
      _nativeBridge.sequencerSetSavePath(path: path);
  static Future<void> sequencerSetActiveSequenceRunId({int? sequenceRunId}) =>
      _nativeBridge.sequencerSetActiveSequenceRunId(
        sequenceRunId: sequenceRunId,
      );
  static Future<void> sequencerSetDecisionLoggingEnabled({
    required bool enabled,
  }) => _nativeBridge.sequencerSetDecisionLoggingEnabled(enabled: enabled);
  static Future<void> sequencerUpdateDitherConfig({
    required double pixels,
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
    required bool raOnly,
  }) => _nativeBridge.sequencerUpdateDitherConfig(
    pixels: pixels,
    settlePixels: settlePixels,
    settleTime: settleTime,
    settleTimeout: settleTimeout,
    raOnly: raOnly,
  );
  static Future<void> sequencerUpdateMeridianFlipConfig({
    required String configJson,
  }) => _nativeBridge.sequencerUpdateMeridianFlipConfig(configJson: configJson);
  static Future<void> sequencerUpdateLocation({
    required double latitude,
    required double longitude,
  }) => _nativeBridge.sequencerUpdateLocation(
    latitude: latitude,
    longitude: longitude,
  );
  static Future<void> sequencerUpdateFilterOffsets({
    required Map<String, int> offsets,
  }) => _nativeBridge.sequencerUpdateFilterOffsets(offsets: offsets);
  static Future<void> sequencerUpdatePendingIntegrationCarryOver({
    required Map<String, Map<String, double>> carryOver,
  }) => _nativeBridge.sequencerUpdatePendingIntegrationCarryOver(
    carryOver: carryOver,
  );
  static Future<void> sequencerUpdateAutofocusConfig({
    required String configJson,
  }) => _nativeBridge.sequencerUpdateAutofocusConfig(configJson: configJson);
  static Future<void> sequencerUpdateAutofocusInterval({
    required int everyNFrames,
  }) => _nativeBridge.sequencerUpdateAutofocusInterval(
    everyNFrames: everyNFrames,
  );
  static Future<void> sequencerUpdateDefaultQualityCheck({
    double? hfrThreshold,
    double? hfrBaselinePercent,
    double? eccentricityThreshold,
    int? starCountMin,
    required int maxConsecutiveRejects,
    required bool enabled,
  }) => _nativeBridge.sequencerUpdateDefaultQualityCheck(
    hfrThreshold: hfrThreshold,
    hfrBaselinePercent: hfrBaselinePercent,
    eccentricityThreshold: eccentricityThreshold,
    starCountMin: starCountMin,
    maxConsecutiveRejects: maxConsecutiveRejects,
    enabled: enabled,
  );
  static Future<void> sequencerUpdateRejectFolderPath({String? path}) =>
      _nativeBridge.sequencerUpdateRejectFolderPath(path: path);
  static Future<void> sequencerUpdateObserverProfile({
    String? observerName,
    double? siteElevationM,
    String? cameraMake,
    String? cameraModel,
    String? telescopeName,
    double? telescopeFocalLengthMm,
    double? telescopeApertureMm,
  }) => _nativeBridge.sequencerUpdateObserverProfile(
    observerName: observerName,
    siteElevationM: siteElevationM,
    cameraMake: cameraMake,
    cameraModel: cameraModel,
    telescopeName: telescopeName,
    telescopeFocalLengthMm: telescopeFocalLengthMm,
    telescopeApertureMm: telescopeApertureMm,
  );
  static Future<void> sequencerStart() => _nativeBridge.sequencerStart();
  static Future<void> sequencerPause() => _nativeBridge.sequencerPause();
  static Future<void> sequencerResume() => _nativeBridge.sequencerResume();
  static Future<void> sequencerStop({String? origin}) =>
      _nativeBridge.sequencerStop(origin: origin);
  static Future<void> sequencerSkip() => _nativeBridge.sequencerSkip();
  static Future<void> sequencerSkipToNode({required String nodeId}) =>
      _nativeBridge.sequencerSkipToNode(nodeId: nodeId);
  static Future<void> sequencerPluginNodeFinished({
    required String nodeId,
    required bool success,
    String? message,
    String? structuredDetailJson,
  }) => _nativeBridge.sequencerPluginNodeFinished(
    nodeId: nodeId,
    success: success,
    message: message,
    structuredDetailJson: structuredDetailJson,
  );
  static Future<void> sequencerReset() => _nativeBridge.sequencerReset();
  // Retained: the sole reader of `_sequencerState`, which the sequencer
  // lifecycle methods maintain.
  static SequencerState getSequencerState() =>
      _nativeBridge.getSequencerState();
  static Future<void> sequencerSetSimulationMode(bool enabled) =>
      _nativeBridge.sequencerSetSimulationMode(enabled);
  // Retained: the sole reader of `_simulationMode`.
  static bool isSimulationMode() => _nativeBridge.isSimulationMode();
  static Future<SequencerStatus> sequencerGetStatus() =>
      _nativeBridge.sequencerGetStatus();
  static Future<void> sequencerSetCheckpointDir(String path) =>
      _nativeBridge.sequencerSetCheckpointDir(path);
  static Future<bool> sequencerHasCheckpoint() =>
      _nativeBridge.sequencerHasCheckpoint();
  static Future<CheckpointInfoApi?> sequencerGetCheckpointInfo() =>
      _nativeBridge.sequencerGetCheckpointInfo();
  static Future<void> sequencerResumeFromCheckpoint() =>
      _nativeBridge.sequencerResumeFromCheckpoint();
  static Future<void> performMeridianFlip({
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
  }) => _nativeBridge.performMeridianFlip(
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
  static Future<void> sequencerDiscardCheckpoint() =>
      _nativeBridge.sequencerDiscardCheckpoint();
  static Future<void> sequencerSaveCheckpoint() =>
      _nativeBridge.sequencerSaveCheckpoint();
  static Future<void> apiRotatorMoveTo({
    required String deviceId,
    required double angle,
  }) => _nativeBridge.apiRotatorMoveTo(deviceId: deviceId, angle: angle);
  static Future<void> apiRotatorMoveRelative({
    required String deviceId,
    required double delta,
  }) => _nativeBridge.apiRotatorMoveRelative(deviceId: deviceId, delta: delta);
  static Future<RotatorStatus> apiGetRotatorStatus({
    required String deviceId,
  }) => _nativeBridge.apiGetRotatorStatus(deviceId: deviceId);
  static Future<void> apiRotatorHalt({required String deviceId}) =>
      _nativeBridge.apiRotatorHalt(deviceId: deviceId);
  static Future<void> apiRotatorSetReverse({
    required String deviceId,
    required bool reverse,
  }) =>
      _nativeBridge.apiRotatorSetReverse(deviceId: deviceId, reverse: reverse);
  static Future<void> apiRotatorSyncToPa({
    required String deviceId,
    required double pa,
  }) => _nativeBridge.apiRotatorSyncToPa(deviceId: deviceId, pa: pa);
  static Future<List<EquipmentProfile>> apiGetProfiles() =>
      _nativeBridge.apiGetProfiles();
  static Future<void> apiSaveProfile({required EquipmentProfile profile}) =>
      _nativeBridge.apiSaveProfile(profile: profile);
  static Future<void> apiDeleteProfile({required String profileId}) =>
      _nativeBridge.apiDeleteProfile(profileId: profileId);
  static Future<void> apiLoadProfile({required String profileId}) =>
      _nativeBridge.apiLoadProfile(profileId: profileId);
  static Future<EquipmentProfile?> apiGetActiveProfile() =>
      _nativeBridge.apiGetActiveProfile();
  static Future<void> apiInitProfileStorage({required String storagePath}) =>
      _nativeBridge.apiInitProfileStorage(storagePath: storagePath);
  static Future<void> apiInitSettingsStorage({required String storagePath}) =>
      _nativeBridge.apiInitSettingsStorage(storagePath: storagePath);
  static Future<AppSettings> apiGetSettings() => _nativeBridge.apiGetSettings();
  static Future<void> apiUpdateSettings({required AppSettings settings}) =>
      _nativeBridge.apiUpdateSettings(settings: settings);
  static Future<ObserverLocation?> apiGetLocation() =>
      _nativeBridge.apiGetLocation();
  static Future<void> apiSetLocation({ObserverLocation? location}) =>
      _nativeBridge.apiSetLocation(location: location);

  // DepthLock goal store

  static Future<gen_api.ApiDepthLockStatus> apiDepthlockStatus() =>
      _nativeBridge.apiDepthlockStatus();
  static Future<List<gen_api.ApiDepthGoal>> apiDepthlockListGoals() =>
      _nativeBridge.apiDepthlockListGoals();
  static Future<gen_api.ApiDepthGoal> apiDepthlockGetGoal({
    required String goalId,
  }) => _nativeBridge.apiDepthlockGetGoal(goalId: goalId);
  static Future<gen_api.ApiDepthGoal> apiDepthlockCreateGoal({
    required String goalId,
    required gen_api.ApiDepthGoalDefinition definition,
  }) => _nativeBridge.apiDepthlockCreateGoal(
    goalId: goalId,
    definition: definition,
  );
  static Future<gen_api.ApiDepthGoal> apiDepthlockReviseGoal({
    required String goalId,
    required BigInt expectedRevision,
    required gen_api.ApiDepthGoalDefinition definition,
  }) => _nativeBridge.apiDepthlockReviseGoal(
    goalId: goalId,
    expectedRevision: expectedRevision,
    definition: definition,
  );
  static Future<gen_api.ApiDepthGoal> apiDepthlockSetGoalPreferences({
    required String goalId,
    required BigInt expectedRevision,
    required bool enabled,
    required bool automaticCompletion,
  }) => _nativeBridge.apiDepthlockSetGoalPreferences(
    goalId: goalId,
    expectedRevision: expectedRevision,
    enabled: enabled,
    automaticCompletion: automaticCompletion,
  );
  static Future<void> apiDepthlockRemoveGoal({
    required String goalId,
    required BigInt expectedRevision,
  }) => _nativeBridge.apiDepthlockRemoveGoal(
    goalId: goalId,
    expectedRevision: expectedRevision,
  );
  static Future<gen_api.ApiDepthReferenceInfo> apiDepthlockInspectReference({
    required String path,
  }) => _nativeBridge.apiDepthlockInspectReference(path: path);
  static Future<gen_api.ApiDepthFloorSuggestion> apiDepthlockSuggestFloor({
    required String referencePath,
    required String darkPath,
    required String flatPath,
    required double scaleArcsec,
    double? pixelScaleArcsec,
  }) => _nativeBridge.apiDepthlockSuggestFloor(
    referencePath: referencePath,
    darkPath: darkPath,
    flatPath: flatPath,
    scaleArcsec: scaleArcsec,
    pixelScaleArcsec: pixelScaleArcsec,
  );
  static Future<gen_api.ApiSkyRectangle> apiDepthlockSkyRectangle({
    required gen_api.ApiReferenceGeometry reference,
    required double x0,
    required double y0,
    required double x1,
    required double y1,
  }) => _nativeBridge.apiDepthlockSkyRectangle(
    reference: reference,
    x0: x0,
    y0: y0,
    x1: x1,
    y1: y1,
  );
  static Future<int> apiDepthlockCheckMeasurement({
    required gen_api.ApiDepthMeasurement measurement,
  }) => _nativeBridge.apiDepthlockCheckMeasurement(measurement: measurement);
  static Future<gen_api.ApiDepthIngestOutcome> apiDepthlockIngestFrame({
    required String goalId,
    required String path,
  }) => _nativeBridge.apiDepthlockIngestFrame(goalId: goalId, path: path);
  static Future<List<gen_api.ApiDepthCurvePoint>> apiDepthlockGoalCurve({
    required String goalId,
    required int maxPoints,
  }) =>
      _nativeBridge.apiDepthlockGoalCurve(goalId: goalId, maxPoints: maxPoints);
  static Future<gen_api.ApiDepthGoal> apiDepthlockReplayGoal({
    required String goalId,
  }) => _nativeBridge.apiDepthlockReplayGoal(goalId: goalId);
}
