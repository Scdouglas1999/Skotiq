// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'meridian_flip_settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$MeridianFlipSettings {

// === Mode Control ===
/// Enable standalone monitoring when no sequence is running
 bool get standaloneMonitoringEnabled;// === Trigger Conditions ===
/// Which method to use for determining flip timing
 MeridianTriggerMethod get triggerMethod;/// Minutes past meridian to trigger flip (default: 5)
 double get minutesPastMeridian;/// Minutes before mount limit to trigger flip (default: 10)
 double get minutesBeforeLimit;/// Hour angle threshold in hours to trigger flip (default: 0.5 = 30 min)
 double get hourAngleThreshold;/// Minutes to wait after tracking limit hit before flipping (0 = immediate).
/// Only used with onTrackingLimitHit trigger method.
 double get trackingLimitWaitMinutes;// === Flip Sequence Options ===
/// Pause guider before flip
 bool get pauseGuidingBeforeFlip;/// Plate solve and re-center after flip
 bool get recenterAfterFlip;/// Run autofocus after flip
 bool get refocusAfterFlip;/// Settle time in seconds after flip completes
 double get settleTimeSeconds;/// Resume guiding after flip (if was running)
 bool get resumeGuidingAfterFlip;// === Error Handling ===
/// Maximum retry attempts
 int get maxRetries;/// Delay between retries in seconds
 List<double> get retryDelaysSeconds;/// Action to take on permanent failure
 FlipFailureAction get failureAction;// === Notifications ===
/// Play sound alert when flip starts/completes/fails
 bool get soundAlertOnFlip;/// Send push notification to mobile app
 bool get pushNotificationOnFlip;
/// Create a copy of MeridianFlipSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeridianFlipSettingsCopyWith<MeridianFlipSettings> get copyWith => _$MeridianFlipSettingsCopyWithImpl<MeridianFlipSettings>(this as MeridianFlipSettings, _$identity);

  /// Serializes this MeridianFlipSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeridianFlipSettings&&(identical(other.standaloneMonitoringEnabled, standaloneMonitoringEnabled) || other.standaloneMonitoringEnabled == standaloneMonitoringEnabled)&&(identical(other.triggerMethod, triggerMethod) || other.triggerMethod == triggerMethod)&&(identical(other.minutesPastMeridian, minutesPastMeridian) || other.minutesPastMeridian == minutesPastMeridian)&&(identical(other.minutesBeforeLimit, minutesBeforeLimit) || other.minutesBeforeLimit == minutesBeforeLimit)&&(identical(other.hourAngleThreshold, hourAngleThreshold) || other.hourAngleThreshold == hourAngleThreshold)&&(identical(other.trackingLimitWaitMinutes, trackingLimitWaitMinutes) || other.trackingLimitWaitMinutes == trackingLimitWaitMinutes)&&(identical(other.pauseGuidingBeforeFlip, pauseGuidingBeforeFlip) || other.pauseGuidingBeforeFlip == pauseGuidingBeforeFlip)&&(identical(other.recenterAfterFlip, recenterAfterFlip) || other.recenterAfterFlip == recenterAfterFlip)&&(identical(other.refocusAfterFlip, refocusAfterFlip) || other.refocusAfterFlip == refocusAfterFlip)&&(identical(other.settleTimeSeconds, settleTimeSeconds) || other.settleTimeSeconds == settleTimeSeconds)&&(identical(other.resumeGuidingAfterFlip, resumeGuidingAfterFlip) || other.resumeGuidingAfterFlip == resumeGuidingAfterFlip)&&(identical(other.maxRetries, maxRetries) || other.maxRetries == maxRetries)&&const DeepCollectionEquality().equals(other.retryDelaysSeconds, retryDelaysSeconds)&&(identical(other.failureAction, failureAction) || other.failureAction == failureAction)&&(identical(other.soundAlertOnFlip, soundAlertOnFlip) || other.soundAlertOnFlip == soundAlertOnFlip)&&(identical(other.pushNotificationOnFlip, pushNotificationOnFlip) || other.pushNotificationOnFlip == pushNotificationOnFlip));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,standaloneMonitoringEnabled,triggerMethod,minutesPastMeridian,minutesBeforeLimit,hourAngleThreshold,trackingLimitWaitMinutes,pauseGuidingBeforeFlip,recenterAfterFlip,refocusAfterFlip,settleTimeSeconds,resumeGuidingAfterFlip,maxRetries,const DeepCollectionEquality().hash(retryDelaysSeconds),failureAction,soundAlertOnFlip,pushNotificationOnFlip);

