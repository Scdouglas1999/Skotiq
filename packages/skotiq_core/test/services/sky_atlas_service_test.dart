import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;

/// A recording fake [SkyAtlasSeam] that returns canned bridge results so the
/// service body (fold persistence, region bookkeeping) runs without native code.
class _FakeSkyAtlasSeam implements SkyAtlasSeam {
  final List<Map<String, dynamic>> dispatched = [];
  Map<String, dynamic> Function(Map<String, dynamic>)? onDispatch;

  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async {
    dispatched.add(args);
    final handler = onDispatch;
    if (handler != null) return handler(args);
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> queryCutout(Map<String, dynamic> args) async => {
    'ok': true,
    // Echo the paths the service handed in (the native side writes here),
    // mirroring the real bridge's contract.
    'fitsPath': args['fitsPath'] ?? '/tmp/cutout.fits',
    'pngPath': '/tmp/cutout.png',
    'coveredFraction': 0.9,
  };

  @override
  Future<Map<String, dynamic>> regionInfo(Map<String, dynamic> args) async => {
    'ok': true,
    'tilesWithData': 1,
  };

  @override
  Future<Map<String, dynamic>> growth(Map<String, dynamic> args) async => {
    'ok': true,
    'points': const [],
    'totalFrames': 0,
  };

  final List<Map<String, dynamic>> merged = [];

  @override
  Future<Map<String, dynamic>> mergeDelta(Map<String, dynamic> args) async {
    merged.add(args);
    return {
      'ok': true,
      'tileId': args['tileId'] ?? 0,
      'totalFramesAfter': 42,
      'integrationSecondsAfter': 1200.0,
      'contributorsAfter': 2,
    };
  }
}

/// A seam that models a single tile's running frame total as a non-atomic
/// load -> (async gap) -> store, so an interleaving fold would lose a frame.
/// Used to prove [SkyAtlasService]'s single-flight chain serializes folds.
class _AccumulatingSkyAtlasSeam implements SkyAtlasSeam {
  int tileFrames = 0;

  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async {
    if (args['action'] != 'fold') return {'ok': true};
    // Read-modify-write with an awaited gap in the middle: without
    // serialization, two concurrent folds both read the same prior total and
    // one increment is lost.
    final prior = tileFrames;
    await Future<void>.delayed(Duration.zero);
    tileFrames = prior + 1;
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
          'totalFrames': tileFrames,
          'integrationSeconds': 300.0 * tileFrames,
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
  late SkyAtlasDao dao;
  late _FakeSkyAtlasSeam seam;
  late SkyAtlasService service;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = SkyAtlasDao(db);
    await db
        .into(db.imagingSessions)
        .insert(
          ImagingSessionsCompanion.insert(
            id: const Value(7),
            startTime: DateTime.utc(2026, 6, 11, 21),
          ),
        );
    seam = _FakeSkyAtlasSeam();
    service = SkyAtlasService(
      dao: dao,
      seam: seam,
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/test_atlas',
    );
  });

  tearDown(() async {
    await db.close();
  });

  SolvedFrameRef frame({String path = '/tmp/light_001.fits'}) {
    return SolvedFrameRef.fromSolvedWcs(
      framePath: path,
      exposureSec: 300.0,
      wcs: const SolvedWcs(
        raHours: 5.575, // ~83.6 deg
        decDegrees: -5.39,
        rotationDeg: 0.0,
        pixelScaleArcsec: 1.5,
        imageWidth: 1000,
        imageHeight: 800,
      ),
    );
  }

  test('SolvedFrameRef builds the SipWcs JSON contract keys', () {
    final json = frame().toWcsJson();
    expect(
      json.keys,
      containsAll(<String>{
        'crval1',
        'crval2',
        'crpix1',
        'crpix2',
        'cd1_1',
        'cd1_2',
        'cd2_1',
        'cd2_2',
        'aOrder',
        'bOrder',
        'aCoeffs',
        'bCoeffs',
        'apOrder',
        'bpOrder',
        'apCoeffs',
        'bpCoeffs',
      }),
    );
    // crval from RA hours -> degrees, crpix at 1-based image centre.
    expect(json['crval1'] as double, closeTo(83.625, 1e-6));
    expect(json['crpix1'] as double, closeTo(500.5, 1e-9));
    expect(json['crpix2'] as double, closeTo(400.5, 1e-9));
    // CD reconstructed from scale+rotation (cd1_1 = -scale, no rotation).
    expect(json['cd1_1'] as double, closeTo(-1.5 / 3600.0, 1e-12));
  });

