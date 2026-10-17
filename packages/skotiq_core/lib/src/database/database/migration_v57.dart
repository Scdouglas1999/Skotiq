part of '../database.dart';

extension _SkotiqDatabaseMigrationV57 on SkotiqDatabase {
  /// Version 57 makes Session Review's diagnostic-map overlays real.
  ///
  /// The scientific rejection/coverage FITS artifacts remain available, while
  /// explicit PNG preview paths give Flutter decodable layers. All columns are
  /// nullable and guarded, so the migration is additive and idempotent.
  Future<void> _upgradeSchemaV57(Migrator m, int from) async {
    if (from < 57) {
      await _ensureIntegratedMastersOverlayColumns();
    }
  }
}
