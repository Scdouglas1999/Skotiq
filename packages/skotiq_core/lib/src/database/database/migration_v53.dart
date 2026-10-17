part of '../database.dart';

extension _SkotiqDatabaseMigrationV53 on SkotiqDatabase {
  /// Version 53: add user-friendly display-name columns for the safety monitor
  /// and switch to `equipment_profiles`, matching the existing `*_name` columns
  /// for the camera/mount/focuser/filter wheel/guider/rotator. These let a slave
  /// (remote companion) mirror the safety-monitor / switch display names instead
  /// of showing them by id only.
  ///
  /// Each `ALTER TABLE ... ADD COLUMN` is guarded by [_columnExists] so the hook
  /// is idempotent and safe even when an upgrade path passes through a step that
  /// recreated `equipment_profiles` from the current Drift schema (which already
  /// declares these columns).
  Future<void> _upgradeSchemaV53(Migrator m, int from) async {
    if (from < 53) {
      if (!await _columnExists('equipment_profiles', 'safety_monitor_name')) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN safety_monitor_name TEXT',
        );
      }
      if (!await _columnExists('equipment_profiles', 'switch_name')) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN switch_name TEXT',
        );
      }
    }
  }
}