  test('a fold publishes its tile index atomically', () async {
    seam.onDispatch = (args) => {
      'ok': true,
      'tilesTouched': [for (var i = 0; i < 80; i++) i],
      'foldsByTile': [
        for (var i = 0; i < 80; i++)
          {
            'tileId': i,
            'framesAdded': 1,
            'weightAdded': 1.0,
            'rejected': 0,
            'coverageMean': 1.0,
            'centerRa': 83.6,
            'centerDec': -5.39,
            'totalFrames': 1,
            'integrationSeconds': 300.0,
            'channels': 1,
          },
      ],
      'framesSkippedNoCoverage': 0,
    };
    final counts = <int>[];
    final subscription = dao.watchAllTiles().listen(
      (tiles) => counts.add(tiles.length),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final timer = Stopwatch()..start();
    await service.foldSession(sessionId: 7, frames: [frame()], label: 'atomic');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await subscription.cancel();
    print(
      '80-tile persistence: ${timer.elapsedMilliseconds} ms; ${counts.length} index emissions',
    );
    expect(counts, [0, 80]);
    expect((await dao.atlasTotals()).frames, 1);
  });

  test('foldSession dispatches a fold and persists tiles + timeline', () async {
    seam.onDispatch = (args) => {
      'ok': true,
      'tilesTouched': [42],
      'foldsByTile': [
        {
          'tileId': 42,
          'framesAdded': 1,
          'weightAdded': 1.0,
          'rejected': 0,
          'coverageMean': 1.0,
          'centerRa': 83.6,
          'centerDec': -5.39,
          'totalFrames': 1,
          'integrationSeconds': 300.0,
          'channels': 1,
        },
      ],
      'framesSkippedNoCoverage': 0,
    };

    final summary = await service.foldSession(
      sessionId: 7,
      frames: [frame()],
      label: '2026-06-11',
    );

    expect(summary.tilesTouched, [42]);
    expect(summary.totalFramesFolded, 1);
    expect(seam.dispatched.single['action'], 'fold');

    final tile = await dao.getTile(42);
    expect(tile, isNotNull);
    expect(tile!.totalFrames, 1);
    expect(tile.integrationSeconds, 300.0);
    expect(tile.lastFoldSessionId, 7);

    final folds = await dao.listFoldsForTileOverTime(42);
    expect(folds, hasLength(1));
    expect(folds.single.label, '2026-06-11');
    expect(folds.single.framesAdded, 1);
  });

  test(
    'foldSession counts every unlabeled frame in a shared-label batch',
    () async {
      seam.onDispatch = (args) {
        final frames = args['frames'] as List;
        return {
          'ok': true,
          'tilesTouched': [42],
          'foldsByTile': [
            {
              'tileId': 42,
              'framesAdded': frames.length,
              'weightAdded': 2.0,
              'rejected': 0,
              'coverageMean': 2.0,
              'centerRa': 83.6,
              'centerDec': -5.39,
              'totalFrames': 2,
              'integrationSeconds': 600.0,
              'channels': 1,
            },
          ],
          'frameFolds': [
            for (var i = 0; i < frames.length; i++)
              {
                'frameIndex': i,
                'label': frames[i]['label'],
                'tileId': 42,
                'weightAdded': 1.0,
                'integrationSecondsAdded': 300.0,
                'coverageAdded': 1.0,
                'rejected': 0,
              },
          ],
          'framesSkippedNoCoverage': 0,
        };
      };
      await service.foldSession(
        sessionId: 7,
        frames: [
          frame(path: '/night/L_001.fits'),
          frame(path: '/night/L_002.fits'),
        ],
        label: '2026-06-11',
      );
      final totals = await dao.atlasTotals();
      expect(totals.frames, 2);
      expect(totals.seconds, 600);
      final tile = await dao.getTile(42);
      expect(tile!.totalFrames, 2);
      expect(tile.integrationSeconds, 600);
      final folds = await dao.listFoldsForTileOverTime(42);
      expect(folds.map((f) => f.label).toSet(), hasLength(2));
      expect(folds.every((f) => f.label.startsWith('2026-06-11')), isTrue);
      for (final fold in folds) {
        expect(
          AtlasGrowthPoint(
            label: fold.label,
            cumulativeFrames: 2,
            framesAdded: 1,
            secondsAdded: 300,
            cumulativeSeconds: 600,
            contributor: '',
          ).date,
          DateTime(2026, 6, 11),
        );
      }
    },
  );

  test('foldSession drops degenerate-WCS frames before dispatch', () async {
    const bad = SolvedFrameRef(
      framePath: '/tmp/bad.fits',
      crval1: 0,
      crval2: 0,
      crpix1: 0,
      crpix2: 0,
      cd1_1: 0,
      cd1_2: 0,
      cd2_1: 0,
      cd2_2: 0,
    );
    final summary = await service.foldSession(sessionId: 7, frames: [bad]);
    expect(summary.tilesTouched, isEmpty);
    expect(seam.dispatched, isEmpty, reason: 'no usable frames -> no dispatch');
  });

  test('ensureRegion upserts a region and refreshes rollups', () async {
    final id = await service.ensureRegion(
      name: 'Orion',
      centerRaDeg: 83.6,
      centerDecDeg: -5.39,
      radiusDeg: 1.0,
      kind: 'custom',
    );
    final regions = await service.regions();
    expect(regions.where((r) => r.id == id), hasLength(1));
    expect(regions.firstWhere((r) => r.id == id).name, 'Orion');
  });

  test('ensureRegion rejects impossible coordinates before writing', () async {
    for (final values in [
      (ra: double.nan, dec: 0.0, radius: 1.0),
      (ra: 361.0, dec: 0.0, radius: 1.0),
      (ra: 10.0, dec: -91.0, radius: 1.0),
      (ra: 10.0, dec: 20.0, radius: 0.0),
      (ra: 10.0, dec: 20.0, radius: 181.0),
    ]) {
      await expectLater(
        service.ensureRegion(
          name: 'Invalid',
          centerRaDeg: values.ra,
          centerDecDeg: values.dec,
          radiusDeg: values.radius,
        ),
        throwsRangeError,
      );
    }
    expect(await service.regions(), isEmpty);
  });

  test(
    'autoFoldCapturedImage creates + attaches a region from the target',
    () async {
      // A captured-image solve carries a targetId; with a resolver wired the
      // auto-fold must ensure ONE region named after the target and link the
      // folded tile to it — the unlock that makes the region UX reachable.
      seam.onDispatch = (args) {
        if (args['action'] == 'fold') {
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
        return {'ok': true};
      };

      // The region FK references a real target row.
      await db
          .into(db.targets)
          .insert(
            TargetsCompanion.insert(
              id: const Value(11),
              name: 'Orion Nebula',
              ra: 5.575,
              dec: -5.39,
            ),
          );

      var resolveCalls = 0;
      final withResolver = SkyAtlasService(
        dao: dao,
        seam: seam,
        logger: LoggingService(),
        atlasRootResolver: () async => '/tmp/test_atlas',
        targetResolver: (targetId) async {
          resolveCalls++;
          return const AtlasTargetRef(
            name: 'Orion Nebula',
            raDeg: 83.6,
            decDeg: -5.39,
          );
        },
      );

      DbCapturedImage image(int id) => DbCapturedImage(
        id: id,
        filePath: '/tmp/light_$id.fits',
        fileName: 'light_$id.fits',
        fileFormat: 'fits',
        frameType: 'light',
        exposureDuration: 300.0,
        binX: 1,
        binY: 1,
        targetId: 11,
        isPlateSolved: true,
        solvedRa: 5.575,
        solvedDec: -5.39,
        solvedPixelScale: 1.5,
        capturedAt: DateTime.utc(2026, 6, 11, 22),
        createdAt: DateTime.utc(2026, 6, 11, 22),
        isAccepted: true,
      );

      final summary = await withResolver.autoFoldCapturedImage(
        image: image(1),
        imageWidth: 1000,
        imageHeight: 800,
      );
      expect(summary, isNotNull);
      expect(resolveCalls, 1);

      final regions = await dao.getAllRegions();
      expect(regions, hasLength(1));
      final region = regions.single;
      expect(region.name, 'Orion Nebula');
      expect(region.kind, 'target');
      expect(region.targetId, 11);
      expect(region.centerRaDeg, closeTo(83.6, 1e-6));

      // The folded tile is linked to the region + rollups reflect it.
      final tile = await dao.getTile(42, healpixOrder: 9);
      expect(tile!.regionId, region.id);
      final refreshed = (await dao.getAllRegions()).firstWhere(
        (r) => r.id == region.id,
      );
      expect(refreshed.tileCount, 1);
      expect(refreshed.integrationSeconds, closeTo(300.0, 1e-6));

      // A second night's fold of the SAME target reuses the ONE region
      // (idempotent on targetId), never a duplicate.
      await withResolver.autoFoldCapturedImage(
        image: image(2),
        imageWidth: 1000,
        imageHeight: 800,
      );
      expect(await dao.getAllRegions(), hasLength(1));
    },
  );

  test('autoFoldCapturedImage skips non-light frames', () async {
    final image = DbCapturedImage(
      id: 1,
      filePath: '/tmp/dark.fits',
      fileName: 'dark.fits',
      fileFormat: 'fits',
      frameType: 'dark',
      exposureDuration: 300.0,
      binX: 1,
      binY: 1,
      isPlateSolved: true,
      solvedRa: 83.6,
      solvedDec: -5.39,
      capturedAt: DateTime.utc(2026, 6, 11, 22),
      createdAt: DateTime.utc(2026, 6, 11, 22),
      isAccepted: true,
    );
    final result = await service.autoFoldCapturedImage(
      image: image,
      imageWidth: 1000,
      imageHeight: 800,
    );
    expect(result, isNull);
    expect(seam.dispatched, isEmpty);
  });

  test(
    'mergeSwarmDelta writes the swarm overlay tree, not the own-light base',
    () async {
      // The `info` dispatch (read against the overlay root) supplies the
      // centre/channels used to seed a base index row for a never-imaged tile.
      seam.onDispatch = (args) {
        if (args['action'] == 'info') {
          return {
            'ok': true,
            'provenance': {
              'totalFrames': 42,
              'totalIntegrationSeconds': 1200.0,
              'contributors': const ['alice', 'bob'],
              'folds': const [],
            },
            'centerRa': 83.6,
            'centerDec': -5.39,
            'channels': 1,
            'coverageMean': 12.5,
          };
        }
        return {'ok': true};
      };

      final overlayFrames = await service.mergeSwarmDelta(
        tileId: 99,
        deltaPath: '/tmp/atlas/swarm/9/tile_99_9.skt',
      );

      // The merge targets the OVERLAY sidecar tree (separate from tiles/9), so
      // exportDelta — which only ever reads tiles/<order> — never sees it.
      expect(seam.merged, hasLength(1));
      expect(
        seam.merged.single['deltaPath'],
        '/tmp/atlas/swarm/9/tile_99_9.skt',
      );
      expect(
        seam.merged.single['basePath'],
        contains('swarm_overlay/tiles/9/99.skt'),
      );
      // The returned total is the overlay's own (community) depth.
      expect(overlayFrames, 42);

      // The base index row keeps own-light totals at zero (the user never
      // imaged this tile); the blended community depth lands in the overlay
      // columns so the contribution bar stays honest after a pull.
      final tile = await dao.getTile(99, healpixOrder: 9);
      expect(tile, isNotNull);
      expect(tile!.totalFrames, 0);
      expect(tile.integrationSeconds, 0);
      expect(tile.swarmOverlayFrames, 42);
      expect(tile.swarmOverlayIntegrationSeconds, closeTo(1200.0, 1e-9));
    },
  );

  test(
    'mergeSwarmDelta keeps own-light totals when a base row already exists',
    () async {
      // Seed a base row with own-light depth via a fold.
      seam.onDispatch = (args) {
        if (args['action'] == 'fold') {
          return {
            'ok': true,
            'tilesTouched': const [99],
            'foldsByTile': [
              {
                'tileId': 99,
                'channels': 1,
                'centerRa': 83.6,
                'centerDec': -5.39,
                'coverageMean': 4.0,
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
        return {'ok': true};
      };
      await service.foldFrame(sessionId: 7, frame: frame());

      final before = await dao.getTile(99, healpixOrder: 9);
      expect(before!.totalFrames, 1);

      await service.mergeSwarmDelta(
        tileId: 99,
        deltaPath: '/tmp/atlas/swarm/9/tile_99_9.skt',
      );

      // Own-light totals + base sidecar pointer are untouched; only the overlay
      // columns gained the community depth — no `info` seed dispatch needed.
      final after = await dao.getTile(99, healpixOrder: 9);
      expect(after!.totalFrames, 1);
      expect(after.integrationSeconds, closeTo(300.0, 1e-9));
      expect(after.sidecarPath, contains('tiles/9/99.skt'));
      expect(after.sidecarPath, isNot(contains('swarm_overlay')));
      expect(after.swarmOverlayFrames, 42);
    },
  );

  test(
    'single-flight chain serializes concurrent folds with no lost frames',
    () async {
      // A-concurrent-fold-no-loss: fire N folds at the same tile concurrently.
      // The accumulating seam models a non-atomic read-modify-write; only the
      // SkyAtlasService _serialized chain prevents interleaving from dropping a
      // frame. The persisted base total must equal the number of folds.
      final accSeam = _AccumulatingSkyAtlasSeam();
      final accService = SkyAtlasService(
        dao: dao,
        seam: accSeam,
        logger: LoggingService(),
        atlasRootResolver: () async => '/tmp/test_atlas',
      );

      const n = 8;
      await Future.wait(
        List.generate(
          n,
          (i) => accService.foldFrame(
            sessionId: 7,
            frame: frame(path: '/tmp/light_$i.fits'),
          ),
        ),
      );

      expect(
        accSeam.tileFrames,
        n,
        reason: 'serialized read-modify-write loses no fold',
      );
      final tile = await dao.getTile(42, healpixOrder: 9);
      expect(tile, isNotNull);
      expect(
        tile!.totalFrames,
        n,
        reason: 'every concurrent fold lands in the base tile total',
      );
    },
  );

  test(
    'coverageFromIndex equals the native scan but opens no sidecars',
    () async {
      // Two folded tiles with distinct depth so the deepest-first ordering and
      // the per-tile scalars are both exercised. The fold mirrors the same
      // scalars the native scan would read back from the `.skt` sidecars into
      // the SkyTiles index row, so the indexed read must match scalar-for-scalar.
      seam.onDispatch = (args) {
        // The fold of /tmp/light_001.fits hits tile 42 (the frame() WCS);
        // build a deterministic two-tile result so both rows are indexed.
        return {
          'ok': true,
          'tilesTouched': [42, 7],
          'frameFolds': [
            for (var i = 0; i < 3; i++)
              {
                'frameIndex': i,
                'label': '2026-06-21T0$i:00:00Z',
                'tileId': 42,
                'weightAdded': 1.0,
                'integrationSecondsAdded': 300.0,
                'coverageAdded': 0.85 / 3,
                'rejected': 0,
              },
            {
              'frameIndex': 0,
              'label': '2026-06-21T00:00:00Z',
              'tileId': 7,
              'weightAdded': 1.0,
              'integrationSecondsAdded': 300.0,
              'coverageAdded': 0.4,
              'rejected': 0,
            },
          ],
          'foldsByTile': [
            {
              'tileId': 42,
              'framesAdded': 3,
              'weightAdded': 3.0,
              'rejected': 0,
              'coverageMean': 0.85,
              'centerRa': 83.6,
              'centerDec': -5.39,
              'totalFrames': 3,
              'integrationSeconds': 900.0,
              'channels': 1,
            },
            {
              'tileId': 7,
              'framesAdded': 1,
              'weightAdded': 1.0,
              'rejected': 0,
              'coverageMean': 0.4,
              'centerRa': 10.0,
              'centerDec': 41.0,
              'totalFrames': 1,
              'integrationSeconds': 300.0,
              'channels': 3,
            },
          ],
          'framesSkippedNoCoverage': 0,
        };
      };

      await service.foldSession(
        sessionId: 7,
        frames: [
          for (var i = 0; i < 3; i++)
            frame(
              path: '/tmp/light_$i.fits',
            ).withLabel('2026-06-21T0$i:00:00Z'),
        ],
        label: '2026-06-21',
      );

      // The native scan path (the prior behaviour) returns the same per-tile
      // scalars the fold persisted; model it as a coverage dispatch so we can
      // compare the indexed read against the scan-derived value.
      seam.onDispatch = (args) {
        expect(
          args['action'],
          'coverage',
          reason: 'only the native coverage scan should dispatch here',
        );
        return {
          'ok': true,
          'tiles': [
            {
              'tileId': 42,
              'centerRa': 83.6,
              'centerDec': -5.39,
              'coverageMean': 0.85,
              'totalFrames': 3,
              'integrationSeconds': 900.0,
              'channels': 1,
              'lastFoldIso': '2026-06-21',
            },
            {
              'tileId': 7,
              'centerRa': 10.0,
              'centerDec': 41.0,
              'coverageMean': 0.4,
              'totalFrames': 1,
              'integrationSeconds': 300.0,
              'channels': 3,
              'lastFoldIso': '2026-06-21',
            },
          ],
        };
      };
      final scanned = await service.coverage();
      final dispatchesAfterScan = seam.dispatched.length;

      // The indexed read must open NO sidecars: it never touches the seam.
      final indexed = await service.coverageFromIndex();
      expect(
        seam.dispatched.length,
        dispatchesAfterScan,
        reason: 'coverageFromIndex issues no native dispatch (no sidecar open)',
      );

      // Same row count + same deepest-first ordering (tile 42 then 7).
      expect(indexed.map((t) => t.tileId).toList(), [42, 7]);
      expect(scanned.map((t) => t.tileId).toList(), [42, 7]);

      // Same scalars the heat overlay / contribution bar read, per tile.
      for (var i = 0; i < scanned.length; i++) {
        expect(indexed[i].tileId, scanned[i].tileId);
        expect(indexed[i].centerRaDeg, scanned[i].centerRaDeg);
        expect(indexed[i].centerDecDeg, scanned[i].centerDecDeg);
        expect(indexed[i].coverageMean, scanned[i].coverageMean);
        expect(indexed[i].totalFrames, scanned[i].totalFrames);
        expect(indexed[i].integrationSeconds, scanned[i].integrationSeconds);
        expect(indexed[i].channels, scanned[i].channels);
      }
    },
  );

  test(
    'foldSession skips a phantom 0-frame tile (no index row, no timeline noise)',
    () async {
      // A cone that overlaps two tiles' footprints but contributes frames to
      // only ONE of them: the over-coverage tile reports framesAdded == 0.
      seam.onDispatch = (args) => {
        'ok': true,
        'tilesTouched': [42, 99],
        'foldsByTile': [
          {
            'tileId': 42,
            'framesAdded': 1,
            'weightAdded': 1.0,
            'rejected': 0,
            'coverageMean': 1.0,
            'centerRa': 83.6,
            'centerDec': -5.39,
            'totalFrames': 1,
            'integrationSeconds': 300.0,
            'channels': 1,
          },
          {
            'tileId': 99,
            'framesAdded':
                0, // phantom: footprint overlap, zero accepted frames
            'weightAdded': 0.0,
            'rejected': 0,
            'coverageMean': 0.0,
            'centerRa': 83.7,
            'centerDec': -5.40,
            'totalFrames': 0,
            'integrationSeconds': 0.0,
            'channels': 1,
          },
        ],
        'framesSkippedNoCoverage': 0,
      };

      await service.foldSession(
        sessionId: 7,
        frames: [frame()],
        label: '2026-06-11',
      );

      // The real tile persists; the phantom is NOT upserted into the index.
      expect(await dao.getTile(42), isNotNull);
      expect(
        await dao.getTile(99),
        isNull,
        reason: 'a 0-frame phantom tile must not seed a SkyTiles row',
      );
      // And it leaves no "+0 frames" entry in the timeline.
      expect(await dao.listFoldsForTileOverTime(99), isEmpty);
    },
  );

  test(
    'sweepCache evicts aged cutout/delta artefacts by age and size',
    () async {
      final root = Directory.systemTemp.createTempSync('atlas_cache_test');
      addTearDown(() => root.deleteSync(recursive: true));
      final svc = SkyAtlasService(
        dao: dao,
        seam: seam,
        logger: LoggingService(),
        atlasRootResolver: () async => root.path,
      );
      final cacheDir = Directory(p.join(root.path, 'cache'))
        ..createSync(recursive: true);

      File makeFile(String name, {required Duration age, int bytes = 16}) {
        final f = File(p.join(cacheDir.path, name))
          ..writeAsBytesSync(List<int>.filled(bytes, 0));
        final mtime = DateTime.now().subtract(age);
        f.setLastModifiedSync(mtime);
        return f;
      }

      final old = makeFile('cutout_old.png', age: const Duration(days: 30));
      final fresh = makeFile('cutout_fresh.png', age: const Duration(hours: 1));
      final delta = makeFile('delta_5.skt', age: const Duration(days: 30));
      // A non-cache file extension is never touched.
      final keep = makeFile('notes.txt', age: const Duration(days: 30));

      final deleted = await svc.sweepCache(maxAge: const Duration(days: 14));
      expect(
        deleted,
        2,
        reason: 'the two aged artefacts go; the fresh one stays',
      );
      expect(old.existsSync(), isFalse);
      expect(delta.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(keep.existsSync(), isTrue, reason: '.txt is not a cache artefact');
    },
  );

  test('deleteExportedDelta removes a spent federation payload', () async {
    final root = Directory.systemTemp.createTempSync('atlas_delta_test');
    addTearDown(() => root.deleteSync(recursive: true));
    final svc = SkyAtlasService(
      dao: dao,
      seam: seam,
      logger: LoggingService(),
      atlasRootResolver: () async => root.path,
    );
    final cacheDir = Directory(p.join(root.path, 'cache'))
      ..createSync(recursive: true);
    final delta = File(p.join(cacheDir.path, 'delta_42.skt'))
      ..writeAsBytesSync(const [0, 1, 2]);

    expect(await svc.deleteExportedDelta(42), isTrue);
    expect(delta.existsSync(), isFalse);
    // Idempotent: a second call (file already gone) is a no-op, not an error.
    expect(await svc.deleteExportedDelta(42), isFalse);
  });

  test(
    'exportRegionCutout returns the co-add paths for a known region',
    () async {
      final id = await service.ensureRegion(
        name: 'M31',
        centerRaDeg: 10.68,
        centerDecDeg: 41.27,
        radiusDeg: 1.5,
        kind: 'custom',
      );
      final export = await service.exportRegionCutout(id);
      expect(export, isNotNull);
      expect(export!.regionName, 'M31');
      // The fake seam's queryCutout returns a pngPath but no fitsPath; the
      // service synthesizes the fitsPath via the cutout stem.
      expect(export.fitsPath, isNotEmpty);
      expect(export.pngPath, '/tmp/cutout.png');

      // An unknown region id yields null (nothing to export).
      expect(await service.exportRegionCutout(999999), isNull);
    },
  );

  group('per-frame accounting, queue and switches', () {
    DbCapturedImage light(
      int id, {
      String? filter = 'R',
      bool accepted = true,
      double exposure = 120.0,
    }) => DbCapturedImage(
      id: id,
      filePath: '/tmp/light_$id.fits',
      fileName: 'light_$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      filter: filter,
      exposureDuration: exposure,
      binX: 1,
      binY: 1,
      isPlateSolved: true,
      solvedRa: 2.37,
      solvedDec: 42.35,
      solvedPixelScale: 0.79,
      capturedAt: DateTime.utc(2026, 10, 24, 1, id),
      createdAt: DateTime.utc(2026, 10, 24, 1, id),
      isAccepted: accepted,
    );

    /// A native fold result in which every frame of the call lands in the same
    /// [tilesPerFrame] tiles, as a dithered sub does (~100 tiles each).
    Map<String, dynamic> foldResult(
      Map<String, dynamic> args, {
      int tilesPerFrame = 100,
    }) {
      final frames = (args['frames'] as List).cast<Map<String, dynamic>>();
      return {
        'ok': true,
        'tilesTouched': [for (var t = 0; t < tilesPerFrame; t++) 1000 + t],
        'frameFolds': [
          for (var i = 0; i < frames.length; i++)
            for (var t = 0; t < tilesPerFrame; t++)
              {
                'frameIndex': i,
                'label': frames[i]['label'],
                'tileId': 1000 + t,
                'weightAdded': 1.0,
                'integrationSecondsAdded': frames[i]['exposureSec'],
                'coverageAdded': 0.5,
                'rejected': 0,
              },
        ],
        'foldsByTile': [
          for (var t = 0; t < tilesPerFrame; t++)
            {
              'tileId': 1000 + t,
              'framesAdded': frames.length,
              'weightAdded': frames.length.toDouble(),
              'integrationSecondsAdded': frames.fold<double>(
                0,
                (a, f) => a + (f['exposureSec'] as num).toDouble(),
              ),
              'coverageAdded': 0.5 * frames.length,
              'rejected': 0,
              'coverageMean': 0.5 * frames.length,
              'centerRa': 35.6,
              'centerDec': 42.35,
              'totalFrames': frames.length,
              'integrationSeconds': 0.0,
              'channels': 1,
            },
        ],
        'framesSkippedNoCoverage': 0,
        'layer': args['layer'],
      };
    }

    test('each timeline row holds its own frame exposure and totals count '
        'each frame once', () async {
      seam.onDispatch = (args) => foldResult(args);
      await service.autoFoldCapturedImage(
        image: light(1, exposure: 15.0),
        imageWidth: 4656,
        imageHeight: 3520,
      );
      await service.autoFoldCapturedImage(
        image: light(2, exposure: 2.0),
        imageWidth: 4656,
        imageHeight: 3520,
      );

      final rows = await dao.listFoldsForTileOverTime(1000);
      expect(rows.map((r) => r.integrationSecondsAdded), [15.0, 2.0]);
      final tile = await dao.getTile(1000);
      expect(tile!.totalFrames, 2);
      expect(tile.integrationSeconds, 17.0);

      // Two frames of 17 s in all, although each landed in 100 tiles.
      final totals = await dao.atlasTotals();
      expect(totals.frames, 2);
      expect(totals.seconds, 17.0);
    });

    test('frames arriving during a fold wait and fold together, one call '
        'at a time', () async {
      final gate = Completer<void>();
      var inFlight = 0;
      var maxInFlight = 0;
      final batchSizes = <int>[];
      final blocking = _FakeSkyAtlasSeam()
        ..onDispatch = (args) => foldResult(args, tilesPerFrame: 3);
      final svc = SkyAtlasService(
        dao: dao,
        seam: _GatedSeam(blocking, () async {
          inFlight++;
          maxInFlight = math.max(maxInFlight, inFlight);
          await gate.future;
          inFlight--;
        }, batchSizes),
        logger: LoggingService(),
        atlasRootResolver: () async => '/tmp/test_atlas',
      );

      final futures = [
        for (var i = 1; i <= 7; i++)
          svc.autoFoldCapturedImage(
            image: light(i),
            imageWidth: 4656,
            imageHeight: 3520,
          ),
      ];
      await pumpEventQueue();
      expect(batchSizes, [1], reason: 'the first frame folds alone');
      expect(svc.pendingAutoFolds, 6);
      gate.complete();
      final results = await Future.wait(futures);

      expect(batchSizes, [1, SkyAtlasService.maxFoldBatch, 2]);
      expect(maxInFlight, 1);
      expect(results.every((r) => r != null && r.totalFramesFolded == 1), true);
      expect((await dao.atlasTotals()).frames, 7);
    });

    test('the atlas switch, rejected frames and the filter layer', () async {
      var enabled = false;
      final svc = SkyAtlasService(
        dao: dao,
        seam: seam,
        logger: LoggingService(),
        atlasRootResolver: () async => '/tmp/test_atlas',
        autoFoldEnabled: () async => enabled,
      );
      seam.onDispatch = (args) => foldResult(args, tilesPerFrame: 2);

      expect(
        await svc.autoFoldCapturedImage(
          image: light(1),
          imageWidth: 4656,
          imageHeight: 3520,
        ),
        isNull,
      );
      expect(seam.dispatched, isEmpty, reason: 'atlas switched off');

      enabled = true;
      expect(
        await svc.autoFoldCapturedImage(
          image: light(2, accepted: false),
          imageWidth: 4656,
          imageHeight: 3520,
        ),
        isNull,
      );
      expect(seam.dispatched, isEmpty, reason: 'rejected frames never fold');

      await svc.autoFoldCapturedImage(
        image: light(3, filter: 'Ha'),
        imageWidth: 4656,
        imageHeight: 3520,
      );
      expect(seam.dispatched.single['layer'], 'Ha');
    });
  });
}

/// Wraps a seam so each fold waits on [beforeFold] and records its batch size.
class _GatedSeam implements SkyAtlasSeam {
  _GatedSeam(this._inner, this._beforeFold, this._batchSizes);

  final _FakeSkyAtlasSeam _inner;
  final Future<void> Function() _beforeFold;
  final List<int> _batchSizes;

  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async {
    if (args['action'] == 'fold') {
      _batchSizes.add((args['frames'] as List).length);
      await _beforeFold();
    }
    return _inner.dispatch(args);
  }

  @override
  Future<Map<String, dynamic>> queryCutout(Map<String, dynamic> args) =>
      _inner.queryCutout(args);

  @override
  Future<Map<String, dynamic>> regionInfo(Map<String, dynamic> args) =>
      _inner.regionInfo(args);

  @override
  Future<Map<String, dynamic>> growth(Map<String, dynamic> args) =>
      _inner.growth(args);

  @override
  Future<Map<String, dynamic>> mergeDelta(Map<String, dynamic> args) =>
      _inner.mergeDelta(args);
}
