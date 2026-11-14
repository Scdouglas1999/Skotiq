import 'package:flutter/foundation.dart' show listEquals;

import '../../../models/notes/journal_note.dart';
import '../../roles/host_data/host_notes.dart';
import '../../roles/host_data/notes_journal.dart';
import 'host_poll.dart';

/// The notes journal of a linked host. The host announces no note changes,
/// so the lists are polled, and re-read at once after a change made here.
final class RemoteNotesJournal implements NotesJournal {
  RemoteNotesJournal(this._host);

  final HostNotes _host;
  final _poll = HostPoll('journal notes');

  Stream<List<JournalNote>> _watch({String? targetId, int? runId}) =>
      _poll.watch(() async {
        final page = await _host.fetchJournalNotes(
          targetId: targetId,
          runId: runId,
        );
        return [...page.items]
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      }, listEquals);

  @override
  Stream<List<JournalNote>> watchTargetNotes(String targetId) =>
      _watch(targetId: targetId);

  @override
  Stream<List<JournalNote>> watchRunNotes(int runId) => _watch(runId: runId);

  @override
  Stream<List<JournalNote>> watchAllNotes() => _watch();

  @override
  Future<JournalNote> addNote({
    required String targetId,
    int? sequenceRunId,
    required String body,
    String? title,
    List<String> tags = const <String>[],
    List<String> attachments = const <String>[],
    String? sentiment,
  }) async {
    final note = await _host.createJournalNote(
      targetId: targetId,
      sequenceRunId: sequenceRunId,
      body: body,
      title: title,
      tags: tags,
      attachments: attachments,
      sentiment: sentiment,
    );
    _poll.refresh();
    return note;
  }

  @override
  Future<JournalNote> updateNote(
    String id, {
    String? body,
    String? title,
    List<String>? tags,
    List<String>? attachments,
    String? sentiment,
    bool clearTitle = false,
    bool clearSentiment = false,
  }) async {
    final note = await _host.updateJournalNote(
      id,
      body: body,
      title: title,
      tags: tags,
      attachments: attachments,
      sentiment: sentiment,
      clearTitle: clearTitle,
      clearSentiment: clearSentiment,
    );
    _poll.refresh();
    return note;
  }

  @override
  Future<int> deleteNote(String id) async {
    await _host.deleteJournalNote(id);
    _poll.refresh();
    return 1;
  }
}
