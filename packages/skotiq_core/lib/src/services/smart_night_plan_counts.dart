import '../models/imaging/imaging_models.dart' show FrameType;
import '../models/sequence/sequence_models.dart';
import 'plan_timer.dart';
import 'smart_night_models.dart';

/// The preview's frame-count tweak: [plan] with filter row [filterIndex] of
/// [target] taking [delta] more frames (clamped to 1..999), its totals and
/// tree to match.
///
/// The tree's capture steps are patched in place, matched by target name
/// and filter name, rather than emitted again, and the patched tree is timed
/// again by [planTimer] over the plan's window, as the plan was built.
SmartNightPlan smartNightPlanWithCountChange(
  SmartNightPlan plan,
  SmartNightPlannedTarget target,
  int filterIndex,
  int delta, {
  required PlanTimer planTimer,
}) {
  final newPlannedTargets = <SmartNightPlannedTarget>[];
  for (final p in plan.plannedTargets) {
    if (p == target) {
      final updatedFilters = <SmartNightFilterPlan>[];
      for (var i = 0; i < p.filterPlans.length; i++) {
        if (i == filterIndex) {
          final fp = p.filterPlans[i];
          final newCount = (fp.count + delta).clamp(1, 999).toInt();
          updatedFilters.add(
            SmartNightFilterPlan(
              filterName: fp.filterName,
              count: newCount,
              durationSecs: fp.durationSecs,
              recommendation: fp.recommendation,
            ),
          );
        } else {
          updatedFilters.add(p.filterPlans[i]);
        }
      }
      final newIntegration = updatedFilters.fold<double>(
        0,
        (s, fp) => s + fp.integrationSecs,
      );
      newPlannedTargets.add(
        SmartNightPlannedTarget(
          suggestion: p.suggestion,
          windowStart: p.windowStart,
          windowEnd: p.windowEnd,
          filterPlans: updatedFilters,
          integrationSecs: newIntegration,
          rationale: p.rationale,
          filterReason: p.filterReason,
        ),
      );
    } else {
      newPlannedTargets.add(p);
    }
  }

  final sequence = _patchSequenceCounts(plan.sequence, newPlannedTargets);
  final simulation = planTimer.simulate(
    sequence,
    start: plan.context.windowStart,
    darkWindowStart: plan.context.windowStart,
    darkWindowEnd: plan.context.windowEnd,
  );
  return SmartNightPlan(
    sequence: sequence,
    plannedTargets: newPlannedTargets,
    totalIntegrationSecs: newPlannedTargets.fold<double>(
      0,
      (s, p) => s + p.integrationSecs,
    ),
    estimatedWallClockSecs: simulation.duration.inSeconds.toDouble(),
    warnings: plan.warnings,
    strategy: plan.strategy,
    settings: plan.settings,
    context: plan.context,
  );
}

/// Every capture step in [seq] with the counts of [targets]. A wheel-less
/// target emits a single unfiltered [ExposureNode] instead of a
/// [SmartExposureNode]; its count comes from the target's one filter plan.
Sequence _patchSequenceCounts(
  Sequence seq,
  List<SmartNightPlannedTarget> targets,
) {
  final byTargetName = <String, SmartNightPlannedTarget>{
    for (final t in targets) t.suggestion.targetName: t,
  };
  final newNodes = <String, SequenceNode>{...seq.nodes};

  String? targetNameFor(SequenceNode node) =>
      seq.enclosingTarget(node.id)?.targetName;

  for (final entry in seq.nodes.entries) {
    final node = entry.value;
    if (node is ExposureNode && node.frameType == FrameType.light) {
      final targetName = targetNameFor(node);
      if (targetName == null) continue;
      final tweaked = byTargetName[targetName];
      if (tweaked == null || !tweaked.isUnfiltered) continue;
      final plan = tweaked.filterPlans.single;
      newNodes[node.id] = node.copyWith(
        count: plan.count,
        durationSecs: plan.durationSecs,
      );
      continue;
    }
    if (node is! SmartExposureNode) continue;
    final targetName = targetNameFor(node);
    if (targetName == null) continue;
    final tweaked = byTargetName[targetName];
    if (tweaked == null) continue;
    final newPlans = <FilterPlan>[];
    for (final plan in node.plans) {
      final matchingTweak = tweaked.filterPlans.firstWhere(
        (fp) => fp.filterName == plan.filterName,
        orElse: () => SmartNightFilterPlan(
          filterName: plan.filterName,
          count: plan.count,
          durationSecs: plan.durationSecs,
        ),
      );
      newPlans.add(
        plan.copyWith(
          count: matchingTweak.count,
          durationSecs: matchingTweak.durationSecs,
        ),
      );
    }
    newNodes[node.id] = node.copyWith(
      plans: newPlans,
      integrationBudgetSecs: tweaked.integrationSecs,
    );
  }
  return seq.copyWith(nodes: newNodes);
}
