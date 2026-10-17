part of '../database.dart';

extension _SkotiqDatabaseMigrationV47 on SkotiqDatabase {
  /// Version 47 (MPC photometry): `magnitude` + `magnitude_band` columns on
  /// `moving_object_candidates`.
  ///
  /// The moving-object detector has always measured candidate flux but threw
  /// it away, forcing MPC reports to be astrometry-only. The science
  /// pipeline now converts that flux to an apparent magnitude via the
  /// frame's photometric zero point and persists it here so the 80-column
  /// export can fill columns 66–71. Both columns are nullable — frames
  /// without a photometric calibration legitimately produce
  /// astrometry-only rows.
  ///
  /// Unlike v41–v46 this is a Drift-table change (the columns are declared
  /// on [MovingObjectCandidates] and present in the generated data class).
  /// The adds are guarded by [_columnExists] because earlier migration
  /// steps that (re)create `moving_object_candidates` do so from the
  /// CURRENT Drift schema — which already includes these columns — so a
  /// blind `m.addColumn` would fail with "duplicate column" on upgrade
  /// paths that pass through such a step.
  Future<void> _upgradeSchemaV47(Migrator m, int from) async {
    if (from < 47) {
      if (!await _columnExists('moving_object_candidates', 'magnitude')) {
        await m.addColumn(
          movingObjectCandidates,
          movingObjectCandidates.magnitude,
        );
      }
      if (!await _columnExists('moving_object_candidates', 'magnitude_band')) {
        await m.addColumn(
          movingObjectCandidates,
          movingObjectCandidates.magnitudeBand,
        );
      }
    }
  }
}
