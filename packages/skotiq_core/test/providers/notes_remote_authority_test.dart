import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../fakes/fake_network_client.dart';

void main() {
  test('remote notes repository performs CRUD on the imaging host', () async {
    final fake = FakeNetworkClient();
    final backend = NetworkBackend(
      serverHost: '127.0.0.1',
      serverPort: 8080,
      httpClient: fake,
      autoConnectWebSocket: false,
    );
    var invalidations = 0;
    final repository = NotesRepository.remote(
      backend,
      afterMutation: () => invalidations++,
    );
    const createdJson = '''
      {"note":{"id":"note-1","targetId":"M31","sequenceRunId":7,
      "createdAt":"2026-07-13T01:00:00Z","updatedAt":"2026-07-13T01:00:00Z",
      "title":"First light","body":"Good guiding","tags":["guiding"],
      "attachments":[],"sentiment":"happy"}}
    ''';
    fake.setResponse('/api/db/notes', method: 'POST', body: createdJson);

    final created = await repository.addNote(
      targetId: 'M31',
      sequenceRunId: 7,
      title: 'First light',
      body: 'Good guiding',
      tags: const ['guiding'],
      sentiment: 'happy',
    );

    expect(created.id, 'note-1');
    expect(fake.requests.single.method, 'POST');
    expect(fake.requests.single.path, '/api/db/notes');
    expect(fake.requests.single.body, contains('"sequenceRunId":7'));

    const updatedJson = '''
      {"note":{"id":"note-1","targetId":"M31","sequenceRunId":7,
      "createdAt":"2026-07-13T01:00:00Z","updatedAt":"2026-07-13T01:05:00Z",
      "title":null,"body":"Excellent guiding","tags":["keeper"],
      "attachments":[],"sentiment":null}}
    ''';
    fake.setResponse('/api/db/notes/note-1', method: 'PUT', body: updatedJson);
    final updated = await repository.updateNote(
      'note-1',
      body: 'Excellent guiding',
      tags: const ['keeper'],
      clearTitle: true,
      clearSentiment: true,
    );

    expect(updated.title, isNull);
    expect(updated.body, 'Excellent guiding');
    expect(fake.requests[1].method, 'PUT');
    expect(fake.requests[1].body, contains('"clearTitle":true'));

    fake.setResponse(
      '/api/db/notes/note-1',
      method: 'DELETE',
      body: '{"status":"deleted"}',
    );
    expect(await repository.deleteNote('note-1'), 1);
    expect(fake.requests[2].method, 'DELETE');
    expect(fake.requests[2].path, '/api/db/notes/note-1');
    expect(invalidations, 3);
  });
}
