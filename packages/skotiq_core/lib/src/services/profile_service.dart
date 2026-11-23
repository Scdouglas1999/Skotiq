import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import '../backend/skotiq_backend.dart';
import '../models/equipment/equipment_models.dart';
import '../models/equipment_profile.dart' as remote_profile;
import '../models/equipment_profile_validation.dart';
import '../models/equipment_profile_model.dart';
import 'device_service.dart';
import '../models/optical_train_limits.dart';
import '../backend/network_backend.dart';
import '../models/backend/backend_types.dart';
import '../utils/logging_service.dart';
import '../database/daos/equipment_profiles_dao.dart';
import '../database/rows/equipment_profile_rows.dart';
import '../utils/async_scope.dart';

part 'profile_service/profile_export_data.dart';
part 'profile_service/profile_service_types.dart';
part 'profile_service/profile_backends.dart';

class ProfileService {
  /// [hostProfiles] is the linked host's profiles, or null where the profiles
  /// are in this process's database. [beginAuthority] scopes one operation to
  /// the backend that is current when it starts; it must not read through the
  /// provider that built this service, since a continuation can outlive a
  /// backend swap. The other collaborators are asked for at each call.
  /// [onHostProfilesChanged] runs after an import saves a profile on the
  /// linked host, so the profile list re-reads.
  ProfileService({
    HostProfiles? hostProfiles,
    required AsyncScope<SkotiqBackend> Function() beginAuthority,
    required ProfileWriter Function() profiles,
    required void Function() onHostProfilesChanged,
    required EquipmentProfilesDao Function() profilesDao,
    required EquipmentProfileModel? Function() activeProfile,
    required Future<bool> Function() autoConnectOnStartup,
    required FilterWheelState Function() filterWheel,
    required DeviceService Function() deviceService,
  }) : _hostProfiles = hostProfiles,
       _beginAuthority = beginAuthority,
       _profiles = profiles,
       _onHostProfilesChanged = onHostProfilesChanged,
       _profilesDao = profilesDao,
       _activeProfile = activeProfile,
       _autoConnectOnStartup = autoConnectOnStartup,
       _filterWheel = filterWheel,
       _deviceService = deviceService;

  final HostProfiles? _hostProfiles;
  final _BackendAuthority Function() _beginAuthority;
  final ProfileWriter Function() _profiles;
  final void Function() _onHostProfilesChanged;
  final EquipmentProfilesDao Function() _profilesDao;
  final EquipmentProfileModel? Function() _activeProfile;
  final Future<bool> Function() _autoConnectOnStartup;
  final FilterWheelState Function() _filterWheel;
  final DeviceService Function() _deviceService;

  _BackendAuthority get _authority => _beginAuthority();

  ProfileWriter get _profilesNotifier => _profiles();

  /// Load and activate a profile, optionally connecting devices
  Future<void> loadProfile(int profileId, {bool autoConnect = false}) async {
    final authority = _authority;
    // The notifier is the one activation writer: the host's load endpoint on
    // a linked client; here SQLite and the native executor store together, so
    // the Rust sequencer never runs a profile the UI does not show.
    await _profilesNotifier.setActiveProfile(profileId);
    _requireAuthority(authority);

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
    final autoConnect = await _autoConnectOnStartup();
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
    final host = _hostProfiles;
    final List<ProfileExportData> exportData;
    if (host != null) {
      final profiles = await host.getProfiles();
      _requireAuthority(authority);
      exportData = profiles
          .map(
            (p) => ProfileExportData.fromModel(equipmentProfileFromRemote(p)),
          )
          .toList();
    } else {
      final dao = _profilesDao();
      final profiles = await dao.getAllProfiles();
      _requireAuthority(authority);
      exportData = profiles
          .map((p) => ProfileExportData.fromModel(p.toModel()))
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

  Future<int> duplicateProfile(int sourceId, String newName) async {
    final authority = _authority;
    final id = await _profilesNotifier.duplicateProfile(sourceId, newName);
    _requireAuthority(authority);
    return id;
  }

  Future<void> deleteProfile(int profileId) async {
    final authority = _authority;
    await _profilesNotifier.deleteProfile(profileId);
    _requireAuthority(authority);
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

  /// State the camera read mode the profile's frames are taken in, by the
  /// name the camera lists; null states none and leaves the camera in the
  /// mode it is in.
  Future<void> setProfileReadMode(int profileId, String? mode) async {
    final authority = _authority;
    final profile = await _getProfileModelById(profileId, authority: authority);
    if (profile == null) {
      throw Exception('Profile not found');
    }
    await _persistProfileModel(
      profile.copyWith(
        defaultReadoutMode: mode,
        clearDefaultReadoutMode: mode == null,
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
      Log.warning(
        'ProfileService: No active profile to sync filters to',
        source: 'ProfileService',
      );
      return false;
    }

    final filterWheelState = _filterWheel();

    if (filterWheelState.connectionState != DeviceConnectionState.connected) {
      Log.warning(
        'ProfileService: Filter wheel not connected',
        source: 'ProfileService',
      );
      return false;
    }

    final hwFilterNames = filterWheelState.filterNames;
    if (hwFilterNames.isEmpty) {
      Log.warning(
        'ProfileService: No filter names from hardware',
        source: 'ProfileService',
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

    Log.info(
      'ProfileService: Synced ${hwFilterNames.length} filters to profile "${activeProfile.name}"',
      source: 'ProfileService',
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

    final filterWheelState = _filterWheel();

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
