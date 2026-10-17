part of '../database.dart';

extension _SkotiqDatabaseMigrationV48 on SkotiqDatabase {
  /// Version 48 (Night Narrator): the additive `narrator_events` table — the
  /// durable backing store for the session-long Narrator feed.
  ///
  /// Unlike the raw-DDL v41–v46 changes this is a real Drift table (declared on
  /// [NarratorEvents], registered in `@DriftDatabase`, accessed via
  /// [NarratorEventsDao]). It is brand new, so the migration is a single
  /// `createTable` — no column back-fill, no data reshape. Guarded by
  /// [_tableExists] for idempotency on upgrade paths that may already have run
  /// `createAll()` from a fresh `onCreate`.
  Future<void> _upgradeSchemaV48(Migrator m, int from) async {
    if (from < 48) {
      if (!await _tableExists('narrator_events')) {
        await m.createTable(narratorEvents);
      }
    }
  }
}
