// Living Sky — master/slave PROVIDER parity net.
//
// The slave-blind failure (region detail / First Light feed reading an EMPTY
// local store on a companion tablet instead of the host's data) is invisible
// unless the backend-branching read providers are asserted in slave
// (NetworkBackend) mode to surface the HOST's data rather than empty local
// state. These tests pin that branch for every Living Sky read surface a slave
// is expected to mirror:
//
//   Pillar A (Your Sky):
//     * skyAtlasCoverageProvider     -> host GET /api/atlas/coverage
//     * skyAtlasRegionsProvider      -> host GET /api/atlas/regions
//     * atlasRegionProvider          -> host GET /api/atlas/region/<id>
//     * atlasRegionTilesProvider     -> host region-detail `tiles`
//     * atlasRegionTimelineProvider  -> host GET /api/atlas/region/<id>/timeline
//     * atlasRegionCutoutProvider    -> host GET /api/atlas/region/<id>/cutout (bytes)
//     * atlasRegionGrowthProvider    -> host /timeline `growth` block
//     * atlasRegionProvenanceProvider-> host region `tiles` + timeline `folds`
//   Pillar B (First Light):
//     * firstLightCandidatesProvider -> host GET /api/firstlight/candidates
//
// Each test overrides backendProvider with a NetworkBackend mock whose host
// returns NON-empty data, and asserts the slave provider returns that host data
// (not the empty local DAO/seam). The complementary HOST-mode branch is covered
// by sky_atlas_service_test.dart / the First Light service tests; the
// remote-triage refresh path is covered by first_light_remote_triage_refresh_test.dart.
//
// The wire-route safety net (every NetworkBackend Living-Sky call maps to a
// registered + advertised headless route) lives in the contract test at
// apps/desktop/test/headless_api/network_backend_contract_test.dart.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/sky_atlas_provider.dart';
import 'package:skotiq_core/src/providers/transient_detections_provider.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// One host coverage tile (deepest-first wire shape from AtlasHandlers).
Map<String, dynamic> _coverageTile({
  required int tileId,
  required int frames,
}) => {
  'tileId': tileId,
  'healpixOrder': 9,
  'centerRaDeg': 10.68,
  'centerDecDeg': 41.27,
  'coverageMean': 1.0,
  'totalFrames': frames,
  'integrationSeconds': frames * 300.0,
  'swarmOverlayFrames': 0,
  'swarmOverlayIntegrationSeconds': 0.0,
};

/// One host region row (the ISO-8601 createdAt the handler emits).
Map<String, dynamic> _regionJson({required int id, required String name}) => {
  'id': id,
  'name': name,
  'kind': 'target',
  'centerRaDeg': 10.68,
  'centerDecDeg': 41.27,
  'radiusDeg': 1.5,
  'targetId': 31,
  'tileCount': 6,
  'integrationSeconds': 3600.0,
  'createdAt': '2026-06-22T22:30:00.000Z',
};

Map<String, dynamic> _tileJson({required int tileId}) => {
  'id': tileId,
  'tileId': tileId,
  'healpixOrder': 9,
  'channels': 1,
  'centerRaDeg': 10.68,
  'centerDecDeg': 41.27,
  'coverageMean': 1.0,
  'totalFrames': 12,
  'integrationSeconds': 3600.0,
  'regionId': 1,
};

Map<String, dynamic> _foldJson({required int id}) => {
  'id': id,
  'tileId': 99,
  'healpixOrder': 9,
  'sessionId': 4,
  'foldedAt': '2026-06-22T22:30:00.000Z',
  'framesAdded': 3,
  'weightAdded': 3.0,
  'integrationSecondsAdded': 900.0,
  'rejected': 0,
  'contributor': '',
  'label': 'M31',
};

