import 'dart:convert';

import '../models/sequence/sequence_models.dart';
import 'sequence_file_service.dart';
import 'sequence_summary.dart';

export 'sequence_summary.dart';

/// Exact persisted sequence documents surrounding a recorded run.
///
/// Either side may be absent for legacy rows recorded before run snapshots
/// existed. [previousSnapshotJson] is drawn only from an earlier completed run
/// of the same sequence.
class SequenceRunDiffContext {
  final int? sequenceId;
  final String? currentSnapshotJson;
  final String? previousSnapshotJson;

  const SequenceRunDiffContext({
    required this.sequenceId,
    required this.currentSnapshotJson,
    required this.previousSnapshotJson,
  });
}

/// Lightweight row for the sequence version-history list.
///
/// The full snapshot is deliberately absent: remote libraries can render up
/// to 20 restore points without downloading 20 complete sequence documents.
/// [restoreVersion] fetches only the snapshot the operator actually chooses.
class SequenceVersionSummary {
  final int id;
  final int sequenceId;
  final String? label;
  final DateTime createdAt;

  const SequenceVersionSummary({
    required this.id,
    required this.sequenceId,
    required this.createdAt,
    this.label,
  });
}

/// The saved sequences and templates of the imaging host, with their tags,
/// favorites, version history and the snapshots its runs executed.
abstract interface class SequenceRepository {
  /// Creates the sequence, or updates the row its `databaseId` names.
  /// Returns the row id.
  Future<int> saveSequence(Sequence sequence, {bool isTemplate = false});

  Future<Sequence?> loadSequence(int sequenceId);

  Future<List<Sequence>> loadAllSequences();

  Future<List<Sequence>> loadAllTemplates();

  /// A summary of every saved sequence that is not a template, newest
  /// modified first, without loading any node tree.
  Future<List<SequenceSummary>> loadSequenceSummaries();

  /// The sequence JSON of the last completed run of [sequenceId] that started
  /// before run [beforeRunId], for the run history's "diff against the
  /// previous run". Null when there is no such run or it has no snapshot.
  Future<String?> loadPreviousRunSnapshot(
    int sequenceId, {
    required int beforeRunId,
  });

  /// The snapshot run [runId] executed and that of the completed run before
  /// it, read together so the two sides come from one host.
  Future<SequenceRunDiffContext> loadRunDiffContext(int runId);

  /// Replaces the tag list of [sequenceId]. Tags are trimmed, blanks dropped
  /// and duplicates removed, keeping order.
  Future<void> setTags(int sequenceId, List<String> tags);

  /// Returns the new value.
  Future<bool> toggleFavorite(int sequenceId);

  /// Adds [sequence] as it is now to its version history and returns the
  /// version's id, or null for a sequence that was never saved.
  Future<int?> snapshotVersionOnSave(Sequence sequence, {String? label});

  /// The version history of [sequenceId], newest first.
  Future<List<SequenceVersionSummary>> listVersions(int sequenceId);

  /// The sequence as stored version [versionId] holds it, or null when that
  /// version is gone. It keeps the owning `databaseId`, so saving it restores
  /// in place.
  Future<Sequence?> restoreVersion(int versionId);

  Future<void> deleteSequence(int sequenceId);

  /// Copies a sequence under [newName] with new ids for every node.
  Future<Sequence?> duplicateSequence(int sequenceId, String newName);
}

/// [tags] trimmed, without blanks or repeats, in their first order.
List<String> cleanedSequenceTags(List<String> tags) {
  final seen = <String>{};
  return [
    for (final tag in tags)
      if (tag.trim().isNotEmpty && seen.add(tag.trim())) tag.trim(),
  ];
}

/// The editable sequence a stored version snapshot holds, tied to the row
/// [sequenceId] it is a version of.
Sequence sequenceFromVersionSnapshot(
  SequenceFileService fileService, {
  required int versionId,
  required int sequenceId,
  required String snapshotJson,
}) {
  final decoded = jsonDecode(snapshotJson);
  if (decoded is! Map<String, dynamic>) {
    throw FormatException(
      'Version $versionId snapshot is not a JSON object '
      '(got ${decoded.runtimeType}).',
    );
  }
  return fileService.parseFromMap(decoded).copyWith(databaseId: sequenceId);
}
