part of '../network_backend.dart';

/// The equipment profiles of a linked imaging host, as its client reads and
/// changes them.
///
/// The remote half of a feature whose local half is the profiles DAO and
/// `ProfileService` in this process; reached through `backend.remoteHost`,
/// which is null locally.
mixin HostProfiles on NetworkBackendTransport {
  Future<List<EquipmentProfile>> getProfiles();

  Future<EquipmentProfile?> getActiveProfile();

  Future<void> saveProfile(EquipmentProfile profile);

  Future<void> deleteProfile(String profileId);

  /// Makes [profileId] the host's active profile.
  Future<void> loadProfile(String profileId);

  Future<void> saveProfileFields(
    EquipmentProfile profile, {
    required Set<String>? fields,
  });

  /// Set [profileId] as the host's default startup profile (atomically
  /// unsetting the previous default and making this row active). Routes to the
  /// dedicated host endpoint because the generic saveProfile path preserves the
  /// host row's existing `isDefault` and cannot flip the default.
  ///
  /// NetworkBackend-only (not on the abstract ProfileSettingsBackend role) so
  /// FfiBackend/DisconnectedBackend need no implementation.
  Future<void> setDefaultProfileRemote(String profileId) async {
    await _post(ProfileApi.setDefaultProfile, path: {'profileId': profileId});
  }

  /// Clear the host's default startup profile (unset `isDefault` on every
  /// row). Routes to the dedicated host endpoint because saveProfile preserves
  /// the host row's existing `isDefault`. NetworkBackend-only.
  Future<void> clearDefaultProfileRemote() async {
    await _post(ProfileApi.clearDefaultProfile);
  }

  /// Persist [orderedIds] as the host's profile display order. Routes to the
  /// dedicated host endpoint because saveProfile preserves the host row's
  /// existing `sortOrder`. NetworkBackend-only.
  Future<void> reorderProfilesRemote(List<String> orderedIds) async {
    await _post(ProfileApi.reorderProfiles, body: {'profileIds': orderedIds});
  }
}
