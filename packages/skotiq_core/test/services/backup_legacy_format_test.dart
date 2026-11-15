// Backups written by earlier releases keep restoring. The fixtures are files
// as those releases wrote them: 2.1 (8.x: settings, profiles, sequences,
// targets and twenty tables each under a key of its own, as drift JSON) and
// 3.0 (9.0.0: every table under `tables`, a row object per row).
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/services.dart';

import 'backup_restore_support.dart';

const _fixtures = 'test/fixtures/backups';

Future<Map<String, int>> _counts(SkotiqDatabase db) async => {
  for (final t in db.allTables.map((t) => t.actualTableName))
    t: (await db.customSelect('SELECT count(*) AS n FROM "$t"').getSingle())
        .read<int>('n'),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late LoggingService logger;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('skotiq_legacy_backup_');
    logger = LoggingService(
      applicationSupportDirectoryProvider: () async => dir,
      nativeInitWithLogging: ({String? logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );
  });
  tearDown(() => dir.delete(recursive: true));

  BackupService service(SkotiqDatabase db) => BackupService(
    database: db,
    logger: logger,
    backupDirectoryProvider: () async => Directory('${dir.path}/backups'),
  );

  group('a 2.1 backup', () {
    const file = '$_fixtures/backup_2_1.skbackup';

    test('is listed with its head', () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final head = await service(db).readBackupMetadata(file);
      expect(head?.version, '2.1');
      expect(head?.appVersion, '8.2.0');
      expect(head?.targetsCount, 1);
    });

    test('merges into an empty database: what stands alone comes back, and '
        'rows of a session it does not hold are left out', () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final result = await service(db).restoreBackup(filePath: file);
      expect(result.success, isTrue, reason: result.errorMessage);

      final counts = await _counts(db);
      for (final table in [
        'equipment_profiles',
        'targets',
        'sequences',
        'dark_library',
        'flat_history',
        'defect_maps',
        'observation_logs',
        'polar_alignment_history',
        'photometric_transforms',
        'focus_models',
      ]) {
        expect(counts[table], 1, reason: table);
        expect(result.categoryCounts[table], 1, reason: table);
      }
      expect(counts['sequence_nodes'], greaterThan(1));
      // Each of these is a row of a session, frame, target or sequence by its
      // id, and a 2.1 backup holds none of those under an id: placed
      // nowhere, and said so.
      for (final table in [
        'sequence_runs',
        'guide_rms_history',
        'science_session_config',
        'photometry_measurements',
        'frame_photometric_calibration',
        'transparency_samples',
        'psf_field_tiles',
        'science_frame_quality_metrics',
        'science_tile_metrics',
        'astrometry_residual_vectors',
        'moving_object_candidates',
        'line_ratio_products',
      ]) {
        expect(counts[table], 0, reason: table);
        expect(result.notRestored[table], 1, reason: table);
      }
      expect(result.leftOut.keys, [RestoreLeftOut.ownerNotInBackup]);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
      // A profile link follows the profile.
      final link = await db
          .customSelect(
            'SELECT p.name FROM flat_history f '
            'JOIN equipment_profiles p ON p.id = f.equipment_profile_id',
          )
          .getSingle();
      expect(link.read<String>('name'), 'seed equipment_profiles name');
      // A merge leaves the settings alone.
      expect(await SettingsDao(db).getSetting('fixture.setting'), isNull);
    });

    test('merges into the database it was taken from without adding a row '
        'twice', () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await seedEveryTable(db);
      final before = await _counts(db);
      final result = await service(db).restoreBackup(filePath: file);
      expect(result.success, isTrue, reason: result.errorMessage);
      final after = await _counts(db);
      // The fixture's sequence is one this database does not have.
      expect(result.categoryCounts.keys.toSet(), {
        'sequences',
        'sequence_nodes',
      });
      for (final t in before.keys) {
        if (t == 'sequences' || t == 'sequence_nodes') continue;
        expect(after[t], before[t], reason: t);
      }
      // The target agrees in every column a 2.1 backup holds of it.
      expect(result.notRestored, isEmpty, reason: result.report);
    });

    test(
      'replaces a database: its settings and safety limits take over',
      () async {
        final replaced = await replacedDatabase(dir, file, logger);
        addTearDown(replaced.close);
        expect(
          await SettingsDao(replaced).getSetting('fixture.setting'),
          'from the backup',
        );
        expect(
          (await replaced.weatherSettingsDao.getOrCreateSettings())
              .maxHumidityPercent,
          61,
        );
        final counts = await _counts(replaced);
        expect(counts['dark_library'], 1);
        expect(counts['science_tile_metrics'], 0);
        expect(
          await replaced.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
      },
    );
  });

  group('a 3.0 backup', () {
    const file = '$_fixtures/backup_3_0.skbackup';

    test('is listed with its head, without reading its rows', () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final head = await service(db).readBackupMetadata(file);
      expect(head?.version, '3.0');
      expect(head?.appVersion, '9.0.0');
      expect(head?.profilesCount, 1);
    });

    test('comes back row for row, by merge and by replace', () async {
      final source = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(source.close);
      final seeded = await seedEveryTable(source);
      await source.weatherSettingsDao.getOrCreateSettings();
      await source.weatherSettingsDao.updateSettings(maxHumidityPercent: 61);

      final merged = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(merged.close);
      final result = await service(merged).restoreBackup(filePath: file);
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(result.notRestored, isEmpty);
      final replaced = await replacedDatabase(dir, file, logger);
      addTearDown(replaced.close);

      // The fixture is a file of its day: it holds the columns the schema
      // had then. A column added since is not in it, and comes back as the
      // column's default.
      final fixture = jsonDecode(File(file).readAsStringSync()) as Map;
      String jsonKey(String column) => column.replaceAllMapped(
        RegExp('_([a-z0-9])'),
        (m) => m.group(1)!.toUpperCase(),
      );
      bool inFixture(String t, String column) {
        if (t == 'equipment_profiles') {
          return ((fixture['equipmentProfiles'] as List).first as Map)
              .containsKey(jsonKey(column));
        }
        final rows = (fixture['tables'] as Map)[t] as List;
        return rows.isEmpty || (rows.first as Map).containsKey(column);
      }

      Future<List<Map<String, Object?>>> rows(
        SkotiqDatabase db,
        String t,
      ) async => [
        for (final r
            in await db.customSelect('SELECT * FROM "$t" ORDER BY rowid').get())
          {...r.data}..removeWhere(
            (k, _) =>
                !inFixture(t, k) ||
                // Stamped when the row was written here.
                (t == 'weather_settings' && k.endsWith('_at')),
          ),
      ];
      for (final t in [...seeded, 'weather_settings']) {
        if (backupExcludedTables.containsKey(t) || t == 'app_settings') {
          continue;
        }
        final expected = await rows(source, t);
        expect(await rows(replaced, t), expected, reason: 'replace: $t');
        if (!backupMergeKeepsYours.containsKey(t)) {
          expect(await rows(merged, t), expected, reason: 'merge: $t');
        }
      }
      expect(
        await SettingsDao(replaced).getSetting('fixture.setting'),
        'from the backup',
      );
    });
  });

  group('a column the schema gains', () {
    test('is carried by a profile section of the 3.0 kind, whatever the '
        'column is', () async {
      // Built from the schema as it is now: every column of the table,
      // seeded, written the way 3.0 wrote the section.
      final source = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(source.close);
      await seedEveryTable(source);
      final profiles = [
        for (final row in await source.select(source.equipmentProfiles).get())
          row.toJson(),
      ];
      final file = File('${dir.path}/section.skbackup')
        ..writeAsStringSync(
          jsonEncode({
            'version': '3.0',
            'createdAt': '2026-11-14T21:00:00.000',
            'settings': <String, Object?>{},
            'equipmentProfiles': profiles,
            'tables': <String, Object?>{},
          }),
        );
      Future<List<Map<String, Object?>>> rows(SkotiqDatabase db) async => [
        for (final r
            in await db
                .customSelect('SELECT * FROM equipment_profiles ORDER BY id')
                .get())
          r.data,
      ];

      final replaced = await replacedDatabase(dir, file.path, logger);
      addTearDown(replaced.close);
      expect(await rows(replaced), await rows(source));

      final again = await service(source).restoreBackup(filePath: file.path);
      expect(again.success, isTrue, reason: again.errorMessage);
      expect(again.notRestored, isEmpty, reason: again.report);
      expect(again.itemsRestored, 0);
    });

    test('after a backup was written does not make the backup\'s rows '
        'another record', () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await seedEveryTable(db);
      final whole = File('${dir.path}/whole.skbackup');
      expect(
        (await service(db).createBackup(customPath: whole.path)).success,
        isTrue,
      );
      // The same backup as a build before the last column of each table
      // would have written it: without that column, where the column is one
      // a migration can add (it may be null or has a default).
      final addable = <String>{};
      for (final t in db.allTables.map((t) => t.actualTableName)) {
        final last =
            (await db.customSelect('PRAGMA table_info("$t")').get()).last;
        if (last.read<int>('notnull') == 0 ||
            last.readNullable<String>('dflt_value') != null) {
          addable.add(t);
        }
      }
      var dropped = 0;
      var dropping = false;
      String older(String line) {
        if (line.contains('{"columns":[')) {
          final start = jsonDecode('{$line]}}') as Map;
          final columns = (start.values.single as Map)['columns'] as List;
          dropping = addable.contains(start.keys.single);
          if (!dropping) return line;
          dropped++;
          return '${jsonEncode(start.keys.single)}:{"columns":'
              '${jsonEncode(columns.sublist(0, columns.length - 1))},'
              '"rows":[';
        }
        if (line.startsWith('[') && dropping) {
          final comma = line.endsWith(',');
          final row =
              jsonDecode(comma ? line.substring(0, line.length - 1) : line)
                  as List;
          return '${jsonEncode(row.sublist(0, row.length - 1))}'
              '${comma ? ',' : ''}';
        }
        return line;
      }

      final file = File('${dir.path}/older.skbackup')
        ..writeAsStringSync(whole.readAsLinesSync().map(older).join('\n'));
      expect(dropped, greaterThan(20));

      final result = await service(db).restoreBackup(filePath: file.path);
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(result.notRestored, isEmpty, reason: result.report);
      expect(result.itemsRestored, 0);
      expect(result.alreadyHere, greaterThan(40));
      expect(
        (await db
                .customSelect(
                  'SELECT default_readout_mode FROM equipment_profiles',
                )
                .getSingle())
            .data
            .values
            .single,
        isNotNull,
        reason: 'the live value of a column the backup lacks stays',
      );
    });
  });
}
