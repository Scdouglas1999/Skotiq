import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

/// A host that answers `/api/info` with [info] and accepts the event socket.
Future<HttpServer> _host(Map<String, Object?> info) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (request.uri.path == '/api/info') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(info));
      await request.response.close();
      return;
    }
    if (request.uri.path == '/events') {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((_) {});
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  });
  return server;
}

Future<bool?> _whatTheHostSaid(Map<String, Object?> info) async {
  final server = await _host(info);
  final backend = NetworkBackend(
    serverHost: InternetAddress.loopbackIPv4.address,
    serverPort: server.port,
    webSocketPort: server.port,
    autoConnectWebSocket: false,
  );
  addTearDown(() async {
    backend.dispose();
    await server.close(force: true);
  });
  expect(backend.hostRequiresPairing, isNull);
  await backend.connect();
  return backend.hostRequiresPairing;
}

void main() {
  // The Remote access page on a linked client called a host that demanded a
  // token open to anything that could reach it: nothing kept what the host
  // says about itself when the client connects.
  test('a host that requires pairing is known as one after connecting',
      () async {
    expect(
      await _whatTheHostSaid({'version': '2.5.0', 'authRequired': true}),
      isTrue,
    );
  });

  test('an open host is known as open', () async {
    expect(
      await _whatTheHostSaid({'version': '2.5.0', 'authRequired': false}),
      isFalse,
    );
  });

  test('a host that does not say stays unknown', () async {
    expect(await _whatTheHostSaid({'version': '2.5.0'}), isNull);
  });
}
