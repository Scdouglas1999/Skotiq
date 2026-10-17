import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/database.dart';

/// FileSize population (`insertSequenceFrame` stats the on-disk
/// FITS at insert time) plus the `backfillMissingFileSizes` helper for
/// legacy rows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late ImagesDao imagesDao;
  late Directory tempDir;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = ImagesDao(db);
    tempDir = await Directory.systemTemp.createTemp(
      'skotiq_filesize_test_',
    );
  });

  tearDown(() async {
    await db.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Best-effort cleanup.
    }
  });

  group('insertSequenceFrame fileSize population', () {
    test('populates fileSize when on-disk file exists', () async {
      final file = File('${tempDir.path}${Platform.pathSeparator}frame.fits');
      const expectedLength = 4242;
      await file.writeAsBytes(List<int>.filled(expectedLength, 0xAB));

      final id = await imagesDao.insertSequenceFrame(
        filePath: file.path,
        fileName: 'frame.fits',
        fileFormat: 'fits',
        exposureDuration: 60.0,
        capturedAt: DateTime.utc(2026, 1, 1),
        isAccepted: true,
        producingNodeId: 'node-1',
      );

      final row = await imagesDao.getImageById(id);
      expect(row, isNotNull);
      expect(row!.fileSize, expectedLength);
    });

    test('leaves fileSize NULL when filePath is empty', () async {
      // Some legacy emit sites in the Rust executor don't thread
      // save_path through (recorded as a known case in the executor's
      // FrameAccepted handler). The DAO should still write the row.
      final id = await imagesDao.insertSequenceFrame(
        filePath: '',
        fileName: '',
        fileFormat: 'fits',
        exposureDuration: 60.0,
        capturedAt: DateTime.utc(2026, 1, 1),
        isAccepted: true,
        producingNodeId: 'node-2',
      );
      final row = await imagesDao.getImageById(id);
      expect(row, isNotNull);
      expect(row!.fileSize, isNull);
    });

    test(
      'leaves fileSize NULL but still writes the row when file is missing',
      () async {
        final missingPath =
            '${tempDir.path}${Platform.pathSeparator}does_not_exist.fits';

        final id = await imagesDao.insertSequenceFrame(
          filePath: missingPath,
          fileName: 'does_not_exist.fits',
          fileFormat: 'fits',
          exposureDuration: 60.0,
          capturedAt: DateTime.utc(2026, 1, 1),
          isAccepted: true,
          producingNodeId: 'node-3',
        );
        final row = await imagesDao.getImageById(id);
        expect(
          row,
          isNotNull,
          reason: 'row must be written even if file size lookup fails',
        );
        expect(row!.fileSize, isNull);
        expect(row.filePath, missingPath);
      },
    );
  });

  group('backfillMissingFileSizes', () {
    test(
      'updates rows where file_size IS NULL and skips missing files',
      () async {
        // One real file (will be updated), one missing (will be skipped),
        // one empty-path (also skipped).
        final realFile = File(
          '${tempDir.path}${Platform.pathSeparator}real.fits',
        );
        await realFile.writeAsBytes(List<int>.filled(1500, 1));
        final realId = await imagesDao.insertSequenceFrame(
          filePath: realFile.path,
          fileName: 'real.fits',
          fileFormat: 'fits',
          exposureDuration: 60.0,
          capturedAt: DateTime.utc(2026, 1, 1),
          isAccepted: true,
          producingNodeId: 'real',
        );
        // Force this row's fileSize back to NULL to simulate a an earlier build
        // legacy row (insertSequenceFrame a newer build has already populated
        // it from disk).
        await db.customStatement(
          'UPDATE captured_images SET file_size = NULL WHERE id = ?',
          [realId],
        );

        final missingId = await imagesDao.insertSequenceFrame(
          filePath: '${tempDir.path}${Platform.pathSeparator}missing.fits',
          fileName: 'missing.fits',
          fileFormat: 'fits',
          exposureDuration: 60.0,
          capturedAt: DateTime.utc(2026, 1, 1),
          isAccepted: true,
          producingNodeId: 'missing',
        );

        final emptyId = await imagesDao.insertSequenceFrame(
          filePath: '',
          fileName: '',
          fileFormat: 'fits',
          exposureDuration: 60.0,
          capturedAt: DateTime.utc(2026, 1, 1),
          isAccepted: true,
          producingNodeId: 'empty',
        );

        final summary = await imagesDao.backfillMissingFileSizes();
        expect(summary['updated'], 1);
        expect(summary['skipped'], 2);
        expect(summary['errors'], 0);

        final realRow = await imagesDao.getImageById(realId);
        expect(realRow!.fileSize, 1500);
        // Missing/empty rows still null.
        expect((await imagesDao.getImageById(missingId))!.fileSize, isNull);
        expect((await imagesDao.getImageById(emptyId))!.fileSize, isNull);
      },
    );

    test('returns zeros when no rows need backfilling', () async {
      final summary = await imagesDao.backfillMissingFileSizes();
      expect(summary['updated'], 0);
      expect(summary['skipped'], 0);
      expect(summary['errors'], 0);
    });
  });
}
