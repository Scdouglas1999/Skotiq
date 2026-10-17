// Conversational sequence builder: history persistence.
//
// Every successful (or failed) conversational build is logged to a
// dedicated table so the user can see what they've asked the AI to
// build and what came back. The history is also surfaced in the
// Sequencer history tab labelled as "Conversational" entries.
//
// We follow the same DDL convention NotesService uses:
// the table is created with `IF NOT EXISTS` on first access so the
// service stays tolerant of a database that pre-dates this feature.
// This keeps the schema migration out of the drift-codegen path and
// avoids forcing every developer to re-run `melos run generate` just
// to land a new feature table.

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../database/database.dart' as db;
import 'llm_provider.dart';

/// One entry in the conversational build history.
class ConversationalHistoryEntry {
  final String id;
  final DateTime createdAt;

  /// The prompt the user typed.
  final String userPrompt;

  /// Which provider answered.
  final String providerName;

  /// Provider kind storage key — round-trips through
  /// [LlmProviderKindLabel.fromStorageKey] for display.
  final String providerKind;

  /// Number of LLM round-trips taken.
  final int rounds;

  /// True iff the final attempt produced an error-free sequence.
  final bool successful;

  /// Token usage rolled up across rounds. Null when the provider
  /// didn't report usage.
  final LlmUsage? usage;

  /// JSON-encoded list of validation issues from the final attempt.
  /// We store the full structured list rather than just the count so
  /// the UI can re-render the issue chips without re-running the
  /// validator.
  final String issuesJson;

  /// The Sequence id we loaded into the editor (when the user
  /// accepted). Null when the user rejected the result or it was
  /// invalid.
  final String? acceptedSequenceId;

  /// The composed system prompt (gzipped is overkill; LLM system
  /// prompts are ~3-5 KB) — kept for "show details" in the dialog.
  final String systemPrompt;

  /// Raw model replies as a JSON-encoded array (one string per round).
  /// Logged for forensics — bug reports often need the verbatim model
  /// reply to figure out why the parser rejected it.
  final String repliesJson;

  const ConversationalHistoryEntry({
    required this.id,
    required this.createdAt,
    required this.userPrompt,
    required this.providerName,
    required this.providerKind,
    required this.rounds,
    required this.successful,
    required this.usage,
    required this.issuesJson,
    required this.acceptedSequenceId,
    required this.systemPrompt,
    required this.repliesJson,
  });
}

/// CRUD + reactive watch for the `conversational_builds` table.
class ConversationalHistoryService {
  static const String _tableSql =
      'CREATE TABLE IF NOT EXISTS conversational_builds ('
      'id TEXT PRIMARY KEY NOT NULL,'
      'created_at INTEGER NOT NULL,'
      'user_prompt TEXT NOT NULL,'
      'provider_name TEXT NOT NULL,'
      'provider_kind TEXT NOT NULL,'
      'rounds INTEGER NOT NULL,'
      'successful INTEGER NOT NULL,'
      'prompt_tokens INTEGER,'
      'completion_tokens INTEGER,'
      'total_tokens INTEGER,'
      'issues_json TEXT NOT NULL DEFAULT \'[]\','
      'accepted_sequence_id TEXT,'
      'system_prompt TEXT NOT NULL DEFAULT \'\','
      'replies_json TEXT NOT NULL DEFAULT \'[]\''
      ')';

  static const String _createdIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_conversational_builds_created '
      'ON conversational_builds (created_at)';

  final db.SkotiqDatabase _db;
  final Uuid _uuid;
  bool _schemaEnsured = false;

  final StreamController<void> _mutations = StreamController<void>.broadcast();

