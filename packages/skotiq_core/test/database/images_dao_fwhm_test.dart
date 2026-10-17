import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/database.dart';

/// Persisted-FWHM round-trip for the v50 raw-DDL `fwhm` column on
/// `captured_images`. Exercised through the documented APIs:
///   * [ImagesDao.stampProducingNode] — writes the measured FWHM.
///   * [ImagesDao.getFwhm]             — single-row read used by the grader.
///   * [ImagesDao.getImagesByProducingNode] — thumbnail-strip projection.
///
/// Each test runs on a fresh in-memory database.
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

  test('stamps and reads back a measured fwhm', () async {
    final id = await imagesDao.insertSequenceFrame(
      filePath: '/captures/m31/L_0001.fits',
      fileName: 'L_0001.fits',
      fileFormat: 'fits',
      exposureDuration: 120.0,
      capturedAt: DateTime.utc(2026, 1, 1, 22, 15, 0),
      isAccepted: true,
      producingNodeId: 'node-fwhm',
      runtimeGrade: 'pass',
      filter: 'L',
    );
    await imagesDao.stampProducingNode(
      imageId: id,
      eccentricity: 0.28,
      fwhm: 2.45,
    );

    expect(await imagesDao.getFwhm(id), closeTo(2.45, 1e-9));

    final rows = await imagesDao.getImagesByProducingNode(
      producingNodeId: 'node-fwhm',
    );
    expect(rows.single.fwhm, closeTo(2.45, 1e-9));
    expect(rows.single.eccentricity, closeTo(0.28, 1e-9));
  });

  test('fwhm is null when never stamped', () async {
    final id = await imagesDao.insertSequenceFrame(
      filePath: '/captures/m31/L_0002.fits',
      fileName: 'L_0002.fits',
      fileFormat: 'fits',
      exposureDuration: 60.0,
      capturedAt: DateTime.utc(2026, 1, 1, 22, 16, 0),
      isAccepted: true,
      producingNodeId: 'node-null',
    );

    expect(await imagesDao.getFwhm(id), isNull);

    final rows = await imagesDao.getImagesByProducingNode(
      producingNodeId: 'node-null',
    );
    expect(rows.single.fwhm, isNull);
  });

  test('stamping other fields leaves fwhm untouched', () async {
    final id = await imagesDao.insertSequenceFrame(
      filePath: '/captures/m31/L_0003.fits',
      fileName: 'L_0003.fits',
      fileFormat: 'fits',
      exposureDuration: 60.0,
      capturedAt: DateTime.utc(2026, 1, 1, 22, 17, 0),
      isAccepted: true,
      producingNodeId: 'node-keep',
    );
    await imagesDao.stampProducingNode(imageId: id, fwhm: 1.9);
    await imagesDao.stampProducingNode(imageId: id, runtimeGrade: 'pass');

    expect(await imagesDao.getFwhm(id), closeTo(1.9, 1e-9));
  });
}
