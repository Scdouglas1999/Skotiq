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
  group('NetworkBackend dome control', () {
    test('every dome command sends the server-required deviceId', () async {
      final fake = FakeNetworkClient()
        ..setDefaultResponse(body: '{"status":"ok"}');
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await backend.domeOpenShutter('dome-1');
      await backend.domeCloseShutter('dome-1');
      await backend.domeSlewToAzimuth('dome-1', 123.5);
      await backend.domeSetSlaved('dome-1', true);
      await backend.domePark('dome-1');
      await backend.domeFindHome('dome-1');
      await backend.domeAbortSlew('dome-1');

      expect(fake.requests, hasLength(7));
      for (final request in fake.requests) {
        final body = jsonDecode(request.body!) as Map<String, dynamic>;
        expect(
          body['deviceId'],
          'dome-1',
          reason: '${request.path} must address the connected dome',
        );
      }
      final slew =
          jsonDecode(fake.requestsFor('/api/dome/slew').single.body!)
              as Map<String, dynamic>;
      expect(slew['azimuth'], 123.5);
    });

    test(
      'status and capabilities are scoped and capabilities are typed',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse('/api/dome/status', body: '{"connected":true}')
          ..setResponse(
            '/api/dome/capabilities',
            body: '{"canSetShutter":true,"canPark":true,"canSlave":true}',
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        final status = await backend.getDomeStatus('dome-2');
        final capabilities = await backend.getDomeCapabilities('dome-2');

        expect(status['connected'], isTrue);
        expect(capabilities, isNotNull);
        expect(capabilities!.canSetShutter, isTrue);
        expect(capabilities.canPark, isTrue);
        expect(capabilities.canSlave, isTrue);
        expect(
          fake.requestsFor('/api/dome/status').single.url.queryParameters,
          containsPair('deviceId', 'dome-2'),
        );
        expect(
          fake.requestsFor('/api/dome/capabilities').single.url.queryParameters,
          containsPair('deviceId', 'dome-2'),
        );
      },
    );
  });
}
