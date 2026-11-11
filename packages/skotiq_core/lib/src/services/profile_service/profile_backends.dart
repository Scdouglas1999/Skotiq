part of '../profile_service.dart';

extension _ProfileServiceBackends on ProfileService {
  void _requireAuthority(_BackendAuthority authority) {
    if (!authority.owner.isCurrentBackend(authority.backend)) {
      throw StateError(
        'The imaging host changed while the profile operation was running.',
      );
    }
  }

  Future<EquipmentProfileModel?> _getProfileModelById(
    int profileId, {
    _BackendAuthority? authority,
  }) async {
    final operation = authority ?? _authority;
    final backend = operation.backend;
    if (backend.remoteHost != null) {
      final profiles = await backend.getProfiles();
      _requireAuthority(operation);
      for (final profile in profiles) {
        if (int.tryParse(profile.id) == profileId) {
          return EquipmentProfileModel.fromRemoteProfile(profile);
        }
      }
      return null;
    }

    final dao = _ref.read(equipmentProfilesDaoProvider);
    final profile = await dao.getProfileById(profileId);
    _requireAuthority(operation);
    return profile != null ? EquipmentProfileModel.fromDatabase(profile) : null;
  }

  Future<EquipmentProfileModel?> _getActiveProfileModel({
    _BackendAuthority? authority,
  }) async {
    final operation = authority ?? _authority;
    final backend = operation.backend;
    if (backend.remoteHost != null) {
      final active = await backend.getActiveProfile();
      _requireAuthority(operation);
      return active != null
          ? EquipmentProfileModel.fromRemoteProfile(active)
          : null;
    }

    final cached = _ref.read(activeEquipmentProfileProvider);
    if (cached != null) {
      _requireAuthority(operation);
      return cached;
    }

    final dao = _ref.read(equipmentProfilesDaoProvider);
    final profile = await dao.getActiveProfile();
    _requireAuthority(operation);
    return profile != null ? EquipmentProfileModel.fromDatabase(profile) : null;
  }

  Future<EquipmentProfileModel?> _getStartupProfileModel({
    _BackendAuthority? authority,
  }) async {
    final operation = authority ?? _authority;
    final backend = operation.backend;
    if (backend.remoteHost != null) {
      final profiles = await backend.getProfiles();
      _requireAuthority(operation);
      remote_profile.EquipmentProfile? defaultProfile;
      remote_profile.EquipmentProfile? activeProfile;
      for (final profile in profiles) {
        if (profile.isDefault) {
          defaultProfile = profile;
        }
        if (profile.isActive) {
          activeProfile = profile;
        }
      }
      final chosen = defaultProfile ?? activeProfile;
      if (chosen != null) {
        return EquipmentProfileModel.fromRemoteProfile(chosen);
      }
      // Older hosts may omit isActive from list rows while still exposing the
      // authoritative active row on the dedicated endpoint. Never fall back
      // to a cached profile from the previous host.
      final active = await backend.getActiveProfile();
      _requireAuthority(operation);
      return active == null
          ? null
          : EquipmentProfileModel.fromRemoteProfile(active);
    }

    final dao = _ref.read(equipmentProfilesDaoProvider);
    final profile =
        await dao.getDefaultProfile() ?? await dao.getActiveProfile();
    _requireAuthority(operation);
    return profile != null ? EquipmentProfileModel.fromDatabase(profile) : null;
  }

