// Pillar B ("First Light") — the difference scan and the Pillar A atlas fold
// must centre on the SAME sky for the same `captured_images` row.
//
// `captured_images.solved_ra` is app-canonical HOURS on both the write side
// (the science pipeline persists `SolvedResult.raHours`) and every read side —
// `SkyAtlasService` carries the same column straight across. A scan WCS built
// with `raHours: image.solvedRa / 15.0` therefore differences each frame
// against the tile at 1/15 of its true RA (a frame at 20h scanned as if it were
// at 1h20m), so the search finds nothing or garbage — silently, the whole chain
// being fire-and-forget.
//
// The invariant is structural: the scan centre and the fold centre derive from
// one column, so they agree by construction. The fold centre is read back off
// the real atlas seam args rather than recomputed, so a drift in either
// derivation flips the assertion.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as dbm;
import 'package:skotiq_core/src/services/imaging_records_repository.dart'
    show firstLightScanWcs;

/// Atlas fold seam that records the frame WCS the fold was dispatched with.
class _RecordingFoldSeam implements SkyAtlasSeam {
  final List<Map<String, dynamic>> foldedFrameWcs = [];

  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async {
    if (args['action'] != 'fold') return {'ok': true};
    for (final frame in (args['frames'] as List).cast<Map<String, dynamic>>()) {
      foldedFrameWcs.add((frame['wcs'] as Map).cast<String, dynamic>());
    }
    return {
      'ok': true,
      'tilesTouched': const [7],
      'foldsByTile': const [
        {
          'tileId': 7,
          'channels': 1,
          'centerRa': 83.66,
          'centerDec': -5.39,
          'coverageMean': 1.0,
          'totalFrames': 1,
          'integrationSeconds': 300.0,
          'framesAdded': 1,
          'weightAdded': 1.0,
          'rejected': 0,
        },
      ],
      'framesSkippedNoCoverage': 0,
    };
  }

  @override
  Future<Map<String, dynamic>> queryCutout(Map<String, dynamic> args) async => {
    'ok': true,
  };
  @override
  Future<Map<String, dynamic>> regionInfo(Map<String, dynamic> args) async => {
    'ok': true,
  };
  @override
  Future<Map<String, dynamic>> growth(Map<String, dynamic> args) async => {
    'ok': true,
  };
  @override
  Future<Map<String, dynamic>> mergeDelta(Map<String, dynamic> args) async => {
    'ok': true,
  };
}

void main() {
  late SkotiqDatabase db;
  late ImagesDao imagesDao;
  late _RecordingFoldSeam foldSeam;
  late SkyAtlasService atlasService;

  // M42 in the app-canonical unit for `captured_images.solved_ra`: HOURS.
  const solvedRaHours = 5.5773;
  const solvedDecDeg = -5.39;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = ImagesDao(db);
    foldSeam = _RecordingFoldSeam();
    atlasService = SkyAtlasService(
      dao: SkyAtlasDao(db),
      seam: foldSeam,
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/first_light_scan_centre_test',
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<dbm.CapturedImage> seedSolvedLight() async {
    final id = await imagesDao.createImage(
      CapturedImagesCompanion.insert(
        filePath: '/tmp/light_0001.fits',
        fileName: 'light_0001.fits',
        frameType: const Value('light'),
        exposureDuration: 300.0,
        capturedAt: DateTime.utc(2026, 1, 20, 22),
        isPlateSolved: const Value(true),
        solvedRa: const Value(solvedRaHours),
        solvedDec: const Value(solvedDecDeg),
        solvedPixelScale: const Value(1.5),
        solvedRotation: const Value(0.0),
      ),
    );
    return (await imagesDao.getImageById(id))!;
  }

  test(
    'the First Light scan centre is the persisted solved RA in hours',
    () async {
      final image = await seedSolvedLight();

      final wcs = firstLightScanWcs(
        image: image,
        imageWidth: 1000,
        imageHeight: 800,
        distortion: const SolvedWcsDistortion(),
      );

      expect(
        wcs.raHours,
        closeTo(solvedRaHours, 1e-9),
        reason:
            'captured_images.solved_ra is already hours; converting again puts '
            'the scan 1/15 of the way round the sky',
      );
      expect(wcs.decDegrees, closeTo(solvedDecDeg, 1e-9));
    },
  );

  test('the First Light scan centre matches the atlas fold centre for the '
      'same row', () async {
    final image = await seedSolvedLight();

    final scanWcs = firstLightScanWcs(
      image: image,
      imageWidth: 1000,
      imageHeight: 800,
      distortion: const SolvedWcsDistortion(),
    );

    await atlasService.autoFoldCapturedImage(
      image: image,
      imageWidth: 1000,
      imageHeight: 800,
    );

    expect(foldSeam.foldedFrameWcs, hasLength(1));
    final foldCentreRaDeg = foldSeam.foldedFrameWcs.single['crval1'] as double;
    final foldCentreDecDeg = foldSeam.foldedFrameWcs.single['crval2'] as double;

    expect(
      scanWcs.raHours * 15.0,
      closeTo(foldCentreRaDeg, 1e-6),
      reason:
          'the difference template is read from the same per-tile sidecars the '
          'fold writes; a scan centred elsewhere differences the wrong sky',
    );
    expect(scanWcs.decDegrees, closeTo(foldCentreDecDeg, 1e-9));
  });
}
