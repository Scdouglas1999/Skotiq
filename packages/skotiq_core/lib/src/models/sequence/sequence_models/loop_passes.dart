part of '../sequence_models.dart';

/// The exposure seconds one pass of [loop] collects: its enabled Exposure
/// steps directly under it.
double loopPassExposureSecs(LoopNode loop, Map<String, SequenceNode> nodes) {
  var secs = 0.0;
  for (final childId in loop.childIds) {
    final child = nodes[childId];
    if (child is ExposureNode && child.isEnabled) {
      secs += child.totalDurationSecs;
    }
  }
  return secs;
}

/// How many passes [loop] makes when its condition fixes the number: its
/// repeat count, or enough passes to reach its integration target (the
/// executor repeats while the run's integration is short of it). Null when
/// the loop runs by time or sky, or names no integration it could reach.
int? loopPasses(LoopNode loop, Map<String, SequenceNode> nodes) {
  switch (loop.conditionType) {
    case LoopConditionType.count:
      return loop.repeatCount ?? 1;
    case LoopConditionType.integrationTime:
      final target = loop.integrationTimeTarget;
      if (target == null || target <= 0) return null;
      final perPass = loopPassExposureSecs(loop, nodes);
      if (perPass <= 0) return null;
      return (target / perPass).ceil();
    case LoopConditionType.untilTime ||
        LoopConditionType.forever ||
        LoopConditionType.whileDark ||
        LoopConditionType.untilAltitude ||
        LoopConditionType.altitudeAbove:
      return null;
  }
}
