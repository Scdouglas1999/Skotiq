part of '../network_backend.dart';

/// Remote (REST) client for the host's DepthLock goal store
/// (`/api/depthlock/*`).
///
/// The core models ARE the wire shape, so there is no second DTO layer here:
/// every response is decoded straight through `fromJson` and every request
/// body built from `toJson`. What this mixin adds is the refusal to guess —
/// a response missing its envelope key throws rather than handing back an
/// empty goal list, because "the host has no goals" and "the host answered
/// something else" are different facts and only one of them is safe to show.
///
/// Stale revisions come back as a 409 and validation refusals as a 400, both
/// carrying the native reason; `_parseErrorResponse` turns them into the
/// typed error the caller surfaces verbatim.
mixin _NetworkBackendDepthLockOperations on _NetworkBackendTransport {
  /// The value at [key], or a [ValidationException] naming what was missing.
  Map<String, dynamic> _depthLockObject(
    Map<String, dynamic> response,
    String key,
  ) {
    final value = response[key];
    if (value is! Map) {
      throw ValidationException(
        message: 'DepthLock response carries no "$key" object',
        userMessage: 'The host returned an unexpected DepthLock response.',
      );
    }
    return value.cast<String, dynamic>();
  }

  @override
  Future<DepthLockStatus> depthLockStatus() async {
    final response = await _get('depthlock/status');
    return DepthLockStatus.fromJson(_depthLockObject(response, 'status'));
  }

  @override
  Future<List<DepthLockGoal>> listDepthLockGoals() async {
    final response = await _get('depthlock/goals');
    return _rowsFromJson(response['goals'], DepthLockGoal.fromJson);
  }

  @override
  Future<DepthLockGoal> getDepthLockGoal(String goalId) async {
    final response = await _get('depthlock/goals/$goalId');
    return DepthLockGoal.fromJson(_depthLockObject(response, 'goal'));
  }

  @override
  Future<DepthLockGoal> createDepthLockGoal(
    DepthLockGoalDefinition definition, {
    String? goalId,
  }) async {
    final response = await _post('depthlock/goals', {
      if (goalId != null) 'goalId': goalId,
      'definition': definition.toJson(),
    });
    return DepthLockGoal.fromJson(_depthLockObject(response, 'goal'));
  }

  @override
  Future<DepthLockGoal> reviseDepthLockGoal({
    required String goalId,
    required int expectedRevision,
    required DepthLockGoalDefinition definition,
  }) async {
    final response = await _put('depthlock/goals/$goalId', {
      'expectedRevision': expectedRevision,
      'definition': definition.toJson(),
    });
    return DepthLockGoal.fromJson(_depthLockObject(response, 'goal'));
  }

  @override
  Future<DepthLockGoal> setDepthLockGoalPreferences({
    required String goalId,
    required int expectedRevision,
    required bool enabled,
    required bool automaticCompletion,
  }) async {
    final response = await _post('depthlock/goals/$goalId/preferences', {
      'expectedRevision': expectedRevision,
      'enabled': enabled,
      'automaticCompletion': automaticCompletion,
    });
    return DepthLockGoal.fromJson(_depthLockObject(response, 'goal'));
  }

  @override
  Future<void> removeDepthLockGoal({
    required String goalId,
    required int expectedRevision,
  }) async {
    // The revision rides in the query string because the transport's DELETE
    // carries no body, matching every other conditional delete on this client.
    await _delete('depthlock/goals/$goalId?expectedRevision=$expectedRevision');
  }

  @override
  Future<DepthLockReferenceInfo> inspectDepthLockReference(String path) async {
    final response = await _post('depthlock/reference/inspect', {'path': path});
    return DepthLockReferenceInfo.fromJson(
      _depthLockObject(response, 'reference'),
    );
  }

  @override
  Future<SkyRectangle> depthLockSkyRectangle({
    required ReferenceGeometry reference,
    required double x0,
    required double y0,
    required double x1,
    required double y1,
  }) async {
    final response = await _post('depthlock/reference/sky-rectangle', {
      'reference': reference.toJson(),
      'x0': x0,
      'y0': y0,
      'x1': x1,
      'y1': y1,
    });
    return SkyRectangle.fromJson(_depthLockObject(response, 'rectangle'));
  }

  @override
  Future<DepthLockFloorSuggestion> suggestDepthLockFloor({
    required String referencePath,
    required String darkPath,
    required String flatPath,
    required double scaleArcsec,
    double? pixelScaleArcsec,
  }) async {
    final response = await _post('depthlock/measurement/suggest-floor', {
      'referencePath': referencePath,
      'darkPath': darkPath,
      'flatPath': flatPath,
      'scaleArcsec': scaleArcsec,
      // Omitted rather than null when the caller has no scale of its own, so
      // the host reads it from the reference's TAN header exactly as a local
      // call would.
      if (pixelScaleArcsec != null) 'pixelScaleArcsec': pixelScaleArcsec,
    });
    return DepthLockFloorSuggestion.fromJson(
      _depthLockObject(response, 'suggestion'),
    );
  }

  @override
  Future<int> checkDepthLockMeasurement(
    DepthLockMeasurement measurement,
  ) async {
    final response = await _post('depthlock/measurement/check', {
      'measurement': measurement.toJson(),
    });
    final cells = response['cells'];
    if (cells is! int) {
      throw const ValidationException(
        message: 'DepthLock measurement check returned no "cells" count',
        userMessage: 'The host returned an unexpected DepthLock response.',
      );
    }
    return cells;
  }

  @override
  Future<DepthLockIngestOutcome> ingestDepthLockFrame({
    required String goalId,
    required String path,
  }) async {
    final response = await _post('depthlock/goals/$goalId/ingest', {
      'path': path,
    });
    return DepthLockIngestOutcome.fromJson(
      _depthLockObject(response, 'outcome'),
    );
  }

  @override
  Future<List<DepthLockCurvePoint>> depthLockGoalCurve(
    String goalId, {
    int maxPoints = 60,
  }) async {
    final response = await _get('depthlock/goals/$goalId/curve', {
      'maxPoints': maxPoints,
    });
    return _rowsFromJson(response['points'], DepthLockCurvePoint.fromJson);
  }

  @override
  Future<DepthLockGoal> replayDepthLockGoal(String goalId) async {
    final response = await _post('depthlock/goals/$goalId/replay');
    return DepthLockGoal.fromJson(_depthLockObject(response, 'goal'));
  }
}
