part of '../database.dart';

extension _SkotiqDatabaseMigrationV68 on SkotiqDatabase {
  /// Version 68 — a frame says what its gain number is (`gain_kind`).
  ///
  /// DSLR and mirrorless frames now record their ISO speed as their gain.
  /// Frames a gPhoto2 camera took before stored the position in the camera's
  /// ISO list instead; those that can be told apart are marked, and nothing
  /// else is changed (the files on disk are never touched).
  Future<void> _upgradeSchemaV68(Migrator m, int from) async {
    if (from >= 68) return;
    if (!await _columnExists(
      capturedImages.actualTableName,
      capturedImages.gainKind.name,
    )) {
      await m.addColumn(capturedImages, capturedImages.gainKind);
    }
    await markIsoListPositions();
  }

  /// Marks the frames that recorded an ISO-list position as their gain: the
  /// session's profile camera is a gPhoto2 camera, and the number is small
  /// enough to be a position in an ISO list (no body lists 100 speeds).
  Future<void> markIsoListPositions() async {
    await customStatement(
      'UPDATE captured_images SET gain_kind = ? '
      'WHERE (gain_kind IS NULL OR gain_kind = ?) AND gain IS NOT NULL AND gain >= 0 AND gain < 100 '
      'AND session_id IN ('
      'SELECT s.id FROM imaging_sessions s '
      'JOIN equipment_profiles p ON p.id = s.profile_id '
      "WHERE p.camera_id LIKE 'native:gphoto2:%')",
      [GainKind.isoListPosition.recordName, GainKind.gain.recordName],
    );
  }
}
