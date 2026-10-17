part of '../database.dart';

extension _SkotiqDatabaseMigrationV44 on SkotiqDatabase {
  /// Version 44: additive WCS + finishing artifact columns on the raw-DDL
  /// `integrated_masters` table, plus the new `narrowband_composites` table.
  ///
  /// The additive `integrated_masters` columns persist:
  ///   * the per-master **plate-solved WCS** as the eight FITS scalars in the
  ///     CD-matrix form ASTAP / `WcsInfo::from_plate_solve`
  ///     (`imaging/src/fits.rs:1094`) emit — reference world coordinates
  ///     (`wcs_crval1`, `wcs_crval2`), reference pixel (`wcs_crpix1`,
  ///     `wcs_crpix2`), and the CD matrix (`wcs_cd1_1`, `wcs_cd1_2`,
  ///     `wcs_cd2_1`, `wcs_cd2_2`). The master's own solved WCS is what the
  ///     catalog-annotation overlay and colour calibration read (both need a
  ///     `WcsOverlay`); the `WcsOverlay` reader derives cdelt/crota from the
  ///     CD matrix.
  ///   * the **finishing output paths** written by the gated post-steps:
  ///     `background_extracted_path` (`<master>_bgx.fits`),
  ///     `deconvolved_path` (`<master>_decon.fits`), and `star_reduced_path`
  ///     (`<master>_starred.fits`). The v42 `background_extracted` flag stays;
  ///     these are the artifact paths behind it.
  ///
  /// `narrowband_composites` is a new raw-DDL table — one row per applied
  /// SHO/HOO/etc. palette combine — carrying the palette, the component master
  /// ids it was built from, the output FITS path, and the composite dimensions.
  /// It is read/written via the plain [NarrowbandCompositesDao]
  /// (`customSelect`/`customInsert`), mirroring [NightReportsDao].
  ///
  /// Raw-DDL changes, no Drift codegen pass. Both helpers are idempotent
  /// (`_columnExists`-guarded `ADD COLUMN`, `IF NOT EXISTS`) and also run from
  /// `onCreate`, so a fresh database gets the columns and the table too.
  Future<void> _upgradeSchemaV44(Migrator m, int from) async {
    if (from < 44) {
      await _ensureIntegratedMastersV44Columns();
      await _createNarrowbandCompositesTable();
    }
  }
}
