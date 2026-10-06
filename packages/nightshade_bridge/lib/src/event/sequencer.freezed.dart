// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'sequencer.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$SequencerEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SequencerEvent()';
}


}

/// @nodoc
class $SequencerEventCopyWith<$Res>  {
$SequencerEventCopyWith(SequencerEvent _, $Res Function(SequencerEvent) __);
}


/// Adds pattern-matching-related methods to [SequencerEvent].
extension SequencerEventPatterns on SequencerEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( SequencerEvent_Started value)?  started,TResult Function( SequencerEvent_Paused value)?  paused,TResult Function( SequencerEvent_Resumed value)?  resumed,TResult Function( SequencerEvent_Stopped value)?  stopped,TResult Function( SequencerEvent_Completed value)?  completed,TResult Function( SequencerEvent_Failed value)?  failed,TResult Function( SequencerEvent_NodeStarted value)?  nodeStarted,TResult Function( SequencerEvent_NodeCompleted value)?  nodeCompleted,TResult Function( SequencerEvent_Progress value)?  progress,TResult Function( SequencerEvent_TargetChanged value)?  targetChanged,TResult Function( SequencerEvent_TargetCompleted value)?  targetCompleted,TResult Function( SequencerEvent_ExposureStarted value)?  exposureStarted,TResult Function( SequencerEvent_ExposureCompleted value)?  exposureCompleted,TResult Function( SequencerEvent_Error value)?  error,TResult Function( SequencerEvent_MeridianFlipOutcome value)?  meridianFlipOutcome,TResult Function( SequencerEvent_TriggerFired value)?  triggerFired,TResult Function( SequencerEvent_InstructionProgress value)?  instructionProgress,TResult Function( SequencerEvent_InstructionProgressStructured value)?  instructionProgressStructured,TResult Function( SequencerEvent_DepthGoalCompleted value)?  depthGoalCompleted,TResult Function( SequencerEvent_FrameAccepted value)?  frameAccepted,TResult Function( SequencerEvent_FrameRejected value)?  frameRejected,TResult Function( SequencerEvent_SchedulerDecision value)?  schedulerDecision,TResult Function( SequencerEvent_IntegrationBudget value)?  integrationBudget,TResult Function( SequencerEvent_ExposureAdjusted value)?  exposureAdjusted,TResult Function( SequencerEvent_PhotometryFrame value)?  photometryFrame,TResult Function( SequencerEvent_PhotometryCadenceBroken value)?  photometryCadenceBroken,TResult Function( SequencerEvent_PhotometrySummary value)?  photometrySummary,TResult Function( SequencerEvent_RecoveryStarted value)?  recoveryStarted,TResult Function( SequencerEvent_RecoveryProgress value)?  recoveryProgress,TResult Function( SequencerEvent_RecoveryCompleted value)?  recoveryCompleted,TResult Function( SequencerEvent_RecoveryGaveUp value)?  recoveryGaveUp,TResult Function( SequencerEvent_PluginNodeRequested value)?  pluginNodeRequested,TResult Function( SequencerEvent_PluginNodeProgress value)?  pluginNodeProgress,TResult Function( SequencerEvent_DecisionLogged value)?  decisionLogged,required TResult orElse(),}){
final _that = this;
switch (_that) {
case SequencerEvent_Started() when started != null:
return started(_that);case SequencerEvent_Paused() when paused != null:
return paused(_that);case SequencerEvent_Resumed() when resumed != null:
return resumed(_that);case SequencerEvent_Stopped() when stopped != null:
return stopped(_that);case SequencerEvent_Completed() when completed != null:
return completed(_that);case SequencerEvent_Failed() when failed != null:
return failed(_that);case SequencerEvent_NodeStarted() when nodeStarted != null:
return nodeStarted(_that);case SequencerEvent_NodeCompleted() when nodeCompleted != null:
return nodeCompleted(_that);case SequencerEvent_Progress() when progress != null:
return progress(_that);case SequencerEvent_TargetChanged() when targetChanged != null:
return targetChanged(_that);case SequencerEvent_TargetCompleted() when targetCompleted != null:
return targetCompleted(_that);case SequencerEvent_ExposureStarted() when exposureStarted != null:
return exposureStarted(_that);case SequencerEvent_ExposureCompleted() when exposureCompleted != null:
return exposureCompleted(_that);case SequencerEvent_Error() when error != null:
return error(_that);case SequencerEvent_MeridianFlipOutcome() when meridianFlipOutcome != null:
return meridianFlipOutcome(_that);case SequencerEvent_TriggerFired() when triggerFired != null:
return triggerFired(_that);case SequencerEvent_InstructionProgress() when instructionProgress != null:
return instructionProgress(_that);case SequencerEvent_InstructionProgressStructured() when instructionProgressStructured != null:
return instructionProgressStructured(_that);case SequencerEvent_DepthGoalCompleted() when depthGoalCompleted != null:
return depthGoalCompleted(_that);case SequencerEvent_FrameAccepted() when frameAccepted != null:
return frameAccepted(_that);case SequencerEvent_FrameRejected() when frameRejected != null:
return frameRejected(_that);case SequencerEvent_SchedulerDecision() when schedulerDecision != null:
return schedulerDecision(_that);case SequencerEvent_IntegrationBudget() when integrationBudget != null:
return integrationBudget(_that);case SequencerEvent_ExposureAdjusted() when exposureAdjusted != null:
return exposureAdjusted(_that);case SequencerEvent_PhotometryFrame() when photometryFrame != null:
return photometryFrame(_that);case SequencerEvent_PhotometryCadenceBroken() when photometryCadenceBroken != null:
return photometryCadenceBroken(_that);case SequencerEvent_PhotometrySummary() when photometrySummary != null:
return photometrySummary(_that);case SequencerEvent_RecoveryStarted() when recoveryStarted != null:
return recoveryStarted(_that);case SequencerEvent_RecoveryProgress() when recoveryProgress != null:
return recoveryProgress(_that);case SequencerEvent_RecoveryCompleted() when recoveryCompleted != null:
return recoveryCompleted(_that);case SequencerEvent_RecoveryGaveUp() when recoveryGaveUp != null:
return recoveryGaveUp(_that);case SequencerEvent_PluginNodeRequested() when pluginNodeRequested != null:
return pluginNodeRequested(_that);case SequencerEvent_PluginNodeProgress() when pluginNodeProgress != null:
return pluginNodeProgress(_that);case SequencerEvent_DecisionLogged() when decisionLogged != null:
return decisionLogged(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( SequencerEvent_Started value)  started,required TResult Function( SequencerEvent_Paused value)  paused,required TResult Function( SequencerEvent_Resumed value)  resumed,required TResult Function( SequencerEvent_Stopped value)  stopped,required TResult Function( SequencerEvent_Completed value)  completed,required TResult Function( SequencerEvent_Failed value)  failed,required TResult Function( SequencerEvent_NodeStarted value)  nodeStarted,required TResult Function( SequencerEvent_NodeCompleted value)  nodeCompleted,required TResult Function( SequencerEvent_Progress value)  progress,required TResult Function( SequencerEvent_TargetChanged value)  targetChanged,required TResult Function( SequencerEvent_TargetCompleted value)  targetCompleted,required TResult Function( SequencerEvent_ExposureStarted value)  exposureStarted,required TResult Function( SequencerEvent_ExposureCompleted value)  exposureCompleted,required TResult Function( SequencerEvent_Error value)  error,required TResult Function( SequencerEvent_MeridianFlipOutcome value)  meridianFlipOutcome,required TResult Function( SequencerEvent_TriggerFired value)  triggerFired,required TResult Function( SequencerEvent_InstructionProgress value)  instructionProgress,required TResult Function( SequencerEvent_InstructionProgressStructured value)  instructionProgressStructured,required TResult Function( SequencerEvent_DepthGoalCompleted value)  depthGoalCompleted,required TResult Function( SequencerEvent_FrameAccepted value)  frameAccepted,required TResult Function( SequencerEvent_FrameRejected value)  frameRejected,required TResult Function( SequencerEvent_SchedulerDecision value)  schedulerDecision,required TResult Function( SequencerEvent_IntegrationBudget value)  integrationBudget,required TResult Function( SequencerEvent_ExposureAdjusted value)  exposureAdjusted,required TResult Function( SequencerEvent_PhotometryFrame value)  photometryFrame,required TResult Function( SequencerEvent_PhotometryCadenceBroken value)  photometryCadenceBroken,required TResult Function( SequencerEvent_PhotometrySummary value)  photometrySummary,required TResult Function( SequencerEvent_RecoveryStarted value)  recoveryStarted,required TResult Function( SequencerEvent_RecoveryProgress value)  recoveryProgress,required TResult Function( SequencerEvent_RecoveryCompleted value)  recoveryCompleted,required TResult Function( SequencerEvent_RecoveryGaveUp value)  recoveryGaveUp,required TResult Function( SequencerEvent_PluginNodeRequested value)  pluginNodeRequested,required TResult Function( SequencerEvent_PluginNodeProgress value)  pluginNodeProgress,required TResult Function( SequencerEvent_DecisionLogged value)  decisionLogged,}){
final _that = this;
switch (_that) {
case SequencerEvent_Started():
return started(_that);case SequencerEvent_Paused():
return paused(_that);case SequencerEvent_Resumed():
return resumed(_that);case SequencerEvent_Stopped():
return stopped(_that);case SequencerEvent_Completed():
return completed(_that);case SequencerEvent_Failed():
return failed(_that);case SequencerEvent_NodeStarted():
return nodeStarted(_that);case SequencerEvent_NodeCompleted():
return nodeCompleted(_that);case SequencerEvent_Progress():
return progress(_that);case SequencerEvent_TargetChanged():
return targetChanged(_that);case SequencerEvent_TargetCompleted():
return targetCompleted(_that);case SequencerEvent_ExposureStarted():
return exposureStarted(_that);case SequencerEvent_ExposureCompleted():
return exposureCompleted(_that);case SequencerEvent_Error():
return error(_that);case SequencerEvent_MeridianFlipOutcome():
return meridianFlipOutcome(_that);case SequencerEvent_TriggerFired():
return triggerFired(_that);case SequencerEvent_InstructionProgress():
return instructionProgress(_that);case SequencerEvent_InstructionProgressStructured():
return instructionProgressStructured(_that);case SequencerEvent_DepthGoalCompleted():
return depthGoalCompleted(_that);case SequencerEvent_FrameAccepted():
return frameAccepted(_that);case SequencerEvent_FrameRejected():
return frameRejected(_that);case SequencerEvent_SchedulerDecision():
return schedulerDecision(_that);case SequencerEvent_IntegrationBudget():
return integrationBudget(_that);case SequencerEvent_ExposureAdjusted():
return exposureAdjusted(_that);case SequencerEvent_PhotometryFrame():
return photometryFrame(_that);case SequencerEvent_PhotometryCadenceBroken():
return photometryCadenceBroken(_that);case SequencerEvent_PhotometrySummary():
return photometrySummary(_that);case SequencerEvent_RecoveryStarted():
return recoveryStarted(_that);case SequencerEvent_RecoveryProgress():
return recoveryProgress(_that);case SequencerEvent_RecoveryCompleted():
return recoveryCompleted(_that);case SequencerEvent_RecoveryGaveUp():
return recoveryGaveUp(_that);case SequencerEvent_PluginNodeRequested():
return pluginNodeRequested(_that);case SequencerEvent_PluginNodeProgress():
return pluginNodeProgress(_that);case SequencerEvent_DecisionLogged():
return decisionLogged(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( SequencerEvent_Started value)?  started,TResult? Function( SequencerEvent_Paused value)?  paused,TResult? Function( SequencerEvent_Resumed value)?  resumed,TResult? Function( SequencerEvent_Stopped value)?  stopped,TResult? Function( SequencerEvent_Completed value)?  completed,TResult? Function( SequencerEvent_Failed value)?  failed,TResult? Function( SequencerEvent_NodeStarted value)?  nodeStarted,TResult? Function( SequencerEvent_NodeCompleted value)?  nodeCompleted,TResult? Function( SequencerEvent_Progress value)?  progress,TResult? Function( SequencerEvent_TargetChanged value)?  targetChanged,TResult? Function( SequencerEvent_TargetCompleted value)?  targetCompleted,TResult? Function( SequencerEvent_ExposureStarted value)?  exposureStarted,TResult? Function( SequencerEvent_ExposureCompleted value)?  exposureCompleted,TResult? Function( SequencerEvent_Error value)?  error,TResult? Function( SequencerEvent_MeridianFlipOutcome value)?  meridianFlipOutcome,TResult? Function( SequencerEvent_TriggerFired value)?  triggerFired,TResult? Function( SequencerEvent_InstructionProgress value)?  instructionProgress,TResult? Function( SequencerEvent_InstructionProgressStructured value)?  instructionProgressStructured,TResult? Function( SequencerEvent_DepthGoalCompleted value)?  depthGoalCompleted,TResult? Function( SequencerEvent_FrameAccepted value)?  frameAccepted,TResult? Function( SequencerEvent_FrameRejected value)?  frameRejected,TResult? Function( SequencerEvent_SchedulerDecision value)?  schedulerDecision,TResult? Function( SequencerEvent_IntegrationBudget value)?  integrationBudget,TResult? Function( SequencerEvent_ExposureAdjusted value)?  exposureAdjusted,TResult? Function( SequencerEvent_PhotometryFrame value)?  photometryFrame,TResult? Function( SequencerEvent_PhotometryCadenceBroken value)?  photometryCadenceBroken,TResult? Function( SequencerEvent_PhotometrySummary value)?  photometrySummary,TResult? Function( SequencerEvent_RecoveryStarted value)?  recoveryStarted,TResult? Function( SequencerEvent_RecoveryProgress value)?  recoveryProgress,TResult? Function( SequencerEvent_RecoveryCompleted value)?  recoveryCompleted,TResult? Function( SequencerEvent_RecoveryGaveUp value)?  recoveryGaveUp,TResult? Function( SequencerEvent_PluginNodeRequested value)?  pluginNodeRequested,TResult? Function( SequencerEvent_PluginNodeProgress value)?  pluginNodeProgress,TResult? Function( SequencerEvent_DecisionLogged value)?  decisionLogged,}){
final _that = this;
switch (_that) {
case SequencerEvent_Started() when started != null:
return started(_that);case SequencerEvent_Paused() when paused != null:
return paused(_that);case SequencerEvent_Resumed() when resumed != null:
return resumed(_that);case SequencerEvent_Stopped() when stopped != null:
return stopped(_that);case SequencerEvent_Completed() when completed != null:
return completed(_that);case SequencerEvent_Failed() when failed != null:
return failed(_that);case SequencerEvent_NodeStarted() when nodeStarted != null:
return nodeStarted(_that);case SequencerEvent_NodeCompleted() when nodeCompleted != null:
return nodeCompleted(_that);case SequencerEvent_Progress() when progress != null:
return progress(_that);case SequencerEvent_TargetChanged() when targetChanged != null:
return targetChanged(_that);case SequencerEvent_TargetCompleted() when targetCompleted != null:
return targetCompleted(_that);case SequencerEvent_ExposureStarted() when exposureStarted != null:
return exposureStarted(_that);case SequencerEvent_ExposureCompleted() when exposureCompleted != null:
return exposureCompleted(_that);case SequencerEvent_Error() when error != null:
return error(_that);case SequencerEvent_MeridianFlipOutcome() when meridianFlipOutcome != null:
return meridianFlipOutcome(_that);case SequencerEvent_TriggerFired() when triggerFired != null:
return triggerFired(_that);case SequencerEvent_InstructionProgress() when instructionProgress != null:
return instructionProgress(_that);case SequencerEvent_InstructionProgressStructured() when instructionProgressStructured != null:
return instructionProgressStructured(_that);case SequencerEvent_DepthGoalCompleted() when depthGoalCompleted != null:
return depthGoalCompleted(_that);case SequencerEvent_FrameAccepted() when frameAccepted != null:
return frameAccepted(_that);case SequencerEvent_FrameRejected() when frameRejected != null:
return frameRejected(_that);case SequencerEvent_SchedulerDecision() when schedulerDecision != null:
return schedulerDecision(_that);case SequencerEvent_IntegrationBudget() when integrationBudget != null:
return integrationBudget(_that);case SequencerEvent_ExposureAdjusted() when exposureAdjusted != null:
return exposureAdjusted(_that);case SequencerEvent_PhotometryFrame() when photometryFrame != null:
return photometryFrame(_that);case SequencerEvent_PhotometryCadenceBroken() when photometryCadenceBroken != null:
return photometryCadenceBroken(_that);case SequencerEvent_PhotometrySummary() when photometrySummary != null:
return photometrySummary(_that);case SequencerEvent_RecoveryStarted() when recoveryStarted != null:
return recoveryStarted(_that);case SequencerEvent_RecoveryProgress() when recoveryProgress != null:
return recoveryProgress(_that);case SequencerEvent_RecoveryCompleted() when recoveryCompleted != null:
return recoveryCompleted(_that);case SequencerEvent_RecoveryGaveUp() when recoveryGaveUp != null:
return recoveryGaveUp(_that);case SequencerEvent_PluginNodeRequested() when pluginNodeRequested != null:
return pluginNodeRequested(_that);case SequencerEvent_PluginNodeProgress() when pluginNodeProgress != null:
return pluginNodeProgress(_that);case SequencerEvent_DecisionLogged() when decisionLogged != null:
return decisionLogged(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String sequenceName)?  started,TResult Function()?  paused,TResult Function()?  resumed,TResult Function( PlatformInt64? sequenceRunId)?  stopped,TResult Function()?  completed,TResult Function( String error)?  failed,TResult Function( String nodeId,  String nodeType)?  nodeStarted,TResult Function( String nodeId,  String status)?  nodeCompleted,TResult Function( int current,  int total)?  progress,TResult Function( String targetName,  double? ra,  double? dec)?  targetChanged,TResult Function( String targetName)?  targetCompleted,TResult Function( int frame,  int total,  String? filter,  double durationSecs)?  exposureStarted,TResult Function( int frame,  int total,  double durationSecs)?  exposureCompleted,TResult Function( String message)?  error,TResult Function( String outcome,  String targetName,  String newPierSide,  double durationSecs,  int attempts,  List<String> failedSteps,  String? error,  String? actionTaken)?  meridianFlipOutcome,TResult Function( String triggerId,  String triggerName,  String action)?  triggerFired,TResult Function( String nodeId,  String instruction,  double progressPercent,  String detail)?  instructionProgress,TResult Function( String nodeId,  String instruction,  double progressPercent,  String detailKind,  String detailJson)?  instructionProgressStructured,TResult Function( String nodeId,  String filterName,  String goalId,  BigInt revision,  int evidenceFrames,  int confirmationFrames,  double score,  double threshold)?  depthGoalCompleted,TResult Function( String nodeId,  int frame,  int total,  double? hfr,  double? eccentricity,  int? starCount,  int acceptedTotal,  int rejectedTotal,  String? savePath,  FrameCaptureMetadata capture)?  frameAccepted,TResult Function( String nodeId,  int frame,  int total,  String reason,  double? hfr,  double? eccentricity,  int? starCount,  String rejectPath,  int consecutiveRejects,  int acceptedTotal,  int rejectedTotal,  String? likelyCauseLabel,  List<String> evidence,  double? skyBrightnessAtCapture,  double? cloudCoverAtCapture,  double? windAtCapture,  double? guideRmsAtCapture,  double? sensorTempAtCapture,  FrameCaptureMetadata capture)?  frameRejected,TResult Function( String nodeId,  int decisionCounter,  String? pickedTargetId,  String? pickedTargetName,  double? pickedScore,  List<SchedulerScoreEntry> scores)?  schedulerDecision,TResult Function( String targetId,  String filter,  double completedSecs,  double budgetSecs,  double fraction,  bool budgetMet)?  integrationBudget,TResult Function( String nodeId,  double adaptedSecs,  double nominalSecs,  double? skyBrightnessMag,  String? filter,  String reason)?  exposureAdjusted,TResult Function( String nodeId,  String targetDesignation,  List<String> referenceStars,  int frame,  int total,  String filter,  double exposureSecs,  double? airmass,  double? fwhmArcsec,  double? snr,  double mjdObs,  double frameStartUnix,  bool accepted,  String? rejectReason,  bool reduceLive,  bool applyDifferential)?  photometryFrame,TResult Function( String nodeId,  int frame,  int total,  double gapSecs,  double maxGapSecs,  int cadenceBreaks)?  photometryCadenceBroken,TResult Function( String nodeId,  String targetDesignation,  String filter,  int framesCaptured,  int cadenceBreaks,  String? lastRejectReason)?  photometrySummary,TResult Function( String startedAtIso,  String causeKind,  String? causeCustomLabel,  String? lastAttemptAtIso,  int attemptCount,  int maxAttempts,  double retryIntervalSecs,  double maxDurationSecs,  String phase,  String? lastError)?  recoveryStarted,TResult Function( String startedAtIso,  String causeKind,  String? causeCustomLabel,  String? lastAttemptAtIso,  int attemptCount,  int maxAttempts,  double retryIntervalSecs,  double maxDurationSecs,  String phase,  String? lastError)?  recoveryProgress,TResult Function( String startedAtIso,  String causeKind,  String? causeCustomLabel,  String? lastAttemptAtIso,  int attemptCount,  int maxAttempts,  double retryIntervalSecs,  double maxDurationSecs,  String phase,  String? lastError)?  recoveryCompleted,TResult Function( String startedAtIso,  String causeKind,  String? causeCustomLabel,  String? lastAttemptAtIso,  int attemptCount,  int maxAttempts,  double retryIntervalSecs,  double maxDurationSecs,  String phase,  String? lastError,  bool abortedByUser)?  recoveryGaveUp,TResult Function( String nodeId,  String pluginId,  String nodeTypeId,  String configJson,  String? displayName,  int timeoutSecs)?  pluginNodeRequested,TResult Function( String nodeId,  String pluginId,  String nodeTypeId,  String detailJson)?  pluginNodeProgress,TResult Function( String timestampIso,  String category,  String summary,  String detailsJson,  String? nodeId,  PlatformInt64? sequenceRunId)?  decisionLogged,required TResult orElse(),}) {final _that = this;
switch (_that) {
case SequencerEvent_Started() when started != null:
return started(_that.sequenceName);case SequencerEvent_Paused() when paused != null:
return paused();case SequencerEvent_Resumed() when resumed != null:
return resumed();case SequencerEvent_Stopped() when stopped != null:
return stopped(_that.sequenceRunId);case SequencerEvent_Completed() when completed != null:
return completed();case SequencerEvent_Failed() when failed != null:
return failed(_that.error);case SequencerEvent_NodeStarted() when nodeStarted != null:
return nodeStarted(_that.nodeId,_that.nodeType);case SequencerEvent_NodeCompleted() when nodeCompleted != null:
return nodeCompleted(_that.nodeId,_that.status);case SequencerEvent_Progress() when progress != null:
return progress(_that.current,_that.total);case SequencerEvent_TargetChanged() when targetChanged != null:
return targetChanged(_that.targetName,_that.ra,_that.dec);case SequencerEvent_TargetCompleted() when targetCompleted != null:
return targetCompleted(_that.targetName);case SequencerEvent_ExposureStarted() when exposureStarted != null:
return exposureStarted(_that.frame,_that.total,_that.filter,_that.durationSecs);case SequencerEvent_ExposureCompleted() when exposureCompleted != null:
return exposureCompleted(_that.frame,_that.total,_that.durationSecs);case SequencerEvent_Error() when error != null:
return error(_that.message);case SequencerEvent_MeridianFlipOutcome() when meridianFlipOutcome != null:
return meridianFlipOutcome(_that.outcome,_that.targetName,_that.newPierSide,_that.durationSecs,_that.attempts,_that.failedSteps,_that.error,_that.actionTaken);case SequencerEvent_TriggerFired() when triggerFired != null:
return triggerFired(_that.triggerId,_that.triggerName,_that.action);case SequencerEvent_InstructionProgress() when instructionProgress != null:
return instructionProgress(_that.nodeId,_that.instruction,_that.progressPercent,_that.detail);case SequencerEvent_InstructionProgressStructured() when instructionProgressStructured != null:
return instructionProgressStructured(_that.nodeId,_that.instruction,_that.progressPercent,_that.detailKind,_that.detailJson);case SequencerEvent_DepthGoalCompleted() when depthGoalCompleted != null:
return depthGoalCompleted(_that.nodeId,_that.filterName,_that.goalId,_that.revision,_that.evidenceFrames,_that.confirmationFrames,_that.score,_that.threshold);case SequencerEvent_FrameAccepted() when frameAccepted != null:
return frameAccepted(_that.nodeId,_that.frame,_that.total,_that.hfr,_that.eccentricity,_that.starCount,_that.acceptedTotal,_that.rejectedTotal,_that.savePath,_that.capture);case SequencerEvent_FrameRejected() when frameRejected != null:
return frameRejected(_that.nodeId,_that.frame,_that.total,_that.reason,_that.hfr,_that.eccentricity,_that.starCount,_that.rejectPath,_that.consecutiveRejects,_that.acceptedTotal,_that.rejectedTotal,_that.likelyCauseLabel,_that.evidence,_that.skyBrightnessAtCapture,_that.cloudCoverAtCapture,_that.windAtCapture,_that.guideRmsAtCapture,_that.sensorTempAtCapture,_that.capture);case SequencerEvent_SchedulerDecision() when schedulerDecision != null:
return schedulerDecision(_that.nodeId,_that.decisionCounter,_that.pickedTargetId,_that.pickedTargetName,_that.pickedScore,_that.scores);case SequencerEvent_IntegrationBudget() when integrationBudget != null:
return integrationBudget(_that.targetId,_that.filter,_that.completedSecs,_that.budgetSecs,_that.fraction,_that.budgetMet);case SequencerEvent_ExposureAdjusted() when exposureAdjusted != null:
return exposureAdjusted(_that.nodeId,_that.adaptedSecs,_that.nominalSecs,_that.skyBrightnessMag,_that.filter,_that.reason);case SequencerEvent_PhotometryFrame() when photometryFrame != null:
return photometryFrame(_that.nodeId,_that.targetDesignation,_that.referenceStars,_that.frame,_that.total,_that.filter,_that.exposureSecs,_that.airmass,_that.fwhmArcsec,_that.snr,_that.mjdObs,_that.frameStartUnix,_that.accepted,_that.rejectReason,_that.reduceLive,_that.applyDifferential);case SequencerEvent_PhotometryCadenceBroken() when photometryCadenceBroken != null:
return photometryCadenceBroken(_that.nodeId,_that.frame,_that.total,_that.gapSecs,_that.maxGapSecs,_that.cadenceBreaks);case SequencerEvent_PhotometrySummary() when photometrySummary != null:
return photometrySummary(_that.nodeId,_that.targetDesignation,_that.filter,_that.framesCaptured,_that.cadenceBreaks,_that.lastRejectReason);case SequencerEvent_RecoveryStarted() when recoveryStarted != null:
return recoveryStarted(_that.startedAtIso,_that.causeKind,_that.causeCustomLabel,_that.lastAttemptAtIso,_that.attemptCount,_that.maxAttempts,_that.retryIntervalSecs,_that.maxDurationSecs,_that.phase,_that.lastError);case SequencerEvent_RecoveryProgress() when recoveryProgress != null:
return recoveryProgress(_that.startedAtIso,_that.causeKind,_that.causeCustomLabel,_that.lastAttemptAtIso,_that.attemptCount,_that.maxAttempts,_that.retryIntervalSecs,_that.maxDurationSecs,_that.phase,_that.lastError);case SequencerEvent_RecoveryCompleted() when recoveryCompleted != null:
return recoveryCompleted(_that.startedAtIso,_that.causeKind,_that.causeCustomLabel,_that.lastAttemptAtIso,_that.attemptCount,_that.maxAttempts,_that.retryIntervalSecs,_that.maxDurationSecs,_that.phase,_that.lastError);case SequencerEvent_RecoveryGaveUp() when recoveryGaveUp != null:
return recoveryGaveUp(_that.startedAtIso,_that.causeKind,_that.causeCustomLabel,_that.lastAttemptAtIso,_that.attemptCount,_that.maxAttempts,_that.retryIntervalSecs,_that.maxDurationSecs,_that.phase,_that.lastError,_that.abortedByUser);case SequencerEvent_PluginNodeRequested() when pluginNodeRequested != null:
return pluginNodeRequested(_that.nodeId,_that.pluginId,_that.nodeTypeId,_that.configJson,_that.displayName,_that.timeoutSecs);case SequencerEvent_PluginNodeProgress() when pluginNodeProgress != null:
return pluginNodeProgress(_that.nodeId,_that.pluginId,_that.nodeTypeId,_that.detailJson);case SequencerEvent_DecisionLogged() when decisionLogged != null:
return decisionLogged(_that.timestampIso,_that.category,_that.summary,_that.detailsJson,_that.nodeId,_that.sequenceRunId);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String sequenceName)  started,required TResult Function()  paused,required TResult Function()  resumed,required TResult Function( PlatformInt64? sequenceRunId)  stopped,required TResult Function()  completed,required TResult Function( String error)  failed,required TResult Function( String nodeId,  String nodeType)  nodeStarted,required TResult Function( String nodeId,  String status)  nodeCompleted,required TResult Function( int current,  int total)  progress,required TResult Function( String targetName,  double? ra,  double? dec)  targetChanged,required TResult Function( String targetName)  targetCompleted,required TResult Function( int frame,  int total,  String? filter,  double durationSecs)  exposureStarted,required TResult Function( int frame,  int total,  double durationSecs)  exposureCompleted,required TResult Function( String message)  error,required TResult Function( String outcome,  String targetName,  String newPierSide,  double durationSecs,  int attempts,  List<String> failedSteps,  String? error,  String? actionTaken)  meridianFlipOutcome,required TResult Function( String triggerId,  String triggerName,  String action)  triggerFired,required TResult Function( String nodeId,  String instruction,  double progressPercent,  String detail)  instructionProgress,required TResult Function( String nodeId,  String instruction,  double progressPercent,  String detailKind,  String detailJson)  instructionProgressStructured,required TResult Function( String nodeId,  String filterName,  String goalId,  BigInt revision,  int evidenceFrames,  int confirmationFrames,  double score,  double threshold)  depthGoalCompleted,required TResult Function( String nodeId,  int frame,  int total,  double? hfr,  double? eccentricity,  int? starCount,  int acceptedTotal,  int rejectedTotal,  String? savePath,  FrameCaptureMetadata capture)  frameAccepted,required TResult Function( String nodeId,  int frame,  int total,  String reason,  double? hfr,  double? eccentricity,  int? starCount,  String rejectPath,  int consecutiveRejects,  int acceptedTotal,  int rejectedTotal,  String? likelyCauseLabel,  List<String> evidence,  double? skyBrightnessAtCapture,  double? cloudCoverAtCapture,  double? windAtCapture,  double? guideRmsAtCapture,  double? sensorTempAtCapture,  FrameCaptureMetadata capture)  frameRejected,required TResult Function( String nodeId,  int decisionCounter,  String? pickedTargetId,  String? pickedTargetName,  double? pickedScore,  List<SchedulerScoreEntry> scores)  schedulerDecision,required TResult Function( String targetId,  String filter,  double completedSecs,  double budgetSecs,  double fraction,  bool budgetMet)  integrationBudget,required TResult Function( String nodeId,  double adaptedSecs,  double nominalSecs,  double? skyBrightnessMag,  String? filter,  String reason)  exposureAdjusted,required TResult Function( String nodeId,  String targetDesignation,  List<String> referenceStars,  int frame,  int total,  String filter,  double exposureSecs,  double? airmass,  double? fwhmArcsec,  double? snr,  double mjdObs,  double frameStartUnix,  bool accepted,  String? rejectReason,  bool reduceLive,  bool applyDifferential)  photometryFrame,required TResult Function( String nodeId,  int frame,  int total,  double gapSecs,  double maxGapSecs,  int cadenceBreaks)  photometryCadenceBroken,required TResult Function( String nodeId,  String targetDesignation,  String filter,  int framesCaptured,  int cadenceBreaks,  String? lastRejectReason)  photometrySummary,required TResult Function( String startedAtIso,  String causeKind,  String? causeCustomLabel,  String? lastAttemptAtIso,  int attemptCount,  int maxAttempts,  double retryIntervalSecs,  double maxDurationSecs,  String phase,  String? lastError)  recoveryStarted,required TResult Function( String startedAtIso,  String causeKind,  String? causeCustomLabel,  String? lastAttemptAtIso,  int attemptCount,  int maxAttempts,  double retryIntervalSecs,  double maxDurationSecs,  String phase,  String? lastError)  recoveryProgress,required TResult Function( String startedAtIso,  String causeKind,  String? causeCustomLabel,  String? lastAttemptAtIso,  int attemptCount,  int maxAttempts,  double retryIntervalSecs,  double maxDurationSecs,  String phase,  String? lastError)  recoveryCompleted,required TResult Function( String startedAtIso,  String causeKind,  String? causeCustomLabel,  String? lastAttemptAtIso,  int attemptCount,  int maxAttempts,  double retryIntervalSecs,  double maxDurationSecs,  String phase,  String? lastError,  bool abortedByUser)  recoveryGaveUp,required TResult Function( String nodeId,  String pluginId,  String nodeTypeId,  String configJson,  String? displayName,  int timeoutSecs)  pluginNodeRequested,required TResult Function( String nodeId,  String pluginId,  String nodeTypeId,  String detailJson)  pluginNodeProgress,required TResult Function( String timestampIso,  String category,  String summary,  String detailsJson,  String? nodeId,  PlatformInt64? sequenceRunId)  decisionLogged,}) {final _that = this;
switch (_that) {
case SequencerEvent_Started():
return started(_that.sequenceName);case SequencerEvent_Paused():
return paused();case SequencerEvent_Resumed():
return resumed();case SequencerEvent_Stopped():
return stopped(_that.sequenceRunId);case SequencerEvent_Completed():
return completed();case SequencerEvent_Failed():
return failed(_that.error);case SequencerEvent_NodeStarted():
return nodeStarted(_that.nodeId,_that.nodeType);case SequencerEvent_NodeCompleted():
return nodeCompleted(_that.nodeId,_that.status);case SequencerEvent_Progress():
return progress(_that.current,_that.total);case SequencerEvent_TargetChanged():
return targetChanged(_that.targetName,_that.ra,_that.dec);case SequencerEvent_TargetCompleted():
return targetCompleted(_that.targetName);case SequencerEvent_ExposureStarted():
return exposureStarted(_that.frame,_that.total,_that.filter,_that.durationSecs);case SequencerEvent_ExposureCompleted():
return exposureCompleted(_that.frame,_that.total,_that.durationSecs);case SequencerEvent_Error():
return error(_that.message);case SequencerEvent_MeridianFlipOutcome():
return meridianFlipOutcome(_that.outcome,_that.targetName,_that.newPierSide,_that.durationSecs,_that.attempts,_that.failedSteps,_that.error,_that.actionTaken);case SequencerEvent_TriggerFired():
return triggerFired(_that.triggerId,_that.triggerName,_that.action);case SequencerEvent_InstructionProgress():
return instructionProgress(_that.nodeId,_that.instruction,_that.progressPercent,_that.detail);case SequencerEvent_InstructionProgressStructured():
return instructionProgressStructured(_that.nodeId,_that.instruction,_that.progressPercent,_that.detailKind,_that.detailJson);case SequencerEvent_DepthGoalCompleted():
return depthGoalCompleted(_that.nodeId,_that.filterName,_that.goalId,_that.revision,_that.evidenceFrames,_that.confirmationFrames,_that.score,_that.threshold);case SequencerEvent_FrameAccepted():
return frameAccepted(_that.nodeId,_that.frame,_that.total,_that.hfr,_that.eccentricity,_that.starCount,_that.acceptedTotal,_that.rejectedTotal,_that.savePath,_that.capture);case SequencerEvent_FrameRejected():
return frameRejected(_that.nodeId,_that.frame,_that.total,_that.reason,_that.hfr,_that.eccentricity,_that.starCount,_that.rejectPath,_that.consecutiveRejects,_that.acceptedTotal,_that.rejectedTotal,_that.likelyCauseLabel,_that.evidence,_that.skyBrightnessAtCapture,_that.cloudCoverAtCapture,_that.windAtCapture,_that.guideRmsAtCapture,_that.sensorTempAtCapture,_that.capture);case SequencerEvent_SchedulerDecision():
return schedulerDecision(_that.nodeId,_that.decisionCounter,_that.pickedTargetId,_that.pickedTargetName,_that.pickedScore,_that.scores);case SequencerEvent_IntegrationBudget():
return integrationBudget(_that.targetId,_that.filter,_that.completedSecs,_that.budgetSecs,_that.fraction,_that.budgetMet);case SequencerEvent_ExposureAdjusted():
return exposureAdjusted(_that.nodeId,_that.adaptedSecs,_that.nominalSecs,_that.skyBrightnessMag,_that.filter,_that.reason);case SequencerEvent_PhotometryFrame():
return photometryFrame(_that.nodeId,_that.targetDesignation,_that.referenceStars,_that.frame,_that.total,_that.filter,_that.exposureSecs,_that.airmass,_that.fwhmArcsec,_that.snr,_that.mjdObs,_that.frameStartUnix,_that.accepted,_that.rejectReason,_that.reduceLive,_that.applyDifferential);case SequencerEvent_PhotometryCadenceBroken():
return photometryCadenceBroken(_that.nodeId,_that.frame,_that.total,_that.gapSecs,_that.maxGapSecs,_that.cadenceBreaks);case SequencerEvent_PhotometrySummary():
return photometrySummary(_that.nodeId,_that.targetDesignation,_that.filter,_that.framesCaptured,_that.cadenceBreaks,_that.lastRejectReason);case SequencerEvent_RecoveryStarted():
return recoveryStarted(_that.startedAtIso,_that.causeKind,_that.causeCustomLabel,_that.lastAttemptAtIso,_that.attemptCount,_that.maxAttempts,_that.retryIntervalSecs,_that.maxDurationSecs,_that.phase,_that.lastError);case SequencerEvent_RecoveryProgress():
return recoveryProgress(_that.startedAtIso,_that.causeKind,_that.causeCustomLabel,_that.lastAttemptAtIso,_that.attemptCount,_that.maxAttempts,_that.retryIntervalSecs,_that.maxDurationSecs,_that.phase,_that.lastError);case SequencerEvent_RecoveryCompleted():
return recoveryCompleted(_that.startedAtIso,_that.causeKind,_that.causeCustomLabel,_that.lastAttemptAtIso,_that.attemptCount,_that.maxAttempts,_that.retryIntervalSecs,_that.maxDurationSecs,_that.phase,_that.lastError);case SequencerEvent_RecoveryGaveUp():
return recoveryGaveUp(_that.startedAtIso,_that.causeKind,_that.causeCustomLabel,_that.lastAttemptAtIso,_that.attemptCount,_that.maxAttempts,_that.retryIntervalSecs,_that.maxDurationSecs,_that.phase,_that.lastError,_that.abortedByUser);case SequencerEvent_PluginNodeRequested():
return pluginNodeRequested(_that.nodeId,_that.pluginId,_that.nodeTypeId,_that.configJson,_that.displayName,_that.timeoutSecs);case SequencerEvent_PluginNodeProgress():
return pluginNodeProgress(_that.nodeId,_that.pluginId,_that.nodeTypeId,_that.detailJson);case SequencerEvent_DecisionLogged():
return decisionLogged(_that.timestampIso,_that.category,_that.summary,_that.detailsJson,_that.nodeId,_that.sequenceRunId);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String sequenceName)?  started,TResult? Function()?  paused,TResult? Function()?  resumed,TResult? Function( PlatformInt64? sequenceRunId)?  stopped,TResult? Function()?  completed,TResult? Function( String error)?  failed,TResult? Function( String nodeId,  String nodeType)?  nodeStarted,TResult? Function( String nodeId,  String status)?  nodeCompleted,TResult? Function( int current,  int total)?  progress,TResult? Function( String targetName,  double? ra,  double? dec)?  targetChanged,TResult? Function( String targetName)?  targetCompleted,TResult? Function( int frame,  int total,  String? filter,  double durationSecs)?  exposureStarted,TResult? Function( int frame,  int total,  double durationSecs)?  exposureCompleted,TResult? Function( String message)?  error,TResult? Function( String outcome,  String targetName,  String newPierSide,  double durationSecs,  int attempts,  List<String> failedSteps,  String? error,  String? actionTaken)?  meridianFlipOutcome,TResult? Function( String triggerId,  String triggerName,  String action)?  triggerFired,TResult? Function( String nodeId,  String instruction,  double progressPercent,  String detail)?  instructionProgress,TResult? Function( String nodeId,  String instruction,  double progressPercent,  String detailKind,  String detailJson)?  instructionProgressStructured,TResult? Function( String nodeId,  String filterName,  String goalId,  BigInt revision,  int evidenceFrames,  int confirmationFrames,  double score,  double threshold)?  depthGoalCompleted,TResult? Function( String nodeId,  int frame,  int total,  double? hfr,  double? eccentricity,  int? starCount,  int acceptedTotal,  int rejectedTotal,  String? savePath,  FrameCaptureMetadata capture)?  frameAccepted,TResult? Function( String nodeId,  int frame,  int total,  String reason,  double? hfr,  double? eccentricity,  int? starCount,  String rejectPath,  int consecutiveRejects,  int acceptedTotal,  int rejectedTotal,  String? likelyCauseLabel,  List<String> evidence,  double? skyBrightnessAtCapture,  double? cloudCoverAtCapture,  double? windAtCapture,  double? guideRmsAtCapture,  double? sensorTempAtCapture,  FrameCaptureMetadata capture)?  frameRejected,TResult? Function( String nodeId,  int decisionCounter,  String? pickedTargetId,  String? pickedTargetName,  double? pickedScore,  List<SchedulerScoreEntry> scores)?  schedulerDecision,TResult? Function( String targetId,  String filter,  double completedSecs,  double budgetSecs,  double fraction,  bool budgetMet)?  integrationBudget,TResult? Function( String nodeId,  double adaptedSecs,  double nominalSecs,  double? skyBrightnessMag,  String? filter,  String reason)?  exposureAdjusted,TResult? Function( String nodeId,  String targetDesignation,  List<String> referenceStars,  int frame,  int total,  String filter,  double exposureSecs,  double? airmass,  double? fwhmArcsec,  double? snr,  double mjdObs,  double frameStartUnix,  bool accepted,  String? rejectReason,  bool reduceLive,  bool applyDifferential)?  photometryFrame,TResult? Function( String nodeId,  int frame,  int total,  double gapSecs,  double maxGapSecs,  int cadenceBreaks)?  photometryCadenceBroken,TResult? Function( String nodeId,  String targetDesignation,  String filter,  int framesCaptured,  int cadenceBreaks,  String? lastRejectReason)?  photometrySummary,TResult? Function( String startedAtIso,  String causeKind,  String? causeCustomLabel,  String? lastAttemptAtIso,  int attemptCount,  int maxAttempts,  double retryIntervalSecs,  double maxDurationSecs,  String phase,  String? lastError)?  recoveryStarted,TResult? Function( String startedAtIso,  String causeKind,  String? causeCustomLabel,  String? lastAttemptAtIso,  int attemptCount,  int maxAttempts,  double retryIntervalSecs,  double maxDurationSecs,  String phase,  String? lastError)?  recoveryProgress,TResult? Function( String startedAtIso,  String causeKind,  String? causeCustomLabel,  String? lastAttemptAtIso,  int attemptCount,  int maxAttempts,  double retryIntervalSecs,  double maxDurationSecs,  String phase,  String? lastError)?  recoveryCompleted,TResult? Function( String startedAtIso,  String causeKind,  String? causeCustomLabel,  String? lastAttemptAtIso,  int attemptCount,  int maxAttempts,  double retryIntervalSecs,  double maxDurationSecs,  String phase,  String? lastError,  bool abortedByUser)?  recoveryGaveUp,TResult? Function( String nodeId,  String pluginId,  String nodeTypeId,  String configJson,  String? displayName,  int timeoutSecs)?  pluginNodeRequested,TResult? Function( String nodeId,  String pluginId,  String nodeTypeId,  String detailJson)?  pluginNodeProgress,TResult? Function( String timestampIso,  String category,  String summary,  String detailsJson,  String? nodeId,  PlatformInt64? sequenceRunId)?  decisionLogged,}) {final _that = this;
switch (_that) {
case SequencerEvent_Started() when started != null:
return started(_that.sequenceName);case SequencerEvent_Paused() when paused != null:
return paused();case SequencerEvent_Resumed() when resumed != null:
return resumed();case SequencerEvent_Stopped() when stopped != null:
return stopped(_that.sequenceRunId);case SequencerEvent_Completed() when completed != null:
return completed();case SequencerEvent_Failed() when failed != null:
return failed(_that.error);case SequencerEvent_NodeStarted() when nodeStarted != null:
return nodeStarted(_that.nodeId,_that.nodeType);case SequencerEvent_NodeCompleted() when nodeCompleted != null:
return nodeCompleted(_that.nodeId,_that.status);case SequencerEvent_Progress() when progress != null:
return progress(_that.current,_that.total);case SequencerEvent_TargetChanged() when targetChanged != null:
return targetChanged(_that.targetName,_that.ra,_that.dec);case SequencerEvent_TargetCompleted() when targetCompleted != null:
return targetCompleted(_that.targetName);case SequencerEvent_ExposureStarted() when exposureStarted != null:
return exposureStarted(_that.frame,_that.total,_that.filter,_that.durationSecs);case SequencerEvent_ExposureCompleted() when exposureCompleted != null:
return exposureCompleted(_that.frame,_that.total,_that.durationSecs);case SequencerEvent_Error() when error != null:
return error(_that.message);case SequencerEvent_MeridianFlipOutcome() when meridianFlipOutcome != null:
return meridianFlipOutcome(_that.outcome,_that.targetName,_that.newPierSide,_that.durationSecs,_that.attempts,_that.failedSteps,_that.error,_that.actionTaken);case SequencerEvent_TriggerFired() when triggerFired != null:
return triggerFired(_that.triggerId,_that.triggerName,_that.action);case SequencerEvent_InstructionProgress() when instructionProgress != null:
return instructionProgress(_that.nodeId,_that.instruction,_that.progressPercent,_that.detail);case SequencerEvent_InstructionProgressStructured() when instructionProgressStructured != null:
return instructionProgressStructured(_that.nodeId,_that.instruction,_that.progressPercent,_that.detailKind,_that.detailJson);case SequencerEvent_DepthGoalCompleted() when depthGoalCompleted != null:
return depthGoalCompleted(_that.nodeId,_that.filterName,_that.goalId,_that.revision,_that.evidenceFrames,_that.confirmationFrames,_that.score,_that.threshold);case SequencerEvent_FrameAccepted() when frameAccepted != null:
return frameAccepted(_that.nodeId,_that.frame,_that.total,_that.hfr,_that.eccentricity,_that.starCount,_that.acceptedTotal,_that.rejectedTotal,_that.savePath,_that.capture);case SequencerEvent_FrameRejected() when frameRejected != null:
return frameRejected(_that.nodeId,_that.frame,_that.total,_that.reason,_that.hfr,_that.eccentricity,_that.starCount,_that.rejectPath,_that.consecutiveRejects,_that.acceptedTotal,_that.rejectedTotal,_that.likelyCauseLabel,_that.evidence,_that.skyBrightnessAtCapture,_that.cloudCoverAtCapture,_that.windAtCapture,_that.guideRmsAtCapture,_that.sensorTempAtCapture,_that.capture);case SequencerEvent_SchedulerDecision() when schedulerDecision != null:
return schedulerDecision(_that.nodeId,_that.decisionCounter,_that.pickedTargetId,_that.pickedTargetName,_that.pickedScore,_that.scores);case SequencerEvent_IntegrationBudget() when integrationBudget != null:
return integrationBudget(_that.targetId,_that.filter,_that.completedSecs,_that.budgetSecs,_that.fraction,_that.budgetMet);case SequencerEvent_ExposureAdjusted() when exposureAdjusted != null:
return exposureAdjusted(_that.nodeId,_that.adaptedSecs,_that.nominalSecs,_that.skyBrightnessMag,_that.filter,_that.reason);case SequencerEvent_PhotometryFrame() when photometryFrame != null:
return photometryFrame(_that.nodeId,_that.targetDesignation,_that.referenceStars,_that.frame,_that.total,_that.filter,_that.exposureSecs,_that.airmass,_that.fwhmArcsec,_that.snr,_that.mjdObs,_that.frameStartUnix,_that.accepted,_that.rejectReason,_that.reduceLive,_that.applyDifferential);case SequencerEvent_PhotometryCadenceBroken() when photometryCadenceBroken != null:
return photometryCadenceBroken(_that.nodeId,_that.frame,_that.total,_that.gapSecs,_that.maxGapSecs,_that.cadenceBreaks);case SequencerEvent_PhotometrySummary() when photometrySummary != null:
return photometrySummary(_that.nodeId,_that.targetDesignation,_that.filter,_that.framesCaptured,_that.cadenceBreaks,_that.lastRejectReason);case SequencerEvent_RecoveryStarted() when recoveryStarted != null:
return recoveryStarted(_that.startedAtIso,_that.causeKind,_that.causeCustomLabel,_that.lastAttemptAtIso,_that.attemptCount,_that.maxAttempts,_that.retryIntervalSecs,_that.maxDurationSecs,_that.phase,_that.lastError);case SequencerEvent_RecoveryProgress() when recoveryProgress != null:
return recoveryProgress(_that.startedAtIso,_that.causeKind,_that.causeCustomLabel,_that.lastAttemptAtIso,_that.attemptCount,_that.maxAttempts,_that.retryIntervalSecs,_that.maxDurationSecs,_that.phase,_that.lastError);case SequencerEvent_RecoveryCompleted() when recoveryCompleted != null:
return recoveryCompleted(_that.startedAtIso,_that.causeKind,_that.causeCustomLabel,_that.lastAttemptAtIso,_that.attemptCount,_that.maxAttempts,_that.retryIntervalSecs,_that.maxDurationSecs,_that.phase,_that.lastError);case SequencerEvent_RecoveryGaveUp() when recoveryGaveUp != null:
return recoveryGaveUp(_that.startedAtIso,_that.causeKind,_that.causeCustomLabel,_that.lastAttemptAtIso,_that.attemptCount,_that.maxAttempts,_that.retryIntervalSecs,_that.maxDurationSecs,_that.phase,_that.lastError,_that.abortedByUser);case SequencerEvent_PluginNodeRequested() when pluginNodeRequested != null:
return pluginNodeRequested(_that.nodeId,_that.pluginId,_that.nodeTypeId,_that.configJson,_that.displayName,_that.timeoutSecs);case SequencerEvent_PluginNodeProgress() when pluginNodeProgress != null:
return pluginNodeProgress(_that.nodeId,_that.pluginId,_that.nodeTypeId,_that.detailJson);case SequencerEvent_DecisionLogged() when decisionLogged != null:
return decisionLogged(_that.timestampIso,_that.category,_that.summary,_that.detailsJson,_that.nodeId,_that.sequenceRunId);case _:
  return null;

}
}

}

