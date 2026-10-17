import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/database_entities.dart'
    show Target, TargetsCompanion;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for target CRUD operations
class TargetHandlers {
  final ProviderContainer container;

  TargetHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'TargetHandlers');

  // A helper rather than `int.parse`: on a malformed path segment `int.parse`
  // throws FormatException, which the generic trap renders as a 500 with a
  // stack trace in the body. BadRequestError becomes a structured 400 through
  // errorTranslationMiddleware.
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

  // Get all targets

  Future<Response> handleGetAllTargets(Request request) async {
    _logInfo('[API] GET /api/targets');
    final database = container.read(databaseProvider);
    final targets = await database.targetsDao.getAllTargets();

    return jsonOk({'targets': targets.map((t) => _targetToJson(t)).toList()});
  }

  // Get Target By ID

  Future<Response> handleGetTargetById(Request request, String id) async {
    _logInfo('[API] GET /api/targets/$id');
    final targetId = _parsePathId(id, 'id');
    final database = container.read(databaseProvider);
    final target = await database.targetsDao.getTargetById(targetId);

    if (target == null) {
      return jsonNotFound({'error': 'Target not found: $id'});
    }

    return jsonOk({'target': _targetToJson(target)});
  }

  // Search targets

  Future<Response> handleSearchTargets(Request request) async {
    final query = request.url.queryParameters['query'] ?? '';
    _logInfo('[API] GET /api/targets/search?query=$query');
    final database = container.read(databaseProvider);
    final targets = await database.targetsDao.searchTargets(query);

    return jsonOk({'targets': targets.map((t) => _targetToJson(t)).toList()});
  }

  // Get favorite targets

  Future<Response> handleGetFavoriteTargets(Request request) async {
    _logInfo('[API] GET /api/targets/favorites');
    final database = container.read(databaseProvider);
    final targets = await database.targetsDao.getFavoriteTargets();

    return jsonOk({'targets': targets.map((t) => _targetToJson(t)).toList()});
  }

  // Create target

  Future<Response> handleCreateTarget(Request request) async {
    _logInfo('[API] POST /api/targets');
    final payload = await readJsonObject(request);
    final database = container.read(databaseProvider);

    final companion = TargetsCompanion(
      name: Value(requireString(payload, 'name')),
      catalogId: Value(optionalString(payload, 'catalogId')),
      ra: Value(requireDouble(payload, 'ra', min: 0, max: 24)),
      dec: Value(requireDouble(payload, 'dec', min: -90, max: 90)),
      objectType: Value(optionalString(payload, 'objectType')),
      constellation: Value(optionalString(payload, 'constellation')),
      magnitude: Value(optionalDouble(payload, 'magnitude')),
      sizeArcmin: Value(optionalDouble(payload, 'sizeArcmin', min: 0)),
      positionAngle: Value(
        optionalDouble(payload, 'positionAngle', min: 0, max: 360),
      ),
      minAltitude: Value(
        optionalDouble(payload, 'minAltitude', min: 0, max: 90) ?? 30.0,
      ),
      notes: Value(optionalString(payload, 'notes')),
      isFavorite: Value(optionalBool(payload, 'isFavorite') ?? false),
      priority: Value(optionalInt(payload, 'priority', min: 0) ?? 0),
      totalPlannedSubs: Value(
        optionalInt(payload, 'totalPlannedSubs', min: 0) ?? 0,
      ),
      capturedSubs: Value(optionalInt(payload, 'capturedSubs', min: 0) ?? 0),
      totalIntegrationSecs: Value(
        optionalDouble(payload, 'totalIntegrationSecs', min: 0) ?? 0.0,
      ),
      goalIntegrationSecs: Value(
        optionalDouble(payload, 'goalIntegrationSecs', min: 0) ?? 0.0,
      ),
      filterProgress: Value(optionalString(payload, 'filterProgress')),
    );

    final id = await database.targetsDao.createTarget(companion);

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.target,
      action: HostMutationAction.created,
      entityId: id.toString(),
      extra: {'name': requireString(payload, 'name')},
    );
    return jsonOk({'status': 'created', 'id': id});
  }

  // Update target

  Future<Response> handleUpdateTarget(Request request, String id) async {
    _logInfo('[API] PUT /api/targets/$id');
    final targetId = _parsePathId(id, 'id');
    final payload = await readJsonObject(request);
    final database = container.read(databaseProvider);

    // Get existing target
    final existing = await database.targetsDao.getTargetById(targetId);
    if (existing == null) {
      return jsonNotFound({'error': 'Target not found: $id'});
    }

    // Build updated target. Why optional* with fallback to existing values:
    // PUT semantics here are partial-update — missing fields preserve current
    // state rather than overwriting with null.
    final updated = existing.copyWith(
      name: optionalString(payload, 'name') ?? existing.name,
      catalogId: Value(
        optionalString(payload, 'catalogId') ?? existing.catalogId,
      ),
      ra: optionalDouble(payload, 'ra', min: 0, max: 24) ?? existing.ra,
      dec: optionalDouble(payload, 'dec', min: -90, max: 90) ?? existing.dec,
      objectType: Value(
        optionalString(payload, 'objectType') ?? existing.objectType,
      ),
      constellation: Value(
        optionalString(payload, 'constellation') ?? existing.constellation,
      ),
      magnitude: Value(
        optionalDouble(payload, 'magnitude') ?? existing.magnitude,
      ),
      sizeArcmin: Value(
        optionalDouble(payload, 'sizeArcmin', min: 0) ?? existing.sizeArcmin,
      ),
      positionAngle: Value(
        optionalDouble(payload, 'positionAngle', min: 0, max: 360) ??
            existing.positionAngle,
      ),
      minAltitude:
          optionalDouble(payload, 'minAltitude', min: 0, max: 90) ??
          existing.minAltitude,
      notes: Value(optionalString(payload, 'notes') ?? existing.notes),
      isFavorite: optionalBool(payload, 'isFavorite') ?? existing.isFavorite,
      priority: optionalInt(payload, 'priority', min: 0) ?? existing.priority,
      totalPlannedSubs:
          optionalInt(payload, 'totalPlannedSubs', min: 0) ??
          existing.totalPlannedSubs,
      capturedSubs:
          optionalInt(payload, 'capturedSubs', min: 0) ?? existing.capturedSubs,
      totalIntegrationSecs:
          optionalDouble(payload, 'totalIntegrationSecs', min: 0) ??
          existing.totalIntegrationSecs,
      goalIntegrationSecs:
          optionalDouble(payload, 'goalIntegrationSecs', min: 0) ??
          existing.goalIntegrationSecs,
      filterProgress: Value(
        optionalString(payload, 'filterProgress') ?? existing.filterProgress,
      ),
      updatedAt: DateTime.now(),
    );

    await database.targetsDao.updateTarget(updated);

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.target,
      action: HostMutationAction.updated,
      entityId: targetId.toString(),
      extra: {'name': updated.name},
    );
    return jsonOk({'status': 'updated'});
  }

  // Delete target

  Future<Response> handleDeleteTarget(Request request, String id) async {
    _logInfo('[API] DELETE /api/targets/$id');
    final targetId = _parsePathId(id, 'id');
    final database = container.read(databaseProvider);

    final deleted = await database.targetsDao.deleteTarget(targetId);
    if (deleted == 0) {
      return jsonNotFound({'error': 'Target not found: $id'});
    }

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.target,
      action: HostMutationAction.deleted,
      entityId: targetId.toString(),
    );
    return jsonOk({'status': 'deleted'});
  }

  // Toggle favorite

  Future<Response> handleToggleFavorite(Request request, String id) async {
    _logInfo('[API] POST /api/targets/$id/favorite');
    final targetId = _parsePathId(id, 'id');
    final database = container.read(databaseProvider);

    await database.targetsDao.toggleFavorite(targetId);

    return jsonOk({'status': 'toggled'});
  }

  // Update progress

  Future<Response> handleUpdateProgress(Request request, String id) async {
    _logInfo('[API] PUT /api/targets/$id/progress');
    final targetId = _parsePathId(id, 'id');
    final payload = await readJsonObject(request);
    final database = container.read(databaseProvider);

    await database.targetsDao.updateProgress(
      targetId,
      capturedSubs: optionalInt(payload, 'capturedSubs', min: 0),
      totalIntegrationSecs: optionalDouble(
        payload,
        'totalIntegrationSecs',
        min: 0,
      ),
      filterProgress: optionalString(payload, 'filterProgress'),
    );

    return jsonOk({'status': 'updated'});
  }

  // Get targets by type

  Future<Response> handleGetTargetsByType(Request request) async {
    final objectType = request.url.queryParameters['type'] ?? '';
    _logInfo('[API] GET /api/targets/by-type?type=$objectType');
    final database = container.read(databaseProvider);
    final targets = await database.targetsDao.getTargetsByType(objectType);

    return jsonOk({'targets': targets.map((t) => _targetToJson(t)).toList()});
  }

  // Get targets by priority

  Future<Response> handleGetTargetsByPriority(Request request) async {
    _logInfo('[API] GET /api/targets/by-priority');
    final database = container.read(databaseProvider);
    final targets = await database.targetsDao.getTargetsByPriority();

    return jsonOk({'targets': targets.map((t) => _targetToJson(t)).toList()});
  }

  // Helper: Convert Target to JSON

  Map<String, dynamic> _targetToJson(Target target) {
    return {
      'id': target.id,
      'name': target.name,
      'catalogId': target.catalogId,
      'ra': target.ra,
      'dec': target.dec,
      'objectType': target.objectType,
      'constellation': target.constellation,
      'magnitude': target.magnitude,
      'sizeArcmin': target.sizeArcmin,
      'positionAngle': target.positionAngle,
      'minAltitude': target.minAltitude,
      'notes': target.notes,
      'isFavorite': target.isFavorite,
      'priority': target.priority,
      'totalPlannedSubs': target.totalPlannedSubs,
      'capturedSubs': target.capturedSubs,
      'totalIntegrationSecs': target.totalIntegrationSecs,
      'goalIntegrationSecs': target.goalIntegrationSecs,
      'filterProgress': target.filterProgress,
      'createdAt': target.createdAt.millisecondsSinceEpoch,
      'updatedAt': target.updatedAt.millisecondsSinceEpoch,
    };
  }
}
