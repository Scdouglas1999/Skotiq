// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'equipment.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$EquipmentEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EquipmentEvent()';
}


}

/// @nodoc
class $EquipmentEventCopyWith<$Res>  {
$EquipmentEventCopyWith(EquipmentEvent _, $Res Function(EquipmentEvent) __);
}


/// Adds pattern-matching-related methods to [EquipmentEvent].
extension EquipmentEventPatterns on EquipmentEvent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( EquipmentEvent_Connecting value)?  connecting,TResult Function( EquipmentEvent_Connected value)?  connected,TResult Function( EquipmentEvent_Disconnected value)?  disconnected,TResult Function( EquipmentEvent_PropertyChanged value)?  propertyChanged,TResult Function( EquipmentEvent_Error value)?  error,TResult Function( EquipmentEvent_MountSlewStarted value)?  mountSlewStarted,TResult Function( EquipmentEvent_MountSlewCompleted value)?  mountSlewCompleted,TResult Function( EquipmentEvent_MountTrackingStarted value)?  mountTrackingStarted,TResult Function( EquipmentEvent_MountTrackingStopped value)?  mountTrackingStopped,TResult Function( EquipmentEvent_MountParkStarted value)?  mountParkStarted,TResult Function( EquipmentEvent_MountParkCompleted value)?  mountParkCompleted,TResult Function( EquipmentEvent_MountUnparked value)?  mountUnparked,TResult Function( EquipmentEvent_FocuserMoveStarted value)?  focuserMoveStarted,TResult Function( EquipmentEvent_FocuserMoveCompleted value)?  focuserMoveCompleted,TResult Function( EquipmentEvent_FocuserTemperatureChanged value)?  focuserTemperatureChanged,TResult Function( EquipmentEvent_FilterChanging value)?  filterChanging,TResult Function( EquipmentEvent_FilterChanged value)?  filterChanged,TResult Function( EquipmentEvent_RotatorMoveStarted value)?  rotatorMoveStarted,TResult Function( EquipmentEvent_RotatorMoveCompleted value)?  rotatorMoveCompleted,TResult Function( EquipmentEvent_CameraCoolingStarted value)?  cameraCoolingStarted,TResult Function( EquipmentEvent_CameraCoolingReached value)?  cameraCoolingReached,TResult Function( EquipmentEvent_CameraWarmingStarted value)?  cameraWarmingStarted,TResult Function( EquipmentEvent_CameraWarmingCompleted value)?  cameraWarmingCompleted,TResult Function( EquipmentEvent_HeartbeatStarted value)?  heartbeatStarted,TResult Function( EquipmentEvent_HeartbeatStopped value)?  heartbeatStopped,TResult Function( EquipmentEvent_HeartbeatStatusChanged value)?  heartbeatStatusChanged,TResult Function( EquipmentEvent_HeartbeatReconnecting value)?  heartbeatReconnecting,TResult Function( EquipmentEvent_HeartbeatReconnected value)?  heartbeatReconnected,TResult Function( EquipmentEvent_DeviceDiscovered value)?  deviceDiscovered,TResult Function( EquipmentEvent_DeviceLost value)?  deviceLost,required TResult orElse(),}){
final _that = this;
switch (_that) {
case EquipmentEvent_Connecting() when connecting != null:
return connecting(_that);case EquipmentEvent_Connected() when connected != null:
return connected(_that);case EquipmentEvent_Disconnected() when disconnected != null:
return disconnected(_that);case EquipmentEvent_PropertyChanged() when propertyChanged != null:
return propertyChanged(_that);case EquipmentEvent_Error() when error != null:
return error(_that);case EquipmentEvent_MountSlewStarted() when mountSlewStarted != null:
return mountSlewStarted(_that);case EquipmentEvent_MountSlewCompleted() when mountSlewCompleted != null:
return mountSlewCompleted(_that);case EquipmentEvent_MountTrackingStarted() when mountTrackingStarted != null:
return mountTrackingStarted(_that);case EquipmentEvent_MountTrackingStopped() when mountTrackingStopped != null:
return mountTrackingStopped(_that);case EquipmentEvent_MountParkStarted() when mountParkStarted != null:
return mountParkStarted(_that);case EquipmentEvent_MountParkCompleted() when mountParkCompleted != null:
return mountParkCompleted(_that);case EquipmentEvent_MountUnparked() when mountUnparked != null:
return mountUnparked(_that);case EquipmentEvent_FocuserMoveStarted() when focuserMoveStarted != null:
return focuserMoveStarted(_that);case EquipmentEvent_FocuserMoveCompleted() when focuserMoveCompleted != null:
return focuserMoveCompleted(_that);case EquipmentEvent_FocuserTemperatureChanged() when focuserTemperatureChanged != null:
return focuserTemperatureChanged(_that);case EquipmentEvent_FilterChanging() when filterChanging != null:
return filterChanging(_that);case EquipmentEvent_FilterChanged() when filterChanged != null:
return filterChanged(_that);case EquipmentEvent_RotatorMoveStarted() when rotatorMoveStarted != null:
return rotatorMoveStarted(_that);case EquipmentEvent_RotatorMoveCompleted() when rotatorMoveCompleted != null:
return rotatorMoveCompleted(_that);case EquipmentEvent_CameraCoolingStarted() when cameraCoolingStarted != null:
return cameraCoolingStarted(_that);case EquipmentEvent_CameraCoolingReached() when cameraCoolingReached != null:
return cameraCoolingReached(_that);case EquipmentEvent_CameraWarmingStarted() when cameraWarmingStarted != null:
return cameraWarmingStarted(_that);case EquipmentEvent_CameraWarmingCompleted() when cameraWarmingCompleted != null:
return cameraWarmingCompleted(_that);case EquipmentEvent_HeartbeatStarted() when heartbeatStarted != null:
return heartbeatStarted(_that);case EquipmentEvent_HeartbeatStopped() when heartbeatStopped != null:
return heartbeatStopped(_that);case EquipmentEvent_HeartbeatStatusChanged() when heartbeatStatusChanged != null:
return heartbeatStatusChanged(_that);case EquipmentEvent_HeartbeatReconnecting() when heartbeatReconnecting != null:
return heartbeatReconnecting(_that);case EquipmentEvent_HeartbeatReconnected() when heartbeatReconnected != null:
return heartbeatReconnected(_that);case EquipmentEvent_DeviceDiscovered() when deviceDiscovered != null:
return deviceDiscovered(_that);case EquipmentEvent_DeviceLost() when deviceLost != null:
return deviceLost(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( EquipmentEvent_Connecting value)  connecting,required TResult Function( EquipmentEvent_Connected value)  connected,required TResult Function( EquipmentEvent_Disconnected value)  disconnected,required TResult Function( EquipmentEvent_PropertyChanged value)  propertyChanged,required TResult Function( EquipmentEvent_Error value)  error,required TResult Function( EquipmentEvent_MountSlewStarted value)  mountSlewStarted,required TResult Function( EquipmentEvent_MountSlewCompleted value)  mountSlewCompleted,required TResult Function( EquipmentEvent_MountTrackingStarted value)  mountTrackingStarted,required TResult Function( EquipmentEvent_MountTrackingStopped value)  mountTrackingStopped,required TResult Function( EquipmentEvent_MountParkStarted value)  mountParkStarted,required TResult Function( EquipmentEvent_MountParkCompleted value)  mountParkCompleted,required TResult Function( EquipmentEvent_MountUnparked value)  mountUnparked,required TResult Function( EquipmentEvent_FocuserMoveStarted value)  focuserMoveStarted,required TResult Function( EquipmentEvent_FocuserMoveCompleted value)  focuserMoveCompleted,required TResult Function( EquipmentEvent_FocuserTemperatureChanged value)  focuserTemperatureChanged,required TResult Function( EquipmentEvent_FilterChanging value)  filterChanging,required TResult Function( EquipmentEvent_FilterChanged value)  filterChanged,required TResult Function( EquipmentEvent_RotatorMoveStarted value)  rotatorMoveStarted,required TResult Function( EquipmentEvent_RotatorMoveCompleted value)  rotatorMoveCompleted,required TResult Function( EquipmentEvent_CameraCoolingStarted value)  cameraCoolingStarted,required TResult Function( EquipmentEvent_CameraCoolingReached value)  cameraCoolingReached,required TResult Function( EquipmentEvent_CameraWarmingStarted value)  cameraWarmingStarted,required TResult Function( EquipmentEvent_CameraWarmingCompleted value)  cameraWarmingCompleted,required TResult Function( EquipmentEvent_HeartbeatStarted value)  heartbeatStarted,required TResult Function( EquipmentEvent_HeartbeatStopped value)  heartbeatStopped,required TResult Function( EquipmentEvent_HeartbeatStatusChanged value)  heartbeatStatusChanged,required TResult Function( EquipmentEvent_HeartbeatReconnecting value)  heartbeatReconnecting,required TResult Function( EquipmentEvent_HeartbeatReconnected value)  heartbeatReconnected,required TResult Function( EquipmentEvent_DeviceDiscovered value)  deviceDiscovered,required TResult Function( EquipmentEvent_DeviceLost value)  deviceLost,}){
final _that = this;
switch (_that) {
case EquipmentEvent_Connecting():
return connecting(_that);case EquipmentEvent_Connected():
return connected(_that);case EquipmentEvent_Disconnected():
return disconnected(_that);case EquipmentEvent_PropertyChanged():
return propertyChanged(_that);case EquipmentEvent_Error():
return error(_that);case EquipmentEvent_MountSlewStarted():
return mountSlewStarted(_that);case EquipmentEvent_MountSlewCompleted():
return mountSlewCompleted(_that);case EquipmentEvent_MountTrackingStarted():
return mountTrackingStarted(_that);case EquipmentEvent_MountTrackingStopped():
return mountTrackingStopped(_that);case EquipmentEvent_MountParkStarted():
return mountParkStarted(_that);case EquipmentEvent_MountParkCompleted():
return mountParkCompleted(_that);case EquipmentEvent_MountUnparked():
return mountUnparked(_that);case EquipmentEvent_FocuserMoveStarted():
return focuserMoveStarted(_that);case EquipmentEvent_FocuserMoveCompleted():
return focuserMoveCompleted(_that);case EquipmentEvent_FocuserTemperatureChanged():
return focuserTemperatureChanged(_that);case EquipmentEvent_FilterChanging():
return filterChanging(_that);case EquipmentEvent_FilterChanged():
return filterChanged(_that);case EquipmentEvent_RotatorMoveStarted():
return rotatorMoveStarted(_that);case EquipmentEvent_RotatorMoveCompleted():
return rotatorMoveCompleted(_that);case EquipmentEvent_CameraCoolingStarted():
return cameraCoolingStarted(_that);case EquipmentEvent_CameraCoolingReached():
return cameraCoolingReached(_that);case EquipmentEvent_CameraWarmingStarted():
return cameraWarmingStarted(_that);case EquipmentEvent_CameraWarmingCompleted():
return cameraWarmingCompleted(_that);case EquipmentEvent_HeartbeatStarted():
return heartbeatStarted(_that);case EquipmentEvent_HeartbeatStopped():
return heartbeatStopped(_that);case EquipmentEvent_HeartbeatStatusChanged():
return heartbeatStatusChanged(_that);case EquipmentEvent_HeartbeatReconnecting():
return heartbeatReconnecting(_that);case EquipmentEvent_HeartbeatReconnected():
return heartbeatReconnected(_that);case EquipmentEvent_DeviceDiscovered():
return deviceDiscovered(_that);case EquipmentEvent_DeviceLost():
return deviceLost(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( EquipmentEvent_Connecting value)?  connecting,TResult? Function( EquipmentEvent_Connected value)?  connected,TResult? Function( EquipmentEvent_Disconnected value)?  disconnected,TResult? Function( EquipmentEvent_PropertyChanged value)?  propertyChanged,TResult? Function( EquipmentEvent_Error value)?  error,TResult? Function( EquipmentEvent_MountSlewStarted value)?  mountSlewStarted,TResult? Function( EquipmentEvent_MountSlewCompleted value)?  mountSlewCompleted,TResult? Function( EquipmentEvent_MountTrackingStarted value)?  mountTrackingStarted,TResult? Function( EquipmentEvent_MountTrackingStopped value)?  mountTrackingStopped,TResult? Function( EquipmentEvent_MountParkStarted value)?  mountParkStarted,TResult? Function( EquipmentEvent_MountParkCompleted value)?  mountParkCompleted,TResult? Function( EquipmentEvent_MountUnparked value)?  mountUnparked,TResult? Function( EquipmentEvent_FocuserMoveStarted value)?  focuserMoveStarted,TResult? Function( EquipmentEvent_FocuserMoveCompleted value)?  focuserMoveCompleted,TResult? Function( EquipmentEvent_FocuserTemperatureChanged value)?  focuserTemperatureChanged,TResult? Function( EquipmentEvent_FilterChanging value)?  filterChanging,TResult? Function( EquipmentEvent_FilterChanged value)?  filterChanged,TResult? Function( EquipmentEvent_RotatorMoveStarted value)?  rotatorMoveStarted,TResult? Function( EquipmentEvent_RotatorMoveCompleted value)?  rotatorMoveCompleted,TResult? Function( EquipmentEvent_CameraCoolingStarted value)?  cameraCoolingStarted,TResult? Function( EquipmentEvent_CameraCoolingReached value)?  cameraCoolingReached,TResult? Function( EquipmentEvent_CameraWarmingStarted value)?  cameraWarmingStarted,TResult? Function( EquipmentEvent_CameraWarmingCompleted value)?  cameraWarmingCompleted,TResult? Function( EquipmentEvent_HeartbeatStarted value)?  heartbeatStarted,TResult? Function( EquipmentEvent_HeartbeatStopped value)?  heartbeatStopped,TResult? Function( EquipmentEvent_HeartbeatStatusChanged value)?  heartbeatStatusChanged,TResult? Function( EquipmentEvent_HeartbeatReconnecting value)?  heartbeatReconnecting,TResult? Function( EquipmentEvent_HeartbeatReconnected value)?  heartbeatReconnected,TResult? Function( EquipmentEvent_DeviceDiscovered value)?  deviceDiscovered,TResult? Function( EquipmentEvent_DeviceLost value)?  deviceLost,}){
final _that = this;
switch (_that) {
case EquipmentEvent_Connecting() when connecting != null:
return connecting(_that);case EquipmentEvent_Connected() when connected != null:
return connected(_that);case EquipmentEvent_Disconnected() when disconnected != null:
return disconnected(_that);case EquipmentEvent_PropertyChanged() when propertyChanged != null:
return propertyChanged(_that);case EquipmentEvent_Error() when error != null:
return error(_that);case EquipmentEvent_MountSlewStarted() when mountSlewStarted != null:
return mountSlewStarted(_that);case EquipmentEvent_MountSlewCompleted() when mountSlewCompleted != null:
return mountSlewCompleted(_that);case EquipmentEvent_MountTrackingStarted() when mountTrackingStarted != null:
return mountTrackingStarted(_that);case EquipmentEvent_MountTrackingStopped() when mountTrackingStopped != null:
return mountTrackingStopped(_that);case EquipmentEvent_MountParkStarted() when mountParkStarted != null:
return mountParkStarted(_that);case EquipmentEvent_MountParkCompleted() when mountParkCompleted != null:
return mountParkCompleted(_that);case EquipmentEvent_MountUnparked() when mountUnparked != null:
return mountUnparked(_that);case EquipmentEvent_FocuserMoveStarted() when focuserMoveStarted != null:
return focuserMoveStarted(_that);case EquipmentEvent_FocuserMoveCompleted() when focuserMoveCompleted != null:
return focuserMoveCompleted(_that);case EquipmentEvent_FocuserTemperatureChanged() when focuserTemperatureChanged != null:
return focuserTemperatureChanged(_that);case EquipmentEvent_FilterChanging() when filterChanging != null:
return filterChanging(_that);case EquipmentEvent_FilterChanged() when filterChanged != null:
return filterChanged(_that);case EquipmentEvent_RotatorMoveStarted() when rotatorMoveStarted != null:
return rotatorMoveStarted(_that);case EquipmentEvent_RotatorMoveCompleted() when rotatorMoveCompleted != null:
return rotatorMoveCompleted(_that);case EquipmentEvent_CameraCoolingStarted() when cameraCoolingStarted != null:
return cameraCoolingStarted(_that);case EquipmentEvent_CameraCoolingReached() when cameraCoolingReached != null:
return cameraCoolingReached(_that);case EquipmentEvent_CameraWarmingStarted() when cameraWarmingStarted != null:
return cameraWarmingStarted(_that);case EquipmentEvent_CameraWarmingCompleted() when cameraWarmingCompleted != null:
return cameraWarmingCompleted(_that);case EquipmentEvent_HeartbeatStarted() when heartbeatStarted != null:
return heartbeatStarted(_that);case EquipmentEvent_HeartbeatStopped() when heartbeatStopped != null:
return heartbeatStopped(_that);case EquipmentEvent_HeartbeatStatusChanged() when heartbeatStatusChanged != null:
return heartbeatStatusChanged(_that);case EquipmentEvent_HeartbeatReconnecting() when heartbeatReconnecting != null:
return heartbeatReconnecting(_that);case EquipmentEvent_HeartbeatReconnected() when heartbeatReconnected != null:
return heartbeatReconnected(_that);case EquipmentEvent_DeviceDiscovered() when deviceDiscovered != null:
return deviceDiscovered(_that);case EquipmentEvent_DeviceLost() when deviceLost != null:
return deviceLost(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String deviceType,  String deviceId)?  connecting,TResult Function( String deviceType,  String deviceId)?  connected,TResult Function( String deviceType,  String deviceId)?  disconnected,TResult Function( String deviceType,  String deviceId,  String property,  String value)?  propertyChanged,TResult Function( String deviceType,  String deviceId,  String message)?  error,TResult Function( double ra,  double dec)?  mountSlewStarted,TResult Function( double ra,  double dec)?  mountSlewCompleted,TResult Function()?  mountTrackingStarted,TResult Function()?  mountTrackingStopped,TResult Function()?  mountParkStarted,TResult Function()?  mountParkCompleted,TResult Function()?  mountUnparked,TResult Function( int targetPosition)?  focuserMoveStarted,TResult Function( int position)?  focuserMoveCompleted,TResult Function( double temperature)?  focuserTemperatureChanged,TResult Function( int fromPosition,  int toPosition,  String? filterName)?  filterChanging,TResult Function( int position,  String? filterName)?  filterChanged,TResult Function( double targetAngle)?  rotatorMoveStarted,TResult Function( double angle)?  rotatorMoveCompleted,TResult Function( double targetTemp)?  cameraCoolingStarted,TResult Function( double temperature)?  cameraCoolingReached,TResult Function()?  cameraWarmingStarted,TResult Function()?  cameraWarmingCompleted,TResult Function( String deviceType,  String deviceId,  BigInt intervalSecs)?  heartbeatStarted,TResult Function( String deviceType,  String deviceId)?  heartbeatStopped,TResult Function( String deviceType,  String deviceId,  HeartbeatStatus status,  int consecutiveFailures,  BigInt? lastRttMs)?  heartbeatStatusChanged,TResult Function( String deviceType,  String deviceId,  int attempt,  int maxAttempts)?  heartbeatReconnecting,TResult Function( String deviceType,  String deviceId,  int afterAttempts)?  heartbeatReconnected,TResult Function( String deviceClass,  String driver,  String id,  String name,  String displayName,  String? uniqueId)?  deviceDiscovered,TResult Function( String deviceClass,  String driver,  String id)?  deviceLost,required TResult orElse(),}) {final _that = this;
switch (_that) {
case EquipmentEvent_Connecting() when connecting != null:
return connecting(_that.deviceType,_that.deviceId);case EquipmentEvent_Connected() when connected != null:
return connected(_that.deviceType,_that.deviceId);case EquipmentEvent_Disconnected() when disconnected != null:
return disconnected(_that.deviceType,_that.deviceId);case EquipmentEvent_PropertyChanged() when propertyChanged != null:
return propertyChanged(_that.deviceType,_that.deviceId,_that.property,_that.value);case EquipmentEvent_Error() when error != null:
return error(_that.deviceType,_that.deviceId,_that.message);case EquipmentEvent_MountSlewStarted() when mountSlewStarted != null:
return mountSlewStarted(_that.ra,_that.dec);case EquipmentEvent_MountSlewCompleted() when mountSlewCompleted != null:
return mountSlewCompleted(_that.ra,_that.dec);case EquipmentEvent_MountTrackingStarted() when mountTrackingStarted != null:
return mountTrackingStarted();case EquipmentEvent_MountTrackingStopped() when mountTrackingStopped != null:
return mountTrackingStopped();case EquipmentEvent_MountParkStarted() when mountParkStarted != null:
return mountParkStarted();case EquipmentEvent_MountParkCompleted() when mountParkCompleted != null:
return mountParkCompleted();case EquipmentEvent_MountUnparked() when mountUnparked != null:
return mountUnparked();case EquipmentEvent_FocuserMoveStarted() when focuserMoveStarted != null:
return focuserMoveStarted(_that.targetPosition);case EquipmentEvent_FocuserMoveCompleted() when focuserMoveCompleted != null:
return focuserMoveCompleted(_that.position);case EquipmentEvent_FocuserTemperatureChanged() when focuserTemperatureChanged != null:
return focuserTemperatureChanged(_that.temperature);case EquipmentEvent_FilterChanging() when filterChanging != null:
return filterChanging(_that.fromPosition,_that.toPosition,_that.filterName);case EquipmentEvent_FilterChanged() when filterChanged != null:
return filterChanged(_that.position,_that.filterName);case EquipmentEvent_RotatorMoveStarted() when rotatorMoveStarted != null:
return rotatorMoveStarted(_that.targetAngle);case EquipmentEvent_RotatorMoveCompleted() when rotatorMoveCompleted != null:
return rotatorMoveCompleted(_that.angle);case EquipmentEvent_CameraCoolingStarted() when cameraCoolingStarted != null:
return cameraCoolingStarted(_that.targetTemp);case EquipmentEvent_CameraCoolingReached() when cameraCoolingReached != null:
return cameraCoolingReached(_that.temperature);case EquipmentEvent_CameraWarmingStarted() when cameraWarmingStarted != null:
return cameraWarmingStarted();case EquipmentEvent_CameraWarmingCompleted() when cameraWarmingCompleted != null:
return cameraWarmingCompleted();case EquipmentEvent_HeartbeatStarted() when heartbeatStarted != null:
return heartbeatStarted(_that.deviceType,_that.deviceId,_that.intervalSecs);case EquipmentEvent_HeartbeatStopped() when heartbeatStopped != null:
return heartbeatStopped(_that.deviceType,_that.deviceId);case EquipmentEvent_HeartbeatStatusChanged() when heartbeatStatusChanged != null:
return heartbeatStatusChanged(_that.deviceType,_that.deviceId,_that.status,_that.consecutiveFailures,_that.lastRttMs);case EquipmentEvent_HeartbeatReconnecting() when heartbeatReconnecting != null:
return heartbeatReconnecting(_that.deviceType,_that.deviceId,_that.attempt,_that.maxAttempts);case EquipmentEvent_HeartbeatReconnected() when heartbeatReconnected != null:
return heartbeatReconnected(_that.deviceType,_that.deviceId,_that.afterAttempts);case EquipmentEvent_DeviceDiscovered() when deviceDiscovered != null:
return deviceDiscovered(_that.deviceClass,_that.driver,_that.id,_that.name,_that.displayName,_that.uniqueId);case EquipmentEvent_DeviceLost() when deviceLost != null:
return deviceLost(_that.deviceClass,_that.driver,_that.id);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String deviceType,  String deviceId)  connecting,required TResult Function( String deviceType,  String deviceId)  connected,required TResult Function( String deviceType,  String deviceId)  disconnected,required TResult Function( String deviceType,  String deviceId,  String property,  String value)  propertyChanged,required TResult Function( String deviceType,  String deviceId,  String message)  error,required TResult Function( double ra,  double dec)  mountSlewStarted,required TResult Function( double ra,  double dec)  mountSlewCompleted,required TResult Function()  mountTrackingStarted,required TResult Function()  mountTrackingStopped,required TResult Function()  mountParkStarted,required TResult Function()  mountParkCompleted,required TResult Function()  mountUnparked,required TResult Function( int targetPosition)  focuserMoveStarted,required TResult Function( int position)  focuserMoveCompleted,required TResult Function( double temperature)  focuserTemperatureChanged,required TResult Function( int fromPosition,  int toPosition,  String? filterName)  filterChanging,required TResult Function( int position,  String? filterName)  filterChanged,required TResult Function( double targetAngle)  rotatorMoveStarted,required TResult Function( double angle)  rotatorMoveCompleted,required TResult Function( double targetTemp)  cameraCoolingStarted,required TResult Function( double temperature)  cameraCoolingReached,required TResult Function()  cameraWarmingStarted,required TResult Function()  cameraWarmingCompleted,required TResult Function( String deviceType,  String deviceId,  BigInt intervalSecs)  heartbeatStarted,required TResult Function( String deviceType,  String deviceId)  heartbeatStopped,required TResult Function( String deviceType,  String deviceId,  HeartbeatStatus status,  int consecutiveFailures,  BigInt? lastRttMs)  heartbeatStatusChanged,required TResult Function( String deviceType,  String deviceId,  int attempt,  int maxAttempts)  heartbeatReconnecting,required TResult Function( String deviceType,  String deviceId,  int afterAttempts)  heartbeatReconnected,required TResult Function( String deviceClass,  String driver,  String id,  String name,  String displayName,  String? uniqueId)  deviceDiscovered,required TResult Function( String deviceClass,  String driver,  String id)  deviceLost,}) {final _that = this;
switch (_that) {
case EquipmentEvent_Connecting():
return connecting(_that.deviceType,_that.deviceId);case EquipmentEvent_Connected():
return connected(_that.deviceType,_that.deviceId);case EquipmentEvent_Disconnected():
return disconnected(_that.deviceType,_that.deviceId);case EquipmentEvent_PropertyChanged():
return propertyChanged(_that.deviceType,_that.deviceId,_that.property,_that.value);case EquipmentEvent_Error():
return error(_that.deviceType,_that.deviceId,_that.message);case EquipmentEvent_MountSlewStarted():
return mountSlewStarted(_that.ra,_that.dec);case EquipmentEvent_MountSlewCompleted():
return mountSlewCompleted(_that.ra,_that.dec);case EquipmentEvent_MountTrackingStarted():
return mountTrackingStarted();case EquipmentEvent_MountTrackingStopped():
return mountTrackingStopped();case EquipmentEvent_MountParkStarted():
return mountParkStarted();case EquipmentEvent_MountParkCompleted():
return mountParkCompleted();case EquipmentEvent_MountUnparked():
return mountUnparked();case EquipmentEvent_FocuserMoveStarted():
return focuserMoveStarted(_that.targetPosition);case EquipmentEvent_FocuserMoveCompleted():
return focuserMoveCompleted(_that.position);case EquipmentEvent_FocuserTemperatureChanged():
return focuserTemperatureChanged(_that.temperature);case EquipmentEvent_FilterChanging():
return filterChanging(_that.fromPosition,_that.toPosition,_that.filterName);case EquipmentEvent_FilterChanged():
return filterChanged(_that.position,_that.filterName);case EquipmentEvent_RotatorMoveStarted():
return rotatorMoveStarted(_that.targetAngle);case EquipmentEvent_RotatorMoveCompleted():
return rotatorMoveCompleted(_that.angle);case EquipmentEvent_CameraCoolingStarted():
return cameraCoolingStarted(_that.targetTemp);case EquipmentEvent_CameraCoolingReached():
return cameraCoolingReached(_that.temperature);case EquipmentEvent_CameraWarmingStarted():
return cameraWarmingStarted();case EquipmentEvent_CameraWarmingCompleted():
return cameraWarmingCompleted();case EquipmentEvent_HeartbeatStarted():
return heartbeatStarted(_that.deviceType,_that.deviceId,_that.intervalSecs);case EquipmentEvent_HeartbeatStopped():
return heartbeatStopped(_that.deviceType,_that.deviceId);case EquipmentEvent_HeartbeatStatusChanged():
return heartbeatStatusChanged(_that.deviceType,_that.deviceId,_that.status,_that.consecutiveFailures,_that.lastRttMs);case EquipmentEvent_HeartbeatReconnecting():
return heartbeatReconnecting(_that.deviceType,_that.deviceId,_that.attempt,_that.maxAttempts);case EquipmentEvent_HeartbeatReconnected():
return heartbeatReconnected(_that.deviceType,_that.deviceId,_that.afterAttempts);case EquipmentEvent_DeviceDiscovered():
return deviceDiscovered(_that.deviceClass,_that.driver,_that.id,_that.name,_that.displayName,_that.uniqueId);case EquipmentEvent_DeviceLost():
return deviceLost(_that.deviceClass,_that.driver,_that.id);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String deviceType,  String deviceId)?  connecting,TResult? Function( String deviceType,  String deviceId)?  connected,TResult? Function( String deviceType,  String deviceId)?  disconnected,TResult? Function( String deviceType,  String deviceId,  String property,  String value)?  propertyChanged,TResult? Function( String deviceType,  String deviceId,  String message)?  error,TResult? Function( double ra,  double dec)?  mountSlewStarted,TResult? Function( double ra,  double dec)?  mountSlewCompleted,TResult? Function()?  mountTrackingStarted,TResult? Function()?  mountTrackingStopped,TResult? Function()?  mountParkStarted,TResult? Function()?  mountParkCompleted,TResult? Function()?  mountUnparked,TResult? Function( int targetPosition)?  focuserMoveStarted,TResult? Function( int position)?  focuserMoveCompleted,TResult? Function( double temperature)?  focuserTemperatureChanged,TResult? Function( int fromPosition,  int toPosition,  String? filterName)?  filterChanging,TResult? Function( int position,  String? filterName)?  filterChanged,TResult? Function( double targetAngle)?  rotatorMoveStarted,TResult? Function( double angle)?  rotatorMoveCompleted,TResult? Function( double targetTemp)?  cameraCoolingStarted,TResult? Function( double temperature)?  cameraCoolingReached,TResult? Function()?  cameraWarmingStarted,TResult? Function()?  cameraWarmingCompleted,TResult? Function( String deviceType,  String deviceId,  BigInt intervalSecs)?  heartbeatStarted,TResult? Function( String deviceType,  String deviceId)?  heartbeatStopped,TResult? Function( String deviceType,  String deviceId,  HeartbeatStatus status,  int consecutiveFailures,  BigInt? lastRttMs)?  heartbeatStatusChanged,TResult? Function( String deviceType,  String deviceId,  int attempt,  int maxAttempts)?  heartbeatReconnecting,TResult? Function( String deviceType,  String deviceId,  int afterAttempts)?  heartbeatReconnected,TResult? Function( String deviceClass,  String driver,  String id,  String name,  String displayName,  String? uniqueId)?  deviceDiscovered,TResult? Function( String deviceClass,  String driver,  String id)?  deviceLost,}) {final _that = this;
switch (_that) {
case EquipmentEvent_Connecting() when connecting != null:
return connecting(_that.deviceType,_that.deviceId);case EquipmentEvent_Connected() when connected != null:
return connected(_that.deviceType,_that.deviceId);case EquipmentEvent_Disconnected() when disconnected != null:
return disconnected(_that.deviceType,_that.deviceId);case EquipmentEvent_PropertyChanged() when propertyChanged != null:
return propertyChanged(_that.deviceType,_that.deviceId,_that.property,_that.value);case EquipmentEvent_Error() when error != null:
return error(_that.deviceType,_that.deviceId,_that.message);case EquipmentEvent_MountSlewStarted() when mountSlewStarted != null:
return mountSlewStarted(_that.ra,_that.dec);case EquipmentEvent_MountSlewCompleted() when mountSlewCompleted != null:
return mountSlewCompleted(_that.ra,_that.dec);case EquipmentEvent_MountTrackingStarted() when mountTrackingStarted != null:
return mountTrackingStarted();case EquipmentEvent_MountTrackingStopped() when mountTrackingStopped != null:
return mountTrackingStopped();case EquipmentEvent_MountParkStarted() when mountParkStarted != null:
return mountParkStarted();case EquipmentEvent_MountParkCompleted() when mountParkCompleted != null:
return mountParkCompleted();case EquipmentEvent_MountUnparked() when mountUnparked != null:
return mountUnparked();case EquipmentEvent_FocuserMoveStarted() when focuserMoveStarted != null:
return focuserMoveStarted(_that.targetPosition);case EquipmentEvent_FocuserMoveCompleted() when focuserMoveCompleted != null:
return focuserMoveCompleted(_that.position);case EquipmentEvent_FocuserTemperatureChanged() when focuserTemperatureChanged != null:
return focuserTemperatureChanged(_that.temperature);case EquipmentEvent_FilterChanging() when filterChanging != null:
return filterChanging(_that.fromPosition,_that.toPosition,_that.filterName);case EquipmentEvent_FilterChanged() when filterChanged != null:
return filterChanged(_that.position,_that.filterName);case EquipmentEvent_RotatorMoveStarted() when rotatorMoveStarted != null:
return rotatorMoveStarted(_that.targetAngle);case EquipmentEvent_RotatorMoveCompleted() when rotatorMoveCompleted != null:
return rotatorMoveCompleted(_that.angle);case EquipmentEvent_CameraCoolingStarted() when cameraCoolingStarted != null:
return cameraCoolingStarted(_that.targetTemp);case EquipmentEvent_CameraCoolingReached() when cameraCoolingReached != null:
return cameraCoolingReached(_that.temperature);case EquipmentEvent_CameraWarmingStarted() when cameraWarmingStarted != null:
return cameraWarmingStarted();case EquipmentEvent_CameraWarmingCompleted() when cameraWarmingCompleted != null:
return cameraWarmingCompleted();case EquipmentEvent_HeartbeatStarted() when heartbeatStarted != null:
return heartbeatStarted(_that.deviceType,_that.deviceId,_that.intervalSecs);case EquipmentEvent_HeartbeatStopped() when heartbeatStopped != null:
return heartbeatStopped(_that.deviceType,_that.deviceId);case EquipmentEvent_HeartbeatStatusChanged() when heartbeatStatusChanged != null:
return heartbeatStatusChanged(_that.deviceType,_that.deviceId,_that.status,_that.consecutiveFailures,_that.lastRttMs);case EquipmentEvent_HeartbeatReconnecting() when heartbeatReconnecting != null:
return heartbeatReconnecting(_that.deviceType,_that.deviceId,_that.attempt,_that.maxAttempts);case EquipmentEvent_HeartbeatReconnected() when heartbeatReconnected != null:
return heartbeatReconnected(_that.deviceType,_that.deviceId,_that.afterAttempts);case EquipmentEvent_DeviceDiscovered() when deviceDiscovered != null:
return deviceDiscovered(_that.deviceClass,_that.driver,_that.id,_that.name,_that.displayName,_that.uniqueId);case EquipmentEvent_DeviceLost() when deviceLost != null:
return deviceLost(_that.deviceClass,_that.driver,_that.id);case _:
  return null;

}
}

}

