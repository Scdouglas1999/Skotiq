// Follow-the-night id namespace.
//
// The follow-the-night sweep queries the hub's handoff baton by target id.
// Those ids MUST be true hub `shared_targets.id` values (the joined
// `SharedTarget`s). A local `db.Target.id` is a private autoincrement that is
// NOT a hub id — and both are small ints, so a local id in the query set can
// collide with a DIFFERENT hub target and take the baton for the wrong sky,
// which is the double-collect the feature exists to prevent.
//
// Pins:
//   * only JOINED hub ids are ever queried (a local-only id is never queried),
//   * a local id that collides with a different hub target's id is NOT queried,
//   * display name/coords come from the hub row, name-enriched from a local
//     target only when the NAMES match (never by id-equality).

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
  late List<int> queriedHandoffIds;

  // The user has JOINED exactly one hub target: Orion, hub id 7.
  const orion = SharedTarget(
    targetId: 7,
    name: 'Orion',
    raDeg: 83.6,
    decDeg: -5.4,
    contributors: 3,
    integrationSeconds: 7200.0,
    activeTileId: 1234,
  );

  ConstellationService buildService({
    required List<({int targetId, String name, double raDeg, double decDeg})>
    locals,
  }) {
    final atlas = SkyAtlasService(
      dao: atlasDao,
      seam: _Seam(),
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/constellation_ftn_test',
      order: ConstellationService.defaultHealpixOrder,
    );
    return ConstellationService(
      atlas: atlas,
      logger: LoggingService(),
      credentialsResolver: () async => ConstellationCredentials(
        hubBaseUrl: Uri.parse('https://hub.example.org/'),
        bearerToken: 'tok',
      ),
      localTargetsResolver: () async => locals,
      clientFactory: (creds) {
        final mock = MockClient((request) async {
          final path = request.url.path;
          // GET /v1/handoff/{targetId}
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
    queriedHandoffIds = [];
  });

  tearDown(() => db.close());

  test(
    'only joined hub ids are queried — a local-only id is never queried',
    () async {
      // A local target whose db id (999) is NOT a joined hub target.
      final service = buildService(
        locals: const [(targetId: 999, name: 'M31', raDeg: 10.7, decDeg: 41.3)],
      )..joinSharedTarget(orion);

      final suggestions = await service.followTheNight();

      // Exactly the one joined hub id was queried; the local id 999 never was.
      expect(queriedHandoffIds, [7]);
      expect(queriedHandoffIds, isNot(contains(999)));
      expect(suggestions, hasLength(1));
      expect(suggestions.single.targetId, 7);
      expect(suggestions.single.targetName, 'Orion');
    },
  );

  test('a local id colliding with a DIFFERENT hub id is not queried (no '
      'wrong-target baton)', () async {
    // The collision: a LOCAL target row carries db id 7 — the same int as the
    // joined hub target Orion — but it is a different sky (M42 region). #7 must
    // be queried exactly once, for the real joined hub target; the local id-7
    // row contributes nothing to the candidate set.
    final service = buildService(
      locals: const [
        (targetId: 7, name: 'M42 Trapezium', raDeg: 83.8, decDeg: -5.39),
      ],
    )..joinSharedTarget(orion);

    final suggestions = await service.followTheNight();

    // #7 queried once and only once (from the joined hub row, not the local).
    expect(queriedHandoffIds, [7]);
    expect(suggestions, hasLength(1));
    // The suggestion describes the HUB's Orion, never the colliding local M42.
    expect(suggestions.single.targetId, 7);
    expect(suggestions.single.targetName, 'Orion');
    expect(suggestions.single.raDeg, 83.6);
    expect(suggestions.single.decDeg, -5.4);
  });

  test('display name is enriched from a NAME-matched local target only', () async {
    // A local target with a matching name but an unrelated db id (42). Geometry
    // still comes from the hub; only a same-name local participates, and never
    // via its id.
    final service = buildService(
      locals: const [(targetId: 42, name: 'orion', raDeg: 0.0, decDeg: 0.0)],
    )..joinSharedTarget(orion);

    final suggestions = await service.followTheNight();

    expect(queriedHandoffIds, [7]);
    expect(suggestions.single.targetId, 7);
    // Hub name preferred; hub geometry authoritative regardless of the local row.
    expect(suggestions.single.targetName, 'Orion');
    expect(suggestions.single.raDeg, 83.6);
    expect(suggestions.single.decDeg, -5.4);
  });

  test('no joined targets → empty sweep, nothing queried', () async {
    final service = buildService(
      locals: const [
        (targetId: 1, name: 'M81', raDeg: 148.9, decDeg: 69.1),
        (targetId: 2, name: 'M82', raDeg: 148.97, decDeg: 69.68),
      ],
    );

    final suggestions = await service.followTheNight();

    expect(suggestions, isEmpty);
    expect(queriedHandoffIds, isEmpty);
  });
}
