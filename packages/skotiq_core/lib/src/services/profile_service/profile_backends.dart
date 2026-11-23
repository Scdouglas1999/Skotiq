part of '../profile_service.dart';

extension _ProfileServiceBackends on ProfileService {
  void _requireAuthority(_BackendAuthority authority) =>
      authority.ensureCurrent('the profile operation was running');

  Future<EquipmentProfileModel?> _getProfileModelById(
    int profileId, {
    _BackendAuthority? authority,
  }) async {
    final operation = authority ?? _authority;
    final host = _hostProfiles;
    if (host != null) {
      final profiles = await host.getProfiles();
      _requireAuthority(operation);
      for (final profile in profiles) {
        if (int.tryParse(profile.id) == profileId) {
          return equipmentProfileFromRemote(profile);
        }
      }
      return null;
    }

    final dao = _profilesDao();
    final profile = await dao.getProfileById(profileId);
    _requireAuthority(operation);
    return profile?.toModel();
  }

  Future<EquipmentProfileModel?> _getActiveProfileModel({
    _BackendAuthority? authority,
  }) async {
    final operation = authority ?? _authority;
    final host = _hostProfiles;
    if (host != null) {
      final active = await host.getActiveProfile();
      _requireAuthority(operation);
      return active != null ? equipmentProfileFromRemote(active) : null;
    }

    final cached = _activeProfile();
    if (cached != null) {
      _requireAuthority(operation);
      return cached;
    }

    final dao = _profilesDao();
    final profile = await dao.getActiveProfile();
    _requireAuthority(operation);
    return profile?.toModel();
  }

  Future<EquipmentProfileModel?> _getStartupProfileModel({
    _BackendAuthority? authority,
  }) async {
    final operation = authority ?? _authority;
    final host = _hostProfiles;
    if (host != null) {
      final profiles = await host.getProfiles();
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
      return chosen == null ? null : equipmentProfileFromRemote(chosen);
    }

    final dao = _profilesDao();
    final profile =
        await dao.getDefaultProfile() ?? await dao.getActiveProfile();
    _requireAuthority(operation);
    return profile?.toModel();
  }

  /// Save [profile] through the profile store, the one writer of a profile.
  Future<void> _persistProfileModel(
    EquipmentProfileModel profile, {
    _BackendAuthority? authority,
  }) async {
    final operation = authority ?? _authority;
    _requireAuthority(operation);
    await _profiles().saveProfile(profile);
    _requireAuthority(operation);
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
    final sweep = await _deviceService().connectProfile(
      profile,
      source: progressSource,
    );
    final failures = [
      for (final failure in sweep.failures)
        (
          device: _deviceCalled(profile, failure.deviceType),
          deviceId: failure.deviceId,
          reason: '${failure.errorMessage ?? failure.error ?? 'unknown error'}',
        ),
    ];

    if (failures.isNotEmpty) {
      throw ProfileAutoConnectException(
        profileName: profile.name,
        failures: failures,
      );
    }
  }

  /// What a person calls the device a sweep names by [label] ("focuser",
  /// "guide camera"): its kind, and the name the profile gives it.
  String _deviceCalled(EquipmentProfileModel profile, String label) {
    final (String kind, String? name) = label == guideCameraLabel
        ? ('Guide camera', profile.guideCameraName)
        : switch (DeviceType.values.where((type) => type.noun == label)) {
            final types when types.isNotEmpty => (
              types.first.displayName,
              profile.deviceNameFor(types.first),
            ),
            _ => (label, null),
          };
    final trimmed = name?.trim() ?? '';
    return trimmed.isEmpty ? kind : '$kind ($trimmed)';
  }

  Future<int> _createProfileFromExport(
    ProfileExportData data, {
    required _BackendAuthority authority,
  }) async {
    _requireAuthority(authority);
    final host = _hostProfiles;
    final takenNames = host != null
        ? [for (final p in await host.getProfiles()) p.name]
        : [for (final p in await _profilesDao().getAllProfiles()) p.name];
    _requireAuthority(authority);
    var name = data.name;
    var suffix = 1;
    while (takenNames.contains(name)) {
      name = '${data.name} ($suffix)';
      suffix++;
    }
    final model = data.toModel(name: name);

    if (host != null) {
      final savedId = await host.saveProfile(model.toRemoteProfile());
      _requireAuthority(authority);
      _onHostProfilesChanged();
      return savedId;
    }

    final id = await _profilesDao().createProfile(
      model.toCompanion().copyWith(updatedAt: const Value.absent()),
    );
    _requireAuthority(authority);
    return id;
  }
}