/// @nodoc


class EquipmentEvent_Connecting extends EquipmentEvent {
  const EquipmentEvent_Connecting({required this.deviceType, required this.deviceId}): super._();
  

 final  String deviceType;
 final  String deviceId;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_ConnectingCopyWith<EquipmentEvent_Connecting> get copyWith => _$EquipmentEvent_ConnectingCopyWithImpl<EquipmentEvent_Connecting>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_Connecting&&(identical(other.deviceType, deviceType) || other.deviceType == deviceType)&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId));
}


@override
int get hashCode => Object.hash(runtimeType,deviceType,deviceId);

@override
String toString() {
  return 'EquipmentEvent.connecting(deviceType: $deviceType, deviceId: $deviceId)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_ConnectingCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_ConnectingCopyWith(EquipmentEvent_Connecting value, $Res Function(EquipmentEvent_Connecting) _then) = _$EquipmentEvent_ConnectingCopyWithImpl;
@useResult
$Res call({
 String deviceType, String deviceId
});




}
/// @nodoc
class _$EquipmentEvent_ConnectingCopyWithImpl<$Res>
    implements $EquipmentEvent_ConnectingCopyWith<$Res> {
  _$EquipmentEvent_ConnectingCopyWithImpl(this._self, this._then);

  final EquipmentEvent_Connecting _self;
  final $Res Function(EquipmentEvent_Connecting) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceType = null,Object? deviceId = null,}) {
  return _then(EquipmentEvent_Connecting(
deviceType: null == deviceType ? _self.deviceType : deviceType // ignore: cast_nullable_to_non_nullable
as String,deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class EquipmentEvent_Connected extends EquipmentEvent {
  const EquipmentEvent_Connected({required this.deviceType, required this.deviceId}): super._();
  

 final  String deviceType;
 final  String deviceId;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_ConnectedCopyWith<EquipmentEvent_Connected> get copyWith => _$EquipmentEvent_ConnectedCopyWithImpl<EquipmentEvent_Connected>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_Connected&&(identical(other.deviceType, deviceType) || other.deviceType == deviceType)&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId));
}


@override
int get hashCode => Object.hash(runtimeType,deviceType,deviceId);

@override
String toString() {
  return 'EquipmentEvent.connected(deviceType: $deviceType, deviceId: $deviceId)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_ConnectedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_ConnectedCopyWith(EquipmentEvent_Connected value, $Res Function(EquipmentEvent_Connected) _then) = _$EquipmentEvent_ConnectedCopyWithImpl;
@useResult
$Res call({
 String deviceType, String deviceId
});




}
/// @nodoc
class _$EquipmentEvent_ConnectedCopyWithImpl<$Res>
    implements $EquipmentEvent_ConnectedCopyWith<$Res> {
  _$EquipmentEvent_ConnectedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_Connected _self;
  final $Res Function(EquipmentEvent_Connected) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceType = null,Object? deviceId = null,}) {
  return _then(EquipmentEvent_Connected(
deviceType: null == deviceType ? _self.deviceType : deviceType // ignore: cast_nullable_to_non_nullable
as String,deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class EquipmentEvent_Disconnected extends EquipmentEvent {
  const EquipmentEvent_Disconnected({required this.deviceType, required this.deviceId}): super._();
  

 final  String deviceType;
 final  String deviceId;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_DisconnectedCopyWith<EquipmentEvent_Disconnected> get copyWith => _$EquipmentEvent_DisconnectedCopyWithImpl<EquipmentEvent_Disconnected>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_Disconnected&&(identical(other.deviceType, deviceType) || other.deviceType == deviceType)&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId));
}


@override
int get hashCode => Object.hash(runtimeType,deviceType,deviceId);

@override
String toString() {
  return 'EquipmentEvent.disconnected(deviceType: $deviceType, deviceId: $deviceId)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_DisconnectedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_DisconnectedCopyWith(EquipmentEvent_Disconnected value, $Res Function(EquipmentEvent_Disconnected) _then) = _$EquipmentEvent_DisconnectedCopyWithImpl;
@useResult
$Res call({
 String deviceType, String deviceId
});




}
/// @nodoc
class _$EquipmentEvent_DisconnectedCopyWithImpl<$Res>
    implements $EquipmentEvent_DisconnectedCopyWith<$Res> {
  _$EquipmentEvent_DisconnectedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_Disconnected _self;
  final $Res Function(EquipmentEvent_Disconnected) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceType = null,Object? deviceId = null,}) {
  return _then(EquipmentEvent_Disconnected(
deviceType: null == deviceType ? _self.deviceType : deviceType // ignore: cast_nullable_to_non_nullable
as String,deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class EquipmentEvent_PropertyChanged extends EquipmentEvent {
  const EquipmentEvent_PropertyChanged({required this.deviceType, required this.deviceId, required this.property, required this.value}): super._();
  

 final  String deviceType;
 final  String deviceId;
 final  String property;
 final  String value;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_PropertyChangedCopyWith<EquipmentEvent_PropertyChanged> get copyWith => _$EquipmentEvent_PropertyChangedCopyWithImpl<EquipmentEvent_PropertyChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_PropertyChanged&&(identical(other.deviceType, deviceType) || other.deviceType == deviceType)&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.property, property) || other.property == property)&&(identical(other.value, value) || other.value == value));
}


