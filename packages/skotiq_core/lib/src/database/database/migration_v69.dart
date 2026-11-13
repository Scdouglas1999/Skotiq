part of '../database.dart';

extension _SkotiqDatabaseMigrationV69 on SkotiqDatabase {
  /// Version 69 — every frame names its type in the one record spelling
  /// (`FrameType.record`). Rows written before said "Light", "darkFlat" or
  /// "dark_flat"; nothing reads those spellings any more. A name that is no
  /// frame type at all is left as it was.
  Future<void> _upgradeSchemaV69(Migrator m, int from) async {
    if (from >= 69) return;
    await customStatement(
      'UPDATE captured_images '
      "SET frame_type = replace(lower(frame_type), '_', '') "
      "WHERE replace(lower(frame_type), '_', '') IN "
      "('light', 'dark', 'flat', 'bias', 'darkflat', 'snapshot') "
      "AND frame_type <> replace(lower(frame_type), '_', '')",
    );
  }
}
