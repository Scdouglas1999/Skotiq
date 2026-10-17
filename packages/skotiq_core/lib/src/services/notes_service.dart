import 'dart:async';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database/database.dart' as db;
import '../models/notes/journal_note.dart';
import '../utils/duration_format.dart';

/// Persistence + business logic for per-target /
/// per-run notes.
///
/// Manages the `notes_journal` table directly with raw SQL: the table
/// lives outside the `@DriftDatabase` declaration to avoid forcing a
/// codegen pass (same convention as the v27 scheduler tables and the
/// v28 defect_maps table). The service:
///   * Lazily ensures the schema on first access via [_ensureSchema] so
///     a freshly-installed service is tolerant of a pre-v29 connection.
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
  /// SQL schema, kept here so a single source declares the table shape.
  /// Mirrors the migration block in `database.dart` v29 and the fresh
  /// install bootstrap in `_createCustomIndexes`. Idempotent: every
  /// statement is `IF NOT EXISTS`.
  static const String schemaCreateTableSql =
      'CREATE TABLE IF NOT EXISTS notes_journal ('
      'id TEXT PRIMARY KEY NOT NULL,'
      'target_id TEXT NOT NULL,'
      'sequence_run_id INTEGER,'
      'created_at INTEGER NOT NULL,'
      'updated_at INTEGER NOT NULL,'
      'title TEXT,'
      'body TEXT NOT NULL,'
      'tags_json TEXT NOT NULL DEFAULT \'[]\','
      'attachments_json TEXT NOT NULL DEFAULT \'[]\','
      'sentiment TEXT)';

  static const String schemaTargetIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_notes_journal_target '
      'ON notes_journal (target_id)';
  static const String schemaRunIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_notes_journal_run '
      'ON notes_journal (sequence_run_id)';
  static const String schemaCreatedIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_notes_journal_created '
      'ON notes_journal (created_at)';

  final db.SkotiqDatabase _db;
  bool _schemaEnsured = false;
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

  Future<void> _ensureSchema() async {
    if (_schemaEnsured) return;
    await _db.customStatement(schemaCreateTableSql);
    await _db.customStatement(schemaTargetIndexSql);
    await _db.customStatement(schemaRunIndexSql);
    await _db.customStatement(schemaCreatedIndexSql);
    _schemaEnsured = true;
  }

  void _notifyMutated() {
    if (!_mutations.isClosed) _mutations.add(null);
  }

  // CRUD

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
    await _ensureSchema();
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
    await _db.customStatement(
      'INSERT INTO notes_journal '
      '(id, target_id, sequence_run_id, created_at, updated_at, '
      'title, body, tags_json, attachments_json, sentiment) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        note.id,
        note.targetId,
        note.sequenceRunId,
        _toEpochMs(note.createdAt),
        _toEpochMs(note.updatedAt),
        note.title,
        note.body,
        JournalNote.encodeStringList(note.tags),
        JournalNote.encodeStringList(note.attachments),
        note.sentiment,
      ],
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
    await _ensureSchema();
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
    await _db.customStatement(
      'UPDATE notes_journal SET '
      'title = ?, body = ?, tags_json = ?, attachments_json = ?, '
      'sentiment = ?, updated_at = ? WHERE id = ?',
      [
        updated.title,
        updated.body,
        JournalNote.encodeStringList(updated.tags),
        JournalNote.encodeStringList(updated.attachments),
        updated.sentiment,
        _toEpochMs(updated.updatedAt),
        updated.id,
      ],
    );
    _notifyMutated();
    return updated;
  }

  /// Delete a single note by id. No-op when the id does not exist.
  Future<int> deleteNote(String id) async {
    await _ensureSchema();
    final affected = await _db.customUpdate(
      'DELETE FROM notes_journal WHERE id = ?',
      variables: [Variable.withString(id)],
    );
    if (affected > 0) _notifyMutated();
    return affected;
  }

  // Reads

  Future<JournalNote?> getNoteById(String id) async {
    await _ensureSchema();
    final rows = await _db
        .customSelect(
          'SELECT * FROM notes_journal WHERE id = ?',
          variables: [Variable.withString(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _rowToNote(rows.first);
  }

  /// All notes attached to [targetId], chronological (oldest → newest).
  /// The display order — newest-first — is the caller's responsibility
  /// (most UI uses [JournalNote.createdAt] descending).
  Future<List<JournalNote>> notesForTarget(String targetId) async {
    await _ensureSchema();
    final rows = await _db
        .customSelect(
          'SELECT * FROM notes_journal WHERE target_id = ? '
          'ORDER BY created_at DESC',
          variables: [Variable.withString(targetId)],
        )
        .get();
    return rows.map(_rowToNote).toList();
  }

  /// All notes attached to a specific sequence run.
  Future<List<JournalNote>> notesForRun(int runId) async {
    await _ensureSchema();
    final rows = await _db
        .customSelect(
          'SELECT * FROM notes_journal WHERE sequence_run_id = ? '
          'ORDER BY created_at DESC',
          variables: [Variable.withInt(runId)],
        )
        .get();
    return rows.map(_rowToNote).toList();
  }

  /// Every note ever written, newest-first. Used by the global search
  /// UI and as a fallback when the targets directory enumerates all
  /// referenced target ids.
  Future<List<JournalNote>> allNotes() async {
    await _ensureSchema();
    final rows = await _db
        .customSelect('SELECT * FROM notes_journal ORDER BY created_at DESC')
        .get();
    return rows.map(_rowToNote).toList();
  }

  /// Search notes by free-text [query] (matches title or body, case
  /// insensitive) and/or [tags] (any-of). When both are supplied the
  /// match is the intersection. Returns newest-first.
  ///
  /// The tag predicate uses a LIKE on the JSON-encoded tags blob, which
  /// is acceptable for the small per-user dataset. We wrap the tag in
  /// `"..."` to avoid matching substrings of other tag names (e.g.
  /// "see" matching "seeing").
  Future<List<JournalNote>> searchNotes({
    String? query,
    List<String> tags = const <String>[],
  }) async {
    await _ensureSchema();
    final clauses = <String>[];
    final variables = <Variable>[];
    if (query != null && query.isNotEmpty) {
      clauses.add("(LOWER(body) LIKE ? OR LOWER(COALESCE(title, '')) LIKE ?)");
      final like = '%${query.toLowerCase()}%';
      variables.add(Variable.withString(like));
      variables.add(Variable.withString(like));
    }
    for (final tag in tags) {
      // Match the tag wrapped in JSON-string quotes so we don't match
      // partial tag strings. e.g. searching for "see" must NOT match
      // a note tagged "seeing".
      clauses.add('tags_json LIKE ?');
      variables.add(Variable.withString('%"$tag"%'));
    }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')} ';
    final rows = await _db
        .customSelect(
          'SELECT * FROM notes_journal ${where}ORDER BY created_at DESC',
          variables: variables,
        )
        .get();
    return rows.map(_rowToNote).toList();
  }

  // Reactive streams

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

  // Internals

  JournalNote _rowToNote(QueryRow row) {
    return JournalNote(
      id: row.read<String>('id'),
      targetId: row.read<String>('target_id'),
      sequenceRunId: row.readNullable<int>('sequence_run_id'),
      createdAt: _fromEpochMs(row.read<int>('created_at')),
      updatedAt: _fromEpochMs(row.read<int>('updated_at')),
      title: row.readNullable<String>('title'),
      body: row.read<String>('body'),
      tags: JournalNote.decodeStringList(row.readNullable<String>('tags_json')),
      attachments: JournalNote.decodeStringList(
        row.readNullable<String>('attachments_json'),
      ),
      sentiment: row.readNullable<String>('sentiment'),
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