@override
int get hashCode => Object.hash(runtimeType,deviceType,deviceId,property,value);

@override
String toString() {
  return 'EquipmentEvent.propertyChanged(deviceType: $deviceType, deviceId: $deviceId, property: $property, value: $value)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_PropertyChangedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_PropertyChangedCopyWith(EquipmentEvent_PropertyChanged value, $Res Function(EquipmentEvent_PropertyChanged) _then) = _$EquipmentEvent_PropertyChangedCopyWithImpl;
@useResult
$Res call({
 String deviceType, String deviceId, String property, String value
});




}
/// @nodoc
class _$EquipmentEvent_PropertyChangedCopyWithImpl<$Res>
    implements $EquipmentEvent_PropertyChangedCopyWith<$Res> {
  _$EquipmentEvent_PropertyChangedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_PropertyChanged _self;
  final $Res Function(EquipmentEvent_PropertyChanged) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceType = null,Object? deviceId = null,Object? property = null,Object? value = null,}) {
  return _then(EquipmentEvent_PropertyChanged(
deviceType: null == deviceType ? _self.deviceType : deviceType // ignore: cast_nullable_to_non_nullable
as String,deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,property: null == property ? _self.property : property // ignore: cast_nullable_to_non_nullable
as String,value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class EquipmentEvent_Error extends EquipmentEvent {
  const EquipmentEvent_Error({required this.deviceType, required this.deviceId, required this.message}): super._();
  

 final  String deviceType;
 final  String deviceId;
 final  String message;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_ErrorCopyWith<EquipmentEvent_Error> get copyWith => _$EquipmentEvent_ErrorCopyWithImpl<EquipmentEvent_Error>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_Error&&(identical(other.deviceType, deviceType) || other.deviceType == deviceType)&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,deviceType,deviceId,message);

@override
String toString() {
  return 'EquipmentEvent.error(deviceType: $deviceType, deviceId: $deviceId, message: $message)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_ErrorCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_ErrorCopyWith(EquipmentEvent_Error value, $Res Function(EquipmentEvent_Error) _then) = _$EquipmentEvent_ErrorCopyWithImpl;
@useResult
$Res call({
 String deviceType, String deviceId, String message
});




}
/// @nodoc
class _$EquipmentEvent_ErrorCopyWithImpl<$Res>
    implements $EquipmentEvent_ErrorCopyWith<$Res> {
  _$EquipmentEvent_ErrorCopyWithImpl(this._self, this._then);

  final EquipmentEvent_Error _self;
  final $Res Function(EquipmentEvent_Error) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceType = null,Object? deviceId = null,Object? message = null,}) {
  return _then(EquipmentEvent_Error(
deviceType: null == deviceType ? _self.deviceType : deviceType // ignore: cast_nullable_to_non_nullable
as String,deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class EquipmentEvent_MountSlewStarted extends EquipmentEvent {
  const EquipmentEvent_MountSlewStarted({required this.ra, required this.dec}): super._();
  

 final  double ra;
 final  double dec;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_MountSlewStartedCopyWith<EquipmentEvent_MountSlewStarted> get copyWith => _$EquipmentEvent_MountSlewStartedCopyWithImpl<EquipmentEvent_MountSlewStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_MountSlewStarted&&(identical(other.ra, ra) || other.ra == ra)&&(identical(other.dec, dec) || other.dec == dec));
}


@override
int get hashCode => Object.hash(runtimeType,ra,dec);

@override
String toString() {
  return 'EquipmentEvent.mountSlewStarted(ra: $ra, dec: $dec)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_MountSlewStartedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_MountSlewStartedCopyWith(EquipmentEvent_MountSlewStarted value, $Res Function(EquipmentEvent_MountSlewStarted) _then) = _$EquipmentEvent_MountSlewStartedCopyWithImpl;
@useResult
$Res call({
 double ra, double dec
});




}
/// @nodoc
class _$EquipmentEvent_MountSlewStartedCopyWithImpl<$Res>
    implements $EquipmentEvent_MountSlewStartedCopyWith<$Res> {
  _$EquipmentEvent_MountSlewStartedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_MountSlewStarted _self;
  final $Res Function(EquipmentEvent_MountSlewStarted) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? ra = null,Object? dec = null,}) {
  return _then(EquipmentEvent_MountSlewStarted(
ra: null == ra ? _self.ra : ra // ignore: cast_nullable_to_non_nullable
as double,dec: null == dec ? _self.dec : dec // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class EquipmentEvent_MountSlewCompleted extends EquipmentEvent {
  const EquipmentEvent_MountSlewCompleted({required this.ra, required this.dec}): super._();
  

 final  double ra;
 final  double dec;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_MountSlewCompletedCopyWith<EquipmentEvent_MountSlewCompleted> get copyWith => _$EquipmentEvent_MountSlewCompletedCopyWithImpl<EquipmentEvent_MountSlewCompleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_MountSlewCompleted&&(identical(other.ra, ra) || other.ra == ra)&&(identical(other.dec, dec) || other.dec == dec));
}


@override
int get hashCode => Object.hash(runtimeType,ra,dec);

@override
String toString() {
  return 'EquipmentEvent.mountSlewCompleted(ra: $ra, dec: $dec)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_MountSlewCompletedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_MountSlewCompletedCopyWith(EquipmentEvent_MountSlewCompleted value, $Res Function(EquipmentEvent_MountSlewCompleted) _then) = _$EquipmentEvent_MountSlewCompletedCopyWithImpl;
@useResult
$Res call({
 double ra, double dec
});




}
/// @nodoc
class _$EquipmentEvent_MountSlewCompletedCopyWithImpl<$Res>
    implements $EquipmentEvent_MountSlewCompletedCopyWith<$Res> {
  _$EquipmentEvent_MountSlewCompletedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_MountSlewCompleted _self;
  final $Res Function(EquipmentEvent_MountSlewCompleted) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? ra = null,Object? dec = null,}) {
  return _then(EquipmentEvent_MountSlewCompleted(
ra: null == ra ? _self.ra : ra // ignore: cast_nullable_to_non_nullable
as double,dec: null == dec ? _self.dec : dec // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class EquipmentEvent_MountTrackingStarted extends EquipmentEvent {
  const EquipmentEvent_MountTrackingStarted(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_MountTrackingStarted);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EquipmentEvent.mountTrackingStarted()';
}


}




/// @nodoc


class EquipmentEvent_MountTrackingStopped extends EquipmentEvent {
  const EquipmentEvent_MountTrackingStopped(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_MountTrackingStopped);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EquipmentEvent.mountTrackingStopped()';
}


}




/// @nodoc


class EquipmentEvent_MountParkStarted extends EquipmentEvent {
  const EquipmentEvent_MountParkStarted(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_MountParkStarted);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EquipmentEvent.mountParkStarted()';
}


}




/// @nodoc


class EquipmentEvent_MountParkCompleted extends EquipmentEvent {
  const EquipmentEvent_MountParkCompleted(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_MountParkCompleted);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EquipmentEvent.mountParkCompleted()';
}


}




/// @nodoc


class EquipmentEvent_MountUnparked extends EquipmentEvent {
  const EquipmentEvent_MountUnparked(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_MountUnparked);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EquipmentEvent.mountUnparked()';
}


}




