part of '../database.dart';

extension _SkotiqDatabaseMigrationV67 on SkotiqDatabase {
  /// Version 67 — a library dark, bias or flat may have no gain or offset.
  ///
  /// A camera without gain or offset control (FLI, Atik CCDs) records neither
  /// on its frames, and its masters are matched to its lights on that: both
  /// lacking the value. `dark_library` and `flat_library` held the two as
  /// `NOT NULL DEFAULT 0`, so such a master read as gain 0. The tables are
  /// rebuilt with nullable columns; every row keeps its values (an old 0 stays
  /// 0, since nothing says whether the camera had the control).
  Future<void> _upgradeSchemaV67(Migrator m, int from) async {
    if (from >= 67) return;
    for (final table in <TableInfo<Table, dynamic>>[darkLibrary, flatLibrary]) {
      if (await _tableExists(table.actualTableName)) {
        await m.alterTable(TableMigration(table));
      }
    }
  }
}
