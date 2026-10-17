import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

void main() {
  group('NetworkBackend cover/calibrator control', () {
    test('every cover command sends the server-required deviceId', () async {
      final fake = FakeNetworkClient()
        ..setDefaultResponse(body: '{"status":"ok"}');
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await backend.coverOpen('cover-1');
      await backend.coverClose('cover-1');
      await backend.setCoverBrightness('cover-1', 73);
      await backend.calibratorOn('cover-1', 91);
      await backend.calibratorOff('cover-1');

      expect(fake.requests, hasLength(5));
      for (final request in fake.requests) {
        final body = jsonDecode(request.body!) as Map<String, dynamic>;
        expect(
          body['deviceId'],
          'cover-1',
          reason: '${request.path} must address the connected accessory',
        );
      }
      expect(
        jsonDecode(
          fake.requestsFor('/api/cover/brightness').single.body!,
        )['brightness'],
        73,
      );
      expect(
        jsonDecode(
          fake.requestsFor('/api/cover/calibrator-on').single.body!,
        )['brightness'],
        91,
      );
    });

    test('status request is scoped to the connected device', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/cover/status',
          body: '{"connected":true,"hasCover":true}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final status = await backend.getCoverStatus('cover-2');

      expect(status['connected'], isTrue);
      expect(status['hasCover'], isTrue);
      expect(
        fake.requestsFor('/api/cover/status').single.url.queryParameters,
        containsPair('deviceId', 'cover-2'),
      );
    });
  });
}
