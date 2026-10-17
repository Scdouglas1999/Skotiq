// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'meridian_flip_event.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
MeridianFlipEvent _$MeridianFlipEventFromJson(
  Map<String, dynamic> json
) {
        switch (json['runtimeType']) {
                  case 'starting':
          return MeridianFlipStarting.fromJson(
            json
          );
                case 'stepStarted':
          return MeridianFlipStepStarted.fromJson(
            json
          );
                case 'stepCompleted':
          return MeridianFlipStepCompleted.fromJson(
            json
          );
                case 'stepFailed':
          return MeridianFlipStepFailed.fromJson(
            json
          );
                case 'progress':
          return MeridianFlipProgress.fromJson(
            json
          );
                case 'retryScheduled':
          return MeridianFlipRetryScheduled.fromJson(
            json
          );
                case 'completed':
          return MeridianFlipCompleted.fromJson(
            json
          );
                case 'failed':
          return MeridianFlipFailed.fromJson(
            json
          );
                case 'aborted':
          return MeridianFlipAborted.fromJson(
            json
          );
        
          default:
            throw CheckedFromJsonException(
  json,
  'runtimeType',
  'MeridianFlipEvent',
  'Invalid union type "${json['runtimeType']}"!'
);
        }
      
}

/// @nodoc
mixin _$MeridianFlipEvent {



  /// Serializes this MeridianFlipEvent to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeridianFlipEvent);
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'MeridianFlipEvent()';
}


}

/// @nodoc
class $MeridianFlipEventCopyWith<$Res>  {
$MeridianFlipEventCopyWith(MeridianFlipEvent _, $Res Function(MeridianFlipEvent) __);
}


