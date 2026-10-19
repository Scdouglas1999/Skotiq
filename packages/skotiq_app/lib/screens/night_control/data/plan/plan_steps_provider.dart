// The Steps list: the plan's instructions in run order, each with its status
// and a time. A finished step shows when it finished, when this session's
// events recorded it; otherwise every time is the estimator's.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import '../../night_control_contracts.dart';
import 'night_plan_inputs.dart';
import 'night_run_phase_provider.dart';

/// The step the run is executing; null when no run is live.
///
/// The executor's current node when it is a step, else the first step it
/// reports running (the current node can be a container between steps).
final nightActiveStepProvider = Provider<NightPlanEntry?>((ref) {
  if (!ref.watch(nightRunPhaseProvider).isRunLive) return null;
  final tree = ref.watch(nightPlanTreeProvider);
  if (tree == null) return null;
  final progress = ref.watch(sequenceProgressProvider);
  final currentId = progress.currentNodeId;
  if (currentId != null) {
    final index = tree.stepIndexOf(currentId);
    if (index >= 0) return tree.steps[index];
  }
  for (final step in tree.steps) {
    if (progress.nodeStatuses[step.node.id] == NodeStatus.running) {
      return step;
    }
  }
  return null;
});

/// "Ha 60 × 180 s" for an exposure; the plan's own name for anything else.
String nightStepLabel(SequenceNode node) {
  if (node is ExposureNode) {
    final filter = node.filter;
    final burst = '${node.count} × ${_seconds(node.durationSecs)} s';
    return filter == null || filter.isEmpty ? burst : '$filter $burst';
  }
  return node.name;
}

String _seconds(double secs) => secs == secs.roundToDouble()
    ? secs.round().toString()
    : secs.toStringAsFixed(1);

PlanStepStatus _statusOf(NodeStatus? status) => switch (status) {
      NodeStatus.success => PlanStepStatus.done,
      NodeStatus.running => PlanStepStatus.active,
      NodeStatus.failure => PlanStepStatus.failed,
      NodeStatus.skipped || NodeStatus.cancelled => PlanStepStatus.skipped,
      NodeStatus.pending || null => PlanStepStatus.pending,
    };

final nightPlanStepsProvider = Provider<List<PlanStepVm>>((ref) {
  final tree = ref.watch(nightPlanTreeProvider);
  if (tree == null || tree.steps.isEmpty) return const <PlanStepVm>[];

  final phase = ref.watch(nightRunPhaseProvider);
  // Statuses describe the run that set them. Before a run starts they are
  // whatever the previous run left, so a plan waiting to start reads pending.
  final hasRun = phase.isRunLive || phase == NightRunPhase.finished;
  final progress = ref.watch(sequenceProgressProvider);
  final tally = ref.watch(nodeExposureTallyProvider);
  final active = ref.watch(nightActiveStepProvider);
  final timing = ref.watch(nightPlanTimingProvider);
  final recorded = ref.watch(nightNodeEventTimesProvider);
  final clock = ref.watch(clockProvider);

  StepWhen? planned(String nodeId) {
    final estimate = timing?.of(nodeId);
    return estimate == null
        ? null
        : StepWhenPlanned(clock.toNightClock(estimate.estimatedStart));
  }

  return <PlanStepVm>[
    for (final step in tree.steps)
      () {
        final id = step.node.id;
        var status = hasRun ? _statusOf(progress.nodeStatuses[id]) : null;
        if (active != null && active.node.id == id) {
          status = PlanStepStatus.active;
        }
        status ??= PlanStepStatus.pending;

        StepWhen? when;
        switch (status) {
          case PlanStepStatus.active:
            // No frame reported yet (or no exposure step): the planned time,
            // not a "0/60" the run never said.
            final frames =
                nightNodeFrames(id, tally: tally, progress: progress);
            when = frames != null
                ? StepWhenProgress(
                    frames.captured,
                    frames.planned ?? nightPlannedFrames(step.node),
                  )
                : planned(id);
          case PlanStepStatus.done ||
                PlanStepStatus.failed ||
                PlanStepStatus.skipped:
            final finished = status == PlanStepStatus.done
                ? recorded.succeededAt(id)
                : recorded.completed[id];
            when = finished != null
                ? StepWhenActual(clock.toNightClock(finished))
                : planned(id);
          case PlanStepStatus.pending:
            when = planned(id);
        }

        return PlanStepVm(
          nodeId: id,
          label: nightStepLabel(step.node),
          status: status,
          depth: step.depth,
          when: when,
        );
      }(),
  ];
});
