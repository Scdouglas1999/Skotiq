part of '../database.dart';

extension _SkotiqDatabaseMigrationV64 on SkotiqDatabase {
  /// Version 64 — a profile names the built-in guider's guide camera and the
  /// guide scope's focal length.
  ///
  /// The built-in guider never takes guide frames on the imaging camera, so a
  /// profile that guides with it needs a camera of its own. Simulator profiles
  /// that use the built-in guider get the simulated guide camera, which the
  /// simulator now provides; every other profile is left for the user to set.
  Future<void> _upgradeSchemaV64(Migrator m, int from) async {
    if (from >= 64) return;
    Future<void> add(TableInfo table, GeneratedColumn column) async {
      if (await _columnExists(table.actualTableName, column.name)) return;
      await m.addColumn(table, column);
    }

    await add(equipmentProfiles, equipmentProfiles.guideCameraId);
    await add(equipmentProfiles, equipmentProfiles.guideCameraName);
    await add(equipmentProfiles, equipmentProfiles.guideFocalLength);
    await assignSimulatedGuideCamera();
  }

  /// Gives every simulator profile that guides with the built-in guider and
  /// has no guide camera the simulated guide camera and guide scope.
  Future<void> assignSimulatedGuideCamera() async {
    await customStatement(
      'UPDATE equipment_profiles '
      'SET guide_camera_id = ?, guide_camera_name = ?, '
      'guide_focal_length = COALESCE(guide_focal_length, ?) '
      "WHERE guider_id = ? AND camera_id LIKE 'sim\\_%' ESCAPE '\\' "
      'AND camera_id <> ? '
      "AND (guide_camera_id IS NULL OR guide_camera_id = '')",
      [
        kSimGuideCameraId,
        kSimGuideCameraName,
        kSimGuideFocalLengthMm,
        kBuiltinGuiderId,
        kSimGuideCameraId,
      ],
    );
  }
}

/// The simulator's guide camera, guide scope and the built-in guider's id;
/// they match the native simulator.
const String kSimGuideCameraId = 'sim_camera_2';
const String kSimGuideCameraName = 'Simulated Guide Camera';
const double kSimGuideFocalLengthMm = 240.0;
const String kBuiltinGuiderId = 'native:builtin_guider:multi_star';

/// Whether a profile with this imaging camera and guider gets the simulated
/// guide camera: a simulator imaging camera guided by the built-in guider.
bool usesSimulatedGuideCamera({String? cameraId, String? guiderId}) =>
    guiderId == kBuiltinGuiderId &&
    cameraId != null &&
    cameraId.startsWith('sim_') &&
    cameraId != kSimGuideCameraId;
