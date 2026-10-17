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
  group('NetworkBackend capability contract', () {
    test('only a 404 becomes capability unavailable', () async {
      final fake = FakeNetworkClient();
      for (final endpoint in [
        'camera',
        'mount',
        'focuser',
        'filter-wheel',
        'rotator',
      ]) {
        fake.setResponse(
          '/api/equipment/$endpoint/capabilities',
          status: 404,
          body: '{"code":"not_found","message":"Device not found"}',
        );
      }
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(await backend.getCameraCapabilities('camera'), isNull);
      expect(await backend.getMountCapabilities('mount'), isNull);
      expect(await backend.getFocuserCapabilities('focuser'), isNull);
      expect(await backend.getFilterWheelCapabilities('filter-wheel'), isNull);
      expect(await backend.getRotatorCapabilities('rotator'), isNull);
    });

    test('auth and transport failures are not capability unavailable', () {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/equipment/mount/capabilities',
          status: 401,
          body: '{"code":"unauthorized","message":"Pairing token expired"}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(
        backend.getMountCapabilities('mount'),
        throwsA(isA<ServerError>()),
      );
    });

    test('malformed success payloads do not fabricate capabilities', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/equipment/camera/capabilities', body: '{}')
        ..setResponse('/api/equipment/mount/capabilities', body: '{}')
        ..setResponse('/api/equipment/focuser/capabilities', body: '{}')
        ..setResponse('/api/equipment/filter-wheel/capabilities', body: '{}')
        ..setResponse('/api/equipment/rotator/capabilities', body: '{}');
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(
        backend.getCameraCapabilities('camera'),
        throwsFormatException,
      );
      await expectLater(
        backend.getMountCapabilities('mount'),
        throwsFormatException,
      );
      await expectLater(
        backend.getFocuserCapabilities('focuser'),
        throwsFormatException,
      );
      await expectLater(
        backend.getFilterWheelCapabilities('filter-wheel'),
        throwsFormatException,
      );
      await expectLater(
        backend.getRotatorCapabilities('rotator'),
        throwsFormatException,
      );
    });

    test('cloud motion distinguishes old host from malformed host', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/sequencer/cloud-motion', body: '{}');
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(
        backend.sequencerGetCloudMotionJson(),
        throwsFormatException,
      );

      fake.setResponse(
        '/api/sequencer/cloud-motion',
        status: 404,
        body: '{"code":"not_found","message":"Endpoint unavailable"}',
      );
      expect(await backend.sequencerGetCloudMotionJson(), isNull);
    });
  });

  group('NetworkBackend camera recommended-settings wire parsing', () {
    test('integer or double cooling setpoint normalizes to double', () async {
      final fake = FakeNetworkClient();
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      // Integer JSON must widen to the double the FFI backend reports so a
      // remote client's profile defaults match the local rig's exactly.
      fake.setResponse(
        '/api/camera/recommended-settings',
        body:
            '{"unityGain":120,"hcgGain":null,"defaultOffset":30,'
            '"recommendedCoolingSetpointC":-10,"notes":"fixture"}',
      );
      final fromInt = await backend.cameraGetRecommendedSettings('cam');
      expect(fromInt.recommendedCoolingSetpointC, -10.0);
      expect(fromInt.recommendedCoolingSetpointC, isA<double>());

      // Fractional JSON round-trips without loss.
      fake.setResponse(
        '/api/camera/recommended-settings',
        body:
            '{"unityGain":120,"defaultOffset":30,'
            '"recommendedCoolingSetpointC":-12.5,"notes":"fixture"}',
      );
      final fromDouble = await backend.cameraGetRecommendedSettings('cam');
      expect(fromDouble.recommendedCoolingSetpointC, -12.5);
    });

    test('cooling setpoint absent on older hosts decodes as null', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/camera/recommended-settings',
          body: '{"unityGain":120,"defaultOffset":30,"notes":"fixture"}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final result = await backend.cameraGetRecommendedSettings('cam');
      expect(result.recommendedCoolingSetpointC, isNull);
      expect(result.unityGain, 120);
      expect(result.defaultOffset, 30);
      expect(result.notes, 'fixture');
    });
  });
}
