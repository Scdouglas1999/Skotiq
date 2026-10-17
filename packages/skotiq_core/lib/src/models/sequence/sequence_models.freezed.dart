// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'sequence_models.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$SequenceOverheadConfig {

/// Time for a slew operation (seconds)
 double get slewSecs;/// Time for an autofocus run (seconds)
 double get autofocusSecs;/// Time for a filter wheel change (seconds)
 double get filterChangeSecs;/// Time for a dither + settle cycle (seconds)
 double get ditherSecs;/// Time for a meridian flip including re-centering (seconds)
 double get meridianFlipSecs;/// Time for guide acquisition and settle (seconds)
 double get guideAcquireSecs;/// Time for a plate solve (seconds)
 double get plateSolveSecs;/// Time for camera cool-down (seconds)
 double get coolingSecs;/// Time for camera warm-up (seconds)
 double get warmingSecs;/// Per-exposure download overhead (seconds)
 double get downloadOverheadPerExposureSecs;/// Time for cover calibrator open/close (seconds)
 double get coverMoveSecs;/// Time for center target operation (plate solve + slew iterations) (seconds)
 double get centerTargetSecs;
/// Create a copy of SequenceOverheadConfig
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequenceOverheadConfigCopyWith<SequenceOverheadConfig> get copyWith => _$SequenceOverheadConfigCopyWithImpl<SequenceOverheadConfig>(this as SequenceOverheadConfig, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequenceOverheadConfig&&(identical(other.slewSecs, slewSecs) || other.slewSecs == slewSecs)&&(identical(other.autofocusSecs, autofocusSecs) || other.autofocusSecs == autofocusSecs)&&(identical(other.filterChangeSecs, filterChangeSecs) || other.filterChangeSecs == filterChangeSecs)&&(identical(other.ditherSecs, ditherSecs) || other.ditherSecs == ditherSecs)&&(identical(other.meridianFlipSecs, meridianFlipSecs) || other.meridianFlipSecs == meridianFlipSecs)&&(identical(other.guideAcquireSecs, guideAcquireSecs) || other.guideAcquireSecs == guideAcquireSecs)&&(identical(other.plateSolveSecs, plateSolveSecs) || other.plateSolveSecs == plateSolveSecs)&&(identical(other.coolingSecs, coolingSecs) || other.coolingSecs == coolingSecs)&&(identical(other.warmingSecs, warmingSecs) || other.warmingSecs == warmingSecs)&&(identical(other.downloadOverheadPerExposureSecs, downloadOverheadPerExposureSecs) || other.downloadOverheadPerExposureSecs == downloadOverheadPerExposureSecs)&&(identical(other.coverMoveSecs, coverMoveSecs) || other.coverMoveSecs == coverMoveSecs)&&(identical(other.centerTargetSecs, centerTargetSecs) || other.centerTargetSecs == centerTargetSecs));
}


@override
int get hashCode => Object.hash(runtimeType,slewSecs,autofocusSecs,filterChangeSecs,ditherSecs,meridianFlipSecs,guideAcquireSecs,plateSolveSecs,coolingSecs,warmingSecs,downloadOverheadPerExposureSecs,coverMoveSecs,centerTargetSecs);

@override
String toString() {
  return 'SequenceOverheadConfig(slewSecs: $slewSecs, autofocusSecs: $autofocusSecs, filterChangeSecs: $filterChangeSecs, ditherSecs: $ditherSecs, meridianFlipSecs: $meridianFlipSecs, guideAcquireSecs: $guideAcquireSecs, plateSolveSecs: $plateSolveSecs, coolingSecs: $coolingSecs, warmingSecs: $warmingSecs, downloadOverheadPerExposureSecs: $downloadOverheadPerExposureSecs, coverMoveSecs: $coverMoveSecs, centerTargetSecs: $centerTargetSecs)';
}


}

/// @nodoc
abstract mixin class $SequenceOverheadConfigCopyWith<$Res>  {
  factory $SequenceOverheadConfigCopyWith(SequenceOverheadConfig value, $Res Function(SequenceOverheadConfig) _then) = _$SequenceOverheadConfigCopyWithImpl;
@useResult
$Res call({
 double slewSecs, double autofocusSecs, double filterChangeSecs, double ditherSecs, double meridianFlipSecs, double guideAcquireSecs, double plateSolveSecs, double coolingSecs, double warmingSecs, double downloadOverheadPerExposureSecs, double coverMoveSecs, double centerTargetSecs
});




}
/// @nodoc
class _$SequenceOverheadConfigCopyWithImpl<$Res>
    implements $SequenceOverheadConfigCopyWith<$Res> {
  _$SequenceOverheadConfigCopyWithImpl(this._self, this._then);

  final SequenceOverheadConfig _self;
  final $Res Function(SequenceOverheadConfig) _then;

/// Create a copy of SequenceOverheadConfig
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? slewSecs = null,Object? autofocusSecs = null,Object? filterChangeSecs = null,Object? ditherSecs = null,Object? meridianFlipSecs = null,Object? guideAcquireSecs = null,Object? plateSolveSecs = null,Object? coolingSecs = null,Object? warmingSecs = null,Object? downloadOverheadPerExposureSecs = null,Object? coverMoveSecs = null,Object? centerTargetSecs = null,}) {
  return _then(_self.copyWith(
slewSecs: null == slewSecs ? _self.slewSecs : slewSecs // ignore: cast_nullable_to_non_nullable
as double,autofocusSecs: null == autofocusSecs ? _self.autofocusSecs : autofocusSecs // ignore: cast_nullable_to_non_nullable
as double,filterChangeSecs: null == filterChangeSecs ? _self.filterChangeSecs : filterChangeSecs // ignore: cast_nullable_to_non_nullable
as double,ditherSecs: null == ditherSecs ? _self.ditherSecs : ditherSecs // ignore: cast_nullable_to_non_nullable
as double,meridianFlipSecs: null == meridianFlipSecs ? _self.meridianFlipSecs : meridianFlipSecs // ignore: cast_nullable_to_non_nullable
as double,guideAcquireSecs: null == guideAcquireSecs ? _self.guideAcquireSecs : guideAcquireSecs // ignore: cast_nullable_to_non_nullable
as double,plateSolveSecs: null == plateSolveSecs ? _self.plateSolveSecs : plateSolveSecs // ignore: cast_nullable_to_non_nullable
as double,coolingSecs: null == coolingSecs ? _self.coolingSecs : coolingSecs // ignore: cast_nullable_to_non_nullable
as double,warmingSecs: null == warmingSecs ? _self.warmingSecs : warmingSecs // ignore: cast_nullable_to_non_nullable
as double,downloadOverheadPerExposureSecs: null == downloadOverheadPerExposureSecs ? _self.downloadOverheadPerExposureSecs : downloadOverheadPerExposureSecs // ignore: cast_nullable_to_non_nullable
as double,coverMoveSecs: null == coverMoveSecs ? _self.coverMoveSecs : coverMoveSecs // ignore: cast_nullable_to_non_nullable
as double,centerTargetSecs: null == centerTargetSecs ? _self.centerTargetSecs : centerTargetSecs // ignore: cast_nullable_to_non_nullable
as double,
  ));
}

}


/// Adds pattern-matching-related methods to [SequenceOverheadConfig].
extension SequenceOverheadConfigPatterns on SequenceOverheadConfig {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SequenceOverheadConfig value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SequenceOverheadConfig() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SequenceOverheadConfig value)  $default,){
final _that = this;
switch (_that) {
case _SequenceOverheadConfig():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SequenceOverheadConfig value)?  $default,){
final _that = this;
switch (_that) {
case _SequenceOverheadConfig() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double slewSecs,  double autofocusSecs,  double filterChangeSecs,  double ditherSecs,  double meridianFlipSecs,  double guideAcquireSecs,  double plateSolveSecs,  double coolingSecs,  double warmingSecs,  double downloadOverheadPerExposureSecs,  double coverMoveSecs,  double centerTargetSecs)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SequenceOverheadConfig() when $default != null:
return $default(_that.slewSecs,_that.autofocusSecs,_that.filterChangeSecs,_that.ditherSecs,_that.meridianFlipSecs,_that.guideAcquireSecs,_that.plateSolveSecs,_that.coolingSecs,_that.warmingSecs,_that.downloadOverheadPerExposureSecs,_that.coverMoveSecs,_that.centerTargetSecs);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double slewSecs,  double autofocusSecs,  double filterChangeSecs,  double ditherSecs,  double meridianFlipSecs,  double guideAcquireSecs,  double plateSolveSecs,  double coolingSecs,  double warmingSecs,  double downloadOverheadPerExposureSecs,  double coverMoveSecs,  double centerTargetSecs)  $default,) {final _that = this;
switch (_that) {
case _SequenceOverheadConfig():
return $default(_that.slewSecs,_that.autofocusSecs,_that.filterChangeSecs,_that.ditherSecs,_that.meridianFlipSecs,_that.guideAcquireSecs,_that.plateSolveSecs,_that.coolingSecs,_that.warmingSecs,_that.downloadOverheadPerExposureSecs,_that.coverMoveSecs,_that.centerTargetSecs);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double slewSecs,  double autofocusSecs,  double filterChangeSecs,  double ditherSecs,  double meridianFlipSecs,  double guideAcquireSecs,  double plateSolveSecs,  double coolingSecs,  double warmingSecs,  double downloadOverheadPerExposureSecs,  double coverMoveSecs,  double centerTargetSecs)?  $default,) {final _that = this;
switch (_that) {
case _SequenceOverheadConfig() when $default != null:
return $default(_that.slewSecs,_that.autofocusSecs,_that.filterChangeSecs,_that.ditherSecs,_that.meridianFlipSecs,_that.guideAcquireSecs,_that.plateSolveSecs,_that.coolingSecs,_that.warmingSecs,_that.downloadOverheadPerExposureSecs,_that.coverMoveSecs,_that.centerTargetSecs);case _:
  return null;

}
}

}

/// @nodoc


class _SequenceOverheadConfig implements SequenceOverheadConfig {
  const _SequenceOverheadConfig({this.slewSecs = 30.0, this.autofocusSecs = 180.0, this.filterChangeSecs = 10.0, this.ditherSecs = 15.0, this.meridianFlipSecs = 300.0, this.guideAcquireSecs = 30.0, this.plateSolveSecs = 15.0, this.coolingSecs = 600.0, this.warmingSecs = 300.0, this.downloadOverheadPerExposureSecs = 3.0, this.coverMoveSecs = 30.0, this.centerTargetSecs = 45.0});
  

/// Time for a slew operation (seconds)
@override@JsonKey() final  double slewSecs;
/// Time for an autofocus run (seconds)
@override@JsonKey() final  double autofocusSecs;
/// Time for a filter wheel change (seconds)
@override@JsonKey() final  double filterChangeSecs;
/// Time for a dither + settle cycle (seconds)
@override@JsonKey() final  double ditherSecs;
/// Time for a meridian flip including re-centering (seconds)
@override@JsonKey() final  double meridianFlipSecs;
/// Time for guide acquisition and settle (seconds)
@override@JsonKey() final  double guideAcquireSecs;
/// Time for a plate solve (seconds)
@override@JsonKey() final  double plateSolveSecs;
/// Time for camera cool-down (seconds)
@override@JsonKey() final  double coolingSecs;
/// Time for camera warm-up (seconds)
@override@JsonKey() final  double warmingSecs;
/// Per-exposure download overhead (seconds)
@override@JsonKey() final  double downloadOverheadPerExposureSecs;
/// Time for cover calibrator open/close (seconds)
@override@JsonKey() final  double coverMoveSecs;
/// Time for center target operation (plate solve + slew iterations) (seconds)
@override@JsonKey() final  double centerTargetSecs;

/// Create a copy of SequenceOverheadConfig
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SequenceOverheadConfigCopyWith<_SequenceOverheadConfig> get copyWith => __$SequenceOverheadConfigCopyWithImpl<_SequenceOverheadConfig>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SequenceOverheadConfig&&(identical(other.slewSecs, slewSecs) || other.slewSecs == slewSecs)&&(identical(other.autofocusSecs, autofocusSecs) || other.autofocusSecs == autofocusSecs)&&(identical(other.filterChangeSecs, filterChangeSecs) || other.filterChangeSecs == filterChangeSecs)&&(identical(other.ditherSecs, ditherSecs) || other.ditherSecs == ditherSecs)&&(identical(other.meridianFlipSecs, meridianFlipSecs) || other.meridianFlipSecs == meridianFlipSecs)&&(identical(other.guideAcquireSecs, guideAcquireSecs) || other.guideAcquireSecs == guideAcquireSecs)&&(identical(other.plateSolveSecs, plateSolveSecs) || other.plateSolveSecs == plateSolveSecs)&&(identical(other.coolingSecs, coolingSecs) || other.coolingSecs == coolingSecs)&&(identical(other.warmingSecs, warmingSecs) || other.warmingSecs == warmingSecs)&&(identical(other.downloadOverheadPerExposureSecs, downloadOverheadPerExposureSecs) || other.downloadOverheadPerExposureSecs == downloadOverheadPerExposureSecs)&&(identical(other.coverMoveSecs, coverMoveSecs) || other.coverMoveSecs == coverMoveSecs)&&(identical(other.centerTargetSecs, centerTargetSecs) || other.centerTargetSecs == centerTargetSecs));
}


@override
int get hashCode => Object.hash(runtimeType,slewSecs,autofocusSecs,filterChangeSecs,ditherSecs,meridianFlipSecs,guideAcquireSecs,plateSolveSecs,coolingSecs,warmingSecs,downloadOverheadPerExposureSecs,coverMoveSecs,centerTargetSecs);

@override
String toString() {
  return 'SequenceOverheadConfig(slewSecs: $slewSecs, autofocusSecs: $autofocusSecs, filterChangeSecs: $filterChangeSecs, ditherSecs: $ditherSecs, meridianFlipSecs: $meridianFlipSecs, guideAcquireSecs: $guideAcquireSecs, plateSolveSecs: $plateSolveSecs, coolingSecs: $coolingSecs, warmingSecs: $warmingSecs, downloadOverheadPerExposureSecs: $downloadOverheadPerExposureSecs, coverMoveSecs: $coverMoveSecs, centerTargetSecs: $centerTargetSecs)';
}


}

/// @nodoc
abstract mixin class _$SequenceOverheadConfigCopyWith<$Res> implements $SequenceOverheadConfigCopyWith<$Res> {
  factory _$SequenceOverheadConfigCopyWith(_SequenceOverheadConfig value, $Res Function(_SequenceOverheadConfig) _then) = __$SequenceOverheadConfigCopyWithImpl;
@override @useResult
$Res call({
 double slewSecs, double autofocusSecs, double filterChangeSecs, double ditherSecs, double meridianFlipSecs, double guideAcquireSecs, double plateSolveSecs, double coolingSecs, double warmingSecs, double downloadOverheadPerExposureSecs, double coverMoveSecs, double centerTargetSecs
});




}
/// @nodoc
class __$SequenceOverheadConfigCopyWithImpl<$Res>
    implements _$SequenceOverheadConfigCopyWith<$Res> {
  __$SequenceOverheadConfigCopyWithImpl(this._self, this._then);

  final _SequenceOverheadConfig _self;
  final $Res Function(_SequenceOverheadConfig) _then;

/// Create a copy of SequenceOverheadConfig
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? slewSecs = null,Object? autofocusSecs = null,Object? filterChangeSecs = null,Object? ditherSecs = null,Object? meridianFlipSecs = null,Object? guideAcquireSecs = null,Object? plateSolveSecs = null,Object? coolingSecs = null,Object? warmingSecs = null,Object? downloadOverheadPerExposureSecs = null,Object? coverMoveSecs = null,Object? centerTargetSecs = null,}) {
  return _then(_SequenceOverheadConfig(
slewSecs: null == slewSecs ? _self.slewSecs : slewSecs // ignore: cast_nullable_to_non_nullable
as double,autofocusSecs: null == autofocusSecs ? _self.autofocusSecs : autofocusSecs // ignore: cast_nullable_to_non_nullable
as double,filterChangeSecs: null == filterChangeSecs ? _self.filterChangeSecs : filterChangeSecs // ignore: cast_nullable_to_non_nullable
as double,ditherSecs: null == ditherSecs ? _self.ditherSecs : ditherSecs // ignore: cast_nullable_to_non_nullable
as double,meridianFlipSecs: null == meridianFlipSecs ? _self.meridianFlipSecs : meridianFlipSecs // ignore: cast_nullable_to_non_nullable
as double,guideAcquireSecs: null == guideAcquireSecs ? _self.guideAcquireSecs : guideAcquireSecs // ignore: cast_nullable_to_non_nullable
as double,plateSolveSecs: null == plateSolveSecs ? _self.plateSolveSecs : plateSolveSecs // ignore: cast_nullable_to_non_nullable
as double,coolingSecs: null == coolingSecs ? _self.coolingSecs : coolingSecs // ignore: cast_nullable_to_non_nullable
as double,warmingSecs: null == warmingSecs ? _self.warmingSecs : warmingSecs // ignore: cast_nullable_to_non_nullable
as double,downloadOverheadPerExposureSecs: null == downloadOverheadPerExposureSecs ? _self.downloadOverheadPerExposureSecs : downloadOverheadPerExposureSecs // ignore: cast_nullable_to_non_nullable
as double,coverMoveSecs: null == coverMoveSecs ? _self.coverMoveSecs : coverMoveSecs // ignore: cast_nullable_to_non_nullable
as double,centerTargetSecs: null == centerTargetSecs ? _self.centerTargetSecs : centerTargetSecs // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc
mixin _$SequenceEstimate {

/// Estimated total integration time in seconds (pure shutter-open time)
 double get estimatedSecs;/// Estimated total overhead time in seconds (slews, AF, dithers, etc.)
 double get overheadSecs;/// Time for a single iteration (useful for unbounded loops)
 double get singleIterationSecs;/// Whether the sequence contains unbounded loops (forever, whileDark, etc.)
 bool get isUnbounded;/// For untilTime loops, the target end time
 DateTime? get untilTime;/// For unbounded loops, the condition type
 LoopConditionType? get conditionType;
/// Create a copy of SequenceEstimate
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequenceEstimateCopyWith<SequenceEstimate> get copyWith => _$SequenceEstimateCopyWithImpl<SequenceEstimate>(this as SequenceEstimate, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequenceEstimate&&(identical(other.estimatedSecs, estimatedSecs) || other.estimatedSecs == estimatedSecs)&&(identical(other.overheadSecs, overheadSecs) || other.overheadSecs == overheadSecs)&&(identical(other.singleIterationSecs, singleIterationSecs) || other.singleIterationSecs == singleIterationSecs)&&(identical(other.isUnbounded, isUnbounded) || other.isUnbounded == isUnbounded)&&(identical(other.untilTime, untilTime) || other.untilTime == untilTime)&&(identical(other.conditionType, conditionType) || other.conditionType == conditionType));
}


@override
int get hashCode => Object.hash(runtimeType,estimatedSecs,overheadSecs,singleIterationSecs,isUnbounded,untilTime,conditionType);

@override
String toString() {
  return 'SequenceEstimate(estimatedSecs: $estimatedSecs, overheadSecs: $overheadSecs, singleIterationSecs: $singleIterationSecs, isUnbounded: $isUnbounded, untilTime: $untilTime, conditionType: $conditionType)';
}


}

/// @nodoc
abstract mixin class $SequenceEstimateCopyWith<$Res>  {
  factory $SequenceEstimateCopyWith(SequenceEstimate value, $Res Function(SequenceEstimate) _then) = _$SequenceEstimateCopyWithImpl;
@useResult
$Res call({
 double estimatedSecs, double overheadSecs, double singleIterationSecs, bool isUnbounded, DateTime? untilTime, LoopConditionType? conditionType
});




}
/// @nodoc
class _$SequenceEstimateCopyWithImpl<$Res>
    implements $SequenceEstimateCopyWith<$Res> {
  _$SequenceEstimateCopyWithImpl(this._self, this._then);

  final SequenceEstimate _self;
  final $Res Function(SequenceEstimate) _then;

/// Create a copy of SequenceEstimate
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? estimatedSecs = null,Object? overheadSecs = null,Object? singleIterationSecs = null,Object? isUnbounded = null,Object? untilTime = freezed,Object? conditionType = freezed,}) {
  return _then(_self.copyWith(
estimatedSecs: null == estimatedSecs ? _self.estimatedSecs : estimatedSecs // ignore: cast_nullable_to_non_nullable
as double,overheadSecs: null == overheadSecs ? _self.overheadSecs : overheadSecs // ignore: cast_nullable_to_non_nullable
as double,singleIterationSecs: null == singleIterationSecs ? _self.singleIterationSecs : singleIterationSecs // ignore: cast_nullable_to_non_nullable
as double,isUnbounded: null == isUnbounded ? _self.isUnbounded : isUnbounded // ignore: cast_nullable_to_non_nullable
as bool,untilTime: freezed == untilTime ? _self.untilTime : untilTime // ignore: cast_nullable_to_non_nullable
as DateTime?,conditionType: freezed == conditionType ? _self.conditionType : conditionType // ignore: cast_nullable_to_non_nullable
as LoopConditionType?,
  ));
}

}


