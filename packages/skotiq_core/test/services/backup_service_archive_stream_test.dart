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
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/services.dart';
import 'package:path/path.dart' as p;

import 'backup_restore_support.dart';

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
    logger = testLogger(tempDir);
  });

  tearDown(() async {
    await srcDb.close();
    await dstDb.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  BackupService serviceFor(SkotiqDatabase db) =>
      BackupService(database: db, logger: logger);

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

  test('the archive is one JSON document with a line for each row', () async {
    await seed(srcDb);
    final backupPath = p.join(tempDir.path, 'lines.skbackup');
    final created = await serviceFor(
      srcDb,
    ).createBackup(customPath: backupPath);
    expect(created.success, isTrue, reason: created.errorMessage);

    final archive = await archiveAt(backupPath);
    expect(archive['version'], BackupService.backupVersion);
    final counts = (archive['metadata'] as Map)['tableCounts'] as Map;
    expect(counts['guide_rms_history'], pagedRowCount);
    final lines = await File(backupPath).readAsLines();
    expect(
      lines.where((line) => line.startsWith('[')),
      hasLength(counts.values.fold<int>(0, (sum, n) => sum + (n as int))),
    );
    expect(
      (await serviceFor(srcDb).readBackupMetadata(backupPath))?.version,
      BackupService.backupVersion,
    );
  });

  test(
    'a table larger than one dump page round-trips row-for-row, in order',
    () async {
      await seed(srcDb);

      final backupPath = p.join(tempDir.path, 'paged.skbackup');
      final created = await serviceFor(
        srcDb,
      ).createBackup(customPath: backupPath);
      expect(created.success, isTrue, reason: created.errorMessage);

      final archive = await archiveAt(backupPath);
      final table = archive['tables']['guide_rms_history'] as Map;
      final rms = (table['columns'] as List).indexOf('total_rms_arcsec');
      final rows = (table['rows'] as List).cast<List>();
      expect(rows, hasLength(pagedRowCount));
      expect(
        rows.map((r) => r[rms]).toList(),
        [for (var i = 0; i < pagedRowCount; i++) i.toDouble()],
        reason: 'paging must not drop, duplicate, or reorder rows',
      );

      final restored = await serviceFor(
        dstDb,
      ).restoreBackup(filePath: backupPath);
      expect(restored.success, isTrue, reason: restored.errorMessage);
      expect(restored.categoryCounts['guide_rms_history'], pagedRowCount);

      final destRows = await dstDb.select(dstDb.guideRmsHistory).get();
      expect(destRows, hasLength(pagedRowCount));
      expect(destRows.map((r) => r.totalRmsArcsec).toList(), [
        for (var i = 0; i < pagedRowCount; i++) i.toDouble(),
      ]);
    },
  );
}
