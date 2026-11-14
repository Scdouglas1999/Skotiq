import '../backend/roles/host_data/host_sequence_library.dart';
import '../models/sequence/sequence_models.dart';
import 'sequence_file_service.dart';
import 'sequence_repository.dart';

/// The saved sequences of a linked host, read and written through its API as
/// sequence documents.
final class RemoteSequenceRepository implements SequenceRepository {
  RemoteSequenceRepository(this._host, this._fileService);

  final HostSequenceLibrary _host;
  final SequenceFileService _fileService;

  Sequence _fromMap(Map<String, dynamic> wire) {
    final map = Map<String, dynamic>.from(wire);
    final dbId = map.remove('databaseId');
    final sequence = _fileService.parseFromMap(map);
    return dbId is int ? sequence.copyWith(databaseId: dbId) : sequence;
  }

  @override
  Future<int> saveSequence(Sequence sequence, {bool isTemplate = false}) =>
      _host.saveFullSequence(
        {
          ..._fileService.sequenceToMap(sequence),
          if (sequence.databaseId != null) 'databaseId': sequence.databaseId,
        },
        isTemplate: isTemplate,
        databaseId: sequence.databaseId,
      );

  @override
  Future<Sequence?> loadSequence(int sequenceId) async {
    final map = await _host.getFullSequence(sequenceId);
    return map == null ? null : _fromMap(map);
  }

  @override
  Future<List<Sequence>> loadAllSequences() async =>
      (await _host.listFullSequences()).map(_fromMap).toList();

  @override
  Future<List<Sequence>> loadAllTemplates() async =>
      (await _host.listFullTemplates()).map(_fromMap).toList();

  @override
  Future<List<SequenceSummary>> loadSequenceSummaries() async {
    final summaries = await _host.listSequenceSummaries();
    return [
      for (final summary in summaries)
        SequenceSummary(
          id: summary.id,
          name: summary.name,
          nodeCount: summary.nodeCount,
          targetCount: summary.targetCount,
          exposureCount: summary.exposureCount,
          totalIntegrationSecs: summary.totalIntegrationSecs,
          primaryTargetName: summary.primaryTargetName,
          lastRunAt: summary.lastRunAt,
          runCount: summary.runCount,
          tags: summary.tags,
          isFavorite: summary.isFavorite,
          createdAt: summary.createdAt,
          modifiedAt: summary.modifiedAt,
        ),
    ];
  }

  @override
  Future<String?> loadPreviousRunSnapshot(
    int sequenceId, {
    required int beforeRunId,
  }) async {
    final context = await loadRunDiffContext(beforeRunId);
    if (context.sequenceId != sequenceId) {
      throw StateError(
        'Run $beforeRunId belongs to sequence ${context.sequenceId}, '
        'not sequence $sequenceId.',
      );
    }
    return context.previousSnapshotJson;
  }

  @override
  Future<SequenceRunDiffContext> loadRunDiffContext(int runId) async {
    if (runId <= 0) {
      throw ArgumentError.value(runId, 'runId', 'must be positive');
    }
    final context = await _host.fetchSequenceRunDiffContext(runId);
    return SequenceRunDiffContext(
      sequenceId: context.sequenceId,
      currentSnapshotJson: context.currentSnapshotJson,
      previousSnapshotJson: context.previousSnapshotJson,
    );
  }

  @override
  Future<void> setTags(int sequenceId, List<String> tags) =>
      _host.setSequenceTags(sequenceId, cleanedSequenceTags(tags));

  @override
  Future<bool> toggleFavorite(int sequenceId) =>
      _host.toggleSequenceFavorite(sequenceId);

  @override
  Future<int?> snapshotVersionOnSave(Sequence sequence, {String? label}) async {
    final sequenceId = sequence.databaseId;
    if (sequenceId == null) return null;
    return _host.snapshotSequenceVersion(
      sequenceId,
      _fileService.sequenceToMap(sequence),
      label: label,
    );
  }

  @override
  Future<List<SequenceVersionSummary>> listVersions(int sequenceId) async {
    final versions = await _host.listSequenceVersions(sequenceId);
    return [
      for (final version in versions)
        SequenceVersionSummary(
          id: version.id,
          sequenceId: version.sequenceId,
          label: version.label,
          createdAt: version.createdAt,
        ),
    ];
  }

  @override
  Future<Sequence?> restoreVersion(int versionId) async {
    final version = await _host.getSequenceVersion(versionId);
    if (version == null) return null;
    return sequenceFromVersionSnapshot(
      _fileService,
      versionId: versionId,
      sequenceId: version.sequenceId,
      snapshotJson: version.snapshotJson,
    );
  }

  @override
  Future<void> deleteSequence(int sequenceId) =>
      _host.deleteSequence(sequenceId);

  /// The host copies the sequence and gives its nodes new ids.
  @override
  Future<Sequence?> duplicateSequence(int sequenceId, String newName) async =>
      loadSequence(await _host.duplicateSequence(sequenceId, newName));
}
