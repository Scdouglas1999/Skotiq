part of '../database.dart';

extension _SkotiqDatabaseMigrationV49 on SkotiqDatabase {
  /// Version 49 (sequencer closeout): additive columns + two new tables that
  /// make a *historical* run report self-contained.
  ///
  ///   * `sequence_runs.sequence_snapshot_json` — the exact sequence JSON used
  ///     for each run, so "diff vs previous run" compares real snapshots.
  ///   * `sequences.tags_json` / `sequences.is_favorite` — library tags +
  ///     favorites.
  ///   * `sequence_versions` — append-only, per-sequence version history for
  ///     review/restore.
  ///   * `session_diagnostics` — per-session recovery history + optical-train
  ///     baseline/current snapshots.
  ///
  /// All adds are guarded ([_columnExists] / [_tableExists]) because the v2–v17
  /// migration chain recreates several tables from the CURRENT Drift schema —
  /// which already declares these columns — so a blind `addColumn` /
  /// `createTable` would throw "duplicate column" / "table already exists" on
  /// upgrade paths that pass through such a step.
  Future<void> _upgradeSchemaV49(Migrator m, int from) async {
    if (from < 49) {
      if (!await _columnExists('sequence_runs', 'sequence_snapshot_json')) {
        await m.addColumn(sequenceRuns, sequenceRuns.sequenceSnapshotJson);
      }
      if (!await _columnExists('sequences', 'tags_json')) {
        await m.addColumn(sequences, sequences.tagsJson);
      }
      if (!await _columnExists('sequences', 'is_favorite')) {
        await m.addColumn(sequences, sequences.isFavorite);
      }
      if (!await _tableExists('sequence_versions')) {
        await m.createTable(sequenceVersions);
      }
      if (!await _tableExists('session_diagnostics')) {
        await m.createTable(sessionDiagnostics);
      }
    }
  }
}
