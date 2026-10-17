part of '../database.dart';

extension _SkotiqDatabaseMigrationV59 on SkotiqDatabase {
  /// Version 59 — `recipes.draft_notes_json`, the draft's own account of how it
  /// was composed.
  ///
  /// The operation registry decides about more operations than it carries and
  /// records why it left each of the others out. Until this column existed that
  /// account reached the night report on disk and the editor's in-memory state
  /// and nowhere else: the dawn autopilot's own draft opened with no reasons at
  /// all, and the ones a "Draft for me" produced were erased by the first
  /// Reload. A mono master's four-step stack silently dropped the colour
  /// calibration, and nothing in the editor said why.
  ///
  /// The payload is a JSON array of `{opId, outcome, reason}` objects — the
  /// same shape `DawnDraftNote` writes into the night report — so one record
  /// describes the composition in both places. See [RecipeDraftNote].
  ///
  /// Purely additive: one guarded `ALTER TABLE ... ADD COLUMN` with a `'[]'`
  /// default, so every existing row reads back as a recipe with no draft
  /// account rather than as one whose account is unreadable. The guard is
  /// [_columnExists] because fresh installs get the column from
  /// `_createDarkroomTables`.
  Future<void> _upgradeSchemaV59(Migrator m, int from) async {
    if (from < 59) {
      if (!await _columnExists('recipes', 'draft_notes_json')) {
        await customStatement(
          'ALTER TABLE recipes ADD COLUMN draft_notes_json TEXT NOT NULL '
          "DEFAULT '[]'",
        );
      }
    }
  }
}
