part of '../database.dart';

extension _SkotiqDatabaseMigrationV65 on SkotiqDatabase {
  /// Version 65 — every table and index is in the versioned schema.
  ///
  /// Up to v64 several tables existed only once the service that owns them had
  /// run (`integration_goals`, `target_constraints`, `horizon_profiles`,
  /// `scheduler_removed_targets`, `darkroom_state`, `conversational_builds`),
  /// and `captured_images.plate_solve_failed_at` was added at every open. From
  /// here on a database at the current version has all of them.
  ///
  /// The tables themselves are created by the pass that closes every upgrade
  /// ([_createMissing] over the whole schema); a table that already exists is
  /// left exactly as it is.
  Future<void> _upgradeSchemaV65(Migrator m, int from) async {
    if (from >= 65) return;
    await _ensureCapturedImagesSolveFailureColumn();
  }
}
