// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'polar_alignment_config.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$PolarAlignmentConfig {

/// Exposure time in seconds for each measurement image
 double get exposureTime;/// Step size in degrees for mount rotation between measurements
 double get stepSize;/// Camera binning (1, 2, 3, 4).
///
/// 2 is the default because a binned frame plate-solves in a quarter of
/// the time and the alignment measurement — where the mount's rotation
/// axis sits — is unaffected: the axis is fitted from three solved sky
/// positions, not from the resolution they were solved at.
 int get binning;/// Whether observing from northern hemisphere
 bool get isNorth;/// Whether to use manual rotation (user rotates mount) vs automatic slewing
 bool get manualRotation;/// Direction to rotate (true = east, false = west) for auto rotation
 bool get rotateEast;/// Timeout in seconds for one frame's plate solve.
///
/// This is the whole budget for the frame, shared by the hinted solve and
/// the blind fallback behind it. 30 s was the old default and it was not
/// enough: on the owner's rig a full-resolution blind solve of a
/// pole-region frame took 26.5 s on a good night and was killed
/// mid-solve on a bad one.
 double get solveTimeout;/// Delay between all-sky drift re-solves. Kept in the shared config so
/// headless/API-started runs are recorded and replayed with the cadence
/// they actually used rather than silently reverting to 3 seconds.
 double get iterationCadenceSecs;/// Total error threshold in arcseconds to consider alignment complete
/// When error drops below this value, auto-complete can be triggered
 double get autoCompleteThreshold;/// Whether to start from current mount position or slew to pole first
 bool get startFromCurrent;/// Camera gain (null = use camera default)
 int? get gain;/// Camera offset (null = use camera default)
 int? get offset;
/// Create a copy of PolarAlignmentConfig
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PolarAlignmentConfigCopyWith<PolarAlignmentConfig> get copyWith => _$PolarAlignmentConfigCopyWithImpl<PolarAlignmentConfig>(this as PolarAlignmentConfig, _$identity);

  /// Serializes this PolarAlignmentConfig to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PolarAlignmentConfig&&(identical(other.exposureTime, exposureTime) || other.exposureTime == exposureTime)&&(identical(other.stepSize, stepSize) || other.stepSize == stepSize)&&(identical(other.binning, binning) || other.binning == binning)&&(identical(other.isNorth, isNorth) || other.isNorth == isNorth)&&(identical(other.manualRotation, manualRotation) || other.manualRotation == manualRotation)&&(identical(other.rotateEast, rotateEast) || other.rotateEast == rotateEast)&&(identical(other.solveTimeout, solveTimeout) || other.solveTimeout == solveTimeout)&&(identical(other.iterationCadenceSecs, iterationCadenceSecs) || other.iterationCadenceSecs == iterationCadenceSecs)&&(identical(other.autoCompleteThreshold, autoCompleteThreshold) || other.autoCompleteThreshold == autoCompleteThreshold)&&(identical(other.startFromCurrent, startFromCurrent) || other.startFromCurrent == startFromCurrent)&&(identical(other.gain, gain) || other.gain == gain)&&(identical(other.offset, offset) || other.offset == offset));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,exposureTime,stepSize,binning,isNorth,manualRotation,rotateEast,solveTimeout,iterationCadenceSecs,autoCompleteThreshold,startFromCurrent,gain,offset);

@override
String toString() {
  return 'PolarAlignmentConfig(exposureTime: $exposureTime, stepSize: $stepSize, binning: $binning, isNorth: $isNorth, manualRotation: $manualRotation, rotateEast: $rotateEast, solveTimeout: $solveTimeout, iterationCadenceSecs: $iterationCadenceSecs, autoCompleteThreshold: $autoCompleteThreshold, startFromCurrent: $startFromCurrent, gain: $gain, offset: $offset)';
}


}

