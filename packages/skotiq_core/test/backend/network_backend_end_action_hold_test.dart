// A linked client ends its manual action's hold through the host's resume
// route; the host says whether it resumed the run, and names a pause that
// keeps it paused.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
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
  for (final (status, resumed) in [('resumed', true), ('released', false)]) {
    test('a host answering $status reads as resumed: $resumed', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sequencer/resume',
          method: 'POST',
          body: '{"status":"$status","wasRunning":true}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      expect(await backend.sequencerEndActionHold(), resumed);
      expect(fake.requestsFor('/api/sequencer/resume'), hasLength(1));
    });
  }

  test('a host refusing because another pause keeps the run paused names '
      'that pause', () async {
    final fake = FakeNetworkClient()
      ..setResponse(
        '/api/sequencer/resume',
        method: 'POST',
        status: 409,
        body:
            '{"error":"run_still_paused","message":"The hold was released, '
            'and the run is still paused: weather turned unsafe.",'
            '"pausedBy":"weather turned unsafe","wasRunning":true}',
      );
    final backend = _backend(fake);
    addTearDown(backend.dispose);

    await expectLater(
      backend.sequencerEndActionHold(),
      throwsA(
        isA<RunStillPaused>().having(
          (e) => e.pausedBy,
          'pausedBy',
          'weather turned unsafe',
        ),
      ),
    );
  });
}
