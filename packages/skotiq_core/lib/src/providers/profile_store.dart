import '../backend/roles/profile_settings_backend.dart';
import '../database/daos/equipment_profiles_dao.dart';
import '../database/database.dart';
import '../models/backend/host_mutation_event.dart';
import '../models/equipment_profile.dart' as remote_profile;
import '../models/equipment_profile_validation.dart';
import '../services/host_mutation_event_hub.dart' show HostMutationEventHub;
import '../utils/logging_service.dart';
import 'profile_activation_writethrough.dart';

/// A save named a profile row that does not exist.
class ProfileNotFound extends StateError {
  ProfileNotFound(this.profileId) : super('Profile $profileId was not found.');

  final int profileId;
}

/// Who hears about a saved profile.
class ProfileSaveNotice {
  const ProfileSaveNotice({
    required this.remoteOnly,
    this.extra = const {},
    this.onceWritten = false,
  });

  /// Only linked clients: the app that saved refreshes its own providers.
  final bool remoteOnly;

  /// Announced as soon as the row is written, before the save's follow-up
  /// steps run; otherwise announced last.
  final bool onceWritten;

  /// Extra fields of the host mutation event.
  final Map<String, dynamic> extra;
}

/// Saves an equipment profile on the computer that keeps it: the host's own
/// editor and `POST /api/profiles` from a linked client both save here, so a
/// profile saved either way is written, reaches the native store and is
/// announced the same way.
class ProfileStore {
  const ProfileStore({
    required this.dao,
    required this.native,
    required this.logger,
    required this.hub,
  });

  final EquipmentProfilesDao dao;

  /// The native executor store, which keeps its own copy of the active
  /// profile (the built-in guider, the sequencer and plate solving read it).
  final ProfileSettingsBackend native;
  final LoggingService logger;
  final HostMutationEventHub hub;

  /// Refuses [profile] before anything is written, with why: a blank or
  /// overlong name, malformed optics, a negative gain or offset, an
  /// out-of-range centering exposure.
  static void validate(remote_profile.EquipmentProfile profile) {
    final error = ProfileValidator.validateWireProfile(profile);
    if (error != null) throw ProfileRefused(error);
  }

  /// Saves the profile as row [id], or as a new row when [id] is null, and
  /// returns the row's id. [newRow] is the row to create; [updateRow] writes
  /// the stored row. [beforeWriteThrough] runs once the row is written;
  /// unless [writeThrough] is false, an active row then goes to the native
  /// store (a native failure is logged, not reported: the save has
  /// committed). The change is announced when [ProfileSaveNotice] says.
  /// Throws [ProfileNotFound] when row [id] does not exist.
  Future<int> save({
    required int? id,
    required EquipmentProfilesCompanion Function() newRow,
    required Future<void> Function(DbEquipmentProfile stored) updateRow,
    required ProfileSaveNotice notice,
    Future<void> Function(int id)? beforeWriteThrough,
    bool writeThrough = true,
  }) async {
    final int savedId;
    if (id == null) {
      savedId = await dao.createProfile(newRow());
    } else {
      final stored = await dao.getProfileById(id);
      if (stored == null) throw ProfileNotFound(id);
      await updateRow(stored);
      savedId = stored.id;
    }
    void announce() {
      final action = id == null
          ? HostMutationAction.created
          : HostMutationAction.updated;
      if (notice.remoteOnly) {
        hub.publishRemoteOnly(
          entityType: HostMutationEntity.profile,
          action: action,
          entityId: savedId.toString(),
          extra: notice.extra,
        );
      } else {
        hub.publish(
          entityType: HostMutationEntity.profile,
          action: action,
          entityId: savedId.toString(),
          extra: notice.extra,
        );
      }
    }

    if (notice.onceWritten) announce();
    await beforeWriteThrough?.call(savedId);
    if (writeThrough && (await dao.getProfileById(savedId))?.isActive == true) {
      await writeActiveProfileThrough(
        dao: dao,
        backend: native,
        logger: logger,
        profileId: savedId,
      );
    }
    if (!notice.onceWritten) announce();
    return savedId;
  }
}

/// [ProfileStore.validate] refused a profile.
class ProfileRefused implements Exception {
  const ProfileRefused(this.message);

  final String message;

  @override
  String toString() => message;
}
