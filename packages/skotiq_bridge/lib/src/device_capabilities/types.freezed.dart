// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'types.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$DeviceCapabilities {

 Object get field0;



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DeviceCapabilities&&const DeepCollectionEquality().equals(other.field0, field0));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(field0));

@override
String toString() {
  return 'DeviceCapabilities(field0: $field0)';
}


}

/// @nodoc
class $DeviceCapabilitiesCopyWith<$Res>  {
$DeviceCapabilitiesCopyWith(DeviceCapabilities _, $Res Function(DeviceCapabilities) __);
}


/// Adds pattern-matching-related methods to [DeviceCapabilities].
extension DeviceCapabilitiesPatterns on DeviceCapabilities {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( DeviceCapabilities_Mount value)?  mount,TResult Function( DeviceCapabilities_Camera value)?  camera,TResult Function( DeviceCapabilities_Focuser value)?  focuser,TResult Function( DeviceCapabilities_FilterWheel value)?  filterWheel,TResult Function( DeviceCapabilities_Rotator value)?  rotator,TResult Function( DeviceCapabilities_Dome value)?  dome,TResult Function( DeviceCapabilities_CoverCalibrator value)?  coverCalibrator,TResult Function( DeviceCapabilities_Weather value)?  weather,TResult Function( DeviceCapabilities_SafetyMonitor value)?  safetyMonitor,TResult Function( DeviceCapabilities_Switch value)?  switch_,required TResult orElse(),}){
final _that = this;
switch (_that) {
case DeviceCapabilities_Mount() when mount != null:
return mount(_that);case DeviceCapabilities_Camera() when camera != null:
return camera(_that);case DeviceCapabilities_Focuser() when focuser != null:
return focuser(_that);case DeviceCapabilities_FilterWheel() when filterWheel != null:
return filterWheel(_that);case DeviceCapabilities_Rotator() when rotator != null:
return rotator(_that);case DeviceCapabilities_Dome() when dome != null:
return dome(_that);case DeviceCapabilities_CoverCalibrator() when coverCalibrator != null:
return coverCalibrator(_that);case DeviceCapabilities_Weather() when weather != null:
return weather(_that);case DeviceCapabilities_SafetyMonitor() when safetyMonitor != null:
return safetyMonitor(_that);case DeviceCapabilities_Switch() when switch_ != null:
return switch_(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( DeviceCapabilities_Mount value)  mount,required TResult Function( DeviceCapabilities_Camera value)  camera,required TResult Function( DeviceCapabilities_Focuser value)  focuser,required TResult Function( DeviceCapabilities_FilterWheel value)  filterWheel,required TResult Function( DeviceCapabilities_Rotator value)  rotator,required TResult Function( DeviceCapabilities_Dome value)  dome,required TResult Function( DeviceCapabilities_CoverCalibrator value)  coverCalibrator,required TResult Function( DeviceCapabilities_Weather value)  weather,required TResult Function( DeviceCapabilities_SafetyMonitor value)  safetyMonitor,required TResult Function( DeviceCapabilities_Switch value)  switch_,}){
final _that = this;
switch (_that) {
case DeviceCapabilities_Mount():
return mount(_that);case DeviceCapabilities_Camera():
return camera(_that);case DeviceCapabilities_Focuser():
return focuser(_that);case DeviceCapabilities_FilterWheel():
return filterWheel(_that);case DeviceCapabilities_Rotator():
return rotator(_that);case DeviceCapabilities_Dome():
return dome(_that);case DeviceCapabilities_CoverCalibrator():
return coverCalibrator(_that);case DeviceCapabilities_Weather():
return weather(_that);case DeviceCapabilities_SafetyMonitor():
return safetyMonitor(_that);case DeviceCapabilities_Switch():
return switch_(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( DeviceCapabilities_Mount value)?  mount,TResult? Function( DeviceCapabilities_Camera value)?  camera,TResult? Function( DeviceCapabilities_Focuser value)?  focuser,TResult? Function( DeviceCapabilities_FilterWheel value)?  filterWheel,TResult? Function( DeviceCapabilities_Rotator value)?  rotator,TResult? Function( DeviceCapabilities_Dome value)?  dome,TResult? Function( DeviceCapabilities_CoverCalibrator value)?  coverCalibrator,TResult? Function( DeviceCapabilities_Weather value)?  weather,TResult? Function( DeviceCapabilities_SafetyMonitor value)?  safetyMonitor,TResult? Function( DeviceCapabilities_Switch value)?  switch_,}){
final _that = this;
switch (_that) {
case DeviceCapabilities_Mount() when mount != null:
return mount(_that);case DeviceCapabilities_Camera() when camera != null:
return camera(_that);case DeviceCapabilities_Focuser() when focuser != null:
return focuser(_that);case DeviceCapabilities_FilterWheel() when filterWheel != null:
return filterWheel(_that);case DeviceCapabilities_Rotator() when rotator != null:
return rotator(_that);case DeviceCapabilities_Dome() when dome != null:
return dome(_that);case DeviceCapabilities_CoverCalibrator() when coverCalibrator != null:
return coverCalibrator(_that);case DeviceCapabilities_Weather() when weather != null:
return weather(_that);case DeviceCapabilities_SafetyMonitor() when safetyMonitor != null:
return safetyMonitor(_that);case DeviceCapabilities_Switch() when switch_ != null:
return switch_(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( MountCapabilities field0)?  mount,TResult Function( CameraCapabilities field0)?  camera,TResult Function( FocuserCapabilities field0)?  focuser,TResult Function( FilterWheelCapabilities field0)?  filterWheel,TResult Function( RotatorCapabilities field0)?  rotator,TResult Function( DomeCapabilities field0)?  dome,TResult Function( CoverCalibratorCapabilities field0)?  coverCalibrator,TResult Function( WeatherCapabilities field0)?  weather,TResult Function( SafetyMonitorCapabilities field0)?  safetyMonitor,TResult Function( SwitchCapabilities field0)?  switch_,required TResult orElse(),}) {final _that = this;
switch (_that) {
case DeviceCapabilities_Mount() when mount != null:
return mount(_that.field0);case DeviceCapabilities_Camera() when camera != null:
return camera(_that.field0);case DeviceCapabilities_Focuser() when focuser != null:
return focuser(_that.field0);case DeviceCapabilities_FilterWheel() when filterWheel != null:
return filterWheel(_that.field0);case DeviceCapabilities_Rotator() when rotator != null:
return rotator(_that.field0);case DeviceCapabilities_Dome() when dome != null:
return dome(_that.field0);case DeviceCapabilities_CoverCalibrator() when coverCalibrator != null:
return coverCalibrator(_that.field0);case DeviceCapabilities_Weather() when weather != null:
return weather(_that.field0);case DeviceCapabilities_SafetyMonitor() when safetyMonitor != null:
return safetyMonitor(_that.field0);case DeviceCapabilities_Switch() when switch_ != null:
return switch_(_that.field0);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( MountCapabilities field0)  mount,required TResult Function( CameraCapabilities field0)  camera,required TResult Function( FocuserCapabilities field0)  focuser,required TResult Function( FilterWheelCapabilities field0)  filterWheel,required TResult Function( RotatorCapabilities field0)  rotator,required TResult Function( DomeCapabilities field0)  dome,required TResult Function( CoverCalibratorCapabilities field0)  coverCalibrator,required TResult Function( WeatherCapabilities field0)  weather,required TResult Function( SafetyMonitorCapabilities field0)  safetyMonitor,required TResult Function( SwitchCapabilities field0)  switch_,}) {final _that = this;
switch (_that) {
case DeviceCapabilities_Mount():
return mount(_that.field0);case DeviceCapabilities_Camera():
return camera(_that.field0);case DeviceCapabilities_Focuser():
return focuser(_that.field0);case DeviceCapabilities_FilterWheel():
return filterWheel(_that.field0);case DeviceCapabilities_Rotator():
return rotator(_that.field0);case DeviceCapabilities_Dome():
return dome(_that.field0);case DeviceCapabilities_CoverCalibrator():
return coverCalibrator(_that.field0);case DeviceCapabilities_Weather():
return weather(_that.field0);case DeviceCapabilities_SafetyMonitor():
return safetyMonitor(_that.field0);case DeviceCapabilities_Switch():
return switch_(_that.field0);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( MountCapabilities field0)?  mount,TResult? Function( CameraCapabilities field0)?  camera,TResult? Function( FocuserCapabilities field0)?  focuser,TResult? Function( FilterWheelCapabilities field0)?  filterWheel,TResult? Function( RotatorCapabilities field0)?  rotator,TResult? Function( DomeCapabilities field0)?  dome,TResult? Function( CoverCalibratorCapabilities field0)?  coverCalibrator,TResult? Function( WeatherCapabilities field0)?  weather,TResult? Function( SafetyMonitorCapabilities field0)?  safetyMonitor,TResult? Function( SwitchCapabilities field0)?  switch_,}) {final _that = this;
switch (_that) {
case DeviceCapabilities_Mount() when mount != null:
return mount(_that.field0);case DeviceCapabilities_Camera() when camera != null:
return camera(_that.field0);case DeviceCapabilities_Focuser() when focuser != null:
return focuser(_that.field0);case DeviceCapabilities_FilterWheel() when filterWheel != null:
return filterWheel(_that.field0);case DeviceCapabilities_Rotator() when rotator != null:
return rotator(_that.field0);case DeviceCapabilities_Dome() when dome != null:
return dome(_that.field0);case DeviceCapabilities_CoverCalibrator() when coverCalibrator != null:
return coverCalibrator(_that.field0);case DeviceCapabilities_Weather() when weather != null:
return weather(_that.field0);case DeviceCapabilities_SafetyMonitor() when safetyMonitor != null:
return safetyMonitor(_that.field0);case DeviceCapabilities_Switch() when switch_ != null:
return switch_(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class DeviceCapabilities_Mount extends DeviceCapabilities {
  const DeviceCapabilities_Mount(this.field0): super._();
  

@override final  MountCapabilities field0;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DeviceCapabilities_MountCopyWith<DeviceCapabilities_Mount> get copyWith => _$DeviceCapabilities_MountCopyWithImpl<DeviceCapabilities_Mount>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DeviceCapabilities_Mount&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'DeviceCapabilities.mount(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $DeviceCapabilities_MountCopyWith<$Res> implements $DeviceCapabilitiesCopyWith<$Res> {
  factory $DeviceCapabilities_MountCopyWith(DeviceCapabilities_Mount value, $Res Function(DeviceCapabilities_Mount) _then) = _$DeviceCapabilities_MountCopyWithImpl;
@useResult
$Res call({
 MountCapabilities field0
});




}
/// @nodoc
class _$DeviceCapabilities_MountCopyWithImpl<$Res>
    implements $DeviceCapabilities_MountCopyWith<$Res> {
  _$DeviceCapabilities_MountCopyWithImpl(this._self, this._then);

  final DeviceCapabilities_Mount _self;
  final $Res Function(DeviceCapabilities_Mount) _then;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(DeviceCapabilities_Mount(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as MountCapabilities,
  ));
}


}

/// @nodoc


class DeviceCapabilities_Camera extends DeviceCapabilities {
  const DeviceCapabilities_Camera(this.field0): super._();
  

@override final  CameraCapabilities field0;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DeviceCapabilities_CameraCopyWith<DeviceCapabilities_Camera> get copyWith => _$DeviceCapabilities_CameraCopyWithImpl<DeviceCapabilities_Camera>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DeviceCapabilities_Camera&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'DeviceCapabilities.camera(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $DeviceCapabilities_CameraCopyWith<$Res> implements $DeviceCapabilitiesCopyWith<$Res> {
  factory $DeviceCapabilities_CameraCopyWith(DeviceCapabilities_Camera value, $Res Function(DeviceCapabilities_Camera) _then) = _$DeviceCapabilities_CameraCopyWithImpl;
@useResult
$Res call({
 CameraCapabilities field0
});




}
/// @nodoc
class _$DeviceCapabilities_CameraCopyWithImpl<$Res>
    implements $DeviceCapabilities_CameraCopyWith<$Res> {
  _$DeviceCapabilities_CameraCopyWithImpl(this._self, this._then);

  final DeviceCapabilities_Camera _self;
  final $Res Function(DeviceCapabilities_Camera) _then;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(DeviceCapabilities_Camera(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as CameraCapabilities,
  ));
}


}

/// @nodoc


class DeviceCapabilities_Focuser extends DeviceCapabilities {
  const DeviceCapabilities_Focuser(this.field0): super._();
  

@override final  FocuserCapabilities field0;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DeviceCapabilities_FocuserCopyWith<DeviceCapabilities_Focuser> get copyWith => _$DeviceCapabilities_FocuserCopyWithImpl<DeviceCapabilities_Focuser>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DeviceCapabilities_Focuser&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'DeviceCapabilities.focuser(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $DeviceCapabilities_FocuserCopyWith<$Res> implements $DeviceCapabilitiesCopyWith<$Res> {
  factory $DeviceCapabilities_FocuserCopyWith(DeviceCapabilities_Focuser value, $Res Function(DeviceCapabilities_Focuser) _then) = _$DeviceCapabilities_FocuserCopyWithImpl;
@useResult
$Res call({
 FocuserCapabilities field0
});




}
/// @nodoc
class _$DeviceCapabilities_FocuserCopyWithImpl<$Res>
    implements $DeviceCapabilities_FocuserCopyWith<$Res> {
  _$DeviceCapabilities_FocuserCopyWithImpl(this._self, this._then);

  final DeviceCapabilities_Focuser _self;
  final $Res Function(DeviceCapabilities_Focuser) _then;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(DeviceCapabilities_Focuser(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as FocuserCapabilities,
  ));
}


}

/// @nodoc


class DeviceCapabilities_FilterWheel extends DeviceCapabilities {
  const DeviceCapabilities_FilterWheel(this.field0): super._();
  

@override final  FilterWheelCapabilities field0;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DeviceCapabilities_FilterWheelCopyWith<DeviceCapabilities_FilterWheel> get copyWith => _$DeviceCapabilities_FilterWheelCopyWithImpl<DeviceCapabilities_FilterWheel>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DeviceCapabilities_FilterWheel&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'DeviceCapabilities.filterWheel(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $DeviceCapabilities_FilterWheelCopyWith<$Res> implements $DeviceCapabilitiesCopyWith<$Res> {
  factory $DeviceCapabilities_FilterWheelCopyWith(DeviceCapabilities_FilterWheel value, $Res Function(DeviceCapabilities_FilterWheel) _then) = _$DeviceCapabilities_FilterWheelCopyWithImpl;
@useResult
$Res call({
 FilterWheelCapabilities field0
});




}
/// @nodoc
class _$DeviceCapabilities_FilterWheelCopyWithImpl<$Res>
    implements $DeviceCapabilities_FilterWheelCopyWith<$Res> {
  _$DeviceCapabilities_FilterWheelCopyWithImpl(this._self, this._then);

  final DeviceCapabilities_FilterWheel _self;
  final $Res Function(DeviceCapabilities_FilterWheel) _then;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(DeviceCapabilities_FilterWheel(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as FilterWheelCapabilities,
  ));
}


}

/// @nodoc


class DeviceCapabilities_Rotator extends DeviceCapabilities {
  const DeviceCapabilities_Rotator(this.field0): super._();
  

@override final  RotatorCapabilities field0;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DeviceCapabilities_RotatorCopyWith<DeviceCapabilities_Rotator> get copyWith => _$DeviceCapabilities_RotatorCopyWithImpl<DeviceCapabilities_Rotator>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DeviceCapabilities_Rotator&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'DeviceCapabilities.rotator(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $DeviceCapabilities_RotatorCopyWith<$Res> implements $DeviceCapabilitiesCopyWith<$Res> {
  factory $DeviceCapabilities_RotatorCopyWith(DeviceCapabilities_Rotator value, $Res Function(DeviceCapabilities_Rotator) _then) = _$DeviceCapabilities_RotatorCopyWithImpl;
@useResult
$Res call({
 RotatorCapabilities field0
});




}
/// @nodoc
class _$DeviceCapabilities_RotatorCopyWithImpl<$Res>
    implements $DeviceCapabilities_RotatorCopyWith<$Res> {
  _$DeviceCapabilities_RotatorCopyWithImpl(this._self, this._then);

  final DeviceCapabilities_Rotator _self;
  final $Res Function(DeviceCapabilities_Rotator) _then;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(DeviceCapabilities_Rotator(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as RotatorCapabilities,
  ));
}


}

/// @nodoc


class DeviceCapabilities_Dome extends DeviceCapabilities {
  const DeviceCapabilities_Dome(this.field0): super._();
  

@override final  DomeCapabilities field0;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DeviceCapabilities_DomeCopyWith<DeviceCapabilities_Dome> get copyWith => _$DeviceCapabilities_DomeCopyWithImpl<DeviceCapabilities_Dome>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DeviceCapabilities_Dome&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'DeviceCapabilities.dome(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $DeviceCapabilities_DomeCopyWith<$Res> implements $DeviceCapabilitiesCopyWith<$Res> {
  factory $DeviceCapabilities_DomeCopyWith(DeviceCapabilities_Dome value, $Res Function(DeviceCapabilities_Dome) _then) = _$DeviceCapabilities_DomeCopyWithImpl;
@useResult
$Res call({
 DomeCapabilities field0
});




}
/// @nodoc
class _$DeviceCapabilities_DomeCopyWithImpl<$Res>
    implements $DeviceCapabilities_DomeCopyWith<$Res> {
  _$DeviceCapabilities_DomeCopyWithImpl(this._self, this._then);

  final DeviceCapabilities_Dome _self;
  final $Res Function(DeviceCapabilities_Dome) _then;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(DeviceCapabilities_Dome(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as DomeCapabilities,
  ));
}


}

