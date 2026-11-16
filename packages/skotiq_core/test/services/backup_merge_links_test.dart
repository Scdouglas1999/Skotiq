// A merged row that is given a new id takes with it every row that names it:
// by a foreign key, by a plain id column, by an id whose table another column
// names, by a JSON list of ids, and by a link into its own table.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/services.dart';

import 'backup_restore_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rows that name a record by id follow it to its new id', () async {
    final dir = await Directory.systemTemp.createTemp('skotiq_merge_links_');
    addTearDown(() => dir.delete(recursive: true));
    final logger = testLogger(dir);

    final source = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(source.close);
    await seedEveryTable(source);
    // A recipe branched from the seeded one.
    await source.customStatement(
      'INSERT INTO recipes (id, base_master_path, name, steps_json, '
      'created_by, draft_notes_json, parent_recipe_id, divergence_index, '
      "schema_version, created_at, updated_at) VALUES (8, 'm.fits', "
      "'Branch', '[]', 'user', '[]', 7, 0, 1, 5, 5)",
    );
    final file = '${dir.path}/links.skbackup';
    final made = await BackupService(
      database: source,
      logger: logger,
    ).createBackup(customPath: file);
    expect(made.success, isTrue, reason: made.errorMessage);

    // A database whose own records hold the same ids.
    final live = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(live.close);
    await seedEveryTable(live);
    for (final sql in [
      "UPDATE targets SET name = 'Live', created_at = 99, ra = 9",
      'UPDATE imaging_sessions SET start_time = 99',
      "UPDATE captured_images SET captured_at = 99, file_path = '/live.fits'",
      'UPDATE sequences SET created_at = 99',
      'UPDATE sequence_runs SET started_at = 99',
      "UPDATE dark_library SET created_at = 99, file_path = '/live-dark.fits'",
      'UPDATE integrated_masters SET created_at = 99',
      'UPDATE recipes SET created_at = 99',
      "UPDATE equipment_profiles SET name = 'Live rig'",
      "UPDATE notes_journal SET id = 'a note written here'",
    ]) {
      await live.customStatement(sql);
    }

    final restored = await BackupService(
      database: live,
      logger: logger,
    ).restoreBackup(filePath: file);
    expect(restored.success, isTrue, reason: restored.errorMessage);

    Future<Object?> one(String sql) async =>
        (await live.customSelect(sql).getSingle()).data.values.single;
    const seedTarget =
        "(SELECT id FROM targets WHERE name = 'seed targets name')";
    const seedSession =
        '(SELECT id FROM imaging_sessions WHERE start_time = 1)';
    const seedRun = '(SELECT id FROM sequence_runs WHERE started_at = 1)';
    const seedDark =
        "(SELECT id FROM dark_library WHERE file_path = 'seed dark_library file_path')";
    const seedMaster =
        '(SELECT id FROM integrated_masters WHERE created_at = 1)';
    expect(await one('SELECT $seedTarget'), isNot(7));

    // A foreign key.
    expect(
      await one(
        'SELECT count(*) FROM imaging_sessions '
        'WHERE id = $seedSession AND target_id = $seedTarget',
      ),
      1,
    );
    // A plain id column.
    for (final (table, column, parent) in [
      ('guide_rms_history', 'target_id', seedTarget),
      ('stacked_results', 'target_id', seedTarget),
      ('stacked_results', 'session_id', seedSession),
      ('sequence_decisions', 'sequence_run_id', seedRun),
      ('notes_journal', 'sequence_run_id', seedRun),
    ]) {
      expect(
        await one('SELECT count(*) FROM "$table" WHERE "$column" = $parent'),
        1,
        reason: '$table.$column follows its record',
      );
      expect(
        await one('SELECT count(*) FROM "$table"'),
        2,
        reason: '$table: the live row and the backup row',
      );
    }
    // An id whose table another column names.
    expect(
      await one(
        "SELECT count(*) FROM calibration_tags WHERE master_type = 'dark' "
        'AND master_id = $seedDark',
      ),
      1,
    );
    // A JSON list of ids.
    expect(
      await one(
        'SELECT count(*) FROM narrowband_composites '
        "WHERE component_master_ids = '[' || $seedMaster || ']'",
      ),
      1,
    );
    // A link into its own table.
    expect(
      await one(
        "SELECT p.created_at FROM recipes c JOIN recipes p "
        "ON p.id = c.parent_recipe_id WHERE c.name = 'Branch'",
      ),
      1,
      reason: 'the branch hangs on the backup recipe, not the live one',
    );
    expect(await live.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    // What was left out is a record this database has its own version of;
    // nothing was left out for want of the record it hangs on.
    for (final reason in [
      RestoreLeftOut.ownerLeftOut,
      RestoreLeftOut.ownerNotInBackup,
      RestoreLeftOut.conflict,
    ]) {
      expect(restored.leftOut[reason], isNull, reason: restored.report);
    }
  });
}
