// P1 DATA-LOSS GUARD — restore must validate the ENTIRE backup payload
// before it touches (wipes) the live database.
//
// These tests prove that a corrupt / truncated / wrong-shaped backup file
// aborts the restore with the user's live equipment profiles, targets, and
// sequences fully intact — i.e. `_clearAllData` is never reached when the
// payload is invalid. The happy-path test confirms a well-formed backup still
// round-trips and replaces data as before.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
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
      tempDir = await Directory.systemTemp.createTemp('ns_restore_val_');
      logger = _testLogger(tempDir);
    });

    tearDown(() async {
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    BackupService serviceFor(SkotiqDatabase d) => BackupService(
      database: d,
      sequenceRepository: SequenceRepository(d.sequencesDao),
      logger: logger,
    );

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
      final f = File(p.join(tempDir.path, 'backup.nsbackup'));
      await f.writeAsString(contents);
      return f;
    }

    test('missing version aborts without wiping live data', () async {
      await seedLiveData();

      // replaceExisting:true would normally wipe the DB. A version-less
      // payload must abort BEFORE that.
      final backupFile = await writeBackup(
        jsonEncode({
          'equipmentProfiles': [
            {'name': 'Restored Rig'},
          ],
        }),
      );

      final result = await serviceFor(
        db,
      ).restoreBackup(filePath: backupFile.path, replaceExisting: true);

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
          'version': '3.0',
          'settings': <String, dynamic>{},
          'equipmentProfiles': <Object>[],
          'sequences': <Object>[],
          'targets': <Object>[],
        }),
      );

      final result = await serviceFor(
        db,
      ).restoreBackup(filePath: backup.path, replaceExisting: true);

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
        ).restoreBackup(filePath: backupFile.path, replaceExisting: true);

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
      ).restoreBackup(filePath: backupFile.path, replaceExisting: true);

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
      ).restoreBackup(filePath: backupFile.path, replaceExisting: true);

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
      ).restoreBackup(filePath: backupFile.path, replaceExisting: true);

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('JSON'));

      final profiles = await db.equipmentProfilesDao.getAllProfiles();
      expect(profiles, hasLength(1));
      final targets = await db.targetsDao.getAllTargets();
      expect(targets, hasLength(1));
    });

    test('valid backup still replaces live data on replaceExisting', () async {
      await seedLiveData();

      // Build a real backup from a source DB so the payload is structurally
      // perfect, then restore it over the seeded live DB with replace.
      final srcDb = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(srcDb.close);
      await srcDb.equipmentProfilesDao.createProfile(
        EquipmentProfilesCompanion.insert(name: 'Restored Rig'),
      );
      await srcDb.targetsDao.createTarget(
        TargetsCompanion.insert(name: 'M42', ra: 5.6, dec: -5.4),
      );

      final backupFile = File(p.join(tempDir.path, 'good.nsbackup'));
      final backupResult = await serviceFor(
        srcDb,
      ).createBackup(customPath: backupFile.path);
      expect(backupResult.success, isTrue, reason: backupResult.errorMessage);

      final result = await serviceFor(
        db,
      ).restoreBackup(filePath: backupFile.path, replaceExisting: true);
      expect(result.success, isTrue, reason: result.errorMessage);

      final profiles = await db.equipmentProfilesDao.getAllProfiles();
      final names = profiles.map((e) => e.name).toSet();
      expect(names, contains('Restored Rig'));
      expect(
        names,
        isNot(contains('Live Rig')),
        reason: 'replaceExisting wiped the old profile after validation',
      );

      final targets = await db.targetsDao.getAllTargets();
      final tNames = targets.map((t) => t.name).toSet();
      expect(tNames, contains('M42'));
    });
  });
}
