import '../../../database/database.dart';
import 'package:skotiq_remote_protocol/wire_models.dart';

/// Recorded history of a linked imaging host: polar alignments, guide RMS, the night narrator feed and photometric transforms.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostHistory {
  Future<RemotePage<RemoteGuideRmsHistoryEntry>> fetchGuideRmsHistory({
    String? mountId,
    int? sinceMs,
    int? untilMs,
    int limit = 200,
    int offset = 0,
  });

  Future<RemotePage<RemotePolarAlignmentHistoryEntry>>
  fetchPolarAlignmentHistory({
    int? equipmentProfileId,
    int limit = 200,
    int offset = 0,
  });

  Future<List<Map<String, dynamic>>> getNarratorFeed(int sessionId);

  Future<List<Map<String, dynamic>>> getRecentNarratorFeed({int limit = 50});

  Future<List<PhotometricTransformRow>> getPhotometricTransforms({
    int? profileId,
  });
}
