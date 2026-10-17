// Which sessions actually carry a science product.
//
// "Newest session holding LIGHT frames" is a different question: two test
// frames shot after a 120-frame photometry night are lights, so a Science tab
// opening on them reports "0 of 2 solved" and its never-started empty state
// while the night of real measurements sits one row down in a dropdown.

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  Future<int> addFrame({
    required int sessionId,
    required String name,
    bool solved = false,
  }) {
    return db.imagesDao.createImage(
      CapturedImagesCompanion.insert(
        filePath: '/tmp/$name',
        fileName: name,
        exposureDuration: 120,
        capturedAt: DateTime.utc(2026, 8, 1, 22),
        sessionId: drift.Value(sessionId),
        frameType: const drift.Value('light'),
        isPlateSolved: drift.Value(solved),
      ),
    );
  }

  test('a session of unsolved lights carries no science product', () async {
    final session = await db.sessionsDao.startSession(name: 'Test frames');
    await addFrame(sessionId: session, name: 'a.fits');

    expect(await db.imagesDao.getSessionIdsWithSolvedFrames(), isEmpty);
    expect(await db.scienceDao.getSessionIdsWithPhotometry(), isEmpty);
    expect(
      await db.imagesDao.getLatestSessionIdWithLightFrames(),
      session,
      reason:
          'it does hold lights — which is exactly why that query is the '
          'wrong one to pick the Science tab default with',
    );
  });

  test('a plate-solved frame marks its session', () async {
    // Only one session may be active at a time, so close each before the next.
    final barren = await db.sessionsDao.startSession(name: 'Test frames');
    await db.sessionsDao.endSession(barren);
    final real = await db.sessionsDao.startSession(name: 'Photometry night');
    await db.sessionsDao.endSession(real);
    await addFrame(sessionId: barren, name: 'a.fits');
    await addFrame(sessionId: real, name: 'b.fits', solved: true);
    await addFrame(sessionId: real, name: 'c.fits', solved: true);

    expect(await db.imagesDao.getSessionIdsWithSolvedFrames(), {real});
  });

  test('a photometry measurement marks its session', () async {
    final barren = await db.sessionsDao.startSession(name: 'Test frames');
    await db.sessionsDao.endSession(barren);
    final real = await db.sessionsDao.startSession(name: 'Photometry night');
    await db.sessionsDao.endSession(real);
    final imageId = await addFrame(sessionId: real, name: 'b.fits');
    await addFrame(sessionId: barren, name: 'a.fits');

    await db.scienceDao.insertPhotometryMeasurements([
      PhotometryMeasurementsCompanion.insert(
        capturedImageId: drift.Value(imageId),
        sessionId: drift.Value(real),
        objectId: 'V* SS Cyg',
        x: 100,
        y: 100,
        flux: 5000,
      ),
    ]);

    expect(await db.scienceDao.getSessionIdsWithPhotometry(), {real});
    expect(
      await db.imagesDao.getSessionIdsWithSolvedFrames(),
      isEmpty,
      reason: 'photometry without a solve still counts as a science product',
    );
  });
}
