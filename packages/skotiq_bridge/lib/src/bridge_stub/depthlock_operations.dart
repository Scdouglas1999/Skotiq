part of '../bridge_stub.dart';

/// DepthLock goal store + frame ingestion.
///
/// Every generated entry point but `inspectReference`, `ingestFrame` and
/// `replayGoal` is synchronous on the Rust side (the store is an in-memory
/// map behind a lock). They are wrapped as futures here so the backend role
/// has one shape and a later move of the store onto a worker isolate does not
/// change a single caller.
extension _NativeBridgeDepthLockOperations on _NativeBridgeImplementation {
  Future<gen_api.ApiDepthLockStatus> apiDepthlockStatus() async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDepthlockStatus');
    }
    return gen_api.apiDepthlockStatus();
  }

  Future<List<gen_api.ApiDepthGoal>> apiDepthlockListGoals() async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDepthlockListGoals');
    }
    return gen_api.apiDepthlockListGoals();
  }

  Future<gen_api.ApiDepthGoal> apiDepthlockGetGoal({
    required String goalId,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDepthlockGetGoal');
    }
    return gen_api.apiDepthlockGetGoal(goalId: goalId);
  }

  /// An empty [goalId] asks the native side to generate one.
  Future<gen_api.ApiDepthGoal> apiDepthlockCreateGoal({
    required String goalId,
    required gen_api.ApiDepthGoalDefinition definition,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDepthlockCreateGoal');
    }
    return gen_api.apiDepthlockCreateGoal(
      goalId: goalId,
      definition: definition,
    );
  }

  Future<gen_api.ApiDepthGoal> apiDepthlockReviseGoal({
    required String goalId,
    required BigInt expectedRevision,
    required gen_api.ApiDepthGoalDefinition definition,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDepthlockReviseGoal');
    }
    return gen_api.apiDepthlockReviseGoal(
      goalId: goalId,
      expectedRevision: expectedRevision,
      definition: definition,
    );
  }

  Future<gen_api.ApiDepthGoal> apiDepthlockSetGoalPreferences({
    required String goalId,
    required BigInt expectedRevision,
    required bool enabled,
    required bool automaticCompletion,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDepthlockSetGoalPreferences');
    }
    return gen_api.apiDepthlockSetGoalPreferences(
      goalId: goalId,
      expectedRevision: expectedRevision,
      enabled: enabled,
      automaticCompletion: automaticCompletion,
    );
  }

  Future<void> apiDepthlockRemoveGoal({
    required String goalId,
    required BigInt expectedRevision,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDepthlockRemoveGoal');
    }
    gen_api.apiDepthlockRemoveGoal(
      goalId: goalId,
      expectedRevision: expectedRevision,
    );
  }

  Future<gen_api.ApiDepthReferenceInfo> apiDepthlockInspectReference({
    required String path,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDepthlockInspectReference');
    }
    return gen_api.apiDepthlockInspectReference(path: path);
  }

  Future<gen_api.ApiDepthFloorSuggestion> apiDepthlockSuggestFloor({
    required String referencePath,
    required String darkPath,
    required String flatPath,
    required double scaleArcsec,
    double? pixelScaleArcsec,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDepthlockSuggestFloor');
    }
    return gen_api.apiDepthlockSuggestFloor(
      referencePath: referencePath,
      darkPath: darkPath,
      flatPath: flatPath,
      scaleArcsec: scaleArcsec,
      pixelScaleArcsec: pixelScaleArcsec,
    );
  }

  Future<gen_api.ApiSkyRectangle> apiDepthlockSkyRectangle({
    required gen_api.ApiReferenceGeometry reference,
    required double x0,
    required double y0,
    required double x1,
    required double y1,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDepthlockSkyRectangle');
    }
    return gen_api.apiDepthlockSkyRectangle(
      reference: reference,
      x0: x0,
      y0: y0,
      x1: x1,
      y1: y1,
    );
  }

  Future<int> apiDepthlockCheckMeasurement({
    required gen_api.ApiDepthMeasurement measurement,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDepthlockCheckMeasurement');
    }
    return gen_api.apiDepthlockCheckMeasurement(measurement: measurement);
  }

  Future<gen_api.ApiDepthIngestOutcome> apiDepthlockIngestFrame({
    required String goalId,
    required String path,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDepthlockIngestFrame');
    }
    return gen_api.apiDepthlockIngestFrame(goalId: goalId, path: path);
  }

  Future<List<gen_api.ApiDepthCurvePoint>> apiDepthlockGoalCurve({
    required String goalId,
    required int maxPoints,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDepthlockGoalCurve');
    }
    return gen_api.apiDepthlockGoalCurve(goalId: goalId, maxPoints: maxPoints);
  }

  Future<gen_api.ApiDepthGoal> apiDepthlockReplayGoal({
    required String goalId,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('apiDepthlockReplayGoal');
    }
    return gen_api.apiDepthlockReplayGoal(goalId: goalId);
  }
}