/// @nodoc


class EquipmentEvent_FocuserMoveStarted extends EquipmentEvent {
  const EquipmentEvent_FocuserMoveStarted({required this.targetPosition}): super._();
  

 final  int targetPosition;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_FocuserMoveStartedCopyWith<EquipmentEvent_FocuserMoveStarted> get copyWith => _$EquipmentEvent_FocuserMoveStartedCopyWithImpl<EquipmentEvent_FocuserMoveStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_FocuserMoveStarted&&(identical(other.targetPosition, targetPosition) || other.targetPosition == targetPosition));
}


@override
int get hashCode => Object.hash(runtimeType,targetPosition);

@override
String toString() {
  return 'EquipmentEvent.focuserMoveStarted(targetPosition: $targetPosition)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_FocuserMoveStartedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_FocuserMoveStartedCopyWith(EquipmentEvent_FocuserMoveStarted value, $Res Function(EquipmentEvent_FocuserMoveStarted) _then) = _$EquipmentEvent_FocuserMoveStartedCopyWithImpl;
@useResult
$Res call({
 int targetPosition
});




}
/// @nodoc
class _$EquipmentEvent_FocuserMoveStartedCopyWithImpl<$Res>
    implements $EquipmentEvent_FocuserMoveStartedCopyWith<$Res> {
  _$EquipmentEvent_FocuserMoveStartedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_FocuserMoveStarted _self;
  final $Res Function(EquipmentEvent_FocuserMoveStarted) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? targetPosition = null,}) {
  return _then(EquipmentEvent_FocuserMoveStarted(
targetPosition: null == targetPosition ? _self.targetPosition : targetPosition // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class EquipmentEvent_FocuserMoveCompleted extends EquipmentEvent {
  const EquipmentEvent_FocuserMoveCompleted({required this.position}): super._();
  

 final  int position;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_FocuserMoveCompletedCopyWith<EquipmentEvent_FocuserMoveCompleted> get copyWith => _$EquipmentEvent_FocuserMoveCompletedCopyWithImpl<EquipmentEvent_FocuserMoveCompleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_FocuserMoveCompleted&&(identical(other.position, position) || other.position == position));
}


@override
int get hashCode => Object.hash(runtimeType,position);

@override
String toString() {
  return 'EquipmentEvent.focuserMoveCompleted(position: $position)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_FocuserMoveCompletedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_FocuserMoveCompletedCopyWith(EquipmentEvent_FocuserMoveCompleted value, $Res Function(EquipmentEvent_FocuserMoveCompleted) _then) = _$EquipmentEvent_FocuserMoveCompletedCopyWithImpl;
@useResult
$Res call({
 int position
});




}
/// @nodoc
class _$EquipmentEvent_FocuserMoveCompletedCopyWithImpl<$Res>
    implements $EquipmentEvent_FocuserMoveCompletedCopyWith<$Res> {
  _$EquipmentEvent_FocuserMoveCompletedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_FocuserMoveCompleted _self;
  final $Res Function(EquipmentEvent_FocuserMoveCompleted) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? position = null,}) {
  return _then(EquipmentEvent_FocuserMoveCompleted(
position: null == position ? _self.position : position // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class EquipmentEvent_FocuserTemperatureChanged extends EquipmentEvent {
  const EquipmentEvent_FocuserTemperatureChanged({required this.temperature}): super._();
  

 final  double temperature;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_FocuserTemperatureChangedCopyWith<EquipmentEvent_FocuserTemperatureChanged> get copyWith => _$EquipmentEvent_FocuserTemperatureChangedCopyWithImpl<EquipmentEvent_FocuserTemperatureChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_FocuserTemperatureChanged&&(identical(other.temperature, temperature) || other.temperature == temperature));
}


@override
int get hashCode => Object.hash(runtimeType,temperature);

@override
String toString() {
  return 'EquipmentEvent.focuserTemperatureChanged(temperature: $temperature)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_FocuserTemperatureChangedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_FocuserTemperatureChangedCopyWith(EquipmentEvent_FocuserTemperatureChanged value, $Res Function(EquipmentEvent_FocuserTemperatureChanged) _then) = _$EquipmentEvent_FocuserTemperatureChangedCopyWithImpl;
@useResult
$Res call({
 double temperature
});




}
/// @nodoc
class _$EquipmentEvent_FocuserTemperatureChangedCopyWithImpl<$Res>
    implements $EquipmentEvent_FocuserTemperatureChangedCopyWith<$Res> {
  _$EquipmentEvent_FocuserTemperatureChangedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_FocuserTemperatureChanged _self;
  final $Res Function(EquipmentEvent_FocuserTemperatureChanged) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? temperature = null,}) {
  return _then(EquipmentEvent_FocuserTemperatureChanged(
temperature: null == temperature ? _self.temperature : temperature // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class EquipmentEvent_FilterChanging extends EquipmentEvent {
  const EquipmentEvent_FilterChanging({required this.fromPosition, required this.toPosition, this.filterName}): super._();
  

 final  int fromPosition;
 final  int toPosition;
 final  String? filterName;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_FilterChangingCopyWith<EquipmentEvent_FilterChanging> get copyWith => _$EquipmentEvent_FilterChangingCopyWithImpl<EquipmentEvent_FilterChanging>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_FilterChanging&&(identical(other.fromPosition, fromPosition) || other.fromPosition == fromPosition)&&(identical(other.toPosition, toPosition) || other.toPosition == toPosition)&&(identical(other.filterName, filterName) || other.filterName == filterName));
}


@override
int get hashCode => Object.hash(runtimeType,fromPosition,toPosition,filterName);

@override
String toString() {
  return 'EquipmentEvent.filterChanging(fromPosition: $fromPosition, toPosition: $toPosition, filterName: $filterName)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_FilterChangingCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_FilterChangingCopyWith(EquipmentEvent_FilterChanging value, $Res Function(EquipmentEvent_FilterChanging) _then) = _$EquipmentEvent_FilterChangingCopyWithImpl;
@useResult
$Res call({
 int fromPosition, int toPosition, String? filterName
});




}
/// @nodoc
class _$EquipmentEvent_FilterChangingCopyWithImpl<$Res>
    implements $EquipmentEvent_FilterChangingCopyWith<$Res> {
  _$EquipmentEvent_FilterChangingCopyWithImpl(this._self, this._then);

  final EquipmentEvent_FilterChanging _self;
  final $Res Function(EquipmentEvent_FilterChanging) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? fromPosition = null,Object? toPosition = null,Object? filterName = freezed,}) {
  return _then(EquipmentEvent_FilterChanging(
fromPosition: null == fromPosition ? _self.fromPosition : fromPosition // ignore: cast_nullable_to_non_nullable
as int,toPosition: null == toPosition ? _self.toPosition : toPosition // ignore: cast_nullable_to_non_nullable
as int,filterName: freezed == filterName ? _self.filterName : filterName // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class EquipmentEvent_FilterChanged extends EquipmentEvent {
  const EquipmentEvent_FilterChanged({required this.position, this.filterName}): super._();
  

 final  int position;
 final  String? filterName;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_FilterChangedCopyWith<EquipmentEvent_FilterChanged> get copyWith => _$EquipmentEvent_FilterChangedCopyWithImpl<EquipmentEvent_FilterChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_FilterChanged&&(identical(other.position, position) || other.position == position)&&(identical(other.filterName, filterName) || other.filterName == filterName));
}


@override
int get hashCode => Object.hash(runtimeType,position,filterName);

@override
String toString() {
  return 'EquipmentEvent.filterChanged(position: $position, filterName: $filterName)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_FilterChangedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_FilterChangedCopyWith(EquipmentEvent_FilterChanged value, $Res Function(EquipmentEvent_FilterChanged) _then) = _$EquipmentEvent_FilterChangedCopyWithImpl;
@useResult
$Res call({
 int position, String? filterName
});




}
/// @nodoc
class _$EquipmentEvent_FilterChangedCopyWithImpl<$Res>
    implements $EquipmentEvent_FilterChangedCopyWith<$Res> {
  _$EquipmentEvent_FilterChangedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_FilterChanged _self;
  final $Res Function(EquipmentEvent_FilterChanged) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? position = null,Object? filterName = freezed,}) {
  return _then(EquipmentEvent_FilterChanged(
position: null == position ? _self.position : position // ignore: cast_nullable_to_non_nullable
as int,filterName: freezed == filterName ? _self.filterName : filterName // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class EquipmentEvent_RotatorMoveStarted extends EquipmentEvent {
  const EquipmentEvent_RotatorMoveStarted({required this.targetAngle}): super._();
  

 final  double targetAngle;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_RotatorMoveStartedCopyWith<EquipmentEvent_RotatorMoveStarted> get copyWith => _$EquipmentEvent_RotatorMoveStartedCopyWithImpl<EquipmentEvent_RotatorMoveStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_RotatorMoveStarted&&(identical(other.targetAngle, targetAngle) || other.targetAngle == targetAngle));
}


@override
int get hashCode => Object.hash(runtimeType,targetAngle);

@override
String toString() {
  return 'EquipmentEvent.rotatorMoveStarted(targetAngle: $targetAngle)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_RotatorMoveStartedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_RotatorMoveStartedCopyWith(EquipmentEvent_RotatorMoveStarted value, $Res Function(EquipmentEvent_RotatorMoveStarted) _then) = _$EquipmentEvent_RotatorMoveStartedCopyWithImpl;
@useResult
$Res call({
 double targetAngle
});




}
/// @nodoc
class _$EquipmentEvent_RotatorMoveStartedCopyWithImpl<$Res>
    implements $EquipmentEvent_RotatorMoveStartedCopyWith<$Res> {
  _$EquipmentEvent_RotatorMoveStartedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_RotatorMoveStarted _self;
  final $Res Function(EquipmentEvent_RotatorMoveStarted) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? targetAngle = null,}) {
  return _then(EquipmentEvent_RotatorMoveStarted(
targetAngle: null == targetAngle ? _self.targetAngle : targetAngle // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class EquipmentEvent_RotatorMoveCompleted extends EquipmentEvent {
  const EquipmentEvent_RotatorMoveCompleted({required this.angle}): super._();
  

 final  double angle;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_RotatorMoveCompletedCopyWith<EquipmentEvent_RotatorMoveCompleted> get copyWith => _$EquipmentEvent_RotatorMoveCompletedCopyWithImpl<EquipmentEvent_RotatorMoveCompleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_RotatorMoveCompleted&&(identical(other.angle, angle) || other.angle == angle));
}


@override
int get hashCode => Object.hash(runtimeType,angle);

@override
String toString() {
  return 'EquipmentEvent.rotatorMoveCompleted(angle: $angle)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_RotatorMoveCompletedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_RotatorMoveCompletedCopyWith(EquipmentEvent_RotatorMoveCompleted value, $Res Function(EquipmentEvent_RotatorMoveCompleted) _then) = _$EquipmentEvent_RotatorMoveCompletedCopyWithImpl;
@useResult
$Res call({
 double angle
});




}
/// @nodoc
class _$EquipmentEvent_RotatorMoveCompletedCopyWithImpl<$Res>
    implements $EquipmentEvent_RotatorMoveCompletedCopyWith<$Res> {
  _$EquipmentEvent_RotatorMoveCompletedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_RotatorMoveCompleted _self;
  final $Res Function(EquipmentEvent_RotatorMoveCompleted) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? angle = null,}) {
  return _then(EquipmentEvent_RotatorMoveCompleted(
angle: null == angle ? _self.angle : angle // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class EquipmentEvent_CameraCoolingStarted extends EquipmentEvent {
  const EquipmentEvent_CameraCoolingStarted({required this.targetTemp}): super._();
  

 final  double targetTemp;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_CameraCoolingStartedCopyWith<EquipmentEvent_CameraCoolingStarted> get copyWith => _$EquipmentEvent_CameraCoolingStartedCopyWithImpl<EquipmentEvent_CameraCoolingStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_CameraCoolingStarted&&(identical(other.targetTemp, targetTemp) || other.targetTemp == targetTemp));
}


@override
int get hashCode => Object.hash(runtimeType,targetTemp);

@override
String toString() {
  return 'EquipmentEvent.cameraCoolingStarted(targetTemp: $targetTemp)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_CameraCoolingStartedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_CameraCoolingStartedCopyWith(EquipmentEvent_CameraCoolingStarted value, $Res Function(EquipmentEvent_CameraCoolingStarted) _then) = _$EquipmentEvent_CameraCoolingStartedCopyWithImpl;
@useResult
$Res call({
 double targetTemp
});




}
/// @nodoc
class _$EquipmentEvent_CameraCoolingStartedCopyWithImpl<$Res>
    implements $EquipmentEvent_CameraCoolingStartedCopyWith<$Res> {
  _$EquipmentEvent_CameraCoolingStartedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_CameraCoolingStarted _self;
  final $Res Function(EquipmentEvent_CameraCoolingStarted) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? targetTemp = null,}) {
  return _then(EquipmentEvent_CameraCoolingStarted(
targetTemp: null == targetTemp ? _self.targetTemp : targetTemp // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class EquipmentEvent_CameraCoolingReached extends EquipmentEvent {
  const EquipmentEvent_CameraCoolingReached({required this.temperature}): super._();
  

 final  double temperature;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_CameraCoolingReachedCopyWith<EquipmentEvent_CameraCoolingReached> get copyWith => _$EquipmentEvent_CameraCoolingReachedCopyWithImpl<EquipmentEvent_CameraCoolingReached>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_CameraCoolingReached&&(identical(other.temperature, temperature) || other.temperature == temperature));
}


@override
int get hashCode => Object.hash(runtimeType,temperature);

@override
String toString() {
  return 'EquipmentEvent.cameraCoolingReached(temperature: $temperature)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_CameraCoolingReachedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_CameraCoolingReachedCopyWith(EquipmentEvent_CameraCoolingReached value, $Res Function(EquipmentEvent_CameraCoolingReached) _then) = _$EquipmentEvent_CameraCoolingReachedCopyWithImpl;
@useResult
$Res call({
 double temperature
});




}
/// @nodoc
class _$EquipmentEvent_CameraCoolingReachedCopyWithImpl<$Res>
    implements $EquipmentEvent_CameraCoolingReachedCopyWith<$Res> {
  _$EquipmentEvent_CameraCoolingReachedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_CameraCoolingReached _self;
  final $Res Function(EquipmentEvent_CameraCoolingReached) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? temperature = null,}) {
  return _then(EquipmentEvent_CameraCoolingReached(
temperature: null == temperature ? _self.temperature : temperature // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class EquipmentEvent_CameraWarmingStarted extends EquipmentEvent {
  const EquipmentEvent_CameraWarmingStarted(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_CameraWarmingStarted);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EquipmentEvent.cameraWarmingStarted()';
}


}




/// @nodoc


class EquipmentEvent_CameraWarmingCompleted extends EquipmentEvent {
  const EquipmentEvent_CameraWarmingCompleted(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_CameraWarmingCompleted);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EquipmentEvent.cameraWarmingCompleted()';
}


}




