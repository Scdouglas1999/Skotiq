// A backup file that is corrupt, cut short or wrong-shaped fails while it is
// being read into a database of its own, with the live equipment profiles,
// targets and sequences as they were. A well-formed one replaces them at the
// next start.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/services.dart';

import 'backup_restore_support.dart';
import 'package:path/path.dart' as p;

LoggingService _testLogger(Directory tempDir) {
  return LoggingService(
    applicationSupportDirectoryProvider: () async => tempDir,
    nativeInitWithLogging: ({String? logDirectory}) {},
    nativeInit: () {},
    currentLogFileProvider: () => null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackupService restore validation (P1 data-loss guard)', () {
    late SkotiqDatabase db;
    late Directory tempDir;
    late LoggingService logger;

    setUp(() async {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      tempDir = await Directory.systemTemp.createTemp('sk_restore_val_');
      logger = _testLogger(tempDir);
    });

    tearDown(() async {
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    BackupService serviceFor(SkotiqDatabase d) =>
        BackupService(database: d, logger: logger);

    /// Seed one profile and one target so we can prove they survive an
    /// aborted restore.
    Future<void> seedLiveData() async {
      await db.equipmentProfilesDao.createProfile(
        EquipmentProfilesCompanion.insert(
          name: 'Live Rig',
          focalLength: const Value(530.0),
          aperture: const Value(106.0),
        ),
      );
      await db.targetsDao.createTarget(
        TargetsCompanion.insert(name: 'M31', ra: 0.7, dec: 41.3),
      );
    }

    Future<File> writeBackup(String contents) async {
      final f = File(p.join(tempDir.path, 'backup.skbackup'));
      await f.writeAsString(contents);
      return f;
    }

    test('missing version aborts without wiping live data', () async {
      await seedLiveData();

      // A replace is the restore that would take the most away.
      final backupFile = await writeBackup(
        jsonEncode({
          'equipmentProfiles': [
            {'name': 'Restored Rig'},
          ],
        }),
      );

      final result = await serviceFor(
        db,
      ).restoreBackup(filePath: backupFile.path, mode: RestoreMode.replace);

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('version'));

      // Live data is intact — the wipe never ran.
      final profiles = await db.equipmentProfilesDao.getAllProfiles();
      expect(profiles, hasLength(1));
      expect(profiles.single.name, 'Live Rig');
      final targets = await db.targetsDao.getAllTargets();
      expect(targets, hasLength(1));
      expect(targets.single.name, 'M31');
    });

    test('future backup version aborts without wiping live data', () async {
      await seedLiveData();
      final backup = await writeBackup(
        jsonEncode({
          'version': '3.2',
          'settings': <String, dynamic>{},
          'equipmentProfiles': <Object>[],
          'sequences': <Object>[],
          'targets': <Object>[],
        }),
      );

      final result = await serviceFor(
        db,
      ).restoreBackup(filePath: backup.path, mode: RestoreMode.replace);

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('newer than supported'));
      final profiles = await db.equipmentProfilesDao.getAllProfiles();
      final targets = await db.targetsDao.getAllTargets();
      expect(profiles.single.name, 'Live Rig');
      expect(targets.single.name, 'M31');
    });

    test(
      'wrong-shaped section (targets is an object) aborts without wiping',
      () async {
        await seedLiveData();

        final backupFile = await writeBackup(
          jsonEncode({
            'version': '2.1',
            'targets': {'not': 'a list'},
          }),
        );

        final result = await serviceFor(
          db,
        ).restoreBackup(filePath: backupFile.path, mode: RestoreMode.replace);

        expect(result.success, isFalse);
        expect(result.errorMessage, contains('targets'));

        final profiles = await db.equipmentProfilesDao.getAllProfiles();
        expect(profiles, hasLength(1), reason: 'live data must survive abort');
        final targets = await db.targetsDao.getAllTargets();
        expect(targets, hasLength(1));
      },
    );

    test('profile row missing name aborts without wiping', () async {
      await seedLiveData();

      final backupFile = await writeBackup(
        jsonEncode({
          'version': '2.1',
          'equipmentProfiles': [
            {'description': 'no name here'},
          ],
        }),
      );

      final result = await serviceFor(
        db,
      ).restoreBackup(filePath: backupFile.path, mode: RestoreMode.replace);

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('name'));

      final profiles = await db.equipmentProfilesDao.getAllProfiles();
      expect(profiles, hasLength(1));
      expect(profiles.single.name, 'Live Rig');
    });

    test('malformed sequence aborts without wiping', () async {
      await seedLiveData();

      // A sequence entry missing the required rootNodeId / nodes map fails
      // to decode. That must abort the whole restore rather than silently
      // dropping the sequence into a freshly-wiped database.
      final backupFile = await writeBackup(
        jsonEncode({
          'version': '2.1',
          'sequences': [
            {'name': 'Broken Seq'}, // no rootNodeId, no nodes
          ],
        }),
      );

      final result = await serviceFor(
        db,
      ).restoreBackup(filePath: backupFile.path, mode: RestoreMode.replace);

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('sequences'));

      final profiles = await db.equipmentProfilesDao.getAllProfiles();
      expect(profiles, hasLength(1), reason: 'live data must survive abort');
    });

    test('truncated / non-JSON file aborts without wiping', () async {
      await seedLiveData();

      final backupFile = await writeBackup('{ this is not valid json');

      final result = await serviceFor(
        db,
      ).restoreBackup(filePath: backupFile.path, mode: RestoreMode.replace);

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('JSON'));

      final profiles = await db.equipmentProfilesDao.getAllProfiles();
      expect(profiles, hasLength(1));
      final targets = await db.targetsDao.getAllTargets();
      expect(targets, hasLength(1));
    });

    test('a valid backup replaces the live data at the next start', () async {
      final srcDb = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(srcDb.close);
      await srcDb.equipmentProfilesDao.createProfile(
        EquipmentProfilesCompanion.insert(name: 'Restored Rig'),
      );
      await srcDb.targetsDao.createTarget(
        TargetsCompanion.insert(name: 'M42', ra: 5.6, dec: -5.4),
      );
      final backupFile = File(p.join(tempDir.path, 'good.skbackup'));
      final backupResult = await serviceFor(
        srcDb,
      ).createBackup(customPath: backupFile.path);
      expect(backupResult.success, isTrue, reason: backupResult.errorMessage);

      final replaced = await replacedDatabase(
        tempDir,
        backupFile.path,
        logger,
        seed: (live) async {
          await live.equipmentProfilesDao.createProfile(
            EquipmentProfilesCompanion.insert(name: 'Live Rig'),
          );
          await live.targetsDao.createTarget(
            TargetsCompanion.insert(name: 'M31', ra: 0.7, dec: 41.3),
          );
        },
      );
      addTearDown(replaced.close);

      final profiles = await replaced.equipmentProfilesDao.getAllProfiles();
      expect(profiles.map((e) => e.name), ['Restored Rig']);
      final targets = await replaced.targetsDao.getAllTargets();
      expect(targets.map((t) => t.name), ['M42']);
    });
  });
}
