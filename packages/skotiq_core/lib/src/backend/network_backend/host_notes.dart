part of '../network_backend.dart';

/// The notes journal of a linked imaging host.
mixin HostNotes on NetworkBackendTransport {
  /// GET /api/db/notes?targetId=&runId=
  ///
  /// The operator's per-target / per-run journal notes (the `notes_journal`
  /// table). Distinct from [fetchNotesJournal], which despite its name serves
  /// the `observation_logs` table. With no filter it returns every note;
  /// [targetId] / [runId] scope it for the family providers.
  Future<RemotePage<JournalNote>> fetchJournalNotes({
    String? targetId,
    int? runId,
  }) async {
    final response = await _get(
      DbReadApi.listJournalNotes,
      query: {
        if (targetId != null && targetId.isNotEmpty) 'targetId': targetId,
        if (runId != null) 'runId': runId.toString(),
      },
    );
    return RemotePage.fromJson(response, JournalNote.fromJson);
  }

  /// POST /api/db/notes
  Future<JournalNote> createJournalNote({
    required String targetId,
    int? sequenceRunId,
    required String body,
    String? title,
    List<String> tags = const <String>[],
    List<String> attachments = const <String>[],
    String? sentiment,
  }) async {
    // Creating a note is not idempotent because the host assigns its UUID.
    // Avoid duplicating it after an ambiguous timeout.
    final response = await _post(
      DbReadApi.createJournalNote,
      body: {
        'targetId': targetId,
        if (sequenceRunId != null) 'sequenceRunId': sequenceRunId,
        'body': body,
        if (title != null) 'title': title,
        'tags': tags,
        'attachments': attachments,
        if (sentiment != null) 'sentiment': sentiment,
      },
      maxAttempts: 1,
    );
    return _journalNoteFromMutationResponse(response);
  }

  /// PUT `/api/db/notes/<id>`
  Future<JournalNote> updateJournalNote(
    String id, {
    String? body,
    String? title,
    List<String>? tags,
    List<String>? attachments,
    String? sentiment,
    bool clearTitle = false,
    bool clearSentiment = false,
  }) async {
    final response = await _put(
      DbReadApi.updateJournalNote,
      path: {'id': id},
      body: {
        if (body != null) 'body': body,
        if (title != null) 'title': title,
        if (tags != null) 'tags': tags,
        if (attachments != null) 'attachments': attachments,
        if (sentiment != null) 'sentiment': sentiment,
        'clearTitle': clearTitle,
        'clearSentiment': clearSentiment,
      },
    );
    return _journalNoteFromMutationResponse(response);
  }

  /// DELETE `/api/db/notes/<id>`
  Future<void> deleteJournalNote(String id) =>
      _delete(DbReadApi.deleteJournalNote, path: {'id': id});
}
