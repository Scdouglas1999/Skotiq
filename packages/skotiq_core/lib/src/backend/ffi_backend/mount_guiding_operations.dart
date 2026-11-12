part of '../ffi_backend.dart';

mixin _FfiMountGuidingOperations on _FfiBackendBase {

  @override
  Future<void> mountSlewToCoordinates(
    String deviceId,
    double ra,
    double dec,
  ) async {
    await _native(
      'mountSlewToCoordinates',
      () => bridge.apiMountSlewToCoordinates(
        deviceId: deviceId,
        ra: ra,
        dec: dec,
      ),
    );
  }

  @override
  Future<void> mountSync(String deviceId, double ra, double dec) async {
    await _native(
      'mountSync',
      () => bridge.apiMountSyncToCoordinates(
        deviceId: deviceId,
        ra: ra,
        dec: dec,
      ),
    );
  }

  @override
  Future<void> mountPark(String deviceId) async {
    await _native('mountPark', () => bridge.apiMountPark(deviceId: deviceId));
  }

  @override
  Future<void> mountUnpark(String deviceId) async {
    await _native(
      'mountUnpark',
      () => bridge.apiMountUnpark(deviceId: deviceId),
    );
  }

  @override
  Future<void> mountSetTracking(String deviceId, bool enabled) async {
    await _native(
      'mountSetTracking',
      () => bridge.apiMountSetTracking(
        deviceId: deviceId,
        enabled: enabled ? 1 : 0,
      ),
    );
  }

  @override
  Future<void> mountSetTrackingRate(String deviceId, int rate) async {
    await bridge.mountSetTrackingRate(deviceId: deviceId, rate: rate);
  }

  @override
  Future<void> mountMoveAxis(String deviceId, int axis, double rate) async {
    await bridge.mountMoveAxis(deviceId: deviceId, axis: axis, rate: rate);
  }

  @override
  Future<void> mountSlewAltAz(
    String deviceId,
    double altitude,
    double azimuth,
  ) async {
    await bridge.mountSlewAltAz(
      deviceId: deviceId,
      altitude: altitude,
      azimuth: azimuth,
    );
  }

  @override
  Future<void> mountFindHome(String deviceId) async {
    await bridge.mountFindHome(deviceId: deviceId);
  }

  @override
  Future<void> mountSetPark(String deviceId) async {
    await bridge.mountSetPark(deviceId: deviceId);
  }

  @override
  Future<bridge.MountSiteCapabilities> mountSiteCapabilities(
    String deviceId,
  ) async {
    return bridge.mountSiteCapabilities(deviceId: deviceId);
  }

  @override
  Future<bridge.MountSite> mountGetSite(String deviceId) async {
    return bridge.mountGetSite(deviceId: deviceId);
  }

  @override
  Future<void> mountSetSite(
    String deviceId,
    double latitudeDeg,
    double longitudeDeg,
    double? elevationM,
  ) async {
    await bridge.mountSetSite(
      deviceId: deviceId,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      elevationM: elevationM,
    );
  }

  @override
  Future<bridge.MountTimeInfo> mountGetTime(String deviceId) async {
    return bridge.mountGetTime(deviceId: deviceId);
  }

  @override
  Future<void> mountSetTime(
    String deviceId,
    int utcUnixSeconds,
    double utcOffsetHours,
  ) async {
    await bridge.mountSetTime(
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
    await _native(
      'mountPulseGuide',
      () => bridge.apiMountPulseGuide(
        deviceId: deviceId,
        direction: direction,
        durationMs: durationMs,
      ),
    );
  }

  @override
  Future<void> mountAbort(String deviceId) async {
    await bridge.mountAbort(deviceId: deviceId);
  }

  @override
  Future<dynamic> mountGetStatus(String deviceId) async {
    return await bridge.apiGetMountStatus(deviceId: deviceId);
  }

  @override
  Future<void> focuserMoveTo(String deviceId, int position) async {
    await _native(
      'focuserMoveTo',
      () => bridge.apiFocuserMoveTo(deviceId: deviceId, position: position),
    );
  }

  @override
  Future<void> focuserMoveRelative(String deviceId, int delta) async {
    await _native(
      'focuserMoveRelative',
      () => bridge.apiFocuserMoveRelative(deviceId: deviceId, delta: delta),
    );
  }

  @override
  Future<void> focuserHalt(String deviceId) async {
    await _native(
      'apiFocuserHalt',
      () => bridge.apiFocuserHalt(deviceId: deviceId),
    );
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
    final config = bridge.AutofocusConfigApi(
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
      final bridgeResult = await bridge.apiRunAutofocus(
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
    await bridge.apiCancelAutofocus();
  }

  @override
  Future<String> focuserBacklashCalibrationStart({
    required String deviceId,
    required String cameraId,
    required String configJson,
  }) async {
    try {
      return await bridge.apiRunFocuserBacklashCalibration(
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
    await bridge.apiCancelFocuserBacklashCalibration();
  }

  @override
  Future<String> focuserBacklashCalibrationPlan({
    required String configJson,
    required int centerPosition,
  }) async {
    try {
      return await bridge.apiPlanFocuserBacklashCalibration(
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

  @override
  Future<void> filterWheelSetPosition(String deviceId, int position) async {
    await _native(
      'apiFilterwheelSetPosition',
      () => bridge.apiFilterwheelSetPosition(
        deviceId: deviceId,
        position: position,
      ),
    );
  }

  @override
  Future<List<String>> filterWheelGetNames(String deviceId) async {
    final status = await _native(
      'getFilterWheelStatus',
      () => bridge.apiGetFilterwheelStatus(deviceId: deviceId),
    );
    return status.filterNames;
  }

  @override
  Future<void> filterWheelSetNames(String deviceId, List<String> names) async {
    await bridge.apiFilterwheelSetFilterNames(deviceId: deviceId, names: names);
  }

  @override
  Future<void> filterWheelSetByName(String deviceId, String name) async {
    final names = await filterWheelGetNames(deviceId);
    final index = names.indexOf(name);
    if (index < 0) {
      throw ArgumentError('Filter "$name" not found on device $deviceId');
    }
    await filterWheelSetPosition(deviceId, index);
  }

  @override
  Future<void> rotatorMoveTo(String deviceId, double angle) async {
    await _native(
      'apiRotatorMoveTo',
      () => bridge.apiRotatorMoveTo(deviceId: deviceId, angle: angle),
    );
  }

  @override
  Future<void> rotatorMoveRelative(String deviceId, double delta) async {
    await _native(
      'apiRotatorMoveRelative',
      () => bridge.apiRotatorMoveRelative(deviceId: deviceId, delta: delta),
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
    final status = await _native(
      'apiGetRotatorStatus',
      () => bridge.apiGetRotatorStatus(deviceId: deviceId),
    );
    return status.position;
  }

  @override
  Future<void> rotatorHalt(String deviceId) async {
    await _native(
      'apiRotatorHalt',
      () => bridge.apiRotatorHalt(deviceId: deviceId),
    );
  }

  @override
  Future<void> rotatorSetReverse(String deviceId, bool reverse) async {
    await _native(
      'apiRotatorSetReverse',
      () => bridge.apiRotatorSetReverse(deviceId: deviceId, reverse: reverse),
    );
  }

  @override
  Future<void> rotatorSyncToPa(String deviceId, double pa) async {
    await _native(
      'apiRotatorSyncToPa',
      () => bridge.apiRotatorSyncToPa(deviceId: deviceId, pa: pa),
    );
  }

  @override
  Future<void> domeOpenShutter(String deviceId) async {
    await bridge.apiDomeOpenShutter(deviceId: deviceId);
  }

  @override
  Future<void> domeCloseShutter(String deviceId) async {
    await bridge.apiDomeCloseShutter(deviceId: deviceId);
  }

  @override
  Future<void> domeSlewToAzimuth(String deviceId, double azimuth) async {
    await bridge.apiDomeSlewToAzimuth(deviceId: deviceId, azimuth: azimuth);
  }

  @override
  Future<void> domeSetSlaved(String deviceId, bool slaved) async {
    await bridge.apiDomeSetSlaved(deviceId: deviceId, slaved: slaved);
  }

  @override
  Future<void> domePark(String deviceId) async {
    await bridge.apiDomePark(deviceId: deviceId);
  }

  @override
  Future<void> domeFindHome(String deviceId) async {
    await bridge.apiDomeFindHome(deviceId: deviceId);
  }

  @override
  Future<void> domeAbortSlew(String deviceId) async {
    await bridge.apiDomeAbortSlew(deviceId: deviceId);
  }

  @override
  Future<void> coverOpen(String deviceId) async {
    await bridge.apiCoverCalibratorOpenCover(deviceId: deviceId);
  }

  @override
  Future<void> coverClose(String deviceId) async {
    await bridge.apiCoverCalibratorCloseCover(deviceId: deviceId);
  }

  @override
  Future<void> calibratorOn(String deviceId, int brightness) async {
    await bridge.apiCoverCalibratorCalibratorOn(
      deviceId: deviceId,
      brightness: brightness,
    );
  }

  @override
  Future<void> calibratorOff(String deviceId) async {
    await bridge.apiCoverCalibratorCalibratorOff(deviceId: deviceId);
  }

  @override
  Future<bool> isPhd2Running({
    String host = 'localhost',
    int port = 4400,
  }) async {
    // A plain TCP reachability probe, not a device operation: it tells the
    // operator whether the host/port they typed is live before any connect,
    // so it works with or without the native library.
    try {
      final socket = await Socket.connect(
        resolvePhd2ConnectHost(host),
        port,
        timeout: const Duration(seconds: 1),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
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
    await _native(
      'phd2Connect',
      () => bridge.apiPhd2Connect(host: host, port: port),
    );
  }

  @override
  Future<void> phd2Disconnect() async {
    await _native('phd2Disconnect', () => bridge.apiPhd2Disconnect());
  }

  @override
  Future<void> phd2StartGuiding({
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    await _native(
      'phd2StartGuiding',
      () => bridge.apiPhd2StartGuiding(
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: settleTimeout,
      ),
    );
  }

  @override
  Future<void> phd2StopGuiding() async {
    await _native('phd2StopGuiding', () => bridge.apiPhd2StopGuiding());
  }

  @override
  Future<void> phd2Dither({
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    await _native(
      'phd2Dither',
      () => bridge.apiPhd2Dither(
        amount: amount,
        raOnly: raOnly ? 1 : 0,
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: settleTimeout,
      ),
    );
  }

  @override
  Future<Phd2Status> phd2GetStatus() async {
    // A status the UI polls, not a command: without the native library
    // "disconnected" is the truthful answer, so this does not refuse.
    final status = bridge.NativeBridge.isNativeAvailable
        ? await bridge.apiPhd2GetStatus()
        : const bridge.Phd2Status(
            connected: false,
            state: 'Disconnected',
            rmsRa: 0,
            rmsDec: 0,
            rmsTotal: 0,
            snr: 0,
            starMass: 0,
          );
    return _guiderStatus(status);
  }

  @override
  Future<Phd2StarImage> phd2GetStarImage({int size = 50}) async {
    final image = await bridge.apiPhd2GetStarImage(size: size);
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
    return await _native(
      'phd2GetAlgoParamNames',
      () => bridge.apiPhd2GetAlgoParamNames(axis: axis),
    );
  }

  @override
  Future<double> phd2GetAlgoParam({
    required String axis,
    required String name,
  }) async {
    return await _native(
      'phd2GetAlgoParam',
      () => bridge.apiPhd2GetAlgoParam(axis: axis, name: name),
    );
  }

  @override
  Future<void> phd2SetAlgoParam({
    required String axis,
    required String name,
    required double value,
  }) async {
    await _native(
      'phd2SetAlgoParam',
      () => bridge.apiPhd2SetAlgoParam(axis: axis, name: name, value: value),
    );
  }

  @override
  Future<void> phd2SetPaused(bool paused) async {
    await _native(
      'phd2SetPaused',
      () => bridge.apiPhd2SetPaused(paused: paused),
    );
  }

  @override
  Future<void> phd2ClearCalibration({String which = 'both'}) async {
    await _native(
      'phd2ClearCalibration',
      () => bridge.apiPhd2ClearCalibration(which: which),
    );
  }

  @override
  Future<void> phd2FlipCalibration() async {
    await _native('phd2FlipCalibration', () => bridge.apiPhd2FlipCalibration());
  }

  @override
  Future<Phd2CalibrationData> phd2GetCalibrationData() async {
    final data = await _native(
      'phd2GetCalibrationData',
      () => bridge.apiPhd2GetCalibrationData(),
    );
    return _calibrationData(data);
  }

  @override
  Future<(double, double)> phd2FindStar() async {
    final result = await _native(
      'phd2FindStar',
      () => bridge.apiPhd2FindStar(),
    );
    return (result.$1, result.$2);
  }

  @override
  Future<void> phd2SetLockPosition({
    required double x,
    required double y,
    bool exact = false,
  }) async {
    await _native(
      'phd2SetLockPosition',
      () => bridge.apiPhd2SetLockPosition(x: x, y: y, exact: exact),
    );
  }

  @override
  Future<(double, double)> phd2GetLockPosition() async {
    final result = await _native(
      'phd2GetLockPosition',
      () => bridge.apiPhd2GetLockPosition(),
    );
    return (result.$1, result.$2);
  }

  @override
  Future<void> phd2Loop() async {
    await _native('phd2Loop', () => bridge.apiPhd2Loop());
  }

  @override
  Future<void> phd2DeselectStar() async {
    await _native('phd2DeselectStar', () => bridge.apiPhd2DeselectStar());
  }

  @override
  Future<void> guiderStartGuiding({
    required String deviceId,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    await _native(
      'guiderStartGuiding',
      () => bridge.apiGuiderStartGuiding(
        deviceId: _canonicalGuiderDeviceId(deviceId),
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: settleTimeout,
      ),
    );
  }

  @override
  Future<void> guiderStopGuiding({required String deviceId}) async {
    await _native(
      'guiderStop',
      () => bridge.apiGuiderStop(deviceId: _canonicalGuiderDeviceId(deviceId)),
    );
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
    await _native(
      'guiderDither',
      () => bridge.apiGuiderDither(
        deviceId: _canonicalGuiderDeviceId(deviceId),
        amount: amount,
        raOnly: raOnly ? 1 : 0,
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: settleTimeout,
      ),
    );
  }

  @override
  Future<void> guiderLoop({required String deviceId}) async {
    await _native(
      'guiderLoop',
      () => bridge.apiGuiderLoop(deviceId: _canonicalGuiderDeviceId(deviceId)),
    );
  }

  @override
  Future<(double, double)> guiderFindStar({required String deviceId}) async {
    final result = await _native(
      'guiderFindStar',
      () => bridge.apiGuiderFindStar(
        deviceId: _canonicalGuiderDeviceId(deviceId),
      ),
    );
    return (result.$1, result.$2);
  }

  @override
  Future<void> guiderSetLockPosition({
    required String deviceId,
    required double x,
    required double y,
    bool exact = false,
  }) async {
    await _native(
      'guiderSetLockPosition',
      () => bridge.apiGuiderSetLockPosition(
        deviceId: _canonicalGuiderDeviceId(deviceId),
        x: x,
        y: y,
        exact: exact,
      ),
    );
  }

  @override
  Future<(double, double)> guiderGetLockPosition({
    required String deviceId,
  }) async {
    final result = await _native(
      'guiderGetLockPosition',
      () => bridge.apiGuiderGetLockPosition(
        deviceId: _canonicalGuiderDeviceId(deviceId),
      ),
    );
    return (result.$1, result.$2);
  }

  @override
  Future<void> guiderDeselectStar({required String deviceId}) async {
    await _native(
      'guiderDeselectStar',
      () => bridge.apiGuiderDeselectStar(
        deviceId: _canonicalGuiderDeviceId(deviceId),
      ),
    );
  }

  @override
  Future<Phd2StarImage> guiderGetStarImage({
    required String deviceId,
    int size = 50,
  }) async {
    final image = await _native(
      'guiderGetStarImage',
      () => bridge.apiGuiderGetStarImage(
        deviceId: _canonicalGuiderDeviceId(deviceId),
        size: size,
      ),
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
  Future<Phd2Status> guiderGetStatus({required String deviceId}) async {
    // A status the UI polls, not a command: without the native library
    // "disconnected" is the truthful answer, so this does not refuse.
    if (!bridge.NativeBridge.isNativeAvailable) {
      return const Phd2Status(state: 'Disconnected', connected: false);
    }
    final id = _canonicalGuiderDeviceId(deviceId);
    final status = await bridge.apiGuiderGetStatus(deviceId: id);
    // Only the built-in multi-star guider tracks more than its lock star.
    final trackedStars = id == builtinGuiderDeviceId
        ? decodeTrackedStars(
            await bridge.apiBuiltinGuiderGetTrackedStarsJson(),
          )
        : const <GuideStar>[];
    return _guiderStatus(status, trackedStars: trackedStars);
  }

  @override
  Future<Phd2CalibrationData> guiderGetCalibration({
    required String deviceId,
  }) async {
    final data = await _native(
      'guiderGetCalibration',
      () => bridge.apiGuiderGetCalibration(
        deviceId: _canonicalGuiderDeviceId(deviceId),
      ),
    );
    return _calibrationData(data);
  }

  @override
  Future<BuiltinGuiderConfig> builtinGuiderGetConfig() async {
    final config = await _native(
      'builtinGuiderGetConfig',
      () => bridge.apiBuiltinGuiderGetConfig(),
    );
    return BuiltinGuiderConfig.fromJson({
      'exposureSecs': config.exposureSecs,
      'gain': config.gain,
      'offset': config.offset,
      'binning': config.binning,
      'calibrationMs': config.calibrationMs,
      'settleSleepMs': config.settleSleepMs.toInt(),
      'minPulseMs': config.minPulseMs,
      'maxPulseMs': config.maxPulseMs,
    });
  }

  @override
  Future<void> builtinGuiderSetConfig(BuiltinGuiderConfig config) async {
    await _native(
      'builtinGuiderSetConfig',
      () => bridge.apiBuiltinGuiderSetConfig(
        exposureSecs: config.exposureSecs,
        gain: config.gain,
        offset: config.offset,
        binning: config.binning,
        calibrationMs: config.calibrationMs,
        settleSleepMs: BigInt.from(config.settleSleepMs),
        minPulseMs: config.minPulseMs,
        maxPulseMs: config.maxPulseMs,
      ),
    );
  }

  @override
  Future<PlateSolveResult> plateSolve({
    required String imagePath,
    double? ra,
    double? dec,
    double? fovDegrees,
    int? timeoutSeconds,
  }) async {
    if (ra != null && dec != null) {
      bridge.NativeBridge.requireNative('plateSolveNear');
      return bridge.apiPlateSolveNear(
        filePath: imagePath,
        hintRa: ra,
        hintDec: dec,
        searchRadius: fovDegrees ?? 30.0,
        timeoutSecs: timeoutSeconds,
      );
    }
    bridge.NativeBridge.requireNative('plateSolveBlind');
    return bridge.apiPlateSolveBlind(
      filePath: imagePath,
      timeoutSecs: timeoutSeconds,
    );
  }

  // Plate Solver Setup (local — runs against this machine's filesystem)

  @override
  Future<PlateSolverDetection> detectPlateSolvers() async {
    final native = bridge.apiPlatesolveDetect();
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
    final info = await bridge.apiPlatesolveVerify(
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
    final payload = bridge.apiPlatesolveGetConfig();
    return PlateSolverPreference(
      astapPath: payload.astapPath,
      astrometryPath: payload.astrometryPath,
      catalogPath: payload.catalogPath,
      choice: PlateSolverChoice.fromSerialized(payload.solverChoice),
    );
  }

  @override
  Future<void> setPlateSolverConfig(PlateSolverPreference pref) async {
    bridge.apiPlatesolveSetConfig(
      config: bridge.PlateSolverConfigPayload(
        astapPath: pref.astapPath,
        astrometryPath: pref.astrometryPath,
        catalogPath: pref.catalogPath,
        solverChoice: pref.choice.serialized,
      ),
    );
  }
}

Phd2Status _guiderStatus(
  bridge.Phd2Status status, {
  List<GuideStar> trackedStars = const [],
}) => Phd2Status(
  state: status.state,
  connected: status.connected,
  rmsRa: status.rmsRa,
  rmsDec: status.rmsDec,
  rmsTotal: status.rmsTotal,
  snr: status.snr,
  starMass: status.starMass,
  pixelScale: status.pixelScale,
  trackedStars: trackedStars,
  stopReason: status.stopReason,
);

Phd2CalibrationData _calibrationData(bridge.Phd2CalibrationData data) =>
    Phd2CalibrationData(
      isCalibrated: data.isCalibrated,
      rotationAngle: data.raAngle,
      raRate: data.raRate,
      decRate: data.decRate,
      calibratedAt: data.isCalibrated ? DateTime.now() : null,
    );
