part of '../database.dart';

extension _SkotiqDatabaseMigrationV42 on SkotiqDatabase {
  /// Version 42 (Smart Morning Report / "Night Doctor"): the `night_reports`
  /// table plus additive Smart-Morning-Report columns on the v41 raw-DDL
  /// `integrated_masters` and `integrated_master_frames` tables.
  ///
  /// `night_reports` is the persisted Night Doctor verdict — one row per session
  /// (and/or target) carrying an overall quality `score`, a one-line `headline`,
  /// and a `findings_json` array of [NightFinding]s. It is read/written via the
  /// plain [NightReportsDao] (`customSelect`/`customInsert`), mirroring
  /// [IntegratedMastersDao].
  ///
  /// The additive `integrated_masters` columns hold the catalog-powered
  /// finishing artifacts (`color_calibrated_path`, `annotated_preview_path`,
  /// `background_extracted`), the per-master ACHIEVED SNR/time anchor
  /// (`target_snr`, `target_integration_s` — the SNR reached at the accumulated
  /// integration time, i.e. the last marginal-SNR curve point) the "how much
  /// more?" loop scales from, and
  /// the serialized marginal-SNR curve (`improvement_curve_json`). The additive
  /// `integrated_master_frames` columns (`snr`, `fwhm`, `eccentricity`) give the
  /// Night Doctor per-sub science data after a morning integration.
  ///
  /// Raw-DDL changes, no Drift codegen pass. Both helpers are idempotent
  /// (`IF NOT EXISTS`, `_columnExists`-guarded `ADD COLUMN`) and also run from
  /// `onCreate`, so a fresh database gets the table and columns too.
  Future<void> _upgradeSchemaV42(Migrator m, int from) async {
    if (from < 42) {
      await _createNightReportsTable();
      await _ensureIntegratedMastersV42Columns();
    }
  }
}
