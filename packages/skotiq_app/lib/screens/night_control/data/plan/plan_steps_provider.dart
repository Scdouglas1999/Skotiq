// The Steps list: the plan's instructions in run order, each with its status
// and a time. A finished step shows when it finished, when this session's
// events recorded it, and no time otherwise; a step still to run shows the
// estimator's time.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../night_control_contracts.dart';
import 'night_plan_inputs.dart';
import '../../../../services/run_control/run_control.dart';
import '../../../../services/night_session/night_now.dart';

/// The step the run is executing; null when no run is live.
///
/// The executor's current node when it is a step, else the first step it
/// reports running (the current node can be a container between steps).
final nightActiveStepProvider = Provider<NightPlanEntry?>((ref) {
  if (!ref.watch(nightRunPhaseProvider).isRunLive) return null;
  final tree = ref.watch(nightPlanTreeProvider);
  if (tree == null) return null;
  final progress = ref.watch(sequenceStepProgressProvider);
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

/// What a skip of the active step leaves the run to do, when that ends the
/// night: the steps still to come (their labels), all of which only close it
/// (warm the camera, stop guiding, park the mount or dome, close the cover or
/// dome), or none at all. Null when the skip leaves imaging to do, when a loop
/// may run the step again, or when no step is known to be running.
final nightSkipEndsRunProvider = Provider<List<String>?>((ref) {
  final tree = ref.watch(nightPlanTreeProvider);
  final active = ref.watch(nightActiveStepProvider);
  if (tree == null || active == null) return null;
  return closingStepsAfterSkip(tree, active)
      ?.map(
        (step) => nightStepLabel(step.node),
      )
      .toList();
});

/// The steps after [active] when each only closes the night; null when one
/// does more, or when [active] may run again (it sits in a loop, or the plan
/// itself loops).
List<NightPlanEntry>? closingStepsAfterSkip(
  NightPlanTree tree,
  NightPlanEntry active,
) {
  if (tree.sequence.rootNode is LoopNode) return null;
  if (active.multiplier > 1 || active.openEnded) return null;
  final index = tree.stepIndexOf(active.node.id);
  if (index < 0) return null;
  final after = tree.steps.sublist(index + 1);
  return after.every((step) => _closesTheNight(step.node)) ? after : null;
}

bool _closesTheNight(SequenceNode node) =>
    node is WarmCameraNode ||
    node is StopGuidingNode ||
    node is ParkNode ||
    node is ParkDomeNode ||
    node is CloseDomeNode ||
    node is CloseCoverNode;

/// "Ha 60 × 180 s" for an exposure; the plan's own name for anything else.
String nightStepLabel(SequenceNode node) {
  if (node is ExposureNode) {
    // A dark reads "Dark 10 × 55 s", not as the wheel's filter.
    final filter = node.frameType.caption(node.filter);
    final burst =
        '${node.count} × ${QuantityFormat.exposure(node.durationSecs)}';
    return filter == null ? burst : '$filter $burst';
  }
  return node.name;
}

PlanStepStatus _statusOf(NodeStatus? status) => switch (status) {
      NodeStatus.success => PlanStepStatus.done,
      NodeStatus.running => PlanStepStatus.active,
      NodeStatus.failure => PlanStepStatus.failed,
      NodeStatus.skipped => PlanStepStatus.skipped,
      NodeStatus.cancelled => PlanStepStatus.stopped,
      NodeStatus.pending || null => PlanStepStatus.pending,
    };

/// How far a live run is behind its plan: the time since the planned start
/// of its next step, once that has passed; zero otherwise.
///
/// The estimate runs from the run's start, so after a pause or a long flip
/// every later step and the plan's end read as times already gone ("Park
/// mount ≈21:19" at 22:37). Steps still to run move by this much.
final nightPlanLagProvider = Provider<Duration>((ref) {
  if (!ref.watch(nightRunPhaseProvider).isRunLive) return Duration.zero;
  final tree = ref.watch(nightPlanTreeProvider);
  final timing = ref.watch(nightPlanTimingProvider);
  if (tree == null || timing == null) return Duration.zero;
  final statuses = ref.watch(
    sequenceProgressProvider.select((p) => p.nodeStatuses),
  );
  final active = ref.watch(nightActiveStepProvider);
  final now = ref.watch(nightNowProvider);
  final from = active == null ? 0 : tree.stepIndexOf(active.node.id) + 1;
  for (var i = from; i < tree.steps.length; i++) {
    final id = tree.steps[i].node.id;
    final status = statuses[id];
    if (status != null && status != NodeStatus.pending) continue;
    final estimate = timing.of(id);
    if (estimate == null) continue;
    final behind = now.difference(estimate.estimatedStart);
    return behind.isNegative ? Duration.zero : behind;
  }
  return Duration.zero;
});

final nightPlanStepsProvider = Provider<List<PlanStepVm>>((ref) {
  final tree = ref.watch(nightPlanTreeProvider);
  if (tree == null || tree.steps.isEmpty) return const <PlanStepVm>[];

  final phase = ref.watch(nightRunPhaseProvider);
  // Statuses describe the run that set them. Before a run starts they are
  // whatever the previous run left, so a plan waiting to start reads pending.
  final hasRun = phase.isRunLive || phase == NightRunPhase.finished;
  final progress = ref.watch(sequenceStepProgressProvider);
  final tally = ref.watch(nodeExposureTallyProvider);
  final active = ref.watch(nightActiveStepProvider);
  final timing = ref.watch(nightPlanTimingProvider);
  final recorded = ref.watch(runNodeTimesProvider);
  final clock = ref.watch(clockProvider);

  final lag = ref.watch(nightPlanLagProvider);

  StepWhen? planned(String nodeId, {Duration shift = Duration.zero}) {
    final estimate = timing?.of(nodeId);
    return estimate == null
        ? null
        : StepWhenPlanned(
            clock.wallClockOf(estimate.estimatedStart.add(shift)),
          );
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
                PlanStepStatus.skipped ||
                PlanStepStatus.stopped:
            final finished = status == PlanStepStatus.done
                ? recorded.succeededAt(id)
                : recorded.completed[id];
            // An estimate for a step that already ran reads as a time still
            // to come; a client that joined later has no event for it.
            when = finished != null
                ? StepWhenActual(clock.wallClockOf(finished))
                : null;
          case PlanStepStatus.pending:
            when = planned(id, shift: lag);
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
