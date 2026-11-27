// Where the run stands and which of its controls can be pressed, and why
// not: one answer for every surface that offers them (the Sequencer header,
// the phone builder's toolbar, the shell's mini bar and Tonight's header).
// A surface decides how a control looks; this decides whether it may be
// pressed.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../night_actions/night_action_api.dart';
import '../night_actions/night_action_controller.dart';
import '../night_actions/night_text.dart';

/// Whether one control can be pressed; when it cannot, the reason it gives.
@immutable
class RunControl {
  const RunControl.enabled()
      : enabled = true,
        disabledReason = null;

  const RunControl.disabled(NightText this.disabledReason) : enabled = false;

  final bool enabled;

  /// Shown in the tooltip and the semantics hint when [enabled] is false.
  final NightText? disabledReason;

  @override
  bool operator ==(Object other) =>
      other is RunControl &&
      other.enabled == enabled &&
      other.disabledReason == disabledReason;

  @override
  int get hashCode => Object.hash(enabled, disabledReason);
}

const _enabled = RunControl.enabled();

RunControl _off(String key) => RunControl.disabled(NightText(key));

/// Where tonight's run stands.
enum NightRunPhase {
  /// No plan loaded, or the rig is not connected enough to start one.
  notSetUp,

  /// A plan is loaded and could start now.
  ready,

  /// "Start at dark" is armed; the run starts at astronomical dark.
  armed,

  running,

  pausedByUser,

  /// The action controller paused the run to perform a manual action, or a
  /// manual Loop holds it. [ManualActionState.active] says which.
  pausedForAction,

  /// Stop was requested and the run is finalizing.
  stopping,

  /// The run ended (completed, stopped or failed) and nothing new is loaded.
  finished,
}

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

/// The manual-action controller's state, as the run controls read it.
final runActionStateProvider = Provider<ManualActionState>(
  (ref) => ref.watch(nightActionStateProvider),
);

/// True when [action] is what holds a paused run: the controller paused the
/// run for it, or a manual Loop keeps it paused.
bool actionHoldsRun(ManualActionState action) =>
    action.active != null &&
    (action.startedRunPause || action.active == ManualActionId.loop);

/// True when the camera is connected, the least a run needs to start.
final runCameraConnectedProvider = Provider<bool>((ref) {
  return ref.watch(cameraStateProvider.select((s) => s.connectionState)) ==
      DeviceConnectionState.connected;
});