/// Adds pattern-matching-related methods to [SequenceEstimate].
extension SequenceEstimatePatterns on SequenceEstimate {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SequenceEstimate value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SequenceEstimate() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SequenceEstimate value)  $default,){
final _that = this;
switch (_that) {
case _SequenceEstimate():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SequenceEstimate value)?  $default,){
final _that = this;
switch (_that) {
case _SequenceEstimate() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double estimatedSecs,  double overheadSecs,  double singleIterationSecs,  bool isUnbounded,  DateTime? untilTime,  LoopConditionType? conditionType)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SequenceEstimate() when $default != null:
return $default(_that.estimatedSecs,_that.overheadSecs,_that.singleIterationSecs,_that.isUnbounded,_that.untilTime,_that.conditionType);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double estimatedSecs,  double overheadSecs,  double singleIterationSecs,  bool isUnbounded,  DateTime? untilTime,  LoopConditionType? conditionType)  $default,) {final _that = this;
switch (_that) {
case _SequenceEstimate():
return $default(_that.estimatedSecs,_that.overheadSecs,_that.singleIterationSecs,_that.isUnbounded,_that.untilTime,_that.conditionType);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double estimatedSecs,  double overheadSecs,  double singleIterationSecs,  bool isUnbounded,  DateTime? untilTime,  LoopConditionType? conditionType)?  $default,) {final _that = this;
switch (_that) {
case _SequenceEstimate() when $default != null:
return $default(_that.estimatedSecs,_that.overheadSecs,_that.singleIterationSecs,_that.isUnbounded,_that.untilTime,_that.conditionType);case _:
  return null;

}
}

}

/// @nodoc


class _SequenceEstimate extends SequenceEstimate {
  const _SequenceEstimate({required this.estimatedSecs, this.overheadSecs = 0.0, required this.singleIterationSecs, required this.isUnbounded, this.untilTime, this.conditionType}): super._();
  

/// Estimated total integration time in seconds (pure shutter-open time)
@override final  double estimatedSecs;
/// Estimated total overhead time in seconds (slews, AF, dithers, etc.)
@override@JsonKey() final  double overheadSecs;
/// Time for a single iteration (useful for unbounded loops)
@override final  double singleIterationSecs;
/// Whether the sequence contains unbounded loops (forever, whileDark, etc.)
@override final  bool isUnbounded;
/// For untilTime loops, the target end time
@override final  DateTime? untilTime;
/// For unbounded loops, the condition type
@override final  LoopConditionType? conditionType;

/// Create a copy of SequenceEstimate
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SequenceEstimateCopyWith<_SequenceEstimate> get copyWith => __$SequenceEstimateCopyWithImpl<_SequenceEstimate>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SequenceEstimate&&(identical(other.estimatedSecs, estimatedSecs) || other.estimatedSecs == estimatedSecs)&&(identical(other.overheadSecs, overheadSecs) || other.overheadSecs == overheadSecs)&&(identical(other.singleIterationSecs, singleIterationSecs) || other.singleIterationSecs == singleIterationSecs)&&(identical(other.isUnbounded, isUnbounded) || other.isUnbounded == isUnbounded)&&(identical(other.untilTime, untilTime) || other.untilTime == untilTime)&&(identical(other.conditionType, conditionType) || other.conditionType == conditionType));
}


@override
int get hashCode => Object.hash(runtimeType,estimatedSecs,overheadSecs,singleIterationSecs,isUnbounded,untilTime,conditionType);

@override
String toString() {
  return 'SequenceEstimate(estimatedSecs: $estimatedSecs, overheadSecs: $overheadSecs, singleIterationSecs: $singleIterationSecs, isUnbounded: $isUnbounded, untilTime: $untilTime, conditionType: $conditionType)';
}


}

/// @nodoc
abstract mixin class _$SequenceEstimateCopyWith<$Res> implements $SequenceEstimateCopyWith<$Res> {
  factory _$SequenceEstimateCopyWith(_SequenceEstimate value, $Res Function(_SequenceEstimate) _then) = __$SequenceEstimateCopyWithImpl;
@override @useResult
$Res call({
 double estimatedSecs, double overheadSecs, double singleIterationSecs, bool isUnbounded, DateTime? untilTime, LoopConditionType? conditionType
});




}
/// @nodoc
class __$SequenceEstimateCopyWithImpl<$Res>
    implements _$SequenceEstimateCopyWith<$Res> {
  __$SequenceEstimateCopyWithImpl(this._self, this._then);

  final _SequenceEstimate _self;
  final $Res Function(_SequenceEstimate) _then;

/// Create a copy of SequenceEstimate
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? estimatedSecs = null,Object? overheadSecs = null,Object? singleIterationSecs = null,Object? isUnbounded = null,Object? untilTime = freezed,Object? conditionType = freezed,}) {
  return _then(_SequenceEstimate(
estimatedSecs: null == estimatedSecs ? _self.estimatedSecs : estimatedSecs // ignore: cast_nullable_to_non_nullable
as double,overheadSecs: null == overheadSecs ? _self.overheadSecs : overheadSecs // ignore: cast_nullable_to_non_nullable
as double,singleIterationSecs: null == singleIterationSecs ? _self.singleIterationSecs : singleIterationSecs // ignore: cast_nullable_to_non_nullable
as double,isUnbounded: null == isUnbounded ? _self.isUnbounded : isUnbounded // ignore: cast_nullable_to_non_nullable
as bool,untilTime: freezed == untilTime ? _self.untilTime : untilTime // ignore: cast_nullable_to_non_nullable
as DateTime?,conditionType: freezed == conditionType ? _self.conditionType : conditionType // ignore: cast_nullable_to_non_nullable
as LoopConditionType?,
  ));
}


}


/// @nodoc
mixin _$MosaicPanelInfo {

 String get mosaicName; int get panelIndex; int get totalPanels; int get row; int get column;
/// Create a copy of MosaicPanelInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MosaicPanelInfoCopyWith<MosaicPanelInfo> get copyWith => _$MosaicPanelInfoCopyWithImpl<MosaicPanelInfo>(this as MosaicPanelInfo, _$identity);

  /// Serializes this MosaicPanelInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MosaicPanelInfo&&(identical(other.mosaicName, mosaicName) || other.mosaicName == mosaicName)&&(identical(other.panelIndex, panelIndex) || other.panelIndex == panelIndex)&&(identical(other.totalPanels, totalPanels) || other.totalPanels == totalPanels)&&(identical(other.row, row) || other.row == row)&&(identical(other.column, column) || other.column == column));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,mosaicName,panelIndex,totalPanels,row,column);

@override
String toString() {
  return 'MosaicPanelInfo(mosaicName: $mosaicName, panelIndex: $panelIndex, totalPanels: $totalPanels, row: $row, column: $column)';
}


}

/// @nodoc
abstract mixin class $MosaicPanelInfoCopyWith<$Res>  {
  factory $MosaicPanelInfoCopyWith(MosaicPanelInfo value, $Res Function(MosaicPanelInfo) _then) = _$MosaicPanelInfoCopyWithImpl;
@useResult
$Res call({
 String mosaicName, int panelIndex, int totalPanels, int row, int column
});




}
/// @nodoc
class _$MosaicPanelInfoCopyWithImpl<$Res>
    implements $MosaicPanelInfoCopyWith<$Res> {
  _$MosaicPanelInfoCopyWithImpl(this._self, this._then);

  final MosaicPanelInfo _self;
  final $Res Function(MosaicPanelInfo) _then;

/// Create a copy of MosaicPanelInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? mosaicName = null,Object? panelIndex = null,Object? totalPanels = null,Object? row = null,Object? column = null,}) {
  return _then(_self.copyWith(
mosaicName: null == mosaicName ? _self.mosaicName : mosaicName // ignore: cast_nullable_to_non_nullable
as String,panelIndex: null == panelIndex ? _self.panelIndex : panelIndex // ignore: cast_nullable_to_non_nullable
as int,totalPanels: null == totalPanels ? _self.totalPanels : totalPanels // ignore: cast_nullable_to_non_nullable
as int,row: null == row ? _self.row : row // ignore: cast_nullable_to_non_nullable
as int,column: null == column ? _self.column : column // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [MosaicPanelInfo].
extension MosaicPanelInfoPatterns on MosaicPanelInfo {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _MosaicPanelInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _MosaicPanelInfo() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _MosaicPanelInfo value)  $default,){
final _that = this;
switch (_that) {
case _MosaicPanelInfo():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _MosaicPanelInfo value)?  $default,){
final _that = this;
switch (_that) {
case _MosaicPanelInfo() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String mosaicName,  int panelIndex,  int totalPanels,  int row,  int column)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _MosaicPanelInfo() when $default != null:
return $default(_that.mosaicName,_that.panelIndex,_that.totalPanels,_that.row,_that.column);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String mosaicName,  int panelIndex,  int totalPanels,  int row,  int column)  $default,) {final _that = this;
switch (_that) {
case _MosaicPanelInfo():
return $default(_that.mosaicName,_that.panelIndex,_that.totalPanels,_that.row,_that.column);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String mosaicName,  int panelIndex,  int totalPanels,  int row,  int column)?  $default,) {final _that = this;
switch (_that) {
case _MosaicPanelInfo() when $default != null:
return $default(_that.mosaicName,_that.panelIndex,_that.totalPanels,_that.row,_that.column);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake)
class _MosaicPanelInfo extends MosaicPanelInfo {
  const _MosaicPanelInfo({required this.mosaicName, required this.panelIndex, required this.totalPanels, required this.row, required this.column}): super._();
  factory _MosaicPanelInfo.fromJson(Map<String, dynamic> json) => _$MosaicPanelInfoFromJson(json);

@override final  String mosaicName;
@override final  int panelIndex;
@override final  int totalPanels;
@override final  int row;
@override final  int column;

/// Create a copy of MosaicPanelInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$MosaicPanelInfoCopyWith<_MosaicPanelInfo> get copyWith => __$MosaicPanelInfoCopyWithImpl<_MosaicPanelInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MosaicPanelInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _MosaicPanelInfo&&(identical(other.mosaicName, mosaicName) || other.mosaicName == mosaicName)&&(identical(other.panelIndex, panelIndex) || other.panelIndex == panelIndex)&&(identical(other.totalPanels, totalPanels) || other.totalPanels == totalPanels)&&(identical(other.row, row) || other.row == row)&&(identical(other.column, column) || other.column == column));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,mosaicName,panelIndex,totalPanels,row,column);

@override
String toString() {
  return 'MosaicPanelInfo(mosaicName: $mosaicName, panelIndex: $panelIndex, totalPanels: $totalPanels, row: $row, column: $column)';
}


}

/// @nodoc
abstract mixin class _$MosaicPanelInfoCopyWith<$Res> implements $MosaicPanelInfoCopyWith<$Res> {
  factory _$MosaicPanelInfoCopyWith(_MosaicPanelInfo value, $Res Function(_MosaicPanelInfo) _then) = __$MosaicPanelInfoCopyWithImpl;
@override @useResult
$Res call({
 String mosaicName, int panelIndex, int totalPanels, int row, int column
});




}
/// @nodoc
class __$MosaicPanelInfoCopyWithImpl<$Res>
    implements _$MosaicPanelInfoCopyWith<$Res> {
  __$MosaicPanelInfoCopyWithImpl(this._self, this._then);

  final _MosaicPanelInfo _self;
  final $Res Function(_MosaicPanelInfo) _then;

/// Create a copy of MosaicPanelInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? mosaicName = null,Object? panelIndex = null,Object? totalPanels = null,Object? row = null,Object? column = null,}) {
  return _then(_MosaicPanelInfo(
mosaicName: null == mosaicName ? _self.mosaicName : mosaicName // ignore: cast_nullable_to_non_nullable
as String,panelIndex: null == panelIndex ? _self.panelIndex : panelIndex // ignore: cast_nullable_to_non_nullable
as int,totalPanels: null == totalPanels ? _self.totalPanels : totalPanels // ignore: cast_nullable_to_non_nullable
as int,row: null == row ? _self.row : row // ignore: cast_nullable_to_non_nullable
as int,column: null == column ? _self.column : column // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}


/// @nodoc
mixin _$BrightnessTierPreferences {

 double get faintMinScore; double get mediumMinScore; double get brightMinScore;
/// Create a copy of BrightnessTierPreferences
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BrightnessTierPreferencesCopyWith<BrightnessTierPreferences> get copyWith => _$BrightnessTierPreferencesCopyWithImpl<BrightnessTierPreferences>(this as BrightnessTierPreferences, _$identity);

  /// Serializes this BrightnessTierPreferences to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BrightnessTierPreferences&&(identical(other.faintMinScore, faintMinScore) || other.faintMinScore == faintMinScore)&&(identical(other.mediumMinScore, mediumMinScore) || other.mediumMinScore == mediumMinScore)&&(identical(other.brightMinScore, brightMinScore) || other.brightMinScore == brightMinScore));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,faintMinScore,mediumMinScore,brightMinScore);

@override
String toString() {
  return 'BrightnessTierPreferences(faintMinScore: $faintMinScore, mediumMinScore: $mediumMinScore, brightMinScore: $brightMinScore)';
}


}

/// @nodoc
abstract mixin class $BrightnessTierPreferencesCopyWith<$Res>  {
  factory $BrightnessTierPreferencesCopyWith(BrightnessTierPreferences value, $Res Function(BrightnessTierPreferences) _then) = _$BrightnessTierPreferencesCopyWithImpl;
@useResult
$Res call({
 double faintMinScore, double mediumMinScore, double brightMinScore
});




}
/// @nodoc
class _$BrightnessTierPreferencesCopyWithImpl<$Res>
    implements $BrightnessTierPreferencesCopyWith<$Res> {
  _$BrightnessTierPreferencesCopyWithImpl(this._self, this._then);

  final BrightnessTierPreferences _self;
  final $Res Function(BrightnessTierPreferences) _then;

/// Create a copy of BrightnessTierPreferences
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? faintMinScore = null,Object? mediumMinScore = null,Object? brightMinScore = null,}) {
  return _then(_self.copyWith(
faintMinScore: null == faintMinScore ? _self.faintMinScore : faintMinScore // ignore: cast_nullable_to_non_nullable
as double,mediumMinScore: null == mediumMinScore ? _self.mediumMinScore : mediumMinScore // ignore: cast_nullable_to_non_nullable
as double,brightMinScore: null == brightMinScore ? _self.brightMinScore : brightMinScore // ignore: cast_nullable_to_non_nullable
as double,
  ));
}

}


/// Adds pattern-matching-related methods to [BrightnessTierPreferences].
extension BrightnessTierPreferencesPatterns on BrightnessTierPreferences {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _BrightnessTierPreferences value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _BrightnessTierPreferences() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _BrightnessTierPreferences value)  $default,){
final _that = this;
switch (_that) {
case _BrightnessTierPreferences():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _BrightnessTierPreferences value)?  $default,){
final _that = this;
switch (_that) {
case _BrightnessTierPreferences() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double faintMinScore,  double mediumMinScore,  double brightMinScore)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _BrightnessTierPreferences() when $default != null:
return $default(_that.faintMinScore,_that.mediumMinScore,_that.brightMinScore);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double faintMinScore,  double mediumMinScore,  double brightMinScore)  $default,) {final _that = this;
switch (_that) {
case _BrightnessTierPreferences():
return $default(_that.faintMinScore,_that.mediumMinScore,_that.brightMinScore);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double faintMinScore,  double mediumMinScore,  double brightMinScore)?  $default,) {final _that = this;
switch (_that) {
case _BrightnessTierPreferences() when $default != null:
return $default(_that.faintMinScore,_that.mediumMinScore,_that.brightMinScore);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake)
class _BrightnessTierPreferences extends BrightnessTierPreferences {
  const _BrightnessTierPreferences({this.faintMinScore = 70.0, this.mediumMinScore = 50.0, this.brightMinScore = 30.0}): super._();
  factory _BrightnessTierPreferences.fromJson(Map<String, dynamic> json) => _$BrightnessTierPreferencesFromJson(json);

@override@JsonKey() final  double faintMinScore;
@override@JsonKey() final  double mediumMinScore;
@override@JsonKey() final  double brightMinScore;

/// Create a copy of BrightnessTierPreferences
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$BrightnessTierPreferencesCopyWith<_BrightnessTierPreferences> get copyWith => __$BrightnessTierPreferencesCopyWithImpl<_BrightnessTierPreferences>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$BrightnessTierPreferencesToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _BrightnessTierPreferences&&(identical(other.faintMinScore, faintMinScore) || other.faintMinScore == faintMinScore)&&(identical(other.mediumMinScore, mediumMinScore) || other.mediumMinScore == mediumMinScore)&&(identical(other.brightMinScore, brightMinScore) || other.brightMinScore == brightMinScore));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,faintMinScore,mediumMinScore,brightMinScore);

@override
String toString() {
  return 'BrightnessTierPreferences(faintMinScore: $faintMinScore, mediumMinScore: $mediumMinScore, brightMinScore: $brightMinScore)';
}


}

/// @nodoc
abstract mixin class _$BrightnessTierPreferencesCopyWith<$Res> implements $BrightnessTierPreferencesCopyWith<$Res> {
  factory _$BrightnessTierPreferencesCopyWith(_BrightnessTierPreferences value, $Res Function(_BrightnessTierPreferences) _then) = __$BrightnessTierPreferencesCopyWithImpl;
@override @useResult
$Res call({
 double faintMinScore, double mediumMinScore, double brightMinScore
});




}
/// @nodoc
class __$BrightnessTierPreferencesCopyWithImpl<$Res>
    implements _$BrightnessTierPreferencesCopyWith<$Res> {
  __$BrightnessTierPreferencesCopyWithImpl(this._self, this._then);

  final _BrightnessTierPreferences _self;
  final $Res Function(_BrightnessTierPreferences) _then;

/// Create a copy of BrightnessTierPreferences
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? faintMinScore = null,Object? mediumMinScore = null,Object? brightMinScore = null,}) {
  return _then(_BrightnessTierPreferences(
faintMinScore: null == faintMinScore ? _self.faintMinScore : faintMinScore // ignore: cast_nullable_to_non_nullable
as double,mediumMinScore: null == mediumMinScore ? _self.mediumMinScore : mediumMinScore // ignore: cast_nullable_to_non_nullable
as double,brightMinScore: null == brightMinScore ? _self.brightMinScore : brightMinScore // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}


/// @nodoc
mixin _$ConditionsScoreWeights {

 double get transparencyWeight; double get seeingWeight; double get cloudWeight; double get windWeight;
/// Create a copy of ConditionsScoreWeights
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ConditionsScoreWeightsCopyWith<ConditionsScoreWeights> get copyWith => _$ConditionsScoreWeightsCopyWithImpl<ConditionsScoreWeights>(this as ConditionsScoreWeights, _$identity);

  /// Serializes this ConditionsScoreWeights to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ConditionsScoreWeights&&(identical(other.transparencyWeight, transparencyWeight) || other.transparencyWeight == transparencyWeight)&&(identical(other.seeingWeight, seeingWeight) || other.seeingWeight == seeingWeight)&&(identical(other.cloudWeight, cloudWeight) || other.cloudWeight == cloudWeight)&&(identical(other.windWeight, windWeight) || other.windWeight == windWeight));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,transparencyWeight,seeingWeight,cloudWeight,windWeight);

@override
String toString() {
  return 'ConditionsScoreWeights(transparencyWeight: $transparencyWeight, seeingWeight: $seeingWeight, cloudWeight: $cloudWeight, windWeight: $windWeight)';
}


}

/// @nodoc
abstract mixin class $ConditionsScoreWeightsCopyWith<$Res>  {
  factory $ConditionsScoreWeightsCopyWith(ConditionsScoreWeights value, $Res Function(ConditionsScoreWeights) _then) = _$ConditionsScoreWeightsCopyWithImpl;
@useResult
$Res call({
 double transparencyWeight, double seeingWeight, double cloudWeight, double windWeight
});




}
/// @nodoc
class _$ConditionsScoreWeightsCopyWithImpl<$Res>
    implements $ConditionsScoreWeightsCopyWith<$Res> {
  _$ConditionsScoreWeightsCopyWithImpl(this._self, this._then);

  final ConditionsScoreWeights _self;
  final $Res Function(ConditionsScoreWeights) _then;

/// Create a copy of ConditionsScoreWeights
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? transparencyWeight = null,Object? seeingWeight = null,Object? cloudWeight = null,Object? windWeight = null,}) {
  return _then(_self.copyWith(
transparencyWeight: null == transparencyWeight ? _self.transparencyWeight : transparencyWeight // ignore: cast_nullable_to_non_nullable
as double,seeingWeight: null == seeingWeight ? _self.seeingWeight : seeingWeight // ignore: cast_nullable_to_non_nullable
as double,cloudWeight: null == cloudWeight ? _self.cloudWeight : cloudWeight // ignore: cast_nullable_to_non_nullable
as double,windWeight: null == windWeight ? _self.windWeight : windWeight // ignore: cast_nullable_to_non_nullable
as double,
  ));
}

}


/// Adds pattern-matching-related methods to [ConditionsScoreWeights].
extension ConditionsScoreWeightsPatterns on ConditionsScoreWeights {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ConditionsScoreWeights value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ConditionsScoreWeights() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ConditionsScoreWeights value)  $default,){
final _that = this;
switch (_that) {
case _ConditionsScoreWeights():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ConditionsScoreWeights value)?  $default,){
final _that = this;
switch (_that) {
case _ConditionsScoreWeights() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double transparencyWeight,  double seeingWeight,  double cloudWeight,  double windWeight)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ConditionsScoreWeights() when $default != null:
return $default(_that.transparencyWeight,_that.seeingWeight,_that.cloudWeight,_that.windWeight);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double transparencyWeight,  double seeingWeight,  double cloudWeight,  double windWeight)  $default,) {final _that = this;
switch (_that) {
case _ConditionsScoreWeights():
return $default(_that.transparencyWeight,_that.seeingWeight,_that.cloudWeight,_that.windWeight);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double transparencyWeight,  double seeingWeight,  double cloudWeight,  double windWeight)?  $default,) {final _that = this;
switch (_that) {
case _ConditionsScoreWeights() when $default != null:
return $default(_that.transparencyWeight,_that.seeingWeight,_that.cloudWeight,_that.windWeight);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake)
class _ConditionsScoreWeights extends ConditionsScoreWeights {
  const _ConditionsScoreWeights({this.transparencyWeight = 0.40, this.seeingWeight = 0.25, this.cloudWeight = 0.25, this.windWeight = 0.10}): super._();
  factory _ConditionsScoreWeights.fromJson(Map<String, dynamic> json) => _$ConditionsScoreWeightsFromJson(json);

@override@JsonKey() final  double transparencyWeight;
@override@JsonKey() final  double seeingWeight;
@override@JsonKey() final  double cloudWeight;
@override@JsonKey() final  double windWeight;

/// Create a copy of ConditionsScoreWeights
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ConditionsScoreWeightsCopyWith<_ConditionsScoreWeights> get copyWith => __$ConditionsScoreWeightsCopyWithImpl<_ConditionsScoreWeights>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ConditionsScoreWeightsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ConditionsScoreWeights&&(identical(other.transparencyWeight, transparencyWeight) || other.transparencyWeight == transparencyWeight)&&(identical(other.seeingWeight, seeingWeight) || other.seeingWeight == seeingWeight)&&(identical(other.cloudWeight, cloudWeight) || other.cloudWeight == cloudWeight)&&(identical(other.windWeight, windWeight) || other.windWeight == windWeight));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,transparencyWeight,seeingWeight,cloudWeight,windWeight);

