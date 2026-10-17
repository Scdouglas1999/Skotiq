// Pillar C ("Constellation") — Wave 2: hub seeding (proposeTarget) + real
// Retract on the Wave-0 persisted contributionId.
//
// Pins:
//   * proposeTarget POSTs /v1/targets and decodes the echoed client-facing
//     target, then joins it locally so contribute/pull resolve geometry,
//   * a contribution stamps a retractable receipt (contributionId) that
//     myContributions() surfaces,
//   * retractTile() looks up that id, DELETEs it on the hub, and clears the
//     local receipt so the high-water resets (next contribute re-anchors).

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_core/skotiq_core.dart';

/// Seam reporting one own-light tile in the cone with a configurable post-anchor
/// export tally, mirroring the high-water test harness.
class _Seam implements SkyAtlasSeam {
  final int exportFrames = 4;
  final double exportSeconds = 1200;

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
      case 'exportDelta':
        final outPath = args['outPath'] as String;
        final f = File(outPath);
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(const [1, 2, 3, 4]);
        return {
          'ok': true,
          'outPath': outPath,
          'framesInDelta': exportFrames,
          'integrationSeconds': exportSeconds,
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
  late SkotiqDatabase db;
  late SkyAtlasDao atlasDao;
  late ConstellationContributionsDao contributionsDao;
  late List<String> deletedContributionIds;

  const target = SharedTarget(
    targetId: 7,
    name: 'Orion',
    raDeg: 83.6,
    decDeg: -5.4,
    contributors: 3,
    integrationSeconds: 7200.0,
    activeTileId: 1234,
  );

  ConstellationService buildService(_Seam seam) {
    final atlas = SkyAtlasService(
      dao: atlasDao,
      seam: seam,
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/constellation_seed_retract_test',
      order: ConstellationService.defaultHealpixOrder,
    );
    return ConstellationService(
      atlas: atlas,
      logger: LoggingService(),
      contributionsDao: contributionsDao,
      credentialsResolver: () async => ConstellationCredentials(
        hubBaseUrl: Uri.parse('https://hub.example.org/'),
        bearerToken: 'tok',
      ),
      localTargetsResolver: () async => const [],
      clientFactory: (creds) {
        final mock = MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'POST' && path.endsWith('/v1/targets')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'targetId': 42,
                'target': {
                  'targetId': 42,
                  'name': body['name'],
                  'raDeg': body['centerRaDeg'],
                  'decDeg': body['centerDecDeg'],
                  'integrationSeconds': 0.0,
                  'contributors': 1,
                  'activeTileId': 1234,
                },
              }),
              201,
            );
          }
          if (request.method == 'POST' && path.contains('/contributions')) {
            return http.Response(
              jsonEncode({
                'contributionId': 'ctr-1',
                'accepted': true,
                'totalFramesAfter': 104,
              }),
              201,
            );
          }
          if (request.method == 'DELETE' && path.contains('/contributions/')) {
            deletedContributionIds.add(path.split('/').last);
            return http.Response(
              jsonEncode({'retracted': true, 'totalFramesAfter': 100}),
              200,
            );
          }
          return http.Response('{}', 200);
        });
        return ConstellationClient(
          hubBaseUrl: creds.hubBaseUrl,
          bearerToken: creds.bearerToken,
          client: mock,
        );
      },
    );
  }

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    atlasDao = SkyAtlasDao(db);
    contributionsDao = ConstellationContributionsDao(db);
    deletedContributionIds = [];
  });

  tearDown(() => db.close());

  test(
    'proposeTarget POSTs /v1/targets, decodes + joins the new target',
    () async {
      final service = buildService(_Seam());

      final created = await service.proposeTarget(
        name: 'My Field',
        raDeg: 83.6,
        decDeg: -5.4,
      );

      expect(created.targetId, 42);
      expect(created.name, 'My Field');
      expect(created.raDeg, 83.6);
      // Joined locally so contribute/pull can resolve its geometry.
      expect(service.joinedTargets.any((t) => t.targetId == 42), isTrue);
    },
  );

  test(
    'contribute stamps a retractable receipt myContributions surfaces',
    () async {
      final service = buildService(_Seam())..joinSharedTarget(target);

      await service.contributeTarget(target.targetId);

      final records = await service.myContributions();
      expect(records, hasLength(1));
      expect(records.single.tileId, 1234);
      expect(records.single.contributionId, 'ctr-1');
      expect(records.single.contributedFrames, 4);
    },
  );

  test(
    'retractTile DELETEs the persisted id and clears the local receipt',
    () async {
      final service = buildService(_Seam())..joinSharedTarget(target);
      await service.contributeTarget(target.targetId);

      final receipt = await service.retractTile(1234);

      expect(receipt.retracted, isTrue);
      expect(receipt.totalFramesAfter, 100);
      // The hub was asked to subtract exactly the stored receipt id.
      expect(deletedContributionIds, ['ctr-1']);
      // The local receipt is gone so the next contribute re-anchors from epoch.
      final row = await contributionsDao.getContribution(
        'https://hub.example.org',
        1234,
        healpixOrder: 9,
      );
      expect(row, isNull);
      expect(await service.myContributions(), isEmpty);
    },
  );

  test('retractTile throws when there is no recorded contribution', () async {
    final service = buildService(_Seam())..joinSharedTarget(target);

    await expectLater(
      service.retractTile(9999),
      throwsA(
        isA<ConstellationException>().having(
          (e) => e.kind,
          'kind',
          ConstellationErrorKind.notFound,
        ),
      ),
    );
  });
}
