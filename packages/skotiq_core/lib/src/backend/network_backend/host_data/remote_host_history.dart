import 'package:skotiq_core/skotiq_core.dart';

/// [HostHistory] on a linked host.
final class RemoteHostHistory implements HostHistory {
  RemoteHostHistory(this._host);

  final NetworkBackend _host;

  @override
  Future<RemotePage<RemotePolarAlignmentHistoryEntry>>
  fetchPolarAlignmentHistory({
    int? equipmentProfileId,
    int limit = 200,
    int offset = 0,
  }) => _host.fetchPolarAlignmentHistory(
    equipmentProfileId: equipmentProfileId,
    limit: limit,
    offset: offset,
  );

  @override
  Future<RemotePage<RemoteGuideRmsHistoryEntry>> fetchGuideRmsHistory({
    String? mountId,
    int? sinceMs,
    int? untilMs,
    int limit = 200,
    int offset = 0,
  }) => _host.fetchGuideRmsHistory(
    mountId: mountId,
    sinceMs: sinceMs,
    untilMs: untilMs,
    limit: limit,
    offset: offset,
  );

  @override
  Future<RemoteSequenceRunDetail> fetchSequenceRunById(int runId) =>
      _host.fetchSequenceRunById(runId);

  @override
  Future<RemoteReplayEventsPage> fetchSequenceRunEvents(
    int runId, {
    int? sinceMs,
    int? untilMs,
    String? severityMin,
    int limit = 200,
    int offset = 0,
  }) => _host.fetchSequenceRunEvents(
    runId,
    sinceMs: sinceMs,
    untilMs: untilMs,
    severityMin: severityMin,
    limit: limit,
    offset: offset,
  );

  @override
  Future<RemotePage<RemoteReplayFrame>> fetchSequenceRunFrames(
    int runId, {
    int limit = 200,
    int offset = 0,
  }) => _host.fetchSequenceRunFrames(runId, limit: limit, offset: offset);

  @override
  Future<List<Map<String, dynamic>>> getNarratorFeed(int sessionId) =>
      _host.getNarratorFeed(sessionId);

  @override
  Future<List<Map<String, dynamic>>> getRecentNarratorFeed({int limit = 50}) =>
      _host.getRecentNarratorFeed(limit: limit);

  @override
  Future<List<PhotometricTransformRow>> getPhotometricTransforms({
    int? profileId,
  }) => _host.getPhotometricTransforms(profileId: profileId);
}
