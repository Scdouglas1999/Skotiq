// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'optical_config.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$OpticalConfig {

/// Name of the telescope/OTA
 String? get telescopeName;/// Focal length in millimeters
 double? get focalLength;/// Aperture in millimeters
 double? get aperture;/// Focal ratio (f/number), computed from focalLength/aperture if not set
 double? get focalRatio;/// Camera name
 String? get cameraName;/// Sensor width in pixels
 int? get sensorWidth;/// Sensor height in pixels
 int? get sensorHeight;/// Pixel size in microns
 double? get pixelSize;
/// Create a copy of OpticalConfig
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$OpticalConfigCopyWith<OpticalConfig> get copyWith => _$OpticalConfigCopyWithImpl<OpticalConfig>(this as OpticalConfig, _$identity);

  /// Serializes this OpticalConfig to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is OpticalConfig&&(identical(other.telescopeName, telescopeName) || other.telescopeName == telescopeName)&&(identical(other.focalLength, focalLength) || other.focalLength == focalLength)&&(identical(other.aperture, aperture) || other.aperture == aperture)&&(identical(other.focalRatio, focalRatio) || other.focalRatio == focalRatio)&&(identical(other.cameraName, cameraName) || other.cameraName == cameraName)&&(identical(other.sensorWidth, sensorWidth) || other.sensorWidth == sensorWidth)&&(identical(other.sensorHeight, sensorHeight) || other.sensorHeight == sensorHeight)&&(identical(other.pixelSize, pixelSize) || other.pixelSize == pixelSize));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,telescopeName,focalLength,aperture,focalRatio,cameraName,sensorWidth,sensorHeight,pixelSize);

@override
String toString() {
  return 'OpticalConfig(telescopeName: $telescopeName, focalLength: $focalLength, aperture: $aperture, focalRatio: $focalRatio, cameraName: $cameraName, sensorWidth: $sensorWidth, sensorHeight: $sensorHeight, pixelSize: $pixelSize)';
}


}

/// @nodoc
abstract mixin class $OpticalConfigCopyWith<$Res>  {
  factory $OpticalConfigCopyWith(OpticalConfig value, $Res Function(OpticalConfig) _then) = _$OpticalConfigCopyWithImpl;
@useResult
$Res call({
 String? telescopeName, double? focalLength, double? aperture, double? focalRatio, String? cameraName, int? sensorWidth, int? sensorHeight, double? pixelSize
});




}
/// @nodoc
class _$OpticalConfigCopyWithImpl<$Res>
    implements $OpticalConfigCopyWith<$Res> {
  _$OpticalConfigCopyWithImpl(this._self, this._then);

  final OpticalConfig _self;
  final $Res Function(OpticalConfig) _then;

/// Create a copy of OpticalConfig
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? telescopeName = freezed,Object? focalLength = freezed,Object? aperture = freezed,Object? focalRatio = freezed,Object? cameraName = freezed,Object? sensorWidth = freezed,Object? sensorHeight = freezed,Object? pixelSize = freezed,}) {
  return _then(_self.copyWith(
telescopeName: freezed == telescopeName ? _self.telescopeName : telescopeName // ignore: cast_nullable_to_non_nullable
as String?,focalLength: freezed == focalLength ? _self.focalLength : focalLength // ignore: cast_nullable_to_non_nullable
as double?,aperture: freezed == aperture ? _self.aperture : aperture // ignore: cast_nullable_to_non_nullable
as double?,focalRatio: freezed == focalRatio ? _self.focalRatio : focalRatio // ignore: cast_nullable_to_non_nullable
as double?,cameraName: freezed == cameraName ? _self.cameraName : cameraName // ignore: cast_nullable_to_non_nullable
as String?,sensorWidth: freezed == sensorWidth ? _self.sensorWidth : sensorWidth // ignore: cast_nullable_to_non_nullable
as int?,sensorHeight: freezed == sensorHeight ? _self.sensorHeight : sensorHeight // ignore: cast_nullable_to_non_nullable
as int?,pixelSize: freezed == pixelSize ? _self.pixelSize : pixelSize // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}

}


/// Adds pattern-matching-related methods to [OpticalConfig].
extension OpticalConfigPatterns on OpticalConfig {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _OpticalConfig value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _OpticalConfig() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _OpticalConfig value)  $default,){
final _that = this;
switch (_that) {
case _OpticalConfig():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _OpticalConfig value)?  $default,){
final _that = this;
switch (_that) {
case _OpticalConfig() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? telescopeName,  double? focalLength,  double? aperture,  double? focalRatio,  String? cameraName,  int? sensorWidth,  int? sensorHeight,  double? pixelSize)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _OpticalConfig() when $default != null:
return $default(_that.telescopeName,_that.focalLength,_that.aperture,_that.focalRatio,_that.cameraName,_that.sensorWidth,_that.sensorHeight,_that.pixelSize);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? telescopeName,  double? focalLength,  double? aperture,  double? focalRatio,  String? cameraName,  int? sensorWidth,  int? sensorHeight,  double? pixelSize)  $default,) {final _that = this;
switch (_that) {
case _OpticalConfig():
return $default(_that.telescopeName,_that.focalLength,_that.aperture,_that.focalRatio,_that.cameraName,_that.sensorWidth,_that.sensorHeight,_that.pixelSize);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? telescopeName,  double? focalLength,  double? aperture,  double? focalRatio,  String? cameraName,  int? sensorWidth,  int? sensorHeight,  double? pixelSize)?  $default,) {final _that = this;
switch (_that) {
case _OpticalConfig() when $default != null:
return $default(_that.telescopeName,_that.focalLength,_that.aperture,_that.focalRatio,_that.cameraName,_that.sensorWidth,_that.sensorHeight,_that.pixelSize);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _OpticalConfig extends OpticalConfig {
  const _OpticalConfig({this.telescopeName, this.focalLength, this.aperture, this.focalRatio, this.cameraName, this.sensorWidth, this.sensorHeight, this.pixelSize}): super._();
  factory _OpticalConfig.fromJson(Map<String, dynamic> json) => _$OpticalConfigFromJson(json);

/// Name of the telescope/OTA
@override final  String? telescopeName;
/// Focal length in millimeters
@override final  double? focalLength;
/// Aperture in millimeters
@override final  double? aperture;
/// Focal ratio (f/number), computed from focalLength/aperture if not set
@override final  double? focalRatio;
/// Camera name
@override final  String? cameraName;
/// Sensor width in pixels
@override final  int? sensorWidth;
/// Sensor height in pixels
@override final  int? sensorHeight;
/// Pixel size in microns
@override final  double? pixelSize;

/// Create a copy of OpticalConfig
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$OpticalConfigCopyWith<_OpticalConfig> get copyWith => __$OpticalConfigCopyWithImpl<_OpticalConfig>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$OpticalConfigToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _OpticalConfig&&(identical(other.telescopeName, telescopeName) || other.telescopeName == telescopeName)&&(identical(other.focalLength, focalLength) || other.focalLength == focalLength)&&(identical(other.aperture, aperture) || other.aperture == aperture)&&(identical(other.focalRatio, focalRatio) || other.focalRatio == focalRatio)&&(identical(other.cameraName, cameraName) || other.cameraName == cameraName)&&(identical(other.sensorWidth, sensorWidth) || other.sensorWidth == sensorWidth)&&(identical(other.sensorHeight, sensorHeight) || other.sensorHeight == sensorHeight)&&(identical(other.pixelSize, pixelSize) || other.pixelSize == pixelSize));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,telescopeName,focalLength,aperture,focalRatio,cameraName,sensorWidth,sensorHeight,pixelSize);

@override
String toString() {
  return 'OpticalConfig(telescopeName: $telescopeName, focalLength: $focalLength, aperture: $aperture, focalRatio: $focalRatio, cameraName: $cameraName, sensorWidth: $sensorWidth, sensorHeight: $sensorHeight, pixelSize: $pixelSize)';
}


}

