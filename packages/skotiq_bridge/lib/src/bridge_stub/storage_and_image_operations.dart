part of '../bridge_stub.dart';

extension _NativeBridgeStorageAndImageOperations
    on _NativeBridgeImplementation {
  // Rotator control (API methods)

  /// Move rotator to absolute angle
  Future<void> apiRotatorMoveTo({
    required String deviceId,
    required double angle,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiRotatorMoveTo');
    }
    await gen_api.apiRotatorMoveTo(deviceId: deviceId, angle: angle);
  }

  /// Move rotator by relative amount
  Future<void> apiRotatorMoveRelative({
    required String deviceId,
    required double delta,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiRotatorMoveRelative');
    }
    await gen_api.apiRotatorMoveRelative(deviceId: deviceId, delta: delta);
  }

  /// Get rotator status
  Future<RotatorStatus> apiGetRotatorStatus({required String deviceId}) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiGetRotatorStatus');
    }
    return gen_api.apiGetRotatorStatus(deviceId: deviceId);
  }

  /// Halt rotator movement
  Future<void> apiRotatorHalt({required String deviceId}) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiRotatorHalt');
    }
    await gen_api.apiRotatorHalt(deviceId: deviceId);
  }

  /// Set the rotator's reverse-direction flag
  Future<void> apiRotatorSetReverse({
    required String deviceId,
    required bool reverse,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiRotatorSetReverse');
    }
    await gen_api.apiRotatorSetReverse(deviceId: deviceId, reverse: reverse);
  }

  /// Sync rotator reported sky angle to the supplied position-angle (degrees)
  /// without moving the hardware. Used by the "Sync to image PA" plate-solve
  /// workflow â€” see api_rotator_sync_to_pa in bridge/src/api.rs.
  Future<void> apiRotatorSyncToPa({
    required String deviceId,
    required double pa,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiRotatorSyncToPa');
    }
    await gen_api.apiRotatorSyncToPa(deviceId: deviceId, pa: pa);
  }

  // Equipment profiles (API methods)

  /// Get all profiles
  Future<List<EquipmentProfile>> apiGetProfiles() async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiGetProfiles');
    }
    return gen_api.apiGetProfiles();
  }

  /// Save a profile
  Future<void> apiSaveProfile({required EquipmentProfile profile}) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiSaveProfile');
    }
    gen_api.apiSaveProfile(profile: profile);
  }

  /// Delete a profile
  Future<void> apiDeleteProfile({required String profileId}) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDeleteProfile');
    }
    gen_api.apiDeleteProfile(profileId: profileId);
  }

  /// Load a profile
  Future<void> apiLoadProfile({required String profileId}) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiLoadProfile');
    }
    await gen_api.apiLoadProfile(profileId: profileId);
  }

  /// Get active profile
  Future<EquipmentProfile?> apiGetActiveProfile() async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiGetActiveProfile');
    }
    return gen_api.apiGetActiveProfile();
  }

  // Settings (API methods)

  /// Initialize profile storage
  Future<void> apiInitProfileStorage({required String storagePath}) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiInitProfileStorage');
    }
    gen_api.apiInitProfileStorage(storagePath: storagePath);
  }

  /// Initialize settings storage
  Future<void> apiInitSettingsStorage({required String storagePath}) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiInitSettingsStorage');
    }
    gen_api.apiInitSettingsStorage(storagePath: storagePath);
  }

  /// Get application settings
  Future<AppSettings> apiGetSettings() async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiGetSettings');
    }
    return gen_api.apiGetSettings();
  }

  /// Update application settings
  Future<void> apiUpdateSettings({required AppSettings settings}) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiUpdateSettings');
    }
    gen_api.apiUpdateSettings(settings: settings);
  }

  // Location (API methods)

  /// Get observer location
  Future<ObserverLocation?> apiGetLocation() async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiGetLocation');
    }
    return gen_api.apiGetLocation();
  }

  /// Set observer location
  Future<void> apiSetLocation({ObserverLocation? location}) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiSetLocation');
    }
    gen_api.apiSetLocation(location: location);
  }
}
