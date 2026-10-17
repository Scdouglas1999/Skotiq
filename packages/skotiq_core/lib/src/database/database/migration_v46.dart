part of '../database.dart';

extension _SkotiqDatabaseMigrationV46 on SkotiqDatabase {
  /// Version 46 (Calibration Library Manager): the `calibration_tags` table.
  ///
  /// One row per `(master_type, master_id)` artifact — user tags (JSON
  /// array), free-form notes, and the FITS-enriched `camera_id` cache for
  /// the `dark_library` / `flat_library` rows whose schemas predate a camera
  /// column. Keying by the source-table row id (rather than file path) keeps
  /// the row attached across master rebuilds that reuse a path, and the
  /// `UNIQUE(master_type, master_id)` constraint makes the
  /// [CalibrationTagsDao] upsert race-safe.
  ///
  /// Like v41–v45 this is a raw-DDL change (the dominant v27+ convention)
  /// and does NOT require a Drift codegen pass. `_createCalibrationTagsTable`
  /// uses `CREATE TABLE/INDEX IF NOT EXISTS`, so the helper is idempotent and
  /// also runs from `onCreate` so fresh installs get the table too.
  Future<void> _upgradeSchemaV46(Migrator m, int from) async {
    if (from < 46) {
      await _createCalibrationTagsTable();
    }
  }
}
