import '../../../models/equipment_profile.dart';

/// The equipment profiles of a linked imaging host, as its client reads and
/// changes them.
///
/// The remote half of a feature whose local half is the profiles DAO and
/// `ProfileService` in this process; reached through `backend.remoteHost`,
/// which is null locally.
abstract interface class HostProfiles {
  /// The id the host gave the profile this client saved last, or null when
  /// the last save did not return one.
  String? get lastSavedProfileId;

  Future<List<EquipmentProfile>> getProfiles();

  Future<EquipmentProfile?> getActiveProfile();

  Future<void> saveProfile(EquipmentProfile profile);

  Future<void> saveProfileFields(
    EquipmentProfile profile, {
    required Set<String>? fields,
  });

  Future<void> deleteProfile(String profileId);

  Future<void> loadProfile(String profileId);

  Future<void> setDefaultProfileRemote(String profileId);

  Future<void> clearDefaultProfileRemote();

  Future<void> reorderProfilesRemote(List<String> orderedIds);
}