/// @nodoc


class SequencerEvent_Started extends SequencerEvent {
  const SequencerEvent_Started({required this.sequenceName}): super._();
  

 final  String sequenceName;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_StartedCopyWith<SequencerEvent_Started> get copyWith => _$SequencerEvent_StartedCopyWithImpl<SequencerEvent_Started>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_Started&&(identical(other.sequenceName, sequenceName) || other.sequenceName == sequenceName));
}


@override
int get hashCode => Object.hash(runtimeType,sequenceName);

@override
String toString() {
  return 'SequencerEvent.started(sequenceName: $sequenceName)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_StartedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_StartedCopyWith(SequencerEvent_Started value, $Res Function(SequencerEvent_Started) _then) = _$SequencerEvent_StartedCopyWithImpl;
@useResult
$Res call({
 String sequenceName
});




}
/// @nodoc
class _$SequencerEvent_StartedCopyWithImpl<$Res>
    implements $SequencerEvent_StartedCopyWith<$Res> {
  _$SequencerEvent_StartedCopyWithImpl(this._self, this._then);

  final SequencerEvent_Started _self;
  final $Res Function(SequencerEvent_Started) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sequenceName = null,}) {
  return _then(SequencerEvent_Started(
sequenceName: null == sequenceName ? _self.sequenceName : sequenceName // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SequencerEvent_Paused extends SequencerEvent {
  const SequencerEvent_Paused(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_Paused);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SequencerEvent.paused()';
}


}




/// @nodoc


class SequencerEvent_Resumed extends SequencerEvent {
  const SequencerEvent_Resumed(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_Resumed);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SequencerEvent.resumed()';
}


}




