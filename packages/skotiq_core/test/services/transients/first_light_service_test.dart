import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Recording fake seam returning a canned `api_difference_image` envelope.
class _FakeDifferenceSeam implements DifferenceImageSeam {
  _FakeDifferenceSeam(this.result);
  Map<String, dynamic> result;
  final List<Map<String, dynamic>> dispatched = [];
  bool throws = false;

  @override
  Future<Map<String, dynamic>> difference(Map<String, dynamic> args) async {
    dispatched.add(args);
    if (throws) throw StateError('difference failed');
    return result;
  }

  @override
  Future<Map<String, dynamic>> tileCenter(Map<String, dynamic> args) async => {
    'tileId': args['tileId'],
    'ra': 0.0,
    'dec': 0.0,
  };
}

/// Catalog matcher that returns a fixed star list (empty = no match).
class _FakeCatalogMatcher implements TransientCatalogMatcher {
  _FakeCatalogMatcher(this.stars, {this.throwError = false});
  List<PhotometricCatalogStar> stars;
  bool throwError;
  double? lastRadiusArcsec;

  @override
  Future<List<PhotometricCatalogStar>> coneStars({
    required double raDegrees,
    required double decDegrees,
    required double radiusDegrees,
    double maxMagnitude = 18.0,
  }) async {
    lastRadiusArcsec = radiusDegrees * 3600.0;
    if (throwError) throw StateError('network down');
    return stars;
  }
}

const _wcs = SolvedWcs(
  raHours: 8.0, // 120 deg
  decDegrees: 25.0,
  rotationDeg: 0.0,
  pixelScaleArcsec: 2.0,
  imageWidth: 1024,
  imageHeight: 1024,
);

Map<String, dynamic> _candidateJson({
  double ra = 120.0,
  double dec = 25.0,
  int tileId = 42,
  double snr = 18.0,
  String kind = 'newSource',
  double? deltaMag,
  double eccentricity = 0.1,
}) {
  return {
    'ra': ra,
    'dec': dec,
    'tileId': tileId,
    'tileX': 512.0,
    'tileY': 600.0,
    'residualFlux': 5000.0,
    'deltaMag': deltaMag,
    'snr': snr,
    'fwhm': 2.1,
    'eccentricity': eccentricity,
    'kind': kind,
    'catalogMatch': null,
  };
}

