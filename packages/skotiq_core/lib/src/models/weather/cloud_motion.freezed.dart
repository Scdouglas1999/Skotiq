// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'cloud_motion.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$CloudMotion {

/// Cloud movement speed in km/h
 double get speedKmh;/// Direction clouds are moving TOWARD (0-360, 0=N, 90=E, 180=S, 270=W)
 double get directionDegrees;/// Time until clouds reach user location (null if moving away)
 Duration? get etaToLocation;/// Current distance of nearest significant clouds in kilometers
 double get distanceKm;/// When this analysis was performed
 DateTime get calculatedAt;
/// Create a copy of CloudMotion
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CloudMotionCopyWith<CloudMotion> get copyWith => _$CloudMotionCopyWithImpl<CloudMotion>(this as CloudMotion, _$identity);

  /// Serializes this CloudMotion to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CloudMotion&&(identical(other.speedKmh, speedKmh) || other.speedKmh == speedKmh)&&(identical(other.directionDegrees, directionDegrees) || other.directionDegrees == directionDegrees)&&(identical(other.etaToLocation, etaToLocation) || other.etaToLocation == etaToLocation)&&(identical(other.distanceKm, distanceKm) || other.distanceKm == distanceKm)&&(identical(other.calculatedAt, calculatedAt) || other.calculatedAt == calculatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,speedKmh,directionDegrees,etaToLocation,distanceKm,calculatedAt);

@override
String toString() {
  return 'CloudMotion(speedKmh: $speedKmh, directionDegrees: $directionDegrees, etaToLocation: $etaToLocation, distanceKm: $distanceKm, calculatedAt: $calculatedAt)';
}


}

