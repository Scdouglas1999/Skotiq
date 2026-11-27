part of '../ffi_backend.dart';

mixin _FfiStatusProfileOperations on _FfiBackendBase {
  @override
  Future<CameraStatus> getCameraStatus(String deviceId) async {
    final bridgeStatus = await _native(
      'getCameraStatus',
      () => bridge.getCameraStatus(deviceId: deviceId),
    );
    return cameraStatusFromBridge(bridgeStatus);
  }

  @override
  Future<MountStatus> getMountStatus(String deviceId) async {
    final bridgeStatus = await _native(
      'getMountStatus',
      () => bridge.apiGetMountStatus(deviceId: deviceId),
    );
    return mountStatusFromBridge(bridgeStatus);
  }

  @override
  Future<FocuserStatus> getFocuserStatus(String deviceId) async {
    final bridgeStatus = await _native(
      'getFocuserStatus',
      () => bridge.apiGetFocuserStatus(deviceId: deviceId),
    );
    return focuserStatusFromBridge(bridgeStatus);
  }

  @override
  Future<FilterWheelStatus> getFilterWheelStatus(String deviceId) async {
    final bridgeStatus = await _native(
      'getFilterWheelStatus',
      () => bridge.apiGetFilterwheelStatus(deviceId: deviceId),
    );
    return filterWheelStatusFromBridge(bridgeStatus);
  }

  @override
  Future<RotatorStatus> getRotatorStatus(String deviceId) async {
    final bridgeStatus = await bridge.apiGetRotatorStatus(deviceId: deviceId);
    return rotatorStatusFromBridge(bridgeStatus);
  }

  @override
  Future<HardwareWeatherConditions> getHardwareWeatherConditions(
    String deviceId,
  ) async {
    final status = await bridge.apiGetWeatherConditions(deviceId: deviceId);
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
    final status = await bridge.apiGetSafetyMonitorStatus(deviceId: deviceId);
    if (!status.connected) {
      throw StateError('Safety monitor $deviceId reported disconnected');
    }
    return status.isSafe;
  }

  @override
  Future<HardwareDomeStatus> getHardwareDomeStatus(String deviceId) async {
    final status = await (this as AccessoryDeviceBackend).readDomeStatus(
      deviceId,
    );
    if (!status.connected) {
      throw StateError('Dome $deviceId reported disconnected');
    }
    return HardwareDomeStatus(
      azimuth: status.azimuth,
      altitude: status.altitude,
      // `canSetShutter: false` means the driver has no shutter property at all;
      // reporting `closed` there would be a fabrication, so leave it unknown.
      shutterStatus: status.canSetShutter
          ? _shutterStateCode(status.shutter)
          : null,
      isSlewing: status.slewing,
      isAtHome: status.atHome,
      isParked: status.atPark,
      isSlaved: status.isSlaved,
    );
  }

  static int? _shutterStateCode(ShutterStatus state) => switch (state) {
    ShutterStatus.open => 0,
    ShutterStatus.closed => 1,
    ShutterStatus.opening => 2,
    ShutterStatus.closing => 3,
    ShutterStatus.error => 4,
    ShutterStatus.unknown => null,
  };

  @override
  Future<CameraCapabilities?> getCameraCapabilities(String deviceId) async {
    try {
      final bridgeCaps = await bridge.apiGetCameraCapabilities(
        deviceId: deviceId,
      );
      return cameraCapabilitiesFromBridge(bridgeCaps);
    } catch (e) {
      Log.warning('Failed to get camera capabilities: $e', source: _logSource);
      return null;
    }
  }

  @override
  Future<MountCapabilities?> getMountCapabilities(String deviceId) async {
    try {
      final bridgeCaps = await bridge.apiGetMountCapabilities(
        deviceId: deviceId,
      );
      return mountCapabilitiesFromBridge(bridgeCaps);
    } catch (e) {
      Log.warning('Failed to get mount capabilities: $e', source: _logSource);
      return null;
    }
  }

  @override
  Future<FocuserCapabilities?> getFocuserCapabilities(String deviceId) async {
    try {
      final bridgeCaps = await bridge.apiGetFocuserCapabilities(
        deviceId: deviceId,
      );
      return focuserCapabilitiesFromBridge(bridgeCaps);
    } catch (e) {
      Log.warning('Failed to get focuser capabilities: $e', source: _logSource);
      return null;
    }
  }

  @override
  Future<FilterWheelCapabilities?> getFilterWheelCapabilities(
    String deviceId,
  ) async {
    try {
      final bridgeCaps = await bridge.apiGetFilterwheelCapabilities(
        deviceId: deviceId,
      );
      return filterWheelCapabilitiesFromBridge(bridgeCaps);
    } catch (e) {
      Log.warning(
        'Failed to get filter wheel capabilities: $e',
        source: _logSource,
      );
      return null;
    }
  }

  @override
  Future<RotatorCapabilities?> getRotatorCapabilities(String deviceId) async {
    try {
      final result = await bridge.apiGetDeviceCapabilities(deviceId: deviceId);
      if (result is bridge.DeviceCapabilities_Rotator) {
        return rotatorCapabilitiesFromBridge(result.field0);
      }
      return null;
    } catch (e) {
      Log.warning('Failed to get rotator capabilities: $e', source: _logSource);
      return null;
    }
  }

  @override
  Future<List<EquipmentProfile>> getProfiles() async {
    final bridgeProfiles = await _native(
      'apiGetProfiles',
      () => bridge.apiGetProfiles(),
    );
    return bridgeProfiles.map(_fromBridgeProfile).toList();
  }

  @override
  Future<void> saveProfile(EquipmentProfile profile) async {
    await _native(
      'apiSaveProfile',
      () => bridge.apiSaveProfile(profile: _toBridgeProfile(profile)),
    );
  }

  @override
  Future<void> deleteProfile(String profileId) async {
    await _native(
      'apiDeleteProfile',
      () => bridge.apiDeleteProfile(profileId: profileId),
    );
  }

  @override
  Future<void> loadProfile(String profileId) async {
    await _native(
      'apiLoadProfile',
      () => bridge.apiLoadProfile(profileId: profileId),
    );
  }

  @override
  Future<EquipmentProfile?> getActiveProfile() async {
    final bridgeProfile = await _native(
      'apiGetActiveProfile',
      () => bridge.apiGetActiveProfile(),
    );
    return bridgeProfile != null ? _fromBridgeProfile(bridgeProfile) : null;
  }

  /// The settings document lives in this process's settings store
  /// (`appSettingsProvider`); the native library keeps only the observing
  /// site ([getLocation]). Only a linked client asks a backend for it.
  @override
  Future<models.AppSettings> getSettings() async => throw UnsupportedError(
    'The app settings are read from the settings store on the imaging '
    'computer, not from the native library.',
  );

  @override
  Future<void> updateSettings(models.AppSettings settings) async =>
      throw UnsupportedError(
        'The app settings are saved to the settings store on the imaging '
        'computer; the native library keeps only the site (setLocation).',
      );

  @override
  Future<models.ObserverLocation?> getLocation() async {
    final bridgeLocation = await _native(
      'apiGetLocation',
      () => bridge.apiGetLocation(),
    );
    return bridgeLocation != null ? _fromBridgeLocation(bridgeLocation) : null;
  }

  @override
  Future<void> setLocation(models.ObserverLocation? location) async {
    final bridgeLoc = location != null ? _toBridgeLocation(location) : null;
    Log.debug(
      'setLocation: ${location != null ? "lat=${location.latitude}, lon=${location.longitude}, elev=${location.elevation}" : "null"}',
      source: _logSource,
    );
    await _native(
      'apiSetLocation',
      () => bridge.apiSetLocation(location: bridgeLoc),
    );
  }
}
