import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_remote_protocol/wire.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

void main() {
  test('a path value is sent as one percent-encoded segment of the declared '
      'route', () async {
    const deviceId = 'indi:localhost:7624:CCD Simulator/1';
    final path = EquipmentApi.getDeviceHealth.route.fill({
      'deviceId': deviceId,
    });
    final fake = FakeNetworkClient()
      ..setResponse(
        path,
        body: '{"last_successful_comm":12,"is_healthy":true}',
      );
    final backend = _backend(fake);
    addTearDown(backend.dispose);

    expect(await backend.getDeviceHealth(deviceId), (12, true));
    expect(
      fake.requests.single.url.toString(),
      'http://example.invalid:8080/api/device/health/'
      'indi%3Alocalhost%3A7624%3ACCD%20Simulator%2F1',
    );
  });

  test(
    'a query that used to be written into the path is sent as a query',
    () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/calibration/darks/7', method: 'DELETE');
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await backend.deleteDark(7, deleteFile: true);

      final request = fake.requests.single;
      expect(request.method, 'DELETE');
      expect(request.url.path, '/api/calibration/darks/7');
      expect(request.url.queryParameters, {'deleteFile': 'true'});
    },
  );
}
