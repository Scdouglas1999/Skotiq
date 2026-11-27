// A linked client reads the host's run status, the manual-action hold
// included: the periodic re-read writes it over what the run channel said.
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
  for (final held in [true, false]) {
    test('a host whose run is held: $held reads so on the client', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sequencer/status',
          body:
              '{"state":"paused","currentNodeId":"exp",'
              '"currentNodeName":"Smart Exposure","progress":0.1,'
              '"message":"Paused","guidingStopReason":"mount_move",'
              '"pausedIdle":true,"heldByAction":$held}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final status = await backend.sequencerGetStatus();

      expect(status.heldByAction, held);
      expect(status.state, 'paused');
      expect(status.currentNodeName, 'Smart Exposure');
      expect(status.guidingStopReason, 'mount_move');
    });
  }
}
