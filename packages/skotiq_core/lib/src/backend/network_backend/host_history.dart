part of '../network_backend.dart';

/// Recorded history of a linked imaging host: polar alignments, guide RMS, the night narrator feed and photometric transforms.
final class HostHistory {
  HostHistory(this._host);

  final NetworkBackend _host;

  /// GET /api/guide-rms-history?sinceMs=&untilMs=&limit=&offset=
  Future<RemotePage<RemoteGuideRmsHistoryEntry>> fetchGuideRmsHistory({
    String? mountId,
    int? sinceMs,
    int? untilMs,
    int limit = 200,
    int offset = 0,
  }) async {
    final response = await _host._get(
      DbReadApi.listGuideRmsHistory,
      query: {
        if (mountId != null && mountId.trim().isNotEmpty)
          'mountId': mountId.trim(),
        if (sinceMs != null) 'sinceMs': sinceMs.toString(),
        if (untilMs != null) 'untilMs': untilMs.toString(),
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
    );
    return RemotePage.fromJson(response, RemoteGuideRmsHistoryEntry.fromJson);
  }

  /// GET /api/polar-alignment-history?equipmentProfileId=&limit=&offset=
  Future<RemotePage<RemotePolarAlignmentHistoryEntry>>
  fetchPolarAlignmentHistory({
    int? equipmentProfileId,
    int limit = 200,
    int offset = 0,
  }) async {
    final response = await _host._get(
      DbReadApi.listPolarAlignmentHistory,
      query: {
        if (equipmentProfileId != null)
          'equipmentProfileId': equipmentProfileId.toString(),
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
    );
    return RemotePage.fromJson(
      response,
      RemotePolarAlignmentHistoryEntry.fromJson,
    );
  }

  // Night Narrator feed (read-only)

  /// Fetch the appliance's narrator feed for a session (pinned-first,
  /// newest-first). Returns the raw event maps; callers reconstruct
  /// `NarratorEvent` via `narratorEventFromWireJson`. The narrator runs on the
  /// host, so a remote client reads its feed here instead of the local DB.
  Future<List<Map<String, dynamic>>> getNarratorFeed(int sessionId) async {
    final json = await _host._get(
      NarratorApi.feed,
      query: {'sessionId': sessionId.toString()},
    );
    return _host._narratorEventsList(json);
  }

  /// Fetch the appliance's sessionless recent narrator feed.
  Future<List<Map<String, dynamic>>> getRecentNarratorFeed({
    int limit = 50,
  }) async {
    final json = await _host._get(
      NarratorApi.recent,
      query: {'limit': limit.toString()},
    );
    return _host._narratorEventsList(json);
  }

  Future<List<PhotometricTransformRow>> getPhotometricTransforms({
    int? profileId,
  }) async {
    final response = await _host._get(
      ScienceApi.getPhotometricTransforms,
      query: profileId == null ? null : {'profileId': profileId.toString()},
    );
    return _rowsFromJson<PhotometricTransformRow>(
      response['transforms'],
      PhotometricTransformRow.fromJson,
    );
  }
}