@override
String toString() {
  return 'ConditionsScoreWeights(transparencyWeight: $transparencyWeight, seeingWeight: $seeingWeight, cloudWeight: $cloudWeight, windWeight: $windWeight)';
}


}

/// @nodoc
abstract mixin class _$ConditionsScoreWeightsCopyWith<$Res> implements $ConditionsScoreWeightsCopyWith<$Res> {
  factory _$ConditionsScoreWeightsCopyWith(_ConditionsScoreWeights value, $Res Function(_ConditionsScoreWeights) _then) = __$ConditionsScoreWeightsCopyWithImpl;
@override @useResult
$Res call({
 double transparencyWeight, double seeingWeight, double cloudWeight, double windWeight
});




}
/// @nodoc
class __$ConditionsScoreWeightsCopyWithImpl<$Res>
    implements _$ConditionsScoreWeightsCopyWith<$Res> {
  __$ConditionsScoreWeightsCopyWithImpl(this._self, this._then);

  final _ConditionsScoreWeights _self;
  final $Res Function(_ConditionsScoreWeights) _then;

/// Create a copy of ConditionsScoreWeights
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? transparencyWeight = null,Object? seeingWeight = null,Object? cloudWeight = null,Object? windWeight = null,}) {
  return _then(_ConditionsScoreWeights(
transparencyWeight: null == transparencyWeight ? _self.transparencyWeight : transparencyWeight // ignore: cast_nullable_to_non_nullable
as double,seeingWeight: null == seeingWeight ? _self.seeingWeight : seeingWeight // ignore: cast_nullable_to_non_nullable
as double,cloudWeight: null == cloudWeight ? _self.cloudWeight : cloudWeight // ignore: cast_nullable_to_non_nullable
as double,windWeight: null == windWeight ? _self.windWeight : windWeight // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}


/// @nodoc
mixin _$ConditionsScore {

 double get score; double? get transparencyScore; double? get seeingScore; double? get cloudScore; double? get windScore; ConditionsScoreWeights get weights;// `generated_unix_secs` (int seconds) on the wire. The Rust side uses
// `serde_with::TimestampSeconds<i64>`. The field is required rather than
// defaulting to `0` (epoch), so a missing key throws instead of decoding
// into a fabricated timestamp. The Rust producer always emits it, so only
// synthetic JSON can hit that path.
@JsonKey(name: 'generated_unix_secs')@UnixSecsDateTimeConverter() DateTime get generatedAt;
/// Create a copy of ConditionsScore
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ConditionsScoreCopyWith<ConditionsScore> get copyWith => _$ConditionsScoreCopyWithImpl<ConditionsScore>(this as ConditionsScore, _$identity);

  /// Serializes this ConditionsScore to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ConditionsScore&&(identical(other.score, score) || other.score == score)&&(identical(other.transparencyScore, transparencyScore) || other.transparencyScore == transparencyScore)&&(identical(other.seeingScore, seeingScore) || other.seeingScore == seeingScore)&&(identical(other.cloudScore, cloudScore) || other.cloudScore == cloudScore)&&(identical(other.windScore, windScore) || other.windScore == windScore)&&(identical(other.weights, weights) || other.weights == weights)&&(identical(other.generatedAt, generatedAt) || other.generatedAt == generatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,score,transparencyScore,seeingScore,cloudScore,windScore,weights,generatedAt);

@override
String toString() {
  return 'ConditionsScore(score: $score, transparencyScore: $transparencyScore, seeingScore: $seeingScore, cloudScore: $cloudScore, windScore: $windScore, weights: $weights, generatedAt: $generatedAt)';
}


}

/// @nodoc
abstract mixin class $ConditionsScoreCopyWith<$Res>  {
  factory $ConditionsScoreCopyWith(ConditionsScore value, $Res Function(ConditionsScore) _then) = _$ConditionsScoreCopyWithImpl;
@useResult
$Res call({
 double score, double? transparencyScore, double? seeingScore, double? cloudScore, double? windScore, ConditionsScoreWeights weights,@JsonKey(name: 'generated_unix_secs')@UnixSecsDateTimeConverter() DateTime generatedAt
});


$ConditionsScoreWeightsCopyWith<$Res> get weights;

}
/// @nodoc
class _$ConditionsScoreCopyWithImpl<$Res>
    implements $ConditionsScoreCopyWith<$Res> {
  _$ConditionsScoreCopyWithImpl(this._self, this._then);

  final ConditionsScore _self;
  final $Res Function(ConditionsScore) _then;

/// Create a copy of ConditionsScore
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? score = null,Object? transparencyScore = freezed,Object? seeingScore = freezed,Object? cloudScore = freezed,Object? windScore = freezed,Object? weights = null,Object? generatedAt = null,}) {
  return _then(_self.copyWith(
score: null == score ? _self.score : score // ignore: cast_nullable_to_non_nullable
as double,transparencyScore: freezed == transparencyScore ? _self.transparencyScore : transparencyScore // ignore: cast_nullable_to_non_nullable
as double?,seeingScore: freezed == seeingScore ? _self.seeingScore : seeingScore // ignore: cast_nullable_to_non_nullable
as double?,cloudScore: freezed == cloudScore ? _self.cloudScore : cloudScore // ignore: cast_nullable_to_non_nullable
as double?,windScore: freezed == windScore ? _self.windScore : windScore // ignore: cast_nullable_to_non_nullable
as double?,weights: null == weights ? _self.weights : weights // ignore: cast_nullable_to_non_nullable
as ConditionsScoreWeights,generatedAt: null == generatedAt ? _self.generatedAt : generatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}
/// Create a copy of ConditionsScore
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ConditionsScoreWeightsCopyWith<$Res> get weights {
  
  return $ConditionsScoreWeightsCopyWith<$Res>(_self.weights, (value) {
    return _then(_self.copyWith(weights: value));
  });
}
}


/// Adds pattern-matching-related methods to [ConditionsScore].
extension ConditionsScorePatterns on ConditionsScore {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ConditionsScore value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ConditionsScore() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ConditionsScore value)  $default,){
final _that = this;
switch (_that) {
case _ConditionsScore():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ConditionsScore value)?  $default,){
final _that = this;
switch (_that) {
case _ConditionsScore() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double score,  double? transparencyScore,  double? seeingScore,  double? cloudScore,  double? windScore,  ConditionsScoreWeights weights, @JsonKey(name: 'generated_unix_secs')@UnixSecsDateTimeConverter()  DateTime generatedAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ConditionsScore() when $default != null:
return $default(_that.score,_that.transparencyScore,_that.seeingScore,_that.cloudScore,_that.windScore,_that.weights,_that.generatedAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double score,  double? transparencyScore,  double? seeingScore,  double? cloudScore,  double? windScore,  ConditionsScoreWeights weights, @JsonKey(name: 'generated_unix_secs')@UnixSecsDateTimeConverter()  DateTime generatedAt)  $default,) {final _that = this;
switch (_that) {
case _ConditionsScore():
return $default(_that.score,_that.transparencyScore,_that.seeingScore,_that.cloudScore,_that.windScore,_that.weights,_that.generatedAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double score,  double? transparencyScore,  double? seeingScore,  double? cloudScore,  double? windScore,  ConditionsScoreWeights weights, @JsonKey(name: 'generated_unix_secs')@UnixSecsDateTimeConverter()  DateTime generatedAt)?  $default,) {final _that = this;
switch (_that) {
case _ConditionsScore() when $default != null:
return $default(_that.score,_that.transparencyScore,_that.seeingScore,_that.cloudScore,_that.windScore,_that.weights,_that.generatedAt);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class _ConditionsScore extends ConditionsScore {
  const _ConditionsScore({required this.score, this.transparencyScore, this.seeingScore, this.cloudScore, this.windScore, this.weights = const ConditionsScoreWeights(), @JsonKey(name: 'generated_unix_secs')@UnixSecsDateTimeConverter() required this.generatedAt}): super._();
  factory _ConditionsScore.fromJson(Map<String, dynamic> json) => _$ConditionsScoreFromJson(json);

@override final  double score;
@override final  double? transparencyScore;
@override final  double? seeingScore;
@override final  double? cloudScore;
@override final  double? windScore;
@override@JsonKey() final  ConditionsScoreWeights weights;
// `generated_unix_secs` (int seconds) on the wire. The Rust side uses
// `serde_with::TimestampSeconds<i64>`. The field is required rather than
// defaulting to `0` (epoch), so a missing key throws instead of decoding
// into a fabricated timestamp. The Rust producer always emits it, so only
// synthetic JSON can hit that path.
@override@JsonKey(name: 'generated_unix_secs')@UnixSecsDateTimeConverter() final  DateTime generatedAt;

/// Create a copy of ConditionsScore
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ConditionsScoreCopyWith<_ConditionsScore> get copyWith => __$ConditionsScoreCopyWithImpl<_ConditionsScore>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ConditionsScoreToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ConditionsScore&&(identical(other.score, score) || other.score == score)&&(identical(other.transparencyScore, transparencyScore) || other.transparencyScore == transparencyScore)&&(identical(other.seeingScore, seeingScore) || other.seeingScore == seeingScore)&&(identical(other.cloudScore, cloudScore) || other.cloudScore == cloudScore)&&(identical(other.windScore, windScore) || other.windScore == windScore)&&(identical(other.weights, weights) || other.weights == weights)&&(identical(other.generatedAt, generatedAt) || other.generatedAt == generatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,score,transparencyScore,seeingScore,cloudScore,windScore,weights,generatedAt);

@override
String toString() {
  return 'ConditionsScore(score: $score, transparencyScore: $transparencyScore, seeingScore: $seeingScore, cloudScore: $cloudScore, windScore: $windScore, weights: $weights, generatedAt: $generatedAt)';
}


}

/// @nodoc
abstract mixin class _$ConditionsScoreCopyWith<$Res> implements $ConditionsScoreCopyWith<$Res> {
  factory _$ConditionsScoreCopyWith(_ConditionsScore value, $Res Function(_ConditionsScore) _then) = __$ConditionsScoreCopyWithImpl;
@override @useResult
$Res call({
 double score, double? transparencyScore, double? seeingScore, double? cloudScore, double? windScore, ConditionsScoreWeights weights,@JsonKey(name: 'generated_unix_secs')@UnixSecsDateTimeConverter() DateTime generatedAt
});


@override $ConditionsScoreWeightsCopyWith<$Res> get weights;

}
/// @nodoc
class __$ConditionsScoreCopyWithImpl<$Res>
    implements _$ConditionsScoreCopyWith<$Res> {
  __$ConditionsScoreCopyWithImpl(this._self, this._then);

  final _ConditionsScore _self;
  final $Res Function(_ConditionsScore) _then;

/// Create a copy of ConditionsScore
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? score = null,Object? transparencyScore = freezed,Object? seeingScore = freezed,Object? cloudScore = freezed,Object? windScore = freezed,Object? weights = null,Object? generatedAt = null,}) {
  return _then(_ConditionsScore(
score: null == score ? _self.score : score // ignore: cast_nullable_to_non_nullable
as double,transparencyScore: freezed == transparencyScore ? _self.transparencyScore : transparencyScore // ignore: cast_nullable_to_non_nullable
as double?,seeingScore: freezed == seeingScore ? _self.seeingScore : seeingScore // ignore: cast_nullable_to_non_nullable
as double?,cloudScore: freezed == cloudScore ? _self.cloudScore : cloudScore // ignore: cast_nullable_to_non_nullable
as double?,windScore: freezed == windScore ? _self.windScore : windScore // ignore: cast_nullable_to_non_nullable
as double?,weights: null == weights ? _self.weights : weights // ignore: cast_nullable_to_non_nullable
as ConditionsScoreWeights,generatedAt: null == generatedAt ? _self.generatedAt : generatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}

/// Create a copy of ConditionsScore
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ConditionsScoreWeightsCopyWith<$Res> get weights {
  
  return $ConditionsScoreWeightsCopyWith<$Res>(_self.weights, (value) {
    return _then(_self.copyWith(weights: value));
  });
}
}


/// @nodoc
mixin _$AdaptiveSwapRuntimeState {

 String? get currentTargetId; String? get currentTier; String? get lastDecisionKind; String? get lastDecisionReason;// `last_swap_unix_secs` (nullable int seconds). When `null`, the
// JSON field is present-with-null (not omitted) — Phase 1's
// `null_last_swap_serialises_as_null_field` contract test pins this.
@JsonKey(name: 'last_swap_unix_secs')@NullableUnixSecsDateTimeConverter() DateTime? get lastSwapAt; String? get lastSwapFromTargetId; String? get lastSwapToTargetId; double? get lastObservedScore; double? get configuredThreshold; double get configuredHysteresisSecs;
/// Create a copy of AdaptiveSwapRuntimeState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AdaptiveSwapRuntimeStateCopyWith<AdaptiveSwapRuntimeState> get copyWith => _$AdaptiveSwapRuntimeStateCopyWithImpl<AdaptiveSwapRuntimeState>(this as AdaptiveSwapRuntimeState, _$identity);

  /// Serializes this AdaptiveSwapRuntimeState to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AdaptiveSwapRuntimeState&&(identical(other.currentTargetId, currentTargetId) || other.currentTargetId == currentTargetId)&&(identical(other.currentTier, currentTier) || other.currentTier == currentTier)&&(identical(other.lastDecisionKind, lastDecisionKind) || other.lastDecisionKind == lastDecisionKind)&&(identical(other.lastDecisionReason, lastDecisionReason) || other.lastDecisionReason == lastDecisionReason)&&(identical(other.lastSwapAt, lastSwapAt) || other.lastSwapAt == lastSwapAt)&&(identical(other.lastSwapFromTargetId, lastSwapFromTargetId) || other.lastSwapFromTargetId == lastSwapFromTargetId)&&(identical(other.lastSwapToTargetId, lastSwapToTargetId) || other.lastSwapToTargetId == lastSwapToTargetId)&&(identical(other.lastObservedScore, lastObservedScore) || other.lastObservedScore == lastObservedScore)&&(identical(other.configuredThreshold, configuredThreshold) || other.configuredThreshold == configuredThreshold)&&(identical(other.configuredHysteresisSecs, configuredHysteresisSecs) || other.configuredHysteresisSecs == configuredHysteresisSecs));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,currentTargetId,currentTier,lastDecisionKind,lastDecisionReason,lastSwapAt,lastSwapFromTargetId,lastSwapToTargetId,lastObservedScore,configuredThreshold,configuredHysteresisSecs);

@override
String toString() {
  return 'AdaptiveSwapRuntimeState(currentTargetId: $currentTargetId, currentTier: $currentTier, lastDecisionKind: $lastDecisionKind, lastDecisionReason: $lastDecisionReason, lastSwapAt: $lastSwapAt, lastSwapFromTargetId: $lastSwapFromTargetId, lastSwapToTargetId: $lastSwapToTargetId, lastObservedScore: $lastObservedScore, configuredThreshold: $configuredThreshold, configuredHysteresisSecs: $configuredHysteresisSecs)';
}


}

/// @nodoc
abstract mixin class $AdaptiveSwapRuntimeStateCopyWith<$Res>  {
  factory $AdaptiveSwapRuntimeStateCopyWith(AdaptiveSwapRuntimeState value, $Res Function(AdaptiveSwapRuntimeState) _then) = _$AdaptiveSwapRuntimeStateCopyWithImpl;
@useResult
$Res call({
 String? currentTargetId, String? currentTier, String? lastDecisionKind, String? lastDecisionReason,@JsonKey(name: 'last_swap_unix_secs')@NullableUnixSecsDateTimeConverter() DateTime? lastSwapAt, String? lastSwapFromTargetId, String? lastSwapToTargetId, double? lastObservedScore, double? configuredThreshold, double configuredHysteresisSecs
});




}
/// @nodoc
class _$AdaptiveSwapRuntimeStateCopyWithImpl<$Res>
    implements $AdaptiveSwapRuntimeStateCopyWith<$Res> {
  _$AdaptiveSwapRuntimeStateCopyWithImpl(this._self, this._then);

  final AdaptiveSwapRuntimeState _self;
  final $Res Function(AdaptiveSwapRuntimeState) _then;

/// Create a copy of AdaptiveSwapRuntimeState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? currentTargetId = freezed,Object? currentTier = freezed,Object? lastDecisionKind = freezed,Object? lastDecisionReason = freezed,Object? lastSwapAt = freezed,Object? lastSwapFromTargetId = freezed,Object? lastSwapToTargetId = freezed,Object? lastObservedScore = freezed,Object? configuredThreshold = freezed,Object? configuredHysteresisSecs = null,}) {
  return _then(_self.copyWith(
currentTargetId: freezed == currentTargetId ? _self.currentTargetId : currentTargetId // ignore: cast_nullable_to_non_nullable
as String?,currentTier: freezed == currentTier ? _self.currentTier : currentTier // ignore: cast_nullable_to_non_nullable
as String?,lastDecisionKind: freezed == lastDecisionKind ? _self.lastDecisionKind : lastDecisionKind // ignore: cast_nullable_to_non_nullable
as String?,lastDecisionReason: freezed == lastDecisionReason ? _self.lastDecisionReason : lastDecisionReason // ignore: cast_nullable_to_non_nullable
as String?,lastSwapAt: freezed == lastSwapAt ? _self.lastSwapAt : lastSwapAt // ignore: cast_nullable_to_non_nullable
as DateTime?,lastSwapFromTargetId: freezed == lastSwapFromTargetId ? _self.lastSwapFromTargetId : lastSwapFromTargetId // ignore: cast_nullable_to_non_nullable
as String?,lastSwapToTargetId: freezed == lastSwapToTargetId ? _self.lastSwapToTargetId : lastSwapToTargetId // ignore: cast_nullable_to_non_nullable
as String?,lastObservedScore: freezed == lastObservedScore ? _self.lastObservedScore : lastObservedScore // ignore: cast_nullable_to_non_nullable
as double?,configuredThreshold: freezed == configuredThreshold ? _self.configuredThreshold : configuredThreshold // ignore: cast_nullable_to_non_nullable
as double?,configuredHysteresisSecs: null == configuredHysteresisSecs ? _self.configuredHysteresisSecs : configuredHysteresisSecs // ignore: cast_nullable_to_non_nullable
as double,
  ));
}

}


/// Adds pattern-matching-related methods to [AdaptiveSwapRuntimeState].
extension AdaptiveSwapRuntimeStatePatterns on AdaptiveSwapRuntimeState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AdaptiveSwapRuntimeState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AdaptiveSwapRuntimeState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AdaptiveSwapRuntimeState value)  $default,){
final _that = this;
switch (_that) {
case _AdaptiveSwapRuntimeState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AdaptiveSwapRuntimeState value)?  $default,){
final _that = this;
switch (_that) {
case _AdaptiveSwapRuntimeState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? currentTargetId,  String? currentTier,  String? lastDecisionKind,  String? lastDecisionReason, @JsonKey(name: 'last_swap_unix_secs')@NullableUnixSecsDateTimeConverter()  DateTime? lastSwapAt,  String? lastSwapFromTargetId,  String? lastSwapToTargetId,  double? lastObservedScore,  double? configuredThreshold,  double configuredHysteresisSecs)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AdaptiveSwapRuntimeState() when $default != null:
return $default(_that.currentTargetId,_that.currentTier,_that.lastDecisionKind,_that.lastDecisionReason,_that.lastSwapAt,_that.lastSwapFromTargetId,_that.lastSwapToTargetId,_that.lastObservedScore,_that.configuredThreshold,_that.configuredHysteresisSecs);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? currentTargetId,  String? currentTier,  String? lastDecisionKind,  String? lastDecisionReason, @JsonKey(name: 'last_swap_unix_secs')@NullableUnixSecsDateTimeConverter()  DateTime? lastSwapAt,  String? lastSwapFromTargetId,  String? lastSwapToTargetId,  double? lastObservedScore,  double? configuredThreshold,  double configuredHysteresisSecs)  $default,) {final _that = this;
switch (_that) {
case _AdaptiveSwapRuntimeState():
return $default(_that.currentTargetId,_that.currentTier,_that.lastDecisionKind,_that.lastDecisionReason,_that.lastSwapAt,_that.lastSwapFromTargetId,_that.lastSwapToTargetId,_that.lastObservedScore,_that.configuredThreshold,_that.configuredHysteresisSecs);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? currentTargetId,  String? currentTier,  String? lastDecisionKind,  String? lastDecisionReason, @JsonKey(name: 'last_swap_unix_secs')@NullableUnixSecsDateTimeConverter()  DateTime? lastSwapAt,  String? lastSwapFromTargetId,  String? lastSwapToTargetId,  double? lastObservedScore,  double? configuredThreshold,  double configuredHysteresisSecs)?  $default,) {final _that = this;
switch (_that) {
case _AdaptiveSwapRuntimeState() when $default != null:
return $default(_that.currentTargetId,_that.currentTier,_that.lastDecisionKind,_that.lastDecisionReason,_that.lastSwapAt,_that.lastSwapFromTargetId,_that.lastSwapToTargetId,_that.lastObservedScore,_that.configuredThreshold,_that.configuredHysteresisSecs);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake, includeIfNull: true)
class _AdaptiveSwapRuntimeState extends AdaptiveSwapRuntimeState {
  const _AdaptiveSwapRuntimeState({this.currentTargetId, this.currentTier, this.lastDecisionKind, this.lastDecisionReason, @JsonKey(name: 'last_swap_unix_secs')@NullableUnixSecsDateTimeConverter() this.lastSwapAt, this.lastSwapFromTargetId, this.lastSwapToTargetId, this.lastObservedScore, this.configuredThreshold, this.configuredHysteresisSecs = 180.0}): super._();
  factory _AdaptiveSwapRuntimeState.fromJson(Map<String, dynamic> json) => _$AdaptiveSwapRuntimeStateFromJson(json);

@override final  String? currentTargetId;
@override final  String? currentTier;
@override final  String? lastDecisionKind;
@override final  String? lastDecisionReason;
// `last_swap_unix_secs` (nullable int seconds). When `null`, the
// JSON field is present-with-null (not omitted) — Phase 1's
// `null_last_swap_serialises_as_null_field` contract test pins this.
@override@JsonKey(name: 'last_swap_unix_secs')@NullableUnixSecsDateTimeConverter() final  DateTime? lastSwapAt;
@override final  String? lastSwapFromTargetId;
@override final  String? lastSwapToTargetId;
@override final  double? lastObservedScore;
@override final  double? configuredThreshold;
@override@JsonKey() final  double configuredHysteresisSecs;

/// Create a copy of AdaptiveSwapRuntimeState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AdaptiveSwapRuntimeStateCopyWith<_AdaptiveSwapRuntimeState> get copyWith => __$AdaptiveSwapRuntimeStateCopyWithImpl<_AdaptiveSwapRuntimeState>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AdaptiveSwapRuntimeStateToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AdaptiveSwapRuntimeState&&(identical(other.currentTargetId, currentTargetId) || other.currentTargetId == currentTargetId)&&(identical(other.currentTier, currentTier) || other.currentTier == currentTier)&&(identical(other.lastDecisionKind, lastDecisionKind) || other.lastDecisionKind == lastDecisionKind)&&(identical(other.lastDecisionReason, lastDecisionReason) || other.lastDecisionReason == lastDecisionReason)&&(identical(other.lastSwapAt, lastSwapAt) || other.lastSwapAt == lastSwapAt)&&(identical(other.lastSwapFromTargetId, lastSwapFromTargetId) || other.lastSwapFromTargetId == lastSwapFromTargetId)&&(identical(other.lastSwapToTargetId, lastSwapToTargetId) || other.lastSwapToTargetId == lastSwapToTargetId)&&(identical(other.lastObservedScore, lastObservedScore) || other.lastObservedScore == lastObservedScore)&&(identical(other.configuredThreshold, configuredThreshold) || other.configuredThreshold == configuredThreshold)&&(identical(other.configuredHysteresisSecs, configuredHysteresisSecs) || other.configuredHysteresisSecs == configuredHysteresisSecs));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,currentTargetId,currentTier,lastDecisionKind,lastDecisionReason,lastSwapAt,lastSwapFromTargetId,lastSwapToTargetId,lastObservedScore,configuredThreshold,configuredHysteresisSecs);

@override
String toString() {
  return 'AdaptiveSwapRuntimeState(currentTargetId: $currentTargetId, currentTier: $currentTier, lastDecisionKind: $lastDecisionKind, lastDecisionReason: $lastDecisionReason, lastSwapAt: $lastSwapAt, lastSwapFromTargetId: $lastSwapFromTargetId, lastSwapToTargetId: $lastSwapToTargetId, lastObservedScore: $lastObservedScore, configuredThreshold: $configuredThreshold, configuredHysteresisSecs: $configuredHysteresisSecs)';
}


}

/// @nodoc
abstract mixin class _$AdaptiveSwapRuntimeStateCopyWith<$Res> implements $AdaptiveSwapRuntimeStateCopyWith<$Res> {
  factory _$AdaptiveSwapRuntimeStateCopyWith(_AdaptiveSwapRuntimeState value, $Res Function(_AdaptiveSwapRuntimeState) _then) = __$AdaptiveSwapRuntimeStateCopyWithImpl;
@override @useResult
$Res call({
 String? currentTargetId, String? currentTier, String? lastDecisionKind, String? lastDecisionReason,@JsonKey(name: 'last_swap_unix_secs')@NullableUnixSecsDateTimeConverter() DateTime? lastSwapAt, String? lastSwapFromTargetId, String? lastSwapToTargetId, double? lastObservedScore, double? configuredThreshold, double configuredHysteresisSecs
});




}
/// @nodoc
class __$AdaptiveSwapRuntimeStateCopyWithImpl<$Res>
    implements _$AdaptiveSwapRuntimeStateCopyWith<$Res> {
  __$AdaptiveSwapRuntimeStateCopyWithImpl(this._self, this._then);

  final _AdaptiveSwapRuntimeState _self;
  final $Res Function(_AdaptiveSwapRuntimeState) _then;

/// Create a copy of AdaptiveSwapRuntimeState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? currentTargetId = freezed,Object? currentTier = freezed,Object? lastDecisionKind = freezed,Object? lastDecisionReason = freezed,Object? lastSwapAt = freezed,Object? lastSwapFromTargetId = freezed,Object? lastSwapToTargetId = freezed,Object? lastObservedScore = freezed,Object? configuredThreshold = freezed,Object? configuredHysteresisSecs = null,}) {
  return _then(_AdaptiveSwapRuntimeState(
currentTargetId: freezed == currentTargetId ? _self.currentTargetId : currentTargetId // ignore: cast_nullable_to_non_nullable
as String?,currentTier: freezed == currentTier ? _self.currentTier : currentTier // ignore: cast_nullable_to_non_nullable
as String?,lastDecisionKind: freezed == lastDecisionKind ? _self.lastDecisionKind : lastDecisionKind // ignore: cast_nullable_to_non_nullable
as String?,lastDecisionReason: freezed == lastDecisionReason ? _self.lastDecisionReason : lastDecisionReason // ignore: cast_nullable_to_non_nullable
as String?,lastSwapAt: freezed == lastSwapAt ? _self.lastSwapAt : lastSwapAt // ignore: cast_nullable_to_non_nullable
as DateTime?,lastSwapFromTargetId: freezed == lastSwapFromTargetId ? _self.lastSwapFromTargetId : lastSwapFromTargetId // ignore: cast_nullable_to_non_nullable
as String?,lastSwapToTargetId: freezed == lastSwapToTargetId ? _self.lastSwapToTargetId : lastSwapToTargetId // ignore: cast_nullable_to_non_nullable
as String?,lastObservedScore: freezed == lastObservedScore ? _self.lastObservedScore : lastObservedScore // ignore: cast_nullable_to_non_nullable
as double?,configuredThreshold: freezed == configuredThreshold ? _self.configuredThreshold : configuredThreshold // ignore: cast_nullable_to_non_nullable
as double?,configuredHysteresisSecs: null == configuredHysteresisSecs ? _self.configuredHysteresisSecs : configuredHysteresisSecs // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}


/// @nodoc
mixin _$AdaptiveSwapSnapshot {

 ConditionsScore? get score;// Default empty state used when the JSON payload is missing
// `state` entirely (Phase 1's
// `from_json_treats_missing_state_as_default_state` contract test).
 AdaptiveSwapRuntimeState get state;
/// Create a copy of AdaptiveSwapSnapshot
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AdaptiveSwapSnapshotCopyWith<AdaptiveSwapSnapshot> get copyWith => _$AdaptiveSwapSnapshotCopyWithImpl<AdaptiveSwapSnapshot>(this as AdaptiveSwapSnapshot, _$identity);

  /// Serializes this AdaptiveSwapSnapshot to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AdaptiveSwapSnapshot&&(identical(other.score, score) || other.score == score)&&(identical(other.state, state) || other.state == state));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,score,state);

@override
String toString() {
  return 'AdaptiveSwapSnapshot(score: $score, state: $state)';
}


}

/// @nodoc
abstract mixin class $AdaptiveSwapSnapshotCopyWith<$Res>  {
  factory $AdaptiveSwapSnapshotCopyWith(AdaptiveSwapSnapshot value, $Res Function(AdaptiveSwapSnapshot) _then) = _$AdaptiveSwapSnapshotCopyWithImpl;
@useResult
$Res call({
 ConditionsScore? score, AdaptiveSwapRuntimeState state
});


$ConditionsScoreCopyWith<$Res>? get score;$AdaptiveSwapRuntimeStateCopyWith<$Res> get state;

}
/// @nodoc
class _$AdaptiveSwapSnapshotCopyWithImpl<$Res>
    implements $AdaptiveSwapSnapshotCopyWith<$Res> {
  _$AdaptiveSwapSnapshotCopyWithImpl(this._self, this._then);

  final AdaptiveSwapSnapshot _self;
  final $Res Function(AdaptiveSwapSnapshot) _then;

/// Create a copy of AdaptiveSwapSnapshot
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? score = freezed,Object? state = null,}) {
  return _then(_self.copyWith(
score: freezed == score ? _self.score : score // ignore: cast_nullable_to_non_nullable
as ConditionsScore?,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as AdaptiveSwapRuntimeState,
  ));
}
/// Create a copy of AdaptiveSwapSnapshot
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ConditionsScoreCopyWith<$Res>? get score {
    if (_self.score == null) {
    return null;
  }

  return $ConditionsScoreCopyWith<$Res>(_self.score!, (value) {
    return _then(_self.copyWith(score: value));
  });
}/// Create a copy of AdaptiveSwapSnapshot
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AdaptiveSwapRuntimeStateCopyWith<$Res> get state {
  
  return $AdaptiveSwapRuntimeStateCopyWith<$Res>(_self.state, (value) {
    return _then(_self.copyWith(state: value));
  });
}
}


/// Adds pattern-matching-related methods to [AdaptiveSwapSnapshot].
extension AdaptiveSwapSnapshotPatterns on AdaptiveSwapSnapshot {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AdaptiveSwapSnapshot value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AdaptiveSwapSnapshot() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AdaptiveSwapSnapshot value)  $default,){
final _that = this;
switch (_that) {
case _AdaptiveSwapSnapshot():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AdaptiveSwapSnapshot value)?  $default,){
final _that = this;
switch (_that) {
case _AdaptiveSwapSnapshot() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( ConditionsScore? score,  AdaptiveSwapRuntimeState state)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AdaptiveSwapSnapshot() when $default != null:
return $default(_that.score,_that.state);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( ConditionsScore? score,  AdaptiveSwapRuntimeState state)  $default,) {final _that = this;
switch (_that) {
case _AdaptiveSwapSnapshot():
return $default(_that.score,_that.state);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( ConditionsScore? score,  AdaptiveSwapRuntimeState state)?  $default,) {final _that = this;
switch (_that) {
case _AdaptiveSwapSnapshot() when $default != null:
return $default(_that.score,_that.state);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(explicitToJson: true)
class _AdaptiveSwapSnapshot implements AdaptiveSwapSnapshot {
  const _AdaptiveSwapSnapshot({this.score, this.state = const AdaptiveSwapRuntimeState()});
  factory _AdaptiveSwapSnapshot.fromJson(Map<String, dynamic> json) => _$AdaptiveSwapSnapshotFromJson(json);

@override final  ConditionsScore? score;
// Default empty state used when the JSON payload is missing
// `state` entirely (Phase 1's
// `from_json_treats_missing_state_as_default_state` contract test).
@override@JsonKey() final  AdaptiveSwapRuntimeState state;

/// Create a copy of AdaptiveSwapSnapshot
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AdaptiveSwapSnapshotCopyWith<_AdaptiveSwapSnapshot> get copyWith => __$AdaptiveSwapSnapshotCopyWithImpl<_AdaptiveSwapSnapshot>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AdaptiveSwapSnapshotToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AdaptiveSwapSnapshot&&(identical(other.score, score) || other.score == score)&&(identical(other.state, state) || other.state == state));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,score,state);

@override
String toString() {
  return 'AdaptiveSwapSnapshot(score: $score, state: $state)';
}


}

/// @nodoc
abstract mixin class _$AdaptiveSwapSnapshotCopyWith<$Res> implements $AdaptiveSwapSnapshotCopyWith<$Res> {
  factory _$AdaptiveSwapSnapshotCopyWith(_AdaptiveSwapSnapshot value, $Res Function(_AdaptiveSwapSnapshot) _then) = __$AdaptiveSwapSnapshotCopyWithImpl;
@override @useResult
$Res call({
 ConditionsScore? score, AdaptiveSwapRuntimeState state
});


@override $ConditionsScoreCopyWith<$Res>? get score;@override $AdaptiveSwapRuntimeStateCopyWith<$Res> get state;

}
/// @nodoc
class __$AdaptiveSwapSnapshotCopyWithImpl<$Res>
    implements _$AdaptiveSwapSnapshotCopyWith<$Res> {
  __$AdaptiveSwapSnapshotCopyWithImpl(this._self, this._then);

  final _AdaptiveSwapSnapshot _self;
  final $Res Function(_AdaptiveSwapSnapshot) _then;

/// Create a copy of AdaptiveSwapSnapshot
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? score = freezed,Object? state = null,}) {
  return _then(_AdaptiveSwapSnapshot(
score: freezed == score ? _self.score : score // ignore: cast_nullable_to_non_nullable
as ConditionsScore?,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as AdaptiveSwapRuntimeState,
  ));
}

/// Create a copy of AdaptiveSwapSnapshot
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ConditionsScoreCopyWith<$Res>? get score {
    if (_self.score == null) {
    return null;
  }

  return $ConditionsScoreCopyWith<$Res>(_self.score!, (value) {
    return _then(_self.copyWith(score: value));
  });
}/// Create a copy of AdaptiveSwapSnapshot
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AdaptiveSwapRuntimeStateCopyWith<$Res> get state {
  
  return $AdaptiveSwapRuntimeStateCopyWith<$Res>(_self.state, (value) {
    return _then(_self.copyWith(state: value));
  });
}
}


/// @nodoc
mixin _$FilterPlan {

/// Filter wheel slot name (e.g. "L", "Ha"). Matched against the
/// connected filter wheel's name list when [filterIndex] is null.
 String get filterName;/// 0-based filter wheel index. Preferred over [filterName] for
/// reliability — matches `ExposureNode.filterIndex` / Rust
/// `FilterConfig::filter_index`.
 int? get filterIndex;/// Total number of exposures to take for this filter.
 int get count;/// Sub-exposure duration in seconds.
 double get durationSecs;/// Optional gain override. null means "use camera/profile default".
 int? get gain;/// Optional offset override.
 int? get offset;/// Binning for this filter. Defaults to 1x1.
@BinningModeJsonConverter() BinningMode get binning;/// Per-plan dither cadence (every N frames). null disables dithering for
/// this filter regardless of any global default. 0 is treated as "no
/// dither" — matches `ExposureNode.ditherEvery`.
 int? get ditherEvery;/// Optional DepthLock binding. When set, the executor asks the goal
/// store for a verdict before each batch of this plan and treats an
/// achieved goal (with automatic completion enabled) as the plan being
/// complete. null keeps the plan purely count-bounded — matches Rust
/// `FilterPlan::depth_goal`.
 DepthGoalBinding? get depthGoal;
/// Create a copy of FilterPlan
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FilterPlanCopyWith<FilterPlan> get copyWith => _$FilterPlanCopyWithImpl<FilterPlan>(this as FilterPlan, _$identity);

  /// Serializes this FilterPlan to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FilterPlan&&(identical(other.filterName, filterName) || other.filterName == filterName)&&(identical(other.filterIndex, filterIndex) || other.filterIndex == filterIndex)&&(identical(other.count, count) || other.count == count)&&(identical(other.durationSecs, durationSecs) || other.durationSecs == durationSecs)&&(identical(other.gain, gain) || other.gain == gain)&&(identical(other.offset, offset) || other.offset == offset)&&(identical(other.binning, binning) || other.binning == binning)&&(identical(other.ditherEvery, ditherEvery) || other.ditherEvery == ditherEvery)&&(identical(other.depthGoal, depthGoal) || other.depthGoal == depthGoal));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,filterName,filterIndex,count,durationSecs,gain,offset,binning,ditherEvery,depthGoal);

@override
String toString() {
  return 'FilterPlan(filterName: $filterName, filterIndex: $filterIndex, count: $count, durationSecs: $durationSecs, gain: $gain, offset: $offset, binning: $binning, ditherEvery: $ditherEvery, depthGoal: $depthGoal)';
}


}

/// @nodoc
abstract mixin class $FilterPlanCopyWith<$Res>  {
  factory $FilterPlanCopyWith(FilterPlan value, $Res Function(FilterPlan) _then) = _$FilterPlanCopyWithImpl;
@useResult
$Res call({
 String filterName, int? filterIndex, int count, double durationSecs, int? gain, int? offset,@BinningModeJsonConverter() BinningMode binning, int? ditherEvery, DepthGoalBinding? depthGoal
});


$DepthGoalBindingCopyWith<$Res>? get depthGoal;

}
/// @nodoc
class _$FilterPlanCopyWithImpl<$Res>
    implements $FilterPlanCopyWith<$Res> {
  _$FilterPlanCopyWithImpl(this._self, this._then);

  final FilterPlan _self;
  final $Res Function(FilterPlan) _then;

/// Create a copy of FilterPlan
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? filterName = null,Object? filterIndex = freezed,Object? count = null,Object? durationSecs = null,Object? gain = freezed,Object? offset = freezed,Object? binning = null,Object? ditherEvery = freezed,Object? depthGoal = freezed,}) {
  return _then(_self.copyWith(
filterName: null == filterName ? _self.filterName : filterName // ignore: cast_nullable_to_non_nullable
as String,filterIndex: freezed == filterIndex ? _self.filterIndex : filterIndex // ignore: cast_nullable_to_non_nullable
as int?,count: null == count ? _self.count : count // ignore: cast_nullable_to_non_nullable
as int,durationSecs: null == durationSecs ? _self.durationSecs : durationSecs // ignore: cast_nullable_to_non_nullable
as double,gain: freezed == gain ? _self.gain : gain // ignore: cast_nullable_to_non_nullable
as int?,offset: freezed == offset ? _self.offset : offset // ignore: cast_nullable_to_non_nullable
as int?,binning: null == binning ? _self.binning : binning // ignore: cast_nullable_to_non_nullable
as BinningMode,ditherEvery: freezed == ditherEvery ? _self.ditherEvery : ditherEvery // ignore: cast_nullable_to_non_nullable
as int?,depthGoal: freezed == depthGoal ? _self.depthGoal : depthGoal // ignore: cast_nullable_to_non_nullable
as DepthGoalBinding?,
  ));
}
/// Create a copy of FilterPlan
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$DepthGoalBindingCopyWith<$Res>? get depthGoal {
    if (_self.depthGoal == null) {
    return null;
  }

  return $DepthGoalBindingCopyWith<$Res>(_self.depthGoal!, (value) {
    return _then(_self.copyWith(depthGoal: value));
  });
}
}


/// Adds pattern-matching-related methods to [FilterPlan].
extension FilterPlanPatterns on FilterPlan {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _FilterPlan value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _FilterPlan() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _FilterPlan value)  $default,){
final _that = this;
switch (_that) {
case _FilterPlan():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _FilterPlan value)?  $default,){
final _that = this;
switch (_that) {
case _FilterPlan() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String filterName,  int? filterIndex,  int count,  double durationSecs,  int? gain,  int? offset, @BinningModeJsonConverter()  BinningMode binning,  int? ditherEvery,  DepthGoalBinding? depthGoal)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _FilterPlan() when $default != null:
return $default(_that.filterName,_that.filterIndex,_that.count,_that.durationSecs,_that.gain,_that.offset,_that.binning,_that.ditherEvery,_that.depthGoal);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String filterName,  int? filterIndex,  int count,  double durationSecs,  int? gain,  int? offset, @BinningModeJsonConverter()  BinningMode binning,  int? ditherEvery,  DepthGoalBinding? depthGoal)  $default,) {final _that = this;
switch (_that) {
case _FilterPlan():
return $default(_that.filterName,_that.filterIndex,_that.count,_that.durationSecs,_that.gain,_that.offset,_that.binning,_that.ditherEvery,_that.depthGoal);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String filterName,  int? filterIndex,  int count,  double durationSecs,  int? gain,  int? offset, @BinningModeJsonConverter()  BinningMode binning,  int? ditherEvery,  DepthGoalBinding? depthGoal)?  $default,) {final _that = this;
switch (_that) {
case _FilterPlan() when $default != null:
return $default(_that.filterName,_that.filterIndex,_that.count,_that.durationSecs,_that.gain,_that.offset,_that.binning,_that.ditherEvery,_that.depthGoal);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake, includeIfNull: true, explicitToJson: true)
class _FilterPlan extends FilterPlan {
  const _FilterPlan({this.filterName = '', this.filterIndex, this.count = 10, this.durationSecs = 60.0, this.gain, this.offset, @BinningModeJsonConverter() this.binning = BinningMode.one, this.ditherEvery, this.depthGoal}): super._();
  factory _FilterPlan.fromJson(Map<String, dynamic> json) => _$FilterPlanFromJson(json);

/// Filter wheel slot name (e.g. "L", "Ha"). Matched against the
/// connected filter wheel's name list when [filterIndex] is null.
@override@JsonKey() final  String filterName;
/// 0-based filter wheel index. Preferred over [filterName] for
/// reliability — matches `ExposureNode.filterIndex` / Rust
/// `FilterConfig::filter_index`.
@override final  int? filterIndex;
/// Total number of exposures to take for this filter.
@override@JsonKey() final  int count;
/// Sub-exposure duration in seconds.
@override@JsonKey() final  double durationSecs;
/// Optional gain override. null means "use camera/profile default".
@override final  int? gain;
/// Optional offset override.
@override final  int? offset;
/// Binning for this filter. Defaults to 1x1.
@override@JsonKey()@BinningModeJsonConverter() final  BinningMode binning;
/// Per-plan dither cadence (every N frames). null disables dithering for
/// this filter regardless of any global default. 0 is treated as "no
/// dither" — matches `ExposureNode.ditherEvery`.
@override final  int? ditherEvery;
/// Optional DepthLock binding. When set, the executor asks the goal
/// store for a verdict before each batch of this plan and treats an
/// achieved goal (with automatic completion enabled) as the plan being
/// complete. null keeps the plan purely count-bounded — matches Rust
/// `FilterPlan::depth_goal`.
@override final  DepthGoalBinding? depthGoal;

/// Create a copy of FilterPlan
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$FilterPlanCopyWith<_FilterPlan> get copyWith => __$FilterPlanCopyWithImpl<_FilterPlan>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$FilterPlanToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _FilterPlan&&(identical(other.filterName, filterName) || other.filterName == filterName)&&(identical(other.filterIndex, filterIndex) || other.filterIndex == filterIndex)&&(identical(other.count, count) || other.count == count)&&(identical(other.durationSecs, durationSecs) || other.durationSecs == durationSecs)&&(identical(other.gain, gain) || other.gain == gain)&&(identical(other.offset, offset) || other.offset == offset)&&(identical(other.binning, binning) || other.binning == binning)&&(identical(other.ditherEvery, ditherEvery) || other.ditherEvery == ditherEvery)&&(identical(other.depthGoal, depthGoal) || other.depthGoal == depthGoal));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,filterName,filterIndex,count,durationSecs,gain,offset,binning,ditherEvery,depthGoal);

