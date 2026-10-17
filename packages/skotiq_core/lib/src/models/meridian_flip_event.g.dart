// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'meridian_flip_event.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MeridianFlipStarting _$MeridianFlipStartingFromJson(
  Map<String, dynamic> json,
) => MeridianFlipStarting(
  targetName: json['targetName'] as String,
  fromPierSide: $enumDecode(_$PierSideEnumMap, json['fromPierSide']),
  hourAngle: (json['hourAngle'] as num).toDouble(),
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$MeridianFlipStartingToJson(
  MeridianFlipStarting instance,
) => <String, dynamic>{
  'targetName': instance.targetName,
  'fromPierSide': _$PierSideEnumMap[instance.fromPierSide]!,
  'hourAngle': instance.hourAngle,
  'runtimeType': instance.$type,
};

const _$PierSideEnumMap = {
  PierSide.east: 'east',
  PierSide.west: 'west',
  PierSide.unknown: 'unknown',
};

MeridianFlipStepStarted _$MeridianFlipStepStartedFromJson(
  Map<String, dynamic> json,
) => MeridianFlipStepStarted(
  step: $enumDecode(_$FlipStepEnumMap, json['step']),
  stepIndex: (json['stepIndex'] as num).toInt(),
  totalSteps: (json['totalSteps'] as num).toInt(),
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$MeridianFlipStepStartedToJson(
  MeridianFlipStepStarted instance,
) => <String, dynamic>{
  'step': _$FlipStepEnumMap[instance.step]!,
  'stepIndex': instance.stepIndex,
  'totalSteps': instance.totalSteps,
  'runtimeType': instance.$type,
};

const _$FlipStepEnumMap = {
  FlipStep.pausingGuider: 'pausingGuider',
  FlipStep.stoppingTracking: 'stoppingTracking',
  FlipStep.slewingToTarget: 'slewingToTarget',
  FlipStep.verifyingPierSide: 'verifyingPierSide',
  FlipStep.resumingTracking: 'resumingTracking',
  FlipStep.plateSolvingAndCentering: 'plateSolvingAndCentering',
  FlipStep.refocusing: 'refocusing',
  FlipStep.resumingGuider: 'resumingGuider',
  FlipStep.settling: 'settling',
};

MeridianFlipStepCompleted _$MeridianFlipStepCompletedFromJson(
  Map<String, dynamic> json,
) => MeridianFlipStepCompleted(
  step: $enumDecode(_$FlipStepEnumMap, json['step']),
  durationSecs: (json['durationSecs'] as num?)?.toDouble(),
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$MeridianFlipStepCompletedToJson(
  MeridianFlipStepCompleted instance,
) => <String, dynamic>{
  'step': _$FlipStepEnumMap[instance.step]!,
  'durationSecs': instance.durationSecs,
  'runtimeType': instance.$type,
};

MeridianFlipStepFailed _$MeridianFlipStepFailedFromJson(
  Map<String, dynamic> json,
) => MeridianFlipStepFailed(
  step: $enumDecode(_$FlipStepEnumMap, json['step']),
  error: json['error'] as String,
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$MeridianFlipStepFailedToJson(
  MeridianFlipStepFailed instance,
) => <String, dynamic>{
  'step': _$FlipStepEnumMap[instance.step]!,
  'error': instance.error,
  'runtimeType': instance.$type,
};

MeridianFlipProgress _$MeridianFlipProgressFromJson(
  Map<String, dynamic> json,
) => MeridianFlipProgress(
  percent: (json['percent'] as num).toInt(),
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$MeridianFlipProgressToJson(
  MeridianFlipProgress instance,
) => <String, dynamic>{
  'percent': instance.percent,
  'runtimeType': instance.$type,
};

MeridianFlipRetryScheduled _$MeridianFlipRetryScheduledFromJson(
  Map<String, dynamic> json,
) => MeridianFlipRetryScheduled(
  attempt: (json['attempt'] as num).toInt(),
  maxAttempts: (json['maxAttempts'] as num).toInt(),
  delaySecs: (json['delaySecs'] as num).toDouble(),
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$MeridianFlipRetryScheduledToJson(
  MeridianFlipRetryScheduled instance,
) => <String, dynamic>{
  'attempt': instance.attempt,
  'maxAttempts': instance.maxAttempts,
  'delaySecs': instance.delaySecs,
  'runtimeType': instance.$type,
};

MeridianFlipCompleted _$MeridianFlipCompletedFromJson(
  Map<String, dynamic> json,
) => MeridianFlipCompleted(
  newPierSide: $enumDecode(_$PierSideEnumMap, json['newPierSide']),
  durationSecs: (json['durationSecs'] as num).toDouble(),
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$MeridianFlipCompletedToJson(
  MeridianFlipCompleted instance,
) => <String, dynamic>{
  'newPierSide': _$PierSideEnumMap[instance.newPierSide]!,
  'durationSecs': instance.durationSecs,
  'runtimeType': instance.$type,
};

MeridianFlipFailed _$MeridianFlipFailedFromJson(Map<String, dynamic> json) =>
    MeridianFlipFailed(
      error: json['error'] as String,
      actionTaken: json['actionTaken'] as String,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$MeridianFlipFailedToJson(MeridianFlipFailed instance) =>
    <String, dynamic>{
      'error': instance.error,
      'actionTaken': instance.actionTaken,
      'runtimeType': instance.$type,
    };

MeridianFlipAborted _$MeridianFlipAbortedFromJson(Map<String, dynamic> json) =>
    MeridianFlipAborted(
      reason: json['reason'] as String,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$MeridianFlipAbortedToJson(
  MeridianFlipAborted instance,
) => <String, dynamic>{
  'reason': instance.reason,
  'runtimeType': instance.$type,
};
