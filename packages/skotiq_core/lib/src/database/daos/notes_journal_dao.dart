import 'package:drift/drift.dart';

import '../database.dart';

part 'notes_journal_dao.g.dart';

/// Reads and writes for the `notes_journal` table. Every list is newest
/// first.
@DriftAccessor(include: {'../schema/run_records.drift'})
class NotesJournalDao extends DatabaseAccessor<SkotiqDatabase>
    with _$NotesJournalDaoMixin {
  NotesJournalDao(super.db);

  Future<void> insertNote(NotesJournalCompanion note) =>
      into(notesJournal).insert(note);

  Future<void> updateNote(String id, NotesJournalCompanion changes) =>
      (update(notesJournal)..where((n) => n.id.equals(id))).write(changes);

  /// Returns how many rows were deleted (0 when the id is unknown).
  Future<int> deleteNote(String id) =>
      (delete(notesJournal)..where((n) => n.id.equals(id))).go();

  Future<NotesJournalRow?> noteById(String id) =>
      (select(notesJournal)..where((n) => n.id.equals(id))).getSingleOrNull();

  Future<List<NotesJournalRow>> notesForTarget(String targetId) =>
      (_newestFirst()..where((n) => n.targetId.equals(targetId))).get();

  Future<List<NotesJournalRow>> notesForRun(int runId) =>
      (_newestFirst()..where((n) => n.sequenceRunId.equals(runId))).get();

  Future<List<NotesJournalRow>> allNotes() => _newestFirst().get();

  /// Notes whose title or body contains [text] (compared in lower case) and
  /// that carry every one of [tags].
  Future<List<NotesJournalRow>> searchNotes({
    String? text,
    List<String> tags = const <String>[],
  }) {
    final query = _newestFirst();
    if (text != null && text.isNotEmpty) {
      final like = '%${text.toLowerCase()}%';
      query.where(
        (n) =>
            n.body.lower().like(like) |
            coalesce<String>([n.title, const Constant('')]).lower().like(like),
      );
    }
    for (final tag in tags) {
      // Quoted as it is inside the JSON array, so "see" does not match a
      // note tagged "seeing".
      query.where((n) => n.tagsJson.like('%"$tag"%'));
    }
    return query.get();
  }

  SimpleSelectStatement<NotesJournal, NotesJournalRow> _newestFirst() =>
      select(notesJournal)..orderBy([(n) => OrderingTerm.desc(n.createdAt)]);
}