/// @nodoc


class SequencerEvent_Stopped extends SequencerEvent {
  const SequencerEvent_Stopped({this.sequenceRunId}): super._();
  

/// The run this terminal belongs to, when the publisher knows it.
/// Episode identity for the dashboard's stop fold: without it a
/// bare terminal and a neighbouring press are indistinguishable.
 final  PlatformInt64? sequenceRunId;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_StoppedCopyWith<SequencerEvent_Stopped> get copyWith => _$SequencerEvent_StoppedCopyWithImpl<SequencerEvent_Stopped>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_Stopped&&(identical(other.sequenceRunId, sequenceRunId) || other.sequenceRunId == sequenceRunId));
}


@override
int get hashCode => Object.hash(runtimeType,sequenceRunId);

@override
String toString() {
  return 'SequencerEvent.stopped(sequenceRunId: $sequenceRunId)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_StoppedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_StoppedCopyWith(SequencerEvent_Stopped value, $Res Function(SequencerEvent_Stopped) _then) = _$SequencerEvent_StoppedCopyWithImpl;
@useResult
$Res call({
 PlatformInt64? sequenceRunId
});




}
/// @nodoc
class _$SequencerEvent_StoppedCopyWithImpl<$Res>
    implements $SequencerEvent_StoppedCopyWith<$Res> {
  _$SequencerEvent_StoppedCopyWithImpl(this._self, this._then);

  final SequencerEvent_Stopped _self;
  final $Res Function(SequencerEvent_Stopped) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sequenceRunId = freezed,}) {
  return _then(SequencerEvent_Stopped(
sequenceRunId: freezed == sequenceRunId ? _self.sequenceRunId : sequenceRunId // ignore: cast_nullable_to_non_nullable
as PlatformInt64?,
  ));
}


}

/// @nodoc


class SequencerEvent_Completed extends SequencerEvent {
  const SequencerEvent_Completed(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_Completed);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SequencerEvent.completed()';
}


}




/// @nodoc


class SequencerEvent_Failed extends SequencerEvent {
  const SequencerEvent_Failed({required this.error}): super._();
  

 final  String error;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_FailedCopyWith<SequencerEvent_Failed> get copyWith => _$SequencerEvent_FailedCopyWithImpl<SequencerEvent_Failed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_Failed&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode => Object.hash(runtimeType,error);

@override
String toString() {
  return 'SequencerEvent.failed(error: $error)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_FailedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_FailedCopyWith(SequencerEvent_Failed value, $Res Function(SequencerEvent_Failed) _then) = _$SequencerEvent_FailedCopyWithImpl;
@useResult
$Res call({
 String error
});




}
/// @nodoc
class _$SequencerEvent_FailedCopyWithImpl<$Res>
    implements $SequencerEvent_FailedCopyWith<$Res> {
  _$SequencerEvent_FailedCopyWithImpl(this._self, this._then);

  final SequencerEvent_Failed _self;
  final $Res Function(SequencerEvent_Failed) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? error = null,}) {
  return _then(SequencerEvent_Failed(
error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SequencerEvent_NodeStarted extends SequencerEvent {
  const SequencerEvent_NodeStarted({required this.nodeId, required this.nodeType}): super._();
  

 final  String nodeId;
 final  String nodeType;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_NodeStartedCopyWith<SequencerEvent_NodeStarted> get copyWith => _$SequencerEvent_NodeStartedCopyWithImpl<SequencerEvent_NodeStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_NodeStarted&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.nodeType, nodeType) || other.nodeType == nodeType));
}


@override
int get hashCode => Object.hash(runtimeType,nodeId,nodeType);

@override
String toString() {
  return 'SequencerEvent.nodeStarted(nodeId: $nodeId, nodeType: $nodeType)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_NodeStartedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_NodeStartedCopyWith(SequencerEvent_NodeStarted value, $Res Function(SequencerEvent_NodeStarted) _then) = _$SequencerEvent_NodeStartedCopyWithImpl;
@useResult
$Res call({
 String nodeId, String nodeType
});




}
/// @nodoc
class _$SequencerEvent_NodeStartedCopyWithImpl<$Res>
    implements $SequencerEvent_NodeStartedCopyWith<$Res> {
  _$SequencerEvent_NodeStartedCopyWithImpl(this._self, this._then);

  final SequencerEvent_NodeStarted _self;
  final $Res Function(SequencerEvent_NodeStarted) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nodeId = null,Object? nodeType = null,}) {
  return _then(SequencerEvent_NodeStarted(
nodeId: null == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String,nodeType: null == nodeType ? _self.nodeType : nodeType // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SequencerEvent_NodeCompleted extends SequencerEvent {
  const SequencerEvent_NodeCompleted({required this.nodeId, required this.status}): super._();
  

 final  String nodeId;
/// Completion status: "success", "failed", "cancelled", or "skipped"
 final  String status;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_NodeCompletedCopyWith<SequencerEvent_NodeCompleted> get copyWith => _$SequencerEvent_NodeCompletedCopyWithImpl<SequencerEvent_NodeCompleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_NodeCompleted&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.status, status) || other.status == status));
}


