import 'package:skotiq_core/skotiq_core.dart';

/// What a linked imaging host is running: the plan open in its editor, its scheduled start, the end-of-night state and its recent events.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostRunState {
  Future<Map<String, dynamic>?> getOpenEditorSequence();

  Future<void> putOpenEditorSequence(
    Map<String, dynamic>? sequence, {
    int? databaseId,
    required bool isDirty,
  });

  Future<void> sequencerStopOnHost({required bool preserveCheckpoint});

  Future<EonStatus?> hostEndOfNightStatus();

  Future<DateTime?> hostScheduledStart();

  Future<List<SkotiqEvent>> getHostRecentEvents({int limit = 100});
}
