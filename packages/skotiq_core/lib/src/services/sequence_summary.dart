import 'dart:convert';

/// Lightweight, display-only roll-up of a saved sequence for the library list.
///
/// Built by [SequenceRepository.loadSequenceSummaries] from a single grouped
/// DAO query (plus a batched run-history roll-up) so rendering the library does
/// NOT hydrate every sequence's full node tree — the N+1 that
/// `loadAllSequences` incurs. Every field here is derivable from persisted
/// columns; nothing requires decoding node properties beyond the primary
/// target name.
class SequenceSummary {
  /// `sequences.id` — the database row id (stable handle for open/edit).
  final int id;

  /// Display name.
  final String name;

  /// Total number of nodes in the sequence (all categories).
  final int nodeCount;

  /// Number of target-category nodes (imaging targets).
  final int targetCount;

  /// Number of capture/exposure nodes (`TakeExposure` / `SmartExposure`).
  final int exposureCount;

  /// Estimated total integration time in seconds, derived from the persisted
  /// `estimatedDurationMins` so the card shows a duration without re-walking
  /// the node tree.
  final int totalIntegrationSecs;

  /// Display name of the first target node, or `null` when the sequence has no
  /// target nodes (e.g. a calibration-only sequence).
  final String? primaryTargetName;

  /// When this sequence last started a run, or `null` if it has never run.
  final DateTime? lastRunAt;

  /// How many times this sequence has been run.
  final int runCount;

  /// Library tags.
  final List<String> tags;

  /// Library favorite flag.
  final bool isFavorite;

  /// When the sequence row was first created (`sequences.createdAt`).
  final DateTime createdAt;

  /// When the sequence row was last modified (`sequences.updatedAt`).
  final DateTime modifiedAt;

  const SequenceSummary({
    required this.id,
    required this.name,
    required this.nodeCount,
    required this.targetCount,
    required this.exposureCount,
    required this.totalIntegrationSecs,
    required this.primaryTargetName,
    required this.lastRunAt,
    required this.runCount,
    required this.tags,
    required this.isFavorite,
    required this.createdAt,
    required this.modifiedAt,
  });

  /// Decode a `sequences.tags_json` column (JSON-encoded `List<String>`) into a
  /// tag list, tolerating null / malformed values by returning an empty list.
  static List<String> decodeTags(String? tagsJson) {
    if (tagsJson == null || tagsJson.isEmpty) return const [];
    try {
      final decoded = jsonDecode(tagsJson);
      if (decoded is List) {
        return [
          for (final tag in decoded)
            if (tag is String) tag,
        ];
      }
    } on FormatException {
      // Malformed tag JSON — treat as untagged rather than throwing into the
      // library list.
    }
    return const [];
  }
}
