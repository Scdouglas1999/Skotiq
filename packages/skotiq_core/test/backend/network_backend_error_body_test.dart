import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/errors/server_error.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

void main() {
  test('a refusal is not retried because its words sound transient', () async {
    final fake = FakeNetworkClient()
      ..setResponse(
        '/api/devices/connected',
        status: 409,
        body: '{"error":"camera_busy","message":"The camera is busy"}',
      );
    final backend = _backend(fake);
    addTearDown(backend.dispose);

    await expectLater(
      backend.getConnectedDevices(),
      throwsA(
        isA<ServerError>()
            .having((e) => e.code, 'code', 'camera_busy')
            .having((e) => e.message, 'message', 'The camera is busy')
            .having((e) => e.httpStatus, 'httpStatus', 409),
      ),
    );
    expect(fake.requestsFor('/api/devices/connected'), hasLength(1));
  });

  test('an answer that is not an error body keeps its status', () async {
    final fake = FakeNetworkClient()
      ..setResponse(
        '/api/devices/connected',
        status: 404,
        body: '<html>nope</html>',
      );
    final backend = _backend(fake);
    addTearDown(backend.dispose);

    await expectLater(
      backend.getConnectedDevices(),
      throwsA(
        isA<ServerError>()
            .having((e) => e.code, 'code', 'not_found')
            .having((e) => e.httpStatus, 'httpStatus', 404),
      ),
    );
  });
}
