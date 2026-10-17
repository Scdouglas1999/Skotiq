part of '../profiles_provider.dart';

/// State class for equipment profiles
class EquipmentProfilesState {
  final List<EquipmentProfileModel> profiles;
  final EquipmentProfileModel? activeProfile;
  final bool isLoading;
  final String? error;

  const EquipmentProfilesState({
    this.profiles = const [],
    this.activeProfile,
    this.isLoading = false,
    this.error,
  });

  EquipmentProfilesState copyWith({
    List<EquipmentProfileModel>? profiles,
    EquipmentProfileModel? activeProfile,
    bool? isLoading,
    String? error,
  }) {
    return EquipmentProfilesState(
      profiles: profiles ?? this.profiles,
      activeProfile: activeProfile ?? this.activeProfile,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

/// Notifier for managing equipment profiles
class EquipmentProfilesNotifier extends AsyncNotifier<EquipmentProfilesState> {
  ({NetworkBackend backend, BackendNotifier owner})? get _remoteAuthority {
    final owner = ref.read(backendProvider.notifier);
    final backend = owner.currentBackend;
    return backend is NetworkBackend ? (backend: backend, owner: owner) : null;
  }

  void _requireRemoteAuthority(NetworkBackend backend, BackendNotifier owner) {
    if (!owner.isCurrentBackend(backend)) {
      throw StateError(
        'The imaging host changed while the profile operation was running.',
      );
    }
  }

  Future<int?> _resolveRemoteProfileIdByName(
    NetworkBackend backend,
    BackendNotifier owner,
    String name, {
    Set<int> excludingIds = const <int>{},
  }) async {
    final profiles = await backend.getProfiles();
    _requireRemoteAuthority(backend, owner);
    final candidates = <int>[];
    for (final profile in profiles) {
      if (profile.name == name) {
        final id = int.tryParse(profile.id);
        if (id != null && id > 0 && !excludingIds.contains(id)) {
          candidates.add(id);
        }
      }
    }
    // A name is not an identity. The compatibility fallback for older hosts
    // is only safe when exactly one unseen row matches; otherwise fail loudly
    // instead of selecting an arbitrary same-name profile.
    return candidates.length == 1 ? candidates.single : null;
  }

  @override
  Future<EquipmentProfilesState> build() async {
    final backend = ref.watch(backendProvider);
    if (backend is NetworkBackend) {
      try {
        final remoteProfiles = await backend.getProfiles();
        final activeRemote = await backend.getActiveProfile();
        final profiles =
            remoteProfiles.map(EquipmentProfileModel.fromRemoteProfile).toList()
              ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

        EquipmentProfileModel? active;
        if (activeRemote != null) {
          active = EquipmentProfileModel.fromRemoteProfile(activeRemote);
        } else {
          for (final profile in profiles) {
            if (profile.isActive) {
              active = profile;
              break;
            }
          }
        }

        return EquipmentProfilesState(
          profiles: profiles,
          activeProfile: active,
        );
      } catch (e, stackTrace) {
        _log.warning('Remote equipment profile fetch failed: $e\n$stackTrace');
        Error.throwWithStackTrace(
          StateError('Could not load equipment profiles from host: $e'),
          stackTrace,
        );
      }
    }

    // Wait for both authoritative database streams. Returning an empty data
    // state while either stream was loading (or had failed) made an existing
    // installation look like it had no profiles and could launch first-run
    // onboarding over a transient database error.
    final profilesFuture = ref.watch(allProfilesProvider.future);
    final activeFuture = ref.watch(activeProfileProvider.future);
    final databaseProfiles = await profilesFuture;
    final databaseActive = await activeFuture;

    final profiles = databaseProfiles
        .map((profile) => EquipmentProfileModel.fromDatabase(profile))
        .toList();
    final active = databaseActive == null
        ? null
        : EquipmentProfileModel.fromDatabase(databaseActive);

    return EquipmentProfilesState(profiles: profiles, activeProfile: active);
  }

  /// Create a new profile
  Future<int> createProfile({required String name, String? description}) async {
    final authority = _remoteAuthority;
    if (authority != null) {
      final remote = authority.backend;
      final current = await future;
      _requireRemoteAuthority(remote, authority.owner);
      final existingIds = current.profiles
          .map((profile) => profile.id)
          .whereType<int>()
          .toSet();
      await remote.saveProfile(
        EquipmentProfileModel(
          name: name,
          description: description,
        ).toRemoteProfile(),
      );
      _requireRemoteAuthority(remote, authority.owner);
      final id =
          int.tryParse(remote.lastSavedProfileId ?? '') ??
          await _resolveRemoteProfileIdByName(
            remote,
            authority.owner,
            name,
            excludingIds: existingIds,
          );
      if (id == null || id <= 0) {
        throw StateError(
          'Host saved profile "$name" but id could not be resolved',
        );
      }
      ref.invalidateSelf();
      return id;
    }

    final dao = ref.read(equipmentProfilesDaoProvider);

    final id = await dao.createProfile(
      EquipmentProfilesCompanion.insert(
        name: name,
        description: Value(description),
      ),
    );

    // Refresh state
    ref.invalidateSelf();

    return id;
  }

  /// Update an existing profile.
  ///
  /// In remote (slave) mode this routes the FULL profile to the host's
  /// `POST /api/profiles` (SQLite-backed since the profiles layer); the host
  /// decides create-vs-update by the parsed id, so a null-id model is accepted
  /// as a remote CREATE. The local (host/desktop) DAO path still requires an id.
  Future<int> updateProfile(EquipmentProfileModel profile) async {
    final authority = _remoteAuthority;
    if (authority != null) {
      final remote = authority.backend;
      await remote.saveProfile(profile.toRemoteProfile());
      _requireRemoteAuthority(remote, authority.owner);
      final savedId =
          int.tryParse(remote.lastSavedProfileId ?? '') ??
          profile.id ??
          await _resolveRemoteProfileIdByName(
            remote,
            authority.owner,
            profile.name,
          );
      if (savedId == null || savedId <= 0) {
        throw StateError(
          'Host saved profile "${profile.name}" but returned no valid id',
        );
      }
      ref.invalidateSelf();
      return savedId;
    }

    if (profile.id == null) {
      throw Exception('Cannot update profile without ID');
    }

    final dao = ref.read(equipmentProfilesDaoProvider);
    final settingsBackend = ref.read(profileSettingsBackendProvider);
    final logger = ref.read(loggingServiceProvider);
    final dbProfile = await dao.getProfileById(profile.id!);

    if (dbProfile == null) {
      throw Exception('Profile not found');
    }

    // Create updated profile
    final updated = dbProfile.copyWith(
      name: profile.name,
      description: Value(profile.description),
      cameraId: Value(profile.cameraId),
      mountId: Value(profile.mountId),
      focuserId: Value(profile.focuserId),
      filterWheelId: Value(profile.filterWheelId),
      guiderId: Value(profile.guiderId),
      rotatorId: Value(profile.rotatorId),
      domeId: Value(profile.domeId),
      weatherId: Value(profile.weatherId),
      safetyMonitorId: Value(profile.safetyMonitorId),
      switchId: Value(profile.switchId),
      coverCalibratorId: Value(profile.coverCalibratorId),
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
        profile.filterNames.isNotEmpty ? jsonEncode(profile.filterNames) : null,
      ),
      filterFocusOffsets: Value(
        profile.filterFocusOffsets.isNotEmpty
            ? jsonEncode(profile.filterFocusOffsets)
            : null,
      ),
      updatedAt: DateTime.now(),
    );

    await dao.updateProfile(updated);
    if (dbProfile.isActive) {
      await writeActiveProfileThrough(
        dao: dao,
        backend: settingsBackend,
        logger: logger,
        profileId: profile.id!,
        strict: true,
      );
    }
    ref.invalidateSelf();
    return profile.id!;
  }

  /// Delete a profile
  Future<void> deleteProfile(int profileId) async {
    final authority = _remoteAuthority;
    if (authority != null) {
      final remote = authority.backend;
      await remote.deleteProfile(profileId.toString());
      _requireRemoteAuthority(remote, authority.owner);
      ref.invalidateSelf();
      return;
    }

    final dao = ref.read(equipmentProfilesDaoProvider);
    await dao.deleteProfile(profileId);
    ref.invalidateSelf();
  }

  /// Set a profile as active.
  ///
  /// This is the single, remote-aware activation authority. In remote (slave)
  /// mode it defers to the host's load endpoint exactly once (the host owns
  /// activation and its own native write-through). In local (desktop /
  /// Pi-headless) mode it updates SQLite, mirrors the now-active row into the
  /// native (Rust) executor store via [writeActiveProfileThrough], then
  /// refreshes provider state — so SQLite/UI and the native sequencer can never
  /// disagree about which profile is active.
  ///
  /// Activation is transactional for every caller: the native executor accepts
  /// the target before SQLite changes, so an interactive tap cannot leave the
  /// UI and running sequencer on different profiles.
  Future<void> setActiveProfile(int profileId) => _activateProfile(profileId);

  /// Startup-facing alias for the same strict transaction used by every
  /// activation. Kept as a named API because startup callers use the failure as
  /// a hard gate before connecting equipment.
  Future<void> setActiveProfileStrict(int profileId) =>
      _activateProfile(profileId);

  Future<void> _activateProfile(int profileId) async {
    final authority = _remoteAuthority;
    if (authority != null) {
      final remote = authority.backend;
      // Host owns activation and its own native write-through; a failed host
      // load already throws, which is exactly the strict behaviour startup
      // needs on a remote companion. No slave-local SQLite/native write.
      await remote.loadProfile(profileId.toString());
      _requireRemoteAuthority(remote, authority.owner);
      ref.invalidateSelf();
      return;
    }

    // Resolve every collaborator BEFORE mutating SQLite. build() watches the
    // profile streams, so a `ref.read` AFTER a SQLite mutation would trip
    // Riverpod's "dependency changed before rebuild" guard.
    final dao = ref.read(equipmentProfilesDaoProvider);
    final settingsBackend = ref.read(profileSettingsBackendProvider);
    final logger = ref.read(loggingServiceProvider);

    // Transactional truth: validate the target, push it into the native
    // executor store FIRST, and only THEN commit the SQLite active flag —
    // compensating the native store if the commit fails. This applies equally
    // to startup and operator-initiated activation.
    try {
      await activateProfileStrictTransactional(
        dao: dao,
        backend: settingsBackend,
        logger: logger,
        profileId: profileId,
      );
    } finally {
      ref.invalidateSelf();
    }
  }

  /// Set or clear the default startup profile.
  Future<void> setDefaultProfile(
    int? profileId, {
    bool makeActive = true,
  }) async {
    final authority = _remoteAuthority;
    if (authority != null) {
      final remote = authority.backend;
      if (profileId != null) {
        // Dedicated host endpoint: setDefaultProfile atomically unsets the
        // previous default and makes this row active (makeActive is owned
        // host-side). The generic saveProfile path could never flip the
        // host's isDefault because the converter preserves existing.isDefault.
        await remote.setDefaultProfileRemote(profileId.toString());
      } else {
        // Clear-default: dedicated host endpoint (the saveProfile path can't
        // clear isDefault because the converter preserves the existing row's
        // flag).
        await remote.clearDefaultProfileRemote();
      }
      _requireRemoteAuthority(remote, authority.owner);
      ref.invalidateSelf();
      return;
    }

    // Resolve collaborators up front (see [setActiveProfile] for why the reads
    // must precede the SQLite mutation).
    final dao = ref.read(equipmentProfilesDaoProvider);
    final settingsBackend = ref.read(profileSettingsBackendProvider);
    final logger = ref.read(loggingServiceProvider);
    if (profileId == null) {
      await dao.clearDefaultProfile();
    } else if (makeActive) {
      // The default+active DAO mutation is one transaction, but native must
      // accept the target first. Reuse the strict activation coordinator with
      // the default-setting transaction as its commit step.
      await activateProfileStrictTransactional(
        dao: dao,
        backend: settingsBackend,
        logger: logger,
        profileId: profileId,
        commit: () => dao.setDefaultProfile(profileId, makeActive: true),
      );
    } else {
      await dao.setDefaultProfile(profileId, makeActive: false);
    }
    ref.invalidateSelf();
  }

  /// Persist a new display order for the profiles.
  ///
  /// [orderedIds] is the full list of profile ids in their new order; each id
  /// is assigned `sortOrder == its index`. On a slave this routes to the
  /// dedicated host endpoint (the generic saveProfile path can't change
  /// sortOrder because the converter preserves the existing row's value);
  /// locally it writes the DAO directly.
  Future<void> reorderProfiles(List<int> orderedIds) async {
    final authority = _remoteAuthority;
    if (authority != null) {
      final remote = authority.backend;
      await remote.reorderProfilesRemote(
        orderedIds.map((id) => id.toString()).toList(),
      );
      _requireRemoteAuthority(remote, authority.owner);
      ref.invalidateSelf();
      return;
    }

    final dao = ref.read(equipmentProfilesDaoProvider);
    await dao.reorderProfiles(orderedIds);
    ref.invalidateSelf();
  }

  /// Duplicate a profile
  Future<int> duplicateProfile(int sourceId, String newName) async {
    final authority = _remoteAuthority;
    if (authority != null) {
      final remote = authority.backend;
      final current = await future;
      _requireRemoteAuthority(remote, authority.owner);
      EquipmentProfileModel? source;
      for (final profile in current.profiles) {
        if (profile.id == sourceId) {
          source = profile;
          break;
        }
      }
      if (source == null) {
        throw StateError('Profile $sourceId not found on host');
      }
      // Build a genuine insertion copy: id CLEARED (so the host creates a new
      // row rather than updating/renaming the source), active/default false, new
      // name, every other field preserved. `copyWith(id: null)` cannot clear the
      // id (id ?? this.id) and would send the source id — silently overwriting
      // the source instead of duplicating it.
      await remote.saveProfile(
        source.toInsertionCopy(name: newName).toRemoteProfile(),
      );
      _requireRemoteAuthority(remote, authority.owner);
      final existingIds = current.profiles
          .map((profile) => profile.id)
          .whereType<int>()
          .toSet();
      final id =
          int.tryParse(remote.lastSavedProfileId ?? '') ??
          await _resolveRemoteProfileIdByName(
            remote,
            authority.owner,
            newName,
            excludingIds: existingIds,
          );
      if (id == null) {
        throw StateError(
          'Host duplicated profile as "$newName" but id could not be resolved',
        );
      }
      ref.invalidateSelf();
      return id;
    }

    final dao = ref.read(equipmentProfilesDaoProvider);
    final id = await dao.duplicateProfile(sourceId, newName);
    ref.invalidateSelf();
    return id;
  }

  /// Import profiles from JSON
  Future<List<int>> importProfiles(String json) async {
    final service = ref.read(profileServiceProvider);
    final ids = await service.importAllProfilesFromJson(json);
    ref.invalidateSelf();
    return ids;
  }

  /// Export a single profile to JSON
  Future<String> exportProfile(int profileId) async {
    final service = ref.read(profileServiceProvider);
    return await service.exportProfileToJson(profileId);
  }
}

/// Main provider for equipment profiles
final equipmentProfilesProvider =
    AsyncNotifierProvider<EquipmentProfilesNotifier, EquipmentProfilesState>(
      () {
        return EquipmentProfilesNotifier();
      },
    );
