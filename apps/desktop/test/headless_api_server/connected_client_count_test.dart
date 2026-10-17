// "Active Viewers" on Settings > Remote Access — and the status-bar share chip
// it shares a field with — read 0 while a paired client held an authenticated
// /events WebSocket open, because the only number the GUI was ever given came
// from the co-imaging collaboration manager's viewer list. A client that just
// streams events all night never joins a collaboration session.
//
// This asserts the server publishes the thing the GUI actually asks about: the
// socket registry.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import '../headless_api/handler_test_helpers.dart';

void main() {
  late ProviderContainer container;
  late HeadlessApiServer server;

  setUp(() async {
    container = createHeadlessTestContainer(
      overrides: [
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '6.0.0', buildNumber: 1),
        ),
      ],
    );
    server = HeadlessApiServer(
      port: 0,
      container: container,
      bindLocalOnly: true,
      authToken: 'admin-token',
      webSocketHeartbeatInterval: const Duration(hours: 1),
      webSocketHeartbeatTimeout: const Duration(hours: 2),
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
  });

  Future<WebSocket> connect() async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.actualPort}'
      '/events?token=admin-token&apiVersion=2.6.0',
    );
    // The server greets every socket with collaboration_state; waiting for it
    // proves the upgrade completed rather than racing the registry write.
    final first = await socket.first;
    expect((jsonDecode(first as String) as Map)['type'], 'collaboration_state');
    return socket;
  }

  test('a client holding the event stream is counted as connected', () async {
    final counts = <int>[];
    final subscription = server.connectedClientCountStream.listen(counts.add);
    addTearDown(subscription.cancel);

    expect(server.connectedClientCount, 0);

    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.actualPort}'
      '/events?token=admin-token&apiVersion=2.6.0',
    );
    addTearDown(() async => socket.close());

    await _until(() => server.connectedClientCount == 1);
    expect(
      server.connectedClientCount,
      1,
      reason: 'a paired client is on the wire; the GUI must not read 0',
    );
    expect(counts, contains(1), reason: 'the GUI is told without polling');
  });

  test('the count drops when the client goes away', () async {
    final counts = <int>[];
    final subscription = server.connectedClientCountStream.listen(counts.add);
    addTearDown(subscription.cancel);

    final socket = await connect();
    await _until(() => server.connectedClientCount == 1);

    await socket.close();
    await _until(() => server.connectedClientCount == 0);

    expect(server.connectedClientCount, 0);
    expect(counts.last, 0, reason: 'the chip must go dark again');
  });
}

/// Poll until [condition] holds or a bounded window expires. The socket
/// registry is written on the server's own event loop turn, not on the client's.
Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
