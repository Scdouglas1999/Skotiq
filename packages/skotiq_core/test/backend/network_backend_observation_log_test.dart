import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

import '../fakes/fake_network_client.dart';

void main() {
  late FakeNetworkClient fake;
  late NetworkBackend backend;

  setUp(() {
    fake = FakeNetworkClient()
      ..setResponse(
        '/api/notes-journal',
        method: 'POST',
        body: '{"status":"created","id":42}',
      )
      ..setResponse(
        '/api/notes-journal/42',
        method: 'DELETE',
        body: '{"status":"deleted","id":42}',
      )
      ..setResponse(
        '/api/notes-journal',
        method: 'DELETE',
        body: '{"status":"deleted","count":1}',
      );
    backend = NetworkBackend(
      serverHost: '127.0.0.1',
      serverPort: 9999,
      webSocketPort: 9999,
      httpClient: fake,
      autoConnectWebSocket: false,
    );
  });

  tearDown(() => backend.dispose());

  test('observation-log CRUD uses host routes and preserves payload', () async {
    final timestamp = DateTime.utc(2026, 7, 13, 1, 2, 3);
    final id = await backend.createObservationLog(
      timestamp: timestamp,
      objectName: 'M31',
      ra: 0.7,
      dec: 41.3,
      notes: 'Clear, steady',
      rating: 5,
      latitude: 40,
      longitude: -75,
    );
    await backend.deleteObservationLog(id);
    await backend.deleteAllObservationLogs();

    expect(id, 42);
    final journalRequests = fake.requestsFor('/api/notes-journal');
    final post = journalRequests.singleWhere(
      (request) => request.method == 'POST',
    );
    final body = jsonDecode(post.body!) as Map<String, dynamic>;
    expect(body['timestamp'], timestamp.toIso8601String());
    expect(body['objectName'], 'M31');
    expect(body['notes'], 'Clear, steady');
    expect(body['rating'], 5);
    expect(body['latitude'], 40);
    expect(body['longitude'], -75);
    expect(
      fake
          .requestsFor('/api/notes-journal/42')
          .where((request) => request.method == 'DELETE'),
      hasLength(1),
    );
    expect(
      journalRequests.where((request) => request.method == 'DELETE'),
      hasLength(1),
    );
  });
}
