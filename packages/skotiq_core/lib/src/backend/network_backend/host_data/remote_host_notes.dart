import 'package:skotiq_core/skotiq_core.dart';

/// [HostNotes] on a linked host.
final class RemoteHostNotes implements HostNotes {
  RemoteHostNotes(this._host);

  final NetworkBackend _host;

  @override
  Future<RemotePage<RemoteJournalNote>> fetchJournalNotes({
    String? targetId,
    int? runId,
  }) => _host.fetchJournalNotes(targetId: targetId, runId: runId);

  @override
  Future<RemoteJournalNote> createJournalNote({
    required String targetId,
    int? sequenceRunId,
    required String body,
    String? title,
    List<String> tags = const <String>[],
    List<String> attachments = const <String>[],
    String? sentiment,
  }) => _host.createJournalNote(
    targetId: targetId,
    sequenceRunId: sequenceRunId,
    body: body,
    title: title,
    tags: tags,
    attachments: attachments,
    sentiment: sentiment,
  );

  @override
  Future<RemoteJournalNote> updateJournalNote(
    String id, {
    String? body,
    String? title,
    List<String>? tags,
    List<String>? attachments,
    String? sentiment,
    bool clearTitle = false,
    bool clearSentiment = false,
  }) => _host.updateJournalNote(
    id,
    body: body,
    title: title,
    tags: tags,
    attachments: attachments,
    sentiment: sentiment,
    clearTitle: clearTitle,
    clearSentiment: clearSentiment,
  );

  @override
  Future<void> deleteJournalNote(String id) => _host.deleteJournalNote(id);
}
