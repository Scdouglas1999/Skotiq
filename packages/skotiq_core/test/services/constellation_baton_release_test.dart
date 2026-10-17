// Pillar C ("Constellation") — baton RELEASE affordance + held-by-me flag.
//
// The follow-the-night sweep must mark a suggestion `heldByMe` when the hub's
// baton `holder` account id matches THIS user's registered account id (resolved
// via the injected accountIdResolver), so the card can offer "Release" instead
// of "Take the baton". A held target sorts ahead of free ones so Release is easy
// to find. `releaseHandoff` must hit the hub's POST /handoff/{id}/release route.
//
// Pins:
//   * holder == my account id  -> heldByMe == true (and sorts first),
//   * holder == someone else   -> heldByMe == false,
//   * no accountIdResolver     -> heldByMe == false (never crashes),
//   * releaseHandoff posts to the right release path with the target id.

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
  late List<({String method, String path})> calls;

  // Two joined hub targets: Orion (id 7) and Rosette (id 9). The mock hub
  // reports Orion held by `me-123` and Rosette held by `someone-else`.
  const orion = SharedTarget(
    targetId: 7,
    name: 'Orion',
    raDeg: 83.6,
    decDeg: -5.4,
    contributors: 3,
    integrationSeconds: 7200.0,
    activeTileId: 1234,
  );
  const rosette = SharedTarget(
    targetId: 9,
    name: 'Rosette',
    raDeg: 98.0,
    decDeg: 4.9,
    contributors: 2,
    integrationSeconds: 3600.0,
    activeTileId: 5678,
  );

  ConstellationService buildService({String? myAccountId}) {
    final atlas = SkyAtlasService(
      dao: atlasDao,
      seam: _Seam(),
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/constellation_release_test',
      order: ConstellationService.defaultHealpixOrder,
    );
    return ConstellationService(
      atlas: atlas,
      logger: LoggingService(),
      credentialsResolver: () async => ConstellationCredentials(
        hubBaseUrl: Uri.parse('https://hub.example.org/'),
        bearerToken: 'tok',
      ),
      accountIdResolver: () async => myAccountId,
      localTargetsResolver: () async => const [],
      clientFactory: (creds) {
        final mock = MockClient((request) async {
          calls.add((method: request.method, path: request.url.path));
          final path = request.url.path;
          if (request.method == 'GET' && path.contains('/handoff/')) {
            final id = int.parse(path.split('/').last);
            final holder = id == 7 ? 'me-123' : 'someone-else';
            return http.Response(
              jsonEncode({
                'targetId': id,
                'activeTileId': id == 7 ? 1234 : 5678,
                'holder': holder,
                'altitudeOk': true,
              }),
              200,
            );
          }
          if (request.method == 'POST' && path.endsWith('/release')) {
            return http.Response(jsonEncode({'released': true}), 200);
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
    calls = [];
  });

  tearDown(() => db.close());

  test(
    'a baton held by my account id is flagged heldByMe and sorts first',
    () async {
      final service = buildService(myAccountId: 'me-123')
        ..joinSharedTarget(rosette)
        ..joinSharedTarget(orion);

      final suggestions = await service.followTheNight();

      expect(suggestions, hasLength(2));
      // Orion (held by me) sorts ahead of Rosette (held by someone else).
      expect(suggestions.first.targetId, 7);
      expect(suggestions.first.heldByMe, isTrue);
      final rosetteSuggestion = suggestions.firstWhere((s) => s.targetId == 9);
      expect(rosetteSuggestion.heldByMe, isFalse);
    },
  );

  test('no account-id resolver means nothing is heldByMe (no crash)', () async {
    final service = buildService()..joinSharedTarget(orion);

    final suggestions = await service.followTheNight();

    expect(suggestions, hasLength(1));
    expect(suggestions.single.heldByMe, isFalse);
  });

  test(
    'releaseHandoff posts to the hub release route for the target',
    () async {
      final service = buildService(myAccountId: 'me-123');

      await service.releaseHandoff(7);

      expect(calls, contains((method: 'POST', path: '/v1/handoff/7/release')));
    },
  );
}
