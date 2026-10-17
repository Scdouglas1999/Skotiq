// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'auto_stretch_settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$AutoStretchSettings {

/// Whether auto-stretch is enabled for image display.
 bool get enabled;/// The stretch method to use.
 AutoStretchMethod get method;/// Shadow clipping parameter (in standard deviations from median).
/// Lower (more negative) values clip more shadows.
/// Typical range: -4.0 to -1.0. Default -2.8 is standard for STF.
 double get shadowClip;/// Highlight clipping parameter (in standard deviations from median).
/// Lower (more negative) values clip more highlights.
/// Typical range: -1.0 to 0.0. Default -0.5 protects highlights.
 double get highlightClip;/// Target median level for the stretched image (0.0 to 1.0).
/// Higher values produce brighter midtones.
/// Default 0.25 places the median in the lower quarter for natural appearance.
 double get targetMedian;/// Whether to link RGB channels during stretch calculation.
/// When true, uses the same stretch parameters for all channels to preserve
/// color balance. When false, each channel is stretched independently.
 bool get linkedChannels;/// Gamma value for gamma correction method.
/// Only used when [method] is [AutoStretchMethod.gamma].
/// Standard display gamma is 2.2. Lower values brighten, higher values darken.
 double get gammaValue;
/// Create a copy of AutoStretchSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AutoStretchSettingsCopyWith<AutoStretchSettings> get copyWith => _$AutoStretchSettingsCopyWithImpl<AutoStretchSettings>(this as AutoStretchSettings, _$identity);

  /// Serializes this AutoStretchSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AutoStretchSettings&&(identical(other.enabled, enabled) || other.enabled == enabled)&&(identical(other.method, method) || other.method == method)&&(identical(other.shadowClip, shadowClip) || other.shadowClip == shadowClip)&&(identical(other.highlightClip, highlightClip) || other.highlightClip == highlightClip)&&(identical(other.targetMedian, targetMedian) || other.targetMedian == targetMedian)&&(identical(other.linkedChannels, linkedChannels) || other.linkedChannels == linkedChannels)&&(identical(other.gammaValue, gammaValue) || other.gammaValue == gammaValue));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,enabled,method,shadowClip,highlightClip,targetMedian,linkedChannels,gammaValue);

@override
String toString() {
  return 'AutoStretchSettings(enabled: $enabled, method: $method, shadowClip: $shadowClip, highlightClip: $highlightClip, targetMedian: $targetMedian, linkedChannels: $linkedChannels, gammaValue: $gammaValue)';
}


}

/// @nodoc
abstract mixin class $AutoStretchSettingsCopyWith<$Res>  {
  factory $AutoStretchSettingsCopyWith(AutoStretchSettings value, $Res Function(AutoStretchSettings) _then) = _$AutoStretchSettingsCopyWithImpl;
@useResult
$Res call({
 bool enabled, AutoStretchMethod method, double shadowClip, double highlightClip, double targetMedian, bool linkedChannels, double gammaValue
});




}
/// @nodoc
class _$AutoStretchSettingsCopyWithImpl<$Res>
    implements $AutoStretchSettingsCopyWith<$Res> {
  _$AutoStretchSettingsCopyWithImpl(this._self, this._then);

  final AutoStretchSettings _self;
  final $Res Function(AutoStretchSettings) _then;

/// Create a copy of AutoStretchSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? enabled = null,Object? method = null,Object? shadowClip = null,Object? highlightClip = null,Object? targetMedian = null,Object? linkedChannels = null,Object? gammaValue = null,}) {
  return _then(_self.copyWith(
enabled: null == enabled ? _self.enabled : enabled // ignore: cast_nullable_to_non_nullable
as bool,method: null == method ? _self.method : method // ignore: cast_nullable_to_non_nullable
as AutoStretchMethod,shadowClip: null == shadowClip ? _self.shadowClip : shadowClip // ignore: cast_nullable_to_non_nullable
as double,highlightClip: null == highlightClip ? _self.highlightClip : highlightClip // ignore: cast_nullable_to_non_nullable
as double,targetMedian: null == targetMedian ? _self.targetMedian : targetMedian // ignore: cast_nullable_to_non_nullable
as double,linkedChannels: null == linkedChannels ? _self.linkedChannels : linkedChannels // ignore: cast_nullable_to_non_nullable
as bool,gammaValue: null == gammaValue ? _self.gammaValue : gammaValue // ignore: cast_nullable_to_non_nullable
as double,
  ));
}

}


