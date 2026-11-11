import 'package:skotiq_core/skotiq_core.dart';

/// Recorded history of a linked imaging host: polar alignments, guide RMS, run replays, the night narrator feed and photometric transforms.
abstract interface class HostHistory {
  /// GET /api/polar-alignment-history?equipmentProfileId=&limit=&offset=
  Future<RemotePage<RemotePolarAlignmentHistoryEntry>>
  fetchPolarAlignmentHistory({
    int? equipmentProfileId,
    int limit = 200,
    int offset = 0,
  });

  /// GET /api/guide-rms-history?sinceMs=&untilMs=&limit=&offset=
  Future<RemotePage<RemoteGuideRmsHistoryEntry>> fetchGuideRmsHistory({
    String? mountId,
    int? sinceMs,
    int? untilMs,
    int limit = 200,
    int offset = 0,
  });

  Future<RemoteSequenceRunDetail> fetchSequenceRunById(int runId);

  Future<RemoteReplayEventsPage> fetchSequenceRunEvents(
    int runId, {
    int? sinceMs,
    int? untilMs,
    String? severityMin,
    int limit = 200,
    int offset = 0,
  });

  Future<RemotePage<RemoteReplayFrame>> fetchSequenceRunFrames(
    int runId, {
    int limit = 200,
    int offset = 0,
  });

  /// Fetch the appliance's narrator feed for a session (pinned-first,
  /// newest-first). Returns the raw event maps; callers reconstruct
  /// `NarratorEvent` via `narratorEventFromWireJson`. The narrator runs on the
  /// host, so a remote client reads its feed here instead of the local DB.
  Future<List<Map<String, dynamic>>> getNarratorFeed(int sessionId);

  /// Fetch the appliance's sessionless recent narrator feed.
  Future<List<Map<String, dynamic>>> getRecentNarratorFeed({int limit = 50});

  Future<List<PhotometricTransformRow>> getPhotometricTransforms({
    int? profileId,
  });
}
