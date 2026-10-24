// A solve that arrives after a frame was recorded lands on that frame's row,
// in the row's units, and only a successful one is written.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late SkotiqDatabase db;

  setUp(() => db = SkotiqDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> insert(String path) => db.imagesDao.insertSequenceFrame(
    filePath: path,
    fileName: path.split('/').last,
    fileFormat: 'fits',
    exposureDuration: 120,
    capturedAt: DateTime.utc(2026, 10, 24, 5),
    isAccepted: true,
    producingNodeId: 'lights',
  );

  test('writes RA in hours and the CD matrix when the solve has one', () async {
    final id = await insert('/c/B_0086.fits');
    final written = await writeFrameSolveToRow(
      db.imagesDao,
      '/c/B_0086.fits',
      raDegrees: 35.64,
      decDegrees: 42.35,
      rotationDegrees: 181.2,
      pixelScaleArcsec: 1.12,
      cd1_1: -3.1e-4,
      cd1_2: 1e-6,
      cd2_1: 1e-6,
      cd2_2: 3.1e-4,
    );
    expect(written, isTrue);
    final row = (await db.imagesDao.getImageById(id))!;
    expect(row.isPlateSolved, isTrue);
    expect(row.solvedRa, closeTo(35.64 / 15, 1e-12));
    expect(row.solvedRotation, closeTo(181.2, 1e-12));
    final wcs = (await db.imagesDao.getStoredWcsDistortion(id))!;
    expect(wcs.cd1_1, closeTo(-3.1e-4, 1e-15));
  });

  test('an unusable solve or an unknown path writes nothing', () async {
    final id = await insert('/c/B_0087.fits');
    expect(
      await writeFrameSolveToRow(
        db.imagesDao,
        '/c/B_0087.fits',
        raDegrees: double.nan,
        decDegrees: 0,
        rotationDegrees: 0,
        pixelScaleArcsec: 1.1,
      ),
      isFalse,
    );
    expect((await db.imagesDao.getImageById(id))!.isPlateSolved, isFalse);
    expect(
      await writeFrameSolveToRow(
        db.imagesDao,
        '/c/missing.fits',
        raDegrees: 10,
        decDegrees: 0,
        rotationDegrees: 0,
        pixelScaleArcsec: 1.1,
      ),
      isFalse,
    );
  });

  test('settled waits for the row insert tracked for a path', () async {
    final tracker = FrameRegistrationTracker();
    final insertDone = Completer<void>();
    tracker.track('/c/x.fits', insertDone.future);
    var settled = false;
    unawaited(tracker.settled('/c/x.fits').then((_) => settled = true));
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    insertDone.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(settled, isTrue);
    await tracker.settled('/c/other.fits');
  });
}
