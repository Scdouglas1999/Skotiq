part of '../bridge_stub.dart';

extension _NativeBridgeEquipmentOperations on _NativeBridgeImplementation {
  // Camera control

  /// Get camera status
  Future<CameraStatus> getCameraStatus(String deviceId) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('getCameraStatus');
    }
    try {
      return await gen_api.getCameraStatus(deviceId: deviceId);
    } catch (e) {
      developer.log(
        '[Bridge] Error getting camera status from native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Set camera cooler
  Future<void> setCameraCooler(
    String deviceId,
    bool enabled,
    double? targetTemp,
  ) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('setCameraCooler');
    }
    try {
      await gen_api.setCameraCooler(
        deviceId: deviceId,
        enabled: enabled ? 1 : 0,
        targetTemp: targetTemp,
      );
    } catch (e) {
      developer.log(
        '[Bridge] Error setting camera cooler from native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Set camera gain
  Future<void> setCameraGain(String deviceId, int gain) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('setCameraGain');
    }
    try {
      await gen_api.setCameraGain(deviceId: deviceId, gain: gain);
    } catch (e) {
      developer.log(
        '[Bridge] Error setting camera gain from native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Set camera offset
  Future<void> setCameraOffset(String deviceId, int offset) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('setCameraOffset');
    }
    try {
      await gen_api.setCameraOffset(deviceId: deviceId, offset: offset);
    } catch (e) {
      developer.log(
        '[Bridge] Error setting camera offset from native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Set camera readout mode by index
  /// modeIndex: 0 = default/high quality, 1 = fast readout, etc.
  Future<void> setReadoutMode({
    required String deviceId,
    required int modeIndex,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('setReadoutMode');
    }
    try {
      await gen_api.apiCameraSetReadoutMode(
        deviceId: deviceId,
        modeIndex: modeIndex,
      );
    } catch (e) {
      developer.log(
        '[Bridge] Error calling native setReadoutMode: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Cancel current exposure
  Future<void> cancelExposure(String deviceId) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('cancelExposure');
    }
    try {
      await gen_api.apiCameraCancelExposure(deviceId: deviceId);
    } catch (e) {
      developer.log(
        '[Bridge] Error calling native cancelExposure: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  // Mount control

  /// Get mount status
  Future<MountStatus> getMountStatus(String deviceId) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('getMountStatus');
    }
    try {
      return await gen_api.apiGetMountStatus(deviceId: deviceId);
    } catch (e) {
      developer.log(
        '[Bridge] Error getting mount status from native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Slew the mount to coordinates
  Future<void> mountSlewToCoordinates(
    String deviceId,
    double ra,
    double dec,
  ) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('mountSlewToCoordinates');
    }
    try {
      await gen_api.apiMountSlewToCoordinates(
        deviceId: deviceId,
        ra: ra,
        dec: dec,
      );
    } catch (e) {
      developer.log(
        '[Bridge] Error slewing mount via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Sync the mount to coordinates
  Future<void> mountSync(String deviceId, double ra, double dec) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('mountSync');
    }
    try {
      await gen_api.apiMountSyncToCoordinates(
        deviceId: deviceId,
        ra: ra,
        dec: dec,
      );
    } catch (e) {
      developer.log(
        '[Bridge] Error syncing mount via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Park the mount
  Future<void> mountPark(String deviceId) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('mountPark');
    }
    try {
      await gen_api.apiMountPark(deviceId: deviceId);
    } catch (e) {
      developer.log(
        '[Bridge] Error parking mount via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Unpark the mount
  Future<void> mountUnpark(String deviceId) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('mountUnpark');
    }
    try {
      await gen_api.apiMountUnpark(deviceId: deviceId);
    } catch (e) {
      developer.log(
        '[Bridge] Error unparking mount via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Set mount tracking
  Future<void> mountSetTracking(String deviceId, bool enabled) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('mountSetTracking');
    }
    try {
      await gen_api.apiMountSetTracking(
        deviceId: deviceId,
        enabled: enabled ? 1 : 0,
      );
    } catch (e) {
      developer.log(
        '[Bridge] Error setting mount tracking via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Pulse guide mount
  Future<void> mountPulseGuide(
    String deviceId,
    String direction,
    int durationMs,
  ) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('mountPulseGuide');
    }
    try {
      await gen_api.apiMountPulseGuide(
        deviceId: deviceId,
        direction: direction,
        durationMs: durationMs,
      );
    } catch (e) {
      developer.log(
        '[Bridge] Error pulse guiding mount via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  // Focuser control

  /// Get focuser status
  Future<FocuserStatus> getFocuserStatus(String deviceId) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('getFocuserStatus');
    }
    try {
      return await gen_api.apiGetFocuserStatus(deviceId: deviceId);
    } catch (e) {
      developer.log(
        '[Bridge] Error getting focuser status from native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Move focuser to position
  Future<void> focuserMoveTo(String deviceId, int position) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('focuserMoveTo');
    }
    try {
      await gen_api.apiFocuserMoveTo(deviceId: deviceId, position: position);
    } catch (e) {
      developer.log(
        '[Bridge] Error moving focuser via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Move focuser by relative amount
  Future<void> focuserMoveRelative(String deviceId, int delta) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('focuserMoveRelative');
    }
    try {
      await gen_api.apiFocuserMoveRelative(deviceId: deviceId, delta: delta);
    } catch (e) {
      developer.log(
        '[Bridge] Error moving focuser relative via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Halt focuser
  Future<void> apiFocuserHalt({required String deviceId}) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiFocuserHalt');
    }
    try {
      await gen_api.apiFocuserHalt(deviceId: deviceId);
    } catch (e) {
      developer.log(
        '[Bridge] Error halting focuser via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  // Filter wheel control

  /// Get filter wheel status
  Future<FilterWheelStatus> getFilterWheelStatus(String deviceId) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('getFilterWheelStatus');
    }
    try {
      return await gen_api.apiGetFilterwheelStatus(deviceId: deviceId);
    } catch (e) {
      developer.log(
        '[Bridge] Error getting filter wheel status from native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Set filter wheel position
  Future<void> apiFilterwheelSetPosition({
    required String deviceId,
    required int position,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiFilterwheelSetPosition');
    }
    try {
      await gen_api.apiFilterwheelSetPosition(
        deviceId: deviceId,
        position: position,
      );
    } catch (e) {
      developer.log(
        '[Bridge] Error setting filter wheel position via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Get filter wheel names (API method)
  Future<List<String>> apiFilterwheelGetNames({
    required String deviceId,
  }) async {
    final status = await getFilterWheelStatus(deviceId);
    return status.filterNames;
  }

  /// Set filter wheel by name (API method)
  Future<void> apiFilterwheelSetByName({
    required String deviceId,
    required String name,
  }) async {
    final status = await getFilterWheelStatus(deviceId);
    final index = status.filterNames.indexOf(name);
    if (index < 0) {
      throw ArgumentError('Filter "$name" not found on device $deviceId');
    }
    await apiFilterwheelSetPosition(deviceId: deviceId, position: index);
  }

  // Plate solving

  /// Plate solve blind
  Future<PlateSolveResult> plateSolveBlind(
    String filePath, [
    int? timeoutSeconds,
  ]) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('plateSolveBlind');
    }
    return gen_api.apiPlateSolveBlind(
      filePath: filePath,
      timeoutSecs: timeoutSeconds,
    );
  }

  /// Plate solve near coordinates
  Future<PlateSolveResult> plateSolveNear(
    String filePath,
    double hintRa,
    double hintDec,
    double searchRadius, [
    int? timeoutSeconds,
  ]) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('plateSolveNear');
    }
    return gen_api.apiPlateSolveNear(
      filePath: filePath,
      hintRa: hintRa,
      hintDec: hintDec,
      searchRadius: searchRadius,
      timeoutSecs: timeoutSeconds,
    );
  }
}