  ConversationalHistoryService(this._db, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  Stream<void> get mutationStream => _mutations.stream;

  Future<void> dispose() async {
    if (!_mutations.isClosed) await _mutations.close();
  }

  Future<void> _ensureSchema() async {
    if (_schemaEnsured) return;
    await _db.customStatement(_tableSql);
    await _db.customStatement(_createdIndexSql);
    _schemaEnsured = true;
  }

  /// Record a new conversational build attempt.
  Future<ConversationalHistoryEntry> record({
    required String userPrompt,
    required String providerName,
    required LlmProviderKind providerKind,
    required int rounds,
    required bool successful,
    required LlmUsage? usage,
    required List<Map<String, dynamic>> issueRecords,
    required String? acceptedSequenceId,
    required String systemPrompt,
    required List<String> rawReplies,
  }) async {
    await _ensureSchema();
    final entry = ConversationalHistoryEntry(
      id: _uuid.v4(),
      createdAt: DateTime.now(),
      userPrompt: userPrompt,
      providerName: providerName,
      providerKind: providerKind.storageKey,
      rounds: rounds,
      successful: successful,
      usage: usage,
      issuesJson: jsonEncode(issueRecords),
      acceptedSequenceId: acceptedSequenceId,
      systemPrompt: systemPrompt,
      repliesJson: jsonEncode(rawReplies),
    );
    await _db.customStatement(
      'INSERT INTO conversational_builds ('
      'id, created_at, user_prompt, provider_name, provider_kind, '
      'rounds, successful, prompt_tokens, completion_tokens, total_tokens, '
      'issues_json, accepted_sequence_id, system_prompt, replies_json'
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        entry.id,
        entry.createdAt.millisecondsSinceEpoch,
        entry.userPrompt,
        entry.providerName,
        entry.providerKind,
        entry.rounds,
        entry.successful ? 1 : 0,
        entry.usage?.promptTokens,
        entry.usage?.completionTokens,
        entry.usage?.totalTokens,
        entry.issuesJson,
        entry.acceptedSequenceId,
        entry.systemPrompt,
        entry.repliesJson,
      ],
    );
    if (!_mutations.isClosed) _mutations.add(null);
    return entry;
  }

  /// Stamp an existing entry with the sequence id the user accepted.
  /// Used after the user clicks "Accept" in the dialog — we don't
  /// want to lose the prompt history if they accept later.
  Future<void> markAccepted(String entryId, String sequenceId) async {
    await _ensureSchema();
    final affected = await _db.customUpdate(
      'UPDATE conversational_builds SET accepted_sequence_id = ? '
      'WHERE id = ?',
      variables: [
        Variable.withString(sequenceId),
        Variable.withString(entryId),
      ],
    );
    if (affected > 0 && !_mutations.isClosed) _mutations.add(null);
  }

  /// Fetch the most recent N entries, newest first.
  Future<List<ConversationalHistoryEntry>> recent({int limit = 50}) async {
    await _ensureSchema();
    final rows = await _db
        .customSelect(
          'SELECT * FROM conversational_builds '
          'ORDER BY created_at DESC LIMIT ?',
          variables: [Variable.withInt(limit)],
        )
        .get();
    return rows.map(_rowToEntry).toList();
  }

  Future<int> deleteEntry(String id) async {
    await _ensureSchema();
    final affected = await _db.customUpdate(
      'DELETE FROM conversational_builds WHERE id = ?',
      variables: [Variable.withString(id)],
    );
    if (affected > 0 && !_mutations.isClosed) _mutations.add(null);
    return affected;
  }

  /// Reactive watch — emits a fresh snapshot on every record / delete.
  Stream<List<ConversationalHistoryEntry>> watch({int limit = 50}) async* {
    yield await recent(limit: limit);
    await for (final _ in _mutations.stream) {
      yield await recent(limit: limit);
    }
  }

  ConversationalHistoryEntry _rowToEntry(QueryRow row) {
    final pt = row.readNullable<int>('prompt_tokens');
    final ct = row.readNullable<int>('completion_tokens');
    final tt = row.readNullable<int>('total_tokens');
    LlmUsage? usage;
    if (pt != null || ct != null || tt != null) {
      usage = LlmUsage(
        promptTokens: pt ?? 0,
        completionTokens: ct ?? 0,
        totalTokens: tt ?? ((pt ?? 0) + (ct ?? 0)),
      );
    }
    return ConversationalHistoryEntry(
      id: row.read<String>('id'),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('created_at'),
      ),
      userPrompt: row.read<String>('user_prompt'),
      providerName: row.read<String>('provider_name'),
      providerKind: row.read<String>('provider_kind'),
      rounds: row.read<int>('rounds'),
      successful: row.read<int>('successful') == 1,
      usage: usage,
      issuesJson: row.read<String>('issues_json'),
      acceptedSequenceId: row.readNullable<String>('accepted_sequence_id'),
      systemPrompt: row.read<String>('system_prompt'),
      repliesJson: row.read<String>('replies_json'),
    );
  }
}
