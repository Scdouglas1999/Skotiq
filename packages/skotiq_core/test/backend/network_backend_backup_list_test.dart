import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

import '../fakes/fakes.dart';

void main() {
  test(
    'backup list keeps valid object rows and ignores malformed elements',
    () async {
      final client = FakeNetworkClient();
      client.setResponse(
        '/api/backup/list',
        method: 'GET',
        body:
            '{"backups":['
            '{"id":"one","fileName":"one.skbackup"},'
            '"bad",7,{"id":"two","fileName":"two.skbackup"}'
            ']}',
      );
      final backend = NetworkBackend(
        serverHost: '127.0.0.1',
        serverPort: 9999,
        webSocketPort: 9999,
        httpClient: client,
        autoConnectWebSocket: false,
      );
      addTearDown(backend.dispose);

      final rows = await backend.listBackups();

      expect(rows.map((row) => row['id']), ['one', 'two']);
    },
  );

  test('backup list rejects a missing top-level backups field', () async {
    final client = FakeNetworkClient()
      ..setResponse('/api/backup/list', method: 'GET', body: '{}');
    final backend = NetworkBackend(
      serverHost: '127.0.0.1',
      serverPort: 9999,
      webSocketPort: 9999,
      httpClient: client,
      autoConnectWebSocket: false,
    );
    addTearDown(backend.dispose);

    await expectLater(backend.listBackups(), throwsFormatException);
  });
}