@override
String toString() {
  return 'FilterPlan(filterName: $filterName, filterIndex: $filterIndex, count: $count, durationSecs: $durationSecs, gain: $gain, offset: $offset, binning: $binning, ditherEvery: $ditherEvery, depthGoal: $depthGoal)';
}


}

/// @nodoc
abstract mixin class _$FilterPlanCopyWith<$Res> implements $FilterPlanCopyWith<$Res> {
  factory _$FilterPlanCopyWith(_FilterPlan value, $Res Function(_FilterPlan) _then) = __$FilterPlanCopyWithImpl;
@override @useResult
$Res call({
 String filterName, int? filterIndex, int count, double durationSecs, int? gain, int? offset,@BinningModeJsonConverter() BinningMode binning, int? ditherEvery, DepthGoalBinding? depthGoal
});


@override $DepthGoalBindingCopyWith<$Res>? get depthGoal;

}
/// @nodoc
class __$FilterPlanCopyWithImpl<$Res>
    implements _$FilterPlanCopyWith<$Res> {
  __$FilterPlanCopyWithImpl(this._self, this._then);

  final _FilterPlan _self;
  final $Res Function(_FilterPlan) _then;

/// Create a copy of FilterPlan
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? filterName = null,Object? filterIndex = freezed,Object? count = null,Object? durationSecs = null,Object? gain = freezed,Object? offset = freezed,Object? binning = null,Object? ditherEvery = freezed,Object? depthGoal = freezed,}) {
  return _then(_FilterPlan(
filterName: null == filterName ? _self.filterName : filterName // ignore: cast_nullable_to_non_nullable
as String,filterIndex: freezed == filterIndex ? _self.filterIndex : filterIndex // ignore: cast_nullable_to_non_nullable
as int?,count: null == count ? _self.count : count // ignore: cast_nullable_to_non_nullable
as int,durationSecs: null == durationSecs ? _self.durationSecs : durationSecs // ignore: cast_nullable_to_non_nullable
as double,gain: freezed == gain ? _self.gain : gain // ignore: cast_nullable_to_non_nullable
as int?,offset: freezed == offset ? _self.offset : offset // ignore: cast_nullable_to_non_nullable
as int?,binning: null == binning ? _self.binning : binning // ignore: cast_nullable_to_non_nullable
as BinningMode,ditherEvery: freezed == ditherEvery ? _self.ditherEvery : ditherEvery // ignore: cast_nullable_to_non_nullable
as int?,depthGoal: freezed == depthGoal ? _self.depthGoal : depthGoal // ignore: cast_nullable_to_non_nullable
as DepthGoalBinding?,
  ));
}