/// @nodoc
abstract mixin class $PolarAlignmentConfigCopyWith<$Res>  {
  factory $PolarAlignmentConfigCopyWith(PolarAlignmentConfig value, $Res Function(PolarAlignmentConfig) _then) = _$PolarAlignmentConfigCopyWithImpl;
@useResult
$Res call({
 double exposureTime, double stepSize, int binning, bool isNorth, bool manualRotation, bool rotateEast, double solveTimeout, double iterationCadenceSecs, double autoCompleteThreshold, bool startFromCurrent, int? gain, int? offset
});




}
/// @nodoc
class _$PolarAlignmentConfigCopyWithImpl<$Res>
    implements $PolarAlignmentConfigCopyWith<$Res> {
  _$PolarAlignmentConfigCopyWithImpl(this._self, this._then);

  final PolarAlignmentConfig _self;
  final $Res Function(PolarAlignmentConfig) _then;

/// Create a copy of PolarAlignmentConfig
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? exposureTime = null,Object? stepSize = null,Object? binning = null,Object? isNorth = null,Object? manualRotation = null,Object? rotateEast = null,Object? solveTimeout = null,Object? iterationCadenceSecs = null,Object? autoCompleteThreshold = null,Object? startFromCurrent = null,Object? gain = freezed,Object? offset = freezed,}) {
  return _then(_self.copyWith(
exposureTime: null == exposureTime ? _self.exposureTime : exposureTime // ignore: cast_nullable_to_non_nullable
as double,stepSize: null == stepSize ? _self.stepSize : stepSize // ignore: cast_nullable_to_non_nullable
as double,binning: null == binning ? _self.binning : binning // ignore: cast_nullable_to_non_nullable
as int,isNorth: null == isNorth ? _self.isNorth : isNorth // ignore: cast_nullable_to_non_nullable
as bool,manualRotation: null == manualRotation ? _self.manualRotation : manualRotation // ignore: cast_nullable_to_non_nullable
as bool,rotateEast: null == rotateEast ? _self.rotateEast : rotateEast // ignore: cast_nullable_to_non_nullable
as bool,solveTimeout: null == solveTimeout ? _self.solveTimeout : solveTimeout // ignore: cast_nullable_to_non_nullable
as double,iterationCadenceSecs: null == iterationCadenceSecs ? _self.iterationCadenceSecs : iterationCadenceSecs // ignore: cast_nullable_to_non_nullable
as double,autoCompleteThreshold: null == autoCompleteThreshold ? _self.autoCompleteThreshold : autoCompleteThreshold // ignore: cast_nullable_to_non_nullable
as double,startFromCurrent: null == startFromCurrent ? _self.startFromCurrent : startFromCurrent // ignore: cast_nullable_to_non_nullable
as bool,gain: freezed == gain ? _self.gain : gain // ignore: cast_nullable_to_non_nullable
as int?,offset: freezed == offset ? _self.offset : offset // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}

}


/// Adds pattern-matching-related methods to [PolarAlignmentConfig].
extension PolarAlignmentConfigPatterns on PolarAlignmentConfig {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PolarAlignmentConfig value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PolarAlignmentConfig() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PolarAlignmentConfig value)  $default,){
final _that = this;
switch (_that) {
case _PolarAlignmentConfig():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PolarAlignmentConfig value)?  $default,){
final _that = this;
switch (_that) {
case _PolarAlignmentConfig() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double exposureTime,  double stepSize,  int binning,  bool isNorth,  bool manualRotation,  bool rotateEast,  double solveTimeout,  double iterationCadenceSecs,  double autoCompleteThreshold,  bool startFromCurrent,  int? gain,  int? offset)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PolarAlignmentConfig() when $default != null:
return $default(_that.exposureTime,_that.stepSize,_that.binning,_that.isNorth,_that.manualRotation,_that.rotateEast,_that.solveTimeout,_that.iterationCadenceSecs,_that.autoCompleteThreshold,_that.startFromCurrent,_that.gain,_that.offset);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double exposureTime,  double stepSize,  int binning,  bool isNorth,  bool manualRotation,  bool rotateEast,  double solveTimeout,  double iterationCadenceSecs,  double autoCompleteThreshold,  bool startFromCurrent,  int? gain,  int? offset)  $default,) {final _that = this;
switch (_that) {
case _PolarAlignmentConfig():
return $default(_that.exposureTime,_that.stepSize,_that.binning,_that.isNorth,_that.manualRotation,_that.rotateEast,_that.solveTimeout,_that.iterationCadenceSecs,_that.autoCompleteThreshold,_that.startFromCurrent,_that.gain,_that.offset);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double exposureTime,  double stepSize,  int binning,  bool isNorth,  bool manualRotation,  bool rotateEast,  double solveTimeout,  double iterationCadenceSecs,  double autoCompleteThreshold,  bool startFromCurrent,  int? gain,  int? offset)?  $default,) {final _that = this;
switch (_that) {
case _PolarAlignmentConfig() when $default != null:
return $default(_that.exposureTime,_that.stepSize,_that.binning,_that.isNorth,_that.manualRotation,_that.rotateEast,_that.solveTimeout,_that.iterationCadenceSecs,_that.autoCompleteThreshold,_that.startFromCurrent,_that.gain,_that.offset);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PolarAlignmentConfig extends PolarAlignmentConfig {
  const _PolarAlignmentConfig({this.exposureTime = 5.0, this.stepSize = 15.0, this.binning = 2, this.isNorth = true, this.manualRotation = false, this.rotateEast = true, this.solveTimeout = 90.0, this.iterationCadenceSecs = 3.0, this.autoCompleteThreshold = 30.0, this.startFromCurrent = true, this.gain, this.offset}): super._();
  factory _PolarAlignmentConfig.fromJson(Map<String, dynamic> json) => _$PolarAlignmentConfigFromJson(json);

/// Exposure time in seconds for each measurement image
@override@JsonKey() final  double exposureTime;
/// Step size in degrees for mount rotation between measurements
@override@JsonKey() final  double stepSize;
/// Camera binning (1, 2, 3, 4).
///
/// 2 is the default because a binned frame plate-solves in a quarter of
/// the time and the alignment measurement — where the mount's rotation
/// axis sits — is unaffected: the axis is fitted from three solved sky
/// positions, not from the resolution they were solved at.
@override@JsonKey() final  int binning;
/// Whether observing from northern hemisphere
@override@JsonKey() final  bool isNorth;
/// Whether to use manual rotation (user rotates mount) vs automatic slewing
@override@JsonKey() final  bool manualRotation;
/// Direction to rotate (true = east, false = west) for auto rotation
@override@JsonKey() final  bool rotateEast;
/// Timeout in seconds for one frame's plate solve.
///
/// This is the whole budget for the frame, shared by the hinted solve and
/// the blind fallback behind it. 30 s was the old default and it was not
/// enough: on the owner's rig a full-resolution blind solve of a
/// pole-region frame took 26.5 s on a good night and was killed
/// mid-solve on a bad one.
@override@JsonKey() final  double solveTimeout;
/// Delay between all-sky drift re-solves. Kept in the shared config so
/// headless/API-started runs are recorded and replayed with the cadence
/// they actually used rather than silently reverting to 3 seconds.
@override@JsonKey() final  double iterationCadenceSecs;
/// Total error threshold in arcseconds to consider alignment complete
/// When error drops below this value, auto-complete can be triggered
@override@JsonKey() final  double autoCompleteThreshold;
/// Whether to start from current mount position or slew to pole first
@override@JsonKey() final  bool startFromCurrent;
/// Camera gain (null = use camera default)
@override final  int? gain;
/// Camera offset (null = use camera default)
@override final  int? offset;

/// Create a copy of PolarAlignmentConfig
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PolarAlignmentConfigCopyWith<_PolarAlignmentConfig> get copyWith => __$PolarAlignmentConfigCopyWithImpl<_PolarAlignmentConfig>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PolarAlignmentConfigToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PolarAlignmentConfig&&(identical(other.exposureTime, exposureTime) || other.exposureTime == exposureTime)&&(identical(other.stepSize, stepSize) || other.stepSize == stepSize)&&(identical(other.binning, binning) || other.binning == binning)&&(identical(other.isNorth, isNorth) || other.isNorth == isNorth)&&(identical(other.manualRotation, manualRotation) || other.manualRotation == manualRotation)&&(identical(other.rotateEast, rotateEast) || other.rotateEast == rotateEast)&&(identical(other.solveTimeout, solveTimeout) || other.solveTimeout == solveTimeout)&&(identical(other.iterationCadenceSecs, iterationCadenceSecs) || other.iterationCadenceSecs == iterationCadenceSecs)&&(identical(other.autoCompleteThreshold, autoCompleteThreshold) || other.autoCompleteThreshold == autoCompleteThreshold)&&(identical(other.startFromCurrent, startFromCurrent) || other.startFromCurrent == startFromCurrent)&&(identical(other.gain, gain) || other.gain == gain)&&(identical(other.offset, offset) || other.offset == offset));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,exposureTime,stepSize,binning,isNorth,manualRotation,rotateEast,solveTimeout,iterationCadenceSecs,autoCompleteThreshold,startFromCurrent,gain,offset);

@override
String toString() {
  return 'PolarAlignmentConfig(exposureTime: $exposureTime, stepSize: $stepSize, binning: $binning, isNorth: $isNorth, manualRotation: $manualRotation, rotateEast: $rotateEast, solveTimeout: $solveTimeout, iterationCadenceSecs: $iterationCadenceSecs, autoCompleteThreshold: $autoCompleteThreshold, startFromCurrent: $startFromCurrent, gain: $gain, offset: $offset)';
}


}

