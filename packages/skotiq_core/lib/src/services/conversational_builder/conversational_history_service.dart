// Conversational sequence builder: history persistence.
//
// Every successful (or failed) conversational build is logged to a
// dedicated table so the user can see what they've asked the AI to
// build and what came back. The history is also surfaced in the
// Sequencer history tab labelled as "Conversational" entries.

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
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
  final db.SkotiqDatabase _db;
  final Uuid _uuid;

  final StreamController<void> _mutations = StreamController<void>.broadcast();

  ConversationalHistoryService(this._db, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  Stream<void> get mutationStream => _mutations.stream;

  Future<void> dispose() async {
    if (!_mutations.isClosed) await _mutations.close();
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
    await _db.conversationalBuildsDao.insertBuild(
      db.ConversationalBuildsCompanion.insert(
        id: entry.id,
        createdAt: entry.createdAt.millisecondsSinceEpoch,
        userPrompt: entry.userPrompt,
        providerName: entry.providerName,
        providerKind: entry.providerKind,
        rounds: entry.rounds,
        successful: entry.successful ? 1 : 0,
        promptTokens: Value(entry.usage?.promptTokens),
        completionTokens: Value(entry.usage?.completionTokens),
        totalTokens: Value(entry.usage?.totalTokens),
        issuesJson: Value(entry.issuesJson),
        acceptedSequenceId: Value(entry.acceptedSequenceId),
        systemPrompt: Value(entry.systemPrompt),
        repliesJson: Value(entry.repliesJson),
      ),
    );
    if (!_mutations.isClosed) _mutations.add(null);
    return entry;
  }

  /// Stamp an existing entry with the sequence id the user accepted.
  /// Used after the user clicks "Accept" in the dialog — we don't
  /// want to lose the prompt history if they accept later.
  Future<void> markAccepted(String entryId, String sequenceId) async {
    final affected = await _db.conversationalBuildsDao.setAcceptedSequence(
      entryId,
      sequenceId,
    );
    if (affected > 0 && !_mutations.isClosed) _mutations.add(null);
  }

  /// Fetch the most recent N entries, newest first.
  Future<List<ConversationalHistoryEntry>> recent({int limit = 50}) async {
    final rows = await _db.conversationalBuildsDao.recentBuilds(limit);
    return rows.map(_rowToEntry).toList();
  }

  Future<int> deleteEntry(String id) async {
    final affected = await _db.conversationalBuildsDao.deleteBuild(id);
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

  ConversationalHistoryEntry _rowToEntry(db.ConversationalBuildRow row) {
    final pt = row.promptTokens;
    final ct = row.completionTokens;
    final tt = row.totalTokens;
    LlmUsage? usage;
    if (pt != null || ct != null || tt != null) {
      usage = LlmUsage(
        promptTokens: pt ?? 0,
        completionTokens: ct ?? 0,
        totalTokens: tt ?? ((pt ?? 0) + (ct ?? 0)),
      );
    }
    return ConversationalHistoryEntry(
      id: row.id,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      userPrompt: row.userPrompt,
      providerName: row.providerName,
      providerKind: row.providerKind,
      rounds: row.rounds,
      successful: row.successful == 1,
      usage: usage,
      issuesJson: row.issuesJson,
      acceptedSequenceId: row.acceptedSequenceId,
      systemPrompt: row.systemPrompt,
      repliesJson: row.repliesJson,
    );
  }
}
