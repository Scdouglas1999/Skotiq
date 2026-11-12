import '../../../models/notes/journal_note.dart';
import 'package:skotiq_remote_protocol/wire_models.dart';

/// The notes journal of a linked imaging host.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostNotes {
  Future<RemotePage<JournalNote>> fetchJournalNotes({
    String? targetId,
    int? runId,
  });

  Future<JournalNote> createJournalNote({
    required String targetId,
    int? sequenceRunId,
    required String body,
    String? title,
    List<String> tags = const <String>[],
    List<String> attachments = const <String>[],
    String? sentiment,
  });

  Future<JournalNote> updateJournalNote(
    String id, {
    String? body,
    String? title,
    List<String>? tags,
    List<String>? attachments,
    String? sentiment,
    bool clearTitle = false,
    bool clearSentiment = false,
  });

  Future<void> deleteJournalNote(String id);
}
