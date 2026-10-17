part of '../ffi_backend.dart';

mixin _FfiStatusProfileOperations on _FfiBackendBase {
  // Equipment status

  @override
  Future<CameraStatus> getCameraStatus(String deviceId) async {
    final bridgeStatus = await bridge.NativeBridge.getCameraStatus(deviceId);
    return _fromBridgeCameraStatus(bridgeStatus);
  }

  @override
  Future<MountStatus> getMountStatus(String deviceId) async {
    final bridgeStatus = await bridge.NativeBridge.getMountStatus(deviceId);
    return _fromBridgeMountStatus(bridgeStatus);
  }

  @override
  Future<FocuserStatus> getFocuserStatus(String deviceId) async {
    final bridgeStatus = await bridge.NativeBridge.getFocuserStatus(deviceId);
    return _fromBridgeFocuserStatus(bridgeStatus);
  }

  @override
  Future<FilterWheelStatus> getFilterWheelStatus(String deviceId) async {
    final bridgeStatus = await bridge.NativeBridge.getFilterWheelStatus(
      deviceId,
    );
    return _fromBridgeFilterWheelStatus(bridgeStatus);
  }

  @override
  Future<RotatorStatus> getRotatorStatus(String deviceId) async {
    final bridgeStatus = await bridge_api.apiGetRotatorStatus(
      deviceId: deviceId,
    );
    return _fromBridgeRotatorStatus(bridgeStatus);
  }

  @override
  Future<HardwareWeatherConditions> getHardwareWeatherConditions(
    String deviceId,
  ) async {
    final status = await bridge_api.apiGetWeatherConditions(deviceId: deviceId);
    return HardwareWeatherConditions(
      temperature: status.temperature,
      humidity: status.humidity,
      pressure: status.pressure,
      cloudCover: status.cloudCover,
      dewPoint: status.dewPoint,
      windSpeed: status.windSpeed,
      windDirection: status.windDirection,
      skyQuality: status.skyQuality,
      skyTemperature: status.skyTemperature,
      rainRate: status.rainRate,
    );
  }

  @override
  Future<bool> getHardwareSafetyStatus(String deviceId) async {
    final status = await bridge_api.apiGetSafetyMonitorStatus(
      deviceId: deviceId,
    );
    if (!status.connected) {
      throw StateError('Safety monitor $deviceId reported disconnected');
    }
    return status.isSafe;
  }

  @override
  Future<HardwareDomeStatus> getHardwareDomeStatus(String deviceId) async {
    final status = await bridge_api.apiGetDomeStatus(deviceId: deviceId);
    if (!status.connected) {
      throw StateError('Dome $deviceId reported disconnected');
    }
    return HardwareDomeStatus(
      azimuth: status.azimuth,
      altitude: status.altitude,
      // `canSetShutter: false` means the driver has no shutter property at all;
      // reporting `closed` there would be a fabrication, so leave it unknown.
      shutterStatus: status.canSetShutter
          ? _shutterStateCode(status.shutterStatus)
          : null,
      isSlewing: status.slewing,
      isAtHome: status.atHome,
      isParked: status.atPark,
      isSlaved: status.isSlaved,
    );
  }

  static int? _shutterStateCode(bridge.ShutterState state) {
    switch (state) {
      case bridge.ShutterState.open:
        return 0;
      case bridge.ShutterState.closed:
        return 1;
      case bridge.ShutterState.opening:
        return 2;
      case bridge.ShutterState.closing:
        return 3;
      case bridge.ShutterState.error:
        return 4;
      case bridge.ShutterState.unknown:
        return null;
    }
  }

  // Status conversion helpers
  // Device capabilities

  @override
  Future<CameraCapabilities?> getCameraCapabilities(String deviceId) async {
    try {
      final bridgeCaps = await bridge_api.apiGetCameraCapabilities(
        deviceId: deviceId,
      );
      return _fromBridgeCameraCapabilities(bridgeCaps);
    } catch (e) {
      _logger.warning('Failed to get camera capabilities: $e');
      return null;
    }
  }

  @override
  Future<MountCapabilities?> getMountCapabilities(String deviceId) async {
    try {
      final bridgeCaps = await bridge_api.apiGetMountCapabilities(
        deviceId: deviceId,
      );
      return _fromBridgeMountCapabilities(bridgeCaps);
    } catch (e) {
      _logger.warning('Failed to get mount capabilities: $e');
      return null;
    }
  }

  @override
  Future<FocuserCapabilities?> getFocuserCapabilities(String deviceId) async {
    try {
      final bridgeCaps = await bridge_api.apiGetFocuserCapabilities(
        deviceId: deviceId,
      );
      return _fromBridgeFocuserCapabilities(bridgeCaps);
    } catch (e) {
      _logger.warning('Failed to get focuser capabilities: $e');
      return null;
    }
  }

  @override
  Future<FilterWheelCapabilities?> getFilterWheelCapabilities(
    String deviceId,
  ) async {
    try {
      final bridgeCaps = await bridge_api.apiGetFilterwheelCapabilities(
        deviceId: deviceId,
      );
      return _fromBridgeFilterWheelCapabilities(bridgeCaps);
    } catch (e) {
      _logger.warning('Failed to get filter wheel capabilities: $e');
      return null;
    }
  }

  @override
  Future<RotatorCapabilities?> getRotatorCapabilities(String deviceId) async {
    try {
      // Use generic device capabilities and extract rotator
      final result = await bridge_api.apiGetDeviceCapabilities(
        deviceId: deviceId,
      );
      if (result is bridge_caps.DeviceCapabilities_Rotator) {
        return _fromBridgeRotatorCapabilities(result.field0);
      }
      return null;
    } catch (e) {
      _logger.warning('Failed to get rotator capabilities: $e');
      return null;
    }
  }

  // Equipment profiles

  @override
  Future<List<EquipmentProfile>> getProfiles() async {
    final bridgeProfiles = await bridge.NativeBridge.apiGetProfiles();
    return bridgeProfiles.map(_fromBridgeProfile).toList();
  }

  @override
  Future<void> saveProfile(EquipmentProfile profile) async {
    await bridge.NativeBridge.apiSaveProfile(
      profile: _toBridgeProfile(profile),
    );
  }

  @override
  Future<void> deleteProfile(String profileId) async {
    await bridge.NativeBridge.apiDeleteProfile(profileId: profileId);
  }

  @override
  Future<void> loadProfile(String profileId) async {
    await bridge.NativeBridge.apiLoadProfile(profileId: profileId);
  }

  @override
  Future<EquipmentProfile?> getActiveProfile() async {
    final bridgeProfile = await bridge.NativeBridge.apiGetActiveProfile();
    return bridgeProfile != null ? _fromBridgeProfile(bridgeProfile) : null;
  }

  // Settings & Location

  @override
  Future<models.AppSettings> getSettings() async {
    final bridgeSettings = await bridge.NativeBridge.apiGetSettings();
    return _fromBridgeSettings(bridgeSettings);
  }

  @override
  Future<void> updateSettings(models.AppSettings settings) async {
    await bridge.NativeBridge.apiUpdateSettings(
      settings: _toBridgeSettings(settings),
    );
  }

  @override
  Future<models.ObserverLocation?> getLocation() async {
    final bridgeLocation = await bridge.NativeBridge.apiGetLocation();
    return bridgeLocation != null ? _fromBridgeLocation(bridgeLocation) : null;
  }

  @override
  Future<void> setLocation(models.ObserverLocation? location) async {
    final bridgeLoc = location != null ? _toBridgeLocation(location) : null;
    _logger.fine(
      'setLocation: ${location != null ? "lat=${location.latitude}, lon=${location.longitude}, elev=${location.elevation}" : "null"}',
    );
    await bridge.NativeBridge.apiSetLocation(location: bridgeLoc);
  }
}
