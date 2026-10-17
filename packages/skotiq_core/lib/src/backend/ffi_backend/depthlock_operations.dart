part of '../ffi_backend.dart';

/// DepthLock over the FFI bridge.
///
/// The native side owns the goal store and the verdict; this mixin only
/// translates. Revisions and counters cross the bridge as `BigInt`/
/// `PlatformInt64` and become plain `int` here so no UI or wire code ever
/// sees a bridge-only numeric type.
///
/// Native refusals arrive as `SkotiqError.operationFailed(reason)` and are
/// deliberately not caught: the reason is written for the operator and every
/// layer above shows it verbatim.
mixin _FfiDepthLockOperations on _FfiBackendBase {
  @override
  Future<DepthLockStatus> depthLockStatus() async {
    final status = await bridge.NativeBridge.apiDepthlockStatus();
    return _fromBridgeDepthLockStatus(status);
  }

  @override
  Future<List<DepthLockGoal>> listDepthLockGoals() async {
    final goals = await bridge.NativeBridge.apiDepthlockListGoals();
    return goals.map(_fromBridgeDepthGoal).toList(growable: false);
  }

  @override
  Future<DepthLockGoal> getDepthLockGoal(String goalId) async {
    final goal = await bridge.NativeBridge.apiDepthlockGetGoal(goalId: goalId);
    return _fromBridgeDepthGoal(goal);
  }

  @override
  Future<DepthLockGoal> createDepthLockGoal(
    DepthLockGoalDefinition definition, {
    String? goalId,
  }) async {
    // The native contract reads an empty id as "generate one" rather than
    // taking an option, so a null id becomes the empty string here.
    final goal = await bridge.NativeBridge.apiDepthlockCreateGoal(
      goalId: goalId ?? '',
      definition: _toBridgeDepthGoalDefinition(definition),
    );
    return _fromBridgeDepthGoal(goal);
  }

  @override
  Future<DepthLockGoal> reviseDepthLockGoal({
    required String goalId,
    required int expectedRevision,
    required DepthLockGoalDefinition definition,
  }) async {
    final goal = await bridge.NativeBridge.apiDepthlockReviseGoal(
      goalId: goalId,
      expectedRevision: BigInt.from(expectedRevision),
      definition: _toBridgeDepthGoalDefinition(definition),
    );
    return _fromBridgeDepthGoal(goal);
  }

  @override
  Future<DepthLockGoal> setDepthLockGoalPreferences({
    required String goalId,
    required int expectedRevision,
    required bool enabled,
    required bool automaticCompletion,
  }) async {
    final goal = await bridge.NativeBridge.apiDepthlockSetGoalPreferences(
      goalId: goalId,
      expectedRevision: BigInt.from(expectedRevision),
      enabled: enabled,
      automaticCompletion: automaticCompletion,
    );
    return _fromBridgeDepthGoal(goal);
  }

  @override
  Future<void> removeDepthLockGoal({
    required String goalId,
    required int expectedRevision,
  }) async {
    await bridge.NativeBridge.apiDepthlockRemoveGoal(
      goalId: goalId,
      expectedRevision: BigInt.from(expectedRevision),
    );
  }

  @override
  Future<DepthLockReferenceInfo> inspectDepthLockReference(String path) async {
    final info = await bridge.NativeBridge.apiDepthlockInspectReference(
      path: path,
    );
    return _fromBridgeDepthReferenceInfo(info);
  }

  @override
  Future<List<DepthLockCurvePoint>> depthLockGoalCurve(
    String goalId, {
    int maxPoints = 60,
  }) async {
    final points = await bridge.NativeBridge.apiDepthlockGoalCurve(
      goalId: goalId,
      maxPoints: maxPoints,
    );
    return points.map(_fromBridgeDepthCurvePoint).toList(growable: false);
  }

  @override
  Future<DepthLockFloorSuggestion> suggestDepthLockFloor({
    required String referencePath,
    required String darkPath,
    required String flatPath,
    required double scaleArcsec,
    double? pixelScaleArcsec,
  }) async {
    final suggestion = await bridge.NativeBridge.apiDepthlockSuggestFloor(
      referencePath: referencePath,
      darkPath: darkPath,
      flatPath: flatPath,
      scaleArcsec: scaleArcsec,
      pixelScaleArcsec: pixelScaleArcsec,
    );
    return _fromBridgeDepthFloorSuggestion(suggestion);
  }

  @override
  Future<SkyRectangle> depthLockSkyRectangle({
    required ReferenceGeometry reference,
    required double x0,
    required double y0,
    required double x1,
    required double y1,
  }) async {
    final rectangle = await bridge.NativeBridge.apiDepthlockSkyRectangle(
      reference: _toBridgeReferenceGeometry(reference),
      x0: x0,
      y0: y0,
      x1: x1,
      y1: y1,
    );
    return _fromBridgeSkyRectangle(rectangle);
  }

  @override
  Future<int> checkDepthLockMeasurement(
    DepthLockMeasurement measurement,
  ) async {
    return bridge.NativeBridge.apiDepthlockCheckMeasurement(
      measurement: _toBridgeDepthMeasurement(measurement),
    );
  }

  @override
  Future<DepthLockIngestOutcome> ingestDepthLockFrame({
    required String goalId,
    required String path,
  }) async {
    final outcome = await bridge.NativeBridge.apiDepthlockIngestFrame(
      goalId: goalId,
      path: path,
    );
    return DepthLockIngestOutcome(
      outcome: outcome.outcome,
      state: outcome.state == null
          ? null
          : DepthLockState.fromWire(outcome.state!),
      reason: outcome.reason,
    );
  }

  @override
  Future<DepthLockGoal> replayDepthLockGoal(String goalId) async {
    final goal = await bridge.NativeBridge.apiDepthlockReplayGoal(
      goalId: goalId,
    );
    return _fromBridgeDepthGoal(goal);
  }
}