/// @nodoc


class EquipmentEvent_HeartbeatStarted extends EquipmentEvent {
  const EquipmentEvent_HeartbeatStarted({required this.deviceType, required this.deviceId, required this.intervalSecs}): super._();
  

 final  String deviceType;
 final  String deviceId;
 final  BigInt intervalSecs;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_HeartbeatStartedCopyWith<EquipmentEvent_HeartbeatStarted> get copyWith => _$EquipmentEvent_HeartbeatStartedCopyWithImpl<EquipmentEvent_HeartbeatStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_HeartbeatStarted&&(identical(other.deviceType, deviceType) || other.deviceType == deviceType)&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.intervalSecs, intervalSecs) || other.intervalSecs == intervalSecs));
}


@override
int get hashCode => Object.hash(runtimeType,deviceType,deviceId,intervalSecs);

@override
String toString() {
  return 'EquipmentEvent.heartbeatStarted(deviceType: $deviceType, deviceId: $deviceId, intervalSecs: $intervalSecs)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_HeartbeatStartedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_HeartbeatStartedCopyWith(EquipmentEvent_HeartbeatStarted value, $Res Function(EquipmentEvent_HeartbeatStarted) _then) = _$EquipmentEvent_HeartbeatStartedCopyWithImpl;
@useResult
$Res call({
 String deviceType, String deviceId, BigInt intervalSecs
});




}
/// @nodoc
class _$EquipmentEvent_HeartbeatStartedCopyWithImpl<$Res>
    implements $EquipmentEvent_HeartbeatStartedCopyWith<$Res> {
  _$EquipmentEvent_HeartbeatStartedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_HeartbeatStarted _self;
  final $Res Function(EquipmentEvent_HeartbeatStarted) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceType = null,Object? deviceId = null,Object? intervalSecs = null,}) {
  return _then(EquipmentEvent_HeartbeatStarted(
deviceType: null == deviceType ? _self.deviceType : deviceType // ignore: cast_nullable_to_non_nullable
as String,deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,intervalSecs: null == intervalSecs ? _self.intervalSecs : intervalSecs // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class EquipmentEvent_HeartbeatStopped extends EquipmentEvent {
  const EquipmentEvent_HeartbeatStopped({required this.deviceType, required this.deviceId}): super._();
  

 final  String deviceType;
 final  String deviceId;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_HeartbeatStoppedCopyWith<EquipmentEvent_HeartbeatStopped> get copyWith => _$EquipmentEvent_HeartbeatStoppedCopyWithImpl<EquipmentEvent_HeartbeatStopped>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_HeartbeatStopped&&(identical(other.deviceType, deviceType) || other.deviceType == deviceType)&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId));
}