/// Adds pattern-matching-related methods to [MeridianFlipEvent].
extension MeridianFlipEventPatterns on MeridianFlipEvent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( MeridianFlipStarting value)?  starting,TResult Function( MeridianFlipStepStarted value)?  stepStarted,TResult Function( MeridianFlipStepCompleted value)?  stepCompleted,TResult Function( MeridianFlipStepFailed value)?  stepFailed,TResult Function( MeridianFlipProgress value)?  progress,TResult Function( MeridianFlipRetryScheduled value)?  retryScheduled,TResult Function( MeridianFlipCompleted value)?  completed,TResult Function( MeridianFlipFailed value)?  failed,TResult Function( MeridianFlipAborted value)?  aborted,required TResult orElse(),}){
final _that = this;
switch (_that) {
case MeridianFlipStarting() when starting != null:
return starting(_that);case MeridianFlipStepStarted() when stepStarted != null:
return stepStarted(_that);case MeridianFlipStepCompleted() when stepCompleted != null:
return stepCompleted(_that);case MeridianFlipStepFailed() when stepFailed != null:
return stepFailed(_that);case MeridianFlipProgress() when progress != null:
return progress(_that);case MeridianFlipRetryScheduled() when retryScheduled != null:
return retryScheduled(_that);case MeridianFlipCompleted() when completed != null:
return completed(_that);case MeridianFlipFailed() when failed != null:
return failed(_that);case MeridianFlipAborted() when aborted != null:
return aborted(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( MeridianFlipStarting value)  starting,required TResult Function( MeridianFlipStepStarted value)  stepStarted,required TResult Function( MeridianFlipStepCompleted value)  stepCompleted,required TResult Function( MeridianFlipStepFailed value)  stepFailed,required TResult Function( MeridianFlipProgress value)  progress,required TResult Function( MeridianFlipRetryScheduled value)  retryScheduled,required TResult Function( MeridianFlipCompleted value)  completed,required TResult Function( MeridianFlipFailed value)  failed,required TResult Function( MeridianFlipAborted value)  aborted,}){
final _that = this;
switch (_that) {
case MeridianFlipStarting():
return starting(_that);case MeridianFlipStepStarted():
return stepStarted(_that);case MeridianFlipStepCompleted():
return stepCompleted(_that);case MeridianFlipStepFailed():
return stepFailed(_that);case MeridianFlipProgress():
return progress(_that);case MeridianFlipRetryScheduled():
return retryScheduled(_that);case MeridianFlipCompleted():
return completed(_that);case MeridianFlipFailed():
return failed(_that);case MeridianFlipAborted():
return aborted(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( MeridianFlipStarting value)?  starting,TResult? Function( MeridianFlipStepStarted value)?  stepStarted,TResult? Function( MeridianFlipStepCompleted value)?  stepCompleted,TResult? Function( MeridianFlipStepFailed value)?  stepFailed,TResult? Function( MeridianFlipProgress value)?  progress,TResult? Function( MeridianFlipRetryScheduled value)?  retryScheduled,TResult? Function( MeridianFlipCompleted value)?  completed,TResult? Function( MeridianFlipFailed value)?  failed,TResult? Function( MeridianFlipAborted value)?  aborted,}){
final _that = this;
switch (_that) {
case MeridianFlipStarting() when starting != null:
return starting(_that);case MeridianFlipStepStarted() when stepStarted != null:
return stepStarted(_that);case MeridianFlipStepCompleted() when stepCompleted != null:
return stepCompleted(_that);case MeridianFlipStepFailed() when stepFailed != null:
return stepFailed(_that);case MeridianFlipProgress() when progress != null:
return progress(_that);case MeridianFlipRetryScheduled() when retryScheduled != null:
return retryScheduled(_that);case MeridianFlipCompleted() when completed != null:
return completed(_that);case MeridianFlipFailed() when failed != null:
return failed(_that);case MeridianFlipAborted() when aborted != null:
return aborted(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String targetName,  PierSide fromPierSide,  double hourAngle)?  starting,TResult Function( FlipStep step,  int stepIndex,  int totalSteps)?  stepStarted,TResult Function( FlipStep step,  double? durationSecs)?  stepCompleted,TResult Function( FlipStep step,  String error)?  stepFailed,TResult Function( int percent)?  progress,TResult Function( int attempt,  int maxAttempts,  double delaySecs)?  retryScheduled,TResult Function( PierSide newPierSide,  double durationSecs)?  completed,TResult Function( String error,  String actionTaken)?  failed,TResult Function( String reason)?  aborted,required TResult orElse(),}) {final _that = this;
switch (_that) {
case MeridianFlipStarting() when starting != null:
return starting(_that.targetName,_that.fromPierSide,_that.hourAngle);case MeridianFlipStepStarted() when stepStarted != null:
return stepStarted(_that.step,_that.stepIndex,_that.totalSteps);case MeridianFlipStepCompleted() when stepCompleted != null:
return stepCompleted(_that.step,_that.durationSecs);case MeridianFlipStepFailed() when stepFailed != null:
return stepFailed(_that.step,_that.error);case MeridianFlipProgress() when progress != null:
return progress(_that.percent);case MeridianFlipRetryScheduled() when retryScheduled != null:
return retryScheduled(_that.attempt,_that.maxAttempts,_that.delaySecs);case MeridianFlipCompleted() when completed != null:
return completed(_that.newPierSide,_that.durationSecs);case MeridianFlipFailed() when failed != null:
return failed(_that.error,_that.actionTaken);case MeridianFlipAborted() when aborted != null:
return aborted(_that.reason);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String targetName,  PierSide fromPierSide,  double hourAngle)  starting,required TResult Function( FlipStep step,  int stepIndex,  int totalSteps)  stepStarted,required TResult Function( FlipStep step,  double? durationSecs)  stepCompleted,required TResult Function( FlipStep step,  String error)  stepFailed,required TResult Function( int percent)  progress,required TResult Function( int attempt,  int maxAttempts,  double delaySecs)  retryScheduled,required TResult Function( PierSide newPierSide,  double durationSecs)  completed,required TResult Function( String error,  String actionTaken)  failed,required TResult Function( String reason)  aborted,}) {final _that = this;
switch (_that) {
case MeridianFlipStarting():
return starting(_that.targetName,_that.fromPierSide,_that.hourAngle);case MeridianFlipStepStarted():
return stepStarted(_that.step,_that.stepIndex,_that.totalSteps);case MeridianFlipStepCompleted():
return stepCompleted(_that.step,_that.durationSecs);case MeridianFlipStepFailed():
return stepFailed(_that.step,_that.error);case MeridianFlipProgress():
return progress(_that.percent);case MeridianFlipRetryScheduled():
return retryScheduled(_that.attempt,_that.maxAttempts,_that.delaySecs);case MeridianFlipCompleted():
return completed(_that.newPierSide,_that.durationSecs);case MeridianFlipFailed():
return failed(_that.error,_that.actionTaken);case MeridianFlipAborted():
return aborted(_that.reason);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String targetName,  PierSide fromPierSide,  double hourAngle)?  starting,TResult? Function( FlipStep step,  int stepIndex,  int totalSteps)?  stepStarted,TResult? Function( FlipStep step,  double? durationSecs)?  stepCompleted,TResult? Function( FlipStep step,  String error)?  stepFailed,TResult? Function( int percent)?  progress,TResult? Function( int attempt,  int maxAttempts,  double delaySecs)?  retryScheduled,TResult? Function( PierSide newPierSide,  double durationSecs)?  completed,TResult? Function( String error,  String actionTaken)?  failed,TResult? Function( String reason)?  aborted,}) {final _that = this;
switch (_that) {
case MeridianFlipStarting() when starting != null:
return starting(_that.targetName,_that.fromPierSide,_that.hourAngle);case MeridianFlipStepStarted() when stepStarted != null:
return stepStarted(_that.step,_that.stepIndex,_that.totalSteps);case MeridianFlipStepCompleted() when stepCompleted != null:
return stepCompleted(_that.step,_that.durationSecs);case MeridianFlipStepFailed() when stepFailed != null:
return stepFailed(_that.step,_that.error);case MeridianFlipProgress() when progress != null:
return progress(_that.percent);case MeridianFlipRetryScheduled() when retryScheduled != null:
return retryScheduled(_that.attempt,_that.maxAttempts,_that.delaySecs);case MeridianFlipCompleted() when completed != null:
return completed(_that.newPierSide,_that.durationSecs);case MeridianFlipFailed() when failed != null:
return failed(_that.error,_that.actionTaken);case MeridianFlipAborted() when aborted != null:
return aborted(_that.reason);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class MeridianFlipStarting implements MeridianFlipEvent {
  const MeridianFlipStarting({required this.targetName, required this.fromPierSide, required this.hourAngle, final  String? $type}): $type = $type ?? 'starting';
  factory MeridianFlipStarting.fromJson(Map<String, dynamic> json) => _$MeridianFlipStartingFromJson(json);

 final  String targetName;
 final  PierSide fromPierSide;
 final  double hourAngle;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeridianFlipStartingCopyWith<MeridianFlipStarting> get copyWith => _$MeridianFlipStartingCopyWithImpl<MeridianFlipStarting>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeridianFlipStartingToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeridianFlipStarting&&(identical(other.targetName, targetName) || other.targetName == targetName)&&(identical(other.fromPierSide, fromPierSide) || other.fromPierSide == fromPierSide)&&(identical(other.hourAngle, hourAngle) || other.hourAngle == hourAngle));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,targetName,fromPierSide,hourAngle);

@override
String toString() {
  return 'MeridianFlipEvent.starting(targetName: $targetName, fromPierSide: $fromPierSide, hourAngle: $hourAngle)';
}


}

