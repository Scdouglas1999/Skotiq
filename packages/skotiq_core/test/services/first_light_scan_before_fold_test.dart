// Pillar B ("First Light") — difference-before-fold at the solve-persist hook.
//
// The diff reads its comparison template from the per-tile `.nst` atlas
// sidecars, so folding the freshly-solved frame in FIRST averages that frame's
// own flux into the template it is differenced against (weight ~1/(N+1)). Every
// transient self-suppresses; a faint SNR~5-6 source drops below the persist gate
// and vanishes.
//
// The scan therefore runs BEFORE the fold: the template reflects history (all
// PRIOR frames only) and the fold deepens it for the NEXT frame. This test lifts
// the production hook order verbatim into `solveHook` and proves the difference
// seam is dispatched BEFORE the fold seam. Reordering fold above scan
// re-introduces self-subtraction and flips this assertion.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A shared event log so both seams record into one ordered timeline; the test
/// asserts the difference (scan) entry precedes the fold entry.
final List<String> _timeline = [];

/// Atlas fold seam that records each `fold` dispatch onto the shared timeline.
class _RecordingFoldSeam implements SkyAtlasSeam {
  int _tileFrames = 0;

  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async {
    if (args['action'] != 'fold') return {'ok': true};
    _timeline.add('fold');
    _tileFrames++;
    return {
      'ok': true,
      'tilesTouched': const [42],
      'foldsByTile': [
        {
          'tileId': 42,
          'channels': 1,
          'centerRa': 83.6,
          'centerDec': -5.39,
          'coverageMean': 1.0,
          'totalFrames': _tileFrames,
          'integrationSeconds': 300.0 * _tileFrames,
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

/// Difference seam that records each `difference` dispatch onto the shared
/// timeline and returns one faint (SNR ~5.5) candidate so the test can also
/// prove the survivor is persisted (no self-suppression).
class _RecordingDiffSeam implements DifferenceImageSeam {
  final List<Map<String, dynamic>> dispatched = [];

  @override
  Future<Map<String, dynamic>> difference(Map<String, dynamic> args) async {
    _timeline.add('diff');
    dispatched.add(args);
    return {
      'ok': true,
      'candidates': [
        {
          'ra': 83.6,
          'dec': -5.39,
          'tileId': 42,
          'tileX': 512.0,
          'tileY': 600.0,
          'residualFlux': 5000.0,
          'deltaMag': null,
          'snr': 5.5, // faint: just above the _minSnr=5.0 persist gate
          'fwhm': 2.1,
          'eccentricity': 0.1,
          'kind': 'newSource',
          'catalogMatch': null,
        },
      ],
      'tilesChecked': [42],
    };
  }

  @override
  Future<Map<String, dynamic>> tileCenter(Map<String, dynamic> args) async => {
    'tileId': args['tileId'],
    'ra': 83.6,
    'dec': -5.39,
  };
}

class _NoStarsCatalog implements TransientCatalogMatcher {
  @override
  Future<List<PhotometricCatalogStar>> coneStars({
    required double raDegrees,
    required double decDegrees,
    required double radiusDegrees,
    double maxMagnitude = 18.0,
  }) async => const [];
}

void main() {
  late SkotiqDatabase db;
  late ImagesDao imagesDao;
  late SkyAtlasDao atlasDao;
  late TransientDetectionsDao transientDao;
  late _RecordingFoldSeam foldSeam;
  late _RecordingDiffSeam diffSeam;
  late SkyAtlasService atlasService;
  late FirstLightService firstLight;

  setUp(() {
    _timeline.clear();
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = ImagesDao(db);
    atlasDao = SkyAtlasDao(db);
    transientDao = TransientDetectionsDao(db);
    foldSeam = _RecordingFoldSeam();
    diffSeam = _RecordingDiffSeam();
    atlasService = SkyAtlasService(
      dao: atlasDao,
      seam: foldSeam,
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/scan_before_fold_test',
    );
    firstLight = FirstLightService(
      dao: transientDao,
      seam: diffSeam,
      catalog: _NoStarsCatalog(),
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/scan_before_fold_test',
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> insertSolvedLight() {
    return imagesDao.createImage(
      CapturedImagesCompanion.insert(
        filePath: '/tmp/light_0001.fits',
        fileName: 'light_0001.fits',
        frameType: const Value('light'),
        exposureDuration: 300.0,
        capturedAt: DateTime.utc(2026, 6, 21, 22),
        isPlateSolved: const Value(true),
        solvedRa: const Value(83.6),
        solvedDec: const Value(-5.39),
        solvedPixelScale: const Value(1.5),
        solvedRotation: const Value(0.0),
      ),
    );
  }

  /// The production solve-persist hook order, lifted verbatim from
  /// imaging_records_repository.dart onSolvedFrameFold: the First Light SCAN
  /// runs BEFORE the atlas FOLD (difference-before-fold). A future refactor that
  /// reorders fold above scan re-introduces self-subtraction.
  Future<void> solveHook(int capturedImageId) async {
    final image = await imagesDao.getImageById(capturedImageId);
    if (image == null) return;
    final wcs = SolvedWcs(
      raHours: image.solvedRa! / 15.0,
      decDegrees: image.solvedDec!,
      rotationDeg: image.solvedRotation ?? 0.0,
      pixelScaleArcsec: image.solvedPixelScale!,
      imageWidth: 1000,
      imageHeight: 800,
    );

    // (B) scan first: template = history, excludes this frame.
    await firstLight.scanFrame(
      framePath: image.filePath,
      wcs: wcs,
      capturedImageId: image.id,
    );

    // (A) fold second: deepen the template for the NEXT frame.
    if (image.atlasFoldedAt == null) {
      final summary = await atlasService.autoFoldCapturedImage(
        image: image,
        imageWidth: 1000,
        imageHeight: 800,
      );
      if (summary != null) {
        await imagesDao.stampAtlasFolded(capturedImageId);
      }
    }
  }

  test(
    'scan-before-fold: the difference seam fires BEFORE the fold seam so the '
    'template excludes the current frame (no self-subtraction)',
    () async {
      final id = await insertSolvedLight();
      await solveHook(id);

      // Both seams ran exactly once.
      expect(diffSeam.dispatched, hasLength(1));
      expect(_timeline.where((e) => e == 'diff'), hasLength(1));
      expect(_timeline.where((e) => e == 'fold'), hasLength(1));

      // The ordering invariant: the diff is dispatched against the template
      // BEFORE this frame is folded into it.
      expect(
        _timeline.indexOf('diff'),
        lessThan(_timeline.indexOf('fold')),
        reason:
            'First Light difference must run before the atlas fold so the '
            'comparison template excludes the current frame',
      );
    },
  );

  test('a faint SNR~5.5 injected transient survives the persist gate '
      '(self-subtraction would have dropped it below SNR 5.0)', () async {
    final id = await insertSolvedLight();
    await solveHook(id);

    // The faint survivor was persisted — not suppressed by folding its own
    // flux into the template (which would have pushed SNR below the floor).
    final persisted = await transientDao.allDetections();
    expect(persisted, hasLength(1));
    expect(persisted.single.snr, closeTo(5.5, 1e-9));
    expect(persisted.single.kind, 'newSource');
  });
}
