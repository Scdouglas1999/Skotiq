part of '../database.dart';

extension _SkotiqDatabaseMigrationV51 on SkotiqDatabase {
  /// Version 51 (science flagship): full anisotropic WCS on `captured_images`.
  ///
  /// The native plate-solve path surfaces the CD matrix and SIP distortion
  /// terms; persisting them per frame is what lets stored and live science
  /// consumers rebuild an anisotropic projection with distortion correction,
  /// rather than the isotropic `solved_pixel_scale`/`solved_rotation` pair.
  ///
  /// The four `solved_cd*` scalars are the same CD-matrix form ASTAP emits
  /// (`cd1_1 = -scale*cos`, `cd1_2 = scale*sin`, `cd2_1 = scale*sin`,
  /// `cd2_2 = scale*cos`); `solved_sip` is a JSON blob
  /// `{aOrder,bOrder,a,b,apOrder,bpOrder,ap,bp}` and is null when the solve
  /// carried no SIP terms.
  ///
  /// Like the v44 master WCS columns and `fwhm`, these are raw-DDL columns
  /// (not declared on the Drift [CapturedImages] table), so they are
  /// retrofitted with guarded `ALTER TABLE ... ADD COLUMN`. The add is guarded
  /// by [_columnExists] because fresh installs add the same columns in
  /// `_ensureCapturedImagesProducingNodeColumns`, and the v2–v17 chain can
  /// recreate `captured_images` mid-upgrade.
  Future<void> _upgradeSchemaV51(Migrator m, int from) async {
    if (from < 51) {
      if (!await _columnExists('captured_images', 'solved_cd1_1')) {
        await customStatement(
          'ALTER TABLE captured_images ADD COLUMN solved_cd1_1 REAL',
        );
      }
      if (!await _columnExists('captured_images', 'solved_cd1_2')) {
        await customStatement(
          'ALTER TABLE captured_images ADD COLUMN solved_cd1_2 REAL',
        );
      }
      if (!await _columnExists('captured_images', 'solved_cd2_1')) {
        await customStatement(
          'ALTER TABLE captured_images ADD COLUMN solved_cd2_1 REAL',
        );
      }
      if (!await _columnExists('captured_images', 'solved_cd2_2')) {
        await customStatement(
          'ALTER TABLE captured_images ADD COLUMN solved_cd2_2 REAL',
        );
      }
      if (!await _columnExists('captured_images', 'solved_sip')) {
        await customStatement(
          'ALTER TABLE captured_images ADD COLUMN solved_sip TEXT',
        );
      }
    }
  }
}
