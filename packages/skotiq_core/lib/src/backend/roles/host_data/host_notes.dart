import 'package:skotiq_core/skotiq_core.dart';

/// The notes journal of a linked imaging host.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostNotes {
  Future<RemotePage<RemoteJournalNote>> fetchJournalNotes({
    String? targetId,
    int? runId,
  });

  Future<RemoteJournalNote> createJournalNote({
    required String targetId,
    int? sequenceRunId,
    required String body,
    String? title,
    List<String> tags = const <String>[],
    List<String> attachments = const <String>[],
    String? sentiment,
  });

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

  Future<void> deleteJournalNote(String id);
}
