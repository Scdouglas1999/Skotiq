part of '../database.dart';

extension _SkotiqDatabaseMigrationV60 on SkotiqDatabase {
  /// Version 60 — autofocus star selection moves from every star to the
  /// brightest 10 on existing installs.
  ///
  /// `af_use_brightest_n_stars` was seeded as '0' (count every detection) into
  /// every database on open, so a stored '0' cannot be told apart from a value
  /// the operator chose. Counting every detection read the owner's in-focus
  /// frame of 2026-09-14 at 13.8 px where its brightest 10 stars read 3.2 px,
  /// and the owner approved moving every stored '0' to '10' (2026-10-06).
  ///
  /// Runs once, on the upgrade to 60. An operator who sets 0 again afterwards
  /// keeps it: nothing here runs on a later open.
  Future<void> _upgradeSchemaV60(Migrator m, int from) async {
    if (from < 60) {
      await customStatement(
        "UPDATE app_settings SET value = '10' "
        "WHERE key = 'af_use_brightest_n_stars' AND TRIM(value) = '0'",
      );
    }
  }
}
