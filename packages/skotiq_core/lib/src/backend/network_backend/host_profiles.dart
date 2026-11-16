part of '../network_backend.dart';

/// The equipment profiles of a linked imaging host, as its client reads and
/// changes them.
///
/// The remote half of a feature whose local half is the profiles DAO and
/// `ProfileService` in this process; reached through `backend.remoteHost`,
/// which is null locally.
final class HostProfiles {
  HostProfiles(this._host);

  final NetworkBackend _host;

  Future<List<EquipmentProfile>> getProfiles() async {
    final response = await _host._get(ProfileApi.getProfiles);
    return (response['profiles'] as List)
        .map((p) => EquipmentProfile.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  Future<EquipmentProfile?> getActiveProfile() async {
    final response = await _host._get(ProfileApi.getActiveProfile);
    if (response['profile'] == null) return null;
    return EquipmentProfile.fromJson(
      response['profile'] as Map<String, dynamic>,
    );
  }

  Future<void> saveProfile(EquipmentProfile profile) =>
      saveProfileFields(profile, fields: null);

  /// Save [profile]; when [fields] is given, ask the host to update only those
  /// fields of its existing row, so edits made elsewhere to the other fields
  /// survive.
  Future<void> saveProfileFields(
    EquipmentProfile profile, {
    required Set<String>? fields,
  }) async {
    _host._lastSavedProfileId = null;
    final response = await _host._post(
      ProfileApi.saveProfile,
      body: {
        'profile': profile.toJson(),
        if (fields != null) 'fields': fields.toList()..sort(),
      },
    );
    final rawId = response['id'];
    final id = rawId?.toString();
    if (id == null || id.isEmpty || (int.tryParse(id) ?? 0) <= 0) {
      throw const FormatException(
        'Profile save response did not contain a valid positive id',
      );
    }
    _host._lastSavedProfileId = id;
  }

  Future<void> deleteProfile(String profileId) async {
    await _host._delete(ProfileApi.deleteProfile, path: {'profileId': profileId});
  }

  Future<void> loadProfile(String profileId) async {
    await _host._post(ProfileApi.loadProfile, path: {'profileId': profileId});
  }

  /// Set [profileId] as the host's default startup profile (atomically
  /// unsetting the previous default and making this row active). Routes to the
  /// dedicated host endpoint because the generic saveProfile path preserves the
  /// host row's existing `isDefault` and cannot flip the default.
  ///
  /// NetworkBackend-only (not on the abstract ProfileSettingsBackend role) so
  /// FfiBackend/DisconnectedBackend need no implementation.
  Future<void> setDefaultProfileRemote(String profileId) async {
    await _host._post(ProfileApi.setDefaultProfile, path: {'profileId': profileId});
  }

  /// Clear the host's default startup profile (unset `isDefault` on every
  /// row). Routes to the dedicated host endpoint because saveProfile preserves
  /// the host row's existing `isDefault`. NetworkBackend-only.
  Future<void> clearDefaultProfileRemote() async {
    await _host._post(ProfileApi.clearDefaultProfile);
  }

  /// Persist [orderedIds] as the host's profile display order. Routes to the
  /// dedicated host endpoint because saveProfile preserves the host row's
  /// existing `sortOrder`. NetworkBackend-only.
  Future<void> reorderProfilesRemote(List<String> orderedIds) async {
    await _host._post(ProfileApi.reorderProfiles, body: {'profileIds': orderedIds});
  }

  /// The id the host gave the profile this client saved last, or null when
  /// the last save did not return one.
  String? get lastSavedProfileId => _host.lastSavedProfileId;
}
