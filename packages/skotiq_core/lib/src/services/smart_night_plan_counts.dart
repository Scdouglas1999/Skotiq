import '../models/imaging/imaging_models.dart' show FrameType;
import '../models/sequence/sequence_models.dart';
import 'smart_night_models.dart';

/// The preview's frame-count tweak: [plan] with filter row [filterIndex] of
/// [target] taking [delta] more frames (clamped to 1..999), its totals and
/// tree to match.
///
/// Wall-clock moves by the exposure time added or taken away; the tree's
/// capture steps are patched in place, each under the target header the
/// planned target emitted (its name and coordinates, so two targets of one
/// name stay apart) and by filter name, rather than emitted again.
SmartNightPlan smartNightPlanWithCountChange(
  SmartNightPlan plan,
  SmartNightPlannedTarget target,
  int filterIndex,
  int delta,
) {
  var wallClockDeltaSecs = 0.0;

  final newPlannedTargets = <SmartNightPlannedTarget>[];
  for (final p in plan.plannedTargets) {
    if (p == target) {
      final updatedFilters = <SmartNightFilterPlan>[];
      for (var i = 0; i < p.filterPlans.length; i++) {
        if (i == filterIndex) {
          final fp = p.filterPlans[i];
          final newCount = (fp.count + delta).clamp(1, 999).toInt();
          wallClockDeltaSecs += (newCount - fp.count) * fp.durationSecs;
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

  return SmartNightPlan(
    sequence: _patchSequenceCounts(plan.sequence, newPlannedTargets),
    plannedTargets: newPlannedTargets,
    totalIntegrationSecs: newPlannedTargets.fold<double>(
      0,
      (s, p) => s + p.integrationSecs,
    ),
    estimatedWallClockSecs: (plan.estimatedWallClockSecs + wallClockDeltaSecs)
        .clamp(0, double.infinity),
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
  final newNodes = <String, SequenceNode>{...seq.nodes};

  SmartNightPlannedTarget? plannedTargetOf(SequenceNode node) {
    final header = seq.enclosingTarget(node.id);
    if (header == null) return null;
    for (final t in targets) {
      if (t.suggestion.targetName == header.targetName &&
          t.suggestion.raHours == header.raHours &&
          t.suggestion.decDegrees == header.decDegrees) {
        return t;
      }
    }
    return null;
  }

  for (final entry in seq.nodes.entries) {
    final node = entry.value;
    if (node is ExposureNode && node.frameType == FrameType.light) {
      final tweaked = plannedTargetOf(node);
      if (tweaked == null || !tweaked.isUnfiltered) continue;
      final plan = tweaked.filterPlans.single;
      newNodes[node.id] = node.copyWith(
        count: plan.count,
        durationSecs: plan.durationSecs,
      );
      continue;
    }
    if (node is! SmartExposureNode) continue;
    final tweaked = plannedTargetOf(node);
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
