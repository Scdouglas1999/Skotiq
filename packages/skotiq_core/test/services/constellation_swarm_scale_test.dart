// Pillar C ("Constellation") — Wave 3 swarm-scale hardening.
//
// Pins the two Track-C scale fixes:
//   * cone tile-selection is index-backed (Dec-band prefilter on
//     idx_sky_tiles_dec, then the exact great-circle test) — bounded by the
//     cone, not the whole atlas, and still CORRECT (it must pick exactly the
//     in-cone tiles and exclude same-Dec-band-but-far-RA and out-of-band tiles);
//   * sweepSwarmBlobs reclaims accumulated swarm .nst/.fits blobs by age/space
//     but NEVER deletes the live overlay backing a currently-pulled tile.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_core/skotiq_core.dart';

/// Seam that records every exportDelta tileId so the cone test can assert which
/// tiles the index-backed selection chose. `coverage` is the full-scan
/// fallback; these tests seed the DB index, so it must never be consulted for
/// an atlas that has folded tiles.
class _RecordingSeam implements SkyAtlasSeam {
  final List<int> exportedTileIds = [];
  var coverageScanned = false;

  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async {
    switch (args['action']) {
      case 'coverage':
        coverageScanned = true;
        return {'ok': true, 'tiles': const []};
      case 'exportDelta':
        exportedTileIds.add(args['tileId'] as int);
        final outPath = args['outPath'] as String;
        final f = File(outPath);
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(const [1, 2, 3, 4]);
        return {
          'ok': true,
          'outPath': outPath,
          'framesInDelta': 4,
          'integrationSeconds': 1200.0,
        };
      default:
        return {'ok': true};
    }
  }

  @override
  Future<Map<String, dynamic>> mergeDelta(Map<String, dynamic> args) async => {
    'ok': true,
    'totalFramesAfter': 7,
  };

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
}

