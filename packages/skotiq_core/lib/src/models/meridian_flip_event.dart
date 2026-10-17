import 'package:freezed_annotation/freezed_annotation.dart';
import 'backend/device_types.dart';

part 'meridian_flip_event.freezed.dart';
part 'meridian_flip_event.g.dart';

// Note: PierSide is imported from device_types.dart to avoid duplication

/// Steps in the meridian flip sequence
enum FlipStep {
  pausingGuider,
  stoppingTracking,
  slewingToTarget,
  verifyingPierSide,
  resumingTracking,
  plateSolvingAndCentering,
  refocusing,
  resumingGuider,
  settling,
}

/// Extension for FlipStep display names
extension FlipStepExtension on FlipStep {
  String get displayName {
    switch (this) {
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

/// Events emitted during meridian flip execution
@freezed
sealed class MeridianFlipEvent with _$MeridianFlipEvent {
  /// Flip is starting
  const factory MeridianFlipEvent.starting({
    required String targetName,
    required PierSide fromPierSide,
    required double hourAngle,
  }) = MeridianFlipStarting;

  /// A step has started
  const factory MeridianFlipEvent.stepStarted({
    required FlipStep step,
    required int stepIndex,
    required int totalSteps,
  }) = MeridianFlipStepStarted;

  /// A step completed successfully
  const factory MeridianFlipEvent.stepCompleted({
    required FlipStep step,
    double? durationSecs,
  }) = MeridianFlipStepCompleted;

  /// A step failed
  const factory MeridianFlipEvent.stepFailed({
    required FlipStep step,
    required String error,
  }) = MeridianFlipStepFailed;

  /// Overall progress update
  const factory MeridianFlipEvent.progress({required int percent}) =
      MeridianFlipProgress;

  /// Retry scheduled after failure
  const factory MeridianFlipEvent.retryScheduled({
    required int attempt,
    required int maxAttempts,
    required double delaySecs,
  }) = MeridianFlipRetryScheduled;

  /// Flip completed successfully
  const factory MeridianFlipEvent.completed({
    required PierSide newPierSide,
    required double durationSecs,
  }) = MeridianFlipCompleted;

  /// Flip failed after all retries
  const factory MeridianFlipEvent.failed({
    required String error,
    required String actionTaken,
  }) = MeridianFlipFailed;

  /// Flip was aborted by user
  const factory MeridianFlipEvent.aborted({required String reason}) =
      MeridianFlipAborted;

  factory MeridianFlipEvent.fromJson(Map<String, dynamic> json) =>
      _$MeridianFlipEventFromJson(json);
}
