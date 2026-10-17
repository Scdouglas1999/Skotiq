part of '../database.dart';

extension _SkotiqDatabaseMigrationV58 on SkotiqDatabase {
  /// Version 58 — the Darkroom data layer. Purely additive: four new raw-DDL
  /// tables and their indexes, no column changes and no drops.
  ///
  ///   * `recipes` — the non-destructive operation stack over a linear master,
  ///     with branching expressed as rows pointing at a parent plus the
  ///     divergence index into that parent's steps.
  ///   * `darkroom_jobs` — the durable dawn-job queue that survives safing and
  ///     a crash, which the 24 h-evicted in-memory `JobManager` cannot.
  ///   * `delivery_targets` / `delivery_journal` — where the night's artifacts
  ///     go and what happened to each file.
  ///
  /// See `tables/darkroom_tables.dart` for the canonical schema, the parent
  /// delete policy, the crash-recovery contract, and the no-secrets rule on
  /// `delivery_targets.config_json`.
  ///
  /// The create helper is `CREATE ... IF NOT EXISTS` throughout, so it is safe
  /// on every upgrade path — including the v2–v17 chain, which recreates tables
  /// from the current schema.
  Future<void> _upgradeSchemaV58(Migrator m, int from) async {
    if (from < 58) {
      await _createDarkroomTables();
    }
  }
}
