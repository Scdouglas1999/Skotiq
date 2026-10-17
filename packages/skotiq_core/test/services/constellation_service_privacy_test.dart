// Pillar C ("Constellation") — privacy plumbing for contributeTarget().
//
// Pins the SUBS (raw subframe) behaviour now that the path is real:
//   * SUMS (default) keeps its existing additive-sums path.
//   * SUBS against a hub that DOES NOT advertise acceptsRawSubs is refused up
//     front (no per-frame pixel leak to a 405-ing hub).
//   * SUBS against an opt-in hub streams the user's own light FITS, one
//     pushSubframe per resolved frame, and never falls back to sums.
//   * SUBS with no host resolver (a slave) is refused — only the host's own
//     pixels can ever be shared.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Minimal seam — the SUMS no-coverage path never reaches the bridge.
class _StubSeam implements SkyAtlasSeam {
  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async => {
    'ok': true,
  };

  @override
  Future<Map<String, dynamic>> queryCutout(Map<String, dynamic> args) async => {
    'ok': true,
  };

  @override
  Future<Map<String, dynamic>> regionInfo(Map<String, dynamic> args) async => {
    'ok': true,
    'tilesWithData': 0,
  };

  @override
  Future<Map<String, dynamic>> growth(Map<String, dynamic> args) async => {
    'ok': true,
    'points': const [],
    'totalFrames': 0,
  };

  @override
  Future<Map<String, dynamic>> mergeDelta(Map<String, dynamic> args) async => {
    'ok': true,
  };
}

void main() {
  late SkotiqDatabase db;
  late SkyAtlasService atlas;
  late Directory tmp;

  const target = SharedTarget(
    targetId: 1,
    name: 'M31',
    raDeg: 10.68,
    decDeg: 41.27,
    contributors: 3,
    integrationSeconds: 7200,
    activeTileId: 4242,
  );

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('cns_privacy_');
    atlas = SkyAtlasService(
      dao: SkyAtlasDao(db),
      seam: _StubSeam(),
      logger: LoggingService(),
      atlasRootResolver: () async => tmp.path,
    );
  });

  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  /// Build a service whose hub is served by [mock], with the given raw-sub
  /// resolver (null = a slave / pre-SUBS wiring).
  ConstellationService serviceWith(
    MockClient mock, {
    RawSubframeResolver? resolver,
  }) {
    final service = ConstellationService(
      atlas: atlas,
      logger: LoggingService(),
      credentialsResolver: () async => ConstellationCredentials(
        hubBaseUrl: Uri.parse('https://hub.example.org'),
        bearerToken: 'tok',
      ),
      localTargetsResolver: () async => const [],
      clientFactory: (creds) => ConstellationClient(
        hubBaseUrl: creds.hubBaseUrl,
        bearerToken: creds.bearerToken,
        client: mock,
      ),
      rawSubframeResolver: resolver,
    );
    service.joinSharedTarget(target);
    return service;
  }

  http.Response infoResp({required bool acceptsRawSubs}) => http.Response(
    jsonEncode({
      'name': 'Backyard Hub',
      'fingerprint': 'abc',
      'version': '5.0.0',
      'healpixOrder': 9,
      'tilePixels': 1024,
      'selfHosted': true,
      'acceptsRawSubs': acceptsRawSubs,
    }),
    200,
  );

  test(
    'SUMS (default) follows the existing sums path (empty cone → no-op)',
    () async {
      final service = serviceWith(
        MockClient((_) async => http.Response('', 404)),
      );
      final outcome = await service.contributeTarget(target.targetId);
      expect(outcome.acceptedCount, 0);
      expect(outcome.rejectedCount, 0);
    },
  );

  test(
    'SUBS is refused against a hub that does not accept raw subframes',
    () async {
      final mock = MockClient((req) async {
        if (req.url.path.endsWith('/v1/info')) {
          return infoResp(acceptsRawSubs: false);
        }
        return http.Response('unexpected', 500);
      });
      final service = serviceWith(
        mock,
        resolver: (_) async => const [
          RawSubframe(
            filePath: '/does/not/matter.fits',
            capturedImageId: 1,
            exposureSeconds: 120,
          ),
        ],
      );
      await expectLater(
        service.contributeTarget(
          target.targetId,
          privacy: ConstellationPrivacy.subs,
        ),
        throwsA(
          isA<ConstellationException>()
              .having((e) => e.kind, 'kind', ConstellationErrorKind.conflict)
              .having((e) => e.message, 'message', contains('raw subframes')),
        ),
      );
    },
  );

  test(
    'SUBS with no resolver (a slave) is refused — only host pixels share',
    () async {
      final service = serviceWith(
        MockClient((_) async => infoResp(acceptsRawSubs: true)),
      );
      await expectLater(
        service.contributeTarget(
          target.targetId,
          privacy: ConstellationPrivacy.subs,
        ),
        throwsA(isA<ConstellationException>()),
      );
    },
  );

  test(
    'SUBS against an opt-in hub streams each own light FITS, never sums',
    () async {
      // Two real FITS-ish files on disk for the resolver to stream.
      final f1 = File('${tmp.path}/light1.fits')
        ..writeAsBytesSync(utf8.encode('SIMPLE = T / frame one'));
      final f2 = File('${tmp.path}/light2.fits')
        ..writeAsBytesSync(utf8.encode('SIMPLE = T / frame two longer'));

      final subPosts = <Uri>[];
      final bodies = <int>[];
      var contribCount = 0;
      final mock = MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/v1/info')) return infoResp(acceptsRawSubs: true);
        if (path.contains('/subframes')) {
          subPosts.add(req.url);
          bodies.add(req.bodyBytes.length);
          return http.Response(
            jsonEncode({
              'contributionId': 'sub-$contribCount',
              'accepted': true,
              'storedBytes': req.bodyBytes.length,
            }),
            200,
          );
        }
        if (path.contains('/contributions')) {
          contribCount++; // a sums push — must NEVER happen on the SUBS path
          return http.Response('{}', 200);
        }
        return http.Response('unexpected $path', 500);
      });

      final service = serviceWith(
        mock,
        resolver: (_) async => [
          RawSubframe(
            filePath: f1.path,
            capturedImageId: 11,
            exposureSeconds: 60,
          ),
          RawSubframe(
            filePath: f2.path,
            capturedImageId: 12,
            exposureSeconds: 120,
          ),
        ],
      );

      final outcome = await service.contributeTarget(
        target.targetId,
        privacy: ConstellationPrivacy.subs,
      );

      // One subframe POST per frame, attributed to the joined active tile, and
      // NOT a single additive-sums contribution.
      expect(subPosts, hasLength(2));
      expect(contribCount, 0);
      expect(outcome.acceptedCount, 2);
      expect(outcome.accepted[11]!.contributionId, isNotEmpty);
      expect(outcome.accepted[12]!.contributionId, isNotEmpty);
      // The streamed bodies match the on-disk file sizes (real bytes shipped).
      expect(bodies, containsAll(<int>[f1.lengthSync(), f2.lengthSync()]));
      // Provenance + tile rode on the query.
      expect(
        subPosts.first.path,
        contains('/tiles/${target.activeTileId}/subframes'),
      );
      expect(subPosts.first.queryParameters['order'], '9');
      expect(subPosts.first.queryParameters['capturedImageId'], isNotNull);
    },
  );
}
