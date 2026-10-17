import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// The remote "Your Sky" atlas browser reconstructs `SkyAtlasRegionRow`s from
/// the appliance's `/api/atlas/regions` wire JSON (companion mode reads the
/// host's atlas, not its own empty local store). This pins that the
/// reconstruction is a faithful round-trip of the shape
/// `AtlasHandlers._regionToJson` emits — in particular that `createdAt` is
/// parsed from the ISO-8601 string the handler serializes, NOT the epoch-millis
/// the Drift default serializer would otherwise expect.
void main() {
  group('skyAtlasRegionFromWireJson', () {
    // Mirrors AtlasHandlers._regionToJson exactly.
    Map<String, dynamic> wire({int? targetId}) => {
      'id': 7,
      'name': 'Orion',
      'kind': 'target',
      'centerRaDeg': 83.82,
      'centerDecDeg': -5.39,
      'radiusDeg': 2.5,
      'targetId': targetId,
      'tileCount': 12,
      'integrationSeconds': 3600.0,
      'createdAt': DateTime.utc(2026, 6, 19, 22, 30).toIso8601String(),
    };

    test('reconstructs every column of a target-linked region', () {
      final row = skyAtlasRegionFromWireJson(wire(targetId: 99));

      expect(row.id, 7);
      expect(row.name, 'Orion');
      expect(row.kind, 'target');
      expect(row.centerRaDeg, 83.82);
      expect(row.centerDecDeg, -5.39);
      expect(row.radiusDeg, 2.5);
      expect(row.targetId, 99);
      expect(row.tileCount, 12);
      expect(row.integrationSeconds, 3600.0);
      expect(row.createdAt.toUtc(), DateTime.utc(2026, 6, 19, 22, 30));
    });

    test(
      'parses the ISO-8601 createdAt the handler emits (not epoch millis)',
      () {
        final row = skyAtlasRegionFromWireJson(wire());
        // A faithful ISO parse — a millis-expecting decoder would have thrown.
        expect(row.createdAt.toUtc(), DateTime.utc(2026, 6, 19, 22, 30));
      },
    );

    test('null targetId stays null (freestanding / orphaned region)', () {
      expect(skyAtlasRegionFromWireJson(wire()).targetId, isNull);
    });

    test('integer JSON numbers decode to the double cone fields', () {
      final json = wire()
        ..['centerRaDeg'] = 84
        ..['radiusDeg'] = 3
        ..['integrationSeconds'] = 3600;
      final row = skyAtlasRegionFromWireJson(json);

      expect(row.centerRaDeg, 84.0);
      expect(row.radiusDeg, 3.0);
      expect(row.integrationSeconds, 3600.0);
    });
  });

  group('skyTileRowFromWireJson (host region-detail tiles[] row)', () {
    // Mirrors AtlasHandlers._tileToJson — the additive `tiles` array the
    // `GET /api/atlas/region/<id>` payload now carries so the slave's region
    // detail renders the same tile rollups the host computes locally.
    Map<String, dynamic> wire() => {
      'id': 3,
      'tileId': 42,
      'healpixOrder': 9,
      'channels': 3,
      'centerRaDeg': 83.6,
      'centerDecDeg': -5.39,
      'coverageMean': 0.9,
      'totalFrames': 30,
      'integrationSeconds': 1800.0,
      'swarmOverlayFrames': 12,
      'swarmOverlayIntegrationSeconds': 720.0,
      'regionId': 7,
    };

    test('reconstructs a tile row from the host region-detail wire shape', () {
      final tile = skyTileRowFromWireJson(wire());
      expect(tile.tileId, 42);
      expect(tile.healpixOrder, 9);
      expect(tile.channels, 3);
      expect(tile.centerRaDeg, 83.6);
      expect(tile.integrationSeconds, 1800.0);
      expect(tile.swarmOverlayFrames, 12);
      expect(tile.regionId, 7);
    });

    test('defaults a missing healpixOrder to the atlas order', () {
      final json = wire()..remove('healpixOrder');
      expect(skyTileRowFromWireJson(json).healpixOrder, skyAtlasHealpixOrder);
    });
  });

  group('skyAtlasFoldRowFromWireJson (host /timeline folds[] row)', () {
    // Mirrors AtlasHandlers._foldToJson — the timeline rows the slave's
    // scrubber + contributing-frames list decode from `/region/<id>/timeline`.
    Map<String, dynamic> wire() => {
      'id': 5,
      'tileId': 42,
      'healpixOrder': 9,
      'sessionId': 7,
      'foldedAt': DateTime.utc(2026, 6, 19, 22, 30).toIso8601String(),
      'framesAdded': 4,
      'weightAdded': 4.0,
      'integrationSecondsAdded': 1200.0,
      'rejected': 1,
      'contributor': '',
      'label': '2026-06-19',
    };

    test('reconstructs a fold row, parsing the ISO foldedAt', () {
      final fold = skyAtlasFoldRowFromWireJson(wire());
      expect(fold.id, 5);
      expect(fold.tileId, 42);
      expect(fold.sessionId, 7);
      expect(fold.framesAdded, 4);
      expect(fold.integrationSecondsAdded, 1200.0);
      expect(fold.rejected, 1);
      expect(fold.label, '2026-06-19');
      expect(fold.foldedAt.toUtc(), DateTime.utc(2026, 6, 19, 22, 30));
    });

    test('null sessionId stays null (sessionless / deleted-session fold)', () {
      final json = wire()..['sessionId'] = null;
      expect(skyAtlasFoldRowFromWireJson(json).sessionId, isNull);
    });
  });

  group('AtlasGrowthCurve.fromJson (bridge growth / host /timeline growth)', () {
    // Mirrors the bridge `growth` action result (see api_sky_atlas_growth):
    // a chronological `points` series + region cone lifetime totals. The host's
    // /api/atlas/region/<id>/timeline payload nests this same map under `growth`.
    Map<String, dynamic> wire() => {
      'ok': true,
      'points': [
        {
          'label': '2026-06-01',
          'framesAdded': 30,
          'secondsAdded': 9000.0,
          'cumulativeFrames': 30,
          'cumulativeSeconds': 9000.0,
          'contributor': '',
        },
        {
          'label': '2026-06-05',
          'framesAdded': 20,
          'secondsAdded': 6000.0,
          'cumulativeFrames': 50,
          'cumulativeSeconds': 15000.0,
          'contributor': 'alice',
        },
      ],
      'totalFrames': 50,
      'totalSeconds': 15000.0,
    };

    test('decodes the chronological cumulative series + totals', () {
      final curve = AtlasGrowthCurve.fromJson(wire());
      expect(curve.points, hasLength(2));
      expect(curve.totalFrames, 50);
      expect(curve.totalSeconds, 15000.0);

      expect(curve.points.first.label, '2026-06-01');
      expect(curve.points.first.cumulativeFrames, 30);
      expect(curve.points.last.cumulativeSeconds, 15000.0);
      expect(curve.points.last.contributor, 'alice');
      // Cumulative must be monotonically non-decreasing (deepening, never shallower).
      expect(
        curve.points.last.cumulativeSeconds >=
            curve.points.first.cumulativeSeconds,
        isTrue,
      );
    });

    test('parses an ISO date label, leaving a session-id label undated', () {
      final curve = AtlasGrowthCurve.fromJson(wire());
      final date = curve.points.first.date;
      expect(date, isNotNull);
      expect(date!.year, 2026);
      expect(date.month, 6);
      expect(date.day, 1);

      final sessionLabelled = AtlasGrowthCurve.fromJson({
        'points': [
          {'label': 'session-42', 'cumulativeSeconds': 100.0},
        ],
      });
      expect(sessionLabelled.points.single.date, isNull);
    });

    test('a missing / empty points block decodes to the empty curve', () {
      expect(AtlasGrowthCurve.fromJson(const {}).points, isEmpty);
      expect(AtlasGrowthCurve.fromJson(const {'points': null}).points, isEmpty);
      expect(AtlasGrowthCurve.empty.points, isEmpty);
      expect(AtlasGrowthCurve.empty.totalSeconds, 0.0);
    });

    test('integer JSON numbers decode to the double second fields', () {
      final curve = AtlasGrowthCurve.fromJson({
        'points': [
          {
            'label': '2026-06-01',
            'secondsAdded': 9000,
            'cumulativeSeconds': 9000,
          },
        ],
        'totalSeconds': 9000,
      });
      expect(curve.points.single.cumulativeSeconds, 9000.0);
      expect(curve.totalSeconds, 9000.0);
    });
  });

  group('AtlasTileCoverage.fromJson (host /api/atlas/coverage row)', () {
    // Mirrors AtlasHandlers._coverageToJson, which emits the bridge-native
    // key names AtlasTileCoverage.fromJson already consumes.
    test('reconstructs a coverage row from the host wire shape', () {
      final row = AtlasTileCoverage.fromJson({
        'tileId': 42,
        'centerRa': 120.5,
        'centerDec': -25.25,
        'coverageMean': 0.87,
        'totalFrames': 30,
        'integrationSeconds': 1800.0,
        'lastFoldIso': '2026-06-19T22:30:00.000Z',
        'channels': 3,
      });

      expect(row.tileId, 42);
      expect(row.centerRaDeg, 120.5);
      expect(row.centerDecDeg, -25.25);
      expect(row.coverageMean, 0.87);
      expect(row.totalFrames, 30);
      expect(row.integrationSeconds, 1800.0);
      expect(row.lastFoldIso, '2026-06-19T22:30:00.000Z');
      expect(row.channels, 3);
    });
  });
}