/// @nodoc


class DeviceCapabilities_CoverCalibrator extends DeviceCapabilities {
  const DeviceCapabilities_CoverCalibrator(this.field0): super._();
  

@override final  CoverCalibratorCapabilities field0;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DeviceCapabilities_CoverCalibratorCopyWith<DeviceCapabilities_CoverCalibrator> get copyWith => _$DeviceCapabilities_CoverCalibratorCopyWithImpl<DeviceCapabilities_CoverCalibrator>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DeviceCapabilities_CoverCalibrator&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'DeviceCapabilities.coverCalibrator(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $DeviceCapabilities_CoverCalibratorCopyWith<$Res> implements $DeviceCapabilitiesCopyWith<$Res> {
  factory $DeviceCapabilities_CoverCalibratorCopyWith(DeviceCapabilities_CoverCalibrator value, $Res Function(DeviceCapabilities_CoverCalibrator) _then) = _$DeviceCapabilities_CoverCalibratorCopyWithImpl;
@useResult
$Res call({
 CoverCalibratorCapabilities field0
});




}
/// @nodoc
class _$DeviceCapabilities_CoverCalibratorCopyWithImpl<$Res>
    implements $DeviceCapabilities_CoverCalibratorCopyWith<$Res> {
  _$DeviceCapabilities_CoverCalibratorCopyWithImpl(this._self, this._then);

  final DeviceCapabilities_CoverCalibrator _self;
  final $Res Function(DeviceCapabilities_CoverCalibrator) _then;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(DeviceCapabilities_CoverCalibrator(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as CoverCalibratorCapabilities,
  ));
}


}

