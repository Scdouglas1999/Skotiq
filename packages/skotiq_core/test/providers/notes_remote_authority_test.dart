import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';

import '../fakes/fake_network_client.dart';
import 'package:skotiq_core/src/models/notes/journal_note.dart';

void main() {
  test('a linked client writes notes on the imaging host and re-reads them', () async {
    final fake = FakeNetworkClient();
    final backend = NetworkBackend(
      serverHost: '127.0.0.1',
      serverPort: 8080,
      httpClient: fake,
      autoConnectWebSocket: false,
    );
    final repository = backend.remoteHost!.notesJournal;
    fake.setResponse(
      '/api/db/notes',
      body: '{"items":[],"total":0,"limit":200,"offset":0}',
    );
    final lists = <List<JournalNote>>[];
    final watch = repository.watchAllNotes().listen(lists.add);
    addTearDown(watch.cancel);
    await pumpEventQueue();
    int listReads() => fake.requests
        .where((r) => r.method == 'GET' && r.path == '/api/db/notes')
        .length;
    expect(listReads(), 1);
    List<RecordedRequest> writes() =>
        fake.requests.where((r) => r.method != 'GET').toList();
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
    expect(writes().single.method, 'POST');
    expect(writes().single.path, '/api/db/notes');
    expect(writes().single.body, contains('"sequenceRunId":7'));

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
    expect(writes()[1].method, 'PUT');
    expect(writes()[1].body, contains('"clearTitle":true'));

    fake.setResponse(
      '/api/db/notes/note-1',
      method: 'DELETE',
      body: '{"status":"deleted"}',
    );
    expect(await repository.deleteNote('note-1'), 1);
    expect(writes()[2].method, 'DELETE');
    expect(writes()[2].path, '/api/db/notes/note-1');
    await pumpEventQueue();
    expect(
      listReads(),
      4,
      reason: 'each change re-reads the watched list without waiting',
    );
  });
}