/// Create a copy of FilterPlan
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$DepthGoalBindingCopyWith<$Res>? get depthGoal {
    if (_self.depthGoal == null) {
    return null;
  }

  return $DepthGoalBindingCopyWith<$Res>(_self.depthGoal!, (value) {
    return _then(_self.copyWith(depthGoal: value));
  });
}
}


/// @nodoc
mixin _$DepthGoalBinding {

 String get goalId; int get revision;
/// Create a copy of DepthGoalBinding
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DepthGoalBindingCopyWith<DepthGoalBinding> get copyWith => _$DepthGoalBindingCopyWithImpl<DepthGoalBinding>(this as DepthGoalBinding, _$identity);

  /// Serializes this DepthGoalBinding to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DepthGoalBinding&&(identical(other.goalId, goalId) || other.goalId == goalId)&&(identical(other.revision, revision) || other.revision == revision));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,goalId,revision);

@override
String toString() {
  return 'DepthGoalBinding(goalId: $goalId, revision: $revision)';
}


}

/// @nodoc
abstract mixin class $DepthGoalBindingCopyWith<$Res>  {
  factory $DepthGoalBindingCopyWith(DepthGoalBinding value, $Res Function(DepthGoalBinding) _then) = _$DepthGoalBindingCopyWithImpl;
@useResult
$Res call({
 String goalId, int revision
});




}
/// @nodoc
class _$DepthGoalBindingCopyWithImpl<$Res>
    implements $DepthGoalBindingCopyWith<$Res> {
  _$DepthGoalBindingCopyWithImpl(this._self, this._then);

  final DepthGoalBinding _self;
  final $Res Function(DepthGoalBinding) _then;

/// Create a copy of DepthGoalBinding
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? goalId = null,Object? revision = null,}) {
  return _then(_self.copyWith(
goalId: null == goalId ? _self.goalId : goalId // ignore: cast_nullable_to_non_nullable
as String,revision: null == revision ? _self.revision : revision // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [DepthGoalBinding].
extension DepthGoalBindingPatterns on DepthGoalBinding {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _DepthGoalBinding value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _DepthGoalBinding() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _DepthGoalBinding value)  $default,){
final _that = this;
switch (_that) {
case _DepthGoalBinding():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _DepthGoalBinding value)?  $default,){
final _that = this;
switch (_that) {
case _DepthGoalBinding() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String goalId,  int revision)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _DepthGoalBinding() when $default != null:
return $default(_that.goalId,_that.revision);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String goalId,  int revision)  $default,) {final _that = this;
switch (_that) {
case _DepthGoalBinding():
return $default(_that.goalId,_that.revision);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String goalId,  int revision)?  $default,) {final _that = this;
switch (_that) {
case _DepthGoalBinding() when $default != null:
return $default(_that.goalId,_that.revision);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake)
class _DepthGoalBinding extends DepthGoalBinding {
  const _DepthGoalBinding({required this.goalId, required this.revision}): super._();
  factory _DepthGoalBinding.fromJson(Map<String, dynamic> json) => _$DepthGoalBindingFromJson(json);

@override final  String goalId;
@override final  int revision;

/// Create a copy of DepthGoalBinding
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$DepthGoalBindingCopyWith<_DepthGoalBinding> get copyWith => __$DepthGoalBindingCopyWithImpl<_DepthGoalBinding>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$DepthGoalBindingToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _DepthGoalBinding&&(identical(other.goalId, goalId) || other.goalId == goalId)&&(identical(other.revision, revision) || other.revision == revision));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,goalId,revision);

@override
String toString() {
  return 'DepthGoalBinding(goalId: $goalId, revision: $revision)';
}


}

/// @nodoc
abstract mixin class _$DepthGoalBindingCopyWith<$Res> implements $DepthGoalBindingCopyWith<$Res> {
  factory _$DepthGoalBindingCopyWith(_DepthGoalBinding value, $Res Function(_DepthGoalBinding) _then) = __$DepthGoalBindingCopyWithImpl;
@override @useResult
$Res call({
 String goalId, int revision
});




}
/// @nodoc
class __$DepthGoalBindingCopyWithImpl<$Res>
    implements _$DepthGoalBindingCopyWith<$Res> {
  __$DepthGoalBindingCopyWithImpl(this._self, this._then);

  final _DepthGoalBinding _self;
  final $Res Function(_DepthGoalBinding) _then;

/// Create a copy of DepthGoalBinding
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? goalId = null,Object? revision = null,}) {
  return _then(_DepthGoalBinding(
goalId: null == goalId ? _self.goalId : goalId // ignore: cast_nullable_to_non_nullable
as String,revision: null == revision ? _self.revision : revision // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc
mixin _$TargetTrigger {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TargetTrigger);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'TargetTrigger()';
}


}

/// @nodoc
class $TargetTriggerCopyWith<$Res>  {
$TargetTriggerCopyWith(TargetTrigger _, $Res Function(TargetTrigger) __);
}


/// Adds pattern-matching-related methods to [TargetTrigger].
extension TargetTriggerPatterns on TargetTrigger {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( AltitudeAboveTrigger value)?  altitudeAbove,TResult Function( AltitudeBelowTrigger value)?  altitudeBelow,TResult Function( TimeAfterTrigger value)?  timeAfter,TResult Function( TimeBeforeTrigger value)?  timeBefore,TResult Function( AndTrigger value)?  and,TResult Function( OrTrigger value)?  or,TResult Function( HourAngleBetweenTrigger value)?  hourAngleBetween,required TResult orElse(),}){
final _that = this;
switch (_that) {
case AltitudeAboveTrigger() when altitudeAbove != null:
return altitudeAbove(_that);case AltitudeBelowTrigger() when altitudeBelow != null:
return altitudeBelow(_that);case TimeAfterTrigger() when timeAfter != null:
return timeAfter(_that);case TimeBeforeTrigger() when timeBefore != null:
return timeBefore(_that);case AndTrigger() when and != null:
return and(_that);case OrTrigger() when or != null:
return or(_that);case HourAngleBetweenTrigger() when hourAngleBetween != null:
return hourAngleBetween(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( AltitudeAboveTrigger value)  altitudeAbove,required TResult Function( AltitudeBelowTrigger value)  altitudeBelow,required TResult Function( TimeAfterTrigger value)  timeAfter,required TResult Function( TimeBeforeTrigger value)  timeBefore,required TResult Function( AndTrigger value)  and,required TResult Function( OrTrigger value)  or,required TResult Function( HourAngleBetweenTrigger value)  hourAngleBetween,}){
final _that = this;
switch (_that) {
case AltitudeAboveTrigger():
return altitudeAbove(_that);case AltitudeBelowTrigger():
return altitudeBelow(_that);case TimeAfterTrigger():
return timeAfter(_that);case TimeBeforeTrigger():
return timeBefore(_that);case AndTrigger():
return and(_that);case OrTrigger():
return or(_that);case HourAngleBetweenTrigger():
return hourAngleBetween(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( AltitudeAboveTrigger value)?  altitudeAbove,TResult? Function( AltitudeBelowTrigger value)?  altitudeBelow,TResult? Function( TimeAfterTrigger value)?  timeAfter,TResult? Function( TimeBeforeTrigger value)?  timeBefore,TResult? Function( AndTrigger value)?  and,TResult? Function( OrTrigger value)?  or,TResult? Function( HourAngleBetweenTrigger value)?  hourAngleBetween,}){
final _that = this;
switch (_that) {
case AltitudeAboveTrigger() when altitudeAbove != null:
return altitudeAbove(_that);case AltitudeBelowTrigger() when altitudeBelow != null:
return altitudeBelow(_that);case TimeAfterTrigger() when timeAfter != null:
return timeAfter(_that);case TimeBeforeTrigger() when timeBefore != null:
return timeBefore(_that);case AndTrigger() when and != null:
return and(_that);case OrTrigger() when or != null:
return or(_that);case HourAngleBetweenTrigger() when hourAngleBetween != null:
return hourAngleBetween(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( double altitudeDeg)?  altitudeAbove,TResult Function( double altitudeDeg)?  altitudeBelow,TResult Function( int unixSeconds)?  timeAfter,TResult Function( int unixSeconds)?  timeBefore,TResult Function( List<TargetTrigger> children)?  and,TResult Function( List<TargetTrigger> children)?  or,TResult Function( double minHa,  double maxHa)?  hourAngleBetween,required TResult orElse(),}) {final _that = this;
switch (_that) {
case AltitudeAboveTrigger() when altitudeAbove != null:
return altitudeAbove(_that.altitudeDeg);case AltitudeBelowTrigger() when altitudeBelow != null:
return altitudeBelow(_that.altitudeDeg);case TimeAfterTrigger() when timeAfter != null:
return timeAfter(_that.unixSeconds);case TimeBeforeTrigger() when timeBefore != null:
return timeBefore(_that.unixSeconds);case AndTrigger() when and != null:
return and(_that.children);case OrTrigger() when or != null:
return or(_that.children);case HourAngleBetweenTrigger() when hourAngleBetween != null:
return hourAngleBetween(_that.minHa,_that.maxHa);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( double altitudeDeg)  altitudeAbove,required TResult Function( double altitudeDeg)  altitudeBelow,required TResult Function( int unixSeconds)  timeAfter,required TResult Function( int unixSeconds)  timeBefore,required TResult Function( List<TargetTrigger> children)  and,required TResult Function( List<TargetTrigger> children)  or,required TResult Function( double minHa,  double maxHa)  hourAngleBetween,}) {final _that = this;
switch (_that) {
case AltitudeAboveTrigger():
return altitudeAbove(_that.altitudeDeg);case AltitudeBelowTrigger():
return altitudeBelow(_that.altitudeDeg);case TimeAfterTrigger():
return timeAfter(_that.unixSeconds);case TimeBeforeTrigger():
return timeBefore(_that.unixSeconds);case AndTrigger():
return and(_that.children);case OrTrigger():
return or(_that.children);case HourAngleBetweenTrigger():
return hourAngleBetween(_that.minHa,_that.maxHa);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( double altitudeDeg)?  altitudeAbove,TResult? Function( double altitudeDeg)?  altitudeBelow,TResult? Function( int unixSeconds)?  timeAfter,TResult? Function( int unixSeconds)?  timeBefore,TResult? Function( List<TargetTrigger> children)?  and,TResult? Function( List<TargetTrigger> children)?  or,TResult? Function( double minHa,  double maxHa)?  hourAngleBetween,}) {final _that = this;
switch (_that) {
case AltitudeAboveTrigger() when altitudeAbove != null:
return altitudeAbove(_that.altitudeDeg);case AltitudeBelowTrigger() when altitudeBelow != null:
return altitudeBelow(_that.altitudeDeg);case TimeAfterTrigger() when timeAfter != null:
return timeAfter(_that.unixSeconds);case TimeBeforeTrigger() when timeBefore != null:
return timeBefore(_that.unixSeconds);case AndTrigger() when and != null:
return and(_that.children);case OrTrigger() when or != null:
return or(_that.children);case HourAngleBetweenTrigger() when hourAngleBetween != null:
return hourAngleBetween(_that.minHa,_that.maxHa);case _:
  return null;

}
}

}

/// @nodoc


class AltitudeAboveTrigger extends TargetTrigger {
  const AltitudeAboveTrigger(this.altitudeDeg): super._();
  

 final  double altitudeDeg;

/// Create a copy of TargetTrigger
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AltitudeAboveTriggerCopyWith<AltitudeAboveTrigger> get copyWith => _$AltitudeAboveTriggerCopyWithImpl<AltitudeAboveTrigger>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AltitudeAboveTrigger&&(identical(other.altitudeDeg, altitudeDeg) || other.altitudeDeg == altitudeDeg));
}


@override
int get hashCode => Object.hash(runtimeType,altitudeDeg);

@override
String toString() {
  return 'TargetTrigger.altitudeAbove(altitudeDeg: $altitudeDeg)';
}


}

/// @nodoc
abstract mixin class $AltitudeAboveTriggerCopyWith<$Res> implements $TargetTriggerCopyWith<$Res> {
  factory $AltitudeAboveTriggerCopyWith(AltitudeAboveTrigger value, $Res Function(AltitudeAboveTrigger) _then) = _$AltitudeAboveTriggerCopyWithImpl;
@useResult
$Res call({
 double altitudeDeg
});




}
/// @nodoc
class _$AltitudeAboveTriggerCopyWithImpl<$Res>
    implements $AltitudeAboveTriggerCopyWith<$Res> {
  _$AltitudeAboveTriggerCopyWithImpl(this._self, this._then);

  final AltitudeAboveTrigger _self;
  final $Res Function(AltitudeAboveTrigger) _then;

/// Create a copy of TargetTrigger
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? altitudeDeg = null,}) {
  return _then(AltitudeAboveTrigger(
null == altitudeDeg ? _self.altitudeDeg : altitudeDeg // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class AltitudeBelowTrigger extends TargetTrigger {
  const AltitudeBelowTrigger(this.altitudeDeg): super._();
  

 final  double altitudeDeg;

/// Create a copy of TargetTrigger
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AltitudeBelowTriggerCopyWith<AltitudeBelowTrigger> get copyWith => _$AltitudeBelowTriggerCopyWithImpl<AltitudeBelowTrigger>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AltitudeBelowTrigger&&(identical(other.altitudeDeg, altitudeDeg) || other.altitudeDeg == altitudeDeg));
}


@override
int get hashCode => Object.hash(runtimeType,altitudeDeg);

@override
String toString() {
  return 'TargetTrigger.altitudeBelow(altitudeDeg: $altitudeDeg)';
}


}

/// @nodoc
abstract mixin class $AltitudeBelowTriggerCopyWith<$Res> implements $TargetTriggerCopyWith<$Res> {
  factory $AltitudeBelowTriggerCopyWith(AltitudeBelowTrigger value, $Res Function(AltitudeBelowTrigger) _then) = _$AltitudeBelowTriggerCopyWithImpl;
@useResult
$Res call({
 double altitudeDeg
});




}
/// @nodoc
class _$AltitudeBelowTriggerCopyWithImpl<$Res>
    implements $AltitudeBelowTriggerCopyWith<$Res> {
  _$AltitudeBelowTriggerCopyWithImpl(this._self, this._then);

  final AltitudeBelowTrigger _self;
  final $Res Function(AltitudeBelowTrigger) _then;

/// Create a copy of TargetTrigger
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? altitudeDeg = null,}) {
  return _then(AltitudeBelowTrigger(
null == altitudeDeg ? _self.altitudeDeg : altitudeDeg // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class TimeAfterTrigger extends TargetTrigger {
  const TimeAfterTrigger(this.unixSeconds): super._();
  

 final  int unixSeconds;

/// Create a copy of TargetTrigger
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TimeAfterTriggerCopyWith<TimeAfterTrigger> get copyWith => _$TimeAfterTriggerCopyWithImpl<TimeAfterTrigger>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TimeAfterTrigger&&(identical(other.unixSeconds, unixSeconds) || other.unixSeconds == unixSeconds));
}


@override
int get hashCode => Object.hash(runtimeType,unixSeconds);

@override
String toString() {
  return 'TargetTrigger.timeAfter(unixSeconds: $unixSeconds)';
}


}

/// @nodoc
abstract mixin class $TimeAfterTriggerCopyWith<$Res> implements $TargetTriggerCopyWith<$Res> {
  factory $TimeAfterTriggerCopyWith(TimeAfterTrigger value, $Res Function(TimeAfterTrigger) _then) = _$TimeAfterTriggerCopyWithImpl;
@useResult
$Res call({
 int unixSeconds
});




}
/// @nodoc
class _$TimeAfterTriggerCopyWithImpl<$Res>
    implements $TimeAfterTriggerCopyWith<$Res> {
  _$TimeAfterTriggerCopyWithImpl(this._self, this._then);

  final TimeAfterTrigger _self;
  final $Res Function(TimeAfterTrigger) _then;

/// Create a copy of TargetTrigger
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? unixSeconds = null,}) {
  return _then(TimeAfterTrigger(
null == unixSeconds ? _self.unixSeconds : unixSeconds // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class TimeBeforeTrigger extends TargetTrigger {
  const TimeBeforeTrigger(this.unixSeconds): super._();
  

 final  int unixSeconds;

/// Create a copy of TargetTrigger
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TimeBeforeTriggerCopyWith<TimeBeforeTrigger> get copyWith => _$TimeBeforeTriggerCopyWithImpl<TimeBeforeTrigger>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TimeBeforeTrigger&&(identical(other.unixSeconds, unixSeconds) || other.unixSeconds == unixSeconds));
}


@override
int get hashCode => Object.hash(runtimeType,unixSeconds);

@override
String toString() {
  return 'TargetTrigger.timeBefore(unixSeconds: $unixSeconds)';
}


}