/// @nodoc


class DeviceCapabilities_Weather extends DeviceCapabilities {
  const DeviceCapabilities_Weather(this.field0): super._();
  

@override final  WeatherCapabilities field0;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DeviceCapabilities_WeatherCopyWith<DeviceCapabilities_Weather> get copyWith => _$DeviceCapabilities_WeatherCopyWithImpl<DeviceCapabilities_Weather>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DeviceCapabilities_Weather&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'DeviceCapabilities.weather(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $DeviceCapabilities_WeatherCopyWith<$Res> implements $DeviceCapabilitiesCopyWith<$Res> {
  factory $DeviceCapabilities_WeatherCopyWith(DeviceCapabilities_Weather value, $Res Function(DeviceCapabilities_Weather) _then) = _$DeviceCapabilities_WeatherCopyWithImpl;
@useResult
$Res call({
 WeatherCapabilities field0
});




}
/// @nodoc
class _$DeviceCapabilities_WeatherCopyWithImpl<$Res>
    implements $DeviceCapabilities_WeatherCopyWith<$Res> {
  _$DeviceCapabilities_WeatherCopyWithImpl(this._self, this._then);

  final DeviceCapabilities_Weather _self;
  final $Res Function(DeviceCapabilities_Weather) _then;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(DeviceCapabilities_Weather(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as WeatherCapabilities,
  ));
}


}

