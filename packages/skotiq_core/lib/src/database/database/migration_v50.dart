part of '../database.dart';

extension _SkotiqDatabaseMigrationV50 on SkotiqDatabase {
  /// Version 50 (science flagship): `fwhm` column on `captured_images`.
  ///
  /// The native stats path now reports a per-frame median FWHM alongside HFR
  /// and eccentricity; persisting it lets the auto-grader's max-FWHM rule act
  /// on the measured value rather than re-deriving it from PSF tiles.
  ///
  /// Like `eccentricity`, `fwhm` is a raw-DDL column (not declared on the
  /// Drift [CapturedImages] table), so it is retrofitted with a guarded
  /// `ALTER TABLE ... ADD COLUMN`. The add is guarded by [_columnExists]
  /// because fresh installs add the same column in
  /// `_ensureCapturedImagesProducingNodeColumns`, and the v2–v17 chain can
  /// recreate `captured_images` mid-upgrade.
  Future<void> _upgradeSchemaV50(Migrator m, int from) async {
    if (from < 50) {
      if (!await _columnExists('captured_images', 'fwhm')) {
        await customStatement(
          'ALTER TABLE captured_images ADD COLUMN fwhm REAL',
        );
      }
    }
  }
}
