// Two claims the Backup & Restore screen makes, and what makes them true.
//
// 1. WHERE backups live. `_getBackupDirectory` resolving to
//    getApplicationDocumentsDirectory()/Skotiq/backups regardless of the
//    configured data directory puts every install on one machine — the GUI, a
//    headless daemon pinned to its own state dir, a scratch profile — into a
//    single shared folder. "Recent Backups" then lists bundles from databases
//    the running instance has never seen, with nothing in the row to tell them
//    apart, and Restore on a foreign row is one click away.
//
// 2. WHAT a restore actually wrote. `_importProfiles` inserting with the
//    bundle's own row id under InsertMode.insertOrIgnore and incrementing its
//    counter unconditionally discards a profile whose id the local table has
//    reused while still reporting it restored: "Restored 123 items" for a
//    restore that wrote 122.

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

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ns_backup_identity_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('backup directory follows the database it snapshots', () {
    test('the configured data directory owns the backups folder', () async {
      final dataDir = Directory(p.join(tempDir.path, 'daemon-state'))
        ..createSync(recursive: true);
      final docs = Directory(p.join(tempDir.path, 'Documents'))
        ..createSync(recursive: true);

      final dir = await resolveDefaultBackupDirectory(
        environment: {'SKOTIQ_DATABASE_DIR': dataDir.path},
        documentsDirectoryProvider: () async => docs,
      );

      expect(dir.path, p.join(dataDir.path, 'backups'));
      // A scratch/daemon instance must NOT be able to read or write the
      // developer's Documents bundles.
      expect(dir.path, isNot(contains(docs.path)));
    });

    test('backups sit beside the database file they came from', () async {
      final dataDir = Directory(p.join(tempDir.path, 'daemon-state'))
        ..createSync(recursive: true);
      final docs = Directory(p.join(tempDir.path, 'Documents'))
        ..createSync(recursive: true);

      final database = await resolveDefaultDatabaseFile(
        environment: {'SKOTIQ_DATABASE_DIR': dataDir.path},
        documentsDirectoryProvider: () async => docs,
      );
      final backups = await resolveDefaultBackupDirectory(
        environment: {'SKOTIQ_DATABASE_DIR': dataDir.path},
        documentsDirectoryProvider: () async => docs,
      );

      expect(p.dirname(backups.path), database.parent.path);
    });

    test('an install with no override keeps its historical folder', () async {
      final docs = Directory(p.join(tempDir.path, 'Documents'))
        ..createSync(recursive: true);

      final dir = await resolveDefaultBackupDirectory(
        environment: const {},
        documentsDirectoryProvider: () async => docs,
      );

      expect(dir.path, p.join(docs.path, 'Skotiq', 'backups'));
    });
  });

  group('restore reports what it wrote', () {
    late SkotiqDatabase db;
    late LoggingService logger;
    late BackupService service;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      logger = _testLogger(tempDir);
      service = BackupService(
        database: db,
        sequenceRepository: SequenceRepository(db.sequencesDao),
        logger: logger,
        backupDirectoryProvider: () async => tempDir,
      );
    });

    tearDown(() async {
      await db.close();
    });

    /// A minimal v2.1 bundle carrying [profiles] and nothing else.
    Future<String> writeBundle(List<Map<String, dynamic>> profiles) async {
      final file = File(p.join(tempDir.path, 'bundle.nsbackup'));
      await file.writeAsString(
        jsonEncode({
          'version': '2.1',
          'createdAt': DateTime.utc(2026, 8, 2).toIso8601String(),
          'appVersion': 'test',
          'platform': 'linux',
          'metadata': {'profilesCount': profiles.length},
          'equipmentProfiles': profiles,
        }),
      );
      return file.path;
    }

    Map<String, dynamic> profileJson({
      required int id,
      required String name,
      bool isActive = false,
      bool isDefault = false,
    }) {
      return {
        'id': id,
        'name': name,
        'isActive': isActive,
        'isDefault': isDefault,
        'focalLength': 530.0,
        'aperture': 106.0,
      };
    }

    test(
      'a backed-up profile survives an id collision instead of being dropped',
      () async {
        // Local row 1 carries the id the bundle's profile was saved under, but
        // has since been renamed. Under insertOrIgnore-by-id the bundle's
        // profile conflicted and was discarded.
        await db.equipmentProfilesDao.createProfile(
          EquipmentProfilesCompanion.insert(name: 'Local Work Do Not Lose'),
        );

        final path = await writeBundle([
          profileJson(id: 1, name: 'Backup Test Rig'),
        ]);

        final result = await service.restoreBackup(filePath: path);

        expect(result.success, isTrue);
        final names = (await db.equipmentProfilesDao.getAllProfiles())
            .map((profile) => profile.name)
            .toList();
        expect(
          names,
          containsAll(['Local Work Do Not Lose', 'Backup Test Rig']),
        );
        expect(result.itemsRestored, 1);
      },
    );

    test('a profile of the same name is updated, not duplicated', () async {
      final localId = await db.equipmentProfilesDao.createProfile(
        EquipmentProfilesCompanion.insert(
          name: 'Shared Rig',
          focalLength: const Value(1.0),
        ),
      );

      final path = await writeBundle([profileJson(id: 99, name: 'Shared Rig')]);

      final result = await service.restoreBackup(filePath: path);

      final profiles = await db.equipmentProfilesDao.getAllProfiles();
      expect(profiles, hasLength(1));
      expect(profiles.single.id, localId);
      expect(profiles.single.focalLength, 530.0);
      expect(result.itemsRestored, 1);
    });

    test('an ACTIVE profile in the bundle survives a merge', () async {
      // `idx_profiles_single_active` is a partial unique index over is_active
      // WHERE is_active = 1. A bundle always carries exactly one active profile
      // and a live install always already has one, so a verbatim
      // `isActive: true` insert violates the index and insertOrIgnore discards
      // the row — whatever the ids are.
      final localId = await db.equipmentProfilesDao.createProfile(
        EquipmentProfilesCompanion.insert(name: 'My Rig'),
      );

      final path = await writeBundle([
        profileJson(
          id: 7,
          name: 'Someone Elses Rig',
          isActive: true,
          isDefault: true,
        ),
      ]);

      final result = await service.restoreBackup(filePath: path);

      expect(result.success, isTrue);
      expect(result.itemsRestored, 1);
      final names = (await db.equipmentProfilesDao.getAllProfiles())
          .map((profile) => profile.name)
          .toList();
      expect(names, containsAll(['My Rig', 'Someone Elses Rig']));

      // getDefaultProfile/getActiveProfile use getSingleOrNull, which throws
      // outright once a second row claims the flag — so a merge that imports
      // the bundle's flags verbatim breaks profile lookup entirely.
      expect((await db.equipmentProfilesDao.getDefaultProfile())?.id, localId);
      expect((await db.equipmentProfilesDao.getActiveProfile())?.id, localId);
    });

    test(
      'restoring into an empty table honours the bundle default exactly once',
      () async {
        final path = await writeBundle([
          profileJson(id: 1, name: 'First'),
          profileJson(id: 2, name: 'Second', isActive: true, isDefault: true),
        ]);

        final result = await service.restoreBackup(filePath: path);

        expect(result.itemsRestored, 2);
        expect(
          (await db.equipmentProfilesDao.getDefaultProfile())?.name,
          'Second',
        );
        expect(
          (await db.equipmentProfilesDao.getActiveProfile())?.name,
          'Second',
        );
      },
    );

    test('two same-named profiles in one bundle claim two rows', () async {
      final path = await writeBundle([
        profileJson(id: 1, name: 'Rig'),
        profileJson(id: 2, name: 'Rig'),
      ]);

      final result = await service.restoreBackup(filePath: path);

      expect(await db.equipmentProfilesDao.getAllProfiles(), hasLength(2));
      expect(result.itemsRestored, 2);
    });
  });
}
