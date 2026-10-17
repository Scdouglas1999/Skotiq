// Round-trip tests for the broadened backup-service coverage.
//
// Two newly-included tables (dark_library + notes_journal/observation_logs)
// are written into an in-memory database, backed up to disk, then restored
// into a fresh database and verified row-for-row. The test covers the
// idempotency guarantee too: re-running the restore against a populated
// destination must not duplicate rows.

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;

/// Test-only LoggingService that skips native init. The defaults inject
/// no-op callbacks so the FFI is never touched; `ensureInitialized` still
/// resolves quickly because the `applicationSupportDirectoryProvider` we
/// pass returns the system temp dir.
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

  group('BackupService extended coverage', () {
    late SkotiqDatabase srcDb;
    late SkotiqDatabase dstDb;
    late Directory tempDir;
    late LoggingService logger;

    setUp(() async {
      srcDb = SkotiqDatabase.forTesting(NativeDatabase.memory());
      dstDb = SkotiqDatabase.forTesting(NativeDatabase.memory());
      tempDir = await Directory.systemTemp.createTemp('sk_backup_ext_test_');
      logger = _testLogger(tempDir);
    });

    tearDown(() async {
      await srcDb.close();
      await dstDb.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    BackupService serviceFor(SkotiqDatabase db) => BackupService(
      database: db,
      sequenceRepository: SequenceRepository(db.sequencesDao),
      logger: logger,
    );

    test(
      'dark_library + notes_journal round-trip through backup/restore',
      () async {
        // Seed two tables that the legacy backup did NOT cover so the round
        // trip exercises the new code path specifically.
        await srcDb.darkLibraryDao.addEntry(
          DarkLibraryCompanion.insert(
            filePath: '/tmp/dark1.fits',
            exposureTime: 60.0,
            gain: const Value(100),
            offset: const Value(10),
            temperature: const Value(-10.0),
            binX: const Value(1),
            binY: const Value(1),
          ),
        );
        await srcDb.darkLibraryDao.addEntry(
          DarkLibraryCompanion.insert(
            filePath: '/tmp/dark2.fits',
            exposureTime: 30.0,
            gain: const Value(200),
            offset: const Value(5),
            temperature: const Value(-15.0),
          ),
        );
        await srcDb.observationLogsDao.insertLog(
          timestamp: DateTime.utc(2026, 4, 1, 22, 0),
          objectName: 'M31',
          ra: 0.7,
          dec: 41.3,
          notes: 'Hazy sky',
        );
        await srcDb.observationLogsDao.insertLog(
          timestamp: DateTime.utc(2026, 4, 2, 22, 0),
          objectName: 'M42',
          ra: 5.6,
          dec: -5.4,
          notes: 'Crisp Orion',
        );

        // Backup
        final backupFile = File(p.join(tempDir.path, 'backup.skbackup'));
        final backupResult = await serviceFor(
          srcDb,
        ).createBackup(customPath: backupFile.path);
        expect(backupResult.success, isTrue, reason: backupResult.errorMessage);
        expect(await backupFile.exists(), isTrue);

        // Restore into a fresh DB.
        final restore = await serviceFor(
          dstDb,
        ).restoreBackup(filePath: backupFile.path);
        expect(restore.success, isTrue, reason: restore.errorMessage);
        expect(restore.categoryCounts['darkLibrary'], 2);
        expect(restore.categoryCounts['notesJournal'], 2);

        // Verify row content survived end-to-end.
        final darks = await dstDb.darkLibraryDao.getAllEntries();
        expect(darks, hasLength(2));
        final paths = darks.map((d) => d.filePath).toSet();
        expect(paths, containsAll(['/tmp/dark1.fits', '/tmp/dark2.fits']));

        final logs = await dstDb.observationLogsDao.getAllLogs();
        expect(logs, hasLength(2));
        final names = logs.map((l) => l.objectName).toSet();
        expect(names, containsAll(['M31', 'M42']));
      },
    );

    test('second restore is idempotent (no row duplication)', () async {
      await srcDb.darkLibraryDao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: '/tmp/dark1.fits',
          exposureTime: 60.0,
          gain: const Value(100),
          offset: const Value(10),
        ),
      );
      await srcDb.observationLogsDao.insertLog(
        timestamp: DateTime.utc(2026, 4, 1, 22, 0),
        objectName: 'M31',
        ra: 0.7,
        dec: 41.3,
      );

      final backupFile = File(p.join(tempDir.path, 'backup.skbackup'));
      final backupResult = await serviceFor(
        srcDb,
      ).createBackup(customPath: backupFile.path);
      expect(backupResult.success, isTrue, reason: backupResult.errorMessage);

      // First restore populates dst.
      final first = await serviceFor(
        dstDb,
      ).restoreBackup(filePath: backupFile.path);
      expect(first.success, isTrue, reason: first.errorMessage);

      // Second restore must NOT double the row counts. InsertMode.insertOrIgnore
      // means the existing primary keys conflict and the new rows are silently
      // dropped — which is exactly what we want so a panicked operator can
      // re-run a restore without destroying data.
      final second = await serviceFor(
        dstDb,
      ).restoreBackup(filePath: backupFile.path);
      expect(second.success, isTrue);

      final darks = await dstDb.darkLibraryDao.getAllEntries();
      expect(darks, hasLength(1), reason: 'restore must be idempotent');

      final logs = await dstDb.observationLogsDao.getAllLogs();
      expect(logs, hasLength(1), reason: 'restore must be idempotent');
    });

    // Audit 2026-07-29: the weather_settings table was in no backup at all, so
    // migrating machines silently reset every safety threshold AND the master
    // switch to defaults while the Backup page promised "restoring replaces
    // local configuration". Configuration must win on restore, which also means
    // it cannot ride on the insert-or-ignore path the history tables use.
    test(
      'weather-safety configuration round-trips through a restore',
      () async {
        await srcDb.weatherSettingsDao.getOrCreateSettings();
        await srcDb.weatherSettingsDao.updateSettings(
          weatherSafetyEnabled: true,
          maxHumidityPercent: 55,
          maxWindSpeedKph: 12,
          maxCloudCoverPercent: 40,
          autoParkEnabled: false,
          autoResumeEnabled: true,
          triggerDistanceKm: 75,
          leadTimeMinutes: 25,
          cloudDensityThreshold: 35,
        );

        final backupFile = File(p.join(tempDir.path, 'weather.skbackup'));
        final backupResult = await serviceFor(
          srcDb,
        ).createBackup(customPath: backupFile.path);
        expect(backupResult.success, isTrue, reason: backupResult.errorMessage);

        // The destination already holds a defaults row, exactly as a fresh
        // install does — this is what made insert-or-ignore drop the payload.
        final before = await dstDb.weatherSettingsDao.getOrCreateSettings();
        expect(before.maxHumidityPercent, isNot(55));

        final restore = await serviceFor(
          dstDb,
        ).restoreBackup(filePath: backupFile.path);
        expect(restore.success, isTrue, reason: restore.errorMessage);
        expect(restore.categoryCounts['weatherSettings'], 1);

        final restored = await dstDb.weatherSettingsDao.getOrCreateSettings();
        expect(restored.weatherSafetyEnabled, isTrue);
        expect(restored.maxHumidityPercent, 55);
        expect(restored.maxWindSpeedKph, 12);
        expect(restored.maxCloudCoverPercent, 40);
        expect(restored.autoParkEnabled, isFalse);
        expect(restored.autoResumeEnabled, isTrue);
        expect(restored.triggerDistanceKm, 75);
        expect(restored.leadTimeMinutes, 25);
        expect(restored.cloudDensityThreshold, 35);

        // Still a single configuration row, not a second one carrying the
        // source machine's auto-increment id.
        final rows = await dstDb.select(dstDb.weatherSettings).get();
        expect(rows, hasLength(1));
      },
    );

    // Audit 2026-07-29: two manual backups were written to disk and the Backup
    // & Restore card still read "Last Full Backup: Never" — only the scheduled
    // path recorded the time. The record now belongs to whoever writes the file.
    test('a manual backup records the last-backup time', () async {
      final dao = srcDb.settingsDao;
      expect(await dao.getSetting(BackupService.lastBackupSettingKey), isNull);

      final backupFile = File(p.join(tempDir.path, 'manual.skbackup'));
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      final result = await serviceFor(
        srcDb,
      ).createBackup(customPath: backupFile.path);
      expect(result.success, isTrue, reason: result.errorMessage);

      final raw = await dao.getSetting(BackupService.lastBackupSettingKey);
      expect(raw, isNotNull);
      final recorded = DateTime.parse(raw!);
      expect(recorded.isAfter(before), isTrue);
      expect(
        recorded.difference(result.timestamp).abs(),
        lessThan(const Duration(seconds: 2)),
      );
    });

    test('modern sequence nodes survive a full backup and restore', () async {
      final sourceRepository = SequenceRepository(srcDb.sequencesDao);
      await sourceRepository.saveSequence(
        Sequence.create(
          name: 'Recovery plan',
          rootNodeId: 'recovery',
          nodes: {
            'recovery': RecoveryNode(
              id: 'recovery',
              name: 'Watch transparency',
              comment: 'Switch plans only after a sustained drop',
              isEnabled: false,
              recoveryAction: RecoveryActionType.switchTargetOrFilter,
              maxRetries: 7,
              triggerType: TriggerType.transparencyDropped,
              triggerThreshold: 0.42,
              hfrThresholdPercent: 17.5,
              hfrConsecutiveFrames: 4,
              triggerEveryNFrames: 19,
              focusDriftWindowSize: 21,
              focusDriftMinIncreasingCount: 8,
              focusDriftMinTotalIncrease: 0.85,
              guidingFailedDurationSecs: 47,
              cloudMinutesBefore: 6,
              cloudCoverageThresholdPercent: 63,
              cloudOpeningMinDurationSecs: 420,
              cloudCoverMaxPercent: 74,
              cloudCoverDurationSecs: 92,
              transparencyBelowThreshold: 0.58,
              transparencyDurationSecs: 135,
            ),
          },
        ),
      );

      final backupFile = File(p.join(tempDir.path, 'sequence.skbackup'));
      final backup = await serviceFor(
        srcDb,
      ).createBackup(customPath: backupFile.path);
      expect(backup.success, isTrue, reason: backup.errorMessage);

      final restore = await serviceFor(
        dstDb,
      ).restoreBackup(filePath: backupFile.path);
      expect(restore.success, isTrue, reason: restore.errorMessage);
      expect(restore.categoryCounts['sequences'], 1);

      final restoredRepository = SequenceRepository(dstDb.sequencesDao);
      final restored = (await restoredRepository.loadAllSequences()).single;
      final recovery = restored.nodes['recovery'] as RecoveryNode;
      expect(recovery.name, 'Watch transparency');
      expect(recovery.comment, 'Switch plans only after a sustained drop');
      expect(recovery.isEnabled, isFalse);
      expect(recovery.recoveryAction, RecoveryActionType.switchTargetOrFilter);
      expect(recovery.maxRetries, 7);
      expect(recovery.triggerType, TriggerType.transparencyDropped);
      expect(recovery.triggerThreshold, 0.42);
      expect(recovery.hfrThresholdPercent, 17.5);
      expect(recovery.hfrConsecutiveFrames, 4);
      expect(recovery.triggerEveryNFrames, 19);
      expect(recovery.focusDriftWindowSize, 21);
      expect(recovery.focusDriftMinIncreasingCount, 8);
      expect(recovery.focusDriftMinTotalIncrease, 0.85);
      expect(recovery.guidingFailedDurationSecs, 47);
      expect(recovery.cloudMinutesBefore, 6);
      expect(recovery.cloudCoverageThresholdPercent, 63);
      expect(recovery.cloudOpeningMinDurationSecs, 420);
      expect(recovery.cloudCoverMaxPercent, 74);
      expect(recovery.cloudCoverDurationSecs, 92);
      expect(recovery.transparencyBelowThreshold, 0.58);
      expect(recovery.transparencyDurationSecs, 135);
    });

    test(
      'profile identity, default flag, and complete settings round-trip',
      () async {
        await srcDb.equipmentProfilesDao.createProfile(
          EquipmentProfilesCompanion.insert(
            id: const Value(47),
            name: 'Production Rig',
            cameraId: const Value('native:zwo:0'),
            safetyMonitorId: const Value('ascom:safety'),
            coverCalibratorId: const Value('alpaca:cover'),
            defaultGain: const Value(139),
            defaultOffset: const Value(21),
            coolOnConnect: const Value(true),
            defaultCenteringExposure: const Value(2.5),
            cameraName: const Value('ASI1600MM Cool'),
            telescopeName: const Value('10-inch Newtonian'),
            telescopeFocalLength: const Value(1016),
            sortOrder: const Value(4),
            profileColor: const Value(0x123456),
          ),
        );

        final backupFile = File(p.join(tempDir.path, 'profile.skbackup'));
        final backup = await serviceFor(
          srcDb,
        ).createBackup(customPath: backupFile.path);
        expect(backup.success, isTrue, reason: backup.errorMessage);

        final restore = await serviceFor(
          dstDb,
        ).restoreBackup(filePath: backupFile.path, replaceExisting: true);
        expect(restore.success, isTrue, reason: restore.errorMessage);

        final profile =
            (await dstDb.equipmentProfilesDao.getAllProfiles()).single;
        // Identity is the profile NAME, not the source row id: ids are local
        // autoincrement values, so re-using the bundle's id drops the row when
        // restoring into a database that has already handed that id out.
        expect(profile.name, 'Production Rig');
        expect(profile.isDefault, isTrue);
        expect(profile.isActive, isTrue);
        expect(profile.defaultGain, 139);
        expect(profile.defaultOffset, 21);
        expect(profile.coolOnConnect, isTrue);
        expect(profile.defaultCenteringExposure, 2.5);
        expect(profile.safetyMonitorId, 'ascom:safety');
        expect(profile.coverCalibratorId, 'alpaca:cover');
        expect(profile.cameraName, 'ASI1600MM Cool');
        expect(profile.telescopeName, '10-inch Newtonian');
        expect(profile.telescopeFocalLength, 1016);
        expect(profile.sortOrder, 4);
        expect(profile.profileColor, 0x123456);
      },
    );

    test('backup format version is bumped', () {
      expect(BackupService.backupVersion, '2.1');
    });
  });
}