@override
int get hashCode => Object.hash(runtimeType,deviceType,deviceId);

@override
String toString() {
  return 'EquipmentEvent.heartbeatStopped(deviceType: $deviceType, deviceId: $deviceId)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_HeartbeatStoppedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_HeartbeatStoppedCopyWith(EquipmentEvent_HeartbeatStopped value, $Res Function(EquipmentEvent_HeartbeatStopped) _then) = _$EquipmentEvent_HeartbeatStoppedCopyWithImpl;
@useResult
$Res call({
 String deviceType, String deviceId
});




}
/// @nodoc
class _$EquipmentEvent_HeartbeatStoppedCopyWithImpl<$Res>
    implements $EquipmentEvent_HeartbeatStoppedCopyWith<$Res> {
  _$EquipmentEvent_HeartbeatStoppedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_HeartbeatStopped _self;
  final $Res Function(EquipmentEvent_HeartbeatStopped) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceType = null,Object? deviceId = null,}) {
  return _then(EquipmentEvent_HeartbeatStopped(
deviceType: null == deviceType ? _self.deviceType : deviceType // ignore: cast_nullable_to_non_nullable
as String,deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class EquipmentEvent_HeartbeatStatusChanged extends EquipmentEvent {
  const EquipmentEvent_HeartbeatStatusChanged({required this.deviceType, required this.deviceId, required this.status, required this.consecutiveFailures, this.lastRttMs}): super._();
  

 final  String deviceType;
 final  String deviceId;
 final  HeartbeatStatus status;
 final  int consecutiveFailures;
 final  BigInt? lastRttMs;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_HeartbeatStatusChangedCopyWith<EquipmentEvent_HeartbeatStatusChanged> get copyWith => _$EquipmentEvent_HeartbeatStatusChangedCopyWithImpl<EquipmentEvent_HeartbeatStatusChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_HeartbeatStatusChanged&&(identical(other.deviceType, deviceType) || other.deviceType == deviceType)&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.status, status) || other.status == status)&&(identical(other.consecutiveFailures, consecutiveFailures) || other.consecutiveFailures == consecutiveFailures)&&(identical(other.lastRttMs, lastRttMs) || other.lastRttMs == lastRttMs));
}


