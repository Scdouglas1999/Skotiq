import 'dart:convert';

import 'package:equatable/equatable.dart';

/// Single per-target / per-run journal entry.
///
/// Notes are written by the operator after (or during) a session to record
/// what worked, what didn't, calibration quirks, equipment oddities, and
/// observations that don't fit the rigid `imaging_sessions.notes` blob. A
/// note is keyed by a UUID and is anchored to a logical `targetId` (catalog
/// id like "M31" or display name); optionally it can also be linked to a
/// specific [sequenceRunId] when the observation is run-scoped.
///
/// The model is intentionally flat — no nested freezed types — because:
///   * Notes are stored via raw SQL through [NotesService] (the table lives
///     outside `@DriftDatabase` for the same reason the scheduler tables
///     do), and a flat record matches the row shape one-for-one.
///   * The UI never needs to share sub-records with other models.
class JournalNote extends Equatable {
  /// Stable UUID string; never regenerated on update.
  final String id;

  /// Logical target identifier (catalog id like "M31" when known,
  /// otherwise the display name). Always non-empty.
  final String targetId;

  /// Optional link to the `sequence_runs.id` of the run this note
  /// describes. `null` for target-scoped notes that span multiple runs.
  final int? sequenceRunId;

  /// First-created timestamp.
  final DateTime createdAt;

  /// Last-updated timestamp; equal to [createdAt] until edited.
  final DateTime updatedAt;

  /// Optional short title. `null` or empty hides the heading in the UI.
  final String? title;

  /// Markdown body. May be empty (the auto-prompt sometimes saves a
  /// note with only a sentiment).
  final String body;

  /// Sorted list of tag strings. Empty when none.
  final List<String> tags;

  /// Sorted list of absolute attachment paths. Empty when none.
  final List<String> attachments;

  /// Optional sentiment emoji (`😊` / `😐` / `😞`). `null` when not set.
  final String? sentiment;

  const JournalNote({
    required this.id,
    required this.targetId,
    required this.sequenceRunId,
    required this.createdAt,
    required this.updatedAt,
    required this.title,
    required this.body,
    required this.tags,
    required this.attachments,
    required this.sentiment,
  });

  JournalNote copyWith({
    String? id,
    String? targetId,
    int? sequenceRunId,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? title,
    String? body,
    List<String>? tags,
    List<String>? attachments,
    String? sentiment,
    bool clearSequenceRunId = false,
    bool clearTitle = false,
    bool clearSentiment = false,
  }) {
    return JournalNote(
      id: id ?? this.id,
      targetId: targetId ?? this.targetId,
      sequenceRunId: clearSequenceRunId
          ? null
          : (sequenceRunId ?? this.sequenceRunId),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      title: clearTitle ? null : (title ?? this.title),
      body: body ?? this.body,
      tags: tags ?? this.tags,
      attachments: attachments ?? this.attachments,
      sentiment: clearSentiment ? null : (sentiment ?? this.sentiment),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'targetId': targetId,
    'sequenceRunId': sequenceRunId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'title': title,
    'body': body,
    'tags': tags,
    'attachments': attachments,
    'sentiment': sentiment,
  };

  /// Decode the JSON-encoded `tags_json` / `attachments_json` columns into
  /// a list of strings. Tolerates malformed payloads by returning an empty
  /// list — a corrupted blob should not crash the notes panel.
  static List<String> decodeStringList(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toList(growable: false);
      }
    } on FormatException {
      // Fall through to the empty fallback: a non-JSON tags column renders as
      // visibly no tags, which the user can see and fix, rather than taking
      // the notes panel down.
    }
    return const <String>[];
  }

  /// Inverse of [decodeStringList]; always produces valid JSON.
  static String encodeStringList(List<String> values) => jsonEncode(values);

  @override
  List<Object?> get props => [
    id,
    targetId,
    sequenceRunId,
    createdAt,
    updatedAt,
    title,
    body,
    tags,
    attachments,
    sentiment,
  ];
}
