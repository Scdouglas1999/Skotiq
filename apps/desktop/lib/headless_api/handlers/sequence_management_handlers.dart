import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/database_entities.dart'
    show Sequence, SequenceNode, SequencesCompanion, SequenceNodesCompanion;
import 'package:skotiq_core/skotiq_core.dart'
    hide Sequence, SequenceNode; // Hide domain models
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for sequence management (CRUD operations)
/// This is SEPARATE from sequencer_handlers.dart which controls sequencer execution.
class SequenceManagementHandlers {
  final ProviderContainer container;

  static const Set<String> _logicNodeTypes = {
    'loop',
    'Loop',
    'parallel',
    'Parallel',
    'conditional',
    'Conditional',
    'recovery',
    'Recovery',
    'instructionSet',
    'InstructionSet',
    'targetScheduler',
    'TargetScheduler',
    'target_scheduler',
  };
  static const Set<String> _targetNodeTypes = {'targetGroup', 'TargetHeader'};
  static const Set<String> _triggerNodeTypes = {'meridianFlip', 'MeridianFlip'};
  static const Set<String> _instructionNodeTypes = {
    'exposure',
    'TakeExposure',
    'slew',
    'SlewToTarget',
    'center',
    'CenterTarget',
    'autofocus',
    'Autofocus',
    'dither',
    'Dither',
    'filterChange',
    'ChangeFilter',
    'coolCamera',
    'CoolCamera',
    'warmCamera',
    'WarmCamera',
    'rotator',
    'MoveRotator',
    'park',
    'Park',
    'unpark',
    'Unpark',
    'waitTime',
    'WaitForTime',
    'delay',
    'Delay',
    'notification',
    'Notification',
    'script',
    'RunScript',
    'startGuiding',
    'StartGuiding',
    'stopGuiding',
    'StopGuiding',
    'openDome',
    'OpenDome',
    'closeDome',
    'CloseDome',
    'parkDome',
    'ParkDome',
    'polarAlignment',
    'PolarAlignment',
    'smartExposure',
    'SmartExposure',
    'smart_exposure',
    'pluginNode',
    'PluginNode',
    'plugin_node',
    'liveStacking',
    'LiveStacking',
    'live_stacking',
    'openCover',
    'OpenCover',
    'open_cover',
    'closeCover',
    'CloseCover',
    'close_cover',
    'calibratorOn',
    'CalibratorOn',
    'calibrator_on',
    'calibratorOff',
    'CalibratorOff',
    'calibrator_off',
    'sciencePhotometry',
    'SciencePhotometry',
    'science_photometry',
  };

  SequenceManagementHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'SequenceManagementHandlers');

  /// Parse a numeric URL path segment to an int.
  ///
  /// Why a dedicated helper: `int.parse(id)` throws `FormatException` on a
  /// bad segment, which the errorTranslationMiddleware would map to 500 +
  /// requestId. That's wrong — a non-numeric path segment is a client-side
  /// error, so we raise BadRequestError and the middleware emits a clean 400.
  int _parsePathId(String value, String field) {
    final parsed = int.tryParse(value);
    if (parsed == null) {
      throw BadRequestError(
        field: field,
        expected: 'integer',
        message: 'Path segment "$value" is not a valid integer id',
      );
    }
    return parsed;
  }

  void _validateNodeWireType(String nodeType, String specificType) {
    final expectedCategory = switch (specificType) {
      _ when _logicNodeTypes.contains(specificType) => 'logic',
      _ when _targetNodeTypes.contains(specificType) => 'target',
      _ when _triggerNodeTypes.contains(specificType) => 'trigger',
      _ when _instructionNodeTypes.contains(specificType) => 'instruction',
      _ => null,
    };
    if (expectedCategory == null) {
      throw BadRequestError(
        field: 'specificType',
        expected: 'a supported sequence node type',
        message: 'Unsupported sequence node type "$specificType"',
      );
    }
    if (nodeType != expectedCategory) {
      throw BadRequestError(
        field: 'nodeType',
        expected: expectedCategory,
        message:
            'Node type "$specificType" belongs to category "$expectedCategory"',
      );
    }
  }

  void _validatePropertiesJson(String properties) {
    try {
      final decoded = jsonDecode(properties);
      if (decoded is! Map) {
        throw const FormatException('properties is not an object');
      }
    } on FormatException {
      throw BadRequestError(
        field: 'properties',
        expected: 'a JSON object encoded as a string',
      );
    }
  }

  // Full sequence documents (remote companion sync)

  /// GET /api/sequence-management/list-full
  ///
  /// Returns complete sequence trees using the same JSON schema as file export
  /// so mobile companions do not maintain a separate local SQLite copy.
  Future<Response> handleListFullSequences(Request request) async {
    _logInfo('[API] GET /api/sequence-management/list-full');
    final fileService = container.read(sequenceFileServiceProvider);
    final repo = container.read(sequenceRepositoryProvider);
    final sequences = await repo.loadAllSequences();

    return jsonOk({
      'sequences': sequences.map((sequence) {
        final map = fileService.sequenceToMap(sequence);
        if (sequence.databaseId != null) {
          map['databaseId'] = sequence.databaseId;
        }
        return map;
      }).toList(),
    });
  }

  /// GET /api/sequence-management/templates-full
  Future<Response> handleListFullTemplates(Request request) async {
    _logInfo('[API] GET /api/sequence-management/templates-full');
    final fileService = container.read(sequenceFileServiceProvider);
    final repo = container.read(sequenceRepositoryProvider);
    final templates = await repo.loadAllTemplates();

    return jsonOk({
      'templates': templates.map((sequence) {
        final map = fileService.sequenceToMap(sequence);
        if (sequence.databaseId != null) {
          map['databaseId'] = sequence.databaseId;
        }
        return map;
      }).toList(),
    });
  }

  /// GET `/api/sequence-management/<id>/full`
  Future<Response> handleGetFullSequence(Request request, String id) async {
    final sequenceId = _parsePathId(id, 'id');
    _logInfo('[API] GET /api/sequence-management/$sequenceId/full');
    final fileService = container.read(sequenceFileServiceProvider);
    final sequence = await container
        .read(sequenceRepositoryProvider)
        .loadSequence(sequenceId);
    if (sequence == null) {
      return jsonNotFound({'error': 'Sequence not found: $id'});
    }
    final map = fileService.sequenceToMap(sequence);
    map['databaseId'] = sequenceId;
    return jsonOk({'sequence': map});
  }

  /// POST /api/sequence-management/save-full
  Future<Response> handleSaveFullSequence(Request request) async {
    _logInfo('[API] POST /api/sequence-management/save-full');
    final payload = await readJsonObject(request);
    final sequenceMap = requireObject(payload, 'sequence');
    final isTemplate = optionalBool(payload, 'isTemplate') ?? false;
    final databaseId = optionalInt(payload, 'databaseId');

    final fileService = container.read(sequenceFileServiceProvider);
    final repo = container.read(sequenceRepositoryProvider);
    // Parse defensively, matching `handleSaveProfile`: `parseFromMap` throws a
    // bare FormatException/TypeError on any shape it dislikes, which the
    // top-level guard turns into `500 internal_error`. A caller sending the
    // wrong node encoding is a client error, and a 500 reads as a server fault
    // that clients are entitled to retry — a sequence whose `nodes` is a JSON
    // list would answer `500 internal_error: FormatException: Sequence field
    // "nodes" must be a JSON object, got List<dynamic>`.
    var sequence = (() {
      try {
        return fileService.parseFromMap(Map<String, dynamic>.from(sequenceMap));
      } on FormatException catch (error) {
        // `parseFromMap` raises FormatException with an authored, caller-facing
        // reason that names the offending field ("Sequence node missing
        // nodeType", "Unsupported sequence node type: ..."). Echo only that
        // `message`: the stringified exception would prefix the Dart class name
        // ("FormatException: ..."), which HandlerFailure/BadRequestError
        // explicitly forbid shipping to the network.
        final reason = error.message.trim();
        throw BadRequestError(
          field: 'sequence',
          expected: 'sequence_document',
          message: reason.isEmpty
              ? 'Malformed sequence payload.'
              : 'Malformed sequence payload: '
                    '${reason.length > 200 ? '${reason.substring(0, 200)}...' : reason}',
        );
      } on Object catch (error, stackTrace) {
        // Any other shape is a parser bug, not an authored validation message:
        // a TypeError reads "type 'String' is not a subtype of type 'int' in
        // type cast", which tells the caller nothing actionable and leaks our
        // internals. The caller still gets 400 — the payload really is
        // unparseable — but the diagnostic goes to the host log only.
        _logger.error(
          'save-full: sequence payload rejected by parser',
          source: 'SequenceManagementHandlers',
          fields: {'error': '$error', 'stack': stackTrace.toString()},
        );
        throw BadRequestError(
          field: 'sequence',
          expected: 'sequence_document',
          message:
              'Malformed sequence payload: the document could not be parsed. '
              'See the host log for the parser diagnostic.',
        );
      }
    })();
    if (databaseId != null) {
      sequence = sequence.copyWith(databaseId: databaseId);
    }

    final id = await repo.saveSequence(sequence, isTemplate: isTemplate);
    notifySequenceCatalogChangedFromContainer(
      container,
      sequenceId: id,
      action: 'saved',
      name: sequence.name,
      isTemplate: isTemplate,
    );
    return jsonOk({'id': id});
  }

  /// GET /api/sequence-management/summaries
  ///
  /// Returns the same lightweight, persisted metadata the desktop sequence
  /// library uses. This keeps tags, favorites and run roll-ups intact on a
  /// companion without transferring every full sequence tree.
  Future<Response> handleListSequenceSummaries(Request request) async {
    _logInfo('[API] GET /api/sequence-management/summaries');
    final summaries = await container
        .read(sequenceRepositoryProvider)
        .loadSequenceSummaries();
    return jsonOk({
      'summaries': summaries.map(_summaryToJson).toList(growable: false),
    });
  }

  /// PUT `/api/sequence-management/<id>/tags`
  Future<Response> handleSetTags(Request request, String id) async {
    final sequenceId = _parsePathId(id, 'id');
    _logInfo('[API] PUT /api/sequence-management/$sequenceId/tags');
    final payload = await readJsonObject(request);
    final tags = requireList<String>(payload, 'tags');
    final database = container.read(databaseProvider);
    final existing = await database.sequencesDao.getSequenceById(sequenceId);
    if (existing == null) {
      return jsonNotFound({'error': 'Sequence not found: $id'});
    }

    await container.read(sequenceRepositoryProvider).setTags(sequenceId, tags);
    notifySequenceCatalogChangedFromContainer(
      container,
      sequenceId: sequenceId,
      action: 'updated',
      name: existing.name,
      isTemplate: existing.isTemplate,
    );
    return jsonOk({'status': 'updated'});
  }

  /// POST `/api/sequence-management/<id>/favorite`
  Future<Response> handleToggleFavorite(Request request, String id) async {
    final sequenceId = _parsePathId(id, 'id');
    _logInfo('[API] POST /api/sequence-management/$sequenceId/favorite');
    final database = container.read(databaseProvider);
    final existing = await database.sequencesDao.getSequenceById(sequenceId);
    if (existing == null) {
      return jsonNotFound({'error': 'Sequence not found: $id'});
    }

    final isFavorite = await container
        .read(sequenceRepositoryProvider)
        .toggleFavorite(sequenceId);
    notifySequenceCatalogChangedFromContainer(
      container,
      sequenceId: sequenceId,
      action: 'updated',
      name: existing.name,
      isTemplate: existing.isTemplate,
    );
    return jsonOk({'status': 'updated', 'isFavorite': isFavorite});
  }

  /// POST `/api/sequence-management/<id>/versions`
  ///
  /// Version rows are explicit save points. The debounced remote editor saves
  /// through `save-full`, so it does not consume version rows every 1.5
  /// seconds; the Save dialog calls this route after a meaningful save.
  Future<Response> handleSnapshotVersion(Request request, String id) async {
    final sequenceId = _parsePathId(id, 'id');
    _logInfo('[API] POST /api/sequence-management/$sequenceId/versions');
    final payload = await readJsonObject(request);
    final sequenceMap = requireObject(payload, 'sequence');
    final label = optionalString(
      payload,
      'label',
      allowEmpty: true,
      maxLength: 200,
    );
    final database = container.read(databaseProvider);
    final existing = await database.sequencesDao.getSequenceById(sequenceId);
    if (existing == null) {
      return jsonNotFound({'error': 'Sequence not found: $id'});
    }

    // Parse and re-encode through the canonical file schema before storing so
    // a malformed client document can never become an unrestorable row.
    final fileService = container.read(sequenceFileServiceProvider);
    final parsed = fileService.parseFromMap(
      Map<String, dynamic>.from(sequenceMap),
    );
    final snapshotJson = jsonEncode(fileService.sequenceToMap(parsed));
    final versionId = await database.sequenceVersionsDao.appendVersion(
      sequenceId: sequenceId,
      snapshotJson: snapshotJson,
      label: label,
    );
    return jsonOk({'id': versionId});
  }

  /// GET `/api/sequence-management/<id>/versions`
  Future<Response> handleListVersions(Request request, String id) async {
    final sequenceId = _parsePathId(id, 'id');
    _logInfo('[API] GET /api/sequence-management/$sequenceId/versions');
    final database = container.read(databaseProvider);
    if (await database.sequencesDao.getSequenceById(sequenceId) == null) {
      return jsonNotFound({'error': 'Sequence not found: $id'});
    }
    final versions = await database.sequenceVersionsDao.listVersions(
      sequenceId,
    );
    return jsonOk({
      'versions': versions.map(_versionSummaryToJson).toList(growable: false),
    });
  }

  /// GET `/api/sequence-management/versions/<versionId>`
  Future<Response> handleGetVersion(Request request, String versionId) async {
    final parsedId = _parsePathId(versionId, 'versionId');
    _logInfo('[API] GET /api/sequence-management/versions/$parsedId');
    final version = await container
        .read(databaseProvider)
        .sequenceVersionsDao
        .loadVersion(parsedId);
    if (version == null) {
      return jsonNotFound({'error': 'Sequence version not found: $versionId'});
    }
    return jsonOk({'version': _versionToJson(version)});
  }

  // Get all sequences

  Future<Response> handleGetAllSequences(Request request) async {
    _logInfo('[API] GET /api/sequence-management/list');
    final database = container.read(databaseProvider);
    final sequences = await database.sequencesDao.getAllSequences();

    return jsonOk({
      'sequences': sequences.map((s) => _sequenceToJson(s)).toList(),
    });
  }

  // Get all templates

  Future<Response> handleGetAllTemplates(Request request) async {
    _logInfo('[API] GET /api/sequence-management/templates');
    final database = container.read(databaseProvider);
    final templates = await database.sequencesDao.getAllTemplates();

    return jsonOk({
      'templates': templates.map((s) => _sequenceToJson(s)).toList(),
    });
  }

  // Get Sequence By ID

  Future<Response> handleGetSequenceById(Request request, String id) async {
    _logInfo('[API] GET /api/sequence-management/$id');
    final sequenceId = _parsePathId(id, 'id');
    final database = container.read(databaseProvider);
    final sequence = await database.sequencesDao.getSequenceById(sequenceId);

    if (sequence == null) {
      return jsonNotFound({'error': 'Sequence not found: $id'});
    }

    return jsonOk({'sequence': _sequenceToJson(sequence)});
  }

  // Get nodes for sequence

  Future<Response> handleGetNodesForSequence(Request request, String id) async {
    _logInfo('[API] GET /api/sequence-management/$id/nodes');
    final sequenceId = _parsePathId(id, 'id');
    final database = container.read(databaseProvider);
    final nodes = await database.sequencesDao.getNodesForSequence(sequenceId);

    return jsonOk({'nodes': nodes.map((n) => _nodeToJson(n)).toList()});
  }

  // Create sequence

  Future<Response> handleCreateSequence(Request request) async {
    _logInfo('[API] POST /api/sequence-management');
    final payload = await readJsonObject(request);
    final database = container.read(databaseProvider);

    final companion = SequencesCompanion.insert(
      name: requireString(payload, 'name'),
      description: Value(optionalString(payload, 'description')),
      rootNodeId: Value(optionalString(payload, 'rootNodeId')),
      isTemplate: Value(optionalBool(payload, 'isTemplate') ?? false),
    );

    final id = await database.sequencesDao.createSequence(companion);

    notifySequenceCatalogChangedFromContainer(
      container,
      sequenceId: id,
      action: 'created',
      name: requireString(payload, 'name'),
      isTemplate: optionalBool(payload, 'isTemplate') ?? false,
    );
    return jsonOk({'status': 'created', 'id': id});
  }

  // Update sequence

  Future<Response> handleUpdateSequence(Request request, String id) async {
    _logInfo('[API] PUT /api/sequence-management/$id');
    final sequenceId = _parsePathId(id, 'id');
    final payload = await readJsonObject(request);
    final database = container.read(databaseProvider);

    // Get existing sequence
    final existing = await database.sequencesDao.getSequenceById(sequenceId);
    if (existing == null) {
      return jsonNotFound({'error': 'Sequence not found: $id'});
    }

    // Build updated sequence. optionalString returning null when the field is
    // absent means we fall back to the existing values, preserving partial-
    // update semantics.
    final updated = existing.copyWith(
      name: optionalString(payload, 'name') ?? existing.name,
      description: Value(
        optionalString(payload, 'description') ?? existing.description,
      ),
      rootNodeId: Value(
        optionalString(payload, 'rootNodeId') ?? existing.rootNodeId,
      ),
      isTemplate: optionalBool(payload, 'isTemplate') ?? existing.isTemplate,
      updatedAt: DateTime.now(),
    );

    await database.sequencesDao.updateSequence(updated);

    notifySequenceCatalogChangedFromContainer(
      container,
      sequenceId: sequenceId,
      action: 'updated',
      name: updated.name,
      isTemplate: updated.isTemplate,
    );
    return jsonOk({'status': 'updated'});
  }

  // Delete sequence

  Future<Response> handleDeleteSequence(Request request, String id) async {
    _logInfo('[API] DELETE /api/sequence-management/$id');
    final sequenceId = _parsePathId(id, 'id');
    final database = container.read(databaseProvider);

    await database.sequencesDao.deleteSequence(sequenceId);

    notifySequenceCatalogChangedFromContainer(
      container,
      sequenceId: sequenceId,
      action: 'deleted',
    );

    return jsonOk({'status': 'deleted'});
  }

  // Duplicate sequence

  Future<Response> handleDuplicateSequence(Request request, String id) async {
    _logInfo('[API] POST /api/sequence-management/$id/duplicate');
    final sequenceId = _parsePathId(id, 'id');
    final payload = await readJsonObject(request);
    final newName =
        optionalString(payload, 'newName') ??
        optionalString(payload, 'name') ??
        'Copy';
    final database = container.read(databaseProvider);

    final newId = await database.sequencesDao.duplicateSequence(
      sequenceId,
      newName,
    );

    notifySequenceCatalogChangedFromContainer(
      container,
      sequenceId: newId,
      action: 'duplicated',
      name: newName,
    );

    return jsonOk({'status': 'duplicated', 'id': newId});
  }

  // Create node

  Future<Response> handleCreateNode(Request request, String sequenceId) async {
    _logInfo('[API] POST /api/sequence-management/$sequenceId/nodes');
    final seqId = _parsePathId(sequenceId, 'sequenceId');
    final payload = await readJsonObject(request);
    final database = container.read(databaseProvider);

    final propertiesValue = optionalString(payload, 'properties') ?? '{}';
    final nodeType = requireString(payload, 'nodeType');
    final specificType = requireString(payload, 'specificType');
    _validateNodeWireType(nodeType, specificType);
    _validatePropertiesJson(propertiesValue);
    if (await database.sequencesDao.getSequenceById(seqId) == null) {
      return jsonNotFound({'error': 'Sequence not found: $seqId'});
    }
    final companion = SequenceNodesCompanion.insert(
      nodeId: requireString(payload, 'nodeId'),
      sequenceId: seqId,
      targetId: Value(optionalInt(payload, 'targetId')),
      nodeType: nodeType,
      specificType: specificType,
      name: requireString(payload, 'name'),
      properties: Value(propertiesValue),
      recoveryConfig: Value(optionalString(payload, 'recoveryConfig')),
      parentNodeId: Value(optionalString(payload, 'parentNodeId')),
      orderIndex: Value(optionalInt(payload, 'orderIndex') ?? 0),
      isEnabled: Value(optionalBool(payload, 'isEnabled') ?? true),
    );

    final id = await database.sequencesDao.createNode(companion);

    notifySequenceCatalogChangedFromContainer(
      container,
      sequenceId: seqId,
      action: 'updated',
    );
    return jsonOk({'status': 'created', 'id': id});
  }

  // Update node

  Future<Response> handleUpdateNode(Request request, String nodeId) async {
    _logInfo('[API] PUT /api/sequence-management/nodes/$nodeId');
    final nid = _parsePathId(nodeId, 'nodeId');
    final payload = await readJsonObject(request);
    final database = container.read(databaseProvider);

    // Get existing node
    final existing = await database.sequencesDao.getNodeById(nid);
    if (existing == null) {
      return jsonNotFound({'error': 'Node not found: $nodeId'});
    }

    // Build updated node. As with handleUpdateSequence, missing fields fall
    // back to existing values.
    final updatedProperties =
        optionalString(payload, 'properties') ?? existing.properties;
    final updatedNodeType =
        optionalString(payload, 'nodeType') ?? existing.nodeType;
    final updatedSpecificType =
        optionalString(payload, 'specificType') ?? existing.specificType;
    _validateNodeWireType(updatedNodeType, updatedSpecificType);
    _validatePropertiesJson(updatedProperties);
    final updated = existing.copyWith(
      name: optionalString(payload, 'name') ?? existing.name,
      nodeType: updatedNodeType,
      specificType: updatedSpecificType,
      properties: updatedProperties,
      recoveryConfig: Value(
        optionalString(payload, 'recoveryConfig') ?? existing.recoveryConfig,
      ),
      parentNodeId: Value(
        optionalString(payload, 'parentNodeId') ?? existing.parentNodeId,
      ),
      orderIndex: optionalInt(payload, 'orderIndex') ?? existing.orderIndex,
      isEnabled: optionalBool(payload, 'isEnabled') ?? existing.isEnabled,
    );

    await database.sequencesDao.updateNode(updated);

    notifySequenceCatalogChangedFromContainer(
      container,
      sequenceId: existing.sequenceId,
      action: 'updated',
    );
    return jsonOk({'status': 'updated'});
  }

  // Delete node

  Future<Response> handleDeleteNode(Request request, String nodeId) async {
    _logInfo('[API] DELETE /api/sequence-management/nodes/$nodeId');
    final nid = _parsePathId(nodeId, 'nodeId');
    final database = container.read(databaseProvider);

    final existing = await database.sequencesDao.getNodeById(nid);
    if (existing == null) {
      return jsonNotFound({'error': 'Node not found: $nodeId'});
    }

    await database.sequencesDao.deleteNode(nid);

    notifySequenceCatalogChangedFromContainer(
      container,
      sequenceId: existing.sequenceId,
      action: 'updated',
    );

    return jsonOk({'status': 'deleted'});
  }

  // Reorder nodes

  Future<Response> handleReorderNodes(
    Request request,
    String sequenceId,
  ) async {
    _logInfo('[API] POST /api/sequence-management/$sequenceId/reorder');
    final seqId = _parsePathId(sequenceId, 'sequenceId');
    final payload = await readJsonObject(request);
    final nodeIds = requireList<String>(payload, 'nodeIds');
    final database = container.read(databaseProvider);

    await database.sequencesDao.reorderNodes(seqId, nodeIds);

    notifySequenceCatalogChangedFromContainer(
      container,
      sequenceId: seqId,
      action: 'updated',
    );
    return jsonOk({'status': 'reordered'});
  }

  // Set node enabled

  Future<Response> handleSetNodeEnabled(Request request, String nodeId) async {
    _logInfo('[API] POST /api/sequence-management/nodes/$nodeId/enabled');
    final nid = _parsePathId(nodeId, 'nodeId');
    final payload = await readJsonObject(request);
    final enabled = requireBool(payload, 'enabled');
    final database = container.read(databaseProvider);

    await database.sequencesDao.setNodeEnabled(nid, enabled);

    final node = await database.sequencesDao.getNodeById(nid);
    if (node != null) {
      notifySequenceCatalogChangedFromContainer(
        container,
        sequenceId: node.sequenceId,
        action: 'updated',
      );
    }
    return jsonOk({'status': 'updated'});
  }

  // Get child nodes

  Future<Response> handleGetChildNodes(
    Request request,
    String sequenceId,
    String parentNodeId,
  ) async {
    _logInfo(
      '[API] GET /api/sequence-management/$sequenceId/nodes/$parentNodeId/children',
    );
    final seqId = _parsePathId(sequenceId, 'sequenceId');
    final database = container.read(databaseProvider);
    final nodes = await database.sequencesDao.getChildNodes(
      seqId,
      parentNodeId,
    );

    return jsonOk({'nodes': nodes.map((n) => _nodeToJson(n)).toList()});
  }

  // Helper: Convert Sequence to JSON

  Map<String, dynamic> _sequenceToJson(Sequence sequence) {
    return {
      'id': sequence.id,
      'name': sequence.name,
      'description': sequence.description,
      'rootNodeId': sequence.rootNodeId,
      'isTemplate': sequence.isTemplate,
      'createdAt': sequence.createdAt.millisecondsSinceEpoch,
      'updatedAt': sequence.updatedAt.millisecondsSinceEpoch,
    };
  }

  Map<String, dynamic> _summaryToJson(SequenceSummary summary) => {
    'id': summary.id,
    'name': summary.name,
    'nodeCount': summary.nodeCount,
    'targetCount': summary.targetCount,
    'exposureCount': summary.exposureCount,
    'totalIntegrationSecs': summary.totalIntegrationSecs,
    'primaryTargetName': summary.primaryTargetName,
    'lastRunAt': summary.lastRunAt?.toIso8601String(),
    'runCount': summary.runCount,
    'tags': summary.tags,
    'isFavorite': summary.isFavorite,
    'createdAt': summary.createdAt.toIso8601String(),
    'modifiedAt': summary.modifiedAt.toIso8601String(),
  };

  Map<String, dynamic> _versionToJson(SequenceVersion version) => {
    'id': version.id,
    'sequenceId': version.sequenceId,
    'snapshotJson': version.snapshotJson,
    'label': version.label,
    'createdAt': version.createdAt.toIso8601String(),
  };

  Map<String, dynamic> _versionSummaryToJson(SequenceVersion version) => {
    'id': version.id,
    'sequenceId': version.sequenceId,
    'label': version.label,
    'createdAt': version.createdAt.toIso8601String(),
  };

  // Helper: Convert SequenceNode to JSON

  Map<String, dynamic> _nodeToJson(SequenceNode node) {
    return {
      'id': node.id,
      'nodeId': node.nodeId,
      'sequenceId': node.sequenceId,
      'targetId': node.targetId,
      'nodeType': node.nodeType,
      'specificType': node.specificType,
      'name': node.name,
      'properties': node.properties,
      'recoveryConfig': node.recoveryConfig,
      'parentNodeId': node.parentNodeId,
      'orderIndex': node.orderIndex,
      'isEnabled': node.isEnabled,
    };
  }
}
