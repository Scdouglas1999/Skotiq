import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';

import '../database/database.dart' as db;
import '../models/notes/journal_note.dart';
import 'package:skotiq_astro/format.dart';

/// Persistence + business logic for per-target /
/// per-run notes.
///
/// Stores notes in the `notes_journal` table through [db.NotesJournalDao].
/// The service:
///   * Broadcasts a manual change-notification on every mutation so
///     consumers of [watchTargetNotes] / [watchRunNotes] see updates
///     without polling.
///   * Returns immutable [JournalNote] records — the row encoding lives
///     entirely inside this file.
///
/// Notes are deliberately not session-scoped: a note attached to target
/// "M31" remains visible the next time the operator opens M31, which is
/// the whole point of the journal feature.
class NotesService {
  final db.SkotiqDatabase _db;
  final Uuid _uuid;

  /// Mutation broadcaster. Every insert / update / delete emits a
  /// signal so subscribers of [watchTargetNotes] / [watchRunNotes] /
  /// [watchAllNotes] re-query. We deliberately don't pass payloads
  /// through this stream — every consumer re-reads the table because
  /// the queries are cheap (per-target indexes) and we want a single
  /// source of truth (the database row).
  final StreamController<void> _mutations = StreamController<void>.broadcast();

  NotesService(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  /// Test/inspection hook: lets a notification-only consumer (the
  /// session_report dialog after the user adds a note from there)
  /// also see the change. Production code uses the watch* streams.
  Stream<void> get mutationStream => _mutations.stream;

  Future<void> dispose() async {
    if (!_mutations.isClosed) await _mutations.close();
  }

  void _notifyMutated() {
    if (!_mutations.isClosed) _mutations.add(null);
  }

  /// Create a new note. Returns the freshly-persisted [JournalNote].
  ///
  /// An empty [targetId] throws [ArgumentError] rather than coercing to
  /// "Untargeted": the caller resolves the target before reaching this layer.
  Future<JournalNote> addNote({
    required String targetId,
    int? sequenceRunId,
    required String body,
    String? title,
    List<String> tags = const <String>[],
    List<String> attachments = const <String>[],
    String? sentiment,
  }) async {
    if (targetId.isEmpty) {
      throw ArgumentError.value(targetId, 'targetId', 'must be non-empty');
    }
    final now = DateTime.now();
    final note = JournalNote(
      id: _uuid.v4(),
      targetId: targetId,
      sequenceRunId: sequenceRunId,
      createdAt: now,
      updatedAt: now,
      title: (title == null || title.isEmpty) ? null : title,
      body: body,
      tags: List<String>.unmodifiable(tags),
      attachments: List<String>.unmodifiable(attachments),
      sentiment: sentiment,
    );
    await _db.notesJournalDao.insertNote(
      db.NotesJournalCompanion.insert(
        id: note.id,
        targetId: note.targetId,
        sequenceRunId: Value(note.sequenceRunId),
        createdAt: _toEpochMs(note.createdAt),
        updatedAt: _toEpochMs(note.updatedAt),
        title: Value(note.title),
        body: note.body,
        tagsJson: Value(JournalNote.encodeStringList(note.tags)),
        attachmentsJson: Value(JournalNote.encodeStringList(note.attachments)),
        sentiment: Value(note.sentiment),
      ),
    );
    _notifyMutated();
    return note;
  }

  /// Update an existing note's editable fields. Throws [StateError] when
  /// the note no longer exists. Pass `clearTitle: true` / `clearSentiment:
  /// true` to drop those optional fields explicitly (matching
  /// [JournalNote.copyWith]).
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
    final existing = await getNoteById(id);
    if (existing == null) {
      throw StateError('Note $id not found');
    }
    final updated = existing.copyWith(
      body: body,
      title: title,
      tags: tags,
      attachments: attachments,
      sentiment: sentiment,
      clearTitle: clearTitle,
      clearSentiment: clearSentiment,
      updatedAt: DateTime.now(),
    );
    await _db.notesJournalDao.updateNote(
      updated.id,
      db.NotesJournalCompanion(
        title: Value(updated.title),
        body: Value(updated.body),
        tagsJson: Value(JournalNote.encodeStringList(updated.tags)),
        attachmentsJson: Value(
          JournalNote.encodeStringList(updated.attachments),
        ),
        sentiment: Value(updated.sentiment),
        updatedAt: Value(_toEpochMs(updated.updatedAt)),
      ),
    );
    _notifyMutated();
    return updated;
  }

  /// Delete a single note by id. No-op when the id does not exist.
  Future<int> deleteNote(String id) async {
    final affected = await _db.notesJournalDao.deleteNote(id);
    if (affected > 0) _notifyMutated();
    return affected;
  }

  Future<JournalNote?> getNoteById(String id) async {
    final row = await _db.notesJournalDao.noteById(id);
    return row == null ? null : _rowToNote(row);
  }

