// A frame a plate solver ran on and could not solve is recorded as such, so
// solve-rate statistics can tell it apart from a frame never submitted.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  late SkotiqDatabase db;
  late ImagesDao imagesDao;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = ImagesDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> insertFrame(String name) => imagesDao.insertSequenceFrame(
    filePath: '/captures/m31/$name',
    fileName: name,
    fileFormat: 'fits',
    exposureDuration: 2.0,
    capturedAt: DateTime.utc(2026, 11, 1, 16, 48),
    isAccepted: true,
    producingNodeId: 'node-solve',
  );

  test(
    'a failed solve is recorded and a never-submitted frame is not',
    () async {
      final failedId = await insertFrame('failed.fits');
      await insertFrame('never.fits');

      expect(
        await imagesDao.markPlateSolveFailed('/captures/m31/failed.fits'),
        isTrue,
      );

      expect(await imagesDao.watchPlateSolveFailedIds().first, {failedId});
    },
  );

  test(
    'a solved frame is never marked failed, and a later solve clears it',
    () async {
      final id = await insertFrame('solved.fits');
      await imagesDao.markPlateSolveFailed('/captures/m31/solved.fits');
      await imagesDao.updatePlateSolveResult(
        id,
        solvedRa: 0.7,
        solvedDec: 41.3,
        solvedRotation: 0,
        solvedPixelScale: 1.46,
      );

      expect(await imagesDao.watchPlateSolveFailedIds().first, isEmpty);
      expect(
        await imagesDao.markPlateSolveFailed('/captures/m31/solved.fits'),
        isFalse,
      );
    },
  );
}
