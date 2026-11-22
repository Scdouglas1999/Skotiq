// Every WebSocket upgrade a client makes names its release, as the host's
// link check requires (it answers 426 release_required otherwise).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show LinkVersion, skotiqRelease;

void main() {
  test('the live-view socket names the release', () async {
    final upgrade = Completer<Uri>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/ws/live-view' && !upgrade.isCompleted) {
        upgrade.complete(request.uri);
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    final backend = NetworkBackend(
      serverHost: InternetAddress.loopbackIPv4.address,
      serverPort: server.port,
      webSocketPort: server.port,
      autoConnectWebSocket: false,
    );
    final subscription = backend
        .subscribeLiveView(deviceId: 'camera-1')
        .listen((_) {}, onError: (Object _) {});
    final uri = await upgrade.future.timeout(const Duration(seconds: 5));
    // The refused upgrade leaves nothing to wait for; cancelling it is not
    // awaited.
    unawaited(subscription.cancel());
    backend.dispose();
    await server.close(force: true);
    expect(uri.queryParameters[LinkVersion.queryParameter], skotiqRelease);
  });
}
