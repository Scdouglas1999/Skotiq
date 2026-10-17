part of '../database.dart';

extension _SkotiqDatabaseMigrationV43 on SkotiqDatabase {
  /// Version 43 (Phase B — durable multi-night campaigns): the `campaigns`
  /// table, a NINA-style Target Scheduler campaign record.
  ///
  /// `campaigns` persists one row per `(target_id, filter)` carrying the desired
  /// accepted-frame goal (`desired_count`), a denormalized running
  /// `accepted_count` incremented on the acceptance path, and the wall-clock of
  /// the most recent accepted frame (`last_date`, the NINA "last date" per
  /// filter). It is read/written via the plain [CampaignsDao]
  /// (`customSelect`/`customInsert`), mirroring [NightReportsDao].
  ///
  /// The table is ADDITIVE and orthogonal to `integration_goals`: it never feeds
  /// the live `SchedulerEngine` goals-complete reject (which stays a read-only
  /// derivation over `integration_goals.frame_count` +
  /// `captured_images.is_accepted=1`). It is a durable bookkeeping surface the
  /// campaign UI can later show.
  ///
  /// Like v41/v42 this is a raw-DDL change (the dominant v27+ convention) and
  /// does NOT require a Drift codegen pass. `_createCampaignsTable()` uses
  /// `IF NOT EXISTS`, so the helper is idempotent and also runs from `onCreate`
  /// (fresh installs) so a fresh DB gets the table too.
  Future<void> _upgradeSchemaV43(Migrator m, int from) async {
    if (from < 43) {
      await _createCampaignsTable();
    }
  }
}