/// @nodoc
abstract mixin class $TimeBeforeTriggerCopyWith<$Res> implements $TargetTriggerCopyWith<$Res> {
  factory $TimeBeforeTriggerCopyWith(TimeBeforeTrigger value, $Res Function(TimeBeforeTrigger) _then) = _$TimeBeforeTriggerCopyWithImpl;
@useResult
$Res call({
 int unixSeconds
});




}
/// @nodoc
class _$TimeBeforeTriggerCopyWithImpl<$Res>
    implements $TimeBeforeTriggerCopyWith<$Res> {
  _$TimeBeforeTriggerCopyWithImpl(this._self, this._then);

  final TimeBeforeTrigger _self;
  final $Res Function(TimeBeforeTrigger) _then;

/// Create a copy of TargetTrigger
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? unixSeconds = null,}) {
  return _then(TimeBeforeTrigger(
null == unixSeconds ? _self.unixSeconds : unixSeconds // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class AndTrigger extends TargetTrigger {
  const AndTrigger(final  List<TargetTrigger> children): _children = children,super._();
  

 final  List<TargetTrigger> _children;
 List<TargetTrigger> get children {
  if (_children is EqualUnmodifiableListView) return _children;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_children);
}


/// Create a copy of TargetTrigger
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AndTriggerCopyWith<AndTrigger> get copyWith => _$AndTriggerCopyWithImpl<AndTrigger>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AndTrigger&&const DeepCollectionEquality().equals(other._children, _children));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_children));

@override
String toString() {
  return 'TargetTrigger.and(children: $children)';
}


}

/// @nodoc
abstract mixin class $AndTriggerCopyWith<$Res> implements $TargetTriggerCopyWith<$Res> {
  factory $AndTriggerCopyWith(AndTrigger value, $Res Function(AndTrigger) _then) = _$AndTriggerCopyWithImpl;
@useResult
$Res call({
 List<TargetTrigger> children
});




}
/// @nodoc
class _$AndTriggerCopyWithImpl<$Res>
    implements $AndTriggerCopyWith<$Res> {
  _$AndTriggerCopyWithImpl(this._self, this._then);

  final AndTrigger _self;
  final $Res Function(AndTrigger) _then;

/// Create a copy of TargetTrigger
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? children = null,}) {
  return _then(AndTrigger(
null == children ? _self._children : children // ignore: cast_nullable_to_non_nullable
as List<TargetTrigger>,
  ));
}


}

/// @nodoc


class OrTrigger extends TargetTrigger {
  const OrTrigger(final  List<TargetTrigger> children): _children = children,super._();
  

 final  List<TargetTrigger> _children;
 List<TargetTrigger> get children {
  if (_children is EqualUnmodifiableListView) return _children;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_children);
}


/// Create a copy of TargetTrigger
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$OrTriggerCopyWith<OrTrigger> get copyWith => _$OrTriggerCopyWithImpl<OrTrigger>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is OrTrigger&&const DeepCollectionEquality().equals(other._children, _children));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_children));

@override
String toString() {
  return 'TargetTrigger.or(children: $children)';
}


}

/// @nodoc
abstract mixin class $OrTriggerCopyWith<$Res> implements $TargetTriggerCopyWith<$Res> {
  factory $OrTriggerCopyWith(OrTrigger value, $Res Function(OrTrigger) _then) = _$OrTriggerCopyWithImpl;
@useResult
$Res call({
 List<TargetTrigger> children
});




}
/// @nodoc
class _$OrTriggerCopyWithImpl<$Res>
    implements $OrTriggerCopyWith<$Res> {
  _$OrTriggerCopyWithImpl(this._self, this._then);

  final OrTrigger _self;
  final $Res Function(OrTrigger) _then;

/// Create a copy of TargetTrigger
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? children = null,}) {
  return _then(OrTrigger(
null == children ? _self._children : children // ignore: cast_nullable_to_non_nullable
as List<TargetTrigger>,
  ));
}


}

/// @nodoc


class HourAngleBetweenTrigger extends TargetTrigger {
  const HourAngleBetweenTrigger({required this.minHa, required this.maxHa}): super._();
  

 final  double minHa;
 final  double maxHa;

/// Create a copy of TargetTrigger
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$HourAngleBetweenTriggerCopyWith<HourAngleBetweenTrigger> get copyWith => _$HourAngleBetweenTriggerCopyWithImpl<HourAngleBetweenTrigger>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is HourAngleBetweenTrigger&&(identical(other.minHa, minHa) || other.minHa == minHa)&&(identical(other.maxHa, maxHa) || other.maxHa == maxHa));
}


@override
int get hashCode => Object.hash(runtimeType,minHa,maxHa);

@override
String toString() {
  return 'TargetTrigger.hourAngleBetween(minHa: $minHa, maxHa: $maxHa)';
}


}

/// @nodoc
abstract mixin class $HourAngleBetweenTriggerCopyWith<$Res> implements $TargetTriggerCopyWith<$Res> {
  factory $HourAngleBetweenTriggerCopyWith(HourAngleBetweenTrigger value, $Res Function(HourAngleBetweenTrigger) _then) = _$HourAngleBetweenTriggerCopyWithImpl;
@useResult
$Res call({
 double minHa, double maxHa
});




}
/// @nodoc
class _$HourAngleBetweenTriggerCopyWithImpl<$Res>
    implements $HourAngleBetweenTriggerCopyWith<$Res> {
  _$HourAngleBetweenTriggerCopyWithImpl(this._self, this._then);

  final HourAngleBetweenTrigger _self;
  final $Res Function(HourAngleBetweenTrigger) _then;

/// Create a copy of TargetTrigger
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? minHa = null,Object? maxHa = null,}) {
  return _then(HourAngleBetweenTrigger(
minHa: null == minHa ? _self.minHa : minHa // ignore: cast_nullable_to_non_nullable
as double,maxHa: null == maxHa ? _self.maxHa : maxHa // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}


/// @nodoc
mixin _$AdaptiveExposureConfig {

/// Target SNR (informational; the current adapter scales by sky-
/// background flux ratio rather than aiming at a numeric target).
 double get targetSnr;/// Sky brightness in mag/arcsec² that the node's configured nominal
/// exposure is calibrated for.
 double get referenceSkyBrightnessMag;/// Global minimum exposure clamp (seconds).
 double get minExposureSecs;/// Global maximum exposure clamp (seconds).
 double get maxExposureSecs;/// Per-filter enable map. Filter name -> bool. Empty => apply globally.
 Map<String, bool> get perFilterEnabled;/// Per-filter minimum exposure overrides (seconds).
 Map<String, double> get perFilterMinSecs;/// Per-filter maximum exposure overrides (seconds).
 Map<String, double> get perFilterMaxSecs;/// Global enable toggle. When false the whole config is a no-op
/// regardless of per-filter map content.
 bool get enabled;
/// Create a copy of AdaptiveExposureConfig
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AdaptiveExposureConfigCopyWith<AdaptiveExposureConfig> get copyWith => _$AdaptiveExposureConfigCopyWithImpl<AdaptiveExposureConfig>(this as AdaptiveExposureConfig, _$identity);

  /// Serializes this AdaptiveExposureConfig to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AdaptiveExposureConfig&&(identical(other.targetSnr, targetSnr) || other.targetSnr == targetSnr)&&(identical(other.referenceSkyBrightnessMag, referenceSkyBrightnessMag) || other.referenceSkyBrightnessMag == referenceSkyBrightnessMag)&&(identical(other.minExposureSecs, minExposureSecs) || other.minExposureSecs == minExposureSecs)&&(identical(other.maxExposureSecs, maxExposureSecs) || other.maxExposureSecs == maxExposureSecs)&&const DeepCollectionEquality().equals(other.perFilterEnabled, perFilterEnabled)&&const DeepCollectionEquality().equals(other.perFilterMinSecs, perFilterMinSecs)&&const DeepCollectionEquality().equals(other.perFilterMaxSecs, perFilterMaxSecs)&&(identical(other.enabled, enabled) || other.enabled == enabled));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,targetSnr,referenceSkyBrightnessMag,minExposureSecs,maxExposureSecs,const DeepCollectionEquality().hash(perFilterEnabled),const DeepCollectionEquality().hash(perFilterMinSecs),const DeepCollectionEquality().hash(perFilterMaxSecs),enabled);

@override
String toString() {
  return 'AdaptiveExposureConfig(targetSnr: $targetSnr, referenceSkyBrightnessMag: $referenceSkyBrightnessMag, minExposureSecs: $minExposureSecs, maxExposureSecs: $maxExposureSecs, perFilterEnabled: $perFilterEnabled, perFilterMinSecs: $perFilterMinSecs, perFilterMaxSecs: $perFilterMaxSecs, enabled: $enabled)';
}


}

/// @nodoc
abstract mixin class $AdaptiveExposureConfigCopyWith<$Res>  {
  factory $AdaptiveExposureConfigCopyWith(AdaptiveExposureConfig value, $Res Function(AdaptiveExposureConfig) _then) = _$AdaptiveExposureConfigCopyWithImpl;
@useResult
$Res call({
 double targetSnr, double referenceSkyBrightnessMag, double minExposureSecs, double maxExposureSecs, Map<String, bool> perFilterEnabled, Map<String, double> perFilterMinSecs, Map<String, double> perFilterMaxSecs, bool enabled
});




}
/// @nodoc
class _$AdaptiveExposureConfigCopyWithImpl<$Res>
    implements $AdaptiveExposureConfigCopyWith<$Res> {
  _$AdaptiveExposureConfigCopyWithImpl(this._self, this._then);

  final AdaptiveExposureConfig _self;
  final $Res Function(AdaptiveExposureConfig) _then;

/// Create a copy of AdaptiveExposureConfig
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? targetSnr = null,Object? referenceSkyBrightnessMag = null,Object? minExposureSecs = null,Object? maxExposureSecs = null,Object? perFilterEnabled = null,Object? perFilterMinSecs = null,Object? perFilterMaxSecs = null,Object? enabled = null,}) {
  return _then(_self.copyWith(
targetSnr: null == targetSnr ? _self.targetSnr : targetSnr // ignore: cast_nullable_to_non_nullable
as double,referenceSkyBrightnessMag: null == referenceSkyBrightnessMag ? _self.referenceSkyBrightnessMag : referenceSkyBrightnessMag // ignore: cast_nullable_to_non_nullable
as double,minExposureSecs: null == minExposureSecs ? _self.minExposureSecs : minExposureSecs // ignore: cast_nullable_to_non_nullable
as double,maxExposureSecs: null == maxExposureSecs ? _self.maxExposureSecs : maxExposureSecs // ignore: cast_nullable_to_non_nullable
as double,perFilterEnabled: null == perFilterEnabled ? _self.perFilterEnabled : perFilterEnabled // ignore: cast_nullable_to_non_nullable
as Map<String, bool>,perFilterMinSecs: null == perFilterMinSecs ? _self.perFilterMinSecs : perFilterMinSecs // ignore: cast_nullable_to_non_nullable
as Map<String, double>,perFilterMaxSecs: null == perFilterMaxSecs ? _self.perFilterMaxSecs : perFilterMaxSecs // ignore: cast_nullable_to_non_nullable
as Map<String, double>,enabled: null == enabled ? _self.enabled : enabled // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [AdaptiveExposureConfig].
extension AdaptiveExposureConfigPatterns on AdaptiveExposureConfig {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AdaptiveExposureConfig value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AdaptiveExposureConfig() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AdaptiveExposureConfig value)  $default,){
final _that = this;
switch (_that) {
case _AdaptiveExposureConfig():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AdaptiveExposureConfig value)?  $default,){
final _that = this;
switch (_that) {
case _AdaptiveExposureConfig() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double targetSnr,  double referenceSkyBrightnessMag,  double minExposureSecs,  double maxExposureSecs,  Map<String, bool> perFilterEnabled,  Map<String, double> perFilterMinSecs,  Map<String, double> perFilterMaxSecs,  bool enabled)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AdaptiveExposureConfig() when $default != null:
return $default(_that.targetSnr,_that.referenceSkyBrightnessMag,_that.minExposureSecs,_that.maxExposureSecs,_that.perFilterEnabled,_that.perFilterMinSecs,_that.perFilterMaxSecs,_that.enabled);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double targetSnr,  double referenceSkyBrightnessMag,  double minExposureSecs,  double maxExposureSecs,  Map<String, bool> perFilterEnabled,  Map<String, double> perFilterMinSecs,  Map<String, double> perFilterMaxSecs,  bool enabled)  $default,) {final _that = this;
switch (_that) {
case _AdaptiveExposureConfig():
return $default(_that.targetSnr,_that.referenceSkyBrightnessMag,_that.minExposureSecs,_that.maxExposureSecs,_that.perFilterEnabled,_that.perFilterMinSecs,_that.perFilterMaxSecs,_that.enabled);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double targetSnr,  double referenceSkyBrightnessMag,  double minExposureSecs,  double maxExposureSecs,  Map<String, bool> perFilterEnabled,  Map<String, double> perFilterMinSecs,  Map<String, double> perFilterMaxSecs,  bool enabled)?  $default,) {final _that = this;
switch (_that) {
case _AdaptiveExposureConfig() when $default != null:
return $default(_that.targetSnr,_that.referenceSkyBrightnessMag,_that.minExposureSecs,_that.maxExposureSecs,_that.perFilterEnabled,_that.perFilterMinSecs,_that.perFilterMaxSecs,_that.enabled);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake)
class _AdaptiveExposureConfig extends AdaptiveExposureConfig {
  const _AdaptiveExposureConfig({this.targetSnr = 30.0, this.referenceSkyBrightnessMag = 21.5, this.minExposureSecs = 5.0, this.maxExposureSecs = 600.0, final  Map<String, bool> perFilterEnabled = const <String, bool>{}, final  Map<String, double> perFilterMinSecs = const <String, double>{}, final  Map<String, double> perFilterMaxSecs = const <String, double>{}, this.enabled = true}): _perFilterEnabled = perFilterEnabled,_perFilterMinSecs = perFilterMinSecs,_perFilterMaxSecs = perFilterMaxSecs,super._();
  factory _AdaptiveExposureConfig.fromJson(Map<String, dynamic> json) => _$AdaptiveExposureConfigFromJson(json);

/// Target SNR (informational; the current adapter scales by sky-
/// background flux ratio rather than aiming at a numeric target).
@override@JsonKey() final  double targetSnr;
/// Sky brightness in mag/arcsec² that the node's configured nominal
/// exposure is calibrated for.
@override@JsonKey() final  double referenceSkyBrightnessMag;
/// Global minimum exposure clamp (seconds).
@override@JsonKey() final  double minExposureSecs;
/// Global maximum exposure clamp (seconds).
@override@JsonKey() final  double maxExposureSecs;
/// Per-filter enable map. Filter name -> bool. Empty => apply globally.
 final  Map<String, bool> _perFilterEnabled;
/// Per-filter enable map. Filter name -> bool. Empty => apply globally.
@override@JsonKey() Map<String, bool> get perFilterEnabled {
  if (_perFilterEnabled is EqualUnmodifiableMapView) return _perFilterEnabled;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_perFilterEnabled);
}

/// Per-filter minimum exposure overrides (seconds).
 final  Map<String, double> _perFilterMinSecs;
/// Per-filter minimum exposure overrides (seconds).
@override@JsonKey() Map<String, double> get perFilterMinSecs {
  if (_perFilterMinSecs is EqualUnmodifiableMapView) return _perFilterMinSecs;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_perFilterMinSecs);
}

/// Per-filter maximum exposure overrides (seconds).
 final  Map<String, double> _perFilterMaxSecs;
/// Per-filter maximum exposure overrides (seconds).
@override@JsonKey() Map<String, double> get perFilterMaxSecs {
  if (_perFilterMaxSecs is EqualUnmodifiableMapView) return _perFilterMaxSecs;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_perFilterMaxSecs);
}

/// Global enable toggle. When false the whole config is a no-op
/// regardless of per-filter map content.
@override@JsonKey() final  bool enabled;

/// Create a copy of AdaptiveExposureConfig
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AdaptiveExposureConfigCopyWith<_AdaptiveExposureConfig> get copyWith => __$AdaptiveExposureConfigCopyWithImpl<_AdaptiveExposureConfig>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AdaptiveExposureConfigToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AdaptiveExposureConfig&&(identical(other.targetSnr, targetSnr) || other.targetSnr == targetSnr)&&(identical(other.referenceSkyBrightnessMag, referenceSkyBrightnessMag) || other.referenceSkyBrightnessMag == referenceSkyBrightnessMag)&&(identical(other.minExposureSecs, minExposureSecs) || other.minExposureSecs == minExposureSecs)&&(identical(other.maxExposureSecs, maxExposureSecs) || other.maxExposureSecs == maxExposureSecs)&&const DeepCollectionEquality().equals(other._perFilterEnabled, _perFilterEnabled)&&const DeepCollectionEquality().equals(other._perFilterMinSecs, _perFilterMinSecs)&&const DeepCollectionEquality().equals(other._perFilterMaxSecs, _perFilterMaxSecs)&&(identical(other.enabled, enabled) || other.enabled == enabled));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,targetSnr,referenceSkyBrightnessMag,minExposureSecs,maxExposureSecs,const DeepCollectionEquality().hash(_perFilterEnabled),const DeepCollectionEquality().hash(_perFilterMinSecs),const DeepCollectionEquality().hash(_perFilterMaxSecs),enabled);

@override
String toString() {
  return 'AdaptiveExposureConfig(targetSnr: $targetSnr, referenceSkyBrightnessMag: $referenceSkyBrightnessMag, minExposureSecs: $minExposureSecs, maxExposureSecs: $maxExposureSecs, perFilterEnabled: $perFilterEnabled, perFilterMinSecs: $perFilterMinSecs, perFilterMaxSecs: $perFilterMaxSecs, enabled: $enabled)';
}


}

/// @nodoc
abstract mixin class _$AdaptiveExposureConfigCopyWith<$Res> implements $AdaptiveExposureConfigCopyWith<$Res> {
  factory _$AdaptiveExposureConfigCopyWith(_AdaptiveExposureConfig value, $Res Function(_AdaptiveExposureConfig) _then) = __$AdaptiveExposureConfigCopyWithImpl;
@override @useResult
$Res call({
 double targetSnr, double referenceSkyBrightnessMag, double minExposureSecs, double maxExposureSecs, Map<String, bool> perFilterEnabled, Map<String, double> perFilterMinSecs, Map<String, double> perFilterMaxSecs, bool enabled
});




}
/// @nodoc
class __$AdaptiveExposureConfigCopyWithImpl<$Res>
    implements _$AdaptiveExposureConfigCopyWith<$Res> {
  __$AdaptiveExposureConfigCopyWithImpl(this._self, this._then);

  final _AdaptiveExposureConfig _self;
  final $Res Function(_AdaptiveExposureConfig) _then;

/// Create a copy of AdaptiveExposureConfig
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? targetSnr = null,Object? referenceSkyBrightnessMag = null,Object? minExposureSecs = null,Object? maxExposureSecs = null,Object? perFilterEnabled = null,Object? perFilterMinSecs = null,Object? perFilterMaxSecs = null,Object? enabled = null,}) {
  return _then(_AdaptiveExposureConfig(
targetSnr: null == targetSnr ? _self.targetSnr : targetSnr // ignore: cast_nullable_to_non_nullable
as double,referenceSkyBrightnessMag: null == referenceSkyBrightnessMag ? _self.referenceSkyBrightnessMag : referenceSkyBrightnessMag // ignore: cast_nullable_to_non_nullable
as double,minExposureSecs: null == minExposureSecs ? _self.minExposureSecs : minExposureSecs // ignore: cast_nullable_to_non_nullable
as double,maxExposureSecs: null == maxExposureSecs ? _self.maxExposureSecs : maxExposureSecs // ignore: cast_nullable_to_non_nullable
as double,perFilterEnabled: null == perFilterEnabled ? _self._perFilterEnabled : perFilterEnabled // ignore: cast_nullable_to_non_nullable
as Map<String, bool>,perFilterMinSecs: null == perFilterMinSecs ? _self._perFilterMinSecs : perFilterMinSecs // ignore: cast_nullable_to_non_nullable
as Map<String, double>,perFilterMaxSecs: null == perFilterMaxSecs ? _self._perFilterMaxSecs : perFilterMaxSecs // ignore: cast_nullable_to_non_nullable
as Map<String, double>,enabled: null == enabled ? _self.enabled : enabled // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}


/// @nodoc
mixin _$PhotometryQualityGates {

/// Minimum target SNR. AAVSO research-grade default is 50.
 double get minSnr;/// Maximum acceptable FWHM in arcseconds. Default 5".
 double get maxFwhmArcsec;/// When true, frames where any reference star failed to extract are
/// rejected.
 bool get requireAllRefsVisible;/// Maximum airmass. AAVSO Bright Star Monitor cut-off ≈ 2.5.
 double get maxAirmass;
/// Create a copy of PhotometryQualityGates
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PhotometryQualityGatesCopyWith<PhotometryQualityGates> get copyWith => _$PhotometryQualityGatesCopyWithImpl<PhotometryQualityGates>(this as PhotometryQualityGates, _$identity);

  /// Serializes this PhotometryQualityGates to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PhotometryQualityGates&&(identical(other.minSnr, minSnr) || other.minSnr == minSnr)&&(identical(other.maxFwhmArcsec, maxFwhmArcsec) || other.maxFwhmArcsec == maxFwhmArcsec)&&(identical(other.requireAllRefsVisible, requireAllRefsVisible) || other.requireAllRefsVisible == requireAllRefsVisible)&&(identical(other.maxAirmass, maxAirmass) || other.maxAirmass == maxAirmass));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,minSnr,maxFwhmArcsec,requireAllRefsVisible,maxAirmass);

@override
String toString() {
  return 'PhotometryQualityGates(minSnr: $minSnr, maxFwhmArcsec: $maxFwhmArcsec, requireAllRefsVisible: $requireAllRefsVisible, maxAirmass: $maxAirmass)';
}


}

/// @nodoc
abstract mixin class $PhotometryQualityGatesCopyWith<$Res>  {
  factory $PhotometryQualityGatesCopyWith(PhotometryQualityGates value, $Res Function(PhotometryQualityGates) _then) = _$PhotometryQualityGatesCopyWithImpl;
@useResult
$Res call({
 double minSnr, double maxFwhmArcsec, bool requireAllRefsVisible, double maxAirmass
});




}
/// @nodoc
class _$PhotometryQualityGatesCopyWithImpl<$Res>
    implements $PhotometryQualityGatesCopyWith<$Res> {
  _$PhotometryQualityGatesCopyWithImpl(this._self, this._then);

  final PhotometryQualityGates _self;
  final $Res Function(PhotometryQualityGates) _then;

/// Create a copy of PhotometryQualityGates
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? minSnr = null,Object? maxFwhmArcsec = null,Object? requireAllRefsVisible = null,Object? maxAirmass = null,}) {
  return _then(_self.copyWith(
minSnr: null == minSnr ? _self.minSnr : minSnr // ignore: cast_nullable_to_non_nullable
as double,maxFwhmArcsec: null == maxFwhmArcsec ? _self.maxFwhmArcsec : maxFwhmArcsec // ignore: cast_nullable_to_non_nullable
as double,requireAllRefsVisible: null == requireAllRefsVisible ? _self.requireAllRefsVisible : requireAllRefsVisible // ignore: cast_nullable_to_non_nullable
as bool,maxAirmass: null == maxAirmass ? _self.maxAirmass : maxAirmass // ignore: cast_nullable_to_non_nullable
as double,
  ));
}

}


/// Adds pattern-matching-related methods to [PhotometryQualityGates].
extension PhotometryQualityGatesPatterns on PhotometryQualityGates {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PhotometryQualityGates value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PhotometryQualityGates() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PhotometryQualityGates value)  $default,){
final _that = this;
switch (_that) {
case _PhotometryQualityGates():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PhotometryQualityGates value)?  $default,){
final _that = this;
switch (_that) {
case _PhotometryQualityGates() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double minSnr,  double maxFwhmArcsec,  bool requireAllRefsVisible,  double maxAirmass)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PhotometryQualityGates() when $default != null:
return $default(_that.minSnr,_that.maxFwhmArcsec,_that.requireAllRefsVisible,_that.maxAirmass);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double minSnr,  double maxFwhmArcsec,  bool requireAllRefsVisible,  double maxAirmass)  $default,) {final _that = this;
switch (_that) {
case _PhotometryQualityGates():
return $default(_that.minSnr,_that.maxFwhmArcsec,_that.requireAllRefsVisible,_that.maxAirmass);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double minSnr,  double maxFwhmArcsec,  bool requireAllRefsVisible,  double maxAirmass)?  $default,) {final _that = this;
switch (_that) {
case _PhotometryQualityGates() when $default != null:
return $default(_that.minSnr,_that.maxFwhmArcsec,_that.requireAllRefsVisible,_that.maxAirmass);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake)
class _PhotometryQualityGates implements PhotometryQualityGates {
  const _PhotometryQualityGates({this.minSnr = 50.0, this.maxFwhmArcsec = 5.0, this.requireAllRefsVisible = true, this.maxAirmass = 2.5});
  factory _PhotometryQualityGates.fromJson(Map<String, dynamic> json) => _$PhotometryQualityGatesFromJson(json);

/// Minimum target SNR. AAVSO research-grade default is 50.
@override@JsonKey() final  double minSnr;
/// Maximum acceptable FWHM in arcseconds. Default 5".
@override@JsonKey() final  double maxFwhmArcsec;
/// When true, frames where any reference star failed to extract are
/// rejected.
@override@JsonKey() final  bool requireAllRefsVisible;
/// Maximum airmass. AAVSO Bright Star Monitor cut-off ≈ 2.5.
@override@JsonKey() final  double maxAirmass;

/// Create a copy of PhotometryQualityGates
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PhotometryQualityGatesCopyWith<_PhotometryQualityGates> get copyWith => __$PhotometryQualityGatesCopyWithImpl<_PhotometryQualityGates>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PhotometryQualityGatesToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PhotometryQualityGates&&(identical(other.minSnr, minSnr) || other.minSnr == minSnr)&&(identical(other.maxFwhmArcsec, maxFwhmArcsec) || other.maxFwhmArcsec == maxFwhmArcsec)&&(identical(other.requireAllRefsVisible, requireAllRefsVisible) || other.requireAllRefsVisible == requireAllRefsVisible)&&(identical(other.maxAirmass, maxAirmass) || other.maxAirmass == maxAirmass));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,minSnr,maxFwhmArcsec,requireAllRefsVisible,maxAirmass);