  /// All notes attached to [targetId], chronological (oldest → newest).
  /// The display order — newest-first — is the caller's responsibility
  /// (most UI uses [JournalNote.createdAt] descending).
  Future<List<JournalNote>> notesForTarget(String targetId) async {
    final rows = await _db.notesJournalDao.notesForTarget(targetId);
    return rows.map(_rowToNote).toList();
  }

  /// All notes attached to a specific sequence run.
  Future<List<JournalNote>> notesForRun(int runId) async {
    final rows = await _db.notesJournalDao.notesForRun(runId);
    return rows.map(_rowToNote).toList();
  }

  /// Every note ever written, newest-first. Used by the global search
  /// UI and as a fallback when the targets directory enumerates all
  /// referenced target ids.
  Future<List<JournalNote>> allNotes() async {
    final rows = await _db.notesJournalDao.allNotes();
    return rows.map(_rowToNote).toList();
  }

  /// Search notes by free-text [query] (matches title or body, case
  /// insensitive) and/or [tags] (any-of). When both are supplied the
  /// match is the intersection. Returns newest-first.
  ///
  /// A tag matches as a whole: searching for "see" does not return a note
  /// tagged "seeing".
  Future<List<JournalNote>> searchNotes({
    String? query,
    List<String> tags = const <String>[],
  }) async {
    final rows = await _db.notesJournalDao.searchNotes(text: query, tags: tags);
    return rows.map(_rowToNote).toList();
  }

  /// Live stream of notes for [targetId]. Emits an initial snapshot
  /// immediately, then a fresh list on every insert / update / delete.
  Stream<List<JournalNote>> watchTargetNotes(String targetId) async* {
    yield await notesForTarget(targetId);
    await for (final _ in _mutations.stream) {
      yield await notesForTarget(targetId);
    }
  }

  /// Live stream of notes for a single sequence run.
  Stream<List<JournalNote>> watchRunNotes(int runId) async* {
    yield await notesForRun(runId);
    await for (final _ in _mutations.stream) {
      yield await notesForRun(runId);
    }
  }

  /// Live stream of every note. Useful for the global search results
  /// list and for tests.
  Stream<List<JournalNote>> watchAllNotes() async* {
    yield await allNotes();
    await for (final _ in _mutations.stream) {
      yield await allNotes();
    }
  }

  JournalNote _rowToNote(db.NotesJournalRow row) {
    return JournalNote(
      id: row.id,
      targetId: row.targetId,
      sequenceRunId: row.sequenceRunId,
      createdAt: _fromEpochMs(row.createdAt),
      updatedAt: _fromEpochMs(row.updatedAt),
      title: row.title,
      body: row.body,
      tags: JournalNote.decodeStringList(row.tagsJson),
      attachments: JournalNote.decodeStringList(row.attachmentsJson),
      sentiment: row.sentiment,
    );
  }

  static int _toEpochMs(DateTime t) => t.millisecondsSinceEpoch;
  static DateTime _fromEpochMs(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms);
}

/// Helper: build an auto-prompt note body from a finished run's stats.
///
/// Lives at the service-layer (not the UI) so it can be reused by tests
/// and by future programmatic consumers (e.g. the web remote). Returns a
/// short, multi-line markdown body that the user can edit before saving.
///
/// Why a helper rather than a static method on [SequenceRunStats]: the
/// stats model is in the providers layer (it's a Riverpod-friendly
/// mutable bag) and pulling it into models/notes would create a layering
/// inversion.
String buildAutoPromptNoteBody({
  required String sequenceName,
  required Duration wallClock,
  required int framesCaptured,
  required int framesRejected,
  required int triggerFires,
  required int autofocusRuns,
  required int meridianFlips,
  Map<String, int>? triggerBreakdown,
}) {
  final buf = StringBuffer();
  buf.writeln(
    '**$sequenceName** completed in ${DurationFormat.of(wallClock)}.',
  );
  buf.writeln();
  buf.writeln(
    '- Frames captured: $framesCaptured'
    '${framesRejected > 0 ? ' ($framesRejected rejected)' : ''}',
  );
  if (autofocusRuns > 0) {
    buf.writeln('- Autofocus runs: $autofocusRuns');
  }
  if (meridianFlips > 0) {
    buf.writeln('- Meridian flips: $meridianFlips');
  }
  if (triggerFires > 0) {
    if (triggerBreakdown != null && triggerBreakdown.isNotEmpty) {
      final summary = triggerBreakdown.entries
          .map((e) => '${e.key} x${e.value}')
          .join(', ');
      buf.writeln('- Triggers fired: $summary');
    } else {
      buf.writeln('- Triggers fired: $triggerFires');
    }
  }
  buf.writeln();
  buf.writeln('_Anything to remember about this run?_');
  return buf.toString();
}
