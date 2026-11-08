// A linked desktop told the operator "frames saved, but the flat library did
// not record this calibration (HTTP 201)" after every flat run: the host
// answers POST /api/calibration/flats with 201 Created, and the client took
// anything but 200 as a failure. The body below is the host's real answer.

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
  test('a 201 Created answer to a POST is success', () async {
    final fake = FakeNetworkClient()
      ..setResponse(
        '/api/calibration/flats',
        method: 'POST',
        status: 201,
        body:
            '{"flat":{"id":4,"filter":"L","exposureDuration":4.0,'
            '"histogramTarget":20.0,"adu":13107,"gain":100,"binning":1,'
            '"panelBrightness":null,"skyAduRate":null,"twilightPhase":null,'
            '"equipmentProfileId":null,"createdAt":"2026-11-08T22:44:38.000Z"}}',
      );
    final backend = _backend(fake);
    addTearDown(backend.dispose);

    final entry = await backend.recordFlat(
      filter: 'L',
      exposureDuration: 4.0,
      adu: 13107,
      histogramTarget: 20.0,
      gain: 100,
    );
    expect(entry.id, 4);
  });

  test('a 4xx answer to a POST is still a failure', () async {
    final fake = FakeNetworkClient()
      ..setResponse(
        '/api/calibration/flats',
        method: 'POST',
        status: 400,
        body: '{"error":"bad","code":"invalid_request"}',
      );
    final backend = _backend(fake);
    addTearDown(backend.dispose);

    await expectLater(
      backend.recordFlat(filter: 'L', exposureDuration: 4.0, adu: 1),
      throwsA(anything),
    );
  });
}
