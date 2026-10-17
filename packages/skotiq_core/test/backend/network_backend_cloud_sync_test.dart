import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

import '../fakes/fake_network_client.dart';

void main() {
  late FakeNetworkClient client;
  late NetworkBackend backend;

  setUp(() {
    client = FakeNetworkClient()
      ..setResponse(
        '/api/sync/status',
        body: jsonEncode({
          'configured': true,
          'autoPushEnabled': true,
          'machineName': 'observatory-host',
          'serverUrl': 'https://backups.example.test',
          'lastPushAt': '2026-07-13T18:30:00.000Z',
          'lastError': null,
          'pushInProgress': false,
        }),
      )
      ..setResponse(
        '/api/sync/push',
        method: 'POST',
        body: jsonEncode({
          'status': 'pushed',
          'remotePath': 'skotiq-sync/observatory-host/bundle.skbak',
          'sizeBytes': 4096,
          'timestamp': 1783968000000,
        }),
      );
    backend = NetworkBackend(
      serverHost: '127.0.0.1',
      serverPort: 9999,
      webSocketPort: 9999,
      httpClient: client,
      autoConnectWebSocket: false,
    );
  });

  tearDown(() => backend.dispose());

  test('cloud sync status and push use the imaging-host endpoints', () async {
    final status = await backend.getCloudSyncStatus();
    final result = await backend.pushCloudSyncNow();

    expect(status.configured, isTrue);
    expect(status.machineName, 'observatory-host');
    expect(status.lastPushAt, DateTime.utc(2026, 7, 13, 18, 30));
    expect(result.success, isTrue);
    expect(result.remotePath, contains('observatory-host'));
    expect(result.sizeBytes, 4096);
    expect(client.requestsFor('/api/sync/status').single.method, 'GET');
    expect(client.requestsFor('/api/sync/push').single.method, 'POST');
  });

  test('malformed host status fails loudly', () async {
    client.setResponse('/api/sync/status', body: '{"configured":"yes"}');

    await expectLater(
      backend.getCloudSyncStatus(),
      throwsA(isA<FormatException>()),
    );
  });
}