/// @nodoc
abstract mixin class $CloudMotionCopyWith<$Res>  {
  factory $CloudMotionCopyWith(CloudMotion value, $Res Function(CloudMotion) _then) = _$CloudMotionCopyWithImpl;
@useResult
$Res call({
 double speedKmh, double directionDegrees, Duration? etaToLocation, double distanceKm, DateTime calculatedAt
});




}
/// @nodoc
class _$CloudMotionCopyWithImpl<$Res>
    implements $CloudMotionCopyWith<$Res> {
  _$CloudMotionCopyWithImpl(this._self, this._then);

  final CloudMotion _self;
  final $Res Function(CloudMotion) _then;

/// Create a copy of CloudMotion
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? speedKmh = null,Object? directionDegrees = null,Object? etaToLocation = freezed,Object? distanceKm = null,Object? calculatedAt = null,}) {
  return _then(_self.copyWith(
speedKmh: null == speedKmh ? _self.speedKmh : speedKmh // ignore: cast_nullable_to_non_nullable
as double,directionDegrees: null == directionDegrees ? _self.directionDegrees : directionDegrees // ignore: cast_nullable_to_non_nullable
as double,etaToLocation: freezed == etaToLocation ? _self.etaToLocation : etaToLocation // ignore: cast_nullable_to_non_nullable
as Duration?,distanceKm: null == distanceKm ? _self.distanceKm : distanceKm // ignore: cast_nullable_to_non_nullable
as double,calculatedAt: null == calculatedAt ? _self.calculatedAt : calculatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}

}


/// Adds pattern-matching-related methods to [CloudMotion].
extension CloudMotionPatterns on CloudMotion {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _CloudMotion value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _CloudMotion() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _CloudMotion value)  $default,){
final _that = this;
switch (_that) {
case _CloudMotion():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _CloudMotion value)?  $default,){
final _that = this;
switch (_that) {
case _CloudMotion() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double speedKmh,  double directionDegrees,  Duration? etaToLocation,  double distanceKm,  DateTime calculatedAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _CloudMotion() when $default != null:
return $default(_that.speedKmh,_that.directionDegrees,_that.etaToLocation,_that.distanceKm,_that.calculatedAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double speedKmh,  double directionDegrees,  Duration? etaToLocation,  double distanceKm,  DateTime calculatedAt)  $default,) {final _that = this;
switch (_that) {
case _CloudMotion():
return $default(_that.speedKmh,_that.directionDegrees,_that.etaToLocation,_that.distanceKm,_that.calculatedAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double speedKmh,  double directionDegrees,  Duration? etaToLocation,  double distanceKm,  DateTime calculatedAt)?  $default,) {final _that = this;
switch (_that) {
case _CloudMotion() when $default != null:
return $default(_that.speedKmh,_that.directionDegrees,_that.etaToLocation,_that.distanceKm,_that.calculatedAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _CloudMotion implements CloudMotion {
  const _CloudMotion({required this.speedKmh, required this.directionDegrees, this.etaToLocation, required this.distanceKm, required this.calculatedAt});
  factory _CloudMotion.fromJson(Map<String, dynamic> json) => _$CloudMotionFromJson(json);

/// Cloud movement speed in km/h
@override final  double speedKmh;
/// Direction clouds are moving TOWARD (0-360, 0=N, 90=E, 180=S, 270=W)
@override final  double directionDegrees;
/// Time until clouds reach user location (null if moving away)
@override final  Duration? etaToLocation;
/// Current distance of nearest significant clouds in kilometers
@override final  double distanceKm;
/// When this analysis was performed
@override final  DateTime calculatedAt;

/// Create a copy of CloudMotion
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$CloudMotionCopyWith<_CloudMotion> get copyWith => __$CloudMotionCopyWithImpl<_CloudMotion>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$CloudMotionToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _CloudMotion&&(identical(other.speedKmh, speedKmh) || other.speedKmh == speedKmh)&&(identical(other.directionDegrees, directionDegrees) || other.directionDegrees == directionDegrees)&&(identical(other.etaToLocation, etaToLocation) || other.etaToLocation == etaToLocation)&&(identical(other.distanceKm, distanceKm) || other.distanceKm == distanceKm)&&(identical(other.calculatedAt, calculatedAt) || other.calculatedAt == calculatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,speedKmh,directionDegrees,etaToLocation,distanceKm,calculatedAt);

@override
String toString() {
  return 'CloudMotion(speedKmh: $speedKmh, directionDegrees: $directionDegrees, etaToLocation: $etaToLocation, distanceKm: $distanceKm, calculatedAt: $calculatedAt)';
}


}

/// @nodoc
abstract mixin class _$CloudMotionCopyWith<$Res> implements $CloudMotionCopyWith<$Res> {
  factory _$CloudMotionCopyWith(_CloudMotion value, $Res Function(_CloudMotion) _then) = __$CloudMotionCopyWithImpl;
@override @useResult
$Res call({
 double speedKmh, double directionDegrees, Duration? etaToLocation, double distanceKm, DateTime calculatedAt
});




}
/// @nodoc
class __$CloudMotionCopyWithImpl<$Res>
    implements _$CloudMotionCopyWith<$Res> {
  __$CloudMotionCopyWithImpl(this._self, this._then);

  final _CloudMotion _self;
  final $Res Function(_CloudMotion) _then;

/// Create a copy of CloudMotion
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? speedKmh = null,Object? directionDegrees = null,Object? etaToLocation = freezed,Object? distanceKm = null,Object? calculatedAt = null,}) {
  return _then(_CloudMotion(
speedKmh: null == speedKmh ? _self.speedKmh : speedKmh // ignore: cast_nullable_to_non_nullable
as double,directionDegrees: null == directionDegrees ? _self.directionDegrees : directionDegrees // ignore: cast_nullable_to_non_nullable
as double,etaToLocation: freezed == etaToLocation ? _self.etaToLocation : etaToLocation // ignore: cast_nullable_to_non_nullable
as Duration?,distanceKm: null == distanceKm ? _self.distanceKm : distanceKm // ignore: cast_nullable_to_non_nullable
as double,calculatedAt: null == calculatedAt ? _self.calculatedAt : calculatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}


}

// dart format on
