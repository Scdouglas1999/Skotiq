part of '../database.dart';

extension _SkotiqDatabaseMigrationV41 on SkotiqDatabase {
  /// Version 41 (Post-Session Integration / "Wake Up to a Finished Image"):
  /// the `integrated_masters`, `integrated_master_frames`, and `flat_library`
  /// tables.
  ///
  /// `integrated_masters` is the archival-master provenance record (one-shot
  /// batch integration or a multi-night accumulating master). The
  /// `integrated_master_frames` join enforces sub-level dedup via its
  /// `(master_id, image_id)` UNIQUE constraint so a captured sub is never
  /// double-folded across runs. `flat_library` is the missing master-flat
  /// artifact library (the counterpart to `dark_library`; distinct from the
  /// `flat_history` exposure-planner table).
  ///
  /// All three are raw-DDL tables (the dominant v27+ convention —
  /// `stacked_results`, `projects`), so adding them does not require a Drift
  /// codegen pass; `IntegratedMastersDao` / `FlatLibraryDao` read/write them
  /// via `customSelect`/`customStatement`. The shared
  /// `_createPostSessionTables()` helper also runs from `onCreate` so fresh
  /// installs get the tables too, and every statement is `IF NOT EXISTS` so the
  /// migration is re-runnable.
  Future<void> _upgradeSchemaV41(Migrator m, int from) async {
    if (from < 41) {
      await _createPostSessionTables();
    }
  }
}