@override
int get hashCode => Object.hash(runtimeType,nodeId,status);

@override
String toString() {
  return 'SequencerEvent.nodeCompleted(nodeId: $nodeId, status: $status)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_NodeCompletedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_NodeCompletedCopyWith(SequencerEvent_NodeCompleted value, $Res Function(SequencerEvent_NodeCompleted) _then) = _$SequencerEvent_NodeCompletedCopyWithImpl;
@useResult
$Res call({
 String nodeId, String status
});




}
/// @nodoc
class _$SequencerEvent_NodeCompletedCopyWithImpl<$Res>
    implements $SequencerEvent_NodeCompletedCopyWith<$Res> {
  _$SequencerEvent_NodeCompletedCopyWithImpl(this._self, this._then);

  final SequencerEvent_NodeCompleted _self;
  final $Res Function(SequencerEvent_NodeCompleted) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nodeId = null,Object? status = null,}) {
  return _then(SequencerEvent_NodeCompleted(
nodeId: null == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SequencerEvent_Progress extends SequencerEvent {
  const SequencerEvent_Progress({required this.current, required this.total}): super._();
  

 final  int current;
 final  int total;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_ProgressCopyWith<SequencerEvent_Progress> get copyWith => _$SequencerEvent_ProgressCopyWithImpl<SequencerEvent_Progress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_Progress&&(identical(other.current, current) || other.current == current)&&(identical(other.total, total) || other.total == total));
}


@override
int get hashCode => Object.hash(runtimeType,current,total);

@override
String toString() {
  return 'SequencerEvent.progress(current: $current, total: $total)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_ProgressCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_ProgressCopyWith(SequencerEvent_Progress value, $Res Function(SequencerEvent_Progress) _then) = _$SequencerEvent_ProgressCopyWithImpl;
@useResult
$Res call({
 int current, int total
});




}
/// @nodoc
class _$SequencerEvent_ProgressCopyWithImpl<$Res>
    implements $SequencerEvent_ProgressCopyWith<$Res> {
  _$SequencerEvent_ProgressCopyWithImpl(this._self, this._then);

  final SequencerEvent_Progress _self;
  final $Res Function(SequencerEvent_Progress) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? current = null,Object? total = null,}) {
  return _then(SequencerEvent_Progress(
current: null == current ? _self.current : current // ignore: cast_nullable_to_non_nullable
as int,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class SequencerEvent_TargetChanged extends SequencerEvent {
  const SequencerEvent_TargetChanged({required this.targetName, this.ra, this.dec}): super._();
  

 final  String targetName;
/// Right Ascension in hours (0-24), if available from the target header
 final  double? ra;
/// Declination in degrees (-90 to +90), if available from the target header
 final  double? dec;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_TargetChangedCopyWith<SequencerEvent_TargetChanged> get copyWith => _$SequencerEvent_TargetChangedCopyWithImpl<SequencerEvent_TargetChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_TargetChanged&&(identical(other.targetName, targetName) || other.targetName == targetName)&&(identical(other.ra, ra) || other.ra == ra)&&(identical(other.dec, dec) || other.dec == dec));
}


@override
int get hashCode => Object.hash(runtimeType,targetName,ra,dec);

@override
String toString() {
  return 'SequencerEvent.targetChanged(targetName: $targetName, ra: $ra, dec: $dec)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_TargetChangedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_TargetChangedCopyWith(SequencerEvent_TargetChanged value, $Res Function(SequencerEvent_TargetChanged) _then) = _$SequencerEvent_TargetChangedCopyWithImpl;
@useResult
$Res call({
 String targetName, double? ra, double? dec
});




}
/// @nodoc
class _$SequencerEvent_TargetChangedCopyWithImpl<$Res>
    implements $SequencerEvent_TargetChangedCopyWith<$Res> {
  _$SequencerEvent_TargetChangedCopyWithImpl(this._self, this._then);

  final SequencerEvent_TargetChanged _self;
  final $Res Function(SequencerEvent_TargetChanged) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? targetName = null,Object? ra = freezed,Object? dec = freezed,}) {
  return _then(SequencerEvent_TargetChanged(
targetName: null == targetName ? _self.targetName : targetName // ignore: cast_nullable_to_non_nullable
as String,ra: freezed == ra ? _self.ra : ra // ignore: cast_nullable_to_non_nullable
as double?,dec: freezed == dec ? _self.dec : dec // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}


}

/// @nodoc


class SequencerEvent_TargetCompleted extends SequencerEvent {
  const SequencerEvent_TargetCompleted({required this.targetName}): super._();
  

 final  String targetName;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_TargetCompletedCopyWith<SequencerEvent_TargetCompleted> get copyWith => _$SequencerEvent_TargetCompletedCopyWithImpl<SequencerEvent_TargetCompleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_TargetCompleted&&(identical(other.targetName, targetName) || other.targetName == targetName));
}


@override
int get hashCode => Object.hash(runtimeType,targetName);

@override
String toString() {
  return 'SequencerEvent.targetCompleted(targetName: $targetName)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_TargetCompletedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_TargetCompletedCopyWith(SequencerEvent_TargetCompleted value, $Res Function(SequencerEvent_TargetCompleted) _then) = _$SequencerEvent_TargetCompletedCopyWithImpl;
@useResult
$Res call({
 String targetName
});




}
/// @nodoc
class _$SequencerEvent_TargetCompletedCopyWithImpl<$Res>
    implements $SequencerEvent_TargetCompletedCopyWith<$Res> {
  _$SequencerEvent_TargetCompletedCopyWithImpl(this._self, this._then);

  final SequencerEvent_TargetCompleted _self;
  final $Res Function(SequencerEvent_TargetCompleted) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? targetName = null,}) {
  return _then(SequencerEvent_TargetCompleted(
targetName: null == targetName ? _self.targetName : targetName // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SequencerEvent_ExposureStarted extends SequencerEvent {
  const SequencerEvent_ExposureStarted({required this.frame, required this.total, this.filter, required this.durationSecs}): super._();
  

 final  int frame;
 final  int total;
 final  String? filter;
 final  double durationSecs;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_ExposureStartedCopyWith<SequencerEvent_ExposureStarted> get copyWith => _$SequencerEvent_ExposureStartedCopyWithImpl<SequencerEvent_ExposureStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_ExposureStarted&&(identical(other.frame, frame) || other.frame == frame)&&(identical(other.total, total) || other.total == total)&&(identical(other.filter, filter) || other.filter == filter)&&(identical(other.durationSecs, durationSecs) || other.durationSecs == durationSecs));
}


@override
int get hashCode => Object.hash(runtimeType,frame,total,filter,durationSecs);

@override
String toString() {
  return 'SequencerEvent.exposureStarted(frame: $frame, total: $total, filter: $filter, durationSecs: $durationSecs)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_ExposureStartedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_ExposureStartedCopyWith(SequencerEvent_ExposureStarted value, $Res Function(SequencerEvent_ExposureStarted) _then) = _$SequencerEvent_ExposureStartedCopyWithImpl;
@useResult
$Res call({
 int frame, int total, String? filter, double durationSecs
});




}
/// @nodoc
class _$SequencerEvent_ExposureStartedCopyWithImpl<$Res>
    implements $SequencerEvent_ExposureStartedCopyWith<$Res> {
  _$SequencerEvent_ExposureStartedCopyWithImpl(this._self, this._then);

  final SequencerEvent_ExposureStarted _self;
  final $Res Function(SequencerEvent_ExposureStarted) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? frame = null,Object? total = null,Object? filter = freezed,Object? durationSecs = null,}) {
  return _then(SequencerEvent_ExposureStarted(
frame: null == frame ? _self.frame : frame // ignore: cast_nullable_to_non_nullable
as int,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,filter: freezed == filter ? _self.filter : filter // ignore: cast_nullable_to_non_nullable
as String?,durationSecs: null == durationSecs ? _self.durationSecs : durationSecs // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class SequencerEvent_ExposureCompleted extends SequencerEvent {
  const SequencerEvent_ExposureCompleted({required this.frame, required this.total, required this.durationSecs}): super._();
  

 final  int frame;
 final  int total;
 final  double durationSecs;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_ExposureCompletedCopyWith<SequencerEvent_ExposureCompleted> get copyWith => _$SequencerEvent_ExposureCompletedCopyWithImpl<SequencerEvent_ExposureCompleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_ExposureCompleted&&(identical(other.frame, frame) || other.frame == frame)&&(identical(other.total, total) || other.total == total)&&(identical(other.durationSecs, durationSecs) || other.durationSecs == durationSecs));
}


@override
int get hashCode => Object.hash(runtimeType,frame,total,durationSecs);

@override
String toString() {
  return 'SequencerEvent.exposureCompleted(frame: $frame, total: $total, durationSecs: $durationSecs)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_ExposureCompletedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_ExposureCompletedCopyWith(SequencerEvent_ExposureCompleted value, $Res Function(SequencerEvent_ExposureCompleted) _then) = _$SequencerEvent_ExposureCompletedCopyWithImpl;
@useResult
$Res call({
 int frame, int total, double durationSecs
});




}
/// @nodoc
class _$SequencerEvent_ExposureCompletedCopyWithImpl<$Res>
    implements $SequencerEvent_ExposureCompletedCopyWith<$Res> {
  _$SequencerEvent_ExposureCompletedCopyWithImpl(this._self, this._then);

  final SequencerEvent_ExposureCompleted _self;
  final $Res Function(SequencerEvent_ExposureCompleted) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? frame = null,Object? total = null,Object? durationSecs = null,}) {
  return _then(SequencerEvent_ExposureCompleted(
frame: null == frame ? _self.frame : frame // ignore: cast_nullable_to_non_nullable
as int,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,durationSecs: null == durationSecs ? _self.durationSecs : durationSecs // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class SequencerEvent_Error extends SequencerEvent {
  const SequencerEvent_Error({required this.message}): super._();
  

 final  String message;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_ErrorCopyWith<SequencerEvent_Error> get copyWith => _$SequencerEvent_ErrorCopyWithImpl<SequencerEvent_Error>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_Error&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,message);

@override
String toString() {
  return 'SequencerEvent.error(message: $message)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_ErrorCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_ErrorCopyWith(SequencerEvent_Error value, $Res Function(SequencerEvent_Error) _then) = _$SequencerEvent_ErrorCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$SequencerEvent_ErrorCopyWithImpl<$Res>
    implements $SequencerEvent_ErrorCopyWith<$Res> {
  _$SequencerEvent_ErrorCopyWithImpl(this._self, this._then);

  final SequencerEvent_Error _self;
  final $Res Function(SequencerEvent_Error) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(SequencerEvent_Error(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SequencerEvent_MeridianFlipOutcome extends SequencerEvent {
  const SequencerEvent_MeridianFlipOutcome({required this.outcome, required this.targetName, required this.newPierSide, required this.durationSecs, required this.attempts, required final  List<String> failedSteps, this.error, this.actionTaken}): _failedSteps = failedSteps,super._();
  

/// `"success"`, `"failed"`, or `"aborted"`.
 final  String outcome;
/// Target the flip was performed for.
 final  String targetName;
/// Pier side reported after the flip (`East` / `West` / `Unknown`).
 final  String newPierSide;
/// Wall-clock seconds for the whole flip, retries included.
 final  double durationSecs;
/// Attempts made; `> 1` means the flip was DEGRADED.
 final  int attempts;
/// One `"<step>: <error>"` per failed attempt, oldest first.
 final  List<String> _failedSteps;
/// One `"<step>: <error>"` per failed attempt, oldest first.
 List<String> get failedSteps {
  if (_failedSteps is EqualUnmodifiableListView) return _failedSteps;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_failedSteps);
}

/// Terminal error. `None` on a clean success.
 final  String? error;
/// Failure action executed (`"PauseAndAlert"` / `"AbortAndPark"`).
 final  String? actionTaken;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_MeridianFlipOutcomeCopyWith<SequencerEvent_MeridianFlipOutcome> get copyWith => _$SequencerEvent_MeridianFlipOutcomeCopyWithImpl<SequencerEvent_MeridianFlipOutcome>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_MeridianFlipOutcome&&(identical(other.outcome, outcome) || other.outcome == outcome)&&(identical(other.targetName, targetName) || other.targetName == targetName)&&(identical(other.newPierSide, newPierSide) || other.newPierSide == newPierSide)&&(identical(other.durationSecs, durationSecs) || other.durationSecs == durationSecs)&&(identical(other.attempts, attempts) || other.attempts == attempts)&&const DeepCollectionEquality().equals(other._failedSteps, _failedSteps)&&(identical(other.error, error) || other.error == error)&&(identical(other.actionTaken, actionTaken) || other.actionTaken == actionTaken));
}


@override
int get hashCode => Object.hash(runtimeType,outcome,targetName,newPierSide,durationSecs,attempts,const DeepCollectionEquality().hash(_failedSteps),error,actionTaken);

@override
String toString() {
  return 'SequencerEvent.meridianFlipOutcome(outcome: $outcome, targetName: $targetName, newPierSide: $newPierSide, durationSecs: $durationSecs, attempts: $attempts, failedSteps: $failedSteps, error: $error, actionTaken: $actionTaken)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_MeridianFlipOutcomeCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_MeridianFlipOutcomeCopyWith(SequencerEvent_MeridianFlipOutcome value, $Res Function(SequencerEvent_MeridianFlipOutcome) _then) = _$SequencerEvent_MeridianFlipOutcomeCopyWithImpl;
@useResult
$Res call({
 String outcome, String targetName, String newPierSide, double durationSecs, int attempts, List<String> failedSteps, String? error, String? actionTaken
});




}
/// @nodoc
class _$SequencerEvent_MeridianFlipOutcomeCopyWithImpl<$Res>
    implements $SequencerEvent_MeridianFlipOutcomeCopyWith<$Res> {
  _$SequencerEvent_MeridianFlipOutcomeCopyWithImpl(this._self, this._then);

  final SequencerEvent_MeridianFlipOutcome _self;
  final $Res Function(SequencerEvent_MeridianFlipOutcome) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? outcome = null,Object? targetName = null,Object? newPierSide = null,Object? durationSecs = null,Object? attempts = null,Object? failedSteps = null,Object? error = freezed,Object? actionTaken = freezed,}) {
  return _then(SequencerEvent_MeridianFlipOutcome(
outcome: null == outcome ? _self.outcome : outcome // ignore: cast_nullable_to_non_nullable
as String,targetName: null == targetName ? _self.targetName : targetName // ignore: cast_nullable_to_non_nullable
as String,newPierSide: null == newPierSide ? _self.newPierSide : newPierSide // ignore: cast_nullable_to_non_nullable
as String,durationSecs: null == durationSecs ? _self.durationSecs : durationSecs // ignore: cast_nullable_to_non_nullable
as double,attempts: null == attempts ? _self.attempts : attempts // ignore: cast_nullable_to_non_nullable
as int,failedSteps: null == failedSteps ? _self._failedSteps : failedSteps // ignore: cast_nullable_to_non_nullable
as List<String>,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String?,actionTaken: freezed == actionTaken ? _self.actionTaken : actionTaken // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class SequencerEvent_TriggerFired extends SequencerEvent {
  const SequencerEvent_TriggerFired({required this.triggerId, required this.triggerName, required this.action}): super._();
  

/// Unique trigger identifier
 final  String triggerId;
/// Human-readable trigger name
 final  String triggerName;
/// Action taken (e.g., "Autofocus", "Dither", "PauseSequence")
 final  String action;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_TriggerFiredCopyWith<SequencerEvent_TriggerFired> get copyWith => _$SequencerEvent_TriggerFiredCopyWithImpl<SequencerEvent_TriggerFired>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_TriggerFired&&(identical(other.triggerId, triggerId) || other.triggerId == triggerId)&&(identical(other.triggerName, triggerName) || other.triggerName == triggerName)&&(identical(other.action, action) || other.action == action));
}


@override
int get hashCode => Object.hash(runtimeType,triggerId,triggerName,action);

@override
String toString() {
  return 'SequencerEvent.triggerFired(triggerId: $triggerId, triggerName: $triggerName, action: $action)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_TriggerFiredCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_TriggerFiredCopyWith(SequencerEvent_TriggerFired value, $Res Function(SequencerEvent_TriggerFired) _then) = _$SequencerEvent_TriggerFiredCopyWithImpl;
@useResult
$Res call({
 String triggerId, String triggerName, String action
});




}
/// @nodoc
class _$SequencerEvent_TriggerFiredCopyWithImpl<$Res>
    implements $SequencerEvent_TriggerFiredCopyWith<$Res> {
  _$SequencerEvent_TriggerFiredCopyWithImpl(this._self, this._then);

  final SequencerEvent_TriggerFired _self;
  final $Res Function(SequencerEvent_TriggerFired) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? triggerId = null,Object? triggerName = null,Object? action = null,}) {
  return _then(SequencerEvent_TriggerFired(
triggerId: null == triggerId ? _self.triggerId : triggerId // ignore: cast_nullable_to_non_nullable
as String,triggerName: null == triggerName ? _self.triggerName : triggerName // ignore: cast_nullable_to_non_nullable
as String,action: null == action ? _self.action : action // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SequencerEvent_InstructionProgress extends SequencerEvent {
  const SequencerEvent_InstructionProgress({required this.nodeId, required this.instruction, required this.progressPercent, required this.detail}): super._();
  

/// Node ID for mapping progress to the correct tree node
 final  String nodeId;
/// Name of the instruction (e.g., "Cool Camera", "Autofocus")
 final  String instruction;
/// Progress percentage (0.0 to 100.0)
 final  double progressPercent;
/// Detailed status message
 final  String detail;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_InstructionProgressCopyWith<SequencerEvent_InstructionProgress> get copyWith => _$SequencerEvent_InstructionProgressCopyWithImpl<SequencerEvent_InstructionProgress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_InstructionProgress&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.instruction, instruction) || other.instruction == instruction)&&(identical(other.progressPercent, progressPercent) || other.progressPercent == progressPercent)&&(identical(other.detail, detail) || other.detail == detail));
}


@override
int get hashCode => Object.hash(runtimeType,nodeId,instruction,progressPercent,detail);

@override
String toString() {
  return 'SequencerEvent.instructionProgress(nodeId: $nodeId, instruction: $instruction, progressPercent: $progressPercent, detail: $detail)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_InstructionProgressCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_InstructionProgressCopyWith(SequencerEvent_InstructionProgress value, $Res Function(SequencerEvent_InstructionProgress) _then) = _$SequencerEvent_InstructionProgressCopyWithImpl;
@useResult
$Res call({
 String nodeId, String instruction, double progressPercent, String detail
});




}
/// @nodoc
class _$SequencerEvent_InstructionProgressCopyWithImpl<$Res>
    implements $SequencerEvent_InstructionProgressCopyWith<$Res> {
  _$SequencerEvent_InstructionProgressCopyWithImpl(this._self, this._then);

  final SequencerEvent_InstructionProgress _self;
  final $Res Function(SequencerEvent_InstructionProgress) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nodeId = null,Object? instruction = null,Object? progressPercent = null,Object? detail = null,}) {
  return _then(SequencerEvent_InstructionProgress(
nodeId: null == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String,instruction: null == instruction ? _self.instruction : instruction // ignore: cast_nullable_to_non_nullable
as String,progressPercent: null == progressPercent ? _self.progressPercent : progressPercent // ignore: cast_nullable_to_non_nullable
as double,detail: null == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SequencerEvent_InstructionProgressStructured extends SequencerEvent {
  const SequencerEvent_InstructionProgressStructured({required this.nodeId, required this.instruction, required this.progressPercent, required this.detailKind, required this.detailJson}): super._();
  

/// Node ID for mapping progress to the correct tree node
 final  String nodeId;
/// Name of the instruction (e.g., "Cool Camera", "Autofocus")
 final  String instruction;
/// Progress percentage (0.0 to 100.0)
 final  double progressPercent;
/// `ProgressDetail` variant name (e.g. `Exposure`, `Autofocus`)
 final  String detailKind;
/// JSON-stringified inner payload for the variant.
 final  String detailJson;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_InstructionProgressStructuredCopyWith<SequencerEvent_InstructionProgressStructured> get copyWith => _$SequencerEvent_InstructionProgressStructuredCopyWithImpl<SequencerEvent_InstructionProgressStructured>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_InstructionProgressStructured&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.instruction, instruction) || other.instruction == instruction)&&(identical(other.progressPercent, progressPercent) || other.progressPercent == progressPercent)&&(identical(other.detailKind, detailKind) || other.detailKind == detailKind)&&(identical(other.detailJson, detailJson) || other.detailJson == detailJson));
}


@override
int get hashCode => Object.hash(runtimeType,nodeId,instruction,progressPercent,detailKind,detailJson);

@override
String toString() {
  return 'SequencerEvent.instructionProgressStructured(nodeId: $nodeId, instruction: $instruction, progressPercent: $progressPercent, detailKind: $detailKind, detailJson: $detailJson)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_InstructionProgressStructuredCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_InstructionProgressStructuredCopyWith(SequencerEvent_InstructionProgressStructured value, $Res Function(SequencerEvent_InstructionProgressStructured) _then) = _$SequencerEvent_InstructionProgressStructuredCopyWithImpl;
@useResult
$Res call({
 String nodeId, String instruction, double progressPercent, String detailKind, String detailJson
});




}
/// @nodoc
class _$SequencerEvent_InstructionProgressStructuredCopyWithImpl<$Res>
    implements $SequencerEvent_InstructionProgressStructuredCopyWith<$Res> {
  _$SequencerEvent_InstructionProgressStructuredCopyWithImpl(this._self, this._then);

  final SequencerEvent_InstructionProgressStructured _self;
  final $Res Function(SequencerEvent_InstructionProgressStructured) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nodeId = null,Object? instruction = null,Object? progressPercent = null,Object? detailKind = null,Object? detailJson = null,}) {
  return _then(SequencerEvent_InstructionProgressStructured(
nodeId: null == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String,instruction: null == instruction ? _self.instruction : instruction // ignore: cast_nullable_to_non_nullable
as String,progressPercent: null == progressPercent ? _self.progressPercent : progressPercent // ignore: cast_nullable_to_non_nullable
as double,detailKind: null == detailKind ? _self.detailKind : detailKind // ignore: cast_nullable_to_non_nullable
as String,detailJson: null == detailJson ? _self.detailJson : detailJson // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SequencerEvent_DepthGoalCompleted extends SequencerEvent {
  const SequencerEvent_DepthGoalCompleted({required this.nodeId, required this.filterName, required this.goalId, required this.revision, required this.evidenceFrames, required this.confirmationFrames, required this.score, required this.threshold}): super._();
  

 final  String nodeId;
 final  String filterName;
 final  String goalId;
 final  BigInt revision;
 final  int evidenceFrames;
 final  int confirmationFrames;
 final  double score;
 final  double threshold;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_DepthGoalCompletedCopyWith<SequencerEvent_DepthGoalCompleted> get copyWith => _$SequencerEvent_DepthGoalCompletedCopyWithImpl<SequencerEvent_DepthGoalCompleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_DepthGoalCompleted&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.filterName, filterName) || other.filterName == filterName)&&(identical(other.goalId, goalId) || other.goalId == goalId)&&(identical(other.revision, revision) || other.revision == revision)&&(identical(other.evidenceFrames, evidenceFrames) || other.evidenceFrames == evidenceFrames)&&(identical(other.confirmationFrames, confirmationFrames) || other.confirmationFrames == confirmationFrames)&&(identical(other.score, score) || other.score == score)&&(identical(other.threshold, threshold) || other.threshold == threshold));
}


@override
int get hashCode => Object.hash(runtimeType,nodeId,filterName,goalId,revision,evidenceFrames,confirmationFrames,score,threshold);

@override
String toString() {
  return 'SequencerEvent.depthGoalCompleted(nodeId: $nodeId, filterName: $filterName, goalId: $goalId, revision: $revision, evidenceFrames: $evidenceFrames, confirmationFrames: $confirmationFrames, score: $score, threshold: $threshold)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_DepthGoalCompletedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_DepthGoalCompletedCopyWith(SequencerEvent_DepthGoalCompleted value, $Res Function(SequencerEvent_DepthGoalCompleted) _then) = _$SequencerEvent_DepthGoalCompletedCopyWithImpl;
@useResult
$Res call({
 String nodeId, String filterName, String goalId, BigInt revision, int evidenceFrames, int confirmationFrames, double score, double threshold
});




}
/// @nodoc
class _$SequencerEvent_DepthGoalCompletedCopyWithImpl<$Res>
    implements $SequencerEvent_DepthGoalCompletedCopyWith<$Res> {
  _$SequencerEvent_DepthGoalCompletedCopyWithImpl(this._self, this._then);

  final SequencerEvent_DepthGoalCompleted _self;
  final $Res Function(SequencerEvent_DepthGoalCompleted) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nodeId = null,Object? filterName = null,Object? goalId = null,Object? revision = null,Object? evidenceFrames = null,Object? confirmationFrames = null,Object? score = null,Object? threshold = null,}) {
  return _then(SequencerEvent_DepthGoalCompleted(
nodeId: null == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String,filterName: null == filterName ? _self.filterName : filterName // ignore: cast_nullable_to_non_nullable
as String,goalId: null == goalId ? _self.goalId : goalId // ignore: cast_nullable_to_non_nullable
as String,revision: null == revision ? _self.revision : revision // ignore: cast_nullable_to_non_nullable
as BigInt,evidenceFrames: null == evidenceFrames ? _self.evidenceFrames : evidenceFrames // ignore: cast_nullable_to_non_nullable
as int,confirmationFrames: null == confirmationFrames ? _self.confirmationFrames : confirmationFrames // ignore: cast_nullable_to_non_nullable
as int,score: null == score ? _self.score : score // ignore: cast_nullable_to_non_nullable
as double,threshold: null == threshold ? _self.threshold : threshold // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class SequencerEvent_FrameAccepted extends SequencerEvent {
  const SequencerEvent_FrameAccepted({required this.nodeId, required this.frame, required this.total, this.hfr, this.eccentricity, this.starCount, required this.acceptedTotal, required this.rejectedTotal, this.savePath, required this.capture}): super._();
  

 final  String nodeId;
/// 1-based frame index within the current TakeExposure burst.
 final  int frame;
 final  int total;
 final  double? hfr;
 final  double? eccentricity;
 final  int? starCount;
/// Running count of accepted frames for the whole run.
 final  int acceptedTotal;
/// Running count of rejected frames for the whole run.
 final  int rejectedTotal;
/// on-disk save path of the accepted frame, so
/// the thumbnail strip can render an inline preview of
/// accepted frames the same way it already does for rejected
/// frames via `FrameRejected.reject_path`. `None` for legacy /
/// non-grading emit sites that did not thread the path through.
 final  String? savePath;
/// Per-frame capture truth, taken from the `FrameContext` the FITS
/// writer stamped this frame's header from. Dart persists it straight
/// into `captured_images`, which is why the row and the file agree:
/// both are written from one struct rather than two independent
/// reconstructions of the same exposure.
 final  FrameCaptureMetadata capture;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_FrameAcceptedCopyWith<SequencerEvent_FrameAccepted> get copyWith => _$SequencerEvent_FrameAcceptedCopyWithImpl<SequencerEvent_FrameAccepted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_FrameAccepted&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.frame, frame) || other.frame == frame)&&(identical(other.total, total) || other.total == total)&&(identical(other.hfr, hfr) || other.hfr == hfr)&&(identical(other.eccentricity, eccentricity) || other.eccentricity == eccentricity)&&(identical(other.starCount, starCount) || other.starCount == starCount)&&(identical(other.acceptedTotal, acceptedTotal) || other.acceptedTotal == acceptedTotal)&&(identical(other.rejectedTotal, rejectedTotal) || other.rejectedTotal == rejectedTotal)&&(identical(other.savePath, savePath) || other.savePath == savePath)&&(identical(other.capture, capture) || other.capture == capture));
}


