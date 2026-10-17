import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/database.dart';

/// Batched read of the v50 raw-DDL `fwhm` column for a whole session. Exporters
/// hold `List<DbCapturedImage>`, which cannot see that column at all, so this is
/// the only way for them to report a MEASURED FWHM instead of deriving one.
void main() {
  late SkotiqDatabase db;
  late ImagesDao imagesDao;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = ImagesDao(db);
    // captured_images.session_id is a real FK.
    for (final id in [1, 2, 3]) {
      await db
          .into(db.imagingSessions)
          .insert(
            ImagingSessionsCompanion.insert(
              id: Value(id),
              startTime: DateTime.utc(2026, 8, 1, 21),
            ),
          );
    }
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> frame(String name, int sessionId) =>
      imagesDao.insertSequenceFrame(
        filePath: '/captures/m31/$name',
        fileName: name,
        fileFormat: 'fits',
        exposureDuration: 120.0,
        capturedAt: DateTime.utc(2026, 8, 1, 22),
        isAccepted: true,
        producingNodeId: 'node-a',
        sessionId: sessionId,
      );

  test('returns only the frames of the session that were measured', () async {
    final measured = await frame('L_0001.fits', 1);
    final unmeasured = await frame('L_0002.fits', 1);
    final otherNight = await frame('L_0003.fits', 2);

    await imagesDao.stampProducingNode(imageId: measured, fwhm: 3.90);
    await imagesDao.stampProducingNode(imageId: otherNight, fwhm: 4.10);

    final byId = await imagesDao.getFwhmForSession(1);

    expect(byId[measured], closeTo(3.90, 1e-9));
    expect(byId.containsKey(unmeasured), isFalse);
    expect(byId.containsKey(otherNight), isFalse);
    expect(byId, hasLength(1));
  });

  test('a session with nothing measured returns an empty map', () async {
    await frame('L_0004.fits', 3);
    expect(await imagesDao.getFwhmForSession(3), isEmpty);
  });
}
