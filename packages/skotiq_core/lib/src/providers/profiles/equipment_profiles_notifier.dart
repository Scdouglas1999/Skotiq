part of '../profiles_provider.dart';

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

/// A linked host's profiles, with the backend they came from and the notifier
/// that says whether that backend is still the current one. The owner is held
/// rather than read through this notifier's `ref`: the notifier watches the
/// backend, so a `ref.read` after a host switch and before the rebuild throws.
typedef _LinkedProfiles = ({
  HostProfiles host,
  SkotiqBackend backend,
  BackendNotifier owner,
});

typedef _LocalProfiles = ({
  EquipmentProfilesDao dao,
  ProfileSettingsBackend settings,
  LoggingService logger,
  HostMutationEventHub hub,
});

class EquipmentProfilesNotifier extends AsyncNotifier<EquipmentProfilesState> {
  /// The linked host's profiles, or null when the profiles are in this
  /// process's database.
  _LinkedProfiles? get _remote {
    final owner = ref.read(backendProvider.notifier);
    final backend = owner.currentBackend;
    final host = ref.read(linkedHostProfilesProvider);
    return host == null ? null : (host: host, backend: backend, owner: owner);
  }

  void _requireSameHost(_LinkedProfiles remote) {
    if (!remote.owner.isCurrentBackend(remote.backend)) {
      throw StateError(
        'The imaging host changed while the profile operation was running.',
      );
    }
  }

