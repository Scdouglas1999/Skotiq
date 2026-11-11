import 'package:skotiq_core/skotiq_core.dart';

/// The notes journal of a linked imaging host.
abstract interface class HostNotes {
  /// GET /api/db/notes?targetId=&runId=
  ///
  /// The operator's per-target / per-run journal notes (the `notes_journal`
  /// table). Distinct from [fetchNotesJournal], which despite its name serves
  /// the `observation_logs` table. With no filter it returns every note;
  /// [targetId] / [runId] scope it for the family providers.
  Future<RemotePage<RemoteJournalNote>> fetchJournalNotes({
    String? targetId,
    int? runId,
  });

  /// POST /api/db/notes
  Future<RemoteJournalNote> createJournalNote({
    required String targetId,
    int? sequenceRunId,
    required String body,
    String? title,
    List<String> tags = const <String>[],
    List<String> attachments = const <String>[],
    String? sentiment,
  });

  /// PUT `/api/db/notes/<id>`
  Future<RemoteJournalNote> updateJournalNote(
    String id, {
    String? body,
    String? title,
    List<String>? tags,
    List<String>? attachments,
    String? sentiment,
    bool clearTitle = false,
    bool clearSentiment = false,
  });

  /// DELETE `/api/db/notes/<id>`
  Future<void> deleteJournalNote(String id);
}
