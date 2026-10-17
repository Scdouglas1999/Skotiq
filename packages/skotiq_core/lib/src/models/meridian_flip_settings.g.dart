// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'meridian_flip_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_MeridianFlipSettings _$MeridianFlipSettingsFromJson(
  Map<String, dynamic> json,
) => _MeridianFlipSettings(
  standaloneMonitoringEnabled:
      json['standaloneMonitoringEnabled'] as bool? ?? false,
  triggerMethod:
      $enumDecodeNullable(
        _$MeridianTriggerMethodEnumMap,
        json['triggerMethod'],
      ) ??
      MeridianTriggerMethod.minutesPastMeridian,
  minutesPastMeridian: (json['minutesPastMeridian'] as num?)?.toDouble() ?? 5.0,
  minutesBeforeLimit: (json['minutesBeforeLimit'] as num?)?.toDouble() ?? 10.0,
  hourAngleThreshold: (json['hourAngleThreshold'] as num?)?.toDouble() ?? 0.5,
  trackingLimitWaitMinutes:
      (json['trackingLimitWaitMinutes'] as num?)?.toDouble() ?? 0.0,
  pauseGuidingBeforeFlip: json['pauseGuidingBeforeFlip'] as bool? ?? true,
  recenterAfterFlip: json['recenterAfterFlip'] as bool? ?? true,
  refocusAfterFlip: json['refocusAfterFlip'] as bool? ?? false,
  settleTimeSeconds: (json['settleTimeSeconds'] as num?)?.toDouble() ?? 10.0,
  resumeGuidingAfterFlip: json['resumeGuidingAfterFlip'] as bool? ?? true,
  maxRetries: (json['maxRetries'] as num?)?.toInt() ?? 3,
  retryDelaysSeconds:
      (json['retryDelaysSeconds'] as List<dynamic>?)
          ?.map((e) => (e as num).toDouble())
          .toList() ??
      const [30.0, 60.0, 120.0],
  failureAction:
      $enumDecodeNullable(_$FlipFailureActionEnumMap, json['failureAction']) ??
      FlipFailureAction.pauseAndAlert,
  soundAlertOnFlip: json['soundAlertOnFlip'] as bool? ?? false,
  pushNotificationOnFlip: json['pushNotificationOnFlip'] as bool? ?? true,
);

Map<String, dynamic> _$MeridianFlipSettingsToJson(
  _MeridianFlipSettings instance,
) => <String, dynamic>{
  'standaloneMonitoringEnabled': instance.standaloneMonitoringEnabled,
  'triggerMethod': _$MeridianTriggerMethodEnumMap[instance.triggerMethod]!,
  'minutesPastMeridian': instance.minutesPastMeridian,
  'minutesBeforeLimit': instance.minutesBeforeLimit,
  'hourAngleThreshold': instance.hourAngleThreshold,
  'trackingLimitWaitMinutes': instance.trackingLimitWaitMinutes,
  'pauseGuidingBeforeFlip': instance.pauseGuidingBeforeFlip,
  'recenterAfterFlip': instance.recenterAfterFlip,
  'refocusAfterFlip': instance.refocusAfterFlip,
  'settleTimeSeconds': instance.settleTimeSeconds,
  'resumeGuidingAfterFlip': instance.resumeGuidingAfterFlip,
  'maxRetries': instance.maxRetries,
  'retryDelaysSeconds': instance.retryDelaysSeconds,
  'failureAction': _$FlipFailureActionEnumMap[instance.failureAction]!,
  'soundAlertOnFlip': instance.soundAlertOnFlip,
  'pushNotificationOnFlip': instance.pushNotificationOnFlip,
};

const _$MeridianTriggerMethodEnumMap = {
  MeridianTriggerMethod.minutesPastMeridian: 'minutesPastMeridian',
  MeridianTriggerMethod.minutesBeforeLimit: 'minutesBeforeLimit',
  MeridianTriggerMethod.hourAngleThreshold: 'hourAngleThreshold',
  MeridianTriggerMethod.onTrackingLimitHit: 'onTrackingLimitHit',
};

const _$FlipFailureActionEnumMap = {
  FlipFailureAction.pauseAndAlert: 'pauseAndAlert',
  FlipFailureAction.abortAndPark: 'abortAndPark',
};