Map<String, dynamic> _candidate({required int id, required bool reviewed}) => {
  'id': id,
  'sessionId': null,
  'capturedImageId': 34,
  'tileId': 42,
  'detectedAt': DateTime.utc(2026, 6, 22, 22, 30).millisecondsSinceEpoch,
  'raDeg': 120.5,
  'decDeg': -25.25,
  'residualFlux': 1500.0,
  'deltaMag': null,
  'snr': 18.3,
  'fwhm': 2.1,
  'eccentricity': 0.12,
  'positionAngleDeg': 63.5,
  'kind': 'newSource',
  'catalogMatch': null,
  'confidence': 0.81,
  'reviewed': reviewed,
  'dismissed': false,
};

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
  });

  _MockNetworkBackend slaveBackend() {
    final backend = _MockNetworkBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    return backend;
  }

  ProviderContainer containerFor(_MockNetworkBackend backend) {
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('Pillar A (Your Sky) — slave reads host atlas, not empty local state', () {
    test('skyAtlasCoverageProvider returns the host coverage tiles', () async {
      final backend = slaveBackend();
      when(() => backend.getAtlasCoverage()).thenAnswer(
        (_) async => [
          _coverageTile(tileId: 1, frames: 40),
          _coverageTile(tileId: 2, frames: 12),
        ],
      );
      final container = containerFor(backend);

      final tiles = await container.read(skyAtlasCoverageProvider.future);

      expect(tiles, hasLength(2));
      expect(tiles.first.tileId, 1);
      expect(tiles.first.totalFrames, 40);
      verify(() => backend.getAtlasCoverage()).called(1);
    });

    test('skyAtlasRegionsProvider returns the host region list', () async {
      final backend = slaveBackend();
      when(
        () => backend.getAtlasRegions(),
      ).thenAnswer((_) async => [_regionJson(id: 1, name: 'M31')]);
      final container = containerFor(backend);

      final regions = await container.read(skyAtlasRegionsProvider.future);

      expect(regions, hasLength(1));
      expect(regions.single.name, 'M31');
      verify(() => backend.getAtlasRegions()).called(1);
    });

    test('skyAtlasRegionWriterProvider creates metadata on the host', () async {
      final backend = slaveBackend();
      when(
        () => backend.createAtlasRegion(
          name: any(named: 'name'),
          centerRaDeg: any(named: 'centerRaDeg'),
          centerDecDeg: any(named: 'centerDecDeg'),
          radiusDeg: any(named: 'radiusDeg'),
          kind: any(named: 'kind'),
          targetId: any(named: 'targetId'),
        ),
      ).thenAnswer((_) async => 42);
      final container = containerFor(backend);

      final id = await container
          .read(skyAtlasRegionWriterProvider)
          .ensureRegion(
            name: 'M31 core',
            centerRaDeg: 10.68,
            centerDecDeg: 41.27,
            radiusDeg: 1.5,
            kind: 'target',
            targetId: 31,
          );

      expect(id, 42);
      verify(
        () => backend.createAtlasRegion(
          name: 'M31 core',
          centerRaDeg: 10.68,
          centerDecDeg: 41.27,
          radiusDeg: 1.5,
          kind: 'target',
          targetId: 31,
        ),
      ).called(1);
    });

    test('atlasRegionProvider reads host region detail (not empty)', () async {
      final backend = slaveBackend();
      when(
        () => backend.getAtlasRegion(1),
      ).thenAnswer((_) async => {'region': _regionJson(id: 1, name: 'M31')});
      final container = containerFor(backend);

      final region = await container.read(atlasRegionProvider(1).future);

      expect(region, isNotNull);
      expect(region!.id, 1);
      expect(region.name, 'M31');
      verify(() => backend.getAtlasRegion(1)).called(1);
    });

    test(
      'atlasRegionTilesProvider reads the host region-detail tiles',
      () async {
        final backend = slaveBackend();
        when(() => backend.getAtlasRegion(1)).thenAnswer(
          (_) async => {
            'region': _regionJson(id: 1, name: 'M31'),
            'tiles': [_tileJson(tileId: 7), _tileJson(tileId: 8)],
          },
        );
        final container = containerFor(backend);

        final tiles = await container.read(atlasRegionTilesProvider(1).future);

        expect(tiles.map((t) => t.tileId), [7, 8]);
        verify(() => backend.getAtlasRegion(1)).called(1);
      },
    );

    test('atlasRegionTimelineProvider reads the host fold timeline', () async {
      final backend = slaveBackend();
      when(() => backend.getAtlasRegionTimeline(1)).thenAnswer(
        (_) async => {
          'folds': [_foldJson(id: 11), _foldJson(id: 12)],
        },
      );
      final container = containerFor(backend);

      final folds = await container.read(atlasRegionTimelineProvider(1).future);

      expect(folds.map((f) => f.id), [11, 12]);
      verify(() => backend.getAtlasRegionTimeline(1)).called(1);
    });

    test(
      'atlasRegionGrowthProvider reads the host /timeline growth block',
      () async {
        final backend = slaveBackend();
        when(() => backend.getAtlasRegionTimeline(1)).thenAnswer(
          (_) async => {
            'folds': [_foldJson(id: 11)],
            'growth': {
              'ok': true,
              'points': [
                {
                  'label': '2026-06-20',
                  'framesAdded': 10,
                  'secondsAdded': 3000.0,
                  'cumulativeFrames': 10,
                  'cumulativeSeconds': 3000.0,
                  'contributor': '',
                },
                {
                  'label': '2026-06-22',
                  'framesAdded': 8,
                  'secondsAdded': 2400.0,
                  'cumulativeFrames': 18,
                  'cumulativeSeconds': 5400.0,
                  'contributor': '',
                },
              ],
              'totalFrames': 18,
              'totalSeconds': 5400.0,
            },
          },
        );
        final container = containerFor(backend);

        final curve = await container.read(atlasRegionGrowthProvider(1).future);

        // The slave plots the host's deepening curve, not an empty local one.
        expect(curve.points, hasLength(2));
        expect(curve.points.last.cumulativeSeconds, 5400.0);
        expect(curve.totalFrames, 18);
        verify(() => backend.getAtlasRegionTimeline(1)).called(1);
      },
    );

    test(
      'atlasRegionProvenanceProvider builds the deepest-tile view from the wire',
      () async {
        final backend = slaveBackend();
        // Two tiles; tile 8 is deepest (more integration), so its fold log drives
        // the provenance trail.
        when(() => backend.getAtlasRegion(1)).thenAnswer(
          (_) async => {
            'region': _regionJson(id: 1, name: 'M31'),
            'tiles': [
              {..._tileJson(tileId: 7), 'integrationSeconds': 1800.0},
              {
                ..._tileJson(tileId: 8),
                'integrationSeconds': 7200.0,
                'coverageMean': 0.95,
              },
            ],
          },
        );
        when(() => backend.getAtlasRegionTimeline(1)).thenAnswer(
          (_) async => {
            'folds': [
              {..._foldJson(id: 11), 'tileId': 7, 'contributor': 'bob'},
              {..._foldJson(id: 12), 'tileId': 8, 'contributor': 'alice'},
              {..._foldJson(id: 13), 'tileId': 8, 'contributor': ''},
            ],
          },
        );
        final container = containerFor(backend);

        final view = await container.read(
          atlasRegionProvenanceProvider(1).future,
        );

        expect(view, isNotNull);
        // Deepest tile is 8 — its two folds become the trail; tile-7 fold excluded.
        expect(view!.tileId, 8);
        expect(view.coverageMean, 0.95);
        expect(view.folds, hasLength(2));
        expect(view.contributors, contains('alice'));
        expect(view.contributors, isNot(contains('bob')));
      },
    );

    test('atlasRegionCutoutProvider returns portable host PNG bytes', () async {
      final backend = slaveBackend();
      final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
      when(() => backend.getAtlasRegionCutout(1)).thenAnswer((_) async => png);
      final container = containerFor(backend);

      final cutout = await container.read(atlasRegionCutoutProvider(1).future);

      // The slave path must carry portable BYTES (Image.memory), never a
      // host-local file path that can't cross the wire.
      expect(cutout.bytes, png);
      expect(cutout.filePath, isNull);
      verify(() => backend.getAtlasRegionCutout(1)).called(1);
    });
  });

  group(
    'Pillar B (First Light) — slave reads host candidates, not empty DB',
    () {
      test('firstLightCandidatesProvider returns the host feed', () async {
        final backend = slaveBackend();
        when(() => backend.getFirstLightCandidates()).thenAnswer(
          (_) async => [
            _candidate(id: 7, reviewed: false),
            _candidate(id: 8, reviewed: true),
          ],
        );
        final container = containerFor(backend);

        // Keep an active listener so the snapshot stream resolves like the UI.
        container.listen(firstLightCandidatesProvider, (_, _) {});
        final rows = await container.read(firstLightCandidatesProvider.future);

        expect(rows.map((r) => r.id), [7, 8]);
        verify(() => backend.getFirstLightCandidates()).called(1);
      });

      test(
        'firstLightCropProvider returns the host real-pixel stamp',
        () async {
          final backend = slaveBackend();
          final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4]);
          when(
            () => backend.getFirstLightCrop(7, 'residual'),
          ).thenAnswer((_) async => png);
          final container = containerFor(backend);

          final bytes = await container.read(
            firstLightCropProvider((
              detectionId: 7,
              tileId: 42,
              raDeg: 120.0,
              decDeg: 25.0,
              stage: 'residual',
            )).future,
          );

          expect(bytes, png);
          verify(() => backend.getFirstLightCrop(7, 'residual')).called(1);
        },
      );
    },
  );
}