@override
int get hashCode => Object.hash(runtimeType,deviceType,deviceId,status,consecutiveFailures,lastRttMs);

@override
String toString() {
  return 'EquipmentEvent.heartbeatStatusChanged(deviceType: $deviceType, deviceId: $deviceId, status: $status, consecutiveFailures: $consecutiveFailures, lastRttMs: $lastRttMs)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_HeartbeatStatusChangedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_HeartbeatStatusChangedCopyWith(EquipmentEvent_HeartbeatStatusChanged value, $Res Function(EquipmentEvent_HeartbeatStatusChanged) _then) = _$EquipmentEvent_HeartbeatStatusChangedCopyWithImpl;
@useResult
$Res call({
 String deviceType, String deviceId, HeartbeatStatus status, int consecutiveFailures, BigInt? lastRttMs
});




}
/// @nodoc
class _$EquipmentEvent_HeartbeatStatusChangedCopyWithImpl<$Res>
    implements $EquipmentEvent_HeartbeatStatusChangedCopyWith<$Res> {
  _$EquipmentEvent_HeartbeatStatusChangedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_HeartbeatStatusChanged _self;
  final $Res Function(EquipmentEvent_HeartbeatStatusChanged) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceType = null,Object? deviceId = null,Object? status = null,Object? consecutiveFailures = null,Object? lastRttMs = freezed,}) {
  return _then(EquipmentEvent_HeartbeatStatusChanged(
deviceType: null == deviceType ? _self.deviceType : deviceType // ignore: cast_nullable_to_non_nullable
as String,deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as HeartbeatStatus,consecutiveFailures: null == consecutiveFailures ? _self.consecutiveFailures : consecutiveFailures // ignore: cast_nullable_to_non_nullable
as int,lastRttMs: freezed == lastRttMs ? _self.lastRttMs : lastRttMs // ignore: cast_nullable_to_non_nullable
as BigInt?,
  ));
}


}

