import 'package:skotiq_core/skotiq_core.dart';

/// Saved sequences, templates and their versions on a linked imaging host.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostSequenceLibrary {
  Future<void> deleteSequence(int id);

  Future<int> duplicateSequence(int sourceId, String newName);

  Future<RemoteSequenceRunDiffContext> fetchSequenceRunDiffContext(
    int runId,
  );

  Future<Map<String, dynamic>?> getFullSequence(int sequenceId);

  Future<RemoteSequenceVersion?> getSequenceVersion(int versionId);

  Future<List<Map<String, dynamic>>> listFullSequences();

  Future<List<Map<String, dynamic>>> listFullTemplates();

  Future<List<RemoteSequenceSummary>> listSequenceSummaries();

  Future<List<RemoteSequenceVersionSummary>> listSequenceVersions(
    int sequenceId,
  );

  Future<int> saveFullSequence(
    Map<String, dynamic> sequence, {
    bool isTemplate = false,
    int? databaseId,
  });

  Future<void> setSequenceTags(int sequenceId, List<String> tags);

  Future<int> snapshotSequenceVersion(
    int sequenceId,
    Map<String, dynamic> sequence, {
    String? label,
  });

  Future<bool> toggleSequenceFavorite(int sequenceId);

  Future<int> createSequence(Map<String, dynamic> sequence);

  Future<void> createSequenceNode(
    int sequenceId,
    Map<String, dynamic> node,
  );

  Future<List<Map<String, dynamic>>> getSequenceTemplates();

  Future<List<Map<String, dynamic>>> getSequenceList();
}