void main() {
  late SkotiqDatabase db;
  late TransientDetectionsDao dao;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = TransientDetectionsDao(db);
    // Detections reference sessions and images these tests do not create.
    await db.customStatement('PRAGMA foreign_keys = OFF');
  });

  tearDown(() async {
    await db.close();
  });

  FirstLightService build({
    required Map<String, dynamic> diffResult,
    List<PhotometricCatalogStar> stars = const [],
    bool catalogThrows = false,
    LivingSkyRetentionDao? retention,
    void Function(FirstLightCoverage)? onCoverage,
  }) {
    return FirstLightService(
      dao: dao,
      seam: _FakeDifferenceSeam(diffResult),
      catalog: _FakeCatalogMatcher(stars, throwError: catalogThrows),
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/test_atlas',
      retention: retention,
      onCoverage: onCoverage,
    );
  }

  /// Scan frame [id] (filter R) of session 3.
  Future<List<TransientDetectionRow>> scan(
    FirstLightService service,
    int id, {
    String? filter = 'R',
  }) => service.scanFrame(
    framePath: '/tmp/light_$id.fits',
    wcs: _wcs,
    sessionId: 3,
    capturedImageId: id,
    filter: filter,
  );

  test('a single-frame sighting is held back; the second frame confirms '
      'and persists it once', () async {
    final service = build(
      diffResult: {
        'ok': true,
        'candidates': [_candidateJson()],
        'tilesChecked': [42],
      },
    );

    expect(await scan(service, 1), isEmpty);
    expect(await dao.allDetections(), isEmpty);

    final rows = await scan(service, 2);
    expect(rows, hasLength(1));
    expect(rows.single.catalogMatch, isNull);
    expect(rows.single.kind, 'newSource');
    expect(rows.single.capturedImageId, 2);

    // Later frames at the same position do not add rows again.
    expect(await scan(service, 3), isEmpty);
    expect(await dao.allDetections(), hasLength(1));
  });

  test('the same frame scanned twice does not confirm itself', () async {
    final service = build(
      diffResult: {
        'ok': true,
        'candidates': [_candidateJson()],
        'tilesChecked': [42],
      },
    );
    expect(await scan(service, 1), isEmpty);
    expect(await scan(service, 1), isEmpty);
  });

  for (final gap in ['clean', 'failed subtraction', 'native error']) {
    test('$gap frames expire an old sighting', () async {
      final result = <String, dynamic>{
        'candidates': [_candidateJson()],
      };
      final seam = _FakeDifferenceSeam(result);
      final service = FirstLightService(
        dao: dao,
        seam: seam,
        catalog: _FakeCatalogMatcher(const []),
        logger: LoggingService(),
        atlasRootResolver: () async => '/tmp/test_atlas',
      );
      expect(await scan(service, 1), isEmpty);
      seam.result = {
        'candidates': gap == 'failed subtraction'
            ? List.generate(26, (i) => _candidateJson(ra: 121.0 + i))
            : <Map<String, dynamic>>[],
      };
      seam.throws = gap == 'native error';
      for (var id = 2; id <= 8; id++) {
        if (seam.throws) {
          await expectLater(scan(service, id), throwsStateError);
        } else {
          expect(await scan(service, id), isEmpty);
        }
      }
      seam.throws = false;
      seam.result = result;
      expect(await scan(service, 9), isEmpty);
      expect(await scan(service, 10), hasLength(1));
    });
  }

  test('duplicate clean scans do not age a sighting twice', () async {
    final result = <String, dynamic>{
      'candidates': [_candidateJson()],
    };
    final seam = _FakeDifferenceSeam(result);
    final service = FirstLightService(
      dao: dao,
      seam: seam,
      catalog: _FakeCatalogMatcher(const []),
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/test_atlas',
    );
    await scan(service, 1);
    seam.result = {'candidates': <Map<String, dynamic>>[]};
    for (var attempt = 0; attempt < 20; attempt++) {
      expect(await scan(service, 2), isEmpty);
    }
    for (var id = 3; id <= 6; id++) {
      expect(await scan(service, id), isEmpty);
    }
    seam.result = result;
    expect(await scan(service, 7), hasLength(1));
  });

  test('sightings in different filters or sessions do not confirm each '
      'other', () async {
    final service = build(
      diffResult: {
        'ok': true,
        'candidates': [_candidateJson()],
        'tilesChecked': [42],
      },
    );
    expect(await scan(service, 1, filter: 'R'), isEmpty);
    expect(await scan(service, 2, filter: 'G'), isEmpty);
    expect(
      await service.scanFrame(
        framePath: '/tmp/light_5.fits',
        wcs: _wcs,
        sessionId: 4,
        capturedImageId: 5,
        filter: 'R',
      ),
      isEmpty,
    );
  });

  test('a frame without a filter is not scanned', () async {
    final seam = _FakeDifferenceSeam({
      'ok': true,
      'candidates': [_candidateJson()],
    });
    final service = FirstLightService(
      dao: dao,
      seam: seam,
      catalog: _FakeCatalogMatcher(const []),
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/test_atlas',
    );
    expect(await scan(service, 1, filter: null), isEmpty);
    expect(seam.dispatched, isEmpty);
  });

  test('positions of a sighting more than 2.5 arcsec apart do not '
      'confirm', () async {
    final seam = _FakeDifferenceSeam({
      'ok': true,
      'candidates': [_candidateJson()],
    });
    final service = FirstLightService(
      dao: dao,
      seam: seam,
      catalog: _FakeCatalogMatcher(const []),
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/test_atlas',
    );
    await scan(service, 1);
    seam.result = {
      'ok': true,
      'candidates': [_candidateJson(dec: 25.0 + 4.0 / 3600.0)],
    };
    expect(await scan(service, 2), isEmpty);
  });

  test('a brightening of a catalog star is named by the star, within '
      '5 arcsec only', () async {
    final service = build(
      diffResult: {
        'ok': true,
        'candidates': [
          _candidateJson(kind: 'pointBrightening', deltaMag: -1.2),
        ],
        'tilesChecked': [42],
      },
      stars: const [
        PhotometricCatalogStar(raDegrees: 120.0, decDegrees: 25.0, magV: 14.2),
      ],
    );
    await scan(service, 1);
    final rows = await scan(service, 2);
    expect(rows, hasLength(1));
    expect(rows.single.kind, 'pointBrightening');
    expect(rows.single.catalogMatch, 'APASS star V=14.2');
    expect(rows.single.deltaMag, -1.2);
  });

  test('a catalog star 8 arcsec away does not name the source (no '
      'proper-motion cone)', () async {
    final catalog = _FakeCatalogMatcher(const [
      PhotometricCatalogStar(
        raDegrees: 120.0,
        decDegrees: 25.0 + 8.0 / 3600.0,
        magV: 9.5,
      ),
    ]);
    final service = FirstLightService(
      dao: dao,
      seam: _FakeDifferenceSeam({
        'ok': true,
        'candidates': [_candidateJson()],
      }),
      catalog: catalog,
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/test_atlas',
    );
    await scan(service, 1);
    final rows = await scan(service, 2);
    expect(rows.single.catalogMatch, isNull);
    expect(catalog.lastRadiusArcsec, closeTo(5.0, 1e-9));
  });

  test('streaks and dipoles are never reported', () async {
    final service = build(
      diffResult: {
        'ok': true,
        'candidates': [
          _candidateJson(kind: 'movingStreak', eccentricity: 0.95),
          _candidateJson(kind: 'dipole', ra: 120.01),
        ],
      },
    );
    await scan(service, 1);
    expect(await scan(service, 2), isEmpty);
  });

  test('drops residuals below the significance floor', () async {
    final service = build(
      diffResult: {
        'ok': true,
        'candidates': [_candidateJson(snr: 6.0)],
        'tilesChecked': [42],
      },
    );
    await scan(service, 1);
    expect(await scan(service, 2), isEmpty);
    expect(await dao.allDetections(), isEmpty);
  });

  test('a frame with an implausible number of candidates keeps none', () async {
    final service = build(
      diffResult: {
        'ok': true,
        'candidates': [
          for (var i = 0; i < 40; i++) _candidateJson(ra: 120.0 + i * 0.01),
        ],
      },
    );
    await scan(service, 1);
    expect(await scan(service, 2), isEmpty);
  });

  test('suppresses a residual at a previously-dismissed position', () async {
    final service = build(
      diffResult: {
        'ok': true,
        'candidates': [_candidateJson()],
        'tilesChecked': [42],
      },
    );
    await scan(service, 1);
    final first = await scan(service, 2);
    expect(first, hasLength(1));
    await service.markReviewed(first.single.id, dismissed: true);

    final again = build(
      diffResult: {
        'ok': true,
        'candidates': [_candidateJson()],
        'tilesChecked': [42],
      },
    );
    await scan(again, 3);
    expect(await scan(again, 4), isEmpty);
  });

  test(
    'dismissed-suppression is scoped to the tiles a frame covers (index seek)',
    () async {
      final service = build(
        diffResult: {
          'ok': true,
          'candidates': [_candidateJson(tileId: 42)],
          'tilesChecked': [42],
        },
      );
      await scan(service, 1);
      final first = await scan(service, 2);
      await service.markReviewed(first.single.id, dismissed: true);

      final other = build(
        diffResult: {
          'ok': true,
          'candidates': [_candidateJson(tileId: 7)],
          'tilesChecked': [7],
        },
      );
      await scan(other, 3);
      final survived = await scan(other, 4);
      expect(survived, hasLength(1));
      expect(survived.single.tileId, 7);

      expect(await dao.dismissedDetectionsForTiles(const [42]), hasLength(1));
      expect(await dao.dismissedDetectionsForTiles(const [7]), isEmpty);
      expect(await dao.dismissedDetectionsForTiles(const []), isEmpty);
    },
  );

  test('pruneOldDetections ages out dismissed history, keeps reviewed/'
      'confirmed/unreviewed, and records the retention marker', () async {
    final retention = LivingSkyRetentionDao(db);
    final service = build(
      diffResult: {'ok': true, 'candidates': const []},
      retention: retention,
    );

    final old = DateTime.utc(2025, 1, 1);
    // 1) Old dismissed artefact — reclaimable.
    final dismissedId = await dao.insertDetection(
      TransientDetectionsCompanion.insert(
        tileId: 42,
        raDeg: 120.0,
        decDeg: 25.0,
        residualFlux: 1500.0,
        snr: 18.0,
        fwhm: 2.1,
        eccentricity: 0.1,
        kind: 'newSource',
        confidence: 0.8,
        detectedAt: Value(old),
        dismissed: const Value(true),
        reviewed: const Value(true),
      ),
    );
    // 2) Old confirmed named discovery — must be kept.
    final confirmedId = await dao.insertDetection(
      TransientDetectionsCompanion.insert(
        tileId: 42,
        raDeg: 121.0,
        decDeg: 25.0,
        residualFlux: 1500.0,
        snr: 18.0,
        fwhm: 2.1,
        eccentricity: 0.1,
        kind: 'newSource',
        confidence: 0.9,
        detectedAt: Value(old),
        reviewed: const Value(true),
      ),
    );
    // 3) Old un-reviewed candidate — must be kept (never silently reclaimed).
    final unreviewedId = await dao.insertDetection(
      TransientDetectionsCompanion.insert(
        tileId: 42,
        raDeg: 122.0,
        decDeg: 25.0,
        residualFlux: 1500.0,
        snr: 18.0,
        fwhm: 2.1,
        eccentricity: 0.1,
        kind: 'newSource',
        confidence: 0.7,
        detectedAt: Value(old),
      ),
    );

    final reclaimed = await service.pruneOldDetections(
      horizon: const Duration(days: 30),
      now: DateTime.utc(2026, 6, 1),
    );

    expect(reclaimed, 1);
    expect(await dao.detectionById(dismissedId), isNull);
    expect(await dao.detectionById(confirmedId), isNotNull);
    expect(await dao.detectionById(unreviewedId), isNotNull);

    final marker = await retention.getMarker(
      LivingSkyRetentionScope.transientDetections,
    );
    expect(marker, isNotNull);
    expect(marker!.prunedCount, 1);
  });

  test(
    'a degraded (network-down) cross-match still surfaces the transient',
    () async {
      final service = build(
        diffResult: {
          'ok': true,
          'candidates': [_candidateJson()],
          'tilesChecked': [42],
        },
        catalogThrows: true,
      );
      await scan(service, 1);
      final rows = await scan(service, 2);
      expect(rows, hasLength(1));
      expect(rows.single.catalogMatch, isNull);
    },
  );

  test('rejects an invalid WCS', () async {
    final service = build(diffResult: {'ok': true, 'candidates': const []});
    expect(
      () => service.scanFrame(
        framePath: '/tmp/a.fits',
        wcs: const SolvedWcs(
          raHours: 8.0,
          decDegrees: 25.0,
          rotationDeg: 0.0,
          pixelScaleArcsec: 0.0, // invalid
          imageWidth: 1024,
          imageHeight: 1024,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('passes the filter layer, the significance floor and a crop output dir '
      'to the difference call', () async {
    final seam = _FakeDifferenceSeam({
      'ok': true,
      'candidates': [_candidateJson()],
      'tilesChecked': [42],
    });
    final service = FirstLightService(
      dao: dao,
      seam: seam,
      catalog: _FakeCatalogMatcher(const []),
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/test_atlas',
      filterResolver: (id) async => id == 777 ? 'Ha' : null,
    );

    await service.scanFrame(
      framePath: '/tmp/light_777.fits',
      wcs: _wcs,
      capturedImageId: 777,
    );

    final args = seam.dispatched.single;
    expect(args['layer'], 'Ha');
    expect(args['minSignificance'], 7.0);
    expect(args['cropOutDir'], firstLightCropDir('/tmp/test_atlas'));
  });

  test('publishes the coverage envelope; a thin atlas is flagged distinctly '
      'from a clean sky', () async {
    // Atlas-too-thin: the frame covered tiles but none were deep enough.
    FirstLightCoverage? thin;
    final thinService = build(
      diffResult: {
        'ok': true,
        'candidates': const [],
        'tilesChecked': const [],
        'tilesSkippedThin': [10, 11],
        'tilesNoTemplate': [12],
      },
      onCoverage: (c) => thin = c,
    );
    final thinRows = await scan(thinService, 1);
    expect(thinRows, isEmpty);
    expect(thin, isNotNull);
    expect(thin!.tilesChecked, 0);
    expect(thin!.tilesCovered, 3);
    expect(thin!.isAtlasTooThin, isTrue);

    // Clean sky: tiles were deep enough, nothing found — NOT atlas-too-thin.
    FirstLightCoverage? clean;
    final cleanService = build(
      diffResult: {
        'ok': true,
        'candidates': const [],
        'tilesChecked': [10, 11],
      },
      onCoverage: (c) => clean = c,
    );
    await scan(cleanService, 2);
    expect(clean!.tilesChecked, 2);
    expect(clean!.isAtlasTooThin, isFalse);
  });

  test(
    'unvalidated subtraction counts as covered but not a thin atlas',
    () async {
      FirstLightCoverage? coverage;
      final service = build(
        diffResult: {
          'ok': true,
          'candidates': const [],
          'tilesChecked': const [],
          'tilesUnnormalized': [10, 11],
          'tilesSkippedThin': [12],
        },
        onCoverage: (c) => coverage = c,
      );
      expect(await scan(service, 1), isEmpty);
      expect(coverage!.tilesCovered, 3);
      expect(coverage!.tilesChecked, 0);
      expect(coverage!.isAtlasTooThin, isFalse);
    },
  );

  test('crop filename is deterministic and mirrors the native key', () {
    final name = firstLightCropName(
      tileId: 42,
      raDeg: 120.5,
      decDeg: -10.25,
      stage: 'residual',
    );
    // tileId _ ra*1e6 _ dec*1e6 _ stage.png
    expect(name, 'crop_42_120500000_-10250000_residual.png');
  });
}
