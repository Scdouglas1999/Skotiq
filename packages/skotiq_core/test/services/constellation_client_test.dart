// Pillar C ("Constellation") — hub client unit tests against a fake HTTP layer.
//
// Verifies request shape (method, /v1 path, bearer auth, order query), JSON
// decode of each typed result, the binary tile blob round-trip to disk, the
// HTTP-status -> ConstellationException mapping (including 409 ->
// geometryMismatch), and the handoff 404 -> null contract. No network access:
// every request is served by `package:http/testing.dart`'s MockClient.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  final hub = Uri.parse('https://hub.example.org');

  ConstellationClient clientWith(MockClient mock) => ConstellationClient(
    hubBaseUrl: hub,
    bearerToken: 'tok-123',
    client: mock,
  );

  group('request shape', () {
    test('info issues GET /v1/info with bearer auth', () async {
      http.Request? seen;
      final mock = MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'name': 'Backyard Hub',
            'fingerprint': 'abc123',
            'version': '5.0.0',
            'healpixOrder': 9,
            'tilePixels': 1024,
            'selfHosted': true,
          }),
          200,
        );
      });

      final info = await clientWith(mock).info();

      expect(seen!.method, 'GET');
      expect(seen!.url.toString(), 'https://hub.example.org/v1/info');
      expect(seen!.headers['Authorization'], 'Bearer tok-123');
      expect(info.name, 'Backyard Hub');
      expect(info.healpixOrder, 9);
      expect(info.tilePixels, 1024);
      expect(info.selfHosted, isTrue);
    });

    test(
      'pushTile POSTs the .nst blob with order query + provenance headers',
      () async {
        final dir = await Directory.systemTemp.createTemp('nst_push');
        final delta = File('${dir.path}/delta_42.nst');
        await delta.writeAsBytes([9, 8, 7, 6]);

        http.Request? seen;
        final mock = MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'contributionId': 'c-1',
              'accepted': true,
              'trustApplied': 0.85,
              'totalFramesAfter': 130,
              'integrationSecondsAfter': 39000.0,
            }),
            201,
          );
        });

        final receipt = await clientWith(mock).pushTile(
          tileId: 42,
          order: 9,
          deltaPath: delta.path,
          license: 'cc-by',
          framesDelta: 30,
          integrationSecondsDelta: 9000.0,
          instrument: 'asi2600-fp',
          solver: 'astap',
        );

        expect(seen!.method, 'POST');
        expect(
          seen!.url.toString(),
          'https://hub.example.org/v1/tiles/42/contributions?order=9',
        );
        expect(seen!.headers['framesDelta'], '30');
        expect(seen!.headers['integrationSecondsDelta'], '9000.0');
        expect(seen!.headers['instrument'], 'asi2600-fp');
        expect(seen!.headers['solver'], 'astap');
        // The share carries its consented license + attribution choice.
        expect(seen!.headers['license'], 'cc-by');
        expect(seen!.headers['attributionConsent'], 'true');
        expect(seen!.bodyBytes, [9, 8, 7, 6]);
        expect(receipt.contributionId, 'c-1');
        expect(receipt.accepted, isTrue);
        expect(receipt.trustApplied, 0.85);
        expect(receipt.totalFramesAfter, 130);

        await dir.delete(recursive: true);
      },
    );

    test(
      'ensureTarget POSTs /v1/targets and decodes the echoed target',
      () async {
        http.Request? seen;
        final mock = MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'targetId': 42,
              'target': {
                'targetId': 42,
                'name': 'My Field',
                'raDeg': 83.6,
                'decDeg': -5.4,
                'integrationSeconds': 0.0,
                'contributors': 1,
                'activeTileId': 1234,
              },
            }),
            201,
          );
        });

        final target = await clientWith(mock).ensureTarget(
          name: 'My Field',
          centerRaDeg: 83.6,
          centerDecDeg: -5.4,
          radiusDeg: 1.5,
        );

        expect(seen!.method, 'POST');
        expect(seen!.url.toString(), 'https://hub.example.org/v1/targets');
        final body = jsonDecode(seen!.body) as Map<String, dynamic>;
        expect(body['name'], 'My Field');
        expect(body['centerRaDeg'], 83.6);
        expect(body['radiusDeg'], 1.5);
        expect(target.targetId, 42);
        expect(target.name, 'My Field');
        expect(target.raDeg, 83.6);
        expect(target.activeTileId, 1234);
      },
    );

    test('pullTile GETs the blob and writes it to disk', () async {
      final dir = await Directory.systemTemp.createTemp('nst_pull');
      final out = '${dir.path}/community_42.fits';

      http.Request? seen;
      final mock = MockClient((request) async {
        seen = request;
        return http.Response.bytes([1, 2, 3, 4, 5], 200);
      });

      final written = await clientWith(
        mock,
      ).pullTile(tileId: 42, order: 9, outPath: out, finalized: true);

      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://hub.example.org/v1/tiles/42?order=9&finalized=true',
      );
      expect(written, out);
      expect(await File(out).readAsBytes(), [1, 2, 3, 4, 5]);

      await dir.delete(recursive: true);
    });
  });

  // `_download` streams panel masters and stitched mosaic output straight to
  // disk — the largest artifacts in the system, and the ones an unattended
  // assembler pulls with nobody watching.
  group('large-artifact downloads', () {
    test('a hub that sends headers then stalls mid-body times out instead of '
        'hanging forever, and leaves no partial artifact behind', () async {
      final dir = await Directory.systemTemp.createTemp('nst_stall');
      final out = '${dir.path}/community_7.fits';
      final body = StreamController<List<int>>();
      addTearDown(() async {
        await body.close();
        await dir.delete(recursive: true);
      });

      // Headers arrive, one chunk arrives, then the hub goes silent.
      final mock = MockClient.streaming((request, _) async {
        body.add([1, 2, 3]);
        return http.StreamedResponse(body.stream, 200);
      });
      final client = ConstellationClient(
        hubBaseUrl: hub,
        bearerToken: 'tok-123',
        client: mock,
        timeout: const Duration(milliseconds: 150),
      );

      await expectLater(
        client.pullPanelMaster('m-7', 3, out),
        throwsA(
          isA<ConstellationException>().having(
            (e) => e.kind,
            'kind',
            ConstellationErrorKind.network,
          ),
        ),
      );
      expect(File(out).existsSync(), isFalse);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('a body that fails mid-stream deletes the truncated file', () async {
      final dir = await Directory.systemTemp.createTemp('nst_reset');
      final out = '${dir.path}/community_8.fits';
      addTearDown(() => dir.delete(recursive: true));

      Stream<List<int>> resetMidBody() async* {
        yield [1, 2, 3];
        throw const SocketException('connection reset by peer');
      }

      final mock = MockClient.streaming(
        (request, _) async => http.StreamedResponse(resetMidBody(), 200),
      );

      await expectLater(
        clientWith(mock).pullMosaicOutput('m-8', out),
        throwsA(
          isA<ConstellationException>().having(
            (e) => e.kind,
            'kind',
            ConstellationErrorKind.network,
          ),
        ),
      );
      expect(File(out).existsSync(), isFalse);
    });
  });

  group('handoff', () {
    test('queryHandoff maps 404 to null (no baton state)', () async {
      final mock = MockClient((_) async => http.Response('not found', 404));
      final claim = await clientWith(mock).queryHandoff(7);
      expect(claim, isNull);
    });

    test('queryHandoff decodes an available baton', () async {
      final mock = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'targetId': 7,
            'activeTileId': 42,
            'holder': null,
            'altitudeOk': true,
            'claimToken': null,
          }),
          200,
        ),
      );
      final claim = await clientWith(mock).queryHandoff(7);
      expect(claim, isNotNull);
      expect(claim!.targetId, 7);
      expect(claim.activeTileId, 42);
      expect(claim.isAvailableNow, isTrue);
    });

    test('claimHandoff returns the granted token + expiry', () async {
      final mock = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'targetId': 7,
            'activeTileId': 42,
            'holder': 'me',
            'altitudeOk': true,
            'claimToken': 'baton-1',
            'expiresAt': '2026-06-20T10:00:00Z',
          }),
          200,
        ),
      );
      final claim = await clientWith(mock).claimHandoff(7);
      expect(claim!.claimToken, 'baton-1');
      expect(claim.expiresAt, DateTime.utc(2026, 6, 20, 10));
      // Held by us -> not "available now" for someone else to grab.
      expect(claim.isAvailableNow, isFalse);
    });
  });

  group('attribution', () {
    test('fetchAttribution GETs /v1/attribution with the artifact query + '
        'decodes the ordered, consent-aware credit list', () async {
      http.Request? seen;
      final mock = MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'artifactType': 'mosaic',
            'artifactRef': 'mos-1',
            'contributors': [
              {
                'accountId': 'acc-a',
                'displayName': 'Ada',
                'anonymous': false,
                'frames': 120,
                'integrationSeconds': 3600.0,
                'license': 'cc-by-4.0',
              },
              {
                'displayName': 'Anonymous contributor',
                'anonymous': true,
                'frames': 40,
                'integrationSeconds': 1200.0,
              },
            ],
          }),
          200,
        );
      });

      final attribution = await clientWith(
        mock,
      ).fetchAttribution(artifactType: 'mosaic', artifactRef: 'mos-1');

      expect(seen!.method, 'GET');
      expect(seen!.url.path, '/v1/attribution');
      expect(seen!.url.queryParameters['artifactType'], 'mosaic');
      expect(seen!.url.queryParameters['artifactRef'], 'mos-1');
      expect(seen!.headers['Authorization'], 'Bearer tok-123');
      expect(attribution.contributors, hasLength(2));
      expect(attribution.displayNames, ['Ada', 'Anonymous contributor']);
      final ada = attribution.contributors.first;
      expect(ada.accountId, 'acc-a');
      expect(ada.frames, 120);
      expect(ada.integrationSeconds, 3600.0);
      expect(ada.license, 'cc-by-4.0');
      final anon = attribution.contributors[1];
      expect(anon.anonymous, isTrue);
      expect(anon.accountId, isNull);
    });

    test('fetchAttribution maps 404 to an empty credit list', () async {
      final mock = MockClient((_) async => http.Response('not found', 404));
      final attribution = await clientWith(
        mock,
      ).fetchAttribution(artifactType: 'coimaging', artifactRef: 'sess-9');
      expect(attribution.artifactType, 'coimaging');
      expect(attribution.artifactRef, 'sess-9');
      expect(attribution.isEmpty, isTrue);
      expect(attribution.contributors, isEmpty);
    });
  });

  group('error mapping', () {
    test('409 maps to geometryMismatch', () async {
      final dir = await Directory.systemTemp.createTemp('nst_409');
      final delta = File('${dir.path}/d.nst')..writeAsBytesSync([0]);
      final mock = MockClient(
        (_) async => http.Response('order mismatch', 409),
      );

      await expectLater(
        clientWith(mock).pushTile(
          tileId: 1,
          order: 9,
          deltaPath: delta.path,
          license: 'cc-by',
        ),
        throwsA(
          isA<ConstellationException>().having(
            (e) => e.kind,
            'kind',
            ConstellationErrorKind.geometryMismatch,
          ),
        ),
      );
      await dir.delete(recursive: true);
    });

    test('401 maps to auth', () async {
      final mock = MockClient((_) async => http.Response('nope', 401));
      await expectLater(
        clientWith(mock).info(),
        throwsA(
          isA<ConstellationException>().having(
            (e) => e.kind,
            'kind',
            ConstellationErrorKind.auth,
          ),
        ),
      );
    });

    test('a hub 400/422 maps to protocol, not unknown', () async {
      // `unknown` is what the headless handlers turn into a 500, so a request
      // the HUB rejected was being reported as an appliance fault — telling the
      // caller to retry something that can never succeed. 400 and 422 are both
      // "your request is wrong": bad params / an un-shareable license (400) and
      // a content-integrity rejection (422).
      for (final status in <int>[400, 422]) {
        final mock = MockClient((_) async => http.Response('bad', status));
        await expectLater(
          clientWith(mock).info(),
          throwsA(
            isA<ConstellationException>()
                .having((e) => e.kind, 'kind', ConstellationErrorKind.protocol)
                .having((e) => e.statusCode, 'statusCode', status),
          ),
          reason: 'HTTP $status',
        );
      }
    });

    test('pushTile throws notFound when the delta file is missing', () async {
      final mock = MockClient((_) async => http.Response('', 200));
      await expectLater(
        clientWith(mock).pushTile(
          tileId: 1,
          order: 9,
          deltaPath: '/does/not/exist.nst',
          license: 'cc-by',
        ),
        throwsA(
          isA<ConstellationException>().having(
            (e) => e.kind,
            'kind',
            ConstellationErrorKind.notFound,
          ),
        ),
      );
    });
  });

  group('raw subframes', () {
    test('pushSubframe streams the FITS to /tiles/<id>/subframes with '
        'provenance query', () async {
      final dir = await Directory.systemTemp.createTemp('cns_sub');
      final fits = File('${dir.path}/light.fits')
        ..writeAsBytesSync(utf8.encode('SIMPLE = T / a frame'));
      http.BaseRequest? seen;
      int? seenLen;
      final mock = MockClient((request) async {
        seen = request;
        seenLen = request.bodyBytes.length;
        return http.Response(
          jsonEncode({
            'contributionId': 'sub-1',
            'accepted': true,
            'storedBytes': request.bodyBytes.length,
          }),
          200,
        );
      });

      final receipt = await clientWith(mock).pushSubframe(
        tileId: 314,
        order: 9,
        fitsPath: fits.path,
        license: 'cc-by',
        capturedImageId: 42,
        exposureSeconds: 120,
        instrument: 'asi2600',
      );

      expect(receipt.contributionId, 'sub-1');
      expect(receipt.storedBytes, fits.lengthSync());
      expect(seen!.method, 'POST');
      expect(seen!.url.path, endsWith('/v1/tiles/314/subframes'));
      expect(seen!.url.queryParameters['order'], '9');
      expect(seen!.url.queryParameters['capturedImageId'], '42');
      expect(seen!.url.queryParameters['instrument'], 'asi2600');
      // The raw-subframe share carries its license + raw-sub opt-in.
      expect(seen!.url.queryParameters['license'], 'cc-by');
      expect(seen!.url.queryParameters['shareRawSubframes'], 'true');
      expect(seen!.headers['Authorization'], 'Bearer tok-123');
      expect(seenLen, fits.lengthSync());
      await dir.delete(recursive: true);
    });

    test('pushSubframe throws notFound when the FITS is missing', () async {
      final mock = MockClient((_) async => http.Response('', 200));
      await expectLater(
        clientWith(mock).pushSubframe(
          tileId: 1,
          order: 9,
          fitsPath: '/no/such.fits',
          license: 'cc-by',
        ),
        throwsA(
          isA<ConstellationException>().having(
            (e) => e.kind,
            'kind',
            ConstellationErrorKind.notFound,
          ),
        ),
      );
    });

    test(
      'pushSubframe maps a 405 (hub does not accept subs) to conflict',
      () async {
        final dir = await Directory.systemTemp.createTemp('cns_sub405');
        final fits = File('${dir.path}/l.fits')..writeAsBytesSync([1, 2, 3]);
        final mock = MockClient(
          (_) async =>
              http.Response('this hub does not accept raw subframes', 405),
        );
        await expectLater(
          clientWith(mock).pushSubframe(
            tileId: 1,
            order: 9,
            fitsPath: fits.path,
            license: 'cc-by',
          ),
          throwsA(
            isA<ConstellationException>().having(
              (e) => e.kind,
              'kind',
              ConstellationErrorKind.conflict,
            ),
          ),
        );
        await dir.delete(recursive: true);
      },
    );

    test('deleteSubframe issues DELETE /v1/subframes/<id>', () async {
      http.Request? seen;
      final mock = MockClient((request) async {
        seen = request;
        return http.Response('{"deleted": true}', 200);
      });
      await clientWith(mock).deleteSubframe('sub-9');
      expect(seen!.method, 'DELETE');
      expect(seen!.url.path, endsWith('/v1/subframes/sub-9'));
    });

    test('releasePanel rejects a malformed success payload', () async {
      final mock = MockClient((_) async => http.Response('{}', 200));

      await expectLater(
        clientWith(mock).releasePanel('mos-1', 2),
        throwsA(
          isA<ConstellationException>()
              .having((e) => e.kind, 'kind', ConstellationErrorKind.protocol)
              .having((e) => e.message, 'message', contains('released')),
        ),
      );
    });
  });
}