/// @nodoc
abstract mixin class _$OpticalConfigCopyWith<$Res> implements $OpticalConfigCopyWith<$Res> {
  factory _$OpticalConfigCopyWith(_OpticalConfig value, $Res Function(_OpticalConfig) _then) = __$OpticalConfigCopyWithImpl;
@override @useResult
$Res call({
 String? telescopeName, double? focalLength, double? aperture, double? focalRatio, String? cameraName, int? sensorWidth, int? sensorHeight, double? pixelSize
});




}
/// @nodoc
class __$OpticalConfigCopyWithImpl<$Res>
    implements _$OpticalConfigCopyWith<$Res> {
  __$OpticalConfigCopyWithImpl(this._self, this._then);

  final _OpticalConfig _self;
  final $Res Function(_OpticalConfig) _then;

/// Create a copy of OpticalConfig
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? telescopeName = freezed,Object? focalLength = freezed,Object? aperture = freezed,Object? focalRatio = freezed,Object? cameraName = freezed,Object? sensorWidth = freezed,Object? sensorHeight = freezed,Object? pixelSize = freezed,}) {
  return _then(_OpticalConfig(
telescopeName: freezed == telescopeName ? _self.telescopeName : telescopeName // ignore: cast_nullable_to_non_nullable
as String?,focalLength: freezed == focalLength ? _self.focalLength : focalLength // ignore: cast_nullable_to_non_nullable
as double?,aperture: freezed == aperture ? _self.aperture : aperture // ignore: cast_nullable_to_non_nullable
as double?,focalRatio: freezed == focalRatio ? _self.focalRatio : focalRatio // ignore: cast_nullable_to_non_nullable
as double?,cameraName: freezed == cameraName ? _self.cameraName : cameraName // ignore: cast_nullable_to_non_nullable
as String?,sensorWidth: freezed == sensorWidth ? _self.sensorWidth : sensorWidth // ignore: cast_nullable_to_non_nullable
as int?,sensorHeight: freezed == sensorHeight ? _self.sensorHeight : sensorHeight // ignore: cast_nullable_to_non_nullable
as int?,pixelSize: freezed == pixelSize ? _self.pixelSize : pixelSize // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}


}

// dart format on
