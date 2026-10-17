// Pillar C ("Constellation") — join-state restart survival.
//
// The follow-the-night sweep iterates ONLY joined targets, and Contribute/Pull
// unlock on join, so a joined-target map that lives purely in memory re-locks
// the federation and empties the baton feed on every app restart.
// `joinSharedTarget` persists a join-rehydration row (at a disjoint negative
// tileId so it can never collide with a real HEALPix tile receipt), and
// `rehydrateJoined` re-populates the map for the configured hub.
//
// Pins:
//   * a join survives a fresh service instance over the SAME db (rehydrated),
//   * the rehydrated membership feeds the follow-the-night sweep,
//   * `leaveSharedTarget` clears the persisted row so it does not resurrect,
//   * the join row never collides with a real tile receipt at the same int id.

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_core/skotiq_core.dart';

class _Seam implements SkyAtlasSeam {
  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async => {
    'ok': true,
  };

  @override
  Future<Map<String, dynamic>> mergeDelta(Map<String, dynamic> args) async => {
    'ok': true,
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
  late List<int> queriedHandoffIds;

  const orion = SharedTarget(
    targetId: 7,
    name: 'Orion',
    raDeg: 83.6,
    decDeg: -5.4,
    contributors: 3,
    integrationSeconds: 7200.0,
    activeTileId: 1234,
  );

  ConstellationService buildService() {
    final atlas = SkyAtlasService(
      dao: atlasDao,
      seam: _Seam(),
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/constellation_join_test',
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
          if (request.method == 'GET' && path.contains('/handoff/')) {
            final id = int.parse(path.split('/').last);
            queriedHandoffIds.add(id);
            return http.Response(
              jsonEncode({
                'targetId': id,
                'activeTileId': 1234,
                'holder': null,
                'altitudeOk': true,
              }),
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
    queriedHandoffIds = [];
  });

  tearDown(() => db.close());

  test(
    'a join survives a fresh service over the same db and feeds the sweep',
    () async {
      // Join on one service instance (e.g. before an app restart).
      final first = buildService();
      first.joinSharedTarget(orion);
      // Let the fire-and-forget persistence settle.
      await Future<void>.delayed(Duration.zero);

      // A brand-new service over the SAME db (the relaunch): memory is empty.
      final second = buildService();
      expect(second.joinedTargets, isEmpty);

      await second.rehydrateJoined();
      expect(second.joinedTargets.map((t) => t.targetId), [7]);
      expect(second.joinedTargets.single.name, 'Orion');

      // The rehydrated membership now drives follow-the-night.
      final suggestions = await second.followTheNight();
      expect(queriedHandoffIds, [7]);
      expect(suggestions.single.targetId, 7);
    },
  );

  test(
    'leaveSharedTarget clears the persisted row so it does not resurrect',
    () async {
      final first = buildService();
      first.joinSharedTarget(orion);
      await Future<void>.delayed(Duration.zero);
      first.leaveSharedTarget(7);
      await Future<void>.delayed(Duration.zero);

      final second = buildService();
      await second.rehydrateJoined();
      expect(second.joinedTargets, isEmpty);
    },
  );

  test(
    'the join row does not collide with a real tile receipt at the same int',
    () async {
      // A real contribution receipt for tile id 7 (non-negative HEALPix pixel).
      await contributionsDao.upsertContribution(
        'https://hub.example.org',
        7,
        contributionId: 'rcpt-7',
        contributedFrames: 12,
      );
      // Join hub target 7 — its join row keys at a DISJOINT negative tileId.
      final service = buildService();
      service.joinSharedTarget(orion);
      await Future<void>.delayed(Duration.zero);

      // The real receipt is untouched (still retractable with its id + frames).
      final receipt = await contributionsDao.getContribution(
        'https://hub.example.org',
        7,
      );
      expect(receipt, isNotNull);
      expect(receipt!.contributionId, 'rcpt-7');
      expect(receipt.contributedFrames, 12);
      expect(receipt.joined, isFalse); // the tile receipt was NOT marked joined

      // And rehydration still recovers the joined target.
      final fresh = buildService();
      await fresh.rehydrateJoined();
      expect(fresh.joinedTargets.map((t) => t.targetId), [7]);
    },
  );
}