  Future<int?> _resolveRemoteProfileIdByName(
    _LinkedProfiles remote,
    String name, {
    Set<int> excludingIds = const <int>{},
  }) async {
    final profiles = await remote.host.getProfiles();
    _requireSameHost(remote);
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
    final host = ref.watch(linkedHostProfilesProvider);
    if (host != null) {
      try {
        final remoteProfiles = await host.getProfiles();
        final activeRemote = await host.getActiveProfile();
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

  /// What a change to the profiles in this process's database works with,
  /// resolved before the change: build() watches the profile streams, so a
  /// read through this ref after a write trips Riverpod's rebuild guard.
  _LocalProfiles get _local => (
    dao: ref.read(equipmentProfilesDaoProvider),
    settings: ref.read(profileSettingsBackendProvider),
    logger: ref.read(loggingServiceProvider),
    hub: ref.read(hostMutationEventHubProvider),
  );

  /// Save [profile] and return its id: a new profile when it has no id,
  /// otherwise the fields it changes relative to the copy this notifier last
  /// loaded, laid over the stored profile so an edit made elsewhere to another
  /// field since then is kept. A changed [EquipmentProfileModel.isDefault]
  /// sets or clears the startup profile as [setDefaultProfile] does; the
  /// active flag, the sort order and the timestamps are not a save's to change.
  Future<int> saveProfile(EquipmentProfileModel profile) async {
    final loaded = _loadedCopy(profile.id);
    final defaultChanged = loaded == null
        ? profile.id == null && profile.isDefault
        : profile.isDefault != loaded.isDefault;
    final remote = _remote;
    final int id;
    if (remote != null) {
      id = await _saveOnHost(remote, profile, loaded);
      if (defaultChanged) {
        await _setDefaultOnHost(remote, profile.isDefault ? id : null);
      }
    } else {
      final local = _local;
      id = await _saveHere(local, profile, loaded);
      if (defaultChanged) {
        await _setDefaultHere(
          local,
          profile.isDefault ? id : null,
          makeActive: true,
        );
      }
      // Making it the default already gave the native store the saved row.
      // Otherwise an active row goes to the native store as well; the save
      // has committed, so a native failure is logged, not reported as one.
      if (!(defaultChanged && profile.isDefault) &&
          (await local.dao.getProfileById(id))?.isActive == true) {
        await writeActiveProfileThrough(
          dao: local.dao,
          backend: local.settings,
          logger: local.logger,
          profileId: id,
        );
      }
    }
    ref.invalidateSelf();
    return id;
  }

  EquipmentProfileModel? _loadedCopy(int? id) {
    if (id == null) return null;
    for (final candidate
        in state.valueOrNull?.profiles ?? const <EquipmentProfileModel>[]) {
      if (candidate.id == id) return candidate;
    }
    return null;
  }

  Future<int> _saveOnHost(
    _LinkedProfiles remote,
    EquipmentProfileModel profile,
    EquipmentProfileModel? loaded,
  ) async {
    final existingIds = <int>{
      for (final known
          in state.valueOrNull?.profiles ?? const <EquipmentProfileModel>[])
        if (known.id != null) known.id!,
    };
    final next = profile.toRemoteProfile();
    await remote.host.saveProfileFields(
      next,
      fields: _changedRemoteFields(loaded, next),
    );
    _requireSameHost(remote);
    final savedId =
        int.tryParse(remote.host.lastSavedProfileId ?? '') ??
        profile.id ??
        await _resolveRemoteProfileIdByName(
          remote,
          profile.name,
          excludingIds: existingIds,
        );
    if (savedId == null || savedId <= 0) {
      throw StateError(
        'Host saved profile "${profile.name}" but returned no valid id',
      );
    }
    return savedId;
  }

  Future<int> _saveHere(
    _LocalProfiles local,
    EquipmentProfileModel profile,
    EquipmentProfileModel? loaded,
  ) async {
    final dao = local.dao;
    final int id;
    if (profile.id == null) {
      id = await dao.createProfile(profile.toCompanion());
    } else {
      final stored = await dao.getProfileById(profile.id!);
      if (stored == null) {
        throw StateError('Profile ${profile.id} was not found.');
      }
      id = stored.id;
      await dao.updateProfileColumns(
        id,
        _changedColumns(
          dao.equipmentProfiles,
          loaded ?? EquipmentProfileModel.fromDatabase(stored),
          profile,
        ),
      );
    }
    _announceProfileChange(
      local.hub,
      profile.id == null
          ? HostMutationAction.created
          : HostMutationAction.updated,
      id,
    );
    return id;
  }

  /// The columns [next] writes with a value other than [before]'s, plus the
  /// update time. The columns a save does not own are left out.
  static Map<String, Expression> _changedColumns(
    $EquipmentProfilesTable table,
    EquipmentProfileModel before,
    EquipmentProfileModel next,
  ) {
    final notSaved = {
      table.id.name,
      table.isDefault.name,
      table.isActive.name,
      table.sortOrder.name,
      table.createdAt.name,
      table.updatedAt.name,
    };
    final previous = before.toCompanion().toColumns(false);
    return {
      for (final column in next.toCompanion().toColumns(false).entries)
        if (!notSaved.contains(column.key) &&
            previous[column.key] != column.value)
          column.key: column.value,
      table.updatedAt.name: Variable(DateTime.now()),
    };
  }

  /// The wire fields [next] changes relative to [loaded], the copy this client
  /// last loaded, or null when it has no copy to compare with (a new profile,
  /// or one it has not loaded), in which case the whole profile is sent.
  Set<String>? _changedRemoteFields(
    EquipmentProfileModel? loaded,
    remote_profile.EquipmentProfile next,
  ) {
    if (loaded == null) return null;
    final before = jsonDecode(jsonEncode(loaded.toRemoteProfile().toJson()));
    final after = jsonDecode(jsonEncode(next.toJson()));
    if (before is! Map || after is! Map) return null;
    return {
      for (final key in {...before.keys, ...after.keys})
        if (jsonEncode(before[key]) != jsonEncode(after[key])) key as String,
    }..removeAll(const {'id', 'createdAt', 'updatedAt'});
  }

  Future<void> deleteProfile(int profileId) async {
    final remote = _remote;
    if (remote != null) {
      await remote.host.deleteProfile(profileId.toString());
      _requireSameHost(remote);
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
    final remote = _remote;
    if (remote != null) {
      // Host owns activation and its own native write-through; a failed host
      // load already throws, which is exactly the strict behaviour startup
      // needs on a remote companion. No slave-local SQLite/native write.
      await remote.host.loadProfile(profileId.toString());
      _requireSameHost(remote);
      ref.invalidateSelf();
      return;
    }

    final local = _local;
    // Transactional truth: validate the target, push it into the native
    // executor store FIRST, and only THEN commit the SQLite active flag —
    // compensating the native store if the commit fails. This applies equally
    // to startup and operator-initiated activation.
    try {
      await activateProfileStrictTransactional(
        dao: local.dao,
        backend: local.settings,
        logger: local.logger,
        profileId: profileId,
      );
      _announceProfileChange(local.hub, HostMutationAction.loaded, profileId);
    } finally {
      ref.invalidateSelf();
    }
  }

  /// Tell linked clients about a profile change made on this host. Only the
  /// clients: this app's own providers refresh through [ref.invalidateSelf].
  /// The REST handlers announce their own changes, which do not come through
  /// this notifier, so no change is announced twice.
  void _announceProfileChange(
    HostMutationEventHub hub,
    String action,
    int? profileId,
  ) {
    hub.publishRemoteOnly(
      entityType: HostMutationEntity.profile,
      action: action,
      entityId: profileId?.toString(),
    );
  }

  /// Set or clear the default startup profile.
  Future<void> setDefaultProfile(
    int? profileId, {
    bool makeActive = true,
  }) async {
    final remote = _remote;
    if (remote != null) {
      await _setDefaultOnHost(remote, profileId);
    } else {
      await _setDefaultHere(_local, profileId, makeActive: makeActive);
    }
    ref.invalidateSelf();
  }

  /// The host's own endpoints set and clear its default, and setting one
  /// also makes it active there: a profile save cannot, because the host
  /// keeps a saved row's default flag.
  Future<void> _setDefaultOnHost(_LinkedProfiles remote, int? profileId) async {
    if (profileId != null) {
      await remote.host.setDefaultProfileRemote(profileId.toString());
    } else {
      await remote.host.clearDefaultProfileRemote();
    }
    _requireSameHost(remote);
  }

  Future<void> _setDefaultHere(
    _LocalProfiles local,
    int? profileId, {
    required bool makeActive,
  }) async {
    final dao = local.dao;
    if (profileId == null) {
      await dao.clearDefaultProfile();
    } else if (makeActive) {
      // The default+active DAO mutation is one transaction, but native must
      // accept the target first. Reuse the strict activation coordinator with
      // the default-setting transaction as its commit step.
      await activateProfileStrictTransactional(
        dao: dao,
        backend: local.settings,
        logger: local.logger,
        profileId: profileId,
        commit: () => dao.setDefaultProfile(profileId, makeActive: true),
      );
    } else {
      await dao.setDefaultProfile(profileId, makeActive: false);
    }
    _announceProfileChange(
      local.hub,
      profileId != null && makeActive
          ? HostMutationAction.loaded
          : HostMutationAction.updated,
      profileId,
    );
  }

  /// Persist a new display order for the profiles.
  ///
  /// [orderedIds] is the full list of profile ids in their new order; each id
  /// is assigned `sortOrder == its index`. On a slave this routes to the
  /// dedicated host endpoint (the generic saveProfile path can't change
  /// sortOrder because the converter preserves the existing row's value);
  /// locally it writes the DAO directly.
  Future<void> reorderProfiles(List<int> orderedIds) async {
    final remote = _remote;
    if (remote != null) {
      await remote.host.reorderProfilesRemote(
        orderedIds.map((id) => id.toString()).toList(),
      );
      _requireSameHost(remote);
      ref.invalidateSelf();
      return;
    }

    final dao = ref.read(equipmentProfilesDaoProvider);
    await dao.reorderProfiles(orderedIds);
    ref.invalidateSelf();
  }

  Future<int> duplicateProfile(int sourceId, String newName) async {
    final remote = _remote;
    if (remote != null) {
      final current = await future;
      _requireSameHost(remote);
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
      await remote.host.saveProfile(
        source.toInsertionCopy(name: newName).toRemoteProfile(),
      );
      _requireSameHost(remote);
      final existingIds = current.profiles
          .map((profile) => profile.id)
          .whereType<int>()
          .toSet();
      final id =
          int.tryParse(remote.host.lastSavedProfileId ?? '') ??
          await _resolveRemoteProfileIdByName(
            remote,
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

  Future<List<int>> importProfiles(String json) async {
    final service = ref.read(profileServiceProvider);
    final ids = await service.importAllProfilesFromJson(json);
    ref.invalidateSelf();
    return ids;
  }

  Future<String> exportProfile(int profileId) async {
    final service = ref.read(profileServiceProvider);
    return await service.exportProfileToJson(profileId);
  }
}

final equipmentProfilesProvider =
    AsyncNotifierProvider<EquipmentProfilesNotifier, EquipmentProfilesState>(
      () {
        return EquipmentProfilesNotifier();
      },
    );