/// @nodoc
abstract mixin class $MeridianFlipStartingCopyWith<$Res> implements $MeridianFlipEventCopyWith<$Res> {
  factory $MeridianFlipStartingCopyWith(MeridianFlipStarting value, $Res Function(MeridianFlipStarting) _then) = _$MeridianFlipStartingCopyWithImpl;
@useResult
$Res call({
 String targetName, PierSide fromPierSide, double hourAngle
});




}
/// @nodoc
class _$MeridianFlipStartingCopyWithImpl<$Res>
    implements $MeridianFlipStartingCopyWith<$Res> {
  _$MeridianFlipStartingCopyWithImpl(this._self, this._then);

  final MeridianFlipStarting _self;
  final $Res Function(MeridianFlipStarting) _then;

/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? targetName = null,Object? fromPierSide = null,Object? hourAngle = null,}) {
  return _then(MeridianFlipStarting(
targetName: null == targetName ? _self.targetName : targetName // ignore: cast_nullable_to_non_nullable
as String,fromPierSide: null == fromPierSide ? _self.fromPierSide : fromPierSide // ignore: cast_nullable_to_non_nullable
as PierSide,hourAngle: null == hourAngle ? _self.hourAngle : hourAngle // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc
@JsonSerializable()

class MeridianFlipStepStarted implements MeridianFlipEvent {
  const MeridianFlipStepStarted({required this.step, required this.stepIndex, required this.totalSteps, final  String? $type}): $type = $type ?? 'stepStarted';
  factory MeridianFlipStepStarted.fromJson(Map<String, dynamic> json) => _$MeridianFlipStepStartedFromJson(json);

 final  FlipStep step;
 final  int stepIndex;
 final  int totalSteps;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeridianFlipStepStartedCopyWith<MeridianFlipStepStarted> get copyWith => _$MeridianFlipStepStartedCopyWithImpl<MeridianFlipStepStarted>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeridianFlipStepStartedToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeridianFlipStepStarted&&(identical(other.step, step) || other.step == step)&&(identical(other.stepIndex, stepIndex) || other.stepIndex == stepIndex)&&(identical(other.totalSteps, totalSteps) || other.totalSteps == totalSteps));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,step,stepIndex,totalSteps);

@override
String toString() {
  return 'MeridianFlipEvent.stepStarted(step: $step, stepIndex: $stepIndex, totalSteps: $totalSteps)';
}


}

/// @nodoc
abstract mixin class $MeridianFlipStepStartedCopyWith<$Res> implements $MeridianFlipEventCopyWith<$Res> {
  factory $MeridianFlipStepStartedCopyWith(MeridianFlipStepStarted value, $Res Function(MeridianFlipStepStarted) _then) = _$MeridianFlipStepStartedCopyWithImpl;
@useResult
$Res call({
 FlipStep step, int stepIndex, int totalSteps
});




}
/// @nodoc
class _$MeridianFlipStepStartedCopyWithImpl<$Res>
    implements $MeridianFlipStepStartedCopyWith<$Res> {
  _$MeridianFlipStepStartedCopyWithImpl(this._self, this._then);

  final MeridianFlipStepStarted _self;
  final $Res Function(MeridianFlipStepStarted) _then;

/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? step = null,Object? stepIndex = null,Object? totalSteps = null,}) {
  return _then(MeridianFlipStepStarted(
step: null == step ? _self.step : step // ignore: cast_nullable_to_non_nullable
as FlipStep,stepIndex: null == stepIndex ? _self.stepIndex : stepIndex // ignore: cast_nullable_to_non_nullable
as int,totalSteps: null == totalSteps ? _self.totalSteps : totalSteps // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc
@JsonSerializable()

class MeridianFlipStepCompleted implements MeridianFlipEvent {
  const MeridianFlipStepCompleted({required this.step, this.durationSecs, final  String? $type}): $type = $type ?? 'stepCompleted';
  factory MeridianFlipStepCompleted.fromJson(Map<String, dynamic> json) => _$MeridianFlipStepCompletedFromJson(json);

 final  FlipStep step;
 final  double? durationSecs;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeridianFlipStepCompletedCopyWith<MeridianFlipStepCompleted> get copyWith => _$MeridianFlipStepCompletedCopyWithImpl<MeridianFlipStepCompleted>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeridianFlipStepCompletedToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeridianFlipStepCompleted&&(identical(other.step, step) || other.step == step)&&(identical(other.durationSecs, durationSecs) || other.durationSecs == durationSecs));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,step,durationSecs);

@override
String toString() {
  return 'MeridianFlipEvent.stepCompleted(step: $step, durationSecs: $durationSecs)';
}


}

/// @nodoc
abstract mixin class $MeridianFlipStepCompletedCopyWith<$Res> implements $MeridianFlipEventCopyWith<$Res> {
  factory $MeridianFlipStepCompletedCopyWith(MeridianFlipStepCompleted value, $Res Function(MeridianFlipStepCompleted) _then) = _$MeridianFlipStepCompletedCopyWithImpl;
@useResult
$Res call({
 FlipStep step, double? durationSecs
});




}
/// @nodoc
class _$MeridianFlipStepCompletedCopyWithImpl<$Res>
    implements $MeridianFlipStepCompletedCopyWith<$Res> {
  _$MeridianFlipStepCompletedCopyWithImpl(this._self, this._then);

  final MeridianFlipStepCompleted _self;
  final $Res Function(MeridianFlipStepCompleted) _then;

/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? step = null,Object? durationSecs = freezed,}) {
  return _then(MeridianFlipStepCompleted(
step: null == step ? _self.step : step // ignore: cast_nullable_to_non_nullable
as FlipStep,durationSecs: freezed == durationSecs ? _self.durationSecs : durationSecs // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}


}

/// @nodoc
@JsonSerializable()

class MeridianFlipStepFailed implements MeridianFlipEvent {
  const MeridianFlipStepFailed({required this.step, required this.error, final  String? $type}): $type = $type ?? 'stepFailed';
  factory MeridianFlipStepFailed.fromJson(Map<String, dynamic> json) => _$MeridianFlipStepFailedFromJson(json);

 final  FlipStep step;
 final  String error;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeridianFlipStepFailedCopyWith<MeridianFlipStepFailed> get copyWith => _$MeridianFlipStepFailedCopyWithImpl<MeridianFlipStepFailed>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeridianFlipStepFailedToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeridianFlipStepFailed&&(identical(other.step, step) || other.step == step)&&(identical(other.error, error) || other.error == error));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,step,error);

@override
String toString() {
  return 'MeridianFlipEvent.stepFailed(step: $step, error: $error)';
}


}

