import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/equipment_profiles.dart';

part 'equipment_profiles_dao.g.dart';

@DriftAccessor(tables: [EquipmentProfiles])
class EquipmentProfilesDao extends DatabaseAccessor<SkotiqDatabase>
    with _$EquipmentProfilesDaoMixin {
  EquipmentProfilesDao(super.db);

  /// Get all equipment profiles
  Future<List<EquipmentProfile>> getAllProfiles() =>
      select(equipmentProfiles).get();

  /// Watch all equipment profiles
  Stream<List<EquipmentProfile>> watchAllProfiles() =>
      select(equipmentProfiles).watch();

  /// Get the active profile
  Future<EquipmentProfile?> getActiveProfile() {
    return (select(
      equipmentProfiles,
    )..where((p) => p.isActive.equals(true))).getSingleOrNull();
  }

  /// Watch the active profile
  Stream<EquipmentProfile?> watchActiveProfile() {
    return (select(
      equipmentProfiles,
    )..where((p) => p.isActive.equals(true))).watchSingleOrNull();
  }

  /// Get a profile by ID
  Future<EquipmentProfile?> getProfileById(int id) {
    return (select(
      equipmentProfiles,
    )..where((p) => p.id.equals(id))).getSingleOrNull();
  }

  /// Get the default profile.
  Future<EquipmentProfile?> getDefaultProfile() {
    return (select(
      equipmentProfiles,
    )..where((p) => p.isDefault.equals(true))).getSingleOrNull();
  }

  /// Create a new profile.
  ///
  /// The first profile becomes both the default and the active profile, so the
  /// rest of the app has a coherent startup target.
  Future<int> createProfile(EquipmentProfilesCompanion profile) async {
    return transaction(() async {
      final countExpression = equipmentProfiles.id.count();
      final existingCount =
          await (selectOnly(equipmentProfiles)..addColumns([countExpression]))
              .map((row) => row.read(countExpression) ?? 0)
              .getSingle();
      final isFirstProfile = existingCount == 0;

      final id = await into(equipmentProfiles).insert(
        profile.copyWith(
          isDefault: Value(isFirstProfile),
          isActive: Value(isFirstProfile),
        ),
      );

      if (isFirstProfile) {
        await setDefaultProfile(id, makeActive: true);
      }

      return id;
    });
  }

  /// Update a profile in place.
  Future<bool> updateProfile(EquipmentProfile profile) async {
    return update(equipmentProfiles).replace(profile);
  }

  /// Delete a profile and preserve a coherent default/active selection.
  Future<int> deleteProfile(int id) async {
    return transaction(() async {
      final deletedProfile = await getProfileById(id);
      final rows = await (delete(
        equipmentProfiles,
      )..where((p) => p.id.equals(id))).go();

      if (rows == 0) {
        return 0;
      }

      final remaining =
          await (select(equipmentProfiles)..orderBy([
                (p) => OrderingTerm.asc(p.sortOrder),
                (p) => OrderingTerm.asc(p.id),
              ]))
              .get();

      if (remaining.isEmpty) {
        return rows;
      }

      final activeProfile = remaining.cast<EquipmentProfile?>().firstWhere(
        (p) => p!.isActive,
        orElse: () => null,
      );
      final defaultProfile = remaining.cast<EquipmentProfile?>().firstWhere(
        (p) => p!.isDefault,
        orElse: () => null,
      );

      if (deletedProfile?.isDefault == true || defaultProfile == null) {
        final replacement = activeProfile ?? remaining.first;
        await setDefaultProfile(
          replacement.id,
          makeActive: activeProfile == null,
        );
      } else if (deletedProfile?.isActive == true || activeProfile == null) {
        await setActiveProfile(defaultProfile.id);
      }

      return rows;
    });
  }

  /// Set a profile as active (and deactivate others) without changing the
  /// persisted startup/default profile.
  Future<void> setActiveProfile(int profileId) async {
    await transaction(() async {
      await update(
        equipmentProfiles,
      ).write(const EquipmentProfilesCompanion(isActive: Value(false)));
      await (update(equipmentProfiles)..where((p) => p.id.equals(profileId)))
          .write(const EquipmentProfilesCompanion(isActive: Value(true)));
    });
  }

  /// Persist [temperatureC] as the active profile's default cooling
  /// temperature (the value the Quick-Start wizard lets the user pick).
  ///
  /// Pass `null` to clear the stored temperature (the column is nullable —
  /// a null value means "no default, ask each session"). Returns the number
  /// of rows updated: `0` when there is no active profile, otherwise `1`.
  Future<int> setActiveProfileDefaultCoolingTemp(double? temperatureC) async {
    return (update(
      equipmentProfiles,
    )..where((p) => p.isActive.equals(true))).write(
      EquipmentProfilesCompanion(defaultCoolingTemp: Value(temperatureC)),
    );
  }

  /// Set a profile as the default startup profile.
  ///
  /// When [makeActive] is true, the default profile also becomes the current
  /// active profile so the UI and startup behavior remain aligned.
  Future<void> setDefaultProfile(
    int profileId, {
    bool makeActive = true,
  }) async {
    await transaction(() async {
      await update(
        equipmentProfiles,
      ).write(const EquipmentProfilesCompanion(isDefault: Value(false)));
      await (update(
        equipmentProfiles,
      )..where((p) => p.id.equals(profileId))).write(
        const EquipmentProfilesCompanion(
          isDefault: Value(true),
          isActive: Value.absent(),
        ),
      );

      if (makeActive) {
        await setActiveProfile(profileId);
      }
    });
  }

  /// Clear the persisted default profile without changing the current active
  /// selection.
  Future<void> clearDefaultProfile() async {
    await update(
      equipmentProfiles,
    ).write(const EquipmentProfilesCompanion(isDefault: Value(false)));
  }

  /// Persist a new display order for the given profiles.
  ///
  /// Each id in [orderedIds] is assigned `sortOrder == its index` in a single
  /// transaction. Ids that no longer resolve to a row (deleted between the
  /// caller's read and this write) are skipped rather than failing the whole
  /// reorder. Other columns are left untouched.
  Future<void> reorderProfiles(List<int> orderedIds) async {
    await transaction(() async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (update(equipmentProfiles)
              ..where((p) => p.id.equals(orderedIds[i])))
            .write(EquipmentProfilesCompanion(sortOrder: Value(i)));
      }
    });
  }

  /// Duplicate a profile
  Future<int> duplicateProfile(int sourceId, String newName) async {
    final source = await getProfileById(sourceId);
    if (source == null) {
      throw Exception('Profile not found');
    }

    return into(equipmentProfiles).insert(
      EquipmentProfilesCompanion.insert(
        name: newName,
        description: Value(source.description),
        cameraId: Value(source.cameraId),
        mountId: Value(source.mountId),
        focuserId: Value(source.focuserId),
        filterWheelId: Value(source.filterWheelId),
        guiderId: Value(source.guiderId),
        rotatorId: Value(source.rotatorId),
        domeId: Value(source.domeId),
        weatherId: Value(source.weatherId),
        safetyMonitorId: Value(source.safetyMonitorId),
        switchId: Value(source.switchId),
        coverCalibratorId: Value(source.coverCalibratorId),
        focalLength: Value(source.focalLength),
        aperture: Value(source.aperture),
        focalRatio: Value(source.focalRatio),
        defaultGain: Value(source.defaultGain),
        defaultOffset: Value(source.defaultOffset),
        defaultBinX: Value(source.defaultBinX),
        defaultBinY: Value(source.defaultBinY),
        defaultCoolingTemp: Value(source.defaultCoolingTemp),
        coolOnConnect: Value(source.coolOnConnect),
        defaultCenteringExposure: Value(source.defaultCenteringExposure),
        filterNames: Value(source.filterNames),
        filterFocusOffsets: Value(source.filterFocusOffsets),
        meridianFlipOverrides: Value(source.meridianFlipOverrides),
        cameraName: Value(source.cameraName),
        mountName: Value(source.mountName),
        focuserName: Value(source.focuserName),
        filterWheelName: Value(source.filterWheelName),
        guiderName: Value(source.guiderName),
        rotatorName: Value(source.rotatorName),
        safetyMonitorName: Value(source.safetyMonitorName),
        switchName: Value(source.switchName),
        telescopeName: Value(source.telescopeName),
        telescopeFocalLength: Value(source.telescopeFocalLength),
        telescopeAperture: Value(source.telescopeAperture),
        profileIcon: Value(source.profileIcon),
        profileColor: Value(source.profileColor),
        sortOrder: Value(source.sortOrder),
      ),
    );
  }
}