/// Adds pattern-matching-related methods to [AutoStretchSettings].
extension AutoStretchSettingsPatterns on AutoStretchSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AutoStretchSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AutoStretchSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AutoStretchSettings value)  $default,){
final _that = this;
switch (_that) {
case _AutoStretchSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AutoStretchSettings value)?  $default,){
final _that = this;
switch (_that) {
case _AutoStretchSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool enabled,  AutoStretchMethod method,  double shadowClip,  double highlightClip,  double targetMedian,  bool linkedChannels,  double gammaValue)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AutoStretchSettings() when $default != null:
return $default(_that.enabled,_that.method,_that.shadowClip,_that.highlightClip,_that.targetMedian,_that.linkedChannels,_that.gammaValue);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool enabled,  AutoStretchMethod method,  double shadowClip,  double highlightClip,  double targetMedian,  bool linkedChannels,  double gammaValue)  $default,) {final _that = this;
switch (_that) {
case _AutoStretchSettings():
return $default(_that.enabled,_that.method,_that.shadowClip,_that.highlightClip,_that.targetMedian,_that.linkedChannels,_that.gammaValue);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool enabled,  AutoStretchMethod method,  double shadowClip,  double highlightClip,  double targetMedian,  bool linkedChannels,  double gammaValue)?  $default,) {final _that = this;
switch (_that) {
case _AutoStretchSettings() when $default != null:
return $default(_that.enabled,_that.method,_that.shadowClip,_that.highlightClip,_that.targetMedian,_that.linkedChannels,_that.gammaValue);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AutoStretchSettings extends AutoStretchSettings {
  const _AutoStretchSettings({this.enabled = false, this.method = AutoStretchMethod.stf, this.shadowClip = -2.8, this.highlightClip = -0.5, this.targetMedian = 0.25, this.linkedChannels = true, this.gammaValue = 2.2}): super._();
  factory _AutoStretchSettings.fromJson(Map<String, dynamic> json) => _$AutoStretchSettingsFromJson(json);

/// Whether auto-stretch is enabled for image display.
@override@JsonKey() final  bool enabled;
/// The stretch method to use.
@override@JsonKey() final  AutoStretchMethod method;
/// Shadow clipping parameter (in standard deviations from median).
/// Lower (more negative) values clip more shadows.
/// Typical range: -4.0 to -1.0. Default -2.8 is standard for STF.
@override@JsonKey() final  double shadowClip;
/// Highlight clipping parameter (in standard deviations from median).
/// Lower (more negative) values clip more highlights.
/// Typical range: -1.0 to 0.0. Default -0.5 protects highlights.
@override@JsonKey() final  double highlightClip;
/// Target median level for the stretched image (0.0 to 1.0).
/// Higher values produce brighter midtones.
/// Default 0.25 places the median in the lower quarter for natural appearance.
@override@JsonKey() final  double targetMedian;
/// Whether to link RGB channels during stretch calculation.
/// When true, uses the same stretch parameters for all channels to preserve
/// color balance. When false, each channel is stretched independently.
@override@JsonKey() final  bool linkedChannels;
/// Gamma value for gamma correction method.
/// Only used when [method] is [AutoStretchMethod.gamma].
/// Standard display gamma is 2.2. Lower values brighten, higher values darken.
@override@JsonKey() final  double gammaValue;

/// Create a copy of AutoStretchSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AutoStretchSettingsCopyWith<_AutoStretchSettings> get copyWith => __$AutoStretchSettingsCopyWithImpl<_AutoStretchSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AutoStretchSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AutoStretchSettings&&(identical(other.enabled, enabled) || other.enabled == enabled)&&(identical(other.method, method) || other.method == method)&&(identical(other.shadowClip, shadowClip) || other.shadowClip == shadowClip)&&(identical(other.highlightClip, highlightClip) || other.highlightClip == highlightClip)&&(identical(other.targetMedian, targetMedian) || other.targetMedian == targetMedian)&&(identical(other.linkedChannels, linkedChannels) || other.linkedChannels == linkedChannels)&&(identical(other.gammaValue, gammaValue) || other.gammaValue == gammaValue));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,enabled,method,shadowClip,highlightClip,targetMedian,linkedChannels,gammaValue);

@override
String toString() {
  return 'AutoStretchSettings(enabled: $enabled, method: $method, shadowClip: $shadowClip, highlightClip: $highlightClip, targetMedian: $targetMedian, linkedChannels: $linkedChannels, gammaValue: $gammaValue)';
}


}

/// @nodoc
abstract mixin class _$AutoStretchSettingsCopyWith<$Res> implements $AutoStretchSettingsCopyWith<$Res> {
  factory _$AutoStretchSettingsCopyWith(_AutoStretchSettings value, $Res Function(_AutoStretchSettings) _then) = __$AutoStretchSettingsCopyWithImpl;
@override @useResult
$Res call({
 bool enabled, AutoStretchMethod method, double shadowClip, double highlightClip, double targetMedian, bool linkedChannels, double gammaValue
});




}
/// @nodoc
class __$AutoStretchSettingsCopyWithImpl<$Res>
    implements _$AutoStretchSettingsCopyWith<$Res> {
  __$AutoStretchSettingsCopyWithImpl(this._self, this._then);

  final _AutoStretchSettings _self;
  final $Res Function(_AutoStretchSettings) _then;

/// Create a copy of AutoStretchSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? enabled = null,Object? method = null,Object? shadowClip = null,Object? highlightClip = null,Object? targetMedian = null,Object? linkedChannels = null,Object? gammaValue = null,}) {
  return _then(_AutoStretchSettings(
enabled: null == enabled ? _self.enabled : enabled // ignore: cast_nullable_to_non_nullable
as bool,method: null == method ? _self.method : method // ignore: cast_nullable_to_non_nullable
as AutoStretchMethod,shadowClip: null == shadowClip ? _self.shadowClip : shadowClip // ignore: cast_nullable_to_non_nullable
as double,highlightClip: null == highlightClip ? _self.highlightClip : highlightClip // ignore: cast_nullable_to_non_nullable
as double,targetMedian: null == targetMedian ? _self.targetMedian : targetMedian // ignore: cast_nullable_to_non_nullable
as double,linkedChannels: null == linkedChannels ? _self.linkedChannels : linkedChannels // ignore: cast_nullable_to_non_nullable
as bool,gammaValue: null == gammaValue ? _self.gammaValue : gammaValue // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

// dart format on