/// @nodoc
abstract mixin class $MeridianFlipStepFailedCopyWith<$Res> implements $MeridianFlipEventCopyWith<$Res> {
  factory $MeridianFlipStepFailedCopyWith(MeridianFlipStepFailed value, $Res Function(MeridianFlipStepFailed) _then) = _$MeridianFlipStepFailedCopyWithImpl;
@useResult
$Res call({
 FlipStep step, String error
});




}
/// @nodoc
class _$MeridianFlipStepFailedCopyWithImpl<$Res>
    implements $MeridianFlipStepFailedCopyWith<$Res> {
  _$MeridianFlipStepFailedCopyWithImpl(this._self, this._then);

  final MeridianFlipStepFailed _self;
  final $Res Function(MeridianFlipStepFailed) _then;

/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? step = null,Object? error = null,}) {
  return _then(MeridianFlipStepFailed(
step: null == step ? _self.step : step // ignore: cast_nullable_to_non_nullable
as FlipStep,error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
@JsonSerializable()

class MeridianFlipProgress implements MeridianFlipEvent {
  const MeridianFlipProgress({required this.percent, final  String? $type}): $type = $type ?? 'progress';
  factory MeridianFlipProgress.fromJson(Map<String, dynamic> json) => _$MeridianFlipProgressFromJson(json);

 final  int percent;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeridianFlipProgressCopyWith<MeridianFlipProgress> get copyWith => _$MeridianFlipProgressCopyWithImpl<MeridianFlipProgress>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeridianFlipProgressToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeridianFlipProgress&&(identical(other.percent, percent) || other.percent == percent));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,percent);

@override
String toString() {
  return 'MeridianFlipEvent.progress(percent: $percent)';
}


}

/// @nodoc
abstract mixin class $MeridianFlipProgressCopyWith<$Res> implements $MeridianFlipEventCopyWith<$Res> {
  factory $MeridianFlipProgressCopyWith(MeridianFlipProgress value, $Res Function(MeridianFlipProgress) _then) = _$MeridianFlipProgressCopyWithImpl;
@useResult
$Res call({
 int percent
});




}
/// @nodoc
class _$MeridianFlipProgressCopyWithImpl<$Res>
    implements $MeridianFlipProgressCopyWith<$Res> {
  _$MeridianFlipProgressCopyWithImpl(this._self, this._then);

  final MeridianFlipProgress _self;
  final $Res Function(MeridianFlipProgress) _then;

/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? percent = null,}) {
  return _then(MeridianFlipProgress(
percent: null == percent ? _self.percent : percent // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc
@JsonSerializable()

class MeridianFlipRetryScheduled implements MeridianFlipEvent {
  const MeridianFlipRetryScheduled({required this.attempt, required this.maxAttempts, required this.delaySecs, final  String? $type}): $type = $type ?? 'retryScheduled';
  factory MeridianFlipRetryScheduled.fromJson(Map<String, dynamic> json) => _$MeridianFlipRetryScheduledFromJson(json);

 final  int attempt;
 final  int maxAttempts;
 final  double delaySecs;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeridianFlipRetryScheduledCopyWith<MeridianFlipRetryScheduled> get copyWith => _$MeridianFlipRetryScheduledCopyWithImpl<MeridianFlipRetryScheduled>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeridianFlipRetryScheduledToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeridianFlipRetryScheduled&&(identical(other.attempt, attempt) || other.attempt == attempt)&&(identical(other.maxAttempts, maxAttempts) || other.maxAttempts == maxAttempts)&&(identical(other.delaySecs, delaySecs) || other.delaySecs == delaySecs));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,attempt,maxAttempts,delaySecs);

@override
String toString() {
  return 'MeridianFlipEvent.retryScheduled(attempt: $attempt, maxAttempts: $maxAttempts, delaySecs: $delaySecs)';
}


}

/// @nodoc
abstract mixin class $MeridianFlipRetryScheduledCopyWith<$Res> implements $MeridianFlipEventCopyWith<$Res> {
  factory $MeridianFlipRetryScheduledCopyWith(MeridianFlipRetryScheduled value, $Res Function(MeridianFlipRetryScheduled) _then) = _$MeridianFlipRetryScheduledCopyWithImpl;
@useResult
$Res call({
 int attempt, int maxAttempts, double delaySecs
});




}
/// @nodoc
class _$MeridianFlipRetryScheduledCopyWithImpl<$Res>
    implements $MeridianFlipRetryScheduledCopyWith<$Res> {
  _$MeridianFlipRetryScheduledCopyWithImpl(this._self, this._then);

  final MeridianFlipRetryScheduled _self;
  final $Res Function(MeridianFlipRetryScheduled) _then;

/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? attempt = null,Object? maxAttempts = null,Object? delaySecs = null,}) {
  return _then(MeridianFlipRetryScheduled(
attempt: null == attempt ? _self.attempt : attempt // ignore: cast_nullable_to_non_nullable
as int,maxAttempts: null == maxAttempts ? _self.maxAttempts : maxAttempts // ignore: cast_nullable_to_non_nullable
as int,delaySecs: null == delaySecs ? _self.delaySecs : delaySecs // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc
@JsonSerializable()

class MeridianFlipCompleted implements MeridianFlipEvent {
  const MeridianFlipCompleted({required this.newPierSide, required this.durationSecs, final  String? $type}): $type = $type ?? 'completed';
  factory MeridianFlipCompleted.fromJson(Map<String, dynamic> json) => _$MeridianFlipCompletedFromJson(json);

 final  PierSide newPierSide;
 final  double durationSecs;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeridianFlipCompletedCopyWith<MeridianFlipCompleted> get copyWith => _$MeridianFlipCompletedCopyWithImpl<MeridianFlipCompleted>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeridianFlipCompletedToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeridianFlipCompleted&&(identical(other.newPierSide, newPierSide) || other.newPierSide == newPierSide)&&(identical(other.durationSecs, durationSecs) || other.durationSecs == durationSecs));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,newPierSide,durationSecs);

@override
String toString() {
  return 'MeridianFlipEvent.completed(newPierSide: $newPierSide, durationSecs: $durationSecs)';
}


}

/// @nodoc
abstract mixin class $MeridianFlipCompletedCopyWith<$Res> implements $MeridianFlipEventCopyWith<$Res> {
  factory $MeridianFlipCompletedCopyWith(MeridianFlipCompleted value, $Res Function(MeridianFlipCompleted) _then) = _$MeridianFlipCompletedCopyWithImpl;
@useResult
$Res call({
 PierSide newPierSide, double durationSecs
});




}
/// @nodoc
class _$MeridianFlipCompletedCopyWithImpl<$Res>
    implements $MeridianFlipCompletedCopyWith<$Res> {
  _$MeridianFlipCompletedCopyWithImpl(this._self, this._then);

  final MeridianFlipCompleted _self;
  final $Res Function(MeridianFlipCompleted) _then;

/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? newPierSide = null,Object? durationSecs = null,}) {
  return _then(MeridianFlipCompleted(
newPierSide: null == newPierSide ? _self.newPierSide : newPierSide // ignore: cast_nullable_to_non_nullable
as PierSide,durationSecs: null == durationSecs ? _self.durationSecs : durationSecs // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc
@JsonSerializable()

class MeridianFlipFailed implements MeridianFlipEvent {
  const MeridianFlipFailed({required this.error, required this.actionTaken, final  String? $type}): $type = $type ?? 'failed';
  factory MeridianFlipFailed.fromJson(Map<String, dynamic> json) => _$MeridianFlipFailedFromJson(json);

 final  String error;
 final  String actionTaken;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeridianFlipFailedCopyWith<MeridianFlipFailed> get copyWith => _$MeridianFlipFailedCopyWithImpl<MeridianFlipFailed>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeridianFlipFailedToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeridianFlipFailed&&(identical(other.error, error) || other.error == error)&&(identical(other.actionTaken, actionTaken) || other.actionTaken == actionTaken));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,error,actionTaken);

@override
String toString() {
  return 'MeridianFlipEvent.failed(error: $error, actionTaken: $actionTaken)';
}


}

/// @nodoc
abstract mixin class $MeridianFlipFailedCopyWith<$Res> implements $MeridianFlipEventCopyWith<$Res> {
  factory $MeridianFlipFailedCopyWith(MeridianFlipFailed value, $Res Function(MeridianFlipFailed) _then) = _$MeridianFlipFailedCopyWithImpl;
@useResult
$Res call({
 String error, String actionTaken
});




}
/// @nodoc
class _$MeridianFlipFailedCopyWithImpl<$Res>
    implements $MeridianFlipFailedCopyWith<$Res> {
  _$MeridianFlipFailedCopyWithImpl(this._self, this._then);

  final MeridianFlipFailed _self;
  final $Res Function(MeridianFlipFailed) _then;

/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? error = null,Object? actionTaken = null,}) {
  return _then(MeridianFlipFailed(
error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String,actionTaken: null == actionTaken ? _self.actionTaken : actionTaken // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
@JsonSerializable()

class MeridianFlipAborted implements MeridianFlipEvent {
  const MeridianFlipAborted({required this.reason, final  String? $type}): $type = $type ?? 'aborted';
  factory MeridianFlipAborted.fromJson(Map<String, dynamic> json) => _$MeridianFlipAbortedFromJson(json);

 final  String reason;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MeridianFlipAbortedCopyWith<MeridianFlipAborted> get copyWith => _$MeridianFlipAbortedCopyWithImpl<MeridianFlipAborted>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MeridianFlipAbortedToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MeridianFlipAborted&&(identical(other.reason, reason) || other.reason == reason));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'MeridianFlipEvent.aborted(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $MeridianFlipAbortedCopyWith<$Res> implements $MeridianFlipEventCopyWith<$Res> {
  factory $MeridianFlipAbortedCopyWith(MeridianFlipAborted value, $Res Function(MeridianFlipAborted) _then) = _$MeridianFlipAbortedCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$MeridianFlipAbortedCopyWithImpl<$Res>
    implements $MeridianFlipAbortedCopyWith<$Res> {
  _$MeridianFlipAbortedCopyWithImpl(this._self, this._then);

  final MeridianFlipAborted _self;
  final $Res Function(MeridianFlipAborted) _then;

/// Create a copy of MeridianFlipEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(MeridianFlipAborted(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