@override
int get hashCode => Object.hash(runtimeType,nodeId,frame,total,hfr,eccentricity,starCount,acceptedTotal,rejectedTotal,savePath,capture);

@override
String toString() {
  return 'SequencerEvent.frameAccepted(nodeId: $nodeId, frame: $frame, total: $total, hfr: $hfr, eccentricity: $eccentricity, starCount: $starCount, acceptedTotal: $acceptedTotal, rejectedTotal: $rejectedTotal, savePath: $savePath, capture: $capture)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_FrameAcceptedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_FrameAcceptedCopyWith(SequencerEvent_FrameAccepted value, $Res Function(SequencerEvent_FrameAccepted) _then) = _$SequencerEvent_FrameAcceptedCopyWithImpl;
@useResult
$Res call({
 String nodeId, int frame, int total, double? hfr, double? eccentricity, int? starCount, int acceptedTotal, int rejectedTotal, String? savePath, FrameCaptureMetadata capture
});




}
/// @nodoc
class _$SequencerEvent_FrameAcceptedCopyWithImpl<$Res>
    implements $SequencerEvent_FrameAcceptedCopyWith<$Res> {
  _$SequencerEvent_FrameAcceptedCopyWithImpl(this._self, this._then);

  final SequencerEvent_FrameAccepted _self;
  final $Res Function(SequencerEvent_FrameAccepted) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nodeId = null,Object? frame = null,Object? total = null,Object? hfr = freezed,Object? eccentricity = freezed,Object? starCount = freezed,Object? acceptedTotal = null,Object? rejectedTotal = null,Object? savePath = freezed,Object? capture = null,}) {
  return _then(SequencerEvent_FrameAccepted(
nodeId: null == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String,frame: null == frame ? _self.frame : frame // ignore: cast_nullable_to_non_nullable
as int,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,hfr: freezed == hfr ? _self.hfr : hfr // ignore: cast_nullable_to_non_nullable
as double?,eccentricity: freezed == eccentricity ? _self.eccentricity : eccentricity // ignore: cast_nullable_to_non_nullable
as double?,starCount: freezed == starCount ? _self.starCount : starCount // ignore: cast_nullable_to_non_nullable
as int?,acceptedTotal: null == acceptedTotal ? _self.acceptedTotal : acceptedTotal // ignore: cast_nullable_to_non_nullable
as int,rejectedTotal: null == rejectedTotal ? _self.rejectedTotal : rejectedTotal // ignore: cast_nullable_to_non_nullable
as int,savePath: freezed == savePath ? _self.savePath : savePath // ignore: cast_nullable_to_non_nullable
as String?,capture: null == capture ? _self.capture : capture // ignore: cast_nullable_to_non_nullable
as FrameCaptureMetadata,
  ));
}


}

/// @nodoc


class SequencerEvent_FrameRejected extends SequencerEvent {
  const SequencerEvent_FrameRejected({required this.nodeId, required this.frame, required this.total, required this.reason, this.hfr, this.eccentricity, this.starCount, required this.rejectPath, required this.consecutiveRejects, required this.acceptedTotal, required this.rejectedTotal, this.likelyCauseLabel, required final  List<String> evidence, this.skyBrightnessAtCapture, this.cloudCoverAtCapture, this.windAtCapture, this.guideRmsAtCapture, this.sensorTempAtCapture, required this.capture}): _evidence = evidence,super._();
  

 final  String nodeId;
 final  int frame;
 final  int total;
 final  String reason;
 final  double? hfr;
 final  double? eccentricity;
 final  int? starCount;
 final  String rejectPath;
/// Running consecutive-rejects counter. When this reaches the
/// configured `max_consecutive_rejects`, the operator is notified
/// once for the streak; the run carries on.
 final  int consecutiveRejects;
 final  int acceptedTotal;
 final  int rejectedTotal;
/// Classified cause label (wire-stable snake_case string from
/// `LikelyCause::label()`). `None` when the classifier was not
/// consulted or could not pick a single best guess. Dart maps
/// this back to its `LikelyCause` enum via
/// `LikelyCauseExt.fromLabel`.
 final  String? likelyCauseLabel;
/// Human-readable evidence bullets the dashboard surfaces in
/// the Forensics panel and Frame Detail dialog. Empty list
/// when no telemetry was available.
 final  List<String> _evidence;
/// Human-readable evidence bullets the dashboard surfaces in
/// the Forensics panel and Frame Detail dialog. Empty list
/// when no telemetry was available.
 List<String> get evidence {
  if (_evidence is EqualUnmodifiableListView) return _evidence;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_evidence);
}

/// Sky brightness reading at capture time (mag/arcsec²).
 final  double? skyBrightnessAtCapture;
/// Cloud cover percentage (0-100) at capture time.
 final  double? cloudCoverAtCapture;
/// Wind speed at capture time (km/h). `None` when no weather
/// feed is wired through to the sequencer.
 final  double? windAtCapture;
/// Guide RMS (arc-seconds) sampled at capture time.
 final  double? guideRmsAtCapture;
/// Sensor temperature (°C) at capture time.
 final  double? sensorTempAtCapture;
/// Per-frame capture truth — see [`SequencerEvent::FrameAccepted`].
/// A rejected frame is still on disk and still gets a row, so it is
/// stamped from the same struct.
 final  FrameCaptureMetadata capture;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_FrameRejectedCopyWith<SequencerEvent_FrameRejected> get copyWith => _$SequencerEvent_FrameRejectedCopyWithImpl<SequencerEvent_FrameRejected>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_FrameRejected&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.frame, frame) || other.frame == frame)&&(identical(other.total, total) || other.total == total)&&(identical(other.reason, reason) || other.reason == reason)&&(identical(other.hfr, hfr) || other.hfr == hfr)&&(identical(other.eccentricity, eccentricity) || other.eccentricity == eccentricity)&&(identical(other.starCount, starCount) || other.starCount == starCount)&&(identical(other.rejectPath, rejectPath) || other.rejectPath == rejectPath)&&(identical(other.consecutiveRejects, consecutiveRejects) || other.consecutiveRejects == consecutiveRejects)&&(identical(other.acceptedTotal, acceptedTotal) || other.acceptedTotal == acceptedTotal)&&(identical(other.rejectedTotal, rejectedTotal) || other.rejectedTotal == rejectedTotal)&&(identical(other.likelyCauseLabel, likelyCauseLabel) || other.likelyCauseLabel == likelyCauseLabel)&&const DeepCollectionEquality().equals(other._evidence, _evidence)&&(identical(other.skyBrightnessAtCapture, skyBrightnessAtCapture) || other.skyBrightnessAtCapture == skyBrightnessAtCapture)&&(identical(other.cloudCoverAtCapture, cloudCoverAtCapture) || other.cloudCoverAtCapture == cloudCoverAtCapture)&&(identical(other.windAtCapture, windAtCapture) || other.windAtCapture == windAtCapture)&&(identical(other.guideRmsAtCapture, guideRmsAtCapture) || other.guideRmsAtCapture == guideRmsAtCapture)&&(identical(other.sensorTempAtCapture, sensorTempAtCapture) || other.sensorTempAtCapture == sensorTempAtCapture)&&(identical(other.capture, capture) || other.capture == capture));
}


@override
int get hashCode => Object.hashAll([runtimeType,nodeId,frame,total,reason,hfr,eccentricity,starCount,rejectPath,consecutiveRejects,acceptedTotal,rejectedTotal,likelyCauseLabel,const DeepCollectionEquality().hash(_evidence),skyBrightnessAtCapture,cloudCoverAtCapture,windAtCapture,guideRmsAtCapture,sensorTempAtCapture,capture]);

@override
String toString() {
  return 'SequencerEvent.frameRejected(nodeId: $nodeId, frame: $frame, total: $total, reason: $reason, hfr: $hfr, eccentricity: $eccentricity, starCount: $starCount, rejectPath: $rejectPath, consecutiveRejects: $consecutiveRejects, acceptedTotal: $acceptedTotal, rejectedTotal: $rejectedTotal, likelyCauseLabel: $likelyCauseLabel, evidence: $evidence, skyBrightnessAtCapture: $skyBrightnessAtCapture, cloudCoverAtCapture: $cloudCoverAtCapture, windAtCapture: $windAtCapture, guideRmsAtCapture: $guideRmsAtCapture, sensorTempAtCapture: $sensorTempAtCapture, capture: $capture)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_FrameRejectedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_FrameRejectedCopyWith(SequencerEvent_FrameRejected value, $Res Function(SequencerEvent_FrameRejected) _then) = _$SequencerEvent_FrameRejectedCopyWithImpl;
@useResult
$Res call({
 String nodeId, int frame, int total, String reason, double? hfr, double? eccentricity, int? starCount, String rejectPath, int consecutiveRejects, int acceptedTotal, int rejectedTotal, String? likelyCauseLabel, List<String> evidence, double? skyBrightnessAtCapture, double? cloudCoverAtCapture, double? windAtCapture, double? guideRmsAtCapture, double? sensorTempAtCapture, FrameCaptureMetadata capture
});




}
/// @nodoc
class _$SequencerEvent_FrameRejectedCopyWithImpl<$Res>
    implements $SequencerEvent_FrameRejectedCopyWith<$Res> {
  _$SequencerEvent_FrameRejectedCopyWithImpl(this._self, this._then);

  final SequencerEvent_FrameRejected _self;
  final $Res Function(SequencerEvent_FrameRejected) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nodeId = null,Object? frame = null,Object? total = null,Object? reason = null,Object? hfr = freezed,Object? eccentricity = freezed,Object? starCount = freezed,Object? rejectPath = null,Object? consecutiveRejects = null,Object? acceptedTotal = null,Object? rejectedTotal = null,Object? likelyCauseLabel = freezed,Object? evidence = null,Object? skyBrightnessAtCapture = freezed,Object? cloudCoverAtCapture = freezed,Object? windAtCapture = freezed,Object? guideRmsAtCapture = freezed,Object? sensorTempAtCapture = freezed,Object? capture = null,}) {
  return _then(SequencerEvent_FrameRejected(
nodeId: null == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String,frame: null == frame ? _self.frame : frame // ignore: cast_nullable_to_non_nullable
as int,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,hfr: freezed == hfr ? _self.hfr : hfr // ignore: cast_nullable_to_non_nullable
as double?,eccentricity: freezed == eccentricity ? _self.eccentricity : eccentricity // ignore: cast_nullable_to_non_nullable
as double?,starCount: freezed == starCount ? _self.starCount : starCount // ignore: cast_nullable_to_non_nullable
as int?,rejectPath: null == rejectPath ? _self.rejectPath : rejectPath // ignore: cast_nullable_to_non_nullable
as String,consecutiveRejects: null == consecutiveRejects ? _self.consecutiveRejects : consecutiveRejects // ignore: cast_nullable_to_non_nullable
as int,acceptedTotal: null == acceptedTotal ? _self.acceptedTotal : acceptedTotal // ignore: cast_nullable_to_non_nullable
as int,rejectedTotal: null == rejectedTotal ? _self.rejectedTotal : rejectedTotal // ignore: cast_nullable_to_non_nullable
as int,likelyCauseLabel: freezed == likelyCauseLabel ? _self.likelyCauseLabel : likelyCauseLabel // ignore: cast_nullable_to_non_nullable
as String?,evidence: null == evidence ? _self._evidence : evidence // ignore: cast_nullable_to_non_nullable
as List<String>,skyBrightnessAtCapture: freezed == skyBrightnessAtCapture ? _self.skyBrightnessAtCapture : skyBrightnessAtCapture // ignore: cast_nullable_to_non_nullable
as double?,cloudCoverAtCapture: freezed == cloudCoverAtCapture ? _self.cloudCoverAtCapture : cloudCoverAtCapture // ignore: cast_nullable_to_non_nullable
as double?,windAtCapture: freezed == windAtCapture ? _self.windAtCapture : windAtCapture // ignore: cast_nullable_to_non_nullable
as double?,guideRmsAtCapture: freezed == guideRmsAtCapture ? _self.guideRmsAtCapture : guideRmsAtCapture // ignore: cast_nullable_to_non_nullable
as double?,sensorTempAtCapture: freezed == sensorTempAtCapture ? _self.sensorTempAtCapture : sensorTempAtCapture // ignore: cast_nullable_to_non_nullable
as double?,capture: null == capture ? _self.capture : capture // ignore: cast_nullable_to_non_nullable
as FrameCaptureMetadata,
  ));
}


}

