import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/skotiq_backend.dart';
import '../database/database.dart';
import '../models/equipment/equipment_models.dart';
import '../models/equipment_profile.dart' as remote_profile;
import '../models/equipment_profile_validation.dart';
import '../providers/backend_provider.dart';
import '../providers/database_provider.dart';
import '../providers/device_connection_progress_provider.dart'
    show guideCameraLabel;
import '../providers/equipment_provider.dart';
import '../providers/profiles_provider.dart';
import '../models/equipment_profile_model.dart';
import '../providers/profile_activation_writethrough.dart';
import 'logging_service.dart';
import '../providers/settings_provider.dart';
import '../utils/json_validation.dart';
import 'device_service.dart';
import 'optical_train_limits.dart';
import '../backend/remote_host.dart';

part 'profile_service/profile_export_data.dart';
part 'profile_service/profile_service_types.dart';
part 'profile_service/profile_backends.dart';

class ProfileService {
  final Ref _ref;

  ProfileService(this._ref);

  _BackendAuthority get _authority {
    final owner = _ref.read(backendProvider.notifier);
    return (owner: owner, backend: owner.currentBackend);
  }

  EquipmentProfilesNotifier get _profilesNotifier =>
      _ref.read(equipmentProfilesProvider.notifier);


  /// Load and activate a profile, optionally connecting devices
  Future<void> loadProfile(int profileId, {bool autoConnect = false}) async {
    final authority = _authority;
    final backend = authority.backend;
    if (backend.remoteHost != null) {
      await backend.loadProfile(profileId.toString());
      _requireAuthority(authority);
      _ref.invalidate(equipmentProfilesProvider);
      if (autoConnect) {
        final profile = await _getProfileModelById(
          profileId,
          authority: authority,
        );
        if (profile != null) {
          await _connectProfileDevicesFromModel(profile);
          _requireAuthority(authority);
        }
      }
      return;
    }

    // Route activation through the single, remote-aware notifier authority so
    // the local path updates SQLite AND write-throughs the active row into the
    // native executor store (rather than a bare DAO write that the Rust
    // sequencer never sees). The notifier refreshes provider state itself.
    await _profilesNotifier.setActiveProfile(profileId);
    _requireAuthority(authority);

    if (autoConnect) {
      final dao = _ref.read(equipmentProfilesDaoProvider);
      final profile = await dao.getProfileById(profileId);
      _requireAuthority(authority);
      if (profile != null) {
        await _connectProfileDevicesFromModel(
          EquipmentProfileModel.fromDatabase(profile),
        );
        _requireAuthority(authority);
      }
    }
  }

  /// Set or clear the default startup profile.
  ///
  /// Delegates to the single [EquipmentProfilesNotifier] authority for both
  /// remote (host endpoint) and local (SQLite + native write-through when
  /// makeActive flips the active profile) so this service never becomes a
  /// second, unsynchronized activation writer.
  Future<void> setDefaultProfile(
    int? profileId, {
    bool makeActive = true,
  }) async {
    await _profilesNotifier.setDefaultProfile(
      profileId,
      makeActive: makeActive,
    );
  }