@override
String toString() {
  return 'PhotometryQualityGates(minSnr: $minSnr, maxFwhmArcsec: $maxFwhmArcsec, requireAllRefsVisible: $requireAllRefsVisible, maxAirmass: $maxAirmass)';
}


}

/// @nodoc
abstract mixin class _$PhotometryQualityGatesCopyWith<$Res> implements $PhotometryQualityGatesCopyWith<$Res> {
  factory _$PhotometryQualityGatesCopyWith(_PhotometryQualityGates value, $Res Function(_PhotometryQualityGates) _then) = __$PhotometryQualityGatesCopyWithImpl;
@override @useResult
$Res call({
 double minSnr, double maxFwhmArcsec, bool requireAllRefsVisible, double maxAirmass
});




}
/// @nodoc
class __$PhotometryQualityGatesCopyWithImpl<$Res>
    implements _$PhotometryQualityGatesCopyWith<$Res> {
  __$PhotometryQualityGatesCopyWithImpl(this._self, this._then);

  final _PhotometryQualityGates _self;
  final $Res Function(_PhotometryQualityGates) _then;

/// Create a copy of PhotometryQualityGates
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? minSnr = null,Object? maxFwhmArcsec = null,Object? requireAllRefsVisible = null,Object? maxAirmass = null,}) {
  return _then(_PhotometryQualityGates(
minSnr: null == minSnr ? _self.minSnr : minSnr // ignore: cast_nullable_to_non_nullable
as double,maxFwhmArcsec: null == maxFwhmArcsec ? _self.maxFwhmArcsec : maxFwhmArcsec // ignore: cast_nullable_to_non_nullable
as double,requireAllRefsVisible: null == requireAllRefsVisible ? _self.requireAllRefsVisible : requireAllRefsVisible // ignore: cast_nullable_to_non_nullable
as bool,maxAirmass: null == maxAirmass ? _self.maxAirmass : maxAirmass // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}


/// @nodoc
mixin _$TransparencyBackupPlan {

/// Filter to switch to when transparency drops (e.g. `"Lum"`).
 String? get backupFilter;/// Sequence node id to skip to when transparency drops.
 String? get backupTargetId;/// Optional human-readable description surfaced in the UI / logs.
 String? get description;
/// Create a copy of TransparencyBackupPlan
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TransparencyBackupPlanCopyWith<TransparencyBackupPlan> get copyWith => _$TransparencyBackupPlanCopyWithImpl<TransparencyBackupPlan>(this as TransparencyBackupPlan, _$identity);

  /// Serializes this TransparencyBackupPlan to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TransparencyBackupPlan&&(identical(other.backupFilter, backupFilter) || other.backupFilter == backupFilter)&&(identical(other.backupTargetId, backupTargetId) || other.backupTargetId == backupTargetId)&&(identical(other.description, description) || other.description == description));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,backupFilter,backupTargetId,description);

@override
String toString() {
  return 'TransparencyBackupPlan(backupFilter: $backupFilter, backupTargetId: $backupTargetId, description: $description)';
}


}

/// @nodoc
abstract mixin class $TransparencyBackupPlanCopyWith<$Res>  {
  factory $TransparencyBackupPlanCopyWith(TransparencyBackupPlan value, $Res Function(TransparencyBackupPlan) _then) = _$TransparencyBackupPlanCopyWithImpl;
@useResult
$Res call({
 String? backupFilter, String? backupTargetId, String? description
});




}
/// @nodoc
class _$TransparencyBackupPlanCopyWithImpl<$Res>
    implements $TransparencyBackupPlanCopyWith<$Res> {
  _$TransparencyBackupPlanCopyWithImpl(this._self, this._then);

  final TransparencyBackupPlan _self;
  final $Res Function(TransparencyBackupPlan) _then;

/// Create a copy of TransparencyBackupPlan
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? backupFilter = freezed,Object? backupTargetId = freezed,Object? description = freezed,}) {
  return _then(_self.copyWith(
backupFilter: freezed == backupFilter ? _self.backupFilter : backupFilter // ignore: cast_nullable_to_non_nullable
as String?,backupTargetId: freezed == backupTargetId ? _self.backupTargetId : backupTargetId // ignore: cast_nullable_to_non_nullable
as String?,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [TransparencyBackupPlan].
extension TransparencyBackupPlanPatterns on TransparencyBackupPlan {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TransparencyBackupPlan value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TransparencyBackupPlan() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TransparencyBackupPlan value)  $default,){
final _that = this;
switch (_that) {
case _TransparencyBackupPlan():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TransparencyBackupPlan value)?  $default,){
final _that = this;
switch (_that) {
case _TransparencyBackupPlan() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? backupFilter,  String? backupTargetId,  String? description)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TransparencyBackupPlan() when $default != null:
return $default(_that.backupFilter,_that.backupTargetId,_that.description);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? backupFilter,  String? backupTargetId,  String? description)  $default,) {final _that = this;
switch (_that) {
case _TransparencyBackupPlan():
return $default(_that.backupFilter,_that.backupTargetId,_that.description);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? backupFilter,  String? backupTargetId,  String? description)?  $default,) {final _that = this;
switch (_that) {
case _TransparencyBackupPlan() when $default != null:
return $default(_that.backupFilter,_that.backupTargetId,_that.description);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake, includeIfNull: true)
class _TransparencyBackupPlan extends TransparencyBackupPlan {
  const _TransparencyBackupPlan({this.backupFilter, this.backupTargetId, this.description}): super._();
  factory _TransparencyBackupPlan.fromJson(Map<String, dynamic> json) => _$TransparencyBackupPlanFromJson(json);

/// Filter to switch to when transparency drops (e.g. `"Lum"`).
@override final  String? backupFilter;
/// Sequence node id to skip to when transparency drops.
@override final  String? backupTargetId;
/// Optional human-readable description surfaced in the UI / logs.
@override final  String? description;

/// Create a copy of TransparencyBackupPlan
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TransparencyBackupPlanCopyWith<_TransparencyBackupPlan> get copyWith => __$TransparencyBackupPlanCopyWithImpl<_TransparencyBackupPlan>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$TransparencyBackupPlanToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TransparencyBackupPlan&&(identical(other.backupFilter, backupFilter) || other.backupFilter == backupFilter)&&(identical(other.backupTargetId, backupTargetId) || other.backupTargetId == backupTargetId)&&(identical(other.description, description) || other.description == description));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,backupFilter,backupTargetId,description);

@override
String toString() {
  return 'TransparencyBackupPlan(backupFilter: $backupFilter, backupTargetId: $backupTargetId, description: $description)';
}


}

/// @nodoc
abstract mixin class _$TransparencyBackupPlanCopyWith<$Res> implements $TransparencyBackupPlanCopyWith<$Res> {
  factory _$TransparencyBackupPlanCopyWith(_TransparencyBackupPlan value, $Res Function(_TransparencyBackupPlan) _then) = __$TransparencyBackupPlanCopyWithImpl;
@override @useResult
$Res call({
 String? backupFilter, String? backupTargetId, String? description
});




}
/// @nodoc
class __$TransparencyBackupPlanCopyWithImpl<$Res>
    implements _$TransparencyBackupPlanCopyWith<$Res> {
  __$TransparencyBackupPlanCopyWithImpl(this._self, this._then);

  final _TransparencyBackupPlan _self;
  final $Res Function(_TransparencyBackupPlan) _then;

/// Create a copy of TransparencyBackupPlan
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? backupFilter = freezed,Object? backupTargetId = freezed,Object? description = freezed,}) {
  return _then(_TransparencyBackupPlan(
backupFilter: freezed == backupFilter ? _self.backupFilter : backupFilter // ignore: cast_nullable_to_non_nullable
as String?,backupTargetId: freezed == backupTargetId ? _self.backupTargetId : backupTargetId // ignore: cast_nullable_to_non_nullable
as String?,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
mixin _$Sequence {

 String get id; int? get databaseId; String get name; String get description; Map<String, SequenceNode> get nodes; String? get rootNodeId; DateTime get createdAt; DateTime get modifiedAt; bool get isTemplate; int? get estimatedDurationMins;
/// Create a copy of Sequence
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequenceCopyWith<Sequence> get copyWith => _$SequenceCopyWithImpl<Sequence>(this as Sequence, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Sequence&&(identical(other.id, id) || other.id == id)&&(identical(other.databaseId, databaseId) || other.databaseId == databaseId)&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&const DeepCollectionEquality().equals(other.nodes, nodes)&&(identical(other.rootNodeId, rootNodeId) || other.rootNodeId == rootNodeId)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.modifiedAt, modifiedAt) || other.modifiedAt == modifiedAt)&&(identical(other.isTemplate, isTemplate) || other.isTemplate == isTemplate)&&(identical(other.estimatedDurationMins, estimatedDurationMins) || other.estimatedDurationMins == estimatedDurationMins));
}


@override
int get hashCode => Object.hash(runtimeType,id,databaseId,name,description,const DeepCollectionEquality().hash(nodes),rootNodeId,createdAt,modifiedAt,isTemplate,estimatedDurationMins);

@override
String toString() {
  return 'Sequence(id: $id, databaseId: $databaseId, name: $name, description: $description, nodes: $nodes, rootNodeId: $rootNodeId, createdAt: $createdAt, modifiedAt: $modifiedAt, isTemplate: $isTemplate, estimatedDurationMins: $estimatedDurationMins)';
}


}

/// @nodoc
abstract mixin class $SequenceCopyWith<$Res>  {
  factory $SequenceCopyWith(Sequence value, $Res Function(Sequence) _then) = _$SequenceCopyWithImpl;
@useResult
$Res call({
 String id, int? databaseId, String name, String description, Map<String, SequenceNode> nodes, String? rootNodeId, DateTime createdAt, DateTime modifiedAt, bool isTemplate, int? estimatedDurationMins
});




}
/// @nodoc
class _$SequenceCopyWithImpl<$Res>
    implements $SequenceCopyWith<$Res> {
  _$SequenceCopyWithImpl(this._self, this._then);

  final Sequence _self;
  final $Res Function(Sequence) _then;

/// Create a copy of Sequence
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? databaseId = freezed,Object? name = null,Object? description = null,Object? nodes = null,Object? rootNodeId = freezed,Object? createdAt = null,Object? modifiedAt = null,Object? isTemplate = null,Object? estimatedDurationMins = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,databaseId: freezed == databaseId ? _self.databaseId : databaseId // ignore: cast_nullable_to_non_nullable
as int?,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: null == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String,nodes: null == nodes ? _self.nodes : nodes // ignore: cast_nullable_to_non_nullable
as Map<String, SequenceNode>,rootNodeId: freezed == rootNodeId ? _self.rootNodeId : rootNodeId // ignore: cast_nullable_to_non_nullable
as String?,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,modifiedAt: null == modifiedAt ? _self.modifiedAt : modifiedAt // ignore: cast_nullable_to_non_nullable
as DateTime,isTemplate: null == isTemplate ? _self.isTemplate : isTemplate // ignore: cast_nullable_to_non_nullable
as bool,estimatedDurationMins: freezed == estimatedDurationMins ? _self.estimatedDurationMins : estimatedDurationMins // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}

}


/// Adds pattern-matching-related methods to [Sequence].
extension SequencePatterns on Sequence {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Sequence value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Sequence() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Sequence value)  $default,){
final _that = this;
switch (_that) {
case _Sequence():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Sequence value)?  $default,){
final _that = this;
switch (_that) {
case _Sequence() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  int? databaseId,  String name,  String description,  Map<String, SequenceNode> nodes,  String? rootNodeId,  DateTime createdAt,  DateTime modifiedAt,  bool isTemplate,  int? estimatedDurationMins)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Sequence() when $default != null:
return $default(_that.id,_that.databaseId,_that.name,_that.description,_that.nodes,_that.rootNodeId,_that.createdAt,_that.modifiedAt,_that.isTemplate,_that.estimatedDurationMins);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  int? databaseId,  String name,  String description,  Map<String, SequenceNode> nodes,  String? rootNodeId,  DateTime createdAt,  DateTime modifiedAt,  bool isTemplate,  int? estimatedDurationMins)  $default,) {final _that = this;
switch (_that) {
case _Sequence():
return $default(_that.id,_that.databaseId,_that.name,_that.description,_that.nodes,_that.rootNodeId,_that.createdAt,_that.modifiedAt,_that.isTemplate,_that.estimatedDurationMins);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  int? databaseId,  String name,  String description,  Map<String, SequenceNode> nodes,  String? rootNodeId,  DateTime createdAt,  DateTime modifiedAt,  bool isTemplate,  int? estimatedDurationMins)?  $default,) {final _that = this;
switch (_that) {
case _Sequence() when $default != null:
return $default(_that.id,_that.databaseId,_that.name,_that.description,_that.nodes,_that.rootNodeId,_that.createdAt,_that.modifiedAt,_that.isTemplate,_that.estimatedDurationMins);case _:
  return null;

}
}

}

/// @nodoc


class _Sequence extends Sequence {
  const _Sequence({required this.id, this.databaseId, required this.name, this.description = '', final  Map<String, SequenceNode> nodes = const <String, SequenceNode>{}, this.rootNodeId, required this.createdAt, required this.modifiedAt, this.isTemplate = false, this.estimatedDurationMins}): _nodes = nodes,super._();
  

@override final  String id;
@override final  int? databaseId;
@override final  String name;
@override@JsonKey() final  String description;
 final  Map<String, SequenceNode> _nodes;
@override@JsonKey() Map<String, SequenceNode> get nodes {
  if (_nodes is EqualUnmodifiableMapView) return _nodes;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_nodes);
}

@override final  String? rootNodeId;
@override final  DateTime createdAt;
@override final  DateTime modifiedAt;
@override@JsonKey() final  bool isTemplate;
@override final  int? estimatedDurationMins;

/// Create a copy of Sequence
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SequenceCopyWith<_Sequence> get copyWith => __$SequenceCopyWithImpl<_Sequence>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Sequence&&(identical(other.id, id) || other.id == id)&&(identical(other.databaseId, databaseId) || other.databaseId == databaseId)&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&const DeepCollectionEquality().equals(other._nodes, _nodes)&&(identical(other.rootNodeId, rootNodeId) || other.rootNodeId == rootNodeId)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.modifiedAt, modifiedAt) || other.modifiedAt == modifiedAt)&&(identical(other.isTemplate, isTemplate) || other.isTemplate == isTemplate)&&(identical(other.estimatedDurationMins, estimatedDurationMins) || other.estimatedDurationMins == estimatedDurationMins));
}


@override
int get hashCode => Object.hash(runtimeType,id,databaseId,name,description,const DeepCollectionEquality().hash(_nodes),rootNodeId,createdAt,modifiedAt,isTemplate,estimatedDurationMins);

@override
String toString() {
  return 'Sequence(id: $id, databaseId: $databaseId, name: $name, description: $description, nodes: $nodes, rootNodeId: $rootNodeId, createdAt: $createdAt, modifiedAt: $modifiedAt, isTemplate: $isTemplate, estimatedDurationMins: $estimatedDurationMins)';
}


}

