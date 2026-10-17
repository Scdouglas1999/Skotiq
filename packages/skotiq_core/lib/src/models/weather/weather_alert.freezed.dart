// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'weather_alert.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$WeatherAlert {

/// Alert severity level
 AlertLevel get level;/// Human-readable alert text
 String get message;/// When clouds expected (null if clear/watch)
 DateTime? get eta;/// Cloud density percentage (0-100)
 double get cloudDensityPercent;/// Distance to threatening clouds in kilometers
 double get distanceKm;/// When this alert was generated
 DateTime get generatedAt;
/// Create a copy of WeatherAlert
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$WeatherAlertCopyWith<WeatherAlert> get copyWith => _$WeatherAlertCopyWithImpl<WeatherAlert>(this as WeatherAlert, _$identity);

  /// Serializes this WeatherAlert to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is WeatherAlert&&(identical(other.level, level) || other.level == level)&&(identical(other.message, message) || other.message == message)&&(identical(other.eta, eta) || other.eta == eta)&&(identical(other.cloudDensityPercent, cloudDensityPercent) || other.cloudDensityPercent == cloudDensityPercent)&&(identical(other.distanceKm, distanceKm) || other.distanceKm == distanceKm)&&(identical(other.generatedAt, generatedAt) || other.generatedAt == generatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,level,message,eta,cloudDensityPercent,distanceKm,generatedAt);

@override
String toString() {
  return 'WeatherAlert(level: $level, message: $message, eta: $eta, cloudDensityPercent: $cloudDensityPercent, distanceKm: $distanceKm, generatedAt: $generatedAt)';
}


}