  Future<void> _persistProfileModel(
    EquipmentProfileModel profile, {
    _BackendAuthority? authority,
  }) async {
    final operation = authority ?? _authority;
    _requireAuthority(operation);
    final backend = operation.backend;
    if (backend.remoteHost != null) {
      await backend.saveProfile(profile.toRemoteProfile());
      _requireAuthority(operation);
      _ref.invalidate(equipmentProfilesProvider);
      return;
    }

    if (profile.id == null) {
      throw StateError('Cannot persist profile without id on local backend');
    }

    final dao = _ref.read(equipmentProfilesDaoProvider);
    final logger = _ref.read(loggingServiceProvider);
    final existing = await dao.getProfileById(profile.id!);
    _requireAuthority(operation);
    if (existing == null) {
      throw Exception('Profile not found');
    }

    await dao.updateProfile(
      existing.copyWith(
        name: profile.name,
        description: Value(profile.description),
        isActive: profile.isActive,
        cameraId: Value(profile.cameraId),
        mountId: Value(profile.mountId),
        focuserId: Value(profile.focuserId),
        filterWheelId: Value(profile.filterWheelId),
        guiderId: Value(profile.guiderId),
        guideCameraId: Value(profile.guideCameraId),
        guideFocalLength: Value(profile.guideFocalLength),
        rotatorId: Value(profile.rotatorId),
        domeId: Value(profile.domeId),
        weatherId: Value(profile.weatherId),
        safetyMonitorId: Value(profile.safetyMonitorId),
        switchId: Value(profile.switchId),
        coverCalibratorId: Value(profile.coverCalibratorId),
        cameraName: Value(profile.cameraName),
        mountName: Value(profile.mountName),
        focuserName: Value(profile.focuserName),
        filterWheelName: Value(profile.filterWheelName),
        guiderName: Value(profile.guiderName),
        guideCameraName: Value(profile.guideCameraName),
        rotatorName: Value(profile.rotatorName),
        telescopeName: Value(profile.telescopeName),
        telescopeFocalLength: Value(profile.telescopeFocalLength),
        telescopeAperture: Value(profile.telescopeAperture),
        focalLength: profile.focalLength,
        aperture: profile.aperture,
        focalRatio: Value(profile.focalRatio),
        defaultGain: Value(profile.defaultGain),
        defaultOffset: Value(profile.defaultOffset),
        defaultBinX: profile.defaultBinX,
        defaultBinY: profile.defaultBinY,
        defaultCoolingTemp: Value(profile.defaultCoolingTemp),
        coolOnConnect: profile.coolOnConnect,
        defaultCenteringExposure: Value(profile.defaultCenteringExposure),
        filterNames: Value(
          profile.filterNames.isNotEmpty
              ? jsonEncode(profile.filterNames)
              : null,
        ),
        filterFocusOffsets: Value(
          profile.filterFocusOffsets.isNotEmpty
              ? jsonEncode(profile.filterFocusOffsets)
              : null,
        ),
        profileIcon: Value(profile.profileIcon),
        profileColor: Value(profile.profileColor),
        sortOrder: profile.sortOrder,
        isDefault: profile.isDefault,
        updatedAt: DateTime.now(),
      ),
    );
    _requireAuthority(operation);
    if (existing.isActive) {
      await writeActiveProfileThrough(
        dao: dao,
        backend: backend,
        logger: logger,
        profileId: profile.id!,
        strict: true,
      );
      _requireAuthority(operation);
    }
    _ref.invalidate(equipmentProfilesProvider);
  }

  /// Connect devices from a profile model (local FFI or remote host).
  ///
  /// Reuses the canonical [DeviceService.connectAllFromProfile] progress path:
  /// every configured device is dispatched (in parallel) and reports its own
  /// outcome, so one offline device cannot abort the sweep and strand the rest.
  /// Per-device failures are aggregated and, if any occurred, surfaced as a
  /// [ProfileAutoConnectException] rather than read as a clean connect-all.
  Future<void> _connectProfileDevicesFromModel(
    EquipmentProfileModel profile, {
    String progressSource = 'Profile connect',
  }) async {
    final sweep = await _ref
        .read(deviceServiceProvider)
        .connectProfile(profile, source: progressSource);
    final failures = [
      for (final failure in sweep.failures)
        '${failure.deviceType} (${failure.deviceId}): '
            '${failure.errorMessage ?? failure.error ?? 'unknown error'}',
    ];

    if (failures.isNotEmpty) {
      throw ProfileAutoConnectException(
        profileName: profile.name,
        failures: failures,
      );
    }
  }