/// @nodoc


class DeviceCapabilities_SafetyMonitor extends DeviceCapabilities {
  const DeviceCapabilities_SafetyMonitor(this.field0): super._();
  

@override final  SafetyMonitorCapabilities field0;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DeviceCapabilities_SafetyMonitorCopyWith<DeviceCapabilities_SafetyMonitor> get copyWith => _$DeviceCapabilities_SafetyMonitorCopyWithImpl<DeviceCapabilities_SafetyMonitor>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DeviceCapabilities_SafetyMonitor&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'DeviceCapabilities.safetyMonitor(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $DeviceCapabilities_SafetyMonitorCopyWith<$Res> implements $DeviceCapabilitiesCopyWith<$Res> {
  factory $DeviceCapabilities_SafetyMonitorCopyWith(DeviceCapabilities_SafetyMonitor value, $Res Function(DeviceCapabilities_SafetyMonitor) _then) = _$DeviceCapabilities_SafetyMonitorCopyWithImpl;
@useResult
$Res call({
 SafetyMonitorCapabilities field0
});




}
/// @nodoc
class _$DeviceCapabilities_SafetyMonitorCopyWithImpl<$Res>
    implements $DeviceCapabilities_SafetyMonitorCopyWith<$Res> {
  _$DeviceCapabilities_SafetyMonitorCopyWithImpl(this._self, this._then);

  final DeviceCapabilities_SafetyMonitor _self;
  final $Res Function(DeviceCapabilities_SafetyMonitor) _then;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(DeviceCapabilities_SafetyMonitor(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as SafetyMonitorCapabilities,
  ));
}


}

