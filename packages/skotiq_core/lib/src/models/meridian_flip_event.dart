import 'package:equatable/equatable.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart'
    show wireMap, wireOptDouble, wireOptInt, wireOptString;

/// The step name a native `FlipStep` serializes as (`EnablingTracking`),
/// as the Dart enum (`enablingTracking`).
FlipStep? flipStepFromNativeName(String stepName) {
  if (stepName.isEmpty) return null;
  final camel = '${stepName[0].toLowerCase()}${stepName.substring(1)}';
  return FlipStep.values.where((step) => step.name == camel).firstOrNull;
}

enum FlipStep {
  pausingGuider,
  enablingTracking,
  confirmingTracking,
  stoppingTracking,
  slewingToTarget,
  verifyingPierSide,
  resumingTracking,
  plateSolvingAndCentering,
  refocusing,
  resumingGuider,
  settling,
}

extension FlipStepExtension on FlipStep {
  String get displayName {
    switch (this) {
      case FlipStep.enablingTracking:
        return 'Turning tracking on';
      case FlipStep.confirmingTracking:
        return 'Confirming tracking';
      case FlipStep.pausingGuider:
        return 'Pausing Guider';
      case FlipStep.stoppingTracking:
        return 'Stopping Tracking';
      case FlipStep.slewingToTarget:
        return 'Slewing to Target';
      case FlipStep.verifyingPierSide:
        return 'Verifying Pier Side';
      case FlipStep.resumingTracking:
        return 'Resuming Tracking';
      case FlipStep.plateSolvingAndCentering:
        return 'Plate Solving & Centering';
      case FlipStep.refocusing:
        return 'Refocusing';
      case FlipStep.resumingGuider:
        return 'Resuming Guider';
      case FlipStep.settling:
        return 'Settling';
    }
  }

  String get description {
    switch (this) {
      case FlipStep.enablingTracking:
        return 'Turning mount tracking on before slewing';
      case FlipStep.confirmingTracking:
        return 'Checking that the mount follows the sky';
      case FlipStep.pausingGuider:
        return 'Pausing autoguiding before the flip';
      case FlipStep.stoppingTracking:
        return 'Stopping mount tracking before slewing';
      case FlipStep.slewingToTarget:
        return 'Slewing mount to target on opposite pier side';
      case FlipStep.verifyingPierSide:
        return 'Verifying mount has changed pier side';
      case FlipStep.resumingTracking:
        return 'Resuming sidereal tracking';
      case FlipStep.plateSolvingAndCentering:
        return 'Plate solving and centering target';
      case FlipStep.refocusing:
        return 'Running autofocus after flip';
      case FlipStep.resumingGuider:
        return 'Restarting autoguiding';
      case FlipStep.settling:
        return 'Waiting for mount to settle';
    }
  }
}

/// One step of a running meridian flip, as the native flip executor reports
/// it (`MeridianFlipEvent` in `meridian_events.rs`, sent externally tagged:
/// `{"StepStarted": {"step": "SlewingToTarget", ...}}`). The fields the app
/// reads are pinned by `test/fixtures/meridian_flip_events.json`, which the
/// native side's test writes from the same events.
sealed class MeridianFlipEvent extends Equatable {
  const MeridianFlipEvent();

  /// The event a flip progress report carries, or null when it is not one
  /// this build reads.
  static MeridianFlipEvent? fromWire(Object? json) {
    final tagged = wireMap(json);
    if (tagged.length != 1) return null;
    final data = tagged.values.single;
    if (data is! Map) return null;
    final fields = wireMap(data);
    final stepName = fields['step'];
    final step = stepName is String ? flipStepFromNativeName(stepName) : null;
    return switch (tagged.keys.single) {
      'Starting' => MeridianFlipStarting(
        targetName: wireOptString(fields, 'target_name'),
      ),
      'StepStarted' => MeridianFlipStepStarted(
        step: step,
        stepIndex: wireOptInt(fields, 'step_index'),
        totalSteps: wireOptInt(fields, 'total_steps'),
      ),
      'StepCompleted' => MeridianFlipStepCompleted(step: step),
      'StepFailed' => MeridianFlipStepFailed(
        step: step,
        error: wireOptString(fields, 'error'),
      ),
      'Progress' => MeridianFlipProgress(
        percent: wireOptInt(fields, 'percent'),
      ),
      'RetryScheduled' => MeridianFlipRetryScheduled(
        attempt: wireOptInt(fields, 'attempt'),
        maxAttempts: wireOptInt(fields, 'max_attempts'),
        delaySecs: wireOptDouble(fields, 'delay_secs'),
      ),
      'Completed' => MeridianFlipCompleted(
        durationSecs: wireOptDouble(fields, 'duration_secs'),
      ),
      'Failed' => MeridianFlipFailed(
        error: wireOptString(fields, 'error'),
        actionTaken: wireOptString(fields, 'action_taken'),
      ),
      'Aborted' => MeridianFlipAborted(reason: wireOptString(fields, 'reason')),
      _ => null,
    };
  }
}

/// The flip is starting.
class MeridianFlipStarting extends MeridianFlipEvent {
  const MeridianFlipStarting({this.targetName});
  final String? targetName;
  @override
  List<Object?> get props => [targetName];
}

/// A step has started. [step] is null for a step this build has no name for.
class MeridianFlipStepStarted extends MeridianFlipEvent {
  const MeridianFlipStepStarted({this.step, this.stepIndex, this.totalSteps});
  final FlipStep? step;
  final int? stepIndex;
  final int? totalSteps;
  @override
  List<Object?> get props => [step, stepIndex, totalSteps];
}

class MeridianFlipStepCompleted extends MeridianFlipEvent {
  const MeridianFlipStepCompleted({this.step});
  final FlipStep? step;
  @override
  List<Object?> get props => [step];
}

class MeridianFlipStepFailed extends MeridianFlipEvent {
  const MeridianFlipStepFailed({this.step, this.error});
  final FlipStep? step;
  final String? error;
  @override
  List<Object?> get props => [step, error];
}

/// How far the whole flip is, 0 to 100.
class MeridianFlipProgress extends MeridianFlipEvent {
  const MeridianFlipProgress({this.percent});
  final int? percent;
  @override
  List<Object?> get props => [percent];
}

/// An attempt failed and the next is scheduled. [attempt] is the one that
/// failed, counted from 1.
class MeridianFlipRetryScheduled extends MeridianFlipEvent {
  const MeridianFlipRetryScheduled({
    this.attempt,
    this.maxAttempts,
    this.delaySecs,
  });
  final int? attempt;
  final int? maxAttempts;
  final double? delaySecs;
  @override
  List<Object?> get props => [attempt, maxAttempts, delaySecs];
}

class MeridianFlipCompleted extends MeridianFlipEvent {
  const MeridianFlipCompleted({this.durationSecs});
  final double? durationSecs;
  @override
  List<Object?> get props => [durationSecs];
}

/// The flip failed after all retries.
class MeridianFlipFailed extends MeridianFlipEvent {
  const MeridianFlipFailed({this.error, this.actionTaken});
  final String? error;
  final String? actionTaken;
  @override
  List<Object?> get props => [error, actionTaken];
}

/// The flip was aborted.
class MeridianFlipAborted extends MeridianFlipEvent {
  const MeridianFlipAborted({this.reason});
  final String? reason;
  @override
  List<Object?> get props => [reason];
}
