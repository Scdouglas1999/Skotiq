import '../../../models/notes/journal_note.dart';

/// The notes journal kept in the imaging host's database: notes on a target
/// and on a sequence run.
///
/// Every watch yields its notes newest first and again after each change.
abstract interface class NotesJournal {
  Stream<List<JournalNote>> watchTargetNotes(String targetId);

  Stream<List<JournalNote>> watchRunNotes(int runId);

  Stream<List<JournalNote>> watchAllNotes();

  /// An empty [targetId] is refused: the caller resolves the target first.
  Future<JournalNote> addNote({
    required String targetId,
    int? sequenceRunId,
    required String body,
    String? title,
    List<String> tags = const <String>[],
    List<String> attachments = const <String>[],
    String? sentiment,
  });

  /// A null field is left alone; [clearTitle] and [clearSentiment] remove
  /// those two.
  Future<JournalNote> updateNote(
    String id, {
    String? body,
    String? title,
    List<String>? tags,
    List<String>? attachments,
    String? sentiment,
    bool clearTitle = false,
    bool clearSentiment = false,
  });

  /// Returns the number of notes deleted.
  Future<int> deleteNote(String id);
}