void main() {
  late Directory tempRoot;
  late SkotiqDatabase db;
  late SkyAtlasDao atlasDao;
  late LivingSkyRetentionDao retentionDao;
  late _RecordingSeam seam;
  late SkyAtlasService atlas;

  // Cone centred on Orion (RA 83.6, Dec -5.4), radius 1.5 deg.
  const target = SharedTarget(
    targetId: 7,
    name: 'Orion',
    raDeg: 83.6,
    decDeg: -5.4,
    contributors: 3,
    integrationSeconds: 7200.0,
    activeTileId: 1000,
  );

  ConstellationService buildService() {
    return ConstellationService(
      atlas: atlas,
      logger: LoggingService(),
      retentionDao: retentionDao,
      credentialsResolver: () async => ConstellationCredentials(
        hubBaseUrl: Uri.parse('https://hub.example.org/'),
        bearerToken: 'tok',
      ),
      localTargetsResolver: () async => const [],
      clientFactory: (creds) {
        final mock = MockClient((request) async {
          // Accept any pushTile; echo a minimal receipt.
          return http.Response(
            '{"contributionId":"c1","accepted":true,"trustApplied":1.0,'
            '"totalFramesAfter":4,"integrationSecondsAfter":1200.0}',
            200,
          );
        });
        return ConstellationClient(
          hubBaseUrl: creds.hubBaseUrl,
          bearerToken: creds.bearerToken,
          client: mock,
        );
      },
    );
  }

  Future<int> seedTile({
    required int tileId,
    required double centerRaDeg,
    required double centerDecDeg,
  }) {
    return atlasDao.upsertTile(
      tileId: tileId,
      channels: 1,
      centerRaDeg: centerRaDeg,
      centerDecDeg: centerDecDeg,
      coverageMean: 0.8,
      totalFrames: 10,
      integrationSeconds: 3000.0,
      sidecarPath: 'tile_$tileId.nst',
    );
  }

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('constellation_swarm');
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    atlasDao = SkyAtlasDao(db);
    retentionDao = LivingSkyRetentionDao(db);
    seam = _RecordingSeam();
    atlas = SkyAtlasService(
      dao: atlasDao,
      seam: seam,
      logger: LoggingService(),
      atlasRootResolver: () async => tempRoot.path,
      order: ConstellationService.defaultHealpixOrder,
    );
  });

  tearDown(() async {
    await db.close();
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('index-backed cone selection', () {
    test(
      'selects exactly the in-cone tile and excludes far-RA + out-of-band tiles',
      () async {
        // IN cone (≈0 deg from centre).
        await seedTile(tileId: 1000, centerRaDeg: 83.6, centerDecDeg: -5.4);
        // Same Dec band but far in RA (~10 deg away) — passes the SQL band,
        // must be rejected by the exact great-circle test.
        await seedTile(tileId: 1001, centerRaDeg: 93.6, centerDecDeg: -5.4);
        // Out of the Dec band entirely (Dec +40) — must never be a candidate.
        await seedTile(tileId: 1002, centerRaDeg: 83.6, centerDecDeg: 40.0);

        final service = buildService()..joinSharedTarget(target);
        final outcome = await service.contributeTarget(
          target.targetId,
          radiusDeg: 1.5,
        );

        // Only the in-cone tile was exported + pushed.
        expect(seam.exportedTileIds, [1000]);
        expect(outcome.accepted.keys, [1000]);
        // The DB index served the cone; the native full-scan was NOT consulted.
        expect(seam.coverageScanned, isFalse);
      },
    );

    test('RA-wrap cone near 0h still finds tiles on both sides', () async {
      // Centre at RA 0.5, Dec 0; a tile at RA 359.5 is only ~1 deg away across
      // the 0/360 wrap and must be selected by the haversine test.
      await seedTile(tileId: 2000, centerRaDeg: 0.5, centerDecDeg: 0.0);
      await seedTile(tileId: 2001, centerRaDeg: 359.5, centerDecDeg: 0.0);
      // A genuinely distant tile in the same Dec band must be excluded.
      await seedTile(tileId: 2002, centerRaDeg: 180.0, centerDecDeg: 0.0);

      final tiles = await atlas.tilesInCone(
        centerRaDeg: 0.5,
        centerDecDeg: 0.0,
        radiusDeg: 1.5,
      );

      final ids = tiles.map((t) => t.tileId).toSet();
      expect(ids, {2000, 2001});
    });

    test('empty Dec band falls back to the native coverage scan', () async {
      // No tiles in the DB index → tilesInCone must fall back to coverage() so
      // a native-only wiring still resolves the cone (behaviour-preserving).
      final tiles = await atlas.tilesInCone(
        centerRaDeg: 83.6,
        centerDecDeg: -5.4,
        radiusDeg: 1.5,
      );
      expect(tiles, isEmpty);
      expect(seam.coverageScanned, isTrue);
    });
  });

  group('sweepSwarmBlobs', () {
    Future<File> writeBlob(String name, {required DateTime modified}) async {
      final dir = Directory(
        '${tempRoot.path}/swarm/'
        '${ConstellationService.defaultHealpixOrder}',
      );
      dir.createSync(recursive: true);
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(const [1, 2, 3, 4]);
      f.setLastModifiedSync(modified);
      return f;
    }

    test('reclaims aged blobs but keeps the live overlay', () async {
      final now = DateTime.now();
      // An old stale blob (30 days) for a tile NOT currently pulled.
      final stale = await writeBlob(
        'tile_9001_9.nst',
        modified: now.subtract(const Duration(days: 30)),
      );
      // A recent blob (1 day) — within the age window, must survive.
      final fresh = await writeBlob(
        'tile_9002_9.fits',
        modified: now.subtract(const Duration(days: 1)),
      );
      // An OLD blob that is the LIVE overlay for a currently-pulled tile — must
      // survive regardless of age.
      final liveOverlay = await writeBlob(
        'tile_9003_9.nst',
        modified: now.subtract(const Duration(days: 90)),
      );

      // Seed the live tile so 9003 is registered in _swarm via a real pull.
      await seedTile(tileId: 9003, centerRaDeg: 83.6, centerDecDeg: -5.4);
      final service = buildService()..joinSharedTarget(target);

      // Pull tile 9003 so its blob path is the live overlay. The pull rewrites
      // the blob, so re-stamp it old afterwards to prove age does not evict it.
      await service.pullTarget(target.targetId, finalized: false);
      expect(
        service.swarmTiles.map((t) => t.tileId),
        contains(9003),
        reason: 'tile 9003 should be a live overlay after pull',
      );
      // Re-age the live overlay file written by the pull.
      File(
        liveOverlay.path,
      ).setLastModifiedSync(now.subtract(const Duration(days: 90)));

      final deleted = await service.sweepSwarmBlobs(
        maxAge: const Duration(days: 14),
      );

      expect(deleted, 1, reason: 'only the un-pulled stale blob is reclaimed');
      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(
        File(liveOverlay.path).existsSync(),
        isTrue,
        reason: 'the live overlay must never be swept',
      );

      // The retention marker advanced.
      final marker = await retentionDao.getMarker(
        LivingSkyRetentionScope.swarmBlobs,
      );
      expect(marker, isNotNull);
      expect(marker!.prunedCount, 1);
      expect(marker.lastPrunedAt, isNotNull);
    });

    test(
      'byte budget evicts oldest survivors LRU, sparing the live overlay',
      () async {
        final now = DateTime.now();
        // Three fresh (within age) blobs, each 4 bytes; oldest mtime first.
        await writeBlob(
          'tile_8001_9.nst',
          modified: now.subtract(const Duration(hours: 3)),
        );
        await writeBlob(
          'tile_8002_9.nst',
          modified: now.subtract(const Duration(hours: 2)),
        );
        await writeBlob(
          'tile_8003_9.nst',
          modified: now.subtract(const Duration(hours: 1)),
        );

        final service = buildService();

        // maxBytes = 4 keeps exactly one blob; the two oldest are evicted.
        final deleted = await service.sweepSwarmBlobs(
          maxAge: const Duration(days: 365),
          maxBytes: 4,
        );

        expect(deleted, 2);
        final remaining = Directory(
          '${tempRoot.path}/swarm/'
          '${ConstellationService.defaultHealpixOrder}',
        ).listSync().whereType<File>().toList();
        expect(remaining, hasLength(1));
        // The newest (hours: 1) blob is the one kept.
        expect(remaining.single.path, endsWith('tile_8003_9.nst'));
      },
    );

    test('no swarm dir is a clean no-op', () async {
      final service = buildService();
      final deleted = await service.sweepSwarmBlobs();
      expect(deleted, 0);
    });
  });
}
