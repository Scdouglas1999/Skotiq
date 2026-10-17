// Verifies that the notes_journal table is created on fresh installs
//. Migration coverage from earlier schemas is exercised
// by the existing database_migration_test.dart suite, which only checks
// that the version number matches; this test adds a direct PRAGMA-level
// assertion that the schema lands.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('notes_journal table is present on fresh-install database', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => db.close());

    // sqlite_master has a row for every table; the row is keyed by name.
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='notes_journal'",
        )
        .get();
    expect(
      rows.length,
      1,
      reason: 'notes_journal table missing on fresh install',
    );

    // Verify the schema columns match what NotesService expects.
    final cols = await db
        .customSelect("PRAGMA table_info('notes_journal')")
        .get();
    final names = cols.map((r) => r.read<String>('name')).toSet();
    expect(
      names,
      containsAll(<String>[
        'id',
        'target_id',
        'sequence_run_id',
        'created_at',
        'updated_at',
        'title',
        'body',
        'tags_json',
        'attachments_json',
        'sentiment',
      ]),
    );

    // Indexes — fresh install should have all three.
    final indexes = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='index' "
          "AND tbl_name='notes_journal'",
        )
        .get();
    final indexNames = indexes.map((r) => r.read<String>('name')).toSet();
    expect(indexNames, contains('idx_notes_journal_target'));
    expect(indexNames, contains('idx_notes_journal_run'));
    expect(indexNames, contains('idx_notes_journal_created'));
  });
}
