// Pillar C ("Constellation") — pull-and-blend path test.
//
// "Pull & blend into Your Sky" has to fold the downloaded community tile into
// the local atlas: the UI-reachable pull requests the additive `.nst`
// accumulator (`finalized: false`) so the service calls
// SkyAtlasService.mergeSwarmDelta. The finalized FITS pull is a display-only
// blob with no consumer and must NOT be merged.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_core/skotiq_core.dart';

/// Recording fake seam: serves `coverage` (one tile in cone) and `info`
/// (post-merge index refresh), and records every `mergeDelta` call so the test
/// can assert the blend ran (or did not).
class _FakeSkyAtlasSeam implements SkyAtlasSeam {
  final List<Map<String, dynamic>> merged = [];

  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async {
    switch (args['action']) {
      case 'coverage':
        return {
          'ok': true,
          'tiles': [
            {
              'tileId': 1234,
              'centerRa': 83.6,
              'centerDec': -5.4,
              'coverageMean': 0.8,
              'totalFrames': 10,
              'integrationSeconds': 3000.0,
              'channels': 1,
            },
          ],
        };
      case 'info':
        return {
          'ok': true,
          'centerRa': 83.6,
          'centerDec': -5.4,
          'channels': 1,
          'coverageMean': 0.9,
          'provenance': {'totalFrames': 42, 'contributors': []},
        };
      default:
        return {'ok': true};
    }
  }

  @override
  Future<Map<String, dynamic>> mergeDelta(Map<String, dynamic> args) async {
    merged.add(args);
    return {
      'ok': true,
      'totalFramesAfter': 42,
      'integrationSecondsAfter': 1200.0,
      'contributorsAfter': 2,
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
}

void main() {
  late Directory tempRoot;
  late _FakeSkyAtlasSeam seam;
  late SkotiqDatabase db;
  late SkyAtlasService atlas;

  // A swarm target whose centre sits on the seeded local tile, so the cone
  // search finds tile 1234 to pull.
  const target = SharedTarget(
    targetId: 7,
    name: 'Orion',
    raDeg: 83.6,
    decDeg: -5.4,
    contributors: 3,
    integrationSeconds: 7200.0,
    activeTileId: 1234,
  );

  ConstellationService buildService() {
    return ConstellationService(
      atlas: atlas,
      logger: LoggingService(),
      credentialsResolver: () async => ConstellationCredentials(
        hubBaseUrl: Uri.parse('https://hub.example.org'),
        bearerToken: 'tok-123',
      ),
      localTargetsResolver: () async => const [],
      clientFactory: (creds) {
        final mock = MockClient((request) async {
          // Serve a tiny tile blob for the pull.
          return http.Response.bytes([1, 2, 3, 4], 200);
        });
        return ConstellationClient(
          hubBaseUrl: creds.hubBaseUrl,
          bearerToken: creds.bearerToken,
          client: mock,
        );
      },
    );
  }

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('constellation_blend');
    seam = _FakeSkyAtlasSeam();
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    atlas = SkyAtlasService(
      dao: SkyAtlasDao(db),
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

  test(
    'pullTarget(finalized: false) folds the community delta into the atlas',
    () async {
      final service = buildService();
      service.joinSharedTarget(target);

      final tiles = await service.pullTarget(target.targetId, finalized: false);

      expect(tiles, hasLength(1));
      // The blend ran: mergeDelta was invoked for the pulled tile.
      expect(seam.merged, hasLength(1));
      expect(seam.merged.single['subtract'], isFalse);
      // The returned SwarmTile reflects the merged frame total (proof the fold
      // result fed back into "Your Sky"), not a display-only zero.
      expect(tiles.single.totalFrames, 42);
      expect(tiles.single.finalized, isFalse);
    },
  );

  test(
    'pullTarget(finalized: true) caches a display-only blob and does NOT blend',
    () async {
      final service = buildService();
      service.joinSharedTarget(target);

      final tiles = await service.pullTarget(target.targetId, finalized: true);

      expect(tiles, hasLength(1));
      // No merge on the finalized FITS path — it is a display-only overlay.
      expect(seam.merged, isEmpty);
      expect(tiles.single.totalFrames, 0);
      expect(tiles.single.finalized, isTrue);
    },
  );
}
