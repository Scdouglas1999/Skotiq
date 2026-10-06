import 'dart:async';
import 'dart:typed_data';
import '../models/autofocus_progress.dart' show StarCrop;
import '../models/imaging/imaging_models.dart';
import '../models/plate_solver.dart'
    show PlateSolverDetection, PlateSolverInfo, PlateSolverPreference;
import '../models/equipment_profile.dart';
import '../models/phd2_models.dart';
import '../services/phd2_probe.dart';
import '../models/depthlock/depthlock_models.dart';
import '../models/settings/app_settings.dart' as models;
import '../models/sequence/sequence_models.dart'
    show AdaptiveSwapSnapshot, ConditionsScore;
import '../providers/settings_provider.dart';
import 'nightshade_backend.dart';
import 'nightshade_exception.dart' show ConnectionException;

part 'disconnected_backend/profile_and_image.dart';

// Import pure Dart types from backend_types

/// A backend implementation that represents a disconnected state.
///
/// This is the default state for the mobile app. It throws clear, user-friendly
/// exceptions for all operations, so no local logic (like FFI) runs while the
/// app should be acting as a thin client.
class DisconnectedBackend
    with _DisconnectedBackendProfileAndImage
    implements NightshadeBackend {
  final _eventController = StreamController<NightshadeEvent>.broadcast();

  @override
  bool get dispatchPluginNodesLocally => true;

  @override
  Stream<NightshadeEvent> get eventStream => _eventController.stream;

  @override
  void dispose() {
    _eventController.close();
    _polarAlignController.close();
  }

  @override
  Never _throwNotConnected() {
    throw const ConnectionException(
      message:
          'Not connected to server. Please connect to a Nightshade Headless Server first.',
      userMessage: 'Not connected to a Nightshade Headless Server',
    );
  }

  @override
  Future<List<DeviceInfo>> discoverDevices(DeviceType deviceType) async {
    _throwNotConnected();
  }

  @override
  Future<List<DeviceInfo>> discoverIndiAtAddress(String host, int port) async {
    _throwNotConnected();
  }

  @override
  Future<List<DeviceInfo>> discoverAlpacaAtAddress(
    String host,
    int port,
  ) async {
    _throwNotConnected();
  }

  @override
  Future<void> connectDevice(DeviceType deviceType, String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> disconnectDevice(DeviceType deviceType, String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async {
    _throwNotConnected();
  }

  @override
  Future<void> rescanDevices() async {
    _throwNotConnected();
  }

  @override
  Future<void> cameraStartExposure({
    required String deviceId,
    required double exposureTime,
    required FrameType frameType,
    int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    int? x,
    int? y,
    int? width,
    int? height,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> cameraAbortExposure(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<CapturedImageResult?> cameraGetLastImage(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<Uint8List> cameraLiveViewFrame(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> cameraSetCooling({
    required String deviceId,
    required bool enabled,
    double? targetTemp,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> cameraSetReadoutMode(String deviceId, int modeIndex) async {
    _throwNotConnected();
  }

  @override
  Future<void> cameraSetGain(String deviceId, int gain) async {
    _throwNotConnected();
  }

  @override
  Future<void> cameraSetOffset(String deviceId, int offset) async {
    _throwNotConnected();
  }

  @override
  Future<CameraRecommendedSettings> cameraGetRecommendedSettings(
    String deviceId,
  ) async {
    _throwNotConnected();
  }

  @override
  Future<void> mountSlewToCoordinates(
    String deviceId,
    double ra,
    double dec,
  ) async {
    _throwNotConnected();
  }

  @override
  Future<void> mountSync(String deviceId, double ra, double dec) async {
    _throwNotConnected();
  }

  @override
  Future<void> mountPark(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> mountUnpark(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> mountSetTracking(String deviceId, bool enabled) async {
    _throwNotConnected();
  }

  @override
  Future<void> mountPulseGuide({
    required String deviceId,
    required String direction,
    required int durationMs,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> mountAbort(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<dynamic> mountGetStatus(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> mountSetTrackingRate(String deviceId, int rate) async {
    _throwNotConnected();
  }

  @override
  Future<void> mountMoveAxis(String deviceId, int axis, double rate) async {
    _throwNotConnected();
  }

  @override
  Future<void> mountSlewAltAz(
    String deviceId,
    double altitude,
    double azimuth,
  ) async {
    _throwNotConnected();
  }

  @override
  Future<void> mountFindHome(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<MountSiteCapabilities> mountSiteCapabilities(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<MountSite> mountGetSite(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> mountSetSite(
    String deviceId,
    double latitudeDeg,
    double longitudeDeg,
    double? elevationM,
  ) async {
    _throwNotConnected();
  }

  @override
  Future<MountTimeInfo> mountGetTime(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> mountSetTime(
    String deviceId,
    int utcUnixSeconds,
    double utcOffsetHours,
  ) async {
    _throwNotConnected();
  }

  @override
  Future<void> focuserMoveTo(String deviceId, int position) async {
    _throwNotConnected();
  }

  @override
  Future<void> focuserMoveRelative(String deviceId, int delta) async {
    _throwNotConnected();
  }

  @override
  Future<void> focuserHalt(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<AutofocusResult> autofocusStart({
    required String deviceId,
    required String cameraId,
    required double exposureTime,
    required int stepSize,
    required int stepsOut,
    String method = 'VCurve',
    int binning = 1,
    int? gain,
    int? offset,
    String curveFitting = 'Hyperbolic',
    int numberOfAttempts = 1,
    int exposuresPerPoint = 1,
    double rSquaredThreshold = 0.7,
    double outerCropRatio = 1.0,
    double innerCropRatio = 0.0,
    int useBrightestNStars = 0,
    int focuserSettleTimeMs = 500,
    String backlashCompMethod = 'Overshoot',
    int backlashIn = 350,
    int backlashOut = 0,
    int? measuredBacklashIn,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> autofocusCancel() async {
    _throwNotConnected();
  }

  @override
  Future<String> focuserBacklashCalibrationStart({
    required String deviceId,
    required String cameraId,
    required String configJson,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> focuserBacklashCalibrationCancel() async {
    _throwNotConnected();
  }

  @override
  Future<String> focuserBacklashCalibrationPlan({
    required String configJson,
    required int centerPosition,
  }) async {
    _throwNotConnected();
  }

  // Filter Wheel Control

  @override
  Future<void> filterWheelSetPosition(String deviceId, int position) async {
    _throwNotConnected();
  }

  @override
  Future<bool> isPhd2Running({
    String host = 'localhost',
    int port = 4400,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<Phd2ProbeResult> phd2Probe({
    String host = 'localhost',
    int port = 4400,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> phd2Connect({String host = 'localhost', int port = 4400}) async {
    _throwNotConnected();
  }

  @override
  Future<void> phd2Disconnect() async {
    _throwNotConnected();
  }

  @override
  Future<void> phd2StartGuiding({
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> phd2StopGuiding() async {
    _throwNotConnected();
  }

  @override
  Future<void> phd2Dither({
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<Phd2Status> phd2GetStatus() async {
    _throwNotConnected();
  }

  @override
  Future<Phd2StarImage> phd2GetStarImage({int size = 50}) async {
    _throwNotConnected();
  }

  @override
  Future<List<String>> phd2GetAlgoParamNames({required String axis}) async {
    _throwNotConnected();
  }

  @override
  Future<double> phd2GetAlgoParam({
    required String axis,
    required String name,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> phd2SetAlgoParam({
    required String axis,
    required String name,
    required double value,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> phd2SetPaused(bool paused) async {
    _throwNotConnected();
  }

  @override
  Future<void> phd2ClearCalibration({String which = 'both'}) async {
    _throwNotConnected();
  }

  @override
  Future<void> phd2FlipCalibration() async {
    _throwNotConnected();
  }

  @override
  Future<Phd2CalibrationData> phd2GetCalibrationData() async {
    _throwNotConnected();
  }

  @override
  Future<(double, double)> phd2FindStar() async {
    _throwNotConnected();
  }

  @override
  Future<void> phd2SetLockPosition({
    required double x,
    required double y,
    bool exact = false,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<(double, double)> phd2GetLockPosition() async {
    _throwNotConnected();
  }

  @override
  Future<void> phd2Loop() async {
    _throwNotConnected();
  }

  @override
  Future<void> phd2DeselectStar() async {
    _throwNotConnected();
  }

  // Generic Guiding (driver-agnostic abstraction)

  @override
  Future<void> guiderStartGuiding({
    required String deviceId,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> guiderStopGuiding({required String deviceId}) async {
    _throwNotConnected();
  }

  @override
  Future<void> guiderDither({
    required String deviceId,
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> guiderLoop({required String deviceId}) async {
    _throwNotConnected();
  }

  @override
  Future<(double, double)> guiderFindStar({required String deviceId}) async {
    _throwNotConnected();
  }

  @override
  Future<void> guiderSetLockPosition({
    required String deviceId,
    required double x,
    required double y,
    bool exact = false,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<(double, double)> guiderGetLockPosition({
    required String deviceId,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> guiderDeselectStar({required String deviceId}) async {
    _throwNotConnected();
  }

  @override
  Future<Phd2StarImage> guiderGetStarImage({
    required String deviceId,
    int size = 50,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<BuiltinGuiderConfig> builtinGuiderGetConfig() async {
    _throwNotConnected();
  }

  @override
  Future<void> builtinGuiderSetConfig(BuiltinGuiderConfig config) async {
    _throwNotConnected();
  }

  @override
  Future<PlateSolveResult> plateSolve({
    required String imagePath,
    double? ra,
    double? dec,
    double? fovDegrees,
    int? timeoutSeconds,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerStart() async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerStop({String? origin}) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerPause() async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerResume() async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerSkip() async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerSkipToNode(String nodeId) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerPluginNodeFinished({
    required String nodeId,
    required bool success,
    String? message,
    String? structuredDetailJson,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerReset() async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerLoadJson(String json) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerSetSimulationMode(bool enabled) async {
    _throwNotConnected();
  }

  @override
  Future<bool> sequencerIsSimulationMode() async {
    _throwNotConnected();
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
    _throwNotConnected();
  }

  @override
  Future<void> sequencerSetSafetyFailMode(String mode) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerSetParkPolicy({
    required bool parkOnUnsafeWeather,
    required bool parkBeforeDawn,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerSetDeviceRetries({
    required int cameraRetries,
    required int filterWheelRetries,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerSetSafetyCheckIntervalSeconds(int seconds) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerSetSavePath(String? path) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerSetActiveSequenceRunId(int? sequenceRunId) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerSetDecisionLoggingEnabled(bool enabled) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerUpdateDitherConfig({
    required double pixels,
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
    required bool raOnly,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerUpdateMeridianFlipConfig(String configJson) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerUpdateLocation({
    required double latitude,
    required double longitude,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerUpdateFilterOffsets(Map<String, int> offsets) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerUpdatePendingIntegrationCarryOver(
    Map<String, Map<String, double>> carryOver,
  ) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerUpdateAutofocusInterval(int everyNFrames) async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerUpdateAutofocusConfig(String configJson) async {
    _throwNotConnected();
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
    _throwNotConnected();
  }

  @override
  Future<void> sequencerUpdateRejectFolderPath(String? path) async {
    _throwNotConnected();
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
    _throwNotConnected();
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
    _throwNotConnected();
  }

  @override
  Future<void> sequencerUpdateWeatherVerdict({bool? unsafeOverride}) async {
    _throwNotConnected();
  }

  @override
  Future<String?> sequencerGetCloudMotionJson() async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerUpdateConditionsScore(ConditionsScore? score) async {
    _throwNotConnected();
  }

  @override
  Future<AdaptiveSwapSnapshot?> sequencerGetAdaptiveSwapSnapshot() async {
    _throwNotConnected();
  }

  @override
  Future<void> sequencerUpdateSkyBrightness({required double? mag}) async {
    _throwNotConnected();
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
    _throwNotConnected();
  }

  @override
  Future<void> sequencerClearDefaultAdaptiveExposure() async {
    _throwNotConnected();
  }

  // Recovery mode

  @override
  Future<void> recoveryTryNow() async {
    _throwNotConnected();
  }

  @override
  Future<void> recoveryAbort() async {
    _throwNotConnected();
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
    _throwNotConnected();
  }

  @override
  Future<String?> getCurrentRecoveryJson() async {
    _throwNotConnected();
  }

  @override
  Future<String> getRecoveryHistoryJson() async {
    _throwNotConnected();
  }

  @override
  Future<SequencerStatus> sequencerGetStatus() async {
    _throwNotConnected();
  }

  // Checkpoint / Crash Recovery

  @override
  Future<void> sequencerSetCheckpointDir(String path) async {
    _throwNotConnected();
  }

  @override
  Future<bool> hasCheckpoint() async {
    _throwNotConnected();
  }

  @override
  Future<CheckpointInfo?> getCheckpointInfo() async {
    _throwNotConnected();
  }

  @override
  Future<void> resumeFromCheckpoint() async {
    _throwNotConnected();
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
    _throwNotConnected();
  }

  @override
  Future<void> discardCheckpoint() async {
    _throwNotConnected();
  }

  @override
  Future<void> saveCheckpoint() async {
    _throwNotConnected();
  }

  @override
  Future<LocationSettings> getLocationFromInternet() async {
    _throwNotConnected();
  }

  // Equipment status

  @override
  Future<CameraStatus> getCameraStatus(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<MountStatus> getMountStatus(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<FocuserStatus> getFocuserStatus(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<FilterWheelStatus> getFilterWheelStatus(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<RotatorStatus> getRotatorStatus(String deviceId) async {
    _throwNotConnected();
  }

  // Device capabilities

  @override
  Future<CameraCapabilities?> getCameraCapabilities(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<MountCapabilities?> getMountCapabilities(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<FocuserCapabilities?> getFocuserCapabilities(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<FilterWheelCapabilities?> getFilterWheelCapabilities(
    String deviceId,
  ) async {
    _throwNotConnected();
  }

  @override
  Future<RotatorCapabilities?> getRotatorCapabilities(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<List<String>> filterWheelGetNames(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> filterWheelSetNames(String deviceId, List<String> names) async {
    _throwNotConnected();
  }

  @override
  Future<void> filterWheelSetByName(String deviceId, String name) async {
    _throwNotConnected();
  }

  @override
  Future<void> rotatorMoveTo(String deviceId, double angle) async {
    _throwNotConnected();
  }

  @override
  Future<void> rotatorSetReverse(String deviceId, bool reverse) async {
    _throwNotConnected();
  }

  @override
  Future<void> rotatorMoveRelative(String deviceId, double delta) async {
    _throwNotConnected();
  }

  @override
  Future<double> rotatorGetAngle(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> rotatorHalt(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> rotatorSyncToPa(String deviceId, double pa) async {
    _throwNotConnected();
  }

  // Dome control

  @override
  Future<void> domeOpenShutter(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> domeCloseShutter(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> domeSlewToAzimuth(String deviceId, double azimuth) async {
    _throwNotConnected();
  }

  @override
  Future<void> domeSetSlaved(String deviceId, bool slaved) async {
    _throwNotConnected();
  }

  @override
  Future<void> domePark(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> domeFindHome(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> domeAbortSlew(String deviceId) async {
    _throwNotConnected();
  }

  // Cover calibrator control

  @override
  Future<void> coverOpen(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> coverClose(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> calibratorOn(String deviceId, int brightness) async {
    _throwNotConnected();
  }

  @override
  Future<void> calibratorOff(String deviceId) async {
    _throwNotConnected();
  }
}