/// @nodoc
abstract mixin class _$SequenceCopyWith<$Res> implements $SequenceCopyWith<$Res> {
  factory _$SequenceCopyWith(_Sequence value, $Res Function(_Sequence) _then) = __$SequenceCopyWithImpl;
@override @useResult
$Res call({
 String id, int? databaseId, String name, String description, Map<String, SequenceNode> nodes, String? rootNodeId, DateTime createdAt, DateTime modifiedAt, bool isTemplate, int? estimatedDurationMins
});




}
/// @nodoc
class __$SequenceCopyWithImpl<$Res>
    implements _$SequenceCopyWith<$Res> {
  __$SequenceCopyWithImpl(this._self, this._then);

  final _Sequence _self;
  final $Res Function(_Sequence) _then;

/// Create a copy of Sequence
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? databaseId = freezed,Object? name = null,Object? description = null,Object? nodes = null,Object? rootNodeId = freezed,Object? createdAt = null,Object? modifiedAt = null,Object? isTemplate = null,Object? estimatedDurationMins = freezed,}) {
  return _then(_Sequence(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,databaseId: freezed == databaseId ? _self.databaseId : databaseId // ignore: cast_nullable_to_non_nullable
as int?,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: null == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String,nodes: null == nodes ? _self._nodes : nodes // ignore: cast_nullable_to_non_nullable
as Map<String, SequenceNode>,rootNodeId: freezed == rootNodeId ? _self.rootNodeId : rootNodeId // ignore: cast_nullable_to_non_nullable
as String?,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,modifiedAt: null == modifiedAt ? _self.modifiedAt : modifiedAt // ignore: cast_nullable_to_non_nullable
as DateTime,isTemplate: null == isTemplate ? _self.isTemplate : isTemplate // ignore: cast_nullable_to_non_nullable
as bool,estimatedDurationMins: freezed == estimatedDurationMins ? _self.estimatedDurationMins : estimatedDurationMins // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}

/// @nodoc
mixin _$SequenceProgress {

 SequenceExecutionState get state; String? get currentNodeId; String? get currentNodeName; NodeStatus? get currentNodeStatus; int get totalExposures; int get completedExposures; double get totalIntegrationSecs; double get completedIntegrationSecs; double get elapsedSecs; double? get estimatedRemainingSecs; String? get currentTarget; String? get currentFilter; String? get message; Map<String, NodeStatus> get nodeStatuses;/// Per-node instruction progress (0-100 percent)
 Map<String, double> get nodeProgressPercent;/// Per-node instruction progress detail message
 Map<String, String> get nodeProgressDetail;/// Per-node structured instruction progress detail.
 Map<String, InstructionProgressDetail> get nodeProgressStructuredDetail;
/// Create a copy of SequenceProgress
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SequenceProgressCopyWith<SequenceProgress> get copyWith => _$SequenceProgressCopyWithImpl<SequenceProgress>(this as SequenceProgress, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SequenceProgress&&(identical(other.state, state) || other.state == state)&&(identical(other.currentNodeId, currentNodeId) || other.currentNodeId == currentNodeId)&&(identical(other.currentNodeName, currentNodeName) || other.currentNodeName == currentNodeName)&&(identical(other.currentNodeStatus, currentNodeStatus) || other.currentNodeStatus == currentNodeStatus)&&(identical(other.totalExposures, totalExposures) || other.totalExposures == totalExposures)&&(identical(other.completedExposures, completedExposures) || other.completedExposures == completedExposures)&&(identical(other.totalIntegrationSecs, totalIntegrationSecs) || other.totalIntegrationSecs == totalIntegrationSecs)&&(identical(other.completedIntegrationSecs, completedIntegrationSecs) || other.completedIntegrationSecs == completedIntegrationSecs)&&(identical(other.elapsedSecs, elapsedSecs) || other.elapsedSecs == elapsedSecs)&&(identical(other.estimatedRemainingSecs, estimatedRemainingSecs) || other.estimatedRemainingSecs == estimatedRemainingSecs)&&(identical(other.currentTarget, currentTarget) || other.currentTarget == currentTarget)&&(identical(other.currentFilter, currentFilter) || other.currentFilter == currentFilter)&&(identical(other.message, message) || other.message == message)&&const DeepCollectionEquality().equals(other.nodeStatuses, nodeStatuses)&&const DeepCollectionEquality().equals(other.nodeProgressPercent, nodeProgressPercent)&&const DeepCollectionEquality().equals(other.nodeProgressDetail, nodeProgressDetail)&&const DeepCollectionEquality().equals(other.nodeProgressStructuredDetail, nodeProgressStructuredDetail));
}


@override
int get hashCode => Object.hash(runtimeType,state,currentNodeId,currentNodeName,currentNodeStatus,totalExposures,completedExposures,totalIntegrationSecs,completedIntegrationSecs,elapsedSecs,estimatedRemainingSecs,currentTarget,currentFilter,message,const DeepCollectionEquality().hash(nodeStatuses),const DeepCollectionEquality().hash(nodeProgressPercent),const DeepCollectionEquality().hash(nodeProgressDetail),const DeepCollectionEquality().hash(nodeProgressStructuredDetail));

@override
String toString() {
  return 'SequenceProgress(state: $state, currentNodeId: $currentNodeId, currentNodeName: $currentNodeName, currentNodeStatus: $currentNodeStatus, totalExposures: $totalExposures, completedExposures: $completedExposures, totalIntegrationSecs: $totalIntegrationSecs, completedIntegrationSecs: $completedIntegrationSecs, elapsedSecs: $elapsedSecs, estimatedRemainingSecs: $estimatedRemainingSecs, currentTarget: $currentTarget, currentFilter: $currentFilter, message: $message, nodeStatuses: $nodeStatuses, nodeProgressPercent: $nodeProgressPercent, nodeProgressDetail: $nodeProgressDetail, nodeProgressStructuredDetail: $nodeProgressStructuredDetail)';
}


}

/// @nodoc
abstract mixin class $SequenceProgressCopyWith<$Res>  {
  factory $SequenceProgressCopyWith(SequenceProgress value, $Res Function(SequenceProgress) _then) = _$SequenceProgressCopyWithImpl;
@useResult
$Res call({
 SequenceExecutionState state, String? currentNodeId, String? currentNodeName, NodeStatus? currentNodeStatus, int totalExposures, int completedExposures, double totalIntegrationSecs, double completedIntegrationSecs, double elapsedSecs, double? estimatedRemainingSecs, String? currentTarget, String? currentFilter, String? message, Map<String, NodeStatus> nodeStatuses, Map<String, double> nodeProgressPercent, Map<String, String> nodeProgressDetail, Map<String, InstructionProgressDetail> nodeProgressStructuredDetail
});




}
/// @nodoc
class _$SequenceProgressCopyWithImpl<$Res>
    implements $SequenceProgressCopyWith<$Res> {
  _$SequenceProgressCopyWithImpl(this._self, this._then);

  final SequenceProgress _self;
  final $Res Function(SequenceProgress) _then;

/// Create a copy of SequenceProgress
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? state = null,Object? currentNodeId = freezed,Object? currentNodeName = freezed,Object? currentNodeStatus = freezed,Object? totalExposures = null,Object? completedExposures = null,Object? totalIntegrationSecs = null,Object? completedIntegrationSecs = null,Object? elapsedSecs = null,Object? estimatedRemainingSecs = freezed,Object? currentTarget = freezed,Object? currentFilter = freezed,Object? message = freezed,Object? nodeStatuses = null,Object? nodeProgressPercent = null,Object? nodeProgressDetail = null,Object? nodeProgressStructuredDetail = null,}) {
  return _then(_self.copyWith(
state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as SequenceExecutionState,currentNodeId: freezed == currentNodeId ? _self.currentNodeId : currentNodeId // ignore: cast_nullable_to_non_nullable
as String?,currentNodeName: freezed == currentNodeName ? _self.currentNodeName : currentNodeName // ignore: cast_nullable_to_non_nullable
as String?,currentNodeStatus: freezed == currentNodeStatus ? _self.currentNodeStatus : currentNodeStatus // ignore: cast_nullable_to_non_nullable
as NodeStatus?,totalExposures: null == totalExposures ? _self.totalExposures : totalExposures // ignore: cast_nullable_to_non_nullable
as int,completedExposures: null == completedExposures ? _self.completedExposures : completedExposures // ignore: cast_nullable_to_non_nullable
as int,totalIntegrationSecs: null == totalIntegrationSecs ? _self.totalIntegrationSecs : totalIntegrationSecs // ignore: cast_nullable_to_non_nullable
as double,completedIntegrationSecs: null == completedIntegrationSecs ? _self.completedIntegrationSecs : completedIntegrationSecs // ignore: cast_nullable_to_non_nullable
as double,elapsedSecs: null == elapsedSecs ? _self.elapsedSecs : elapsedSecs // ignore: cast_nullable_to_non_nullable
as double,estimatedRemainingSecs: freezed == estimatedRemainingSecs ? _self.estimatedRemainingSecs : estimatedRemainingSecs // ignore: cast_nullable_to_non_nullable
as double?,currentTarget: freezed == currentTarget ? _self.currentTarget : currentTarget // ignore: cast_nullable_to_non_nullable
as String?,currentFilter: freezed == currentFilter ? _self.currentFilter : currentFilter // ignore: cast_nullable_to_non_nullable
as String?,message: freezed == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String?,nodeStatuses: null == nodeStatuses ? _self.nodeStatuses : nodeStatuses // ignore: cast_nullable_to_non_nullable
as Map<String, NodeStatus>,nodeProgressPercent: null == nodeProgressPercent ? _self.nodeProgressPercent : nodeProgressPercent // ignore: cast_nullable_to_non_nullable
as Map<String, double>,nodeProgressDetail: null == nodeProgressDetail ? _self.nodeProgressDetail : nodeProgressDetail // ignore: cast_nullable_to_non_nullable
as Map<String, String>,nodeProgressStructuredDetail: null == nodeProgressStructuredDetail ? _self.nodeProgressStructuredDetail : nodeProgressStructuredDetail // ignore: cast_nullable_to_non_nullable
as Map<String, InstructionProgressDetail>,
  ));
}

}


/// Adds pattern-matching-related methods to [SequenceProgress].
extension SequenceProgressPatterns on SequenceProgress {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SequenceProgress value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SequenceProgress() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SequenceProgress value)  $default,){
final _that = this;
switch (_that) {
case _SequenceProgress():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SequenceProgress value)?  $default,){
final _that = this;
switch (_that) {
case _SequenceProgress() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( SequenceExecutionState state,  String? currentNodeId,  String? currentNodeName,  NodeStatus? currentNodeStatus,  int totalExposures,  int completedExposures,  double totalIntegrationSecs,  double completedIntegrationSecs,  double elapsedSecs,  double? estimatedRemainingSecs,  String? currentTarget,  String? currentFilter,  String? message,  Map<String, NodeStatus> nodeStatuses,  Map<String, double> nodeProgressPercent,  Map<String, String> nodeProgressDetail,  Map<String, InstructionProgressDetail> nodeProgressStructuredDetail)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SequenceProgress() when $default != null:
return $default(_that.state,_that.currentNodeId,_that.currentNodeName,_that.currentNodeStatus,_that.totalExposures,_that.completedExposures,_that.totalIntegrationSecs,_that.completedIntegrationSecs,_that.elapsedSecs,_that.estimatedRemainingSecs,_that.currentTarget,_that.currentFilter,_that.message,_that.nodeStatuses,_that.nodeProgressPercent,_that.nodeProgressDetail,_that.nodeProgressStructuredDetail);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( SequenceExecutionState state,  String? currentNodeId,  String? currentNodeName,  NodeStatus? currentNodeStatus,  int totalExposures,  int completedExposures,  double totalIntegrationSecs,  double completedIntegrationSecs,  double elapsedSecs,  double? estimatedRemainingSecs,  String? currentTarget,  String? currentFilter,  String? message,  Map<String, NodeStatus> nodeStatuses,  Map<String, double> nodeProgressPercent,  Map<String, String> nodeProgressDetail,  Map<String, InstructionProgressDetail> nodeProgressStructuredDetail)  $default,) {final _that = this;
switch (_that) {
case _SequenceProgress():
return $default(_that.state,_that.currentNodeId,_that.currentNodeName,_that.currentNodeStatus,_that.totalExposures,_that.completedExposures,_that.totalIntegrationSecs,_that.completedIntegrationSecs,_that.elapsedSecs,_that.estimatedRemainingSecs,_that.currentTarget,_that.currentFilter,_that.message,_that.nodeStatuses,_that.nodeProgressPercent,_that.nodeProgressDetail,_that.nodeProgressStructuredDetail);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( SequenceExecutionState state,  String? currentNodeId,  String? currentNodeName,  NodeStatus? currentNodeStatus,  int totalExposures,  int completedExposures,  double totalIntegrationSecs,  double completedIntegrationSecs,  double elapsedSecs,  double? estimatedRemainingSecs,  String? currentTarget,  String? currentFilter,  String? message,  Map<String, NodeStatus> nodeStatuses,  Map<String, double> nodeProgressPercent,  Map<String, String> nodeProgressDetail,  Map<String, InstructionProgressDetail> nodeProgressStructuredDetail)?  $default,) {final _that = this;
switch (_that) {
case _SequenceProgress() when $default != null:
return $default(_that.state,_that.currentNodeId,_that.currentNodeName,_that.currentNodeStatus,_that.totalExposures,_that.completedExposures,_that.totalIntegrationSecs,_that.completedIntegrationSecs,_that.elapsedSecs,_that.estimatedRemainingSecs,_that.currentTarget,_that.currentFilter,_that.message,_that.nodeStatuses,_that.nodeProgressPercent,_that.nodeProgressDetail,_that.nodeProgressStructuredDetail);case _:
  return null;

}
}

}

/// @nodoc


class _SequenceProgress extends SequenceProgress {
  const _SequenceProgress({this.state = SequenceExecutionState.idle, this.currentNodeId, this.currentNodeName, this.currentNodeStatus, this.totalExposures = 0, this.completedExposures = 0, this.totalIntegrationSecs = 0.0, this.completedIntegrationSecs = 0.0, this.elapsedSecs = 0.0, this.estimatedRemainingSecs, this.currentTarget, this.currentFilter, this.message, final  Map<String, NodeStatus> nodeStatuses = const <String, NodeStatus>{}, final  Map<String, double> nodeProgressPercent = const <String, double>{}, final  Map<String, String> nodeProgressDetail = const <String, String>{}, final  Map<String, InstructionProgressDetail> nodeProgressStructuredDetail = const <String, InstructionProgressDetail>{}}): _nodeStatuses = nodeStatuses,_nodeProgressPercent = nodeProgressPercent,_nodeProgressDetail = nodeProgressDetail,_nodeProgressStructuredDetail = nodeProgressStructuredDetail,super._();
  

@override@JsonKey() final  SequenceExecutionState state;
@override final  String? currentNodeId;
@override final  String? currentNodeName;
@override final  NodeStatus? currentNodeStatus;
@override@JsonKey() final  int totalExposures;
@override@JsonKey() final  int completedExposures;
@override@JsonKey() final  double totalIntegrationSecs;
@override@JsonKey() final  double completedIntegrationSecs;
@override@JsonKey() final  double elapsedSecs;
@override final  double? estimatedRemainingSecs;
@override final  String? currentTarget;
@override final  String? currentFilter;
@override final  String? message;
 final  Map<String, NodeStatus> _nodeStatuses;
@override@JsonKey() Map<String, NodeStatus> get nodeStatuses {
  if (_nodeStatuses is EqualUnmodifiableMapView) return _nodeStatuses;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_nodeStatuses);
}

/// Per-node instruction progress (0-100 percent)
 final  Map<String, double> _nodeProgressPercent;
/// Per-node instruction progress (0-100 percent)
@override@JsonKey() Map<String, double> get nodeProgressPercent {
  if (_nodeProgressPercent is EqualUnmodifiableMapView) return _nodeProgressPercent;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_nodeProgressPercent);
}

/// Per-node instruction progress detail message
 final  Map<String, String> _nodeProgressDetail;
/// Per-node instruction progress detail message
@override@JsonKey() Map<String, String> get nodeProgressDetail {
  if (_nodeProgressDetail is EqualUnmodifiableMapView) return _nodeProgressDetail;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_nodeProgressDetail);
}

/// Per-node structured instruction progress detail.
 final  Map<String, InstructionProgressDetail> _nodeProgressStructuredDetail;
/// Per-node structured instruction progress detail.
@override@JsonKey() Map<String, InstructionProgressDetail> get nodeProgressStructuredDetail {
  if (_nodeProgressStructuredDetail is EqualUnmodifiableMapView) return _nodeProgressStructuredDetail;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_nodeProgressStructuredDetail);
}


/// Create a copy of SequenceProgress
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SequenceProgressCopyWith<_SequenceProgress> get copyWith => __$SequenceProgressCopyWithImpl<_SequenceProgress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SequenceProgress&&(identical(other.state, state) || other.state == state)&&(identical(other.currentNodeId, currentNodeId) || other.currentNodeId == currentNodeId)&&(identical(other.currentNodeName, currentNodeName) || other.currentNodeName == currentNodeName)&&(identical(other.currentNodeStatus, currentNodeStatus) || other.currentNodeStatus == currentNodeStatus)&&(identical(other.totalExposures, totalExposures) || other.totalExposures == totalExposures)&&(identical(other.completedExposures, completedExposures) || other.completedExposures == completedExposures)&&(identical(other.totalIntegrationSecs, totalIntegrationSecs) || other.totalIntegrationSecs == totalIntegrationSecs)&&(identical(other.completedIntegrationSecs, completedIntegrationSecs) || other.completedIntegrationSecs == completedIntegrationSecs)&&(identical(other.elapsedSecs, elapsedSecs) || other.elapsedSecs == elapsedSecs)&&(identical(other.estimatedRemainingSecs, estimatedRemainingSecs) || other.estimatedRemainingSecs == estimatedRemainingSecs)&&(identical(other.currentTarget, currentTarget) || other.currentTarget == currentTarget)&&(identical(other.currentFilter, currentFilter) || other.currentFilter == currentFilter)&&(identical(other.message, message) || other.message == message)&&const DeepCollectionEquality().equals(other._nodeStatuses, _nodeStatuses)&&const DeepCollectionEquality().equals(other._nodeProgressPercent, _nodeProgressPercent)&&const DeepCollectionEquality().equals(other._nodeProgressDetail, _nodeProgressDetail)&&const DeepCollectionEquality().equals(other._nodeProgressStructuredDetail, _nodeProgressStructuredDetail));
}


@override
int get hashCode => Object.hash(runtimeType,state,currentNodeId,currentNodeName,currentNodeStatus,totalExposures,completedExposures,totalIntegrationSecs,completedIntegrationSecs,elapsedSecs,estimatedRemainingSecs,currentTarget,currentFilter,message,const DeepCollectionEquality().hash(_nodeStatuses),const DeepCollectionEquality().hash(_nodeProgressPercent),const DeepCollectionEquality().hash(_nodeProgressDetail),const DeepCollectionEquality().hash(_nodeProgressStructuredDetail));

@override
String toString() {
  return 'SequenceProgress(state: $state, currentNodeId: $currentNodeId, currentNodeName: $currentNodeName, currentNodeStatus: $currentNodeStatus, totalExposures: $totalExposures, completedExposures: $completedExposures, totalIntegrationSecs: $totalIntegrationSecs, completedIntegrationSecs: $completedIntegrationSecs, elapsedSecs: $elapsedSecs, estimatedRemainingSecs: $estimatedRemainingSecs, currentTarget: $currentTarget, currentFilter: $currentFilter, message: $message, nodeStatuses: $nodeStatuses, nodeProgressPercent: $nodeProgressPercent, nodeProgressDetail: $nodeProgressDetail, nodeProgressStructuredDetail: $nodeProgressStructuredDetail)';
}


}

/// @nodoc
abstract mixin class _$SequenceProgressCopyWith<$Res> implements $SequenceProgressCopyWith<$Res> {
  factory _$SequenceProgressCopyWith(_SequenceProgress value, $Res Function(_SequenceProgress) _then) = __$SequenceProgressCopyWithImpl;
@override @useResult
$Res call({
 SequenceExecutionState state, String? currentNodeId, String? currentNodeName, NodeStatus? currentNodeStatus, int totalExposures, int completedExposures, double totalIntegrationSecs, double completedIntegrationSecs, double elapsedSecs, double? estimatedRemainingSecs, String? currentTarget, String? currentFilter, String? message, Map<String, NodeStatus> nodeStatuses, Map<String, double> nodeProgressPercent, Map<String, String> nodeProgressDetail, Map<String, InstructionProgressDetail> nodeProgressStructuredDetail
});




}
/// @nodoc
class __$SequenceProgressCopyWithImpl<$Res>
    implements _$SequenceProgressCopyWith<$Res> {
  __$SequenceProgressCopyWithImpl(this._self, this._then);

  final _SequenceProgress _self;
  final $Res Function(_SequenceProgress) _then;

/// Create a copy of SequenceProgress
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? state = null,Object? currentNodeId = freezed,Object? currentNodeName = freezed,Object? currentNodeStatus = freezed,Object? totalExposures = null,Object? completedExposures = null,Object? totalIntegrationSecs = null,Object? completedIntegrationSecs = null,Object? elapsedSecs = null,Object? estimatedRemainingSecs = freezed,Object? currentTarget = freezed,Object? currentFilter = freezed,Object? message = freezed,Object? nodeStatuses = null,Object? nodeProgressPercent = null,Object? nodeProgressDetail = null,Object? nodeProgressStructuredDetail = null,}) {
  return _then(_SequenceProgress(
state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as SequenceExecutionState,currentNodeId: freezed == currentNodeId ? _self.currentNodeId : currentNodeId // ignore: cast_nullable_to_non_nullable
as String?,currentNodeName: freezed == currentNodeName ? _self.currentNodeName : currentNodeName // ignore: cast_nullable_to_non_nullable
as String?,currentNodeStatus: freezed == currentNodeStatus ? _self.currentNodeStatus : currentNodeStatus // ignore: cast_nullable_to_non_nullable
as NodeStatus?,totalExposures: null == totalExposures ? _self.totalExposures : totalExposures // ignore: cast_nullable_to_non_nullable
as int,completedExposures: null == completedExposures ? _self.completedExposures : completedExposures // ignore: cast_nullable_to_non_nullable
as int,totalIntegrationSecs: null == totalIntegrationSecs ? _self.totalIntegrationSecs : totalIntegrationSecs // ignore: cast_nullable_to_non_nullable
as double,completedIntegrationSecs: null == completedIntegrationSecs ? _self.completedIntegrationSecs : completedIntegrationSecs // ignore: cast_nullable_to_non_nullable
as double,elapsedSecs: null == elapsedSecs ? _self.elapsedSecs : elapsedSecs // ignore: cast_nullable_to_non_nullable
as double,estimatedRemainingSecs: freezed == estimatedRemainingSecs ? _self.estimatedRemainingSecs : estimatedRemainingSecs // ignore: cast_nullable_to_non_nullable
as double?,currentTarget: freezed == currentTarget ? _self.currentTarget : currentTarget // ignore: cast_nullable_to_non_nullable
as String?,currentFilter: freezed == currentFilter ? _self.currentFilter : currentFilter // ignore: cast_nullable_to_non_nullable
as String?,message: freezed == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String?,nodeStatuses: null == nodeStatuses ? _self._nodeStatuses : nodeStatuses // ignore: cast_nullable_to_non_nullable
as Map<String, NodeStatus>,nodeProgressPercent: null == nodeProgressPercent ? _self._nodeProgressPercent : nodeProgressPercent // ignore: cast_nullable_to_non_nullable
as Map<String, double>,nodeProgressDetail: null == nodeProgressDetail ? _self._nodeProgressDetail : nodeProgressDetail // ignore: cast_nullable_to_non_nullable
as Map<String, String>,nodeProgressStructuredDetail: null == nodeProgressStructuredDetail ? _self._nodeProgressStructuredDetail : nodeProgressStructuredDetail // ignore: cast_nullable_to_non_nullable
as Map<String, InstructionProgressDetail>,
  ));
}


}

// dart format on
