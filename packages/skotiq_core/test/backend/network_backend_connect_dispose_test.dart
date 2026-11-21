import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_remote_protocol/wire.dart' show skotiqRelease;

void main() {
  test(
    'a connect that is disposed before the host answers does not become connected',
    () async {
      final infoGate = Completer<http.Response>();
      final backend = NetworkBackend(
        serverHost: '127.0.0.1',
        serverPort: 18999,
        autoConnectWebSocket: false,
        httpClient: MockClient((_) => infoGate.future),
      );

      final states = <BackendConnectionState>[];
      final statesSub = backend.connectionStateStream.listen(states.add);
      final connectFuture = backend.connect();
      await Future<void>.delayed(Duration.zero);
      expect(backend.connectionState, BackendConnectionState.connecting);

      backend.dispose();
      infoGate.complete(
        http.Response(
          '{"version":"$skotiqRelease","serverInstanceId":"inst-1"}',
          200,
        ),
      );
      await connectFuture;

      expect(backend.connectionState, isNot(BackendConnectionState.connected));
      expect(states, isNot(contains(BackendConnectionState.connected)));

      var closed = false;
      backend.connectionStateStream.listen((_) {}, onDone: () => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isTrue);

      await backend.connect();
      expect(backend.connectionState, isNot(BackendConnectionState.connected));
      await statesSub.cancel();
    },
  );
}