/// @nodoc


class DeviceCapabilities_Switch extends DeviceCapabilities {
  const DeviceCapabilities_Switch(this.field0): super._();
  

@override final  SwitchCapabilities field0;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DeviceCapabilities_SwitchCopyWith<DeviceCapabilities_Switch> get copyWith => _$DeviceCapabilities_SwitchCopyWithImpl<DeviceCapabilities_Switch>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DeviceCapabilities_Switch&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'DeviceCapabilities.switch_(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $DeviceCapabilities_SwitchCopyWith<$Res> implements $DeviceCapabilitiesCopyWith<$Res> {
  factory $DeviceCapabilities_SwitchCopyWith(DeviceCapabilities_Switch value, $Res Function(DeviceCapabilities_Switch) _then) = _$DeviceCapabilities_SwitchCopyWithImpl;
@useResult
$Res call({
 SwitchCapabilities field0
});




}
/// @nodoc
class _$DeviceCapabilities_SwitchCopyWithImpl<$Res>
    implements $DeviceCapabilities_SwitchCopyWith<$Res> {
  _$DeviceCapabilities_SwitchCopyWithImpl(this._self, this._then);

  final DeviceCapabilities_Switch _self;
  final $Res Function(DeviceCapabilities_Switch) _then;

/// Create a copy of DeviceCapabilities
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(DeviceCapabilities_Switch(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as SwitchCapabilities,
  ));
}


}

// dart format on