final nightRunPhaseProvider = Provider<NightRunPhase>((ref) {
  final execution = ref.watch(sequenceExecutionStateProvider);
  switch (execution) {
    case SequenceExecutionState.running ||
          // Recovery is the run handling a fault on its own; it is still the
          // run, and the controls say what is unavailable.
          SequenceExecutionState.recovering:
      return NightRunPhase.running;
    case SequenceExecutionState.paused:
      return actionHoldsRun(ref.watch(runActionStateProvider))
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

  if (ref.watch(nightArmedStartProvider) != null) {
    return NightRunPhase.armed;
  }
  // The executor stays completed or failed until the next start, so the
  // night keeps reading as finished, with its results, until then.
  if (execution == SequenceExecutionState.completed ||
      execution == SequenceExecutionState.failed) {
    return NightRunPhase.finished;
  }
  // A stopped or dawn-ended run settles idle; while its plan is still the
  // one loaded, the night reads as finished with its results, not as a plan
  // that never ran.
  final ended = ref.watch(lastEndedRunProvider);
  if (ended != null &&
      ended.ranLoadedPlan(
        ref.watch(currentSequenceProvider.select((s) => s?.id)),
      )) {
    return NightRunPhase.finished;
  }
  final launchable =
      ref.watch(currentSequenceProvider.select((s) => s?.launchable));
  if (launchable != true) return NightRunPhase.notSetUp;
  if (!ref.watch(runCameraConnectedProvider)) return NightRunPhase.notSetUp;
  return NightRunPhase.ready;
});

/// A rule a surface's run controls follow beyond the run's own state.
enum RunGate {
  /// The backend can carry a command: a remote viewer whose host went away
  /// must not offer to pause a run.
  commandAuthority,

  /// A manual action holding the pause owns the resume, and nothing skips
  /// the step under it.
  actionHold,

  /// No run starts while a meridian flip moves the mount.
  flip,

  /// A run starts only with a plan to run, a computer to run it on and a
  /// camera.
  readiness,
}

/// The run's controls: null when the run's phase does not offer one.
@immutable
class RunTransport {
  const RunTransport({
    required this.phase,
    this.pauseResume,
    this.skip,
    this.stop,
    this.start,
    RunControl? startGate,
    NightText? startBlock,
  })  : _startGate = startGate,
        _startBlock = startBlock;

  final NightRunPhase phase;

  /// Pause while running, Resume while paused ([resumes]).
  final RunControl? pauseResume;
  final RunControl? skip;
  final RunControl? stop;
  final RunControl? start;

  /// The start's state before readiness and a flip are asked.
  final RunControl? _startGate;

  /// Why no run can start at all (no plan, no camera, a flip); null when
  /// one can.
  final NightText? _startBlock;

  /// The control is Resume, not Pause.
  bool get resumes =>
      phase == NightRunPhase.pausedByUser ||
      phase == NightRunPhase.pausedForAction;

  /// A start at a later time: [whenFree] adds its own rules to the start's
  /// state once nothing blocks a start. While armed it is the cancel, which
  /// is always possible.
  RunControl? startLater(RunControl Function(RunControl gate) whenFree) {
    if (phase == NightRunPhase.armed) return _enabled;
    final gate = _startGate;
    if (gate == null) return null;
    final block = _startBlock;
    return block != null ? RunControl.disabled(block) : whenFree(gate);
  }
}

/// The run's controls in [phase] under [gates].
///
/// [notReadyReason] is why a plan cannot start (asked only under
/// [RunGate.readiness]).
RunTransport runTransportFor({
  required NightRunPhase phase,
  required SequenceExecutionState execution,
  required Set<RunGate> gates,
  bool canCommand = true,
  bool flipInProgress = false,
  String? notReadyReason,
}) {
  RunControl gated(bool allowed, String reasonKey) {
    if (!allowed) return _off(reasonKey);
    return canCommand || !gates.contains(RunGate.commandAuthority)
        ? _enabled
        : _off('ncPlanCannotCommand');
  }

  final livePhase = phase == NightRunPhase.pausedForAction &&
          !gates.contains(RunGate.actionHold)
      ? NightRunPhase.pausedByUser
      : phase;
  final liveReason = execution == SequenceExecutionState.recovering
      ? 'ncPlanRecovering'
      : 'ncPlanStopping';
  switch (livePhase) {
    case NightRunPhase.running:
      return RunTransport(
        phase: livePhase,
        pauseResume: gated(execution.canPause, liveReason),
        skip: gated(execution.canSkip, liveReason),
        stop: gated(execution.canStop, liveReason),
      );
    case NightRunPhase.pausedByUser:
      return RunTransport(
        phase: livePhase,
        pauseResume: gated(execution.canResume, liveReason),
        skip: gated(execution.canSkip, liveReason),
        stop: gated(execution.canStop, liveReason),
      );
    case NightRunPhase.pausedForAction:
      // The action controller resumes what it paused; a second resume would
      // race it. Stop stays available.
      return RunTransport(
        phase: livePhase,
        pauseResume: _off('ncPlanActionOwnsResume'),
        skip: _off('ncPlanActionInProgress'),
        stop: gated(execution.canStop, liveReason),
      );
    case NightRunPhase.stopping:
      return RunTransport(
        phase: livePhase,
        pauseResume: _off('ncPlanStopping'),
        skip: _off('ncPlanStopping'),
        // A failed stop or cleanup offers Stop again; finalizing has nothing
        // left to stop.
        stop: gated(execution.canStop, 'ncPlanFinalizing'),
      );
    case NightRunPhase.armed ||
          NightRunPhase.ready ||
          NightRunPhase.finished ||
          NightRunPhase.notSetUp:
      final startGate = gated(execution.canStart, 'ncPlanStopping');
      final notReady =
          phase == NightRunPhase.armed || !gates.contains(RunGate.readiness)
              ? null
              : notReadyReason;
      final flip = flipInProgress && gates.contains(RunGate.flip);
      final block = flip
          ? const NightText('nightActBusyFlip')
          : notReady == null
              ? null
              : NightText(notReady);
      return RunTransport(
        phase: livePhase,
        start: block == null ? startGate : RunControl.disabled(block),
        startGate: startGate,
        startBlock: block,
      );
  }
}

/// Why a plan cannot start at all, or null when it can.
String? _notReadyReason({
  required bool? launchable,
  required bool hasHost,
  required bool cameraConnected,
}) {
  if (launchable == null) return 'ncPlanNoPlan';
  if (!launchable) return 'ncPlanNothingToRun';
  // No imaging computer means no camera to connect: say what to do first.
  if (!hasHost) return 'ncPlanLinkComputer';
  if (!cameraConnected) return 'ncPlanConnectCamera';
  return null;
}

RunTransport _transport(Ref ref, Set<RunGate> gates) {
  final phase = ref.watch(nightRunPhaseProvider);
  final starts = !phase.isRunLive;
  return runTransportFor(
    phase: phase,
    execution: ref.watch(sequenceExecutionStateProvider),
    gates: gates,
    canCommand: gates.contains(RunGate.commandAuthority)
        ? ref.watch(backendCanCommandProvider)
        : true,
    flipInProgress: starts &&
        gates.contains(RunGate.flip) &&
        ref.watch(isFlipInProgressProvider),
    notReadyReason: starts && gates.contains(RunGate.readiness)
        ? _notReadyReason(
            launchable: ref.watch(
              currentSequenceProvider.select((s) => s?.launchable),
            ),
            hasHost: !ref.watch(
              backendProvider.select((b) => b.hostPlace == HostPlace.none),
            ),
            cameraConnected: ref.watch(runCameraConnectedProvider),
          )
        : null,
  );
}

/// The run's controls under every gate: what Tonight offers.
final runTransportProvider = Provider<RunTransport>(
  (ref) => _transport(ref, RunGate.values.toSet()),
);

/// The run's controls as the Sequencer and the shell's mini bar offer them.
final sequencerRunTransportProvider = Provider<RunTransport>(
  (ref) =>
      _transport(ref, const {RunGate.actionHold, RunGate.commandAuthority}),
);
