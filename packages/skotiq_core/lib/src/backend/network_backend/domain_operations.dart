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

  // Target management

  /// Get all targets from the headless server
  /// Returns JSON maps that can be used to construct CelestialTarget objects
  Future<List<Map<String, dynamic>>> getAllTargets() async {
    final response = await _get('targets');
    return _domainObjectRows(response, 'targets', 'GET /api/targets');
  }

  /// Get a specific target by ID
  Future<Map<String, dynamic>?> getTargetById(int id) async {
    try {
      final response = await _get('targets/$id');
      return _domainNullableObject(response, 'target', 'GET /api/targets/$id');
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  /// Search targets by query string
  Future<List<Map<String, dynamic>>> searchTargets(String query) async {
    final response = await _get('targets/search', {'query': query});
    return _domainObjectRows(response, 'targets', 'GET /api/targets/search');
  }

  /// Create a new target
  Future<int> createTarget(Map<String, dynamic> target) async {
    final response = await _post('targets', target);
    return _domainId(response, 'POST /api/targets');
  }

  /// Update an existing target
  Future<void> updateTarget(int id, Map<String, dynamic> target) async {
    await _put('targets/$id', target);
  }

  /// Delete a target
  Future<void> deleteTarget(int id) async {
    await _delete('targets/$id');
  }

  /// Toggle favorite status for a target
  Future<void> toggleTargetFavorite(int id) async {
    await _post('targets/$id/favorite');
  }

  /// Update target progress
  Future<void> updateTargetProgress(
    int id, {
    int? capturedSubs,
    double? totalIntegrationSecs,
  }) async {
    await _put('targets/$id/progress', {
      if (capturedSubs != null) 'capturedSubs': capturedSubs,
      if (totalIntegrationSecs != null)
        'totalIntegrationSecs': totalIntegrationSecs,
    });
  }

  /// Get favorite targets
  Future<List<Map<String, dynamic>>> getFavoriteTargets() async {
    final response = await _get('targets/favorites');
    return _domainObjectRows(response, 'targets', 'GET /api/targets/favorites');
  }

  /// Get targets by object type
  Future<List<Map<String, dynamic>>> getTargetsByType(String objectType) async {
    final response = await _get('targets/by-type', {'type': objectType});
    return _domainObjectRows(response, 'targets', 'GET /api/targets/by-type');
  }

  /// Get targets by priority
  Future<List<Map<String, dynamic>>> getTargetsByPriority(int priority) async {
    final response = await _get('targets/by-priority', {
      'priority': priority.toString(),
    });
    return _domainObjectRows(
      response,
      'targets',
      'GET /api/targets/by-priority',
    );
  }

  // Sequence Management (CRUD - separate from sequencer execution)

  /// Get all sequences
  Future<List<Map<String, dynamic>>> getSequenceList() async {
    final response = await _get('sequence-management/list');
    return _domainObjectRows(
      response,
      'sequences',
      'GET /api/sequence-management/list',
    );
  }

  /// Get all sequence templates
  Future<List<Map<String, dynamic>>> getSequenceTemplates() async {
    final response = await _get('sequence-management/templates');
    return _domainObjectRows(
      response,
      'templates',
      'GET /api/sequence-management/templates',
    );
  }

  /// Get a specific sequence by ID
  Future<Map<String, dynamic>?> getSequenceDetails(int id) async {
    try {
      final response = await _get('sequence-management/$id');
      return _domainNullableObject(
        response,
        'sequence',
        'GET /api/sequence-management/$id',
      );
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  /// Get nodes for a sequence
  Future<List<Map<String, dynamic>>> getSequenceNodes(int sequenceId) async {
    final response = await _get('sequence-management/$sequenceId/nodes');
    return _domainObjectRows(
      response,
      'nodes',
      'GET /api/sequence-management/$sequenceId/nodes',
    );
  }

  /// Create a new sequence
  Future<int> createSequence(Map<String, dynamic> sequence) async {
    final response = await _post('sequence-management', sequence);
    return _domainId(response, 'POST /api/sequence-management');
  }

  /// Update an existing sequence
  Future<void> updateSequence(int id, Map<String, dynamic> sequence) async {
    await _put('sequence-management/$id', sequence);
  }

  /// Delete a sequence
  Future<void> deleteSequence(int id) async {
    await _delete('sequence-management/$id');
  }

  /// Duplicate a sequence
  Future<int> duplicateSequence(int sourceId, String newName) async {
    final response = await _post('sequence-management/$sourceId/duplicate', {
      'newName': newName,
    });
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
    final response = await _post('sequence-management/save-full', {
      'sequence': sequence,
      'isTemplate': isTemplate,
      if (databaseId != null) 'databaseId': databaseId,
    });
    return _domainId(response, 'POST /api/sequence-management/save-full');
  }

  /// Load all sequences with full node trees from the host.
  Future<List<Map<String, dynamic>>> listFullSequences() async {
    final response = await _get('sequence-management/list-full');
    return _domainObjectRows(
      response,
      'sequences',
      'GET /api/sequence-management/list-full',
    );
  }

  /// Load all templates with full node trees from the host.
  Future<List<Map<String, dynamic>>> listFullTemplates() async {
    final response = await _get('sequence-management/templates-full');
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
      final response = await _get('sequence-management/$sequenceId/full');
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
    final response = await _get('sequence-management/summaries');
    return _domainObjectRows(
      response,
      'summaries',
      'GET /api/sequence-management/summaries',
    ).map(RemoteSequenceSummary.fromJson).toList(growable: false);
  }

  /// Replace the full tag list for a stored sequence on the host.
  Future<void> setSequenceTags(int sequenceId, List<String> tags) async {
    await _put('sequence-management/$sequenceId/tags', {'tags': tags});
  }

  /// Toggle a stored sequence's favorite flag and return its new value.
  Future<bool> toggleSequenceFavorite(int sequenceId) async {
    final response = await _post('sequence-management/$sequenceId/favorite');
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
    final response = await _post('sequence-management/$sequenceId/versions', {
      'sequence': sequence,
      if (label != null) 'label': label,
    });
    return _domainId(
      response,
      'POST /api/sequence-management/$sequenceId/versions',
    );
  }

  /// List stored snapshots for a host-owned sequence, newest first.
  Future<List<RemoteSequenceVersionSummary>> listSequenceVersions(
    int sequenceId,
  ) async {
    final response = await _get('sequence-management/$sequenceId/versions');
    return _domainObjectRows(
      response,
      'versions',
      'GET /api/sequence-management/$sequenceId/versions',
    ).map(RemoteSequenceVersionSummary.fromJson).toList(growable: false);
  }

  /// Load one host-owned version snapshot, or `null` after a real 404.
  Future<RemoteSequenceVersion?> getSequenceVersion(int versionId) async {
    try {
      final response = await _get('sequence-management/versions/$versionId');
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

  /// Create a new sequence node
  Future<void> createSequenceNode(
    int sequenceId,
    Map<String, dynamic> node,
  ) async {
    await _post('sequence-management/$sequenceId/nodes', node);
  }

  /// Update a sequence node
  Future<void> updateSequenceNode(
    String nodeId,
    Map<String, dynamic> node,
  ) async {
    await _put('sequence-management/nodes/$nodeId', node);
  }

  /// Delete a sequence node
  Future<void> deleteSequenceNode(String nodeId) async {
    await _delete('sequence-management/nodes/$nodeId');
  }

  /// Reorder sequence nodes
  Future<void> reorderSequenceNodes(
    int sequenceId,
    List<String> nodeIds,
  ) async {
    await _post('sequence-management/$sequenceId/reorder', {
      'nodeIds': nodeIds,
    });
  }

  // Flat wizard

  /// Calibrate a single filter for flat frames
  Future<Map<String, dynamic>> flatWizardCalibrateFilter({
    required String deviceId,
    required String filter,
    required int targetAdu,
    required int tolerance,
    double minExposure = 0.001,
    double maxExposure = 30.0,
    int? gain,
    int binning = 1,
  }) async {
    final response = await _post('flat-wizard/calibrate', {
      'deviceId': deviceId,
      'filter': filter,
      'targetAdu': targetAdu,
      'tolerance': tolerance,
      'minExposure': minExposure,
      'maxExposure': maxExposure,
      if (gain != null) 'gain': gain,
      'binning': binning,
    });
    return response;
  }

  /// Calibrate multiple filters for flat frames
  Future<Map<String, dynamic>> flatWizardCalibrateMultiple({
    required String deviceId,
    required List<String> filters,
    required int targetAdu,
    required int tolerance,
    double minExposure = 0.001,
    double maxExposure = 30.0,
    int? gain,
    int binning = 1,
  }) async {
    final response = await _post('flat-wizard/calibrate-multi', {
      'deviceId': deviceId,
      'filters': filters,
      'targetAdu': targetAdu,
      'tolerance': tolerance,
      'minExposure': minExposure,
      'maxExposure': maxExposure,
      if (gain != null) 'gain': gain,
      'binning': binning,
    });
    return response;
  }

  /// Generate a flat frame sequence from calibration results
  Future<Map<String, dynamic>> flatWizardGenerateSequence({
    required List<Map<String, dynamic>> calibrations,
    required int framesPerFilter,
    String sequenceName = 'Flat Frames',
    bool dither = false,
  }) async {
    final response = await _post('flat-wizard/generate-sequence', {
      'calibrations': calibrations,
      'framesPerFilter': framesPerFilter,
      'sequenceName': sequenceName,
      'dither': dither,
    });
    return response;
  }

  // Mosaic planning

  /// Generate mosaic panels
  Future<Map<String, dynamic>> mosaicGeneratePanels(
    Map<String, dynamic> config,
  ) async {
    final response = await _post('mosaic/generate-panels', config);
    return response;
  }

  /// Generate a mosaic sequence
  Future<Map<String, dynamic>> mosaicGenerateSequence({
    required Map<String, dynamic> config,
    required Map<String, dynamic> exposureSettings,
    required Map<String, dynamic> options,
  }) async {
    final response = await _post('mosaic/generate-sequence', {
      'config': config,
      'exposureSettings': exposureSettings,
      'options': options,
    });
    return response;
  }

  /// Calculate mosaic area
  Future<Map<String, dynamic>> mosaicCalculateArea(
    Map<String, dynamic> config,
  ) async {
    final response = await _post('mosaic/calculate-area', config);
    return response;
  }

  /// Validate mosaic configuration
  Future<Map<String, dynamic>> mosaicValidate(
    Map<String, dynamic> config,
  ) async {
    final response = await _post('mosaic/validate', config);
    return response;
  }
}
