import 'package:skotiq_core/skotiq_core.dart';

/// What a linked imaging host is running: the plan this client puts in its
/// editor, its run (to stop it) and its recent events.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostRunState {
  Future<void> putOpenEditorSequence(
    Map<String, dynamic>? sequence, {
    int? databaseId,
    required bool isDirty,
  });

  Future<void> sequencerStopOnHost({required bool preserveCheckpoint});

  Future<List<SkotiqEvent>> getHostRecentEvents({int limit = 100});
}