/// @nodoc


class SequencerEvent_SchedulerDecision extends SequencerEvent {
  const SequencerEvent_SchedulerDecision({required this.nodeId, required this.decisionCounter, this.pickedTargetId, this.pickedTargetName, this.pickedScore, required final  List<SchedulerScoreEntry> scores}): _scores = scores,super._();
  

 final  String nodeId;
/// 1-based decision counter for this scheduler instance.
 final  int decisionCounter;
/// `None` when no target cleared `min_score_to_run`.
 final  String? pickedTargetId;
 final  String? pickedTargetName;
/// Picked target's total score (0..=100). `None` when nothing
/// was picked.
 final  double? pickedScore;
/// Flat score table (runnable first, then by descending total).
 final  List<SchedulerScoreEntry> _scores;
/// Flat score table (runnable first, then by descending total).
 List<SchedulerScoreEntry> get scores {
  if (_scores is EqualUnmodifiableListView) return _scores;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_scores);
}


/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_SchedulerDecisionCopyWith<SequencerEvent_SchedulerDecision> get copyWith => _$SequencerEvent_SchedulerDecisionCopyWithImpl<SequencerEvent_SchedulerDecision>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_SchedulerDecision&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.decisionCounter, decisionCounter) || other.decisionCounter == decisionCounter)&&(identical(other.pickedTargetId, pickedTargetId) || other.pickedTargetId == pickedTargetId)&&(identical(other.pickedTargetName, pickedTargetName) || other.pickedTargetName == pickedTargetName)&&(identical(other.pickedScore, pickedScore) || other.pickedScore == pickedScore)&&const DeepCollectionEquality().equals(other._scores, _scores));
}


@override
int get hashCode => Object.hash(runtimeType,nodeId,decisionCounter,pickedTargetId,pickedTargetName,pickedScore,const DeepCollectionEquality().hash(_scores));

@override
String toString() {
  return 'SequencerEvent.schedulerDecision(nodeId: $nodeId, decisionCounter: $decisionCounter, pickedTargetId: $pickedTargetId, pickedTargetName: $pickedTargetName, pickedScore: $pickedScore, scores: $scores)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_SchedulerDecisionCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_SchedulerDecisionCopyWith(SequencerEvent_SchedulerDecision value, $Res Function(SequencerEvent_SchedulerDecision) _then) = _$SequencerEvent_SchedulerDecisionCopyWithImpl;
@useResult
$Res call({
 String nodeId, int decisionCounter, String? pickedTargetId, String? pickedTargetName, double? pickedScore, List<SchedulerScoreEntry> scores
});




}
/// @nodoc
class _$SequencerEvent_SchedulerDecisionCopyWithImpl<$Res>
    implements $SequencerEvent_SchedulerDecisionCopyWith<$Res> {
  _$SequencerEvent_SchedulerDecisionCopyWithImpl(this._self, this._then);

  final SequencerEvent_SchedulerDecision _self;
  final $Res Function(SequencerEvent_SchedulerDecision) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nodeId = null,Object? decisionCounter = null,Object? pickedTargetId = freezed,Object? pickedTargetName = freezed,Object? pickedScore = freezed,Object? scores = null,}) {
  return _then(SequencerEvent_SchedulerDecision(
nodeId: null == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String,decisionCounter: null == decisionCounter ? _self.decisionCounter : decisionCounter // ignore: cast_nullable_to_non_nullable
as int,pickedTargetId: freezed == pickedTargetId ? _self.pickedTargetId : pickedTargetId // ignore: cast_nullable_to_non_nullable
as String?,pickedTargetName: freezed == pickedTargetName ? _self.pickedTargetName : pickedTargetName // ignore: cast_nullable_to_non_nullable
as String?,pickedScore: freezed == pickedScore ? _self.pickedScore : pickedScore // ignore: cast_nullable_to_non_nullable
as double?,scores: null == scores ? _self._scores : scores // ignore: cast_nullable_to_non_nullable
as List<SchedulerScoreEntry>,
  ));
}


}

/// @nodoc


class SequencerEvent_IntegrationBudget extends SequencerEvent {
  const SequencerEvent_IntegrationBudget({required this.targetId, required this.filter, required this.completedSecs, required this.budgetSecs, required this.fraction, required this.budgetMet}): super._();
  

/// The TargetHeader node id this budget belongs to.
 final  String targetId;
/// Filter the credit was applied to (`""` for no-filter cameras).
 final  String filter;
 final  double completedSecs;
 final  double budgetSecs;
 final  double fraction;
 final  bool budgetMet;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_IntegrationBudgetCopyWith<SequencerEvent_IntegrationBudget> get copyWith => _$SequencerEvent_IntegrationBudgetCopyWithImpl<SequencerEvent_IntegrationBudget>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_IntegrationBudget&&(identical(other.targetId, targetId) || other.targetId == targetId)&&(identical(other.filter, filter) || other.filter == filter)&&(identical(other.completedSecs, completedSecs) || other.completedSecs == completedSecs)&&(identical(other.budgetSecs, budgetSecs) || other.budgetSecs == budgetSecs)&&(identical(other.fraction, fraction) || other.fraction == fraction)&&(identical(other.budgetMet, budgetMet) || other.budgetMet == budgetMet));
}


@override
int get hashCode => Object.hash(runtimeType,targetId,filter,completedSecs,budgetSecs,fraction,budgetMet);

@override
String toString() {
  return 'SequencerEvent.integrationBudget(targetId: $targetId, filter: $filter, completedSecs: $completedSecs, budgetSecs: $budgetSecs, fraction: $fraction, budgetMet: $budgetMet)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_IntegrationBudgetCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_IntegrationBudgetCopyWith(SequencerEvent_IntegrationBudget value, $Res Function(SequencerEvent_IntegrationBudget) _then) = _$SequencerEvent_IntegrationBudgetCopyWithImpl;
@useResult
$Res call({
 String targetId, String filter, double completedSecs, double budgetSecs, double fraction, bool budgetMet
});




}
/// @nodoc
class _$SequencerEvent_IntegrationBudgetCopyWithImpl<$Res>
    implements $SequencerEvent_IntegrationBudgetCopyWith<$Res> {
  _$SequencerEvent_IntegrationBudgetCopyWithImpl(this._self, this._then);

  final SequencerEvent_IntegrationBudget _self;
  final $Res Function(SequencerEvent_IntegrationBudget) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? targetId = null,Object? filter = null,Object? completedSecs = null,Object? budgetSecs = null,Object? fraction = null,Object? budgetMet = null,}) {
  return _then(SequencerEvent_IntegrationBudget(
targetId: null == targetId ? _self.targetId : targetId // ignore: cast_nullable_to_non_nullable
as String,filter: null == filter ? _self.filter : filter // ignore: cast_nullable_to_non_nullable
as String,completedSecs: null == completedSecs ? _self.completedSecs : completedSecs // ignore: cast_nullable_to_non_nullable
as double,budgetSecs: null == budgetSecs ? _self.budgetSecs : budgetSecs // ignore: cast_nullable_to_non_nullable
as double,fraction: null == fraction ? _self.fraction : fraction // ignore: cast_nullable_to_non_nullable
as double,budgetMet: null == budgetMet ? _self.budgetMet : budgetMet // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class SequencerEvent_ExposureAdjusted extends SequencerEvent {
  const SequencerEvent_ExposureAdjusted({required this.nodeId, required this.adaptedSecs, required this.nominalSecs, this.skyBrightnessMag, this.filter, required this.reason}): super._();
  

 final  String nodeId;
/// Adapted (effective) exposure duration in seconds.
 final  double adaptedSecs;
/// User-configured nominal duration in seconds.
 final  double nominalSecs;
/// Live sky brightness used in the decision (mag/arcsec²). `None`
/// when the adapter fell back due to missing telemetry.
 final  double? skyBrightnessMag;
/// Filter being captured through. `None` for monochrome / no
/// filter wheel rigs.
 final  String? filter;
/// Lowercase tag: `adapted`, `clamped_min`, `clamped_max`,
/// `unavailable`, `disabled`, `out_of_nominal_bounds`.
 final  String reason;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_ExposureAdjustedCopyWith<SequencerEvent_ExposureAdjusted> get copyWith => _$SequencerEvent_ExposureAdjustedCopyWithImpl<SequencerEvent_ExposureAdjusted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_ExposureAdjusted&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.adaptedSecs, adaptedSecs) || other.adaptedSecs == adaptedSecs)&&(identical(other.nominalSecs, nominalSecs) || other.nominalSecs == nominalSecs)&&(identical(other.skyBrightnessMag, skyBrightnessMag) || other.skyBrightnessMag == skyBrightnessMag)&&(identical(other.filter, filter) || other.filter == filter)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,nodeId,adaptedSecs,nominalSecs,skyBrightnessMag,filter,reason);

@override
String toString() {
  return 'SequencerEvent.exposureAdjusted(nodeId: $nodeId, adaptedSecs: $adaptedSecs, nominalSecs: $nominalSecs, skyBrightnessMag: $skyBrightnessMag, filter: $filter, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_ExposureAdjustedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_ExposureAdjustedCopyWith(SequencerEvent_ExposureAdjusted value, $Res Function(SequencerEvent_ExposureAdjusted) _then) = _$SequencerEvent_ExposureAdjustedCopyWithImpl;
@useResult
$Res call({
 String nodeId, double adaptedSecs, double nominalSecs, double? skyBrightnessMag, String? filter, String reason
});




}
/// @nodoc
class _$SequencerEvent_ExposureAdjustedCopyWithImpl<$Res>
    implements $SequencerEvent_ExposureAdjustedCopyWith<$Res> {
  _$SequencerEvent_ExposureAdjustedCopyWithImpl(this._self, this._then);

  final SequencerEvent_ExposureAdjusted _self;
  final $Res Function(SequencerEvent_ExposureAdjusted) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nodeId = null,Object? adaptedSecs = null,Object? nominalSecs = null,Object? skyBrightnessMag = freezed,Object? filter = freezed,Object? reason = null,}) {
  return _then(SequencerEvent_ExposureAdjusted(
nodeId: null == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String,adaptedSecs: null == adaptedSecs ? _self.adaptedSecs : adaptedSecs // ignore: cast_nullable_to_non_nullable
as double,nominalSecs: null == nominalSecs ? _self.nominalSecs : nominalSecs // ignore: cast_nullable_to_non_nullable
as double,skyBrightnessMag: freezed == skyBrightnessMag ? _self.skyBrightnessMag : skyBrightnessMag // ignore: cast_nullable_to_non_nullable
as double?,filter: freezed == filter ? _self.filter : filter // ignore: cast_nullable_to_non_nullable
as String?,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SequencerEvent_PhotometryFrame extends SequencerEvent {
  const SequencerEvent_PhotometryFrame({required this.nodeId, required this.targetDesignation, required final  List<String> referenceStars, required this.frame, required this.total, required this.filter, required this.exposureSecs, this.airmass, this.fwhmArcsec, this.snr, required this.mjdObs, required this.frameStartUnix, required this.accepted, this.rejectReason, required this.reduceLive, required this.applyDifferential}): _referenceStars = referenceStars,super._();
  

/// Node ID for mapping progress to the correct tree node.
 final  String nodeId;
/// Resolved target designation (e.g. `"V* DY Peg"`).
 final  String targetDesignation;
/// Reference / comparison star designations used for differential
/// photometry. Empty when differential photometry is disabled.
 final  List<String> _referenceStars;
/// Reference / comparison star designations used for differential
/// photometry. Empty when differential photometry is disabled.
 List<String> get referenceStars {
  if (_referenceStars is EqualUnmodifiableListView) return _referenceStars;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_referenceStars);
}

/// 1-based frame index within the current photometry burst.
 final  int frame;
 final  int total;
 final  String filter;
 final  double exposureSecs;
/// Airmass at exposure midpoint. `None` when no WCS / pointing was
/// available to compute it.
 final  double? airmass;
/// Measured stellar FWHM (arc-seconds). `None` when the frame yielded
/// no usable star measurement.
 final  double? fwhmArcsec;
/// Signal-to-noise ratio of the target aperture. `None` when not
/// measured.
 final  double? snr;
/// Modified Julian Date at exposure midpoint (FITS `MJD-OBS`).
 final  double mjdObs;
/// Unix epoch seconds at exposure start.
 final  double frameStartUnix;
/// True when the frame passed every quality gate
/// (`PhotometryFrameVerdict::Pass`).
 final  bool accepted;
/// Rejection reason when `accepted == false`
/// (`PhotometryFrameVerdict::Reject { reason }`); `None` when accepted.
 final  String? rejectReason;
/// True when live reduction was performed for this frame.
 final  bool reduceLive;
/// True when differential photometry was applied for this frame.
 final  bool applyDifferential;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_PhotometryFrameCopyWith<SequencerEvent_PhotometryFrame> get copyWith => _$SequencerEvent_PhotometryFrameCopyWithImpl<SequencerEvent_PhotometryFrame>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_PhotometryFrame&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.targetDesignation, targetDesignation) || other.targetDesignation == targetDesignation)&&const DeepCollectionEquality().equals(other._referenceStars, _referenceStars)&&(identical(other.frame, frame) || other.frame == frame)&&(identical(other.total, total) || other.total == total)&&(identical(other.filter, filter) || other.filter == filter)&&(identical(other.exposureSecs, exposureSecs) || other.exposureSecs == exposureSecs)&&(identical(other.airmass, airmass) || other.airmass == airmass)&&(identical(other.fwhmArcsec, fwhmArcsec) || other.fwhmArcsec == fwhmArcsec)&&(identical(other.snr, snr) || other.snr == snr)&&(identical(other.mjdObs, mjdObs) || other.mjdObs == mjdObs)&&(identical(other.frameStartUnix, frameStartUnix) || other.frameStartUnix == frameStartUnix)&&(identical(other.accepted, accepted) || other.accepted == accepted)&&(identical(other.rejectReason, rejectReason) || other.rejectReason == rejectReason)&&(identical(other.reduceLive, reduceLive) || other.reduceLive == reduceLive)&&(identical(other.applyDifferential, applyDifferential) || other.applyDifferential == applyDifferential));
}


@override
int get hashCode => Object.hash(runtimeType,nodeId,targetDesignation,const DeepCollectionEquality().hash(_referenceStars),frame,total,filter,exposureSecs,airmass,fwhmArcsec,snr,mjdObs,frameStartUnix,accepted,rejectReason,reduceLive,applyDifferential);