/// @nodoc
abstract mixin class _$PolarAlignmentConfigCopyWith<$Res> implements $PolarAlignmentConfigCopyWith<$Res> {
  factory _$PolarAlignmentConfigCopyWith(_PolarAlignmentConfig value, $Res Function(_PolarAlignmentConfig) _then) = __$PolarAlignmentConfigCopyWithImpl;
@override @useResult
$Res call({
 double exposureTime, double stepSize, int binning, bool isNorth, bool manualRotation, bool rotateEast, double solveTimeout, double iterationCadenceSecs, double autoCompleteThreshold, bool startFromCurrent, int? gain, int? offset
});




}
/// @nodoc
class __$PolarAlignmentConfigCopyWithImpl<$Res>
    implements _$PolarAlignmentConfigCopyWith<$Res> {
  __$PolarAlignmentConfigCopyWithImpl(this._self, this._then);

  final _PolarAlignmentConfig _self;
  final $Res Function(_PolarAlignmentConfig) _then;

/// Create a copy of PolarAlignmentConfig
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? exposureTime = null,Object? stepSize = null,Object? binning = null,Object? isNorth = null,Object? manualRotation = null,Object? rotateEast = null,Object? solveTimeout = null,Object? iterationCadenceSecs = null,Object? autoCompleteThreshold = null,Object? startFromCurrent = null,Object? gain = freezed,Object? offset = freezed,}) {
  return _then(_PolarAlignmentConfig(
exposureTime: null == exposureTime ? _self.exposureTime : exposureTime // ignore: cast_nullable_to_non_nullable
as double,stepSize: null == stepSize ? _self.stepSize : stepSize // ignore: cast_nullable_to_non_nullable
as double,binning: null == binning ? _self.binning : binning // ignore: cast_nullable_to_non_nullable
as int,isNorth: null == isNorth ? _self.isNorth : isNorth // ignore: cast_nullable_to_non_nullable
as bool,manualRotation: null == manualRotation ? _self.manualRotation : manualRotation // ignore: cast_nullable_to_non_nullable
as bool,rotateEast: null == rotateEast ? _self.rotateEast : rotateEast // ignore: cast_nullable_to_non_nullable
as bool,solveTimeout: null == solveTimeout ? _self.solveTimeout : solveTimeout // ignore: cast_nullable_to_non_nullable
as double,iterationCadenceSecs: null == iterationCadenceSecs ? _self.iterationCadenceSecs : iterationCadenceSecs // ignore: cast_nullable_to_non_nullable
as double,autoCompleteThreshold: null == autoCompleteThreshold ? _self.autoCompleteThreshold : autoCompleteThreshold // ignore: cast_nullable_to_non_nullable
as double,startFromCurrent: null == startFromCurrent ? _self.startFromCurrent : startFromCurrent // ignore: cast_nullable_to_non_nullable
as bool,gain: freezed == gain ? _self.gain : gain // ignore: cast_nullable_to_non_nullable
as int?,offset: freezed == offset ? _self.offset : offset // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}


/// @nodoc
mixin _$PolarAlignmentError {

/// Azimuth error in arcseconds (positive = east)
 double get azimuthError;/// Altitude error in arcseconds (positive = above pole)
 double get altitudeError;/// Total error in arcseconds (pythagorean combination)
 double get totalError;/// Current RA position (degrees)
 double get currentRa;/// Current Dec position (degrees)
 double get currentDec;/// Target RA for perfect alignment (degrees)
 double get targetRa;/// Target Dec for perfect alignment (degrees)
 double get targetDec;/// When this measurement was taken
 DateTime get timestamp;
/// Create a copy of PolarAlignmentError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PolarAlignmentErrorCopyWith<PolarAlignmentError> get copyWith => _$PolarAlignmentErrorCopyWithImpl<PolarAlignmentError>(this as PolarAlignmentError, _$identity);

  /// Serializes this PolarAlignmentError to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PolarAlignmentError&&(identical(other.azimuthError, azimuthError) || other.azimuthError == azimuthError)&&(identical(other.altitudeError, altitudeError) || other.altitudeError == altitudeError)&&(identical(other.totalError, totalError) || other.totalError == totalError)&&(identical(other.currentRa, currentRa) || other.currentRa == currentRa)&&(identical(other.currentDec, currentDec) || other.currentDec == currentDec)&&(identical(other.targetRa, targetRa) || other.targetRa == targetRa)&&(identical(other.targetDec, targetDec) || other.targetDec == targetDec)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,azimuthError,altitudeError,totalError,currentRa,currentDec,targetRa,targetDec,timestamp);

@override
String toString() {
  return 'PolarAlignmentError(azimuthError: $azimuthError, altitudeError: $altitudeError, totalError: $totalError, currentRa: $currentRa, currentDec: $currentDec, targetRa: $targetRa, targetDec: $targetDec, timestamp: $timestamp)';
}


}

/// @nodoc
abstract mixin class $PolarAlignmentErrorCopyWith<$Res>  {
  factory $PolarAlignmentErrorCopyWith(PolarAlignmentError value, $Res Function(PolarAlignmentError) _then) = _$PolarAlignmentErrorCopyWithImpl;
@useResult
$Res call({
 double azimuthError, double altitudeError, double totalError, double currentRa, double currentDec, double targetRa, double targetDec, DateTime timestamp
});




}
/// @nodoc
class _$PolarAlignmentErrorCopyWithImpl<$Res>
    implements $PolarAlignmentErrorCopyWith<$Res> {
  _$PolarAlignmentErrorCopyWithImpl(this._self, this._then);

  final PolarAlignmentError _self;
  final $Res Function(PolarAlignmentError) _then;

/// Create a copy of PolarAlignmentError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? azimuthError = null,Object? altitudeError = null,Object? totalError = null,Object? currentRa = null,Object? currentDec = null,Object? targetRa = null,Object? targetDec = null,Object? timestamp = null,}) {
  return _then(_self.copyWith(
azimuthError: null == azimuthError ? _self.azimuthError : azimuthError // ignore: cast_nullable_to_non_nullable
as double,altitudeError: null == altitudeError ? _self.altitudeError : altitudeError // ignore: cast_nullable_to_non_nullable
as double,totalError: null == totalError ? _self.totalError : totalError // ignore: cast_nullable_to_non_nullable
as double,currentRa: null == currentRa ? _self.currentRa : currentRa // ignore: cast_nullable_to_non_nullable
as double,currentDec: null == currentDec ? _self.currentDec : currentDec // ignore: cast_nullable_to_non_nullable
as double,targetRa: null == targetRa ? _self.targetRa : targetRa // ignore: cast_nullable_to_non_nullable
as double,targetDec: null == targetDec ? _self.targetDec : targetDec // ignore: cast_nullable_to_non_nullable
as double,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}

}


/// Adds pattern-matching-related methods to [PolarAlignmentError].
extension PolarAlignmentErrorPatterns on PolarAlignmentError {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PolarAlignmentError value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PolarAlignmentError() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PolarAlignmentError value)  $default,){
final _that = this;
switch (_that) {
case _PolarAlignmentError():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PolarAlignmentError value)?  $default,){
final _that = this;
switch (_that) {
case _PolarAlignmentError() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double azimuthError,  double altitudeError,  double totalError,  double currentRa,  double currentDec,  double targetRa,  double targetDec,  DateTime timestamp)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PolarAlignmentError() when $default != null:
return $default(_that.azimuthError,_that.altitudeError,_that.totalError,_that.currentRa,_that.currentDec,_that.targetRa,_that.targetDec,_that.timestamp);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double azimuthError,  double altitudeError,  double totalError,  double currentRa,  double currentDec,  double targetRa,  double targetDec,  DateTime timestamp)  $default,) {final _that = this;
switch (_that) {
case _PolarAlignmentError():
return $default(_that.azimuthError,_that.altitudeError,_that.totalError,_that.currentRa,_that.currentDec,_that.targetRa,_that.targetDec,_that.timestamp);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double azimuthError,  double altitudeError,  double totalError,  double currentRa,  double currentDec,  double targetRa,  double targetDec,  DateTime timestamp)?  $default,) {final _that = this;
switch (_that) {
case _PolarAlignmentError() when $default != null:
return $default(_that.azimuthError,_that.altitudeError,_that.totalError,_that.currentRa,_that.currentDec,_that.targetRa,_that.targetDec,_that.timestamp);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PolarAlignmentError extends PolarAlignmentError {
  const _PolarAlignmentError({required this.azimuthError, required this.altitudeError, required this.totalError, required this.currentRa, required this.currentDec, required this.targetRa, required this.targetDec, required this.timestamp}): super._();
  factory _PolarAlignmentError.fromJson(Map<String, dynamic> json) => _$PolarAlignmentErrorFromJson(json);

/// Azimuth error in arcseconds (positive = east)
@override final  double azimuthError;
/// Altitude error in arcseconds (positive = above pole)
@override final  double altitudeError;
/// Total error in arcseconds (pythagorean combination)
@override final  double totalError;
/// Current RA position (degrees)
@override final  double currentRa;
/// Current Dec position (degrees)
@override final  double currentDec;
/// Target RA for perfect alignment (degrees)
@override final  double targetRa;
/// Target Dec for perfect alignment (degrees)
@override final  double targetDec;
/// When this measurement was taken
@override final  DateTime timestamp;

/// Create a copy of PolarAlignmentError
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PolarAlignmentErrorCopyWith<_PolarAlignmentError> get copyWith => __$PolarAlignmentErrorCopyWithImpl<_PolarAlignmentError>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PolarAlignmentErrorToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PolarAlignmentError&&(identical(other.azimuthError, azimuthError) || other.azimuthError == azimuthError)&&(identical(other.altitudeError, altitudeError) || other.altitudeError == altitudeError)&&(identical(other.totalError, totalError) || other.totalError == totalError)&&(identical(other.currentRa, currentRa) || other.currentRa == currentRa)&&(identical(other.currentDec, currentDec) || other.currentDec == currentDec)&&(identical(other.targetRa, targetRa) || other.targetRa == targetRa)&&(identical(other.targetDec, targetDec) || other.targetDec == targetDec)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,azimuthError,altitudeError,totalError,currentRa,currentDec,targetRa,targetDec,timestamp);

@override
String toString() {
  return 'PolarAlignmentError(azimuthError: $azimuthError, altitudeError: $altitudeError, totalError: $totalError, currentRa: $currentRa, currentDec: $currentDec, targetRa: $targetRa, targetDec: $targetDec, timestamp: $timestamp)';
}


}

/// @nodoc
abstract mixin class _$PolarAlignmentErrorCopyWith<$Res> implements $PolarAlignmentErrorCopyWith<$Res> {
  factory _$PolarAlignmentErrorCopyWith(_PolarAlignmentError value, $Res Function(_PolarAlignmentError) _then) = __$PolarAlignmentErrorCopyWithImpl;
@override @useResult
$Res call({
 double azimuthError, double altitudeError, double totalError, double currentRa, double currentDec, double targetRa, double targetDec, DateTime timestamp
});




}
/// @nodoc
class __$PolarAlignmentErrorCopyWithImpl<$Res>
    implements _$PolarAlignmentErrorCopyWith<$Res> {
  __$PolarAlignmentErrorCopyWithImpl(this._self, this._then);

  final _PolarAlignmentError _self;
  final $Res Function(_PolarAlignmentError) _then;

/// Create a copy of PolarAlignmentError
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? azimuthError = null,Object? altitudeError = null,Object? totalError = null,Object? currentRa = null,Object? currentDec = null,Object? targetRa = null,Object? targetDec = null,Object? timestamp = null,}) {
  return _then(_PolarAlignmentError(
azimuthError: null == azimuthError ? _self.azimuthError : azimuthError // ignore: cast_nullable_to_non_nullable
as double,altitudeError: null == altitudeError ? _self.altitudeError : altitudeError // ignore: cast_nullable_to_non_nullable
as double,totalError: null == totalError ? _self.totalError : totalError // ignore: cast_nullable_to_non_nullable
as double,currentRa: null == currentRa ? _self.currentRa : currentRa // ignore: cast_nullable_to_non_nullable
as double,currentDec: null == currentDec ? _self.currentDec : currentDec // ignore: cast_nullable_to_non_nullable
as double,targetRa: null == targetRa ? _self.targetRa : targetRa // ignore: cast_nullable_to_non_nullable
as double,targetDec: null == targetDec ? _self.targetDec : targetDec // ignore: cast_nullable_to_non_nullable
as double,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}


}


/// @nodoc
mixin _$PolarAlignmentState {

/// Current phase of alignment
 PolarAlignPhase get phase;/// Current measurement point (1-3 during measuring, 0 during adjusting)
 int get currentPoint;/// Status message to display to user
 String get statusMessage;/// Current error measurements (null if not yet calculated)
 PolarAlignmentError? get currentError;/// Initial error when adjustment phase started (for progress tracking)
 PolarAlignmentError? get initialError;/// Most recent captured image (JPEG bytes for display)
@NullableUint8ListConverter() Uint8List? get imageData;/// Image width
 int? get imageWidth;/// Image height
 int? get imageHeight;/// Solved RA from last image (degrees)
 double? get solvedRa;/// Solved Dec from last image (degrees)
 double? get solvedDec;/// Error message if phase is error
 String? get errorMessage;/// Configuration used for this alignment run
 PolarAlignmentConfig? get config;/// When alignment started
 DateTime? get startedAt;
/// Create a copy of PolarAlignmentState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PolarAlignmentStateCopyWith<PolarAlignmentState> get copyWith => _$PolarAlignmentStateCopyWithImpl<PolarAlignmentState>(this as PolarAlignmentState, _$identity);

  /// Serializes this PolarAlignmentState to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PolarAlignmentState&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.currentPoint, currentPoint) || other.currentPoint == currentPoint)&&(identical(other.statusMessage, statusMessage) || other.statusMessage == statusMessage)&&(identical(other.currentError, currentError) || other.currentError == currentError)&&(identical(other.initialError, initialError) || other.initialError == initialError)&&const DeepCollectionEquality().equals(other.imageData, imageData)&&(identical(other.imageWidth, imageWidth) || other.imageWidth == imageWidth)&&(identical(other.imageHeight, imageHeight) || other.imageHeight == imageHeight)&&(identical(other.solvedRa, solvedRa) || other.solvedRa == solvedRa)&&(identical(other.solvedDec, solvedDec) || other.solvedDec == solvedDec)&&(identical(other.errorMessage, errorMessage) || other.errorMessage == errorMessage)&&(identical(other.config, config) || other.config == config)&&(identical(other.startedAt, startedAt) || other.startedAt == startedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,phase,currentPoint,statusMessage,currentError,initialError,const DeepCollectionEquality().hash(imageData),imageWidth,imageHeight,solvedRa,solvedDec,errorMessage,config,startedAt);

@override
String toString() {
  return 'PolarAlignmentState(phase: $phase, currentPoint: $currentPoint, statusMessage: $statusMessage, currentError: $currentError, initialError: $initialError, imageData: $imageData, imageWidth: $imageWidth, imageHeight: $imageHeight, solvedRa: $solvedRa, solvedDec: $solvedDec, errorMessage: $errorMessage, config: $config, startedAt: $startedAt)';
}


}

/// @nodoc
abstract mixin class $PolarAlignmentStateCopyWith<$Res>  {
  factory $PolarAlignmentStateCopyWith(PolarAlignmentState value, $Res Function(PolarAlignmentState) _then) = _$PolarAlignmentStateCopyWithImpl;
@useResult
$Res call({
 PolarAlignPhase phase, int currentPoint, String statusMessage, PolarAlignmentError? currentError, PolarAlignmentError? initialError,@NullableUint8ListConverter() Uint8List? imageData, int? imageWidth, int? imageHeight, double? solvedRa, double? solvedDec, String? errorMessage, PolarAlignmentConfig? config, DateTime? startedAt
});


$PolarAlignmentErrorCopyWith<$Res>? get currentError;$PolarAlignmentErrorCopyWith<$Res>? get initialError;$PolarAlignmentConfigCopyWith<$Res>? get config;

}
/// @nodoc
class _$PolarAlignmentStateCopyWithImpl<$Res>
    implements $PolarAlignmentStateCopyWith<$Res> {
  _$PolarAlignmentStateCopyWithImpl(this._self, this._then);

  final PolarAlignmentState _self;
  final $Res Function(PolarAlignmentState) _then;

/// Create a copy of PolarAlignmentState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? phase = null,Object? currentPoint = null,Object? statusMessage = null,Object? currentError = freezed,Object? initialError = freezed,Object? imageData = freezed,Object? imageWidth = freezed,Object? imageHeight = freezed,Object? solvedRa = freezed,Object? solvedDec = freezed,Object? errorMessage = freezed,Object? config = freezed,Object? startedAt = freezed,}) {
  return _then(_self.copyWith(
phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as PolarAlignPhase,currentPoint: null == currentPoint ? _self.currentPoint : currentPoint // ignore: cast_nullable_to_non_nullable
as int,statusMessage: null == statusMessage ? _self.statusMessage : statusMessage // ignore: cast_nullable_to_non_nullable
as String,currentError: freezed == currentError ? _self.currentError : currentError // ignore: cast_nullable_to_non_nullable
as PolarAlignmentError?,initialError: freezed == initialError ? _self.initialError : initialError // ignore: cast_nullable_to_non_nullable
as PolarAlignmentError?,imageData: freezed == imageData ? _self.imageData : imageData // ignore: cast_nullable_to_non_nullable
as Uint8List?,imageWidth: freezed == imageWidth ? _self.imageWidth : imageWidth // ignore: cast_nullable_to_non_nullable
as int?,imageHeight: freezed == imageHeight ? _self.imageHeight : imageHeight // ignore: cast_nullable_to_non_nullable
as int?,solvedRa: freezed == solvedRa ? _self.solvedRa : solvedRa // ignore: cast_nullable_to_non_nullable
as double?,solvedDec: freezed == solvedDec ? _self.solvedDec : solvedDec // ignore: cast_nullable_to_non_nullable
as double?,errorMessage: freezed == errorMessage ? _self.errorMessage : errorMessage // ignore: cast_nullable_to_non_nullable
as String?,config: freezed == config ? _self.config : config // ignore: cast_nullable_to_non_nullable
as PolarAlignmentConfig?,startedAt: freezed == startedAt ? _self.startedAt : startedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}
/// Create a copy of PolarAlignmentState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PolarAlignmentErrorCopyWith<$Res>? get currentError {
    if (_self.currentError == null) {
    return null;
  }

  return $PolarAlignmentErrorCopyWith<$Res>(_self.currentError!, (value) {
    return _then(_self.copyWith(currentError: value));
  });
}/// Create a copy of PolarAlignmentState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PolarAlignmentErrorCopyWith<$Res>? get initialError {
    if (_self.initialError == null) {
    return null;
  }

  return $PolarAlignmentErrorCopyWith<$Res>(_self.initialError!, (value) {
    return _then(_self.copyWith(initialError: value));
  });
}/// Create a copy of PolarAlignmentState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PolarAlignmentConfigCopyWith<$Res>? get config {
    if (_self.config == null) {
    return null;
  }

  return $PolarAlignmentConfigCopyWith<$Res>(_self.config!, (value) {
    return _then(_self.copyWith(config: value));
  });
}
}


/// Adds pattern-matching-related methods to [PolarAlignmentState].
extension PolarAlignmentStatePatterns on PolarAlignmentState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PolarAlignmentState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PolarAlignmentState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PolarAlignmentState value)  $default,){
final _that = this;
switch (_that) {
case _PolarAlignmentState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PolarAlignmentState value)?  $default,){
final _that = this;
switch (_that) {
case _PolarAlignmentState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( PolarAlignPhase phase,  int currentPoint,  String statusMessage,  PolarAlignmentError? currentError,  PolarAlignmentError? initialError, @NullableUint8ListConverter()  Uint8List? imageData,  int? imageWidth,  int? imageHeight,  double? solvedRa,  double? solvedDec,  String? errorMessage,  PolarAlignmentConfig? config,  DateTime? startedAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PolarAlignmentState() when $default != null:
return $default(_that.phase,_that.currentPoint,_that.statusMessage,_that.currentError,_that.initialError,_that.imageData,_that.imageWidth,_that.imageHeight,_that.solvedRa,_that.solvedDec,_that.errorMessage,_that.config,_that.startedAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( PolarAlignPhase phase,  int currentPoint,  String statusMessage,  PolarAlignmentError? currentError,  PolarAlignmentError? initialError, @NullableUint8ListConverter()  Uint8List? imageData,  int? imageWidth,  int? imageHeight,  double? solvedRa,  double? solvedDec,  String? errorMessage,  PolarAlignmentConfig? config,  DateTime? startedAt)  $default,) {final _that = this;
switch (_that) {
case _PolarAlignmentState():
return $default(_that.phase,_that.currentPoint,_that.statusMessage,_that.currentError,_that.initialError,_that.imageData,_that.imageWidth,_that.imageHeight,_that.solvedRa,_that.solvedDec,_that.errorMessage,_that.config,_that.startedAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( PolarAlignPhase phase,  int currentPoint,  String statusMessage,  PolarAlignmentError? currentError,  PolarAlignmentError? initialError, @NullableUint8ListConverter()  Uint8List? imageData,  int? imageWidth,  int? imageHeight,  double? solvedRa,  double? solvedDec,  String? errorMessage,  PolarAlignmentConfig? config,  DateTime? startedAt)?  $default,) {final _that = this;
switch (_that) {
case _PolarAlignmentState() when $default != null:
return $default(_that.phase,_that.currentPoint,_that.statusMessage,_that.currentError,_that.initialError,_that.imageData,_that.imageWidth,_that.imageHeight,_that.solvedRa,_that.solvedDec,_that.errorMessage,_that.config,_that.startedAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PolarAlignmentState extends PolarAlignmentState {
  const _PolarAlignmentState({this.phase = PolarAlignPhase.idle, this.currentPoint = 0, this.statusMessage = 'Ready to start polar alignment', this.currentError, this.initialError, @NullableUint8ListConverter() this.imageData, this.imageWidth, this.imageHeight, this.solvedRa, this.solvedDec, this.errorMessage, this.config, this.startedAt}): super._();
  factory _PolarAlignmentState.fromJson(Map<String, dynamic> json) => _$PolarAlignmentStateFromJson(json);

/// Current phase of alignment
@override@JsonKey() final  PolarAlignPhase phase;
/// Current measurement point (1-3 during measuring, 0 during adjusting)
@override@JsonKey() final  int currentPoint;
/// Status message to display to user
@override@JsonKey() final  String statusMessage;
/// Current error measurements (null if not yet calculated)
@override final  PolarAlignmentError? currentError;
/// Initial error when adjustment phase started (for progress tracking)
@override final  PolarAlignmentError? initialError;
/// Most recent captured image (JPEG bytes for display)
@override@NullableUint8ListConverter() final  Uint8List? imageData;
/// Image width
@override final  int? imageWidth;
/// Image height
@override final  int? imageHeight;
/// Solved RA from last image (degrees)
@override final  double? solvedRa;
/// Solved Dec from last image (degrees)
@override final  double? solvedDec;
/// Error message if phase is error
@override final  String? errorMessage;
/// Configuration used for this alignment run
@override final  PolarAlignmentConfig? config;
/// When alignment started
@override final  DateTime? startedAt;

/// Create a copy of PolarAlignmentState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PolarAlignmentStateCopyWith<_PolarAlignmentState> get copyWith => __$PolarAlignmentStateCopyWithImpl<_PolarAlignmentState>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PolarAlignmentStateToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PolarAlignmentState&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.currentPoint, currentPoint) || other.currentPoint == currentPoint)&&(identical(other.statusMessage, statusMessage) || other.statusMessage == statusMessage)&&(identical(other.currentError, currentError) || other.currentError == currentError)&&(identical(other.initialError, initialError) || other.initialError == initialError)&&const DeepCollectionEquality().equals(other.imageData, imageData)&&(identical(other.imageWidth, imageWidth) || other.imageWidth == imageWidth)&&(identical(other.imageHeight, imageHeight) || other.imageHeight == imageHeight)&&(identical(other.solvedRa, solvedRa) || other.solvedRa == solvedRa)&&(identical(other.solvedDec, solvedDec) || other.solvedDec == solvedDec)&&(identical(other.errorMessage, errorMessage) || other.errorMessage == errorMessage)&&(identical(other.config, config) || other.config == config)&&(identical(other.startedAt, startedAt) || other.startedAt == startedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,phase,currentPoint,statusMessage,currentError,initialError,const DeepCollectionEquality().hash(imageData),imageWidth,imageHeight,solvedRa,solvedDec,errorMessage,config,startedAt);

@override
String toString() {
  return 'PolarAlignmentState(phase: $phase, currentPoint: $currentPoint, statusMessage: $statusMessage, currentError: $currentError, initialError: $initialError, imageData: $imageData, imageWidth: $imageWidth, imageHeight: $imageHeight, solvedRa: $solvedRa, solvedDec: $solvedDec, errorMessage: $errorMessage, config: $config, startedAt: $startedAt)';
}


}

/// @nodoc
abstract mixin class _$PolarAlignmentStateCopyWith<$Res> implements $PolarAlignmentStateCopyWith<$Res> {
  factory _$PolarAlignmentStateCopyWith(_PolarAlignmentState value, $Res Function(_PolarAlignmentState) _then) = __$PolarAlignmentStateCopyWithImpl;
@override @useResult
$Res call({
 PolarAlignPhase phase, int currentPoint, String statusMessage, PolarAlignmentError? currentError, PolarAlignmentError? initialError,@NullableUint8ListConverter() Uint8List? imageData, int? imageWidth, int? imageHeight, double? solvedRa, double? solvedDec, String? errorMessage, PolarAlignmentConfig? config, DateTime? startedAt
});


@override $PolarAlignmentErrorCopyWith<$Res>? get currentError;@override $PolarAlignmentErrorCopyWith<$Res>? get initialError;@override $PolarAlignmentConfigCopyWith<$Res>? get config;

}
/// @nodoc
class __$PolarAlignmentStateCopyWithImpl<$Res>
    implements _$PolarAlignmentStateCopyWith<$Res> {
  __$PolarAlignmentStateCopyWithImpl(this._self, this._then);

  final _PolarAlignmentState _self;
  final $Res Function(_PolarAlignmentState) _then;

/// Create a copy of PolarAlignmentState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? phase = null,Object? currentPoint = null,Object? statusMessage = null,Object? currentError = freezed,Object? initialError = freezed,Object? imageData = freezed,Object? imageWidth = freezed,Object? imageHeight = freezed,Object? solvedRa = freezed,Object? solvedDec = freezed,Object? errorMessage = freezed,Object? config = freezed,Object? startedAt = freezed,}) {
  return _then(_PolarAlignmentState(
phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as PolarAlignPhase,currentPoint: null == currentPoint ? _self.currentPoint : currentPoint // ignore: cast_nullable_to_non_nullable
as int,statusMessage: null == statusMessage ? _self.statusMessage : statusMessage // ignore: cast_nullable_to_non_nullable
as String,currentError: freezed == currentError ? _self.currentError : currentError // ignore: cast_nullable_to_non_nullable
as PolarAlignmentError?,initialError: freezed == initialError ? _self.initialError : initialError // ignore: cast_nullable_to_non_nullable
as PolarAlignmentError?,imageData: freezed == imageData ? _self.imageData : imageData // ignore: cast_nullable_to_non_nullable
as Uint8List?,imageWidth: freezed == imageWidth ? _self.imageWidth : imageWidth // ignore: cast_nullable_to_non_nullable
as int?,imageHeight: freezed == imageHeight ? _self.imageHeight : imageHeight // ignore: cast_nullable_to_non_nullable
as int?,solvedRa: freezed == solvedRa ? _self.solvedRa : solvedRa // ignore: cast_nullable_to_non_nullable
as double?,solvedDec: freezed == solvedDec ? _self.solvedDec : solvedDec // ignore: cast_nullable_to_non_nullable
as double?,errorMessage: freezed == errorMessage ? _self.errorMessage : errorMessage // ignore: cast_nullable_to_non_nullable
as String?,config: freezed == config ? _self.config : config // ignore: cast_nullable_to_non_nullable
as PolarAlignmentConfig?,startedAt: freezed == startedAt ? _self.startedAt : startedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}

/// Create a copy of PolarAlignmentState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PolarAlignmentErrorCopyWith<$Res>? get currentError {
    if (_self.currentError == null) {
    return null;
  }

  return $PolarAlignmentErrorCopyWith<$Res>(_self.currentError!, (value) {
    return _then(_self.copyWith(currentError: value));
  });
}/// Create a copy of PolarAlignmentState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PolarAlignmentErrorCopyWith<$Res>? get initialError {
    if (_self.initialError == null) {
    return null;
  }

  return $PolarAlignmentErrorCopyWith<$Res>(_self.initialError!, (value) {
    return _then(_self.copyWith(initialError: value));
  });
}/// Create a copy of PolarAlignmentState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PolarAlignmentConfigCopyWith<$Res>? get config {
    if (_self.config == null) {
    return null;
  }

  return $PolarAlignmentConfigCopyWith<$Res>(_self.config!, (value) {
    return _then(_self.copyWith(config: value));
  });
}
}


/// @nodoc
mixin _$PolarAlignmentResult {

/// Initial error at start of adjustment phase
 PolarAlignmentError get initialError;/// Final error when alignment completed or stopped
 PolarAlignmentError get finalError;/// When alignment started
 DateTime get startedAt;/// When alignment completed
 DateTime get completedAt;/// Configuration used for this alignment
 PolarAlignmentConfig get config;/// Whether alignment was auto-completed (reached threshold)
 bool get autoCompleted;/// Equipment profile ID used (for history tracking)
 int? get equipmentProfileId;
/// Create a copy of PolarAlignmentResult
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PolarAlignmentResultCopyWith<PolarAlignmentResult> get copyWith => _$PolarAlignmentResultCopyWithImpl<PolarAlignmentResult>(this as PolarAlignmentResult, _$identity);

  /// Serializes this PolarAlignmentResult to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PolarAlignmentResult&&(identical(other.initialError, initialError) || other.initialError == initialError)&&(identical(other.finalError, finalError) || other.finalError == finalError)&&(identical(other.startedAt, startedAt) || other.startedAt == startedAt)&&(identical(other.completedAt, completedAt) || other.completedAt == completedAt)&&(identical(other.config, config) || other.config == config)&&(identical(other.autoCompleted, autoCompleted) || other.autoCompleted == autoCompleted)&&(identical(other.equipmentProfileId, equipmentProfileId) || other.equipmentProfileId == equipmentProfileId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,initialError,finalError,startedAt,completedAt,config,autoCompleted,equipmentProfileId);

@override
String toString() {
  return 'PolarAlignmentResult(initialError: $initialError, finalError: $finalError, startedAt: $startedAt, completedAt: $completedAt, config: $config, autoCompleted: $autoCompleted, equipmentProfileId: $equipmentProfileId)';
}


}

/// @nodoc
abstract mixin class $PolarAlignmentResultCopyWith<$Res>  {
  factory $PolarAlignmentResultCopyWith(PolarAlignmentResult value, $Res Function(PolarAlignmentResult) _then) = _$PolarAlignmentResultCopyWithImpl;
@useResult
$Res call({
 PolarAlignmentError initialError, PolarAlignmentError finalError, DateTime startedAt, DateTime completedAt, PolarAlignmentConfig config, bool autoCompleted, int? equipmentProfileId
});


$PolarAlignmentErrorCopyWith<$Res> get initialError;$PolarAlignmentErrorCopyWith<$Res> get finalError;$PolarAlignmentConfigCopyWith<$Res> get config;

}
/// @nodoc
class _$PolarAlignmentResultCopyWithImpl<$Res>
    implements $PolarAlignmentResultCopyWith<$Res> {
  _$PolarAlignmentResultCopyWithImpl(this._self, this._then);

  final PolarAlignmentResult _self;
  final $Res Function(PolarAlignmentResult) _then;

/// Create a copy of PolarAlignmentResult
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? initialError = null,Object? finalError = null,Object? startedAt = null,Object? completedAt = null,Object? config = null,Object? autoCompleted = null,Object? equipmentProfileId = freezed,}) {
  return _then(_self.copyWith(
initialError: null == initialError ? _self.initialError : initialError // ignore: cast_nullable_to_non_nullable
as PolarAlignmentError,finalError: null == finalError ? _self.finalError : finalError // ignore: cast_nullable_to_non_nullable
as PolarAlignmentError,startedAt: null == startedAt ? _self.startedAt : startedAt // ignore: cast_nullable_to_non_nullable
as DateTime,completedAt: null == completedAt ? _self.completedAt : completedAt // ignore: cast_nullable_to_non_nullable
as DateTime,config: null == config ? _self.config : config // ignore: cast_nullable_to_non_nullable
as PolarAlignmentConfig,autoCompleted: null == autoCompleted ? _self.autoCompleted : autoCompleted // ignore: cast_nullable_to_non_nullable
as bool,equipmentProfileId: freezed == equipmentProfileId ? _self.equipmentProfileId : equipmentProfileId // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}
/// Create a copy of PolarAlignmentResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PolarAlignmentErrorCopyWith<$Res> get initialError {
  
  return $PolarAlignmentErrorCopyWith<$Res>(_self.initialError, (value) {
    return _then(_self.copyWith(initialError: value));
  });
}/// Create a copy of PolarAlignmentResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PolarAlignmentErrorCopyWith<$Res> get finalError {
  
  return $PolarAlignmentErrorCopyWith<$Res>(_self.finalError, (value) {
    return _then(_self.copyWith(finalError: value));
  });
}/// Create a copy of PolarAlignmentResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PolarAlignmentConfigCopyWith<$Res> get config {
  
  return $PolarAlignmentConfigCopyWith<$Res>(_self.config, (value) {
    return _then(_self.copyWith(config: value));
  });
}
}


/// Adds pattern-matching-related methods to [PolarAlignmentResult].
extension PolarAlignmentResultPatterns on PolarAlignmentResult {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PolarAlignmentResult value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PolarAlignmentResult() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PolarAlignmentResult value)  $default,){
final _that = this;
switch (_that) {
case _PolarAlignmentResult():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PolarAlignmentResult value)?  $default,){
final _that = this;
switch (_that) {
case _PolarAlignmentResult() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( PolarAlignmentError initialError,  PolarAlignmentError finalError,  DateTime startedAt,  DateTime completedAt,  PolarAlignmentConfig config,  bool autoCompleted,  int? equipmentProfileId)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PolarAlignmentResult() when $default != null:
return $default(_that.initialError,_that.finalError,_that.startedAt,_that.completedAt,_that.config,_that.autoCompleted,_that.equipmentProfileId);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( PolarAlignmentError initialError,  PolarAlignmentError finalError,  DateTime startedAt,  DateTime completedAt,  PolarAlignmentConfig config,  bool autoCompleted,  int? equipmentProfileId)  $default,) {final _that = this;
switch (_that) {
case _PolarAlignmentResult():
return $default(_that.initialError,_that.finalError,_that.startedAt,_that.completedAt,_that.config,_that.autoCompleted,_that.equipmentProfileId);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( PolarAlignmentError initialError,  PolarAlignmentError finalError,  DateTime startedAt,  DateTime completedAt,  PolarAlignmentConfig config,  bool autoCompleted,  int? equipmentProfileId)?  $default,) {final _that = this;
switch (_that) {
case _PolarAlignmentResult() when $default != null:
return $default(_that.initialError,_that.finalError,_that.startedAt,_that.completedAt,_that.config,_that.autoCompleted,_that.equipmentProfileId);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PolarAlignmentResult extends PolarAlignmentResult {
  const _PolarAlignmentResult({required this.initialError, required this.finalError, required this.startedAt, required this.completedAt, required this.config, this.autoCompleted = false, this.equipmentProfileId}): super._();
  factory _PolarAlignmentResult.fromJson(Map<String, dynamic> json) => _$PolarAlignmentResultFromJson(json);

/// Initial error at start of adjustment phase
@override final  PolarAlignmentError initialError;
/// Final error when alignment completed or stopped
@override final  PolarAlignmentError finalError;
/// When alignment started
@override final  DateTime startedAt;
/// When alignment completed
@override final  DateTime completedAt;
/// Configuration used for this alignment
@override final  PolarAlignmentConfig config;
/// Whether alignment was auto-completed (reached threshold)
@override@JsonKey() final  bool autoCompleted;
/// Equipment profile ID used (for history tracking)
@override final  int? equipmentProfileId;

/// Create a copy of PolarAlignmentResult
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PolarAlignmentResultCopyWith<_PolarAlignmentResult> get copyWith => __$PolarAlignmentResultCopyWithImpl<_PolarAlignmentResult>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PolarAlignmentResultToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PolarAlignmentResult&&(identical(other.initialError, initialError) || other.initialError == initialError)&&(identical(other.finalError, finalError) || other.finalError == finalError)&&(identical(other.startedAt, startedAt) || other.startedAt == startedAt)&&(identical(other.completedAt, completedAt) || other.completedAt == completedAt)&&(identical(other.config, config) || other.config == config)&&(identical(other.autoCompleted, autoCompleted) || other.autoCompleted == autoCompleted)&&(identical(other.equipmentProfileId, equipmentProfileId) || other.equipmentProfileId == equipmentProfileId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,initialError,finalError,startedAt,completedAt,config,autoCompleted,equipmentProfileId);

@override
String toString() {
  return 'PolarAlignmentResult(initialError: $initialError, finalError: $finalError, startedAt: $startedAt, completedAt: $completedAt, config: $config, autoCompleted: $autoCompleted, equipmentProfileId: $equipmentProfileId)';
}


}

/// @nodoc
abstract mixin class _$PolarAlignmentResultCopyWith<$Res> implements $PolarAlignmentResultCopyWith<$Res> {
  factory _$PolarAlignmentResultCopyWith(_PolarAlignmentResult value, $Res Function(_PolarAlignmentResult) _then) = __$PolarAlignmentResultCopyWithImpl;
@override @useResult
$Res call({
 PolarAlignmentError initialError, PolarAlignmentError finalError, DateTime startedAt, DateTime completedAt, PolarAlignmentConfig config, bool autoCompleted, int? equipmentProfileId
});


@override $PolarAlignmentErrorCopyWith<$Res> get initialError;@override $PolarAlignmentErrorCopyWith<$Res> get finalError;@override $PolarAlignmentConfigCopyWith<$Res> get config;

}
/// @nodoc
class __$PolarAlignmentResultCopyWithImpl<$Res>
    implements _$PolarAlignmentResultCopyWith<$Res> {
  __$PolarAlignmentResultCopyWithImpl(this._self, this._then);

  final _PolarAlignmentResult _self;
  final $Res Function(_PolarAlignmentResult) _then;

/// Create a copy of PolarAlignmentResult
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? initialError = null,Object? finalError = null,Object? startedAt = null,Object? completedAt = null,Object? config = null,Object? autoCompleted = null,Object? equipmentProfileId = freezed,}) {
  return _then(_PolarAlignmentResult(
initialError: null == initialError ? _self.initialError : initialError // ignore: cast_nullable_to_non_nullable
as PolarAlignmentError,finalError: null == finalError ? _self.finalError : finalError // ignore: cast_nullable_to_non_nullable
as PolarAlignmentError,startedAt: null == startedAt ? _self.startedAt : startedAt // ignore: cast_nullable_to_non_nullable
as DateTime,completedAt: null == completedAt ? _self.completedAt : completedAt // ignore: cast_nullable_to_non_nullable
as DateTime,config: null == config ? _self.config : config // ignore: cast_nullable_to_non_nullable
as PolarAlignmentConfig,autoCompleted: null == autoCompleted ? _self.autoCompleted : autoCompleted // ignore: cast_nullable_to_non_nullable
as bool,equipmentProfileId: freezed == equipmentProfileId ? _self.equipmentProfileId : equipmentProfileId // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}

/// Create a copy of PolarAlignmentResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PolarAlignmentErrorCopyWith<$Res> get initialError {
  
  return $PolarAlignmentErrorCopyWith<$Res>(_self.initialError, (value) {
    return _then(_self.copyWith(initialError: value));
  });
}/// Create a copy of PolarAlignmentResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PolarAlignmentErrorCopyWith<$Res> get finalError {
  
  return $PolarAlignmentErrorCopyWith<$Res>(_self.finalError, (value) {
    return _then(_self.copyWith(finalError: value));
  });
}/// Create a copy of PolarAlignmentResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PolarAlignmentConfigCopyWith<$Res> get config {
  
  return $PolarAlignmentConfigCopyWith<$Res>(_self.config, (value) {
    return _then(_self.copyWith(config: value));
  });
}
}

// dart format on