/// @nodoc


class EquipmentEvent_HeartbeatReconnecting extends EquipmentEvent {
  const EquipmentEvent_HeartbeatReconnecting({required this.deviceType, required this.deviceId, required this.attempt, required this.maxAttempts}): super._();
  

 final  String deviceType;
 final  String deviceId;
 final  int attempt;
 final  int maxAttempts;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_HeartbeatReconnectingCopyWith<EquipmentEvent_HeartbeatReconnecting> get copyWith => _$EquipmentEvent_HeartbeatReconnectingCopyWithImpl<EquipmentEvent_HeartbeatReconnecting>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_HeartbeatReconnecting&&(identical(other.deviceType, deviceType) || other.deviceType == deviceType)&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.attempt, attempt) || other.attempt == attempt)&&(identical(other.maxAttempts, maxAttempts) || other.maxAttempts == maxAttempts));
}


@override
int get hashCode => Object.hash(runtimeType,deviceType,deviceId,attempt,maxAttempts);

@override
String toString() {
  return 'EquipmentEvent.heartbeatReconnecting(deviceType: $deviceType, deviceId: $deviceId, attempt: $attempt, maxAttempts: $maxAttempts)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_HeartbeatReconnectingCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_HeartbeatReconnectingCopyWith(EquipmentEvent_HeartbeatReconnecting value, $Res Function(EquipmentEvent_HeartbeatReconnecting) _then) = _$EquipmentEvent_HeartbeatReconnectingCopyWithImpl;
@useResult
$Res call({
 String deviceType, String deviceId, int attempt, int maxAttempts
});




}
/// @nodoc
class _$EquipmentEvent_HeartbeatReconnectingCopyWithImpl<$Res>
    implements $EquipmentEvent_HeartbeatReconnectingCopyWith<$Res> {
  _$EquipmentEvent_HeartbeatReconnectingCopyWithImpl(this._self, this._then);

  final EquipmentEvent_HeartbeatReconnecting _self;
  final $Res Function(EquipmentEvent_HeartbeatReconnecting) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceType = null,Object? deviceId = null,Object? attempt = null,Object? maxAttempts = null,}) {
  return _then(EquipmentEvent_HeartbeatReconnecting(
deviceType: null == deviceType ? _self.deviceType : deviceType // ignore: cast_nullable_to_non_nullable
as String,deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,attempt: null == attempt ? _self.attempt : attempt // ignore: cast_nullable_to_non_nullable
as int,maxAttempts: null == maxAttempts ? _self.maxAttempts : maxAttempts // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class EquipmentEvent_HeartbeatReconnected extends EquipmentEvent {
  const EquipmentEvent_HeartbeatReconnected({required this.deviceType, required this.deviceId, required this.afterAttempts}): super._();
  

 final  String deviceType;
 final  String deviceId;
 final  int afterAttempts;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_HeartbeatReconnectedCopyWith<EquipmentEvent_HeartbeatReconnected> get copyWith => _$EquipmentEvent_HeartbeatReconnectedCopyWithImpl<EquipmentEvent_HeartbeatReconnected>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_HeartbeatReconnected&&(identical(other.deviceType, deviceType) || other.deviceType == deviceType)&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.afterAttempts, afterAttempts) || other.afterAttempts == afterAttempts));
}


@override
int get hashCode => Object.hash(runtimeType,deviceType,deviceId,afterAttempts);

@override
String toString() {
  return 'EquipmentEvent.heartbeatReconnected(deviceType: $deviceType, deviceId: $deviceId, afterAttempts: $afterAttempts)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_HeartbeatReconnectedCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_HeartbeatReconnectedCopyWith(EquipmentEvent_HeartbeatReconnected value, $Res Function(EquipmentEvent_HeartbeatReconnected) _then) = _$EquipmentEvent_HeartbeatReconnectedCopyWithImpl;
@useResult
$Res call({
 String deviceType, String deviceId, int afterAttempts
});




}
/// @nodoc
class _$EquipmentEvent_HeartbeatReconnectedCopyWithImpl<$Res>
    implements $EquipmentEvent_HeartbeatReconnectedCopyWith<$Res> {
  _$EquipmentEvent_HeartbeatReconnectedCopyWithImpl(this._self, this._then);

  final EquipmentEvent_HeartbeatReconnected _self;
  final $Res Function(EquipmentEvent_HeartbeatReconnected) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceType = null,Object? deviceId = null,Object? afterAttempts = null,}) {
  return _then(EquipmentEvent_HeartbeatReconnected(
deviceType: null == deviceType ? _self.deviceType : deviceType // ignore: cast_nullable_to_non_nullable
as String,deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,afterAttempts: null == afterAttempts ? _self.afterAttempts : afterAttempts // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class EquipmentEvent_DeviceDiscovered extends EquipmentEvent {
  const EquipmentEvent_DeviceDiscovered({required this.deviceClass, required this.driver, required this.id, required this.name, required this.displayName, this.uniqueId}): super._();
  

/// Canonical device class (`camera`, `mount`, `focuser`, `filterWheel`,
/// `rotator`, …).
 final  String deviceClass;
/// Driver backend (`native`, `ascom`, `alpaca`, `indi`, `simulator`).
 final  String driver;
/// Backend-scoped device id used to connect.
 final  String id;
/// Raw device name as reported by the SDK / driver.
 final  String name;
/// User-facing display name (may equal `name`).
 final  String displayName;
/// Stable hardware identity (USB serial, etc.) when the backend exposes
/// one; `None` otherwise.
 final  String? uniqueId;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_DeviceDiscoveredCopyWith<EquipmentEvent_DeviceDiscovered> get copyWith => _$EquipmentEvent_DeviceDiscoveredCopyWithImpl<EquipmentEvent_DeviceDiscovered>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_DeviceDiscovered&&(identical(other.deviceClass, deviceClass) || other.deviceClass == deviceClass)&&(identical(other.driver, driver) || other.driver == driver)&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.displayName, displayName) || other.displayName == displayName)&&(identical(other.uniqueId, uniqueId) || other.uniqueId == uniqueId));
}


@override
int get hashCode => Object.hash(runtimeType,deviceClass,driver,id,name,displayName,uniqueId);

@override
String toString() {
  return 'EquipmentEvent.deviceDiscovered(deviceClass: $deviceClass, driver: $driver, id: $id, name: $name, displayName: $displayName, uniqueId: $uniqueId)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_DeviceDiscoveredCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_DeviceDiscoveredCopyWith(EquipmentEvent_DeviceDiscovered value, $Res Function(EquipmentEvent_DeviceDiscovered) _then) = _$EquipmentEvent_DeviceDiscoveredCopyWithImpl;
@useResult
$Res call({
 String deviceClass, String driver, String id, String name, String displayName, String? uniqueId
});




}
/// @nodoc
class _$EquipmentEvent_DeviceDiscoveredCopyWithImpl<$Res>
    implements $EquipmentEvent_DeviceDiscoveredCopyWith<$Res> {
  _$EquipmentEvent_DeviceDiscoveredCopyWithImpl(this._self, this._then);

  final EquipmentEvent_DeviceDiscovered _self;
  final $Res Function(EquipmentEvent_DeviceDiscovered) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceClass = null,Object? driver = null,Object? id = null,Object? name = null,Object? displayName = null,Object? uniqueId = freezed,}) {
  return _then(EquipmentEvent_DeviceDiscovered(
deviceClass: null == deviceClass ? _self.deviceClass : deviceClass // ignore: cast_nullable_to_non_nullable
as String,driver: null == driver ? _self.driver : driver // ignore: cast_nullable_to_non_nullable
as String,id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,displayName: null == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String,uniqueId: freezed == uniqueId ? _self.uniqueId : uniqueId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class EquipmentEvent_DeviceLost extends EquipmentEvent {
  const EquipmentEvent_DeviceLost({required this.deviceClass, required this.driver, required this.id}): super._();
  

 final  String deviceClass;
 final  String driver;
 final  String id;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentEvent_DeviceLostCopyWith<EquipmentEvent_DeviceLost> get copyWith => _$EquipmentEvent_DeviceLostCopyWithImpl<EquipmentEvent_DeviceLost>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentEvent_DeviceLost&&(identical(other.deviceClass, deviceClass) || other.deviceClass == deviceClass)&&(identical(other.driver, driver) || other.driver == driver)&&(identical(other.id, id) || other.id == id));
}


@override
int get hashCode => Object.hash(runtimeType,deviceClass,driver,id);

@override
String toString() {
  return 'EquipmentEvent.deviceLost(deviceClass: $deviceClass, driver: $driver, id: $id)';
}


}

/// @nodoc
abstract mixin class $EquipmentEvent_DeviceLostCopyWith<$Res> implements $EquipmentEventCopyWith<$Res> {
  factory $EquipmentEvent_DeviceLostCopyWith(EquipmentEvent_DeviceLost value, $Res Function(EquipmentEvent_DeviceLost) _then) = _$EquipmentEvent_DeviceLostCopyWithImpl;
@useResult
$Res call({
 String deviceClass, String driver, String id
});




}
/// @nodoc
class _$EquipmentEvent_DeviceLostCopyWithImpl<$Res>
    implements $EquipmentEvent_DeviceLostCopyWith<$Res> {
  _$EquipmentEvent_DeviceLostCopyWithImpl(this._self, this._then);

  final EquipmentEvent_DeviceLost _self;
  final $Res Function(EquipmentEvent_DeviceLost) _then;

/// Create a copy of EquipmentEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceClass = null,Object? driver = null,Object? id = null,}) {
  return _then(EquipmentEvent_DeviceLost(
deviceClass: null == deviceClass ? _self.deviceClass : deviceClass // ignore: cast_nullable_to_non_nullable
as String,driver: null == driver ? _self.driver : driver // ignore: cast_nullable_to_non_nullable
as String,id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