@override
String toString() {
  return 'SequencerEvent.photometryFrame(nodeId: $nodeId, targetDesignation: $targetDesignation, referenceStars: $referenceStars, frame: $frame, total: $total, filter: $filter, exposureSecs: $exposureSecs, airmass: $airmass, fwhmArcsec: $fwhmArcsec, snr: $snr, mjdObs: $mjdObs, frameStartUnix: $frameStartUnix, accepted: $accepted, rejectReason: $rejectReason, reduceLive: $reduceLive, applyDifferential: $applyDifferential)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_PhotometryFrameCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_PhotometryFrameCopyWith(SequencerEvent_PhotometryFrame value, $Res Function(SequencerEvent_PhotometryFrame) _then) = _$SequencerEvent_PhotometryFrameCopyWithImpl;
@useResult
$Res call({
 String nodeId, String targetDesignation, List<String> referenceStars, int frame, int total, String filter, double exposureSecs, double? airmass, double? fwhmArcsec, double? snr, double mjdObs, double frameStartUnix, bool accepted, String? rejectReason, bool reduceLive, bool applyDifferential
});




}
/// @nodoc
class _$SequencerEvent_PhotometryFrameCopyWithImpl<$Res>
    implements $SequencerEvent_PhotometryFrameCopyWith<$Res> {
  _$SequencerEvent_PhotometryFrameCopyWithImpl(this._self, this._then);

  final SequencerEvent_PhotometryFrame _self;
  final $Res Function(SequencerEvent_PhotometryFrame) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nodeId = null,Object? targetDesignation = null,Object? referenceStars = null,Object? frame = null,Object? total = null,Object? filter = null,Object? exposureSecs = null,Object? airmass = freezed,Object? fwhmArcsec = freezed,Object? snr = freezed,Object? mjdObs = null,Object? frameStartUnix = null,Object? accepted = null,Object? rejectReason = freezed,Object? reduceLive = null,Object? applyDifferential = null,}) {
  return _then(SequencerEvent_PhotometryFrame(
nodeId: null == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String,targetDesignation: null == targetDesignation ? _self.targetDesignation : targetDesignation // ignore: cast_nullable_to_non_nullable
as String,referenceStars: null == referenceStars ? _self._referenceStars : referenceStars // ignore: cast_nullable_to_non_nullable
as List<String>,frame: null == frame ? _self.frame : frame // ignore: cast_nullable_to_non_nullable
as int,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,filter: null == filter ? _self.filter : filter // ignore: cast_nullable_to_non_nullable
as String,exposureSecs: null == exposureSecs ? _self.exposureSecs : exposureSecs // ignore: cast_nullable_to_non_nullable
as double,airmass: freezed == airmass ? _self.airmass : airmass // ignore: cast_nullable_to_non_nullable
as double?,fwhmArcsec: freezed == fwhmArcsec ? _self.fwhmArcsec : fwhmArcsec // ignore: cast_nullable_to_non_nullable
as double?,snr: freezed == snr ? _self.snr : snr // ignore: cast_nullable_to_non_nullable
as double?,mjdObs: null == mjdObs ? _self.mjdObs : mjdObs // ignore: cast_nullable_to_non_nullable
as double,frameStartUnix: null == frameStartUnix ? _self.frameStartUnix : frameStartUnix // ignore: cast_nullable_to_non_nullable
as double,accepted: null == accepted ? _self.accepted : accepted // ignore: cast_nullable_to_non_nullable
as bool,rejectReason: freezed == rejectReason ? _self.rejectReason : rejectReason // ignore: cast_nullable_to_non_nullable
as String?,reduceLive: null == reduceLive ? _self.reduceLive : reduceLive // ignore: cast_nullable_to_non_nullable
as bool,applyDifferential: null == applyDifferential ? _self.applyDifferential : applyDifferential // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class SequencerEvent_PhotometryCadenceBroken extends SequencerEvent {
  const SequencerEvent_PhotometryCadenceBroken({required this.nodeId, required this.frame, required this.total, required this.gapSecs, required this.maxGapSecs, required this.cadenceBreaks}): super._();
  

/// Node ID for mapping progress to the correct tree node.
 final  String nodeId;
/// 1-based frame index whose start broke the cadence.
 final  int frame;
 final  int total;
/// Observed start-to-start gap (seconds).
 final  double gapSecs;
/// Configured maximum allowed gap (seconds).
 final  double maxGapSecs;
/// Cumulative cadence breaks for the current node run.
 final  int cadenceBreaks;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_PhotometryCadenceBrokenCopyWith<SequencerEvent_PhotometryCadenceBroken> get copyWith => _$SequencerEvent_PhotometryCadenceBrokenCopyWithImpl<SequencerEvent_PhotometryCadenceBroken>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_PhotometryCadenceBroken&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.frame, frame) || other.frame == frame)&&(identical(other.total, total) || other.total == total)&&(identical(other.gapSecs, gapSecs) || other.gapSecs == gapSecs)&&(identical(other.maxGapSecs, maxGapSecs) || other.maxGapSecs == maxGapSecs)&&(identical(other.cadenceBreaks, cadenceBreaks) || other.cadenceBreaks == cadenceBreaks));
}


@override
int get hashCode => Object.hash(runtimeType,nodeId,frame,total,gapSecs,maxGapSecs,cadenceBreaks);

@override
String toString() {
  return 'SequencerEvent.photometryCadenceBroken(nodeId: $nodeId, frame: $frame, total: $total, gapSecs: $gapSecs, maxGapSecs: $maxGapSecs, cadenceBreaks: $cadenceBreaks)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_PhotometryCadenceBrokenCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_PhotometryCadenceBrokenCopyWith(SequencerEvent_PhotometryCadenceBroken value, $Res Function(SequencerEvent_PhotometryCadenceBroken) _then) = _$SequencerEvent_PhotometryCadenceBrokenCopyWithImpl;
@useResult
$Res call({
 String nodeId, int frame, int total, double gapSecs, double maxGapSecs, int cadenceBreaks
});




}
/// @nodoc
class _$SequencerEvent_PhotometryCadenceBrokenCopyWithImpl<$Res>
    implements $SequencerEvent_PhotometryCadenceBrokenCopyWith<$Res> {
  _$SequencerEvent_PhotometryCadenceBrokenCopyWithImpl(this._self, this._then);

  final SequencerEvent_PhotometryCadenceBroken _self;
  final $Res Function(SequencerEvent_PhotometryCadenceBroken) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nodeId = null,Object? frame = null,Object? total = null,Object? gapSecs = null,Object? maxGapSecs = null,Object? cadenceBreaks = null,}) {
  return _then(SequencerEvent_PhotometryCadenceBroken(
nodeId: null == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String,frame: null == frame ? _self.frame : frame // ignore: cast_nullable_to_non_nullable
as int,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,gapSecs: null == gapSecs ? _self.gapSecs : gapSecs // ignore: cast_nullable_to_non_nullable
as double,maxGapSecs: null == maxGapSecs ? _self.maxGapSecs : maxGapSecs // ignore: cast_nullable_to_non_nullable
as double,cadenceBreaks: null == cadenceBreaks ? _self.cadenceBreaks : cadenceBreaks // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class SequencerEvent_PhotometrySummary extends SequencerEvent {
  const SequencerEvent_PhotometrySummary({required this.nodeId, required this.targetDesignation, required this.filter, required this.framesCaptured, required this.cadenceBreaks, this.lastRejectReason}): super._();
  

/// Node ID for mapping progress to the correct tree node.
 final  String nodeId;
 final  String targetDesignation;
 final  String filter;
/// Number of frames captured during the burst (accepted + rejected).
 final  int framesCaptured;
/// Total cadence breaks observed during the burst.
 final  int cadenceBreaks;
/// Last rejection reason seen during the burst; `None` when no frame
/// was rejected.
 final  String? lastRejectReason;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_PhotometrySummaryCopyWith<SequencerEvent_PhotometrySummary> get copyWith => _$SequencerEvent_PhotometrySummaryCopyWithImpl<SequencerEvent_PhotometrySummary>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_PhotometrySummary&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.targetDesignation, targetDesignation) || other.targetDesignation == targetDesignation)&&(identical(other.filter, filter) || other.filter == filter)&&(identical(other.framesCaptured, framesCaptured) || other.framesCaptured == framesCaptured)&&(identical(other.cadenceBreaks, cadenceBreaks) || other.cadenceBreaks == cadenceBreaks)&&(identical(other.lastRejectReason, lastRejectReason) || other.lastRejectReason == lastRejectReason));
}


@override
int get hashCode => Object.hash(runtimeType,nodeId,targetDesignation,filter,framesCaptured,cadenceBreaks,lastRejectReason);

@override
String toString() {
  return 'SequencerEvent.photometrySummary(nodeId: $nodeId, targetDesignation: $targetDesignation, filter: $filter, framesCaptured: $framesCaptured, cadenceBreaks: $cadenceBreaks, lastRejectReason: $lastRejectReason)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_PhotometrySummaryCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_PhotometrySummaryCopyWith(SequencerEvent_PhotometrySummary value, $Res Function(SequencerEvent_PhotometrySummary) _then) = _$SequencerEvent_PhotometrySummaryCopyWithImpl;
@useResult
$Res call({
 String nodeId, String targetDesignation, String filter, int framesCaptured, int cadenceBreaks, String? lastRejectReason
});




}
/// @nodoc
class _$SequencerEvent_PhotometrySummaryCopyWithImpl<$Res>
    implements $SequencerEvent_PhotometrySummaryCopyWith<$Res> {
  _$SequencerEvent_PhotometrySummaryCopyWithImpl(this._self, this._then);

  final SequencerEvent_PhotometrySummary _self;
  final $Res Function(SequencerEvent_PhotometrySummary) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nodeId = null,Object? targetDesignation = null,Object? filter = null,Object? framesCaptured = null,Object? cadenceBreaks = null,Object? lastRejectReason = freezed,}) {
  return _then(SequencerEvent_PhotometrySummary(
nodeId: null == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String,targetDesignation: null == targetDesignation ? _self.targetDesignation : targetDesignation // ignore: cast_nullable_to_non_nullable
as String,filter: null == filter ? _self.filter : filter // ignore: cast_nullable_to_non_nullable
as String,framesCaptured: null == framesCaptured ? _self.framesCaptured : framesCaptured // ignore: cast_nullable_to_non_nullable
as int,cadenceBreaks: null == cadenceBreaks ? _self.cadenceBreaks : cadenceBreaks // ignore: cast_nullable_to_non_nullable
as int,lastRejectReason: freezed == lastRejectReason ? _self.lastRejectReason : lastRejectReason // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class SequencerEvent_RecoveryStarted extends SequencerEvent {
  const SequencerEvent_RecoveryStarted({required this.startedAtIso, required this.causeKind, this.causeCustomLabel, this.lastAttemptAtIso, required this.attemptCount, required this.maxAttempts, required this.retryIntervalSecs, required this.maxDurationSecs, required this.phase, this.lastError}): super._();
  

 final  String startedAtIso;
 final  String causeKind;
 final  String? causeCustomLabel;
 final  String? lastAttemptAtIso;
 final  int attemptCount;
 final  int maxAttempts;
 final  double retryIntervalSecs;
 final  double maxDurationSecs;
 final  String phase;
 final  String? lastError;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_RecoveryStartedCopyWith<SequencerEvent_RecoveryStarted> get copyWith => _$SequencerEvent_RecoveryStartedCopyWithImpl<SequencerEvent_RecoveryStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_RecoveryStarted&&(identical(other.startedAtIso, startedAtIso) || other.startedAtIso == startedAtIso)&&(identical(other.causeKind, causeKind) || other.causeKind == causeKind)&&(identical(other.causeCustomLabel, causeCustomLabel) || other.causeCustomLabel == causeCustomLabel)&&(identical(other.lastAttemptAtIso, lastAttemptAtIso) || other.lastAttemptAtIso == lastAttemptAtIso)&&(identical(other.attemptCount, attemptCount) || other.attemptCount == attemptCount)&&(identical(other.maxAttempts, maxAttempts) || other.maxAttempts == maxAttempts)&&(identical(other.retryIntervalSecs, retryIntervalSecs) || other.retryIntervalSecs == retryIntervalSecs)&&(identical(other.maxDurationSecs, maxDurationSecs) || other.maxDurationSecs == maxDurationSecs)&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.lastError, lastError) || other.lastError == lastError));
}


@override
int get hashCode => Object.hash(runtimeType,startedAtIso,causeKind,causeCustomLabel,lastAttemptAtIso,attemptCount,maxAttempts,retryIntervalSecs,maxDurationSecs,phase,lastError);

@override
String toString() {
  return 'SequencerEvent.recoveryStarted(startedAtIso: $startedAtIso, causeKind: $causeKind, causeCustomLabel: $causeCustomLabel, lastAttemptAtIso: $lastAttemptAtIso, attemptCount: $attemptCount, maxAttempts: $maxAttempts, retryIntervalSecs: $retryIntervalSecs, maxDurationSecs: $maxDurationSecs, phase: $phase, lastError: $lastError)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_RecoveryStartedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_RecoveryStartedCopyWith(SequencerEvent_RecoveryStarted value, $Res Function(SequencerEvent_RecoveryStarted) _then) = _$SequencerEvent_RecoveryStartedCopyWithImpl;
@useResult
$Res call({
 String startedAtIso, String causeKind, String? causeCustomLabel, String? lastAttemptAtIso, int attemptCount, int maxAttempts, double retryIntervalSecs, double maxDurationSecs, String phase, String? lastError
});




}
/// @nodoc
class _$SequencerEvent_RecoveryStartedCopyWithImpl<$Res>
    implements $SequencerEvent_RecoveryStartedCopyWith<$Res> {
  _$SequencerEvent_RecoveryStartedCopyWithImpl(this._self, this._then);

  final SequencerEvent_RecoveryStarted _self;
  final $Res Function(SequencerEvent_RecoveryStarted) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? startedAtIso = null,Object? causeKind = null,Object? causeCustomLabel = freezed,Object? lastAttemptAtIso = freezed,Object? attemptCount = null,Object? maxAttempts = null,Object? retryIntervalSecs = null,Object? maxDurationSecs = null,Object? phase = null,Object? lastError = freezed,}) {
  return _then(SequencerEvent_RecoveryStarted(
startedAtIso: null == startedAtIso ? _self.startedAtIso : startedAtIso // ignore: cast_nullable_to_non_nullable
as String,causeKind: null == causeKind ? _self.causeKind : causeKind // ignore: cast_nullable_to_non_nullable
as String,causeCustomLabel: freezed == causeCustomLabel ? _self.causeCustomLabel : causeCustomLabel // ignore: cast_nullable_to_non_nullable
as String?,lastAttemptAtIso: freezed == lastAttemptAtIso ? _self.lastAttemptAtIso : lastAttemptAtIso // ignore: cast_nullable_to_non_nullable
as String?,attemptCount: null == attemptCount ? _self.attemptCount : attemptCount // ignore: cast_nullable_to_non_nullable
as int,maxAttempts: null == maxAttempts ? _self.maxAttempts : maxAttempts // ignore: cast_nullable_to_non_nullable
as int,retryIntervalSecs: null == retryIntervalSecs ? _self.retryIntervalSecs : retryIntervalSecs // ignore: cast_nullable_to_non_nullable
as double,maxDurationSecs: null == maxDurationSecs ? _self.maxDurationSecs : maxDurationSecs // ignore: cast_nullable_to_non_nullable
as double,phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as String,lastError: freezed == lastError ? _self.lastError : lastError // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class SequencerEvent_RecoveryProgress extends SequencerEvent {
  const SequencerEvent_RecoveryProgress({required this.startedAtIso, required this.causeKind, this.causeCustomLabel, this.lastAttemptAtIso, required this.attemptCount, required this.maxAttempts, required this.retryIntervalSecs, required this.maxDurationSecs, required this.phase, this.lastError}): super._();
  

 final  String startedAtIso;
 final  String causeKind;
 final  String? causeCustomLabel;
 final  String? lastAttemptAtIso;
 final  int attemptCount;
 final  int maxAttempts;
 final  double retryIntervalSecs;
 final  double maxDurationSecs;
 final  String phase;
 final  String? lastError;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_RecoveryProgressCopyWith<SequencerEvent_RecoveryProgress> get copyWith => _$SequencerEvent_RecoveryProgressCopyWithImpl<SequencerEvent_RecoveryProgress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_RecoveryProgress&&(identical(other.startedAtIso, startedAtIso) || other.startedAtIso == startedAtIso)&&(identical(other.causeKind, causeKind) || other.causeKind == causeKind)&&(identical(other.causeCustomLabel, causeCustomLabel) || other.causeCustomLabel == causeCustomLabel)&&(identical(other.lastAttemptAtIso, lastAttemptAtIso) || other.lastAttemptAtIso == lastAttemptAtIso)&&(identical(other.attemptCount, attemptCount) || other.attemptCount == attemptCount)&&(identical(other.maxAttempts, maxAttempts) || other.maxAttempts == maxAttempts)&&(identical(other.retryIntervalSecs, retryIntervalSecs) || other.retryIntervalSecs == retryIntervalSecs)&&(identical(other.maxDurationSecs, maxDurationSecs) || other.maxDurationSecs == maxDurationSecs)&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.lastError, lastError) || other.lastError == lastError));
}


@override
int get hashCode => Object.hash(runtimeType,startedAtIso,causeKind,causeCustomLabel,lastAttemptAtIso,attemptCount,maxAttempts,retryIntervalSecs,maxDurationSecs,phase,lastError);

@override
String toString() {
  return 'SequencerEvent.recoveryProgress(startedAtIso: $startedAtIso, causeKind: $causeKind, causeCustomLabel: $causeCustomLabel, lastAttemptAtIso: $lastAttemptAtIso, attemptCount: $attemptCount, maxAttempts: $maxAttempts, retryIntervalSecs: $retryIntervalSecs, maxDurationSecs: $maxDurationSecs, phase: $phase, lastError: $lastError)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_RecoveryProgressCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_RecoveryProgressCopyWith(SequencerEvent_RecoveryProgress value, $Res Function(SequencerEvent_RecoveryProgress) _then) = _$SequencerEvent_RecoveryProgressCopyWithImpl;
@useResult
$Res call({
 String startedAtIso, String causeKind, String? causeCustomLabel, String? lastAttemptAtIso, int attemptCount, int maxAttempts, double retryIntervalSecs, double maxDurationSecs, String phase, String? lastError
});




}
/// @nodoc
class _$SequencerEvent_RecoveryProgressCopyWithImpl<$Res>
    implements $SequencerEvent_RecoveryProgressCopyWith<$Res> {
  _$SequencerEvent_RecoveryProgressCopyWithImpl(this._self, this._then);

  final SequencerEvent_RecoveryProgress _self;
  final $Res Function(SequencerEvent_RecoveryProgress) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? startedAtIso = null,Object? causeKind = null,Object? causeCustomLabel = freezed,Object? lastAttemptAtIso = freezed,Object? attemptCount = null,Object? maxAttempts = null,Object? retryIntervalSecs = null,Object? maxDurationSecs = null,Object? phase = null,Object? lastError = freezed,}) {
  return _then(SequencerEvent_RecoveryProgress(
startedAtIso: null == startedAtIso ? _self.startedAtIso : startedAtIso // ignore: cast_nullable_to_non_nullable
as String,causeKind: null == causeKind ? _self.causeKind : causeKind // ignore: cast_nullable_to_non_nullable
as String,causeCustomLabel: freezed == causeCustomLabel ? _self.causeCustomLabel : causeCustomLabel // ignore: cast_nullable_to_non_nullable
as String?,lastAttemptAtIso: freezed == lastAttemptAtIso ? _self.lastAttemptAtIso : lastAttemptAtIso // ignore: cast_nullable_to_non_nullable
as String?,attemptCount: null == attemptCount ? _self.attemptCount : attemptCount // ignore: cast_nullable_to_non_nullable
as int,maxAttempts: null == maxAttempts ? _self.maxAttempts : maxAttempts // ignore: cast_nullable_to_non_nullable
as int,retryIntervalSecs: null == retryIntervalSecs ? _self.retryIntervalSecs : retryIntervalSecs // ignore: cast_nullable_to_non_nullable
as double,maxDurationSecs: null == maxDurationSecs ? _self.maxDurationSecs : maxDurationSecs // ignore: cast_nullable_to_non_nullable
as double,phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as String,lastError: freezed == lastError ? _self.lastError : lastError // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class SequencerEvent_RecoveryCompleted extends SequencerEvent {
  const SequencerEvent_RecoveryCompleted({required this.startedAtIso, required this.causeKind, this.causeCustomLabel, this.lastAttemptAtIso, required this.attemptCount, required this.maxAttempts, required this.retryIntervalSecs, required this.maxDurationSecs, required this.phase, this.lastError}): super._();
  

 final  String startedAtIso;
 final  String causeKind;
 final  String? causeCustomLabel;
 final  String? lastAttemptAtIso;
 final  int attemptCount;
 final  int maxAttempts;
 final  double retryIntervalSecs;
 final  double maxDurationSecs;
 final  String phase;
 final  String? lastError;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_RecoveryCompletedCopyWith<SequencerEvent_RecoveryCompleted> get copyWith => _$SequencerEvent_RecoveryCompletedCopyWithImpl<SequencerEvent_RecoveryCompleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_RecoveryCompleted&&(identical(other.startedAtIso, startedAtIso) || other.startedAtIso == startedAtIso)&&(identical(other.causeKind, causeKind) || other.causeKind == causeKind)&&(identical(other.causeCustomLabel, causeCustomLabel) || other.causeCustomLabel == causeCustomLabel)&&(identical(other.lastAttemptAtIso, lastAttemptAtIso) || other.lastAttemptAtIso == lastAttemptAtIso)&&(identical(other.attemptCount, attemptCount) || other.attemptCount == attemptCount)&&(identical(other.maxAttempts, maxAttempts) || other.maxAttempts == maxAttempts)&&(identical(other.retryIntervalSecs, retryIntervalSecs) || other.retryIntervalSecs == retryIntervalSecs)&&(identical(other.maxDurationSecs, maxDurationSecs) || other.maxDurationSecs == maxDurationSecs)&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.lastError, lastError) || other.lastError == lastError));
}