  /// Create a profile from export data
  Future<int> _createProfileFromExport(
    ProfileExportData data, {
    required _BackendAuthority authority,
  }) async {
    _requireAuthority(authority);
    final backend = authority.backend;
    if (backend.remoteHost != null) {
      final existingProfiles = await backend.getProfiles();
      _requireAuthority(authority);
      var name = data.name;
      var suffix = 1;
      while (existingProfiles.any((p) => p.name == name)) {
        name = '${data.name} ($suffix)';
        suffix++;
      }

      final model = EquipmentProfileModel(
        name: name,
        description: data.description,
        cameraId: data.cameraId,
        mountId: data.mountId,
        focuserId: data.focuserId,
        filterWheelId: data.filterWheelId,
        guiderId: data.guiderId,
        guideCameraId: data.guideCameraId,
        guideFocalLength: data.guideFocalLength,
        rotatorId: data.rotatorId,
        domeId: data.domeId,
        weatherId: data.weatherId,
        safetyMonitorId: data.safetyMonitorId,
        switchId: data.switchId,
        coverCalibratorId: data.coverCalibratorId,
        cameraName: data.cameraName,
        mountName: data.mountName,
        focuserName: data.focuserName,
        filterWheelName: data.filterWheelName,
        guiderName: data.guiderName,
        guideCameraName: data.guideCameraName,
        rotatorName: data.rotatorName,
        safetyMonitorName: data.safetyMonitorName,
        switchName: data.switchName,
        telescopeName: data.telescopeName,
        telescopeFocalLength: data.telescopeFocalLength,
        telescopeAperture: data.telescopeAperture,
        focalLength: data.focalLength,
        aperture: data.aperture,
        focalRatio: data.focalRatio,
        defaultGain: data.defaultGain,
        defaultOffset: data.defaultOffset,
        defaultBinX: data.defaultBinX,
        defaultBinY: data.defaultBinY,
        defaultCoolingTemp: data.defaultCoolingTemp,
        coolOnConnect: data.coolOnConnect,
        defaultCenteringExposure: data.defaultCenteringExposure,
        filterNames: data.filterNames ?? const [],
        filterFocusOffsets: data.filterFocusOffsets ?? const {},
        meridianFlipOverrides: data.meridianFlipOverrides,
        profileIcon: data.profileIcon,
        profileColor: data.profileColor,
      );
      await backend.saveProfile(model.toRemoteProfile());
      _requireAuthority(authority);
      _ref.invalidate(equipmentProfilesProvider);
      final savedText = backend.remoteHost?.profiles.lastSavedProfileId;
      final savedId = savedText == null ? null : int.tryParse(savedText);
      if (savedId != null && savedId > 0) {
        return savedId;
      }
      final refreshed = await backend.getProfiles();
      _requireAuthority(authority);
      for (final profile in refreshed) {
        if (profile.name == name) {
          final id = int.tryParse(profile.id);
          if (id != null) {
            return id;
          }
        }
      }
      throw StateError(
        'Host saved imported profile "$name" but id was not resolved',
      );
    }

    final dao = _ref.read(equipmentProfilesDaoProvider);

    // Check for name conflicts and rename if needed
    final existingProfiles = await dao.getAllProfiles();
    _requireAuthority(authority);
    var name = data.name;
    var suffix = 1;
    while (existingProfiles.any((p) => p.name == name)) {
      name = '${data.name} ($suffix)';
      suffix++;
    }

    final id = await dao.createProfile(
      EquipmentProfilesCompanion.insert(
        name: name,
        description: Value(data.description),
        cameraId: Value(data.cameraId),
        mountId: Value(data.mountId),
        focuserId: Value(data.focuserId),
        filterWheelId: Value(data.filterWheelId),
        guiderId: Value(data.guiderId),
        guideCameraId: Value(data.guideCameraId),
        guideFocalLength: Value(data.guideFocalLength),
        rotatorId: Value(data.rotatorId),
        domeId: Value(data.domeId),
        weatherId: Value(data.weatherId),
        safetyMonitorId: Value(data.safetyMonitorId),
        switchId: Value(data.switchId),
        coverCalibratorId: Value(data.coverCalibratorId),
        cameraName: Value(data.cameraName),
        mountName: Value(data.mountName),
        focuserName: Value(data.focuserName),
        filterWheelName: Value(data.filterWheelName),
        guiderName: Value(data.guiderName),
        guideCameraName: Value(data.guideCameraName),
        rotatorName: Value(data.rotatorName),
        safetyMonitorName: Value(data.safetyMonitorName),
        switchName: Value(data.switchName),
        telescopeName: Value(data.telescopeName),
        telescopeFocalLength: Value(data.telescopeFocalLength),
        telescopeAperture: Value(data.telescopeAperture),
        focalLength: Value(data.focalLength),
        aperture: Value(data.aperture),
        focalRatio: Value(data.focalRatio),
        defaultGain: Value(data.defaultGain),
        defaultOffset: Value(data.defaultOffset),
        defaultBinX: Value(data.defaultBinX),
        defaultBinY: Value(data.defaultBinY),
        defaultCoolingTemp: Value(data.defaultCoolingTemp),
        coolOnConnect: Value(data.coolOnConnect),
        defaultCenteringExposure: Value(data.defaultCenteringExposure),
        filterNames: Value(
          data.filterNames != null ? jsonEncode(data.filterNames) : null,
        ),
        filterFocusOffsets: Value(
          data.filterFocusOffsets != null
              ? jsonEncode(data.filterFocusOffsets)
              : null,
        ),
        meridianFlipOverrides: Value(data.meridianFlipOverrides),
        profileIcon: Value(data.profileIcon),
        profileColor: Value(data.profileColor),
      ),
    );
    _requireAuthority(authority);
    return id;
  }
}
