part of '../network_backend.dart';

/// Saved sequences, templates and their versions on a linked imaging host.
final class HostSequenceLibrary {
  HostSequenceLibrary(this._host);

  final NetworkBackend _host;

  Future<void> deleteSequence(int id) async {
    await _host._delete(SequenceManagementApi.deleteSequence, path: {'id': id});
  }

  Future<int> duplicateSequence(int sourceId, String newName) async {
    final response = await _host._post(
      SequenceManagementApi.duplicateSequence,
      path: {'id': sourceId},
      body: {'newName': newName},
    );
    return _host._domainId(
      response,
      'POST /api/sequence-management/$sourceId/duplicate',
    );
  }

  /// Load one complete stored sequence document without transferring the
  /// host's entire sequence and template libraries.
  Future<Map<String, dynamic>?> getFullSequence(int sequenceId) async {
    try {
      final response = await _host._get(
        SequenceManagementApi.getFullSequence,
        path: {'id': sequenceId},
      );
      return _host._domainNullableObject(
        response,
        'sequence',
        'GET /api/sequence-management/$sequenceId/full',
      );
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  /// Load one host-owned version snapshot, or `null` after a real 404.
  Future<RemoteSequenceVersion?> getSequenceVersion(int versionId) async {
    try {
      final response = await _host._get(
        SequenceManagementApi.getVersion,
        path: {'versionId': versionId},
      );
      final map = _host._domainNullableObject(
        response,
        'version',
        'GET /api/sequence-management/versions/$versionId',
      );
      return map == null ? null : RemoteSequenceVersion.fromJson(map);
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  /// Load all sequences with full node trees from the host.
  Future<List<Map<String, dynamic>>> listFullSequences() async {
    final response = await _host._get(SequenceManagementApi.listFullSequences);
    return _host._domainObjectRows(
      response,
      'sequences',
      'GET /api/sequence-management/list-full',
    );
  }

  /// Load all templates with full node trees from the host.
  Future<List<Map<String, dynamic>>> listFullTemplates() async {
    final response = await _host._get(SequenceManagementApi.listFullTemplates);
    return _host._domainObjectRows(
      response,
      'templates',
      'GET /api/sequence-management/templates-full',
    );
  }

  /// Load host-authoritative sequence-library metadata and run roll-ups.
  Future<List<RemoteSequenceSummary>> listSequenceSummaries() async {
    final response = await _host._get(SequenceManagementApi.listSequenceSummaries);
    return _host._domainObjectRows(
      response,
      'summaries',
      'GET /api/sequence-management/summaries',
    ).map(RemoteSequenceSummary.fromJson).toList(growable: false);
  }

  /// List stored snapshots for a host-owned sequence, newest first.
  Future<List<RemoteSequenceVersionSummary>> listSequenceVersions(
    int sequenceId,
  ) async {
    final response = await _host._get(
      SequenceManagementApi.listVersions,
      path: {'id': sequenceId},
    );
    return _host._domainObjectRows(
      response,
      'versions',
      'GET /api/sequence-management/$sequenceId/versions',
    ).map(RemoteSequenceVersionSummary.fromJson).toList(growable: false);
  }

  /// Save a full sequence document to the host database.
  Future<int> saveFullSequence(
    Map<String, dynamic> sequence, {
    bool isTemplate = false,
    int? databaseId,
  }) async {
    final response = await _host._post(
      SequenceManagementApi.saveFullSequence,
      body: {
        'sequence': sequence,
        'isTemplate': isTemplate,
        if (databaseId != null) 'databaseId': databaseId,
      },
    );
    return _host._domainId(response, 'POST /api/sequence-management/save-full');
  }

  /// Replace the full tag list for a stored sequence on the host.
  Future<void> setSequenceTags(int sequenceId, List<String> tags) async {
    await _host._put(
      SequenceManagementApi.setTags,
      path: {'id': sequenceId},
      body: {'tags': tags},
    );
  }

  /// Append an explicit, user-meaningful version snapshot on the host.
  Future<int> snapshotSequenceVersion(
    int sequenceId,
    Map<String, dynamic> sequence, {
    String? label,
  }) async {
    final response = await _host._post(
      SequenceManagementApi.snapshotVersion,
      path: {'id': sequenceId},
      body: {'sequence': sequence, if (label != null) 'label': label},
    );
    return _host._domainId(
      response,
      'POST /api/sequence-management/$sequenceId/versions',
    );
  }

  /// Toggle a stored sequence's favorite flag and return its new value.
  Future<bool> toggleSequenceFavorite(int sequenceId) async {
    final response = await _host._post(
      SequenceManagementApi.toggleFavorite,
      path: {'id': sequenceId},
    );
    final value = response['isFavorite'];
    if (value is! bool) {
      throw const FormatException(
        'POST /api/sequence-management/<id>/favorite returned no boolean '
        '`isFavorite` field',
      );
    }
    return value;
  }

  Future<int> createSequence(Map<String, dynamic> sequence) async {
    final response = await _host._post(
      SequenceManagementApi.createSequence,
      body: sequence,
    );
    return _host._domainId(response, 'POST /api/sequence-management');
  }

  Future<void> createSequenceNode(
    int sequenceId,
    Map<String, dynamic> node,
  ) async {
    await _host._post(
      SequenceManagementApi.createNode,
      path: {'id': sequenceId},
      body: node,
    );
  }

  Future<List<Map<String, dynamic>>> getSequenceTemplates() async {
    final response = await _host._get(SequenceManagementApi.getAllTemplates);
    return _host._domainObjectRows(
      response,
      'templates',
      'GET /api/sequence-management/templates',
    );
  }

  // Sequence Management (CRUD - separate from sequencer execution)

  Future<List<Map<String, dynamic>>> getSequenceList() async {
    final response = await _host._get(SequenceManagementApi.getAllSequences);
    return _host._domainObjectRows(
      response,
      'sequences',
      'GET /api/sequence-management/list',
    );
  }

  /// Fetch the exact current and prior completed sequence snapshots needed by
  /// the run-history diff action. The host only includes these potentially
  /// large documents when explicitly requested.
  Future<RemoteSequenceRunDiffContext> fetchSequenceRunDiffContext(
    int runId,
  ) async {
    _host._validateReplayRunId(runId);
    final response = await _host._get(
      DbReadApi.getSequenceRunById,
      path: {'runId': runId},
      query: {'includeDiffContext': 'true'},
    );
    final raw = response['diffContext'];
    if (raw is! Map) {
      throw StateError(
        'Malformed /sequence-runs/$runId diff response: '
        'missing diffContext object',
      );
    }
    final parsed = RemoteSequenceRunDiffContext.fromJson(
      raw.cast<String, dynamic>(),
    );
    if (parsed.runId != runId) {
      throw FormatException(
        'GET /api/sequence-runs/$runId returned diff context for run '
        '${parsed.runId}',
      );
    }
    return parsed;
  }
}