@override
int get hashCode => Object.hash(runtimeType,startedAtIso,causeKind,causeCustomLabel,lastAttemptAtIso,attemptCount,maxAttempts,retryIntervalSecs,maxDurationSecs,phase,lastError);

@override
String toString() {
  return 'SequencerEvent.recoveryCompleted(startedAtIso: $startedAtIso, causeKind: $causeKind, causeCustomLabel: $causeCustomLabel, lastAttemptAtIso: $lastAttemptAtIso, attemptCount: $attemptCount, maxAttempts: $maxAttempts, retryIntervalSecs: $retryIntervalSecs, maxDurationSecs: $maxDurationSecs, phase: $phase, lastError: $lastError)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_RecoveryCompletedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_RecoveryCompletedCopyWith(SequencerEvent_RecoveryCompleted value, $Res Function(SequencerEvent_RecoveryCompleted) _then) = _$SequencerEvent_RecoveryCompletedCopyWithImpl;
@useResult
$Res call({
 String startedAtIso, String causeKind, String? causeCustomLabel, String? lastAttemptAtIso, int attemptCount, int maxAttempts, double retryIntervalSecs, double maxDurationSecs, String phase, String? lastError
});




}
/// @nodoc
class _$SequencerEvent_RecoveryCompletedCopyWithImpl<$Res>
    implements $SequencerEvent_RecoveryCompletedCopyWith<$Res> {
  _$SequencerEvent_RecoveryCompletedCopyWithImpl(this._self, this._then);

  final SequencerEvent_RecoveryCompleted _self;
  final $Res Function(SequencerEvent_RecoveryCompleted) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? startedAtIso = null,Object? causeKind = null,Object? causeCustomLabel = freezed,Object? lastAttemptAtIso = freezed,Object? attemptCount = null,Object? maxAttempts = null,Object? retryIntervalSecs = null,Object? maxDurationSecs = null,Object? phase = null,Object? lastError = freezed,}) {
  return _then(SequencerEvent_RecoveryCompleted(
startedAtIso: null == startedAtIso ? _self.startedAtIso : startedAtIso // ignore: cast_nullable_to_non_nullable
as String,causeKind: null == causeKind ? _self.causeKind : causeKind // ignore: cast_nullable_to_non_nullable
as String,causeCustomLabel: freezed == causeCustomLabel ? _self.causeCustomLabel : causeCustomLabel // ignore: cast_nullable_to_non_nullable
as String?,lastAttemptAtIso: freezed == lastAttemptAtIso ? _self.lastAttemptAtIso : lastAttemptAtIso // ignore: cast_nullable_to_non_nullable
as String?,attemptCount: null == attemptCount ? _self.attemptCount : attemptCount // ignore: cast_nullable_to_non_nullable
as int,maxAttempts: null == maxAttempts ? _self.maxAttempts : maxAttempts // ignore: cast_nullable_to_non_nullable
as int,retryIntervalSecs: null == retryIntervalSecs ? _self.retryIntervalSecs : retryIntervalSecs // ignore: cast_nullable_to_non_nullable
as double,maxDurationSecs: null == maxDurationSecs ? _self.maxDurationSecs : maxDurationSecs // ignore: cast_nullable_to_non_nullable
as double,phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as String,lastError: freezed == lastError ? _self.lastError : lastError // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class SequencerEvent_RecoveryGaveUp extends SequencerEvent {
  const SequencerEvent_RecoveryGaveUp({required this.startedAtIso, required this.causeKind, this.causeCustomLabel, this.lastAttemptAtIso, required this.attemptCount, required this.maxAttempts, required this.retryIntervalSecs, required this.maxDurationSecs, required this.phase, this.lastError, required this.abortedByUser}): super._();
  

 final  String startedAtIso;
 final  String causeKind;
 final  String? causeCustomLabel;
 final  String? lastAttemptAtIso;
 final  int attemptCount;
 final  int maxAttempts;
 final  double retryIntervalSecs;
 final  double maxDurationSecs;
 final  String phase;
 final  String? lastError;
/// True when the loop exited because the user pressed Abort.
/// Distinct from exhaustion so the UI can render different copy
/// ("Aborted by operator" vs "Exhausted retries").
 final  bool abortedByUser;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_RecoveryGaveUpCopyWith<SequencerEvent_RecoveryGaveUp> get copyWith => _$SequencerEvent_RecoveryGaveUpCopyWithImpl<SequencerEvent_RecoveryGaveUp>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_RecoveryGaveUp&&(identical(other.startedAtIso, startedAtIso) || other.startedAtIso == startedAtIso)&&(identical(other.causeKind, causeKind) || other.causeKind == causeKind)&&(identical(other.causeCustomLabel, causeCustomLabel) || other.causeCustomLabel == causeCustomLabel)&&(identical(other.lastAttemptAtIso, lastAttemptAtIso) || other.lastAttemptAtIso == lastAttemptAtIso)&&(identical(other.attemptCount, attemptCount) || other.attemptCount == attemptCount)&&(identical(other.maxAttempts, maxAttempts) || other.maxAttempts == maxAttempts)&&(identical(other.retryIntervalSecs, retryIntervalSecs) || other.retryIntervalSecs == retryIntervalSecs)&&(identical(other.maxDurationSecs, maxDurationSecs) || other.maxDurationSecs == maxDurationSecs)&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.lastError, lastError) || other.lastError == lastError)&&(identical(other.abortedByUser, abortedByUser) || other.abortedByUser == abortedByUser));
}


@override
int get hashCode => Object.hash(runtimeType,startedAtIso,causeKind,causeCustomLabel,lastAttemptAtIso,attemptCount,maxAttempts,retryIntervalSecs,maxDurationSecs,phase,lastError,abortedByUser);

@override
String toString() {
  return 'SequencerEvent.recoveryGaveUp(startedAtIso: $startedAtIso, causeKind: $causeKind, causeCustomLabel: $causeCustomLabel, lastAttemptAtIso: $lastAttemptAtIso, attemptCount: $attemptCount, maxAttempts: $maxAttempts, retryIntervalSecs: $retryIntervalSecs, maxDurationSecs: $maxDurationSecs, phase: $phase, lastError: $lastError, abortedByUser: $abortedByUser)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_RecoveryGaveUpCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_RecoveryGaveUpCopyWith(SequencerEvent_RecoveryGaveUp value, $Res Function(SequencerEvent_RecoveryGaveUp) _then) = _$SequencerEvent_RecoveryGaveUpCopyWithImpl;
@useResult
$Res call({
 String startedAtIso, String causeKind, String? causeCustomLabel, String? lastAttemptAtIso, int attemptCount, int maxAttempts, double retryIntervalSecs, double maxDurationSecs, String phase, String? lastError, bool abortedByUser
});




}
/// @nodoc
class _$SequencerEvent_RecoveryGaveUpCopyWithImpl<$Res>
    implements $SequencerEvent_RecoveryGaveUpCopyWith<$Res> {
  _$SequencerEvent_RecoveryGaveUpCopyWithImpl(this._self, this._then);

  final SequencerEvent_RecoveryGaveUp _self;
  final $Res Function(SequencerEvent_RecoveryGaveUp) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? startedAtIso = null,Object? causeKind = null,Object? causeCustomLabel = freezed,Object? lastAttemptAtIso = freezed,Object? attemptCount = null,Object? maxAttempts = null,Object? retryIntervalSecs = null,Object? maxDurationSecs = null,Object? phase = null,Object? lastError = freezed,Object? abortedByUser = null,}) {
  return _then(SequencerEvent_RecoveryGaveUp(
startedAtIso: null == startedAtIso ? _self.startedAtIso : startedAtIso // ignore: cast_nullable_to_non_nullable
as String,causeKind: null == causeKind ? _self.causeKind : causeKind // ignore: cast_nullable_to_non_nullable
as String,causeCustomLabel: freezed == causeCustomLabel ? _self.causeCustomLabel : causeCustomLabel // ignore: cast_nullable_to_non_nullable
as String?,lastAttemptAtIso: freezed == lastAttemptAtIso ? _self.lastAttemptAtIso : lastAttemptAtIso // ignore: cast_nullable_to_non_nullable
as String?,attemptCount: null == attemptCount ? _self.attemptCount : attemptCount // ignore: cast_nullable_to_non_nullable
as int,maxAttempts: null == maxAttempts ? _self.maxAttempts : maxAttempts // ignore: cast_nullable_to_non_nullable
as int,retryIntervalSecs: null == retryIntervalSecs ? _self.retryIntervalSecs : retryIntervalSecs // ignore: cast_nullable_to_non_nullable
as double,maxDurationSecs: null == maxDurationSecs ? _self.maxDurationSecs : maxDurationSecs // ignore: cast_nullable_to_non_nullable
as double,phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as String,lastError: freezed == lastError ? _self.lastError : lastError // ignore: cast_nullable_to_non_nullable
as String?,abortedByUser: null == abortedByUser ? _self.abortedByUser : abortedByUser // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class SequencerEvent_PluginNodeRequested extends SequencerEvent {
  const SequencerEvent_PluginNodeRequested({required this.nodeId, required this.pluginId, required this.nodeTypeId, required this.configJson, this.displayName, required this.timeoutSecs}): super._();
  

/// Executor-side node identifier. The reply MUST echo this.
 final  String nodeId;
/// Stable plugin identifier (e.g. `com.example.pushover`).
 final  String pluginId;
/// Stable per-plugin node type identifier (e.g. `pushover.notify`).
 final  String nodeTypeId;
/// Opaque JSON payload the plugin author authored on the Dart
/// side. Rust forwards verbatim.
 final  String configJson;
/// Optional human-readable label. `None` => UI uses
/// `node_type_id`.
 final  String? displayName;
/// Effective timeout (seconds) the Rust side will wait. Dart
/// MUST honour this; a longer run on the Dart side will be
/// timed out by Rust first and surfaced as a failure.
 final  int timeoutSecs;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_PluginNodeRequestedCopyWith<SequencerEvent_PluginNodeRequested> get copyWith => _$SequencerEvent_PluginNodeRequestedCopyWithImpl<SequencerEvent_PluginNodeRequested>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_PluginNodeRequested&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.pluginId, pluginId) || other.pluginId == pluginId)&&(identical(other.nodeTypeId, nodeTypeId) || other.nodeTypeId == nodeTypeId)&&(identical(other.configJson, configJson) || other.configJson == configJson)&&(identical(other.displayName, displayName) || other.displayName == displayName)&&(identical(other.timeoutSecs, timeoutSecs) || other.timeoutSecs == timeoutSecs));
}


@override
int get hashCode => Object.hash(runtimeType,nodeId,pluginId,nodeTypeId,configJson,displayName,timeoutSecs);

@override
String toString() {
  return 'SequencerEvent.pluginNodeRequested(nodeId: $nodeId, pluginId: $pluginId, nodeTypeId: $nodeTypeId, configJson: $configJson, displayName: $displayName, timeoutSecs: $timeoutSecs)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_PluginNodeRequestedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_PluginNodeRequestedCopyWith(SequencerEvent_PluginNodeRequested value, $Res Function(SequencerEvent_PluginNodeRequested) _then) = _$SequencerEvent_PluginNodeRequestedCopyWithImpl;
@useResult
$Res call({
 String nodeId, String pluginId, String nodeTypeId, String configJson, String? displayName, int timeoutSecs
});




}
/// @nodoc
class _$SequencerEvent_PluginNodeRequestedCopyWithImpl<$Res>
    implements $SequencerEvent_PluginNodeRequestedCopyWith<$Res> {
  _$SequencerEvent_PluginNodeRequestedCopyWithImpl(this._self, this._then);

  final SequencerEvent_PluginNodeRequested _self;
  final $Res Function(SequencerEvent_PluginNodeRequested) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nodeId = null,Object? pluginId = null,Object? nodeTypeId = null,Object? configJson = null,Object? displayName = freezed,Object? timeoutSecs = null,}) {
  return _then(SequencerEvent_PluginNodeRequested(
nodeId: null == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String,pluginId: null == pluginId ? _self.pluginId : pluginId // ignore: cast_nullable_to_non_nullable
as String,nodeTypeId: null == nodeTypeId ? _self.nodeTypeId : nodeTypeId // ignore: cast_nullable_to_non_nullable
as String,configJson: null == configJson ? _self.configJson : configJson // ignore: cast_nullable_to_non_nullable
as String,displayName: freezed == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String?,timeoutSecs: null == timeoutSecs ? _self.timeoutSecs : timeoutSecs // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class SequencerEvent_PluginNodeProgress extends SequencerEvent {
  const SequencerEvent_PluginNodeProgress({required this.nodeId, required this.pluginId, required this.nodeTypeId, required this.detailJson}): super._();
  

 final  String nodeId;
 final  String pluginId;
 final  String nodeTypeId;
/// Stringified plugin-authored payload. Empty string when the
/// plugin emitted no payload.
 final  String detailJson;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_PluginNodeProgressCopyWith<SequencerEvent_PluginNodeProgress> get copyWith => _$SequencerEvent_PluginNodeProgressCopyWithImpl<SequencerEvent_PluginNodeProgress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_PluginNodeProgress&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.pluginId, pluginId) || other.pluginId == pluginId)&&(identical(other.nodeTypeId, nodeTypeId) || other.nodeTypeId == nodeTypeId)&&(identical(other.detailJson, detailJson) || other.detailJson == detailJson));
}


@override
int get hashCode => Object.hash(runtimeType,nodeId,pluginId,nodeTypeId,detailJson);

@override
String toString() {
  return 'SequencerEvent.pluginNodeProgress(nodeId: $nodeId, pluginId: $pluginId, nodeTypeId: $nodeTypeId, detailJson: $detailJson)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_PluginNodeProgressCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_PluginNodeProgressCopyWith(SequencerEvent_PluginNodeProgress value, $Res Function(SequencerEvent_PluginNodeProgress) _then) = _$SequencerEvent_PluginNodeProgressCopyWithImpl;
@useResult
$Res call({
 String nodeId, String pluginId, String nodeTypeId, String detailJson
});




}
/// @nodoc
class _$SequencerEvent_PluginNodeProgressCopyWithImpl<$Res>
    implements $SequencerEvent_PluginNodeProgressCopyWith<$Res> {
  _$SequencerEvent_PluginNodeProgressCopyWithImpl(this._self, this._then);

  final SequencerEvent_PluginNodeProgress _self;
  final $Res Function(SequencerEvent_PluginNodeProgress) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nodeId = null,Object? pluginId = null,Object? nodeTypeId = null,Object? detailJson = null,}) {
  return _then(SequencerEvent_PluginNodeProgress(
nodeId: null == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String,pluginId: null == pluginId ? _self.pluginId : pluginId // ignore: cast_nullable_to_non_nullable
as String,nodeTypeId: null == nodeTypeId ? _self.nodeTypeId : nodeTypeId // ignore: cast_nullable_to_non_nullable
as String,detailJson: null == detailJson ? _self.detailJson : detailJson // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SequencerEvent_DecisionLogged extends SequencerEvent {
  const SequencerEvent_DecisionLogged({required this.timestampIso, required this.category, required this.summary, required this.detailsJson, this.nodeId, this.sequenceRunId}): super._();
  

/// ISO-8601 UTC timestamp when the decision was made.
 final  String timestampIso;
/// Stable wire key for the underlying DecisionCategory variant.
 final  String category;
/// One-line human-readable summary.
 final  String summary;
/// JSON-stringified opaque details payload.
 final  String detailsJson;
/// Optional associated node id (scheduler / target / exposure
/// node).
 final  String? nodeId;
/// `sequence_runs.id` this decision belongs to, if the executor
/// has been stamped with one.
 final  PlatformInt64? sequenceRunId;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequencerEvent_DecisionLoggedCopyWith<SequencerEvent_DecisionLogged> get copyWith => _$SequencerEvent_DecisionLoggedCopyWithImpl<SequencerEvent_DecisionLogged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequencerEvent_DecisionLogged&&(identical(other.timestampIso, timestampIso) || other.timestampIso == timestampIso)&&(identical(other.category, category) || other.category == category)&&(identical(other.summary, summary) || other.summary == summary)&&(identical(other.detailsJson, detailsJson) || other.detailsJson == detailsJson)&&(identical(other.nodeId, nodeId) || other.nodeId == nodeId)&&(identical(other.sequenceRunId, sequenceRunId) || other.sequenceRunId == sequenceRunId));
}


@override
int get hashCode => Object.hash(runtimeType,timestampIso,category,summary,detailsJson,nodeId,sequenceRunId);

@override
String toString() {
  return 'SequencerEvent.decisionLogged(timestampIso: $timestampIso, category: $category, summary: $summary, detailsJson: $detailsJson, nodeId: $nodeId, sequenceRunId: $sequenceRunId)';
}


}

/// @nodoc
abstract mixin class $SequencerEvent_DecisionLoggedCopyWith<$Res> implements $SequencerEventCopyWith<$Res> {
  factory $SequencerEvent_DecisionLoggedCopyWith(SequencerEvent_DecisionLogged value, $Res Function(SequencerEvent_DecisionLogged) _then) = _$SequencerEvent_DecisionLoggedCopyWithImpl;
@useResult
$Res call({
 String timestampIso, String category, String summary, String detailsJson, String? nodeId, PlatformInt64? sequenceRunId
});




}
/// @nodoc
class _$SequencerEvent_DecisionLoggedCopyWithImpl<$Res>
    implements $SequencerEvent_DecisionLoggedCopyWith<$Res> {
  _$SequencerEvent_DecisionLoggedCopyWithImpl(this._self, this._then);

  final SequencerEvent_DecisionLogged _self;
  final $Res Function(SequencerEvent_DecisionLogged) _then;

/// Create a copy of SequencerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? timestampIso = null,Object? category = null,Object? summary = null,Object? detailsJson = null,Object? nodeId = freezed,Object? sequenceRunId = freezed,}) {
  return _then(SequencerEvent_DecisionLogged(
timestampIso: null == timestampIso ? _self.timestampIso : timestampIso // ignore: cast_nullable_to_non_nullable
as String,category: null == category ? _self.category : category // ignore: cast_nullable_to_non_nullable
as String,summary: null == summary ? _self.summary : summary // ignore: cast_nullable_to_non_nullable
as String,detailsJson: null == detailsJson ? _self.detailsJson : detailsJson // ignore: cast_nullable_to_non_nullable
as String,nodeId: freezed == nodeId ? _self.nodeId : nodeId // ignore: cast_nullable_to_non_nullable
as String?,sequenceRunId: freezed == sequenceRunId ? _self.sequenceRunId : sequenceRunId // ignore: cast_nullable_to_non_nullable
as PlatformInt64?,
  ));
}


}

// dart format on
