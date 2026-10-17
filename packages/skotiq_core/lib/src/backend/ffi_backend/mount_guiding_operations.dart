part of '../ffi_backend.dart';

mixin _FfiMountGuidingOperations on _FfiBackendBase {
  // Mount control

  @override
  Future<void> mountSlewToCoordinates(
    String deviceId,
    double ra,
    double dec,
  ) async {
    await bridge.NativeBridge.mountSlewToCoordinates(deviceId, ra, dec);
  }

  @override
  Future<void> mountSync(String deviceId, double ra, double dec) async {
    await bridge.NativeBridge.mountSync(deviceId, ra, dec);
  }

  @override
  Future<void> mountPark(String deviceId) async {
    await bridge.NativeBridge.mountPark(deviceId);
  }

  @override
  Future<void> mountUnpark(String deviceId) async {
    await bridge.NativeBridge.mountUnpark(deviceId);
  }

  @override
  Future<void> mountSetTracking(String deviceId, bool enabled) async {
    await bridge.NativeBridge.mountSetTracking(deviceId, enabled);
  }

  @override
  Future<void> mountSetTrackingRate(String deviceId, int rate) async {
    await bridge_api.mountSetTrackingRate(deviceId: deviceId, rate: rate);
  }

  @override
  Future<void> mountMoveAxis(String deviceId, int axis, double rate) async {
    await bridge_api.mountMoveAxis(deviceId: deviceId, axis: axis, rate: rate);
  }

  @override
  Future<void> mountSlewAltAz(
    String deviceId,
    double altitude,
    double azimuth,
  ) async {
    await bridge_api.mountSlewAltAz(
      deviceId: deviceId,
      altitude: altitude,
      azimuth: azimuth,
    );
  }

  @override
  Future<void> mountFindHome(String deviceId) async {
    await bridge_api.mountFindHome(deviceId: deviceId);
  }

  @override
  Future<bridge.MountSiteCapabilities> mountSiteCapabilities(
    String deviceId,
  ) async {
    return bridge_api.mountSiteCapabilities(deviceId: deviceId);
  }

  @override
  Future<bridge.MountSite> mountGetSite(String deviceId) async {
    return bridge_api.mountGetSite(deviceId: deviceId);
  }

  @override
  Future<void> mountSetSite(
    String deviceId,
    double latitudeDeg,
    double longitudeDeg,
    double? elevationM,
  ) async {
    await bridge_api.mountSetSite(
      deviceId: deviceId,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      elevationM: elevationM,
    );
  }

  @override
  Future<bridge.MountTimeInfo> mountGetTime(String deviceId) async {
    return bridge_api.mountGetTime(deviceId: deviceId);
  }

  @override
  Future<void> mountSetTime(
    String deviceId,
    int utcUnixSeconds,
    double utcOffsetHours,
  ) async {
    await bridge_api.mountSetTime(
      deviceId: deviceId,
      utcUnixSeconds: utcUnixSeconds,
      utcOffsetHours: utcOffsetHours,
    );
  }

  @override
  Future<void> mountPulseGuide({
    required String deviceId,
    required String direction,
    required int durationMs,
  }) async {
    await bridge.NativeBridge.mountPulseGuide(deviceId, direction, durationMs);
  }

  @override
  Future<void> mountAbort(String deviceId) async {
    await bridge_api.mountAbort(deviceId: deviceId);
  }

  @override
  Future<dynamic> mountGetStatus(String deviceId) async {
    return await bridge_api.apiGetMountStatus(deviceId: deviceId);
  }

  // Focuser control

  @override
  Future<void> focuserMoveTo(String deviceId, int position) async {
    await bridge.NativeBridge.focuserMoveTo(deviceId, position);
  }

  @override
  Future<void> focuserMoveRelative(String deviceId, int delta) async {
    await bridge.NativeBridge.focuserMoveRelative(deviceId, delta);
  }

  @override
  Future<void> focuserHalt(String deviceId) async {
    await bridge.NativeBridge.apiFocuserHalt(deviceId: deviceId);
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
    int useBrightestNStars = 10,
    int focuserSettleTimeMs = 500,
    String backlashCompMethod = 'Overshoot',
    int backlashIn = 350,
    int backlashOut = 0,
    int? measuredBacklashIn,
  }) async {
    final config = bridge_api.AutofocusConfigApi(
      exposureTime: exposureTime,
      stepSize: stepSize,
      stepsOut: stepsOut,
      // `AutofocusConfigApi.method` selects the curve-fitting algorithm. The
      // separate Dart `method` value describes the star metric and is not a
      // native curve enum.
      method: autofocusCurveMethodForNativeBridge(curveFitting),
      binning: binning,
      gain: gain,
      offset: offset,
      numberOfAttempts: numberOfAttempts,
      exposuresPerPoint: exposuresPerPoint,
      rSquaredThreshold: rSquaredThreshold,
      outerCropRatio: outerCropRatio,
      innerCropRatio: innerCropRatio,
      useBrightestNStars: useBrightestNStars,
      focuserSettleTimeMs: BigInt.from(focuserSettleTimeMs),
      backlashCompMethod: backlashCompMethod,
      backlashIn: backlashIn,
      backlashOut: backlashOut,
      measuredBacklashIn: measuredBacklashIn,
    );
    try {
      final bridgeResult = await bridge_api.apiRunAutofocus(
        deviceId: deviceId,
        cameraId: cameraId,
        config: config,
      );
      return _fromBridgeAutofocusResult(bridgeResult);
    } catch (error) {
      throw _toSkotiqError(error, 'Autofocus failed');
    }
  }

  @override
  Future<void> autofocusCancel() async {
    await bridge_api.apiCancelAutofocus();
  }

  @override
  Future<String> focuserBacklashCalibrationStart({
    required String deviceId,
    required String cameraId,
    required String configJson,
  }) async {
    try {
      return await bridge_api.apiRunFocuserBacklashCalibration(
        deviceId: deviceId,
        cameraId: cameraId,
        configJson: configJson,
      );
    } catch (error) {
      throw _toSkotiqError(error, 'Focuser backlash calibration failed');
    }
  }

  @override
  Future<void> focuserBacklashCalibrationCancel() async {
    await bridge_api.apiCancelFocuserBacklashCalibration();
  }

  @override
  Future<String> focuserBacklashCalibrationPlan({
    required String configJson,
    required int centerPosition,
  }) async {
    try {
      return await bridge_api.apiPlanFocuserBacklashCalibration(
        configJson: configJson,
        centerPosition: centerPosition,
      );
    } catch (error) {
      throw _toSkotiqError(
        error,
        'Could not work out what a backlash calibration would cost',
      );
    }
  }

  // Filter wheel control

  @override
  Future<void> filterWheelSetPosition(String deviceId, int position) async {
    await bridge.NativeBridge.apiFilterwheelSetPosition(
      deviceId: deviceId,
      position: position,
    );
  }

  @override
  Future<List<String>> filterWheelGetNames(String deviceId) async {
    return await bridge.NativeBridge.apiFilterwheelGetNames(deviceId: deviceId);
  }

  @override
  Future<void> filterWheelSetNames(String deviceId, List<String> names) async {
    await bridge_api.apiFilterwheelSetFilterNames(
      deviceId: deviceId,
      names: names,
    );
  }

  @override
  Future<void> filterWheelSetByName(String deviceId, String name) async {
    await bridge.NativeBridge.apiFilterwheelSetByName(
      deviceId: deviceId,
      name: name,
    );
  }

  // Rotator control

  @override
  Future<void> rotatorMoveTo(String deviceId, double angle) async {
    await bridge.NativeBridge.apiRotatorMoveTo(
      deviceId: deviceId,
      angle: angle,
    );
  }

  @override
  Future<void> rotatorMoveRelative(String deviceId, double delta) async {
    await bridge.NativeBridge.apiRotatorMoveRelative(
      deviceId: deviceId,
      delta: delta,
    );
  }

  @override
  Future<double> rotatorGetAngle(String deviceId) async {
    // Note: bridge returns RotatorStatus, we need to extract position
    // Or we can add a specific getter. api_get_rotator_status returns RotatorStatus.
    // Wait, api.rs has api_get_rotator_status.
    // But I implemented api_rotator_get_angle in real_device_ops.rs.
    // In api.rs, I implemented api_get_rotator_status which calls real_device_ops.rotator_get_angle.
    // I should probably use apiGetRotatorStatus and extract position.
    final status = await bridge.NativeBridge.apiGetRotatorStatus(
      deviceId: deviceId,
    );
    return status.position;
  }

  @override
  Future<void> rotatorHalt(String deviceId) async {
    await bridge.NativeBridge.apiRotatorHalt(deviceId: deviceId);
  }

  @override
  Future<void> rotatorSetReverse(String deviceId, bool reverse) async {
    await bridge.NativeBridge.apiRotatorSetReverse(
      deviceId: deviceId,
      reverse: reverse,
    );
  }

  @override
  Future<void> rotatorSyncToPa(String deviceId, double pa) async {
    await bridge.NativeBridge.apiRotatorSyncToPa(deviceId: deviceId, pa: pa);
  }

  // Dome control

  @override
  Future<void> domeOpenShutter(String deviceId) async {
    await bridge_api.apiDomeOpenShutter(deviceId: deviceId);
  }

  @override
  Future<void> domeCloseShutter(String deviceId) async {
    await bridge_api.apiDomeCloseShutter(deviceId: deviceId);
  }

  @override
  Future<void> domeSlewToAzimuth(String deviceId, double azimuth) async {
    await bridge_api.apiDomeSlewToAzimuth(deviceId: deviceId, azimuth: azimuth);
  }

  @override
  Future<void> domeSetSlaved(String deviceId, bool slaved) async {
    await bridge_api.apiDomeSetSlaved(deviceId: deviceId, slaved: slaved);
  }

  @override
  Future<void> domePark(String deviceId) async {
    await bridge_api.apiDomePark(deviceId: deviceId);
  }

  @override
  Future<void> domeFindHome(String deviceId) async {
    await bridge_api.apiDomeFindHome(deviceId: deviceId);
  }

  @override
  Future<void> domeAbortSlew(String deviceId) async {
    await bridge_api.apiDomeAbortSlew(deviceId: deviceId);
  }

  // Cover calibrator control

  @override
  Future<void> coverOpen(String deviceId) async {
    await bridge_api.apiCoverCalibratorOpenCover(deviceId: deviceId);
  }

  @override
  Future<void> coverClose(String deviceId) async {
    await bridge_api.apiCoverCalibratorCloseCover(deviceId: deviceId);
  }

  @override
  Future<void> calibratorOn(String deviceId, int brightness) async {
    await bridge_api.apiCoverCalibratorCalibratorOn(
      deviceId: deviceId,
      brightness: brightness,
    );
  }

  @override
  Future<void> calibratorOff(String deviceId) async {
    await bridge_api.apiCoverCalibratorCalibratorOff(deviceId: deviceId);
  }

  // PHD2 Guiding

  @override
  Future<bool> isPhd2Running({
    String host = 'localhost',
    int port = 4400,
  }) async {
    return bridge.NativeBridge.isPhd2Running(host: host, port: port);
  }

  @override
  Future<Phd2ProbeResult> phd2Probe({
    String host = 'localhost',
    int port = 4400,
  }) {
    // The FFI backend runs on the imaging host itself, so the PHD2 event
    // socket is directly reachable from this isolate.
    return probePhd2(host: host, port: port);
  }

  @override
  Future<void> phd2Connect({String host = 'localhost', int port = 4400}) async {
    await bridge.NativeBridge.phd2Connect(host: host, port: port);
  }

  @override
  Future<void> phd2Disconnect() async {
    await bridge.NativeBridge.phd2Disconnect();
  }

  @override
  Future<void> phd2StartGuiding({
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    await bridge.NativeBridge.phd2StartGuiding(
      settlePixels: settlePixels,
      settleTime: settleTime,
      settleTimeout: settleTimeout,
    );
  }

  @override
  Future<void> phd2StopGuiding() async {
    await bridge.NativeBridge.phd2StopGuiding();
  }

  @override
  Future<void> phd2Dither({
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    await bridge.NativeBridge.phd2Dither(
      amount: amount,
      raOnly: raOnly,
      settlePixels: settlePixels,
      settleTime: settleTime,
      settleTimeout: settleTimeout,
    );
  }

  @override
  Future<Phd2Status> phd2GetStatus() async {
    final status = await bridge.NativeBridge.phd2GetStatus();
    // Pull the built-in multi-star guider's per-star list off the native export
    // and decode it into `trackedStars`. Without this the host FFI backend
    // always returned `trackedStars: const []`, so the headless API serialized
    // an empty array and the guider star-list panel stayed permanently empty on
    // real hardware. The native call returns `{"count":0,"stars":[]}` when the
    // built-in guider is not the active guider (e.g. PHD2/external), so the list
    // is naturally empty for those backends — matching the aggregate-only PHD2
    // status path. Failing this lookup must not break the (load-bearing) status
    // poll, so fall back to an empty list.
    List<GuideStar> trackedStars = const [];
    try {
      final trackedStarsJson =
          await bridge.NativeBridge.builtinGuiderGetTrackedStarsJson();
      trackedStars = decodeTrackedStars(trackedStarsJson);
    } catch (_) {
      trackedStars = const [];
    }
    return Phd2Status(
      state: status.state,
      connected: status.connected,
      rmsRa: status.rmsRa,
      rmsDec: status.rmsDec,
      rmsTotal: status.rmsTotal,
      snr: status.snr,
      starMass: status.starMass,
      // FRB Phd2Status carries no avgDistance; the legacy field reports 0.
      avgDistance: 0.0,
      trackedStars: trackedStars,
    );
  }

  @override
  Future<Phd2StarImage> phd2GetStarImage({int size = 50}) async {
    final image = await bridge_api.apiPhd2GetStarImage(size: size);
    return Phd2StarImage(
      frame: image.frame,
      width: image.width,
      height: image.height,
      starX: image.starX,
      starY: image.starY,
      pixels: Uint8List.fromList(image.pixels),
    );
  }

  @override
  Future<List<String>> phd2GetAlgoParamNames({required String axis}) async {
    return await bridge.NativeBridge.phd2GetAlgoParamNames(axis: axis);
  }

  @override
  Future<double> phd2GetAlgoParam({
    required String axis,
    required String name,
  }) async {
    return await bridge.NativeBridge.phd2GetAlgoParam(axis: axis, name: name);
  }

  @override
  Future<void> phd2SetAlgoParam({
    required String axis,
    required String name,
    required double value,
  }) async {
    await bridge.NativeBridge.phd2SetAlgoParam(
      axis: axis,
      name: name,
      value: value,
    );
  }

  @override
  Future<void> phd2SetPaused(bool paused) async {
    await bridge.NativeBridge.phd2SetPaused(paused: paused);
  }

  @override
  Future<void> phd2ClearCalibration({String which = 'both'}) async {
    await bridge.NativeBridge.phd2ClearCalibration(which: which);
  }

  @override
  Future<void> phd2FlipCalibration() async {
    await bridge.NativeBridge.phd2FlipCalibration();
  }

  @override
  Future<Phd2CalibrationData> phd2GetCalibrationData() async {
    final data = await bridge.NativeBridge.phd2GetCalibrationData();
    return Phd2CalibrationData(
      isCalibrated: data.isCalibrated,
      rotationAngle: data.raAngle,
      raRate: data.raRate,
      decRate: data.decRate,
      calibratedAt: data.isCalibrated ? DateTime.now() : null,
    );
  }

  @override
  Future<(double, double)> phd2FindStar() async {
    final result = await bridge.NativeBridge.phd2FindStar();
    return (result.$1, result.$2);
  }

  @override
  Future<void> phd2SetLockPosition({
    required double x,
    required double y,
    bool exact = false,
  }) async {
    await bridge.NativeBridge.phd2SetLockPosition(x: x, y: y, exact: exact);
  }

  @override
  Future<(double, double)> phd2GetLockPosition() async {
    final result = await bridge.NativeBridge.phd2GetLockPosition();
    return (result.$1, result.$2);
  }

  @override
  Future<void> phd2Loop() async {
    await bridge.NativeBridge.phd2Loop();
  }

  @override
  Future<void> phd2DeselectStar() async {
    await bridge.NativeBridge.phd2DeselectStar();
  }

  // Generic Guiding (driver-agnostic abstraction)

  @override
  Future<void> guiderStartGuiding({
    required String deviceId,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    await bridge.NativeBridge.guiderStartGuiding(
      deviceId: deviceId,
      settlePixels: settlePixels,
      settleTime: settleTime,
      settleTimeout: settleTimeout,
    );
  }

  @override
  Future<void> guiderStopGuiding({required String deviceId}) async {
    await bridge.NativeBridge.guiderStop(deviceId: deviceId);
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
    await bridge.NativeBridge.guiderDither(
      deviceId: deviceId,
      amount: amount,
      raOnly: raOnly,
      settlePixels: settlePixels,
      settleTime: settleTime,
      settleTimeout: settleTimeout,
    );
  }

  @override
  Future<void> guiderLoop({required String deviceId}) async {
    await bridge.NativeBridge.guiderLoop(deviceId: deviceId);
  }

  @override
  Future<(double, double)> guiderFindStar({required String deviceId}) async {
    final result = await bridge.NativeBridge.guiderFindStar(deviceId: deviceId);
    return (result.$1, result.$2);
  }

  @override
  Future<void> guiderSetLockPosition({
    required String deviceId,
    required double x,
    required double y,
    bool exact = false,
  }) async {
    await bridge.NativeBridge.guiderSetLockPosition(
      deviceId: deviceId,
      x: x,
      y: y,
      exact: exact,
    );
  }

  @override
  Future<(double, double)> guiderGetLockPosition({
    required String deviceId,
  }) async {
    final result = await bridge.NativeBridge.guiderGetLockPosition(
      deviceId: deviceId,
    );
    return (result.$1, result.$2);
  }

  @override
  Future<void> guiderDeselectStar({required String deviceId}) async {
    await bridge.NativeBridge.guiderDeselectStar(deviceId: deviceId);
  }

  @override
  Future<Phd2StarImage> guiderGetStarImage({
    required String deviceId,
    int size = 50,
  }) async {
    final image = await bridge.NativeBridge.guiderGetStarImage(
      deviceId: deviceId,
      size: size,
    );
    return Phd2StarImage(
      frame: image.frame,
      width: image.width,
      height: image.height,
      starX: image.starX,
      starY: image.starY,
      pixels: image.pixels,
    );
  }

  @override
  Future<BuiltinGuiderConfig> builtinGuiderGetConfig() async {
    final raw = await bridge.NativeBridge.builtinGuiderGetConfigRaw();
    return BuiltinGuiderConfig.fromJson(raw);
  }

  @override
  Future<void> builtinGuiderSetConfig(BuiltinGuiderConfig config) async {
    await bridge.NativeBridge.builtinGuiderSetConfigRaw(
      exposureSecs: config.exposureSecs,
      gain: config.gain,
      offset: config.offset,
      binning: config.binning,
      calibrationMs: config.calibrationMs,
      settleSleepMs: config.settleSleepMs,
      minPulseMs: config.minPulseMs,
      maxPulseMs: config.maxPulseMs,
    );
  }

  // Plate solving

  @override
  Future<PlateSolveResult> plateSolve({
    required String imagePath,
    double? ra,
    double? dec,
    double? fovDegrees,
    int? timeoutSeconds,
  }) async {
    // `bridge.NativeBridge.plateSolve*` already returns the FRB-canonical
    // `PlateSolveResult` (see `bridge_stub.dart` typedef), so no conversion
    // is needed since the model-layer copy was removed.
    return ra != null && dec != null
        ? bridge.NativeBridge.plateSolveNear(
            imagePath,
            ra,
            dec,
            fovDegrees ?? 30.0,
            timeoutSeconds,
          )
        : bridge.NativeBridge.plateSolveBlind(imagePath, timeoutSeconds);
  }

  // Plate Solver Setup (local — runs against this machine's filesystem)

  @override
  Future<PlateSolverDetection> detectPlateSolvers() async {
    final native = bridge_api.apiPlatesolveDetect();
    return PlateSolverDetection(
      astapPath: native.astapPath,
      astrometryPath: native.astrometryPath,
      catalogName: native.catalogName,
      catalogMagnitudeLimit: native.catalogMagnitudeLimit?.toDouble(),
      catalogPath: native.catalogPath,
    );
  }

  @override
  Future<PlateSolverInfo> verifyPlateSolver(String executablePath) async {
    final info = await bridge_api.apiPlatesolveVerify(
      executablePath: executablePath,
    );
    return PlateSolverInfo(
      path: info.path,
      flavour: info.flavour,
      versionLine: info.versionLine,
    );
  }

  @override
  Future<PlateSolverPreference> getPlateSolverConfig() async {
    final payload = bridge_api.apiPlatesolveGetConfig();
    return PlateSolverPreference(
      astapPath: payload.astapPath,
      astrometryPath: payload.astrometryPath,
      catalogPath: payload.catalogPath,
      choice: PlateSolverChoice.fromSerialized(payload.solverChoice),
    );
  }

  @override
  Future<void> setPlateSolverConfig(PlateSolverPreference pref) async {
    bridge_api.apiPlatesolveSetConfig(
      config: bridge_api.PlateSolverConfigPayload(
        astapPath: pref.astapPath,
        astrometryPath: pref.astrometryPath,
        catalogPath: pref.catalogPath,
        solverChoice: pref.choice.serialized,
      ),
    );
  }
}
