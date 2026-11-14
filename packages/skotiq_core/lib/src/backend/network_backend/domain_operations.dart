part of '../network_backend.dart';

mixin _NetworkBackendDomainOperations on _NetworkBackendTransport {
  List<Map<String, dynamic>> _domainObjectRows(
    Map<String, dynamic> response,
    String field,
    String request,
  ) {
    final raw = response[field];
    if (raw is! List) {
      throw FormatException(
        '$request returned a missing or non-list `$field` field',
      );
    }
    final rows = <Map<String, dynamic>>[];
    for (var index = 0; index < raw.length; index++) {
      final row = raw[index];
      if (row is! Map) {
        throw FormatException(
          '$request returned a non-object `$field[$index]` row',
        );
      }
      rows.add(row.cast<String, dynamic>());
    }
    return rows;
  }

  Map<String, dynamic>? _domainNullableObject(
    Map<String, dynamic> response,
    String field,
    String request,
  ) {
    if (!response.containsKey(field)) {
      throw FormatException('$request returned no `$field` field');
    }
    final raw = response[field];
    if (raw == null) return null;
    if (raw is! Map) {
      throw FormatException('$request returned a non-object `$field` field');
    }
    return raw.cast<String, dynamic>();
  }

  int _domainId(Map<String, dynamic> response, String request) {
    final raw = response['id'];
    if (raw is! num ||
        !raw.isFinite ||
        raw != raw.truncateToDouble() ||
        raw < 1) {
      throw FormatException('$request returned no positive integer `id` field');
    }
    return raw.toInt();
  }

  /// Get all targets from the headless server
  /// Returns JSON maps that can be used to construct CelestialTarget objects
  Future<List<Map<String, dynamic>>> getAllTargets() async {
    final response = await _get(TargetApi.getAllTargets);
    return _domainObjectRows(response, 'targets', 'GET /api/targets');
  }

  Future<Map<String, dynamic>?> getTargetById(int id) async {
    try {
      final response = await _get(TargetApi.getTargetById, path: {'id': id});
      return _domainNullableObject(response, 'target', 'GET /api/targets/$id');
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> searchTargets(String query) async {
    final response = await _get(
      TargetApi.searchTargets,
      query: {'query': query},
    );
    return _domainObjectRows(response, 'targets', 'GET /api/targets/search');
  }

  Future<int> createTarget(Map<String, dynamic> target) async {
    final response = await _post(TargetApi.createTarget, body: target);
    return _domainId(response, 'POST /api/targets');
  }

  Future<void> updateTarget(int id, Map<String, dynamic> target) async {
    await _put(TargetApi.updateTarget, path: {'id': id}, body: target);
  }

  Future<void> deleteTarget(int id) async {
    await _delete(TargetApi.deleteTarget, path: {'id': id});
  }

  Future<List<Map<String, dynamic>>> getFavoriteTargets() async {
    final response = await _get(TargetApi.getFavoriteTargets);
    return _domainObjectRows(response, 'targets', 'GET /api/targets/favorites');
  }

  Future<List<Map<String, dynamic>>> getTargetsByType(String objectType) async {
    final response = await _get(
      TargetApi.getTargetsByType,
      query: {'type': objectType},
    );
    return _domainObjectRows(response, 'targets', 'GET /api/targets/by-type');
  }

  Future<List<Map<String, dynamic>>> getTargetsByPriority(int priority) async {
    final response = await _get(
      TargetApi.getTargetsByPriority,
      query: {'priority': priority.toString()},
    );
    return _domainObjectRows(
      response,
      'targets',
      'GET /api/targets/by-priority',
    );
  }

  // Sequence Management (CRUD - separate from sequencer execution)

  Future<List<Map<String, dynamic>>> getSequenceList() async {
    final response = await _get(SequenceManagementApi.getAllSequences);
    return _domainObjectRows(
      response,
      'sequences',
      'GET /api/sequence-management/list',
    );
  }

  Future<List<Map<String, dynamic>>> getSequenceTemplates() async {
    final response = await _get(SequenceManagementApi.getAllTemplates);
    return _domainObjectRows(
      response,
      'templates',
      'GET /api/sequence-management/templates',
    );
  }

  Future<int> createSequence(Map<String, dynamic> sequence) async {
    final response = await _post(
      SequenceManagementApi.createSequence,
      body: sequence,
    );
    return _domainId(response, 'POST /api/sequence-management');
  }

  Future<void> updateSequence(int id, Map<String, dynamic> sequence) async {
    await _put(
      SequenceManagementApi.updateSequence,
      path: {'id': id},
      body: sequence,
    );
  }

  Future<void> deleteSequence(int id) async {
    await _delete(SequenceManagementApi.deleteSequence, path: {'id': id});
  }

  Future<int> duplicateSequence(int sourceId, String newName) async {
    final response = await _post(
      SequenceManagementApi.duplicateSequence,
      path: {'id': sourceId},
      body: {'newName': newName},
    );
    return _domainId(
      response,
      'POST /api/sequence-management/$sourceId/duplicate',
    );
  }

  /// Save a full sequence document to the host database.
  Future<int> saveFullSequence(
    Map<String, dynamic> sequence, {
    bool isTemplate = false,
    int? databaseId,
  }) async {
    final response = await _post(
      SequenceManagementApi.saveFullSequence,
      body: {
        'sequence': sequence,
        'isTemplate': isTemplate,
        if (databaseId != null) 'databaseId': databaseId,
      },
    );
    return _domainId(response, 'POST /api/sequence-management/save-full');
  }

  /// Load all sequences with full node trees from the host.
  Future<List<Map<String, dynamic>>> listFullSequences() async {
    final response = await _get(SequenceManagementApi.listFullSequences);
    return _domainObjectRows(
      response,
      'sequences',
      'GET /api/sequence-management/list-full',
    );
  }

  /// Load all templates with full node trees from the host.
  Future<List<Map<String, dynamic>>> listFullTemplates() async {
    final response = await _get(SequenceManagementApi.listFullTemplates);
    return _domainObjectRows(
      response,
      'templates',
      'GET /api/sequence-management/templates-full',
    );
  }

  /// Load one complete stored sequence document without transferring the
  /// host's entire sequence and template libraries.
  Future<Map<String, dynamic>?> getFullSequence(int sequenceId) async {
    try {
      final response = await _get(
        SequenceManagementApi.getFullSequence,
        path: {'id': sequenceId},
      );
      return _domainNullableObject(
        response,
        'sequence',
        'GET /api/sequence-management/$sequenceId/full',
      );
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  /// Load host-authoritative sequence-library metadata and run roll-ups.
  Future<List<RemoteSequenceSummary>> listSequenceSummaries() async {
    final response = await _get(SequenceManagementApi.listSequenceSummaries);
    return _domainObjectRows(
      response,
      'summaries',
      'GET /api/sequence-management/summaries',
    ).map(RemoteSequenceSummary.fromJson).toList(growable: false);
  }

  /// Replace the full tag list for a stored sequence on the host.
  Future<void> setSequenceTags(int sequenceId, List<String> tags) async {
    await _put(
      SequenceManagementApi.setTags,
      path: {'id': sequenceId},
      body: {'tags': tags},
    );
  }

  /// Toggle a stored sequence's favorite flag and return its new value.
  Future<bool> toggleSequenceFavorite(int sequenceId) async {
    final response = await _post(
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

  /// Append an explicit, user-meaningful version snapshot on the host.
  Future<int> snapshotSequenceVersion(
    int sequenceId,
    Map<String, dynamic> sequence, {
    String? label,
  }) async {
    final response = await _post(
      SequenceManagementApi.snapshotVersion,
      path: {'id': sequenceId},
      body: {'sequence': sequence, if (label != null) 'label': label},
    );
    return _domainId(
      response,
      'POST /api/sequence-management/$sequenceId/versions',
    );
  }

  /// List stored snapshots for a host-owned sequence, newest first.
  Future<List<RemoteSequenceVersionSummary>> listSequenceVersions(
    int sequenceId,
  ) async {
    final response = await _get(
      SequenceManagementApi.listVersions,
      path: {'id': sequenceId},
    );
    return _domainObjectRows(
      response,
      'versions',
      'GET /api/sequence-management/$sequenceId/versions',
    ).map(RemoteSequenceVersionSummary.fromJson).toList(growable: false);
  }

  /// Load one host-owned version snapshot, or `null` after a real 404.
  Future<RemoteSequenceVersion?> getSequenceVersion(int versionId) async {
    try {
      final response = await _get(
        SequenceManagementApi.getVersion,
        path: {'versionId': versionId},
      );
      final map = _domainNullableObject(
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

  Future<void> createSequenceNode(
    int sequenceId,
    Map<String, dynamic> node,
  ) async {
    await _post(
      SequenceManagementApi.createNode,
      path: {'id': sequenceId},
      body: node,
    );
  }
}
