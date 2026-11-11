import 'package:skotiq_core/skotiq_core.dart';

/// [HostRunState] on a linked host.
final class RemoteHostRunState implements HostRunState {
  RemoteHostRunState(this._host);

  final NetworkBackend _host;

  @override
  Future<Map<String, dynamic>?> getOpenEditorSequence() =>
      _host.getOpenEditorSequence();

  @override
  Future<void> putOpenEditorSequence(
    Map<String, dynamic>? sequence, {
    int? databaseId,
    required bool isDirty,
  }) => _host.putOpenEditorSequence(
    sequence,
    databaseId: databaseId,
    isDirty: isDirty,
  );

  @override
  Future<void> sequencerStopOnHost({required bool preserveCheckpoint}) =>
      _host.sequencerStopOnHost(preserveCheckpoint: preserveCheckpoint);

  @override
  Future<EonStatus?> hostEndOfNightStatus() => _host.hostEndOfNightStatus();

  @override
  Future<DateTime?> hostScheduledStart() => _host.hostScheduledStart();

  @override
  Future<void> endSession(int id, {String status = 'completed'}) =>
      _host.endSession(id, status: status);

  @override
  Future<List<SkotiqEvent>> getHostRecentEvents({int limit = 100}) =>
      _host.getHostRecentEvents(limit: limit);

  @override
  Future<bool> cameraHostIsWarming() => _host.cameraHostIsWarming();
}