@override
String toString() {
  return 'MeridianFlipSettings(standaloneMonitoringEnabled: $standaloneMonitoringEnabled, triggerMethod: $triggerMethod, minutesPastMeridian: $minutesPastMeridian, minutesBeforeLimit: $minutesBeforeLimit, hourAngleThreshold: $hourAngleThreshold, trackingLimitWaitMinutes: $trackingLimitWaitMinutes, pauseGuidingBeforeFlip: $pauseGuidingBeforeFlip, recenterAfterFlip: $recenterAfterFlip, refocusAfterFlip: $refocusAfterFlip, settleTimeSeconds: $settleTimeSeconds, resumeGuidingAfterFlip: $resumeGuidingAfterFlip, maxRetries: $maxRetries, retryDelaysSeconds: $retryDelaysSeconds, failureAction: $failureAction, soundAlertOnFlip: $soundAlertOnFlip, pushNotificationOnFlip: $pushNotificationOnFlip)';
}


}

/// @nodoc
abstract mixin class $MeridianFlipSettingsCopyWith<$Res>  {
  factory $MeridianFlipSettingsCopyWith(MeridianFlipSettings value, $Res Function(MeridianFlipSettings) _then) = _$MeridianFlipSettingsCopyWithImpl;
@useResult
$Res call({
 bool standaloneMonitoringEnabled, MeridianTriggerMethod triggerMethod, double minutesPastMeridian, double minutesBeforeLimit, double hourAngleThreshold, double trackingLimitWaitMinutes, bool pauseGuidingBeforeFlip, bool recenterAfterFlip, bool refocusAfterFlip, double settleTimeSeconds, bool resumeGuidingAfterFlip, int maxRetries, List<double> retryDelaysSeconds, FlipFailureAction failureAction, bool soundAlertOnFlip, bool pushNotificationOnFlip
});




}
/// @nodoc
class _$MeridianFlipSettingsCopyWithImpl<$Res>
    implements $MeridianFlipSettingsCopyWith<$Res> {
  _$MeridianFlipSettingsCopyWithImpl(this._self, this._then);

  final MeridianFlipSettings _self;
  final $Res Function(MeridianFlipSettings) _then;

/// Create a copy of MeridianFlipSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? standaloneMonitoringEnabled = null,Object? triggerMethod = null,Object? minutesPastMeridian = null,Object? minutesBeforeLimit = null,Object? hourAngleThreshold = null,Object? trackingLimitWaitMinutes = null,Object? pauseGuidingBeforeFlip = null,Object? recenterAfterFlip = null,Object? refocusAfterFlip = null,Object? settleTimeSeconds = null,Object? resumeGuidingAfterFlip = null,Object? maxRetries = null,Object? retryDelaysSeconds = null,Object? failureAction = null,Object? soundAlertOnFlip = null,Object? pushNotificationOnFlip = null,}) {
  return _then(_self.copyWith(
standaloneMonitoringEnabled: null == standaloneMonitoringEnabled ? _self.standaloneMonitoringEnabled : standaloneMonitoringEnabled // ignore: cast_nullable_to_non_nullable
as bool,triggerMethod: null == triggerMethod ? _self.triggerMethod : triggerMethod // ignore: cast_nullable_to_non_nullable
as MeridianTriggerMethod,minutesPastMeridian: null == minutesPastMeridian ? _self.minutesPastMeridian : minutesPastMeridian // ignore: cast_nullable_to_non_nullable
as double,minutesBeforeLimit: null == minutesBeforeLimit ? _self.minutesBeforeLimit : minutesBeforeLimit // ignore: cast_nullable_to_non_nullable
as double,hourAngleThreshold: null == hourAngleThreshold ? _self.hourAngleThreshold : hourAngleThreshold // ignore: cast_nullable_to_non_nullable
as double,trackingLimitWaitMinutes: null == trackingLimitWaitMinutes ? _self.trackingLimitWaitMinutes : trackingLimitWaitMinutes // ignore: cast_nullable_to_non_nullable
as double,pauseGuidingBeforeFlip: null == pauseGuidingBeforeFlip ? _self.pauseGuidingBeforeFlip : pauseGuidingBeforeFlip // ignore: cast_nullable_to_non_nullable
as bool,recenterAfterFlip: null == recenterAfterFlip ? _self.recenterAfterFlip : recenterAfterFlip // ignore: cast_nullable_to_non_nullable
as bool,refocusAfterFlip: null == refocusAfterFlip ? _self.refocusAfterFlip : refocusAfterFlip // ignore: cast_nullable_to_non_nullable
as bool,settleTimeSeconds: null == settleTimeSeconds ? _self.settleTimeSeconds : settleTimeSeconds // ignore: cast_nullable_to_non_nullable
as double,resumeGuidingAfterFlip: null == resumeGuidingAfterFlip ? _self.resumeGuidingAfterFlip : resumeGuidingAfterFlip // ignore: cast_nullable_to_non_nullable
as bool,maxRetries: null == maxRetries ? _self.maxRetries : maxRetries // ignore: cast_nullable_to_non_nullable
as int,retryDelaysSeconds: null == retryDelaysSeconds ? _self.retryDelaysSeconds : retryDelaysSeconds // ignore: cast_nullable_to_non_nullable
as List<double>,failureAction: null == failureAction ? _self.failureAction : failureAction // ignore: cast_nullable_to_non_nullable
as FlipFailureAction,soundAlertOnFlip: null == soundAlertOnFlip ? _self.soundAlertOnFlip : soundAlertOnFlip // ignore: cast_nullable_to_non_nullable
as bool,pushNotificationOnFlip: null == pushNotificationOnFlip ? _self.pushNotificationOnFlip : pushNotificationOnFlip // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [MeridianFlipSettings].
extension MeridianFlipSettingsPatterns on MeridianFlipSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _MeridianFlipSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _MeridianFlipSettings() when $default != null:
return $default(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _MeridianFlipSettings value)  $default,){
final _that = this;
switch (_that) {
case _MeridianFlipSettings():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _MeridianFlipSettings value)?  $default,){
final _that = this;
switch (_that) {
case _MeridianFlipSettings() when $default != null:
return $default(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool standaloneMonitoringEnabled,  MeridianTriggerMethod triggerMethod,  double minutesPastMeridian,  double minutesBeforeLimit,  double hourAngleThreshold,  double trackingLimitWaitMinutes,  bool pauseGuidingBeforeFlip,  bool recenterAfterFlip,  bool refocusAfterFlip,  double settleTimeSeconds,  bool resumeGuidingAfterFlip,  int maxRetries,  List<double> retryDelaysSeconds,  FlipFailureAction failureAction,  bool soundAlertOnFlip,  bool pushNotificationOnFlip)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _MeridianFlipSettings() when $default != null:
return $default(_that.standaloneMonitoringEnabled,_that.triggerMethod,_that.minutesPastMeridian,_that.minutesBeforeLimit,_that.hourAngleThreshold,_that.trackingLimitWaitMinutes,_that.pauseGuidingBeforeFlip,_that.recenterAfterFlip,_that.refocusAfterFlip,_that.settleTimeSeconds,_that.resumeGuidingAfterFlip,_that.maxRetries,_that.retryDelaysSeconds,_that.failureAction,_that.soundAlertOnFlip,_that.pushNotificationOnFlip);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool standaloneMonitoringEnabled,  MeridianTriggerMethod triggerMethod,  double minutesPastMeridian,  double minutesBeforeLimit,  double hourAngleThreshold,  double trackingLimitWaitMinutes,  bool pauseGuidingBeforeFlip,  bool recenterAfterFlip,  bool refocusAfterFlip,  double settleTimeSeconds,  bool resumeGuidingAfterFlip,  int maxRetries,  List<double> retryDelaysSeconds,  FlipFailureAction failureAction,  bool soundAlertOnFlip,  bool pushNotificationOnFlip)  $default,) {final _that = this;
switch (_that) {
case _MeridianFlipSettings():
return $default(_that.standaloneMonitoringEnabled,_that.triggerMethod,_that.minutesPastMeridian,_that.minutesBeforeLimit,_that.hourAngleThreshold,_that.trackingLimitWaitMinutes,_that.pauseGuidingBeforeFlip,_that.recenterAfterFlip,_that.refocusAfterFlip,_that.settleTimeSeconds,_that.resumeGuidingAfterFlip,_that.maxRetries,_that.retryDelaysSeconds,_that.failureAction,_that.soundAlertOnFlip,_that.pushNotificationOnFlip);case _:
  throw StateError('Unexpected subclass');

}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool standaloneMonitoringEnabled,  MeridianTriggerMethod triggerMethod,  double minutesPastMeridian,  double minutesBeforeLimit,  double hourAngleThreshold,  double trackingLimitWaitMinutes,  bool pauseGuidingBeforeFlip,  bool recenterAfterFlip,  bool refocusAfterFlip,  double settleTimeSeconds,  bool resumeGuidingAfterFlip,  int maxRetries,  List<double> retryDelaysSeconds,  FlipFailureAction failureAction,  bool soundAlertOnFlip,  bool pushNotificationOnFlip)?  $default,) {final _that = this;
switch (_that) {
case _MeridianFlipSettings() when $default != null:
return $default(_that.standaloneMonitoringEnabled,_that.triggerMethod,_that.minutesPastMeridian,_that.minutesBeforeLimit,_that.hourAngleThreshold,_that.trackingLimitWaitMinutes,_that.pauseGuidingBeforeFlip,_that.recenterAfterFlip,_that.refocusAfterFlip,_that.settleTimeSeconds,_that.resumeGuidingAfterFlip,_that.maxRetries,_that.retryDelaysSeconds,_that.failureAction,_that.soundAlertOnFlip,_that.pushNotificationOnFlip);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _MeridianFlipSettings extends MeridianFlipSettings {
  const _MeridianFlipSettings({this.standaloneMonitoringEnabled = false, this.triggerMethod = MeridianTriggerMethod.minutesPastMeridian, this.minutesPastMeridian = 5.0, this.minutesBeforeLimit = 10.0, this.hourAngleThreshold = 0.5, this.trackingLimitWaitMinutes = 0.0, this.pauseGuidingBeforeFlip = true, this.recenterAfterFlip = true, this.refocusAfterFlip = false, this.settleTimeSeconds = 10.0, this.resumeGuidingAfterFlip = true, this.maxRetries = 3, final  List<double> retryDelaysSeconds = const [30.0, 60.0, 120.0], this.failureAction = FlipFailureAction.pauseAndAlert, this.soundAlertOnFlip = false, this.pushNotificationOnFlip = true}): _retryDelaysSeconds = retryDelaysSeconds,super._();
  factory _MeridianFlipSettings.fromJson(Map<String, dynamic> json) => _$MeridianFlipSettingsFromJson(json);

// === Mode Control ===
/// Enable standalone monitoring when no sequence is running
@override@JsonKey() final  bool standaloneMonitoringEnabled;
// === Trigger Conditions ===
/// Which method to use for determining flip timing
@override@JsonKey() final  MeridianTriggerMethod triggerMethod;
/// Minutes past meridian to trigger flip (default: 5)
@override@JsonKey() final  double minutesPastMeridian;
/// Minutes before mount limit to trigger flip (default: 10)
@override@JsonKey() final  double minutesBeforeLimit;
/// Hour angle threshold in hours to trigger flip (default: 0.5 = 30 min)
@override@JsonKey() final  double hourAngleThreshold;
/// Minutes to wait after tracking limit hit before flipping (0 = immediate).
/// Only used with onTrackingLimitHit trigger method.
@override@JsonKey() final  double trackingLimitWaitMinutes;
// === Flip Sequence Options ===
/// Pause guider before flip
@override@JsonKey() final  bool pauseGuidingBeforeFlip;
/// Plate solve and re-center after flip
@override@JsonKey() final  bool recenterAfterFlip;
/// Run autofocus after flip
@override@JsonKey() final  bool refocusAfterFlip;
/// Settle time in seconds after flip completes
@override@JsonKey() final  double settleTimeSeconds;
/// Resume guiding after flip (if was running)
@override@JsonKey() final  bool resumeGuidingAfterFlip;
// === Error Handling ===
/// Maximum retry attempts
@override@JsonKey() final  int maxRetries;
/// Delay between retries in seconds
 final  List<double> _retryDelaysSeconds;
/// Delay between retries in seconds
@override@JsonKey() List<double> get retryDelaysSeconds {
  if (_retryDelaysSeconds is EqualUnmodifiableListView) return _retryDelaysSeconds;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_retryDelaysSeconds);
}

/// Action to take on permanent failure
@override@JsonKey() final  FlipFailureAction failureAction;
// === Notifications ===
/// Play sound alert when flip starts/completes/fails
@override@JsonKey() final  bool soundAlertOnFlip;
/// Send push notification to mobile app
@override@JsonKey() final  bool pushNotificationOnFlip;

/// Create a copy of MeridianFlipSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$MeridianFlipSettingsCopyWith<_MeridianFlipSettings> get copyWith => __$MeridianFlipSettingsCopyWithImpl<_MeridianFlipSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeridianFlipSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _MeridianFlipSettings&&(identical(other.standaloneMonitoringEnabled, standaloneMonitoringEnabled) || other.standaloneMonitoringEnabled == standaloneMonitoringEnabled)&&(identical(other.triggerMethod, triggerMethod) || other.triggerMethod == triggerMethod)&&(identical(other.minutesPastMeridian, minutesPastMeridian) || other.minutesPastMeridian == minutesPastMeridian)&&(identical(other.minutesBeforeLimit, minutesBeforeLimit) || other.minutesBeforeLimit == minutesBeforeLimit)&&(identical(other.hourAngleThreshold, hourAngleThreshold) || other.hourAngleThreshold == hourAngleThreshold)&&(identical(other.trackingLimitWaitMinutes, trackingLimitWaitMinutes) || other.trackingLimitWaitMinutes == trackingLimitWaitMinutes)&&(identical(other.pauseGuidingBeforeFlip, pauseGuidingBeforeFlip) || other.pauseGuidingBeforeFlip == pauseGuidingBeforeFlip)&&(identical(other.recenterAfterFlip, recenterAfterFlip) || other.recenterAfterFlip == recenterAfterFlip)&&(identical(other.refocusAfterFlip, refocusAfterFlip) || other.refocusAfterFlip == refocusAfterFlip)&&(identical(other.settleTimeSeconds, settleTimeSeconds) || other.settleTimeSeconds == settleTimeSeconds)&&(identical(other.resumeGuidingAfterFlip, resumeGuidingAfterFlip) || other.resumeGuidingAfterFlip == resumeGuidingAfterFlip)&&(identical(other.maxRetries, maxRetries) || other.maxRetries == maxRetries)&&const DeepCollectionEquality().equals(other._retryDelaysSeconds, _retryDelaysSeconds)&&(identical(other.failureAction, failureAction) || other.failureAction == failureAction)&&(identical(other.soundAlertOnFlip, soundAlertOnFlip) || other.soundAlertOnFlip == soundAlertOnFlip)&&(identical(other.pushNotificationOnFlip, pushNotificationOnFlip) || other.pushNotificationOnFlip == pushNotificationOnFlip));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,standaloneMonitoringEnabled,triggerMethod,minutesPastMeridian,minutesBeforeLimit,hourAngleThreshold,trackingLimitWaitMinutes,pauseGuidingBeforeFlip,recenterAfterFlip,refocusAfterFlip,settleTimeSeconds,resumeGuidingAfterFlip,maxRetries,const DeepCollectionEquality().hash(_retryDelaysSeconds),failureAction,soundAlertOnFlip,pushNotificationOnFlip);

@override
String toString() {
  return 'MeridianFlipSettings(standaloneMonitoringEnabled: $standaloneMonitoringEnabled, triggerMethod: $triggerMethod, minutesPastMeridian: $minutesPastMeridian, minutesBeforeLimit: $minutesBeforeLimit, hourAngleThreshold: $hourAngleThreshold, trackingLimitWaitMinutes: $trackingLimitWaitMinutes, pauseGuidingBeforeFlip: $pauseGuidingBeforeFlip, recenterAfterFlip: $recenterAfterFlip, refocusAfterFlip: $refocusAfterFlip, settleTimeSeconds: $settleTimeSeconds, resumeGuidingAfterFlip: $resumeGuidingAfterFlip, maxRetries: $maxRetries, retryDelaysSeconds: $retryDelaysSeconds, failureAction: $failureAction, soundAlertOnFlip: $soundAlertOnFlip, pushNotificationOnFlip: $pushNotificationOnFlip)';
}


}

/// @nodoc
abstract mixin class _$MeridianFlipSettingsCopyWith<$Res> implements $MeridianFlipSettingsCopyWith<$Res> {
  factory _$MeridianFlipSettingsCopyWith(_MeridianFlipSettings value, $Res Function(_MeridianFlipSettings) _then) = __$MeridianFlipSettingsCopyWithImpl;
@override @useResult
$Res call({
 bool standaloneMonitoringEnabled, MeridianTriggerMethod triggerMethod, double minutesPastMeridian, double minutesBeforeLimit, double hourAngleThreshold, double trackingLimitWaitMinutes, bool pauseGuidingBeforeFlip, bool recenterAfterFlip, bool refocusAfterFlip, double settleTimeSeconds, bool resumeGuidingAfterFlip, int maxRetries, List<double> retryDelaysSeconds, FlipFailureAction failureAction, bool soundAlertOnFlip, bool pushNotificationOnFlip
});




}
/// @nodoc
class __$MeridianFlipSettingsCopyWithImpl<$Res>
    implements _$MeridianFlipSettingsCopyWith<$Res> {
  __$MeridianFlipSettingsCopyWithImpl(this._self, this._then);

  final _MeridianFlipSettings _self;
  final $Res Function(_MeridianFlipSettings) _then;

/// Create a copy of MeridianFlipSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? standaloneMonitoringEnabled = null,Object? triggerMethod = null,Object? minutesPastMeridian = null,Object? minutesBeforeLimit = null,Object? hourAngleThreshold = null,Object? trackingLimitWaitMinutes = null,Object? pauseGuidingBeforeFlip = null,Object? recenterAfterFlip = null,Object? refocusAfterFlip = null,Object? settleTimeSeconds = null,Object? resumeGuidingAfterFlip = null,Object? maxRetries = null,Object? retryDelaysSeconds = null,Object? failureAction = null,Object? soundAlertOnFlip = null,Object? pushNotificationOnFlip = null,}) {
  return _then(_MeridianFlipSettings(
standaloneMonitoringEnabled: null == standaloneMonitoringEnabled ? _self.standaloneMonitoringEnabled : standaloneMonitoringEnabled // ignore: cast_nullable_to_non_nullable
as bool,triggerMethod: null == triggerMethod ? _self.triggerMethod : triggerMethod // ignore: cast_nullable_to_non_nullable
as MeridianTriggerMethod,minutesPastMeridian: null == minutesPastMeridian ? _self.minutesPastMeridian : minutesPastMeridian // ignore: cast_nullable_to_non_nullable
as double,minutesBeforeLimit: null == minutesBeforeLimit ? _self.minutesBeforeLimit : minutesBeforeLimit // ignore: cast_nullable_to_non_nullable
as double,hourAngleThreshold: null == hourAngleThreshold ? _self.hourAngleThreshold : hourAngleThreshold // ignore: cast_nullable_to_non_nullable
as double,trackingLimitWaitMinutes: null == trackingLimitWaitMinutes ? _self.trackingLimitWaitMinutes : trackingLimitWaitMinutes // ignore: cast_nullable_to_non_nullable
as double,pauseGuidingBeforeFlip: null == pauseGuidingBeforeFlip ? _self.pauseGuidingBeforeFlip : pauseGuidingBeforeFlip // ignore: cast_nullable_to_non_nullable
as bool,recenterAfterFlip: null == recenterAfterFlip ? _self.recenterAfterFlip : recenterAfterFlip // ignore: cast_nullable_to_non_nullable
as bool,refocusAfterFlip: null == refocusAfterFlip ? _self.refocusAfterFlip : refocusAfterFlip // ignore: cast_nullable_to_non_nullable
as bool,settleTimeSeconds: null == settleTimeSeconds ? _self.settleTimeSeconds : settleTimeSeconds // ignore: cast_nullable_to_non_nullable
as double,resumeGuidingAfterFlip: null == resumeGuidingAfterFlip ? _self.resumeGuidingAfterFlip : resumeGuidingAfterFlip // ignore: cast_nullable_to_non_nullable
as bool,maxRetries: null == maxRetries ? _self.maxRetries : maxRetries // ignore: cast_nullable_to_non_nullable
as int,retryDelaysSeconds: null == retryDelaysSeconds ? _self._retryDelaysSeconds : retryDelaysSeconds // ignore: cast_nullable_to_non_nullable
as List<double>,failureAction: null == failureAction ? _self.failureAction : failureAction // ignore: cast_nullable_to_non_nullable
as FlipFailureAction,soundAlertOnFlip: null == soundAlertOnFlip ? _self.soundAlertOnFlip : soundAlertOnFlip // ignore: cast_nullable_to_non_nullable
as bool,pushNotificationOnFlip: null == pushNotificationOnFlip ? _self.pushNotificationOnFlip : pushNotificationOnFlip // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