  /// Auto-connect to the startup profile's devices on startup.
  ///
  /// Contract:
  ///   1. No-op when the Auto-connect setting is off or there is no startup
  ///      profile (fresh install / no profiles) — never activates, never
  ///      connects.
  ///   2. Startup profile selection = default profile first, current active
  ///      profile as the fallback when no default is set.
  ///   3. The selected startup profile is ACTIVATED through the single
  ///      [EquipmentProfilesNotifier] authority BEFORE any device connect
  ///      (local: SQLite flip + strict native save/load once; remote: host load
  ///      endpoint once, no slave-local write). Startup intentionally makes the
  ///      selected startup profile active — so with profile A as default but B
  ///      currently active, A becomes active (B inactive) while A stays default.
  ///   4. If activation fails, NOTHING is connected and the error propagates.
  ///   5. Only then are that same profile's device ids connected, attempting
  ///      every device and aggregating failures (see
  ///      [_connectProfileDevicesFromModel]).
  ///
  /// This method connects hardware, so the production wiring only invokes it on
  /// the LOCAL hardware-owning master (desktop FfiBackend GUI / headless
  /// daemon). A passive remote/mobile slave launch must never call it; a remote
  /// client may still invoke it explicitly, in which case it drives the host via
  /// the host load endpoint + host-side device connects.
  Future<void> autoConnectOnStartup() async {
    final authority = _authority;
    final autoConnect = await _ref.read(autoConnectSettingsProvider.future);
    _requireAuthority(authority);
    if (!autoConnect) return;

    final startupProfile = await _getStartupProfileModel(authority: authority);
    final profileId = startupProfile?.id;
    if (startupProfile == null || profileId == null) return;

    // Activate/load the selected startup profile FIRST, through the single
    // notifier authority, with a strict native write-through. A failure here
    // (activation, or the native store never learning about the profile) throws
    // before any connect, satisfying "activation failure -> connect nothing".
    await _profilesNotifier.setActiveProfileStrict(profileId);
    _requireAuthority(authority);

    // The profile is now active; connect its devices (attempt-all + aggregate).
    await _connectProfileDevicesFromModel(
      startupProfile,
      progressSource: 'Startup auto-connect',
    );
    _requireAuthority(authority);
  }

  Future<String> exportProfileToJson(int profileId) async {
    final authority = _authority;
    final profile = await _getProfileModelById(profileId, authority: authority);

    if (profile == null) {
      throw Exception('Profile not found');
    }

    final exportData = ProfileExportData.fromModel(profile);
    // Enveloped so the file identifies itself: import can then say "that is
    // not a Skotiq profile" instead of failing on the first field it
    // cannot read.
    return jsonEncode(profileExportEnvelope([exportData.toJson()]));
  }

  Future<void> exportProfileToFile(int profileId, String filePath) async {
    final json = await exportProfileToJson(profileId);
    final file = File(filePath);
    await file.writeAsString(json);
  }

  Future<String> exportAllProfilesToJson() async {
    final authority = _authority;
    final backend = authority.backend;
    final List<ProfileExportData> exportData;
    if (backend.remoteHost != null) {
      final profiles = await backend.getProfiles();
      _requireAuthority(authority);
      exportData = profiles
          .map(
            (p) => ProfileExportData.fromModel(
              EquipmentProfileModel.fromRemoteProfile(p),
            ),
          )
          .toList();
    } else {
      final dao = _ref.read(equipmentProfilesDaoProvider);
      final profiles = await dao.getAllProfiles();
      _requireAuthority(authority);
      exportData = profiles
          .map((p) => ProfileExportData.fromDatabase(p))
          .toList();
    }

    return jsonEncode(
      profileExportEnvelope(exportData.map((p) => p.toJson()).toList()),
    );
  }

  Future<void> exportAllProfilesToFile(String filePath) async {
    final json = await exportAllProfilesToJson();
    final file = File(filePath);
    await file.writeAsString(json);
  }

  Future<int> importProfileFromJson(String json) async {
    final authority = _authority;
    final profiles = profilesFromExportDocument(json);
    if (profiles.isEmpty) {
      throw const ProfileImportException(
        'That Skotiq export contains no profiles.',
      );
    }

    final exportData = parseExportedProfile(profiles.first, index: 0);
    return await _createProfileFromExport(exportData, authority: authority);
  }

  Future<int> importProfileFromFile(String filePath) async {
    final file = File(filePath);
    final json = await file.readAsString();
    return await importProfileFromJson(json);
  }

