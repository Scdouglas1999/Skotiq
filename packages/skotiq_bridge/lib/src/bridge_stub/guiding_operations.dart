part of '../bridge_stub.dart';

/// Normalize the PHD2 host the reachability probe dials.
///
/// `localhost` resolves to `::1` first on some hosts while PHD2 only listens on
/// IPv4, so the probe would report "not running" for a perfectly healthy PHD2.
String _resolvePhd2ProbeHost(String host) {
  final normalized = host.trim().toLowerCase();
  if (normalized.isEmpty || normalized == 'localhost' || normalized == '::1') {
    return '127.0.0.1';
  }
  return host.trim();
}

extension _NativeBridgeGuidingOperations on _NativeBridgeImplementation {
  // PHD2 guiding

  /// Check whether something is listening on PHD2's event server.
  ///
  /// This is a plain TCP reachability probe, not a device operation — the
  /// onboarding "Test connection" button uses it to tell the operator whether
  /// the host/port they typed is live before any connect is attempted, so it
  /// works with or without the native bridge.
  Future<bool> isPhd2Running({
    String host = 'localhost',
    int port = 4400,
  }) async {
    try {
      final socket = await Socket.connect(
        _resolvePhd2ProbeHost(host),
        port,
        timeout: const Duration(seconds: 1),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Connect to PHD2
  Future<void> phd2Connect({String? host, int? port}) async {
    if (_nativeAvailable) {
      await gen_api.apiPhd2Connect(
        host: host ?? 'localhost',
        port: port ?? 4400,
      );
      return;
    }
    _nativeBridgeRequired('phd2Connect');
  }

  /// Disconnect from PHD2
  Future<void> phd2Disconnect() async {
    if (_nativeAvailable) {
      await gen_api.apiPhd2Disconnect();
      return;
    }
    _nativeBridgeRequired('phd2Disconnect');
  }

  /// Start guiding
  Future<void> phd2StartGuiding({
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
  }) async {
    if (_nativeAvailable) {
      await gen_api.apiPhd2StartGuiding(
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: settleTimeout,
      );
      return;
    }
    _nativeBridgeRequired('phd2StartGuiding');
  }

  /// Stop guiding
  Future<void> phd2StopGuiding() async {
    if (_nativeAvailable) {
      await gen_api.apiPhd2StopGuiding();
      return;
    }
    _nativeBridgeRequired('phd2StopGuiding');
  }

  /// Dither
  Future<void> phd2Dither({
    required double amount,
    required bool raOnly,
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
  }) async {
    if (_nativeAvailable) {
      await gen_api.apiPhd2Dither(
        amount: amount,
        raOnly: raOnly ? 1 : 0,
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: settleTimeout,
      );
      return;
    }
    _nativeBridgeRequired('phd2Dither');
  }

  /// Get PHD2 status.
  ///
  /// Deliberately non-throwing without the bridge: this is a status query the
  /// UI polls, not a device command, and "disconnected" is the truthful answer
  /// when there is no native library to hold a PHD2 connection.
  Future<Phd2Status> phd2GetStatus() async {
    if (_nativeAvailable) {
      return gen_api.apiPhd2GetStatus();
    }
    return const Phd2Status(
      connected: false,
      state: 'Disconnected',
      rmsRa: 0,
      rmsDec: 0,
      rmsTotal: 0,
      snr: 0,
      starMass: 0,
      pixelScale: 0,
    );
  }

  Future<void> guiderStartGuiding({
    required String deviceId,
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
  }) async {
    if (_nativeAvailable) {
      await gen_api.apiGuiderStartGuiding(
        deviceId: _canonicalGuiderDeviceId(deviceId),
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: settleTimeout,
      );
      return;
    }
    _nativeBridgeRequired('guiderStartGuiding');
  }

  Future<void> guiderStop({required String deviceId}) async {
    if (_nativeAvailable) {
      await gen_api.apiGuiderStop(deviceId: _canonicalGuiderDeviceId(deviceId));
      return;
    }
    _nativeBridgeRequired('guiderStop');
  }

  Future<void> guiderDither({
    required String deviceId,
    required double amount,
    required bool raOnly,
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
  }) async {
    if (_nativeAvailable) {
      await gen_api.apiGuiderDither(
        deviceId: _canonicalGuiderDeviceId(deviceId),
        amount: amount,
        raOnly: raOnly ? 1 : 0,
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: settleTimeout,
      );
      return;
    }
    _nativeBridgeRequired('guiderDither');
  }

  Future<void> guiderLoop({required String deviceId}) async {
    if (_nativeAvailable) {
      await gen_api.apiGuiderLoop(deviceId: _canonicalGuiderDeviceId(deviceId));
      return;
    }
    _nativeBridgeRequired('guiderLoop');
  }

  Future<(double, double)> guiderFindStar({required String deviceId}) async {
    if (_nativeAvailable) {
      return gen_api.apiGuiderFindStar(
        deviceId: _canonicalGuiderDeviceId(deviceId),
      );
    }
    _nativeBridgeRequired('guiderFindStar');
  }

  Future<void> guiderSetLockPosition({
    required String deviceId,
    required double x,
    required double y,
    bool exact = false,
  }) async {
    if (_nativeAvailable) {
      await gen_api.apiGuiderSetLockPosition(
        deviceId: _canonicalGuiderDeviceId(deviceId),
        x: x,
        y: y,
        exact: exact,
      );
      return;
    }
    _nativeBridgeRequired('guiderSetLockPosition');
  }

  Future<(double, double)> guiderGetLockPosition({
    required String deviceId,
  }) async {
    if (_nativeAvailable) {
      return gen_api.apiGuiderGetLockPosition(
        deviceId: _canonicalGuiderDeviceId(deviceId),
      );
    }
    _nativeBridgeRequired('guiderGetLockPosition');
  }

  Future<void> guiderDeselectStar({required String deviceId}) async {
    if (_nativeAvailable) {
      await gen_api.apiGuiderDeselectStar(
        deviceId: _canonicalGuiderDeviceId(deviceId),
      );
      return;
    }
    _nativeBridgeRequired('guiderDeselectStar');
  }

  Future<Phd2StarImage> guiderGetStarImage({
    required String deviceId,
    int size = 50,
  }) async {
    if (_nativeAvailable) {
      return gen_api.apiGuiderGetStarImage(
        deviceId: _canonicalGuiderDeviceId(deviceId),
        size: size,
      );
    }
    _nativeBridgeRequired('guiderGetStarImage');
  }

  // Built-in guider configuration

  /// Get the built-in guider configuration.
  /// Returns a map with keys matching GuiderConfig fields.
  Future<Map<String, dynamic>> builtinGuiderGetConfigRaw() async {
    if (_nativeAvailable) {
      final config = await gen_api.apiBuiltinGuiderGetConfig();
      return {
        'exposureSecs': config.exposureSecs,
        'gain': config.gain,
        'offset': config.offset,
        'binning': config.binning,
        'calibrationMs': config.calibrationMs,
        'settleSleepMs': config.settleSleepMs.toInt(),
        'minPulseMs': config.minPulseMs,
        'maxPulseMs': config.maxPulseMs,
      };
    }
    _nativeBridgeRequired('builtinGuiderGetConfig');
  }

  /// Per-star tracked-star list for the built-in multi-star guider, as a JSON
  /// string (`{"count":N,"stars":[...]}`).
  ///
  /// Bridges the native `api_builtin_guider_get_tracked_stars_json` so the host
  /// FFI backend can populate `Phd2Status.trackedStars` (the per-star guider UI
  /// list). Returns `{"count":0,"stars":[]}` when the built-in guider is not the
  /// active guider or is not tracking, so it is always safe to call on the
  /// status path. Off-native (no bridge) the built-in guider cannot run, so the
  /// empty snapshot is returned.
  Future<String> builtinGuiderGetTrackedStarsJson() async {
    if (_nativeAvailable) {
      return gen_api.apiBuiltinGuiderGetTrackedStarsJson();
    }
    return '{"count":0,"stars":[]}';
  }

  /// Set the built-in guider configuration.
  Future<void> builtinGuiderSetConfigRaw({
    required double exposureSecs,
    required int gain,
    required int offset,
    required int binning,
    required int calibrationMs,
    required int settleSleepMs,
    required double minPulseMs,
    required double maxPulseMs,
  }) async {
    if (_nativeAvailable) {
      await gen_api.apiBuiltinGuiderSetConfig(
        exposureSecs: exposureSecs,
        gain: gain,
        offset: offset,
        binning: binning,
        calibrationMs: calibrationMs,
        settleSleepMs: BigInt.from(settleSleepMs),
        minPulseMs: minPulseMs,
        maxPulseMs: maxPulseMs,
      );
      return;
    }
    _nativeBridgeRequired('builtinGuiderSetConfig');
  }

  /// Start looping exposures in PHD2
  Future<void> phd2Loop() async {
    if (_nativeAvailable) {
      await gen_api.apiPhd2Loop();
      return;
    }
    _nativeBridgeRequired('phd2Loop');
  }

  /// Get PHD2 algorithm parameter names
  Future<List<String>> phd2GetAlgoParamNames({required String axis}) async {
    if (_nativeAvailable) {
      return gen_api.apiPhd2GetAlgoParamNames(axis: axis);
    }
    _nativeBridgeRequired('phd2GetAlgoParamNames');
  }

  /// Get PHD2 algorithm parameter value
  Future<double> phd2GetAlgoParam({
    required String axis,
    required String name,
  }) async {
    if (_nativeAvailable) {
      return gen_api.apiPhd2GetAlgoParam(axis: axis, name: name);
    }
    _nativeBridgeRequired('phd2GetAlgoParam');
  }

  /// Set PHD2 algorithm parameter
  Future<void> phd2SetAlgoParam({
    required String axis,
    required String name,
    required double value,
  }) async {
    if (_nativeAvailable) {
      await gen_api.apiPhd2SetAlgoParam(axis: axis, name: name, value: value);
      return;
    }
    _nativeBridgeRequired('phd2SetAlgoParam');
  }

  /// Set PHD2 paused state
  Future<void> phd2SetPaused({required bool paused}) async {
    if (_nativeAvailable) {
      await gen_api.apiPhd2SetPaused(paused: paused);
      return;
    }
    _nativeBridgeRequired('phd2SetPaused');
  }

  /// Clear PHD2 calibration
  Future<void> phd2ClearCalibration({String which = 'both'}) async {
    if (_nativeAvailable) {
      await gen_api.apiPhd2ClearCalibration(which: which);
      return;
    }
    _nativeBridgeRequired('phd2ClearCalibration');
  }

  /// Flip PHD2 calibration (for meridian flip)
  Future<void> phd2FlipCalibration() async {
    if (_nativeAvailable) {
      await gen_api.apiPhd2FlipCalibration();
      return;
    }
    _nativeBridgeRequired('phd2FlipCalibration');
  }

  /// Get PHD2 calibration data
  Future<gen_api.Phd2CalibrationData> phd2GetCalibrationData() async {
    if (_nativeAvailable) {
      return gen_api.apiPhd2GetCalibrationData();
    }
    _nativeBridgeRequired('phd2GetCalibrationData');
  }

  /// Find a guide star in PHD2
  Future<(double, double)> phd2FindStar() async {
    if (_nativeAvailable) {
      return gen_api.apiPhd2FindStar();
    }
    _nativeBridgeRequired('phd2FindStar');
  }

  /// Set PHD2 lock position
  Future<void> phd2SetLockPosition({
    required double x,
    required double y,
    bool exact = false,
  }) async {
    if (_nativeAvailable) {
      await gen_api.apiPhd2SetLockPosition(x: x, y: y, exact: exact);
      return;
    }
    _nativeBridgeRequired('phd2SetLockPosition');
  }

  /// Get PHD2 lock position
  Future<(double, double)> phd2GetLockPosition() async {
    if (_nativeAvailable) {
      return gen_api.apiPhd2GetLockPosition();
    }
    _nativeBridgeRequired('phd2GetLockPosition');
  }

  /// Deselect star in PHD2
  Future<void> phd2DeselectStar() async {
    if (_nativeAvailable) {
      await gen_api.apiPhd2DeselectStar();
      return;
    }
    _nativeBridgeRequired('phd2DeselectStar');
  }
}
