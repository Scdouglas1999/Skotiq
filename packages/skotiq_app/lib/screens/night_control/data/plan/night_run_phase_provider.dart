// Where tonight's run stands. Replaces the old dashboard's two answers to the
// same question (`dashboardStandbyProvider` and `tonightHeroStateProvider`)
// with one that also knows about armed starts and manual-action pauses.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import '../../night_control_contracts.dart';
import 'night_plan_inputs.dart';

/// True when [action] is what holds a paused run: the controller paused the
/// run for it, or a manual Loop keeps it paused.
bool nightActionHoldsRun(ManualActionState action) =>
    action.active != null &&
    (action.startedRunPause || action.active == ManualActionId.loop);

/// True when the camera is connected, the least a run needs to start.
final nightCameraConnectedProvider = Provider<bool>((ref) {
  return ref.watch(cameraStateProvider.select((s) => s.connectionState)) ==
      DeviceConnectionState.connected;
});

final nightRunPhaseProvider = Provider<NightRunPhase>((ref) {
  final execution = ref.watch(sequenceExecutionStateProvider);
  switch (execution) {
    case SequenceExecutionState.running ||
          // Recovery is the run handling a fault on its own; it is still the
          // run, and the header's controls say what is unavailable.
          SequenceExecutionState.recovering:
      return NightRunPhase.running;
    case SequenceExecutionState.paused:
      final action = ref.watch(nightPlanActionStateSeamProvider);
      return nightActionHoldsRun(action)
          ? NightRunPhase.pausedForAction
          : NightRunPhase.pausedByUser;
    case SequenceExecutionState.stopping ||
          SequenceExecutionState.finalizing ||
          // A failed stop or cleanup is still on its way to stopped: Stop is
          // offered again, Start is not.
          SequenceExecutionState.stopFailed ||
          SequenceExecutionState.cleanupFailed:
      return NightRunPhase.stopping;
    case SequenceExecutionState.idle ||
          SequenceExecutionState.completed ||
          SequenceExecutionState.failed:
      break;
  }

  if (ref.watch(nightPlanArmedStartSeamProvider) != null) {
    return NightRunPhase.armed;
  }
  // The executor stays completed or failed until the next start, so the
  // night keeps reading as finished, with its results, until then.
  if (execution == SequenceExecutionState.completed ||
      execution == SequenceExecutionState.failed) {
    return NightRunPhase.finished;
  }
  final tree = ref.watch(nightPlanTreeProvider);
  if (tree == null || !tree.launchable) return NightRunPhase.notSetUp;
  if (!ref.watch(nightCameraConnectedProvider)) return NightRunPhase.notSetUp;
  return NightRunPhase.ready;
});

extension NightRunPhaseFacts on NightRunPhase {
  /// A run owns the rig: running, paused or on its way to stopped.
  bool get isRunLive => switch (this) {
        NightRunPhase.running ||
        NightRunPhase.pausedByUser ||
        NightRunPhase.pausedForAction ||
        NightRunPhase.stopping =>
          true,
        NightRunPhase.notSetUp ||
        NightRunPhase.ready ||
        NightRunPhase.armed ||
        NightRunPhase.finished =>
          false,
      };
}