  Future<List<int>> importAllProfilesFromJson(String json) async {
    final authority = _authority;
    final profilesData = profilesFromExportDocument(json);

    if (profilesData.isEmpty) {
      throw const ProfileImportException(
        'That Skotiq export contains no profiles.',
      );
    }

    // Parse and validate the entire document before persisting the first row.
    // A malformed later entry must not leave a misleading partial import.
    final parsedProfiles = <ProfileExportData>[];
    for (var i = 0; i < profilesData.length; i++) {
      parsedProfiles.add(parseExportedProfile(profilesData[i], index: i));
    }

    final ids = <int>[];
    for (final exportData in parsedProfiles) {
      final id = await _createProfileFromExport(
        exportData,
        authority: authority,
      );
      ids.add(id);
    }

    return ids;
  }

  Future<List<int>> importAllProfilesFromFile(String filePath) async {
    final file = File(filePath);
    final json = await file.readAsString();
    return await importAllProfilesFromJson(json);
  }

  Future<int> createProfile(String name, {String? description}) async {
    final authority = _authority;
    if (authority.backend.remoteHost != null) {
      final id = await _profilesNotifier.createProfile(
        name: name,
        description: description,
      );
      _requireAuthority(authority);
      return id;
    }

    final dao = _ref.read(equipmentProfilesDaoProvider);
    final id = await dao.createProfile(
      EquipmentProfilesCompanion.insert(
        name: name,
        description: Value(description),
      ),
    );
    _requireAuthority(authority);
    _ref.invalidate(equipmentProfilesProvider);
    return id;
  }

  Future<int> duplicateProfile(int sourceId, String newName) async {
    final authority = _authority;
    if (authority.backend.remoteHost != null) {
      final id = await _profilesNotifier.duplicateProfile(sourceId, newName);
      _requireAuthority(authority);
      return id;
    }

    final dao = _ref.read(equipmentProfilesDaoProvider);
    final id = await dao.duplicateProfile(sourceId, newName);
    _requireAuthority(authority);
    _ref.invalidate(equipmentProfilesProvider);
    return id;
  }

  Future<void> deleteProfile(int profileId) async {
    final authority = _authority;
    if (authority.backend.remoteHost != null) {
      await _profilesNotifier.deleteProfile(profileId);
      _requireAuthority(authority);
      return;
    }

    final dao = _ref.read(equipmentProfilesDaoProvider);
    await dao.deleteProfile(profileId);
    _requireAuthority(authority);
    _ref.invalidate(equipmentProfilesProvider);
  }

  /// Assign [devices] (slot type to device id) in a profile, leaving every
  /// other slot as it is. [guideCameraId] is the built-in guider's camera,
  /// which is a profile field without a slot of its own.
  Future<void> updateProfileDevices(
    int profileId,
    Map<DeviceType, String> devices, {
    String? guideCameraId,
  }) async {
    final authority = _authority;
    var profile = await _getProfileModelById(profileId, authority: authority);
    if (profile == null) {
      throw Exception('Profile not found');
    }
    for (final MapEntry(key: type, value: deviceId) in devices.entries) {
      profile = profile!.withDeviceId(type, deviceId);
    }
    await _persistProfileModel(
      profile!.copyWith(guideCameraId: guideCameraId),
      authority: authority,
    );
  }

  Future<void> updateProfileOptics(
    int profileId, {
    double? focalLength,
    double? aperture,
    double? focalRatio,
  }) async {
    final authority = _authority;
    final profile = await _getProfileModelById(profileId, authority: authority);
    if (profile == null) {
      throw Exception('Profile not found');
    }

    await _persistProfileModel(
      profile.copyWith(
        focalLength: focalLength ?? profile.focalLength,
        aperture: aperture ?? profile.aperture,
        focalRatio: focalRatio ?? profile.focalRatio,
      ),
      authority: authority,
    );
  }

