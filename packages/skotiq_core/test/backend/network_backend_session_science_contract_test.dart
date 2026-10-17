import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/models/errors/server_error.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

void main() {
  group('NetworkBackend session/science wire contract', () {
    test('an absent active session remains a valid null result', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/sessions/active', body: '{"session":null}');
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(await backend.getActiveSession(), isNull);
    });

    test('active-session server failures are not reported as no session', () {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sessions/active',
          status: 401,
          body: '{"code":"unauthorized","message":"Pairing token expired"}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(
        backend.getActiveSession(),
        throwsA(
          isA<ServerError>().having(
            (error) => error.code,
            'code',
            'unauthorized',
          ),
        ),
      );
    });

    test('404 is the only missing-session and missing-image result', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sessions/12',
          status: 404,
          body: '{"code":"not_found","message":"Session not found"}',
        )
        ..setResponse(
          '/api/images/34',
          status: 404,
          body: '{"code":"not_found","message":"Image not found"}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(await backend.getSessionById(12), isNull);
      expect(await backend.getCapturedImageById(34), isNull);
    });

    test(
      'FITS dimensions return null only for an explicit missing file',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/imaging/fits-dimensions',
            status: 404,
            body: '{"code":"fits_not_found","message":"No FITS file at path"}',
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        expect(await backend.getFitsDimensions('/host/missing.fit'), isNull);
      },
    );

    test('FITS transport failures are not reported as a missing file', () {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/imaging/fits-dimensions',
          status: 401,
          body: '{"code":"unauthorized","message":"Pairing token expired"}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(
        backend.getFitsDimensions('/host/image.fit'),
        throwsA(isA<ServerError>()),
      );
    });

    test('malformed collection and scalar payloads fail loudly', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/sessions', body: '{}')
        ..setResponse('/api/analytics/untracked-targets/count', body: '{}')
        ..setResponse('/api/weather/settings', body: '{}')
        ..setResponse('/api/science/session/9/bundle', body: '{}')
        ..setResponse('/api/science/session/9/config', body: '{}');
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(backend.getAllSessions(), throwsFormatException);
      await expectLater(backend.countUntrackedTargets(), throwsFormatException);
      await expectLater(backend.getWeatherSettings(), throwsFormatException);
      await expectLater(
        backend.getScienceSessionBundle(9),
        throwsFormatException,
      );
      await expectLater(
        backend.getScienceSessionConfig(9),
        throwsFormatException,
      );
    });

    test('photometric fit returns null only for a documented 422', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/science/calibration/compute-transform',
          method: 'POST',
          status: 422,
          body: '{"code":"fit_unavailable","message":"Fit did not converge"}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(
        await backend.computePhotometricTransform(
          starMatches: const [],
          filterName: 'V',
        ),
        isNull,
      );
    });

    test('analytics date filters use the host ISO-8601 contract', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/analytics/summary', body: '{}')
        ..setResponse('/api/analytics/integration-time', body: '{}');
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      final start = DateTime.utc(2026, 7, 1, 2, 3, 4);
      final end = DateTime.utc(2026, 7, 2, 5, 6, 7);

      await backend.getAnalyticsSummary(startDate: start, endDate: end);
      await backend.getTotalIntegrationTime(startDate: start, endDate: end);

      for (final path in [
        '/api/analytics/summary',
        '/api/analytics/integration-time',
      ]) {
        final query = fake.requestsFor(path).single.url.queryParameters;
        expect(query['startDate'], '2026-07-01T02:03:04.000Z');
        expect(query['endDate'], '2026-07-02T05:06:07.000Z');
      }
    });

    test('complete PSF and residual rows decode without invented values', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sessions/7/psf-tiles',
          body:
              '''{"psfTiles":[{"id":1,"capturedImageId":2,"sessionId":7,"tileRow":0,"tileCol":1,"starCount":14,"medianFwhm":2.4,"medianHfr":1.2,"medianEccentricity":0.31,"roundness":0.69,"timestamp":1784000000000}]}''',
        )
        ..setResponse(
          '/api/sessions/7/residuals',
          body:
              '''{"residuals":[{"id":3,"capturedImageId":2,"sessionId":7,"x":125.5,"y":64.25,"dxArcsec":-0.3,"dyArcsec":0.4,"magnitudeArcsec":0.5,"recommendationCode":null,"timestamp":1784000000000}]}''',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final tiles = await backend.getSessionPsfTiles(7);
      final residuals = await backend.getSessionResidualVectors(7);

      expect(tiles.single.tileCol, 1);
      expect(tiles.single.medianEccentricity, 0.31);
      expect(residuals.single.dxArcsec, -0.3);
      expect(residuals.single.magnitudeArcsec, 0.5);
    });

    test('PSF rows require every diagnostic field and its real domain', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sessions/7/psf-tiles',
          body:
              '''{"psfTiles":[{"id":1,"capturedImageId":null,"sessionId":7,"tileCol":1,"starCount":14,"medianFwhm":2.4,"medianHfr":1.2,"medianEccentricity":1.4,"roundness":0.69,"timestamp":1784000000000}]}''',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(
        backend.getSessionPsfTiles(7),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('row 0 field `tileRow`'),
          ),
        ),
      );
    });

    test('residual rows reject malformed numeric diagnostics', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sessions/7/residuals',
          body:
              '''{"residuals":[{"id":3,"capturedImageId":2,"sessionId":7,"x":"125.5","y":64.25,"dxArcsec":-0.3,"dyArcsec":0.4,"magnitudeArcsec":-0.5,"recommendationCode":null,"timestamp":1784000000000}]}''',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(
        backend.getSessionResidualVectors(7),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('row 0 field `x`'),
          ),
        ),
      );
    });

    test('duplicate science row ids fail the endpoint atomically', () async {
      const tile =
          '''{"id":1,"capturedImageId":2,"sessionId":7,"tileRow":0,"tileCol":1,"starCount":14,"medianFwhm":2.4,"medianHfr":1.2,"medianEccentricity":0.31,"roundness":0.69,"timestamp":1784000000000}''';
      const residual =
          '''{"id":3,"capturedImageId":2,"sessionId":7,"x":125.5,"y":64.25,"dxArcsec":-0.3,"dyArcsec":0.4,"magnitudeArcsec":0.5,"recommendationCode":null,"timestamp":1784000000000}''';
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sessions/7/psf-tiles',
          body: '{"psfTiles":[$tile,$tile]}',
        )
        ..setResponse(
          '/api/sessions/7/residuals',
          body: '{"residuals":[$residual,$residual]}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(backend.getSessionPsfTiles(7), throwsFormatException);
      await expectLater(
        backend.getSessionResidualVectors(7),
        throwsFormatException,
      );
    });
  });
}
