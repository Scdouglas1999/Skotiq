import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/models/backend/device_types.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

void main() {
  group('NetworkBackend remaining collection contracts', () {
    test('valid empty collections remain empty', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/jobs', body: '{"jobs":[]}')
        ..setResponse('/api/calibration-library', body: '{"masters":[]}')
        ..setResponse('/api/sessions/3/images', body: '{"images":[]}');
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(await backend.listJobs(), isEmpty);
      expect(await backend.getCalibrationMasters(), isEmpty);
      expect(await backend.getSessionImageRows(3), isEmpty);
    });

    test('missing collection fields do not impersonate empty data', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/jobs', body: '{}')
        ..setResponse('/api/calibration-library', body: '{}')
        ..setResponse('/api/sessions/3/images', body: '{}')
        ..setResponse('/api/images', body: '{}')
        ..setResponse('/api/images/standalone', body: '{}');
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(backend.listJobs(), throwsFormatException);
      await expectLater(backend.getCalibrationMasters(), throwsFormatException);
      await expectLater(backend.getSessionImageRows(3), throwsFormatException);
      await expectLater(backend.getAllImageRows(), throwsFormatException);
      await expectLater(
        backend.getStandaloneImageRows(),
        throwsFormatException,
      );
    });

    test(
      'malformed catalog and plugin rows are not silently dropped',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse('/api/catalog/available', body: '{"available":[false]}')
          ..setResponse('/api/plugins', body: '{"items":["broken"]}');
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        await expectLater(
          backend.listAvailableCatalogs(),
          throwsFormatException,
        );
        await expectLater(backend.listPlugins(), throwsFormatException);
      },
    );

    test(
      'device discovery requires the advertised collection and identity',
      () async {
        final missingFake = FakeNetworkClient()
          ..setResponse('/api/devices', body: '{}');
        final missingBackend = _backend(missingFake);
        addTearDown(missingBackend.dispose);
        await expectLater(
          missingBackend.discoverDevices(DeviceType.camera),
          throwsFormatException,
        );

        final malformedFake = FakeNetworkClient()
          ..setResponse(
            '/api/devices',
            body:
                '{"devices":[{"id":"camera","name":"Camera",'
                '"driverType":"simulator"}]}',
          );
        final malformedBackend = _backend(malformedFake);
        addTearDown(malformedBackend.dispose);
        await expectLater(
          malformedBackend.discoverDevices(DeviceType.camera),
          throwsFormatException,
        );
      },
    );

    test('direct network discovery rejects devices without identity', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/devices/discover-indi',
          body:
              '{"devices":[{"id":"","name":"Camera",'
              '"deviceType":"camera","driverType":"indi"}]}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(
        backend.discoverIndiAtAddress('192.0.2.1', 7624),
        throwsFormatException,
      );
    });
  });
}
