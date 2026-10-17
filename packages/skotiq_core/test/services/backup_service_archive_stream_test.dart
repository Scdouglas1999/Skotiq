// The archive writer used to build the whole database as one indented JSON
// String on the calling isolate, and `_dumpTable` read every row of every table
// with one unpaged `SELECT *` — including the per-frame science tables. Both
// run unattended off the auto-backup timer, mid-session.
//
// These tests pin the two behaviours that must not change while that is fixed:
// the compact (auto-save) archive carries exactly the same content as the
// human-readable one, and a table larger than one `_dumpTable` page still round
// -trips row-for-row.

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

  late SkotiqDatabase srcDb;
  late SkotiqDatabase dstDb;
  late Directory tempDir;
  late LoggingService logger;

  setUp(() async {
    srcDb = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dstDb = SkotiqDatabase.forTesting(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('sk_backup_stream_');
    logger = _testLogger(tempDir);
  });

  tearDown(() async {
    await srcDb.close();
    await dstDb.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  BackupService serviceFor(SkotiqDatabase db) => BackupService(
    database: db,
    sequenceRepository: SequenceRepository(db.sequencesDao),
    logger: logger,
  );

  /// More rows than one `_dumpTable` page, so the paged read has to stitch
  /// several pages back together in order.
  const pagedRowCount = 2500;

  Future<void> seed(SkotiqDatabase db) async {
    await db.darkLibraryDao.addEntry(
      DarkLibraryCompanion.insert(
        filePath: '/tmp/dark1.fits',
        exposureTime: 60.0,
        gain: const Value(100),
        offset: const Value(10),
      ),
    );
    await db.observationLogsDao.insertLog(
      timestamp: DateTime.utc(2026, 4, 1, 22),
      objectName: 'M31',
      ra: 0.7,
      dec: 41.3,
      notes: 'Hazy sky',
    );
    await db.batch((batch) {
      batch.insertAll(db.guideRmsHistory, [
        for (var i = 0; i < pagedRowCount; i++)
          GuideRmsHistoryCompanion.insert(
            sessionId: 'session-1',
            mountId: 'mount-1',
            totalRmsArcsec: i.toDouble(),
            sampleCount: i,
            recordedAt: DateTime.utc(2026, 4, 1, 22).add(Duration(seconds: i)),
          ),
      ]);
    });
  }

  Future<Map<String, dynamic>> archiveAt(String path) async =>
      jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;

  test(
    'the compact auto-save archive carries exactly the human-readable content',
    () async {
      await seed(srcDb);
      final service = serviceFor(srcDb);

      // Every successful backup records `autosave.last_backup_at`, so run one
      // throwaway first and the two archives under test see the same key set.
      await service.createBackup(
        customPath: p.join(tempDir.path, 'warmup.nsbackup'),
      );

      final prettyPath = p.join(tempDir.path, 'pretty.nsbackup');
      final compactPath = p.join(tempDir.path, 'compact.nsbackup');
      final pretty = await service.createBackup(customPath: prettyPath);
      final compact = await service.createBackup(
        customPath: compactPath,
        humanReadable: false,
      );
      expect(pretty.success, isTrue, reason: pretty.errorMessage);
      expect(compact.success, isTrue, reason: compact.errorMessage);

      final prettyJson = await archiveAt(prettyPath);
      final compactJson = await archiveAt(compactPath);
      // Both stamps move with the wall clock between the two calls.
      for (final archive in [prettyJson, compactJson]) {
        archive.remove('createdAt');
        (archive['settings'] as Map)[BackupService.lastBackupSettingKey] =
            'normalised';
      }
      expect(compactJson, equals(prettyJson));

      // The saving is real, not cosmetic.
      expect(
        await File(compactPath).length(),
        lessThan(await File(prettyPath).length()),
      );
      expect(
        await File(prettyPath).readAsString(),
        contains('\n  "version"'),
        reason: 'the operator-facing archive stays indented',
      );
    },
  );

  test(
    'a table larger than one dump page round-trips row-for-row, in order',
    () async {
      await seed(srcDb);

      final backupPath = p.join(tempDir.path, 'paged.nsbackup');
      final created = await serviceFor(
        srcDb,
      ).createBackup(customPath: backupPath, humanReadable: false);
      expect(created.success, isTrue, reason: created.errorMessage);

      final archive = await archiveAt(backupPath);
      final rows = (archive['guideRmsHistory'] as List).cast<Map>();
      expect(rows, hasLength(pagedRowCount));
      expect(
        rows.map((r) => r['totalRmsArcsec']).toList(),
        [for (var i = 0; i < pagedRowCount; i++) i.toDouble()],
        reason: 'paging must not drop, duplicate, or reorder rows',
      );

      final restored = await serviceFor(
        dstDb,
      ).restoreBackup(filePath: backupPath);
      expect(restored.success, isTrue, reason: restored.errorMessage);
      expect(restored.categoryCounts['guideRmsHistory'], pagedRowCount);

      final destRows = await dstDb.select(dstDb.guideRmsHistory).get();
      expect(destRows, hasLength(pagedRowCount));
      expect(destRows.map((r) => r.totalRmsArcsec).toList(), [
        for (var i = 0; i < pagedRowCount; i++) i.toDouble(),
      ]);
    },
  );
}
