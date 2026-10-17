// Pillar A ("Your Sky") — Wave 0 fold dedup at the solve-persist hook.
//
// A re-solved frame fires the SolvedFrameFoldHook a SECOND time for the same
// capturedImageId (a duplicate inbound `updateCapturedImage{isPlateSolved:true}`
// is plausible in the master/slave sync architecture). Without a dedup marker
// the second fire double-counts that frame's photons into the atlas.
//
// The production guard is `applyAtlasFoldDedup` in imaging_records_repository.dart
// (the SAME function the local solve-persist hook calls): only fold when
// `image.atlasFoldedAt == null`, then `stampAtlasFolded(id)` after a fold that
// actually ran. This test drives that REAL gate against the REAL ImagesDao +
// SkyAtlasService.autoFoldCapturedImage and proves:
//   * autoFoldCapturedImage dispatches a native fold exactly ONCE across two
//     hook fires for the same row,
//   * the tile's own-light totalFrames counts the frame once (no double-count),
//   * atlasFoldedAt is stamped after the first fold.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Seam that returns a one-frame fold result so a fold increments the tile total
/// by exactly one. Records every `fold` dispatch so the test can assert it ran
/// once, not twice.
class _CountingFoldSeam implements SkyAtlasSeam {
  int foldDispatches = 0;
  int _tileFrames = 0;

  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async {
    if (args['action'] != 'fold') return {'ok': true};
    foldDispatches++;
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

void main() {
  late SkotiqDatabase db;
  late ImagesDao imagesDao;
  late SkyAtlasDao atlasDao;
  late _CountingFoldSeam seam;
  late SkyAtlasService service;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = ImagesDao(db);
    atlasDao = SkyAtlasDao(db);
    seam = _CountingFoldSeam();
    service = SkyAtlasService(
      dao: atlasDao,
      seam: seam,
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/fold_dedup_test',
    );
  });

  tearDown(() async {
    await db.close();
  });

  /// Fetch the current row and run it through the REAL production gate
  /// ([applyAtlasFoldDedup]) — NOT a re-implementation. The fetch is incidental
  /// (the solve hook does the same); the dedup decision + stamp under test all
  /// live inside the production function.
  Future<AtlasFoldSummary?> foldHookGate(int capturedImageId) async {
    final image = await imagesDao.getImageById(capturedImageId);
    if (image == null) return null;
    return applyAtlasFoldDedup(
      image: image,
      imagesDao: imagesDao,
      atlas: service,
      imageWidth: 1000,
      imageHeight: 800,
    );
  }

  Future<int> insertSolvedLight() {
    return imagesDao.createImage(
      CapturedImagesCompanion.insert(
        filePath: '/tmp/light_0001.fits',
        fileName: 'light_0001.fits',
        frameType: const Value('light'),
        exposureDuration: 300.0,
        capturedAt: DateTime.utc(2026, 6, 11, 22),
        isPlateSolved: const Value(true),
        solvedRa: const Value(83.6),
        solvedDec: const Value(-5.39),
        solvedPixelScale: const Value(1.5),
        solvedRotation: const Value(0.0),
      ),
    );
  }

  test(
    'A-resolve-double-fold-dedup: re-solving the same frame folds it ONCE',
    () async {
      final id = await insertSolvedLight();

      // First solve fires the hook: a fold runs, the frame is counted, and the
      // dedup marker is stamped.
      final first = await foldHookGate(id);
      expect(first, isNotNull, reason: 'first fire folds the solved light');
      expect(seam.foldDispatches, 1);

      final afterFirst = await imagesDao.getImageById(id);
      expect(
        afterFirst!.atlasFoldedAt,
        isNotNull,
        reason: 'atlasFoldedAt stamped after the first fold',
      );

      // A re-solve fires the SAME capturedImageId again. The dedup marker must
      // short-circuit it: no second native fold, no second timeline row.
      final second = await foldHookGate(id);
      expect(second, isNull, reason: 'already-folded row is skipped');
      expect(
        seam.foldDispatches,
        1,
        reason: 'autoFoldCapturedImage runs once across two hook fires',
      );

      // The tile counts the frame exactly once — no double-counted photons.
      final tile = await atlasDao.getTile(42, healpixOrder: 9);
      expect(tile, isNotNull);
      expect(
        tile!.totalFrames,
        1,
        reason: 're-solve does not inflate the tile depth',
      );

      // The fold timeline carries one row for the frame, not two.
      final folds = await atlasDao.listFoldsForTileOverTime(42);
      expect(folds, hasLength(1));
    },
  );

  test(
    'a non-foldable solve leaves the marker UNSET so a later real solve folds',
    () async {
      // A light row with neither a CD matrix nor a positive pixel scale is not
      // foldable: autoFoldCapturedImage returns null, the marker stays null, and
      // a subsequent (now-foldable) solve of the same row still folds.
      final id = await imagesDao.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/tmp/light_0002.fits',
          fileName: 'light_0002.fits',
          frameType: const Value('light'),
          exposureDuration: 300.0,
          capturedAt: DateTime.utc(2026, 6, 11, 23),
          isPlateSolved: const Value(true),
          solvedRa: const Value(83.6),
          solvedDec: const Value(-5.39),
          solvedPixelScale: const Value(0.0), // degenerate: no fold
          solvedRotation: const Value(0.0),
        ),
      );

      final skipped = await foldHookGate(id);
      expect(skipped, isNull);
      expect(seam.foldDispatches, 0);
      final unmarked = await imagesDao.getImageById(id);
      expect(
        unmarked!.atlasFoldedAt,
        isNull,
        reason: 'a non-fold must NOT stamp the dedup marker',
      );

      // Now the row gets a usable pixel scale (a better solve) and folds.
      await imagesDao.updatePlateSolveResult(
        id,
        solvedRa: 83.6,
        solvedDec: -5.39,
        solvedRotation: 0.0,
        solvedPixelScale: 1.5,
      );
      final folded = await foldHookGate(id);
      expect(folded, isNotNull, reason: 'a now-foldable solve folds');
      expect(seam.foldDispatches, 1);
      final marked = await imagesDao.getImageById(id);
      expect(marked!.atlasFoldedAt, isNotNull);
    },
  );
}