  Future<void> updateProfileCameraDefaults(
    int profileId, {
    int? defaultGain,
    int? defaultOffset,
    int? defaultBinX,
    int? defaultBinY,
    double? defaultCoolingTemp,
  }) async {
    final authority = _authority;
    final profile = await _getProfileModelById(profileId, authority: authority);
    if (profile == null) {
      throw Exception('Profile not found');
    }

    await _persistProfileModel(
      profile.copyWith(
        defaultGain: defaultGain ?? profile.defaultGain,
        defaultOffset: defaultOffset ?? profile.defaultOffset,
        defaultBinX: defaultBinX ?? profile.defaultBinX,
        defaultBinY: defaultBinY ?? profile.defaultBinY,
        defaultCoolingTemp: defaultCoolingTemp ?? profile.defaultCoolingTemp,
      ),
      authority: authority,
    );
  }

  Future<void> updateProfileFilters(
    int profileId, {
    List<String>? filterNames,
    Map<String, int>? filterFocusOffsets,
  }) async {
    final authority = _authority;
    final profile = await _getProfileModelById(profileId, authority: authority);
    if (profile == null) {
      throw Exception('Profile not found');
    }

    await _persistProfileModel(
      profile.copyWith(
        filterNames: filterNames ?? profile.filterNames,
        filterFocusOffsets: filterFocusOffsets ?? profile.filterFocusOffsets,
      ),
      authority: authority,
    );
  }

  /// Sync filter names from connected filter wheel to the active profile
  /// Returns true if filters were synced, false otherwise
  Future<bool> syncFiltersFromHardware() async {
    final authority = _authority;
    final activeProfile = await _getActiveProfileModel(authority: authority);

    if (activeProfile == null) {
      developer.log(
        'ProfileService: No active profile to sync filters to',
        name: 'ProfileService',
        level: 900,
      );
      return false;
    }

    final filterWheelState = _ref.read(filterWheelStateProvider);

    if (filterWheelState.connectionState != DeviceConnectionState.connected) {
      developer.log(
        'ProfileService: Filter wheel not connected',
        name: 'ProfileService',
        level: 900,
      );
      return false;
    }

    final hwFilterNames = filterWheelState.filterNames;
    if (hwFilterNames.isEmpty) {
      developer.log(
        'ProfileService: No filter names from hardware',
        name: 'ProfileService',
        level: 900,
      );
      return false;
    }

    final existingOffsets = Map<String, int>.from(
      activeProfile.filterFocusOffsets,
    );

    // Build new offsets map, preserving existing offsets for matching filter names
    final newOffsets = <String, int>{};
    for (final filterName in hwFilterNames) {
      newOffsets[filterName] = existingOffsets[filterName] ?? 0;
    }

    await _persistProfileModel(
      activeProfile.copyWith(
        filterNames: hwFilterNames,
        filterFocusOffsets: newOffsets,
      ),
      authority: authority,
    );

    developer.log(
      'ProfileService: Synced ${hwFilterNames.length} filters to profile "${activeProfile.name}"',
      name: 'ProfileService',
      level: 800,
    );
    return true;
  }

  /// Sync filter names from connected filter wheel to a specific profile
  Future<bool> syncFiltersToProfile(int profileId) async {
    final authority = _authority;
    final profile = await _getProfileModelById(profileId, authority: authority);
    if (profile == null) {
      throw Exception('Profile not found');
    }

    final filterWheelState = _ref.read(filterWheelStateProvider);

    if (filterWheelState.connectionState != DeviceConnectionState.connected) {
      return false;
    }

    final hwFilterNames = filterWheelState.filterNames;
    if (hwFilterNames.isEmpty) {
      return false;
    }

    final existingOffsets = Map<String, int>.from(profile.filterFocusOffsets);
    final newOffsets = <String, int>{};
    for (final filterName in hwFilterNames) {
      newOffsets[filterName] = existingOffsets[filterName] ?? 0;
    }

    await _persistProfileModel(
      profile.copyWith(
        filterNames: hwFilterNames,
        filterFocusOffsets: newOffsets,
      ),
      authority: authority,
    );

    return true;
  }
}

final profileServiceProvider = Provider<ProfileService>((ref) {
  return ProfileService(ref);
});
