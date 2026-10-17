part of '../database.dart';

extension _SkotiqDatabaseMigrationV61 on SkotiqDatabase {
  /// Version 61 — saved sequences' quality stops become notices.
  ///
  /// Owner decision 2026-10-06: only a risk to the hardware pauses or ends a
  /// run by itself. A Recovery node whose trigger judges the frames (HFR,
  /// focus drift, guiding RMS, drift, transparency) and pauses or ends the
  /// run, and an exposure trigger set to pause or end the run, now notify
  /// instead; see [notifyInsteadOfQualityStops]. Templates live in the same
  /// tables and move with everything else. Safety triggers are untouched.
  ///
  /// Version history snapshots are left as they were saved; restoring one
  /// passes through the sequence-file importer, which applies the same move.
  ///
  /// Runs once, on the upgrade to 61. A pause the operator chooses afterwards
  /// is kept: nothing here runs on a later open.
  Future<void> _upgradeSchemaV61(Migrator m, int from) async {
    if (from >= 61) return;
    final rows = await customSelect(
      'SELECT id, specific_type, properties FROM sequence_nodes '
      "WHERE LOWER(specific_type) IN ('recovery', 'takeexposure', 'exposure')",
    ).get();
    for (final row in rows) {
      final Object? decoded;
      try {
        decoded = jsonDecode(row.read<String>('properties'));
      } on FormatException {
        // The repository already refuses to load a row it cannot parse; the
        // migration leaves it for that error rather than failing the upgrade.
        continue;
      }
      if (decoded is! Map<String, dynamic>) continue;
      if (!notifyInsteadOfQualityStops(
        row.read<String>('specific_type'),
        decoded,
      )) {
        continue;
      }
      await customStatement(
        'UPDATE sequence_nodes SET properties = ? WHERE id = ?',
        [jsonEncode(decoded), row.read<int>('id')],
      );
    }
  }
}