/// @nodoc
abstract mixin class $WeatherAlertCopyWith<$Res>  {
  factory $WeatherAlertCopyWith(WeatherAlert value, $Res Function(WeatherAlert) _then) = _$WeatherAlertCopyWithImpl;
@useResult
$Res call({
 AlertLevel level, String message, DateTime? eta, double cloudDensityPercent, double distanceKm, DateTime generatedAt
});




}
/// @nodoc
class _$WeatherAlertCopyWithImpl<$Res>
    implements $WeatherAlertCopyWith<$Res> {
  _$WeatherAlertCopyWithImpl(this._self, this._then);

  final WeatherAlert _self;
  final $Res Function(WeatherAlert) _then;

/// Create a copy of WeatherAlert
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? level = null,Object? message = null,Object? eta = freezed,Object? cloudDensityPercent = null,Object? distanceKm = null,Object? generatedAt = null,}) {
  return _then(_self.copyWith(
level: null == level ? _self.level : level // ignore: cast_nullable_to_non_nullable
as AlertLevel,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,eta: freezed == eta ? _self.eta : eta // ignore: cast_nullable_to_non_nullable
as DateTime?,cloudDensityPercent: null == cloudDensityPercent ? _self.cloudDensityPercent : cloudDensityPercent // ignore: cast_nullable_to_non_nullable
as double,distanceKm: null == distanceKm ? _self.distanceKm : distanceKm // ignore: cast_nullable_to_non_nullable
as double,generatedAt: null == generatedAt ? _self.generatedAt : generatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}

}


/// Adds pattern-matching-related methods to [WeatherAlert].
extension WeatherAlertPatterns on WeatherAlert {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _WeatherAlert value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _WeatherAlert() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _WeatherAlert value)  $default,){
final _that = this;
switch (_that) {
case _WeatherAlert():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _WeatherAlert value)?  $default,){
final _that = this;
switch (_that) {
case _WeatherAlert() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( AlertLevel level,  String message,  DateTime? eta,  double cloudDensityPercent,  double distanceKm,  DateTime generatedAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _WeatherAlert() when $default != null:
return $default(_that.level,_that.message,_that.eta,_that.cloudDensityPercent,_that.distanceKm,_that.generatedAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( AlertLevel level,  String message,  DateTime? eta,  double cloudDensityPercent,  double distanceKm,  DateTime generatedAt)  $default,) {final _that = this;
switch (_that) {
case _WeatherAlert():
return $default(_that.level,_that.message,_that.eta,_that.cloudDensityPercent,_that.distanceKm,_that.generatedAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( AlertLevel level,  String message,  DateTime? eta,  double cloudDensityPercent,  double distanceKm,  DateTime generatedAt)?  $default,) {final _that = this;
switch (_that) {
case _WeatherAlert() when $default != null:
return $default(_that.level,_that.message,_that.eta,_that.cloudDensityPercent,_that.distanceKm,_that.generatedAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _WeatherAlert implements WeatherAlert {
  const _WeatherAlert({required this.level, required this.message, this.eta, required this.cloudDensityPercent, required this.distanceKm, required this.generatedAt});
  factory _WeatherAlert.fromJson(Map<String, dynamic> json) => _$WeatherAlertFromJson(json);

/// Alert severity level
@override final  AlertLevel level;
/// Human-readable alert text
@override final  String message;
/// When clouds expected (null if clear/watch)
@override final  DateTime? eta;
/// Cloud density percentage (0-100)
@override final  double cloudDensityPercent;
/// Distance to threatening clouds in kilometers
@override final  double distanceKm;
/// When this alert was generated
@override final  DateTime generatedAt;

/// Create a copy of WeatherAlert
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$WeatherAlertCopyWith<_WeatherAlert> get copyWith => __$WeatherAlertCopyWithImpl<_WeatherAlert>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$WeatherAlertToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _WeatherAlert&&(identical(other.level, level) || other.level == level)&&(identical(other.message, message) || other.message == message)&&(identical(other.eta, eta) || other.eta == eta)&&(identical(other.cloudDensityPercent, cloudDensityPercent) || other.cloudDensityPercent == cloudDensityPercent)&&(identical(other.distanceKm, distanceKm) || other.distanceKm == distanceKm)&&(identical(other.generatedAt, generatedAt) || other.generatedAt == generatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,level,message,eta,cloudDensityPercent,distanceKm,generatedAt);

@override
String toString() {
  return 'WeatherAlert(level: $level, message: $message, eta: $eta, cloudDensityPercent: $cloudDensityPercent, distanceKm: $distanceKm, generatedAt: $generatedAt)';
}


}

/// @nodoc
abstract mixin class _$WeatherAlertCopyWith<$Res> implements $WeatherAlertCopyWith<$Res> {
  factory _$WeatherAlertCopyWith(_WeatherAlert value, $Res Function(_WeatherAlert) _then) = __$WeatherAlertCopyWithImpl;
@override @useResult
$Res call({
 AlertLevel level, String message, DateTime? eta, double cloudDensityPercent, double distanceKm, DateTime generatedAt
});




}
/// @nodoc
class __$WeatherAlertCopyWithImpl<$Res>
    implements _$WeatherAlertCopyWith<$Res> {
  __$WeatherAlertCopyWithImpl(this._self, this._then);

  final _WeatherAlert _self;
  final $Res Function(_WeatherAlert) _then;

/// Create a copy of WeatherAlert
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? level = null,Object? message = null,Object? eta = freezed,Object? cloudDensityPercent = null,Object? distanceKm = null,Object? generatedAt = null,}) {
  return _then(_WeatherAlert(
level: null == level ? _self.level : level // ignore: cast_nullable_to_non_nullable
as AlertLevel,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,eta: freezed == eta ? _self.eta : eta // ignore: cast_nullable_to_non_nullable
as DateTime?,cloudDensityPercent: null == cloudDensityPercent ? _self.cloudDensityPercent : cloudDensityPercent // ignore: cast_nullable_to_non_nullable
as double,distanceKm: null == distanceKm ? _self.distanceKm : distanceKm // ignore: cast_nullable_to_non_nullable
as double,generatedAt: null == generatedAt ? _self.generatedAt : generatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}


}

// dart format on
