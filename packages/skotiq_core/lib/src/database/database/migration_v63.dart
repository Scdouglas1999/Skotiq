part of '../database.dart';

extension _SkotiqDatabaseMigrationV63 on SkotiqDatabase {
  /// Version 63 — photometry rows carry their filter.
  ///
  /// Zero points, transparency samples and differential photometry of
  /// different filters are not comparable, so each row records the frame's
  /// filter; calibrations also record the catalog band, whether that band is
  /// a standard one for the filter, and the zero point's standard error, and
  /// transparency samples record whether their extinction was measured.
  /// Existing rows keep NULL / false: their filter was never recorded.
  Future<void> _upgradeSchemaV63(Migrator m, int from) async {
    if (from >= 63) return;
    Future<void> add(TableInfo table, GeneratedColumn column) async {
      if (await _columnExists(table.actualTableName, column.name)) return;
      await m.addColumn(table, column);
    }

    await add(photometryMeasurements, photometryMeasurements.filter);
    await add(framePhotometricCalibration, framePhotometricCalibration.filter);
    await add(
      framePhotometricCalibration,
      framePhotometricCalibration.photometricBand,
    );
    await add(
      framePhotometricCalibration,
      framePhotometricCalibration.bandIsStandard,
    );
    await add(
      framePhotometricCalibration,
      framePhotometricCalibration.zeroPointError,
    );
    await add(transparencySamples, transparencySamples.filter);
    await add(transparencySamples, transparencySamples.extinctionMeasured);
  }
}
