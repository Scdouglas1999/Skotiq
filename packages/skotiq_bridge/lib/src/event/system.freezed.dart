// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'system.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$SafetyEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SafetyEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SafetyEvent()';
}


}

/// @nodoc
class $SafetyEventCopyWith<$Res>  {
$SafetyEventCopyWith(SafetyEvent _, $Res Function(SafetyEvent) __);
}


/// Adds pattern-matching-related methods to [SafetyEvent].
extension SafetyEventPatterns on SafetyEvent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( SafetyEvent_WeatherUnsafe value)?  weatherUnsafe,TResult Function( SafetyEvent_WeatherSafe value)?  weatherSafe,TResult Function( SafetyEvent_EmergencyStop value)?  emergencyStop,TResult Function( SafetyEvent_ParkInitiated value)?  parkInitiated,TResult Function( SafetyEvent_ParkCompleted value)?  parkCompleted,required TResult orElse(),}){
final _that = this;
switch (_that) {
case SafetyEvent_WeatherUnsafe() when weatherUnsafe != null:
return weatherUnsafe(_that);case SafetyEvent_WeatherSafe() when weatherSafe != null:
return weatherSafe(_that);case SafetyEvent_EmergencyStop() when emergencyStop != null:
return emergencyStop(_that);case SafetyEvent_ParkInitiated() when parkInitiated != null:
return parkInitiated(_that);case SafetyEvent_ParkCompleted() when parkCompleted != null:
return parkCompleted(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( SafetyEvent_WeatherUnsafe value)  weatherUnsafe,required TResult Function( SafetyEvent_WeatherSafe value)  weatherSafe,required TResult Function( SafetyEvent_EmergencyStop value)  emergencyStop,required TResult Function( SafetyEvent_ParkInitiated value)  parkInitiated,required TResult Function( SafetyEvent_ParkCompleted value)  parkCompleted,}){
final _that = this;
switch (_that) {
case SafetyEvent_WeatherUnsafe():
return weatherUnsafe(_that);case SafetyEvent_WeatherSafe():
return weatherSafe(_that);case SafetyEvent_EmergencyStop():
return emergencyStop(_that);case SafetyEvent_ParkInitiated():
return parkInitiated(_that);case SafetyEvent_ParkCompleted():
return parkCompleted(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( SafetyEvent_WeatherUnsafe value)?  weatherUnsafe,TResult? Function( SafetyEvent_WeatherSafe value)?  weatherSafe,TResult? Function( SafetyEvent_EmergencyStop value)?  emergencyStop,TResult? Function( SafetyEvent_ParkInitiated value)?  parkInitiated,TResult? Function( SafetyEvent_ParkCompleted value)?  parkCompleted,}){
final _that = this;
switch (_that) {
case SafetyEvent_WeatherUnsafe() when weatherUnsafe != null:
return weatherUnsafe(_that);case SafetyEvent_WeatherSafe() when weatherSafe != null:
return weatherSafe(_that);case SafetyEvent_EmergencyStop() when emergencyStop != null:
return emergencyStop(_that);case SafetyEvent_ParkInitiated() when parkInitiated != null:
return parkInitiated(_that);case SafetyEvent_ParkCompleted() when parkCompleted != null:
return parkCompleted(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String reason)?  weatherUnsafe,TResult Function()?  weatherSafe,TResult Function( String reason)?  emergencyStop,TResult Function( String reason)?  parkInitiated,TResult Function()?  parkCompleted,required TResult orElse(),}) {final _that = this;
switch (_that) {
case SafetyEvent_WeatherUnsafe() when weatherUnsafe != null:
return weatherUnsafe(_that.reason);case SafetyEvent_WeatherSafe() when weatherSafe != null:
return weatherSafe();case SafetyEvent_EmergencyStop() when emergencyStop != null:
return emergencyStop(_that.reason);case SafetyEvent_ParkInitiated() when parkInitiated != null:
return parkInitiated(_that.reason);case SafetyEvent_ParkCompleted() when parkCompleted != null:
return parkCompleted();case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String reason)  weatherUnsafe,required TResult Function()  weatherSafe,required TResult Function( String reason)  emergencyStop,required TResult Function( String reason)  parkInitiated,required TResult Function()  parkCompleted,}) {final _that = this;
switch (_that) {
case SafetyEvent_WeatherUnsafe():
return weatherUnsafe(_that.reason);case SafetyEvent_WeatherSafe():
return weatherSafe();case SafetyEvent_EmergencyStop():
return emergencyStop(_that.reason);case SafetyEvent_ParkInitiated():
return parkInitiated(_that.reason);case SafetyEvent_ParkCompleted():
return parkCompleted();}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String reason)?  weatherUnsafe,TResult? Function()?  weatherSafe,TResult? Function( String reason)?  emergencyStop,TResult? Function( String reason)?  parkInitiated,TResult? Function()?  parkCompleted,}) {final _that = this;
switch (_that) {
case SafetyEvent_WeatherUnsafe() when weatherUnsafe != null:
return weatherUnsafe(_that.reason);case SafetyEvent_WeatherSafe() when weatherSafe != null:
return weatherSafe();case SafetyEvent_EmergencyStop() when emergencyStop != null:
return emergencyStop(_that.reason);case SafetyEvent_ParkInitiated() when parkInitiated != null:
return parkInitiated(_that.reason);case SafetyEvent_ParkCompleted() when parkCompleted != null:
return parkCompleted();case _:
  return null;

}
}

}

/// @nodoc


class SafetyEvent_WeatherUnsafe extends SafetyEvent {
  const SafetyEvent_WeatherUnsafe({required this.reason}): super._();
  

 final  String reason;

/// Create a copy of SafetyEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SafetyEvent_WeatherUnsafeCopyWith<SafetyEvent_WeatherUnsafe> get copyWith => _$SafetyEvent_WeatherUnsafeCopyWithImpl<SafetyEvent_WeatherUnsafe>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SafetyEvent_WeatherUnsafe&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'SafetyEvent.weatherUnsafe(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $SafetyEvent_WeatherUnsafeCopyWith<$Res> implements $SafetyEventCopyWith<$Res> {
  factory $SafetyEvent_WeatherUnsafeCopyWith(SafetyEvent_WeatherUnsafe value, $Res Function(SafetyEvent_WeatherUnsafe) _then) = _$SafetyEvent_WeatherUnsafeCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$SafetyEvent_WeatherUnsafeCopyWithImpl<$Res>
    implements $SafetyEvent_WeatherUnsafeCopyWith<$Res> {
  _$SafetyEvent_WeatherUnsafeCopyWithImpl(this._self, this._then);

  final SafetyEvent_WeatherUnsafe _self;
  final $Res Function(SafetyEvent_WeatherUnsafe) _then;

/// Create a copy of SafetyEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(SafetyEvent_WeatherUnsafe(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SafetyEvent_WeatherSafe extends SafetyEvent {
  const SafetyEvent_WeatherSafe(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SafetyEvent_WeatherSafe);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SafetyEvent.weatherSafe()';
}


}




/// @nodoc


class SafetyEvent_EmergencyStop extends SafetyEvent {
  const SafetyEvent_EmergencyStop({required this.reason}): super._();
  

 final  String reason;

/// Create a copy of SafetyEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SafetyEvent_EmergencyStopCopyWith<SafetyEvent_EmergencyStop> get copyWith => _$SafetyEvent_EmergencyStopCopyWithImpl<SafetyEvent_EmergencyStop>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SafetyEvent_EmergencyStop&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'SafetyEvent.emergencyStop(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $SafetyEvent_EmergencyStopCopyWith<$Res> implements $SafetyEventCopyWith<$Res> {
  factory $SafetyEvent_EmergencyStopCopyWith(SafetyEvent_EmergencyStop value, $Res Function(SafetyEvent_EmergencyStop) _then) = _$SafetyEvent_EmergencyStopCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$SafetyEvent_EmergencyStopCopyWithImpl<$Res>
    implements $SafetyEvent_EmergencyStopCopyWith<$Res> {
  _$SafetyEvent_EmergencyStopCopyWithImpl(this._self, this._then);

  final SafetyEvent_EmergencyStop _self;
  final $Res Function(SafetyEvent_EmergencyStop) _then;

/// Create a copy of SafetyEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(SafetyEvent_EmergencyStop(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SafetyEvent_ParkInitiated extends SafetyEvent {
  const SafetyEvent_ParkInitiated({required this.reason}): super._();
  

 final  String reason;

/// Create a copy of SafetyEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SafetyEvent_ParkInitiatedCopyWith<SafetyEvent_ParkInitiated> get copyWith => _$SafetyEvent_ParkInitiatedCopyWithImpl<SafetyEvent_ParkInitiated>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SafetyEvent_ParkInitiated&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'SafetyEvent.parkInitiated(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $SafetyEvent_ParkInitiatedCopyWith<$Res> implements $SafetyEventCopyWith<$Res> {
  factory $SafetyEvent_ParkInitiatedCopyWith(SafetyEvent_ParkInitiated value, $Res Function(SafetyEvent_ParkInitiated) _then) = _$SafetyEvent_ParkInitiatedCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$SafetyEvent_ParkInitiatedCopyWithImpl<$Res>
    implements $SafetyEvent_ParkInitiatedCopyWith<$Res> {
  _$SafetyEvent_ParkInitiatedCopyWithImpl(this._self, this._then);

  final SafetyEvent_ParkInitiated _self;
  final $Res Function(SafetyEvent_ParkInitiated) _then;

/// Create a copy of SafetyEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(SafetyEvent_ParkInitiated(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SafetyEvent_ParkCompleted extends SafetyEvent {
  const SafetyEvent_ParkCompleted(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SafetyEvent_ParkCompleted);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SafetyEvent.parkCompleted()';
}


}




/// @nodoc
mixin _$SystemEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SystemEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SystemEvent()';
}


}

/// @nodoc
class $SystemEventCopyWith<$Res>  {
$SystemEventCopyWith(SystemEvent _, $Res Function(SystemEvent) __);
}


/// Adds pattern-matching-related methods to [SystemEvent].
extension SystemEventPatterns on SystemEvent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( SystemEvent_Initialized value)?  initialized,TResult Function( SystemEvent_ShuttingDown value)?  shuttingDown,TResult Function( SystemEvent_Error value)?  error,TResult Function( SystemEvent_DiskSpaceLow value)?  diskSpaceLow,TResult Function( SystemEvent_Notification value)?  notification,TResult Function( SystemEvent_EventsDropped value)?  eventsDropped,required TResult orElse(),}){
final _that = this;
switch (_that) {
case SystemEvent_Initialized() when initialized != null:
return initialized(_that);case SystemEvent_ShuttingDown() when shuttingDown != null:
return shuttingDown(_that);case SystemEvent_Error() when error != null:
return error(_that);case SystemEvent_DiskSpaceLow() when diskSpaceLow != null:
return diskSpaceLow(_that);case SystemEvent_Notification() when notification != null:
return notification(_that);case SystemEvent_EventsDropped() when eventsDropped != null:
return eventsDropped(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( SystemEvent_Initialized value)  initialized,required TResult Function( SystemEvent_ShuttingDown value)  shuttingDown,required TResult Function( SystemEvent_Error value)  error,required TResult Function( SystemEvent_DiskSpaceLow value)  diskSpaceLow,required TResult Function( SystemEvent_Notification value)  notification,required TResult Function( SystemEvent_EventsDropped value)  eventsDropped,}){
final _that = this;
switch (_that) {
case SystemEvent_Initialized():
return initialized(_that);case SystemEvent_ShuttingDown():
return shuttingDown(_that);case SystemEvent_Error():
return error(_that);case SystemEvent_DiskSpaceLow():
return diskSpaceLow(_that);case SystemEvent_Notification():
return notification(_that);case SystemEvent_EventsDropped():
return eventsDropped(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( SystemEvent_Initialized value)?  initialized,TResult? Function( SystemEvent_ShuttingDown value)?  shuttingDown,TResult? Function( SystemEvent_Error value)?  error,TResult? Function( SystemEvent_DiskSpaceLow value)?  diskSpaceLow,TResult? Function( SystemEvent_Notification value)?  notification,TResult? Function( SystemEvent_EventsDropped value)?  eventsDropped,}){
final _that = this;
switch (_that) {
case SystemEvent_Initialized() when initialized != null:
return initialized(_that);case SystemEvent_ShuttingDown() when shuttingDown != null:
return shuttingDown(_that);case SystemEvent_Error() when error != null:
return error(_that);case SystemEvent_DiskSpaceLow() when diskSpaceLow != null:
return diskSpaceLow(_that);case SystemEvent_Notification() when notification != null:
return notification(_that);case SystemEvent_EventsDropped() when eventsDropped != null:
return eventsDropped(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  initialized,TResult Function()?  shuttingDown,TResult Function( String message)?  error,TResult Function( double availableGb)?  diskSpaceLow,TResult Function( String title,  String message,  String level,  List<String>? explicitTransports)?  notification,TResult Function( BigInt droppedCount,  BigInt totalDropped)?  eventsDropped,required TResult orElse(),}) {final _that = this;
switch (_that) {
case SystemEvent_Initialized() when initialized != null:
return initialized();case SystemEvent_ShuttingDown() when shuttingDown != null:
return shuttingDown();case SystemEvent_Error() when error != null:
return error(_that.message);case SystemEvent_DiskSpaceLow() when diskSpaceLow != null:
return diskSpaceLow(_that.availableGb);case SystemEvent_Notification() when notification != null:
return notification(_that.title,_that.message,_that.level,_that.explicitTransports);case SystemEvent_EventsDropped() when eventsDropped != null:
return eventsDropped(_that.droppedCount,_that.totalDropped);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  initialized,required TResult Function()  shuttingDown,required TResult Function( String message)  error,required TResult Function( double availableGb)  diskSpaceLow,required TResult Function( String title,  String message,  String level,  List<String>? explicitTransports)  notification,required TResult Function( BigInt droppedCount,  BigInt totalDropped)  eventsDropped,}) {final _that = this;
switch (_that) {
case SystemEvent_Initialized():
return initialized();case SystemEvent_ShuttingDown():
return shuttingDown();case SystemEvent_Error():
return error(_that.message);case SystemEvent_DiskSpaceLow():
return diskSpaceLow(_that.availableGb);case SystemEvent_Notification():
return notification(_that.title,_that.message,_that.level,_that.explicitTransports);case SystemEvent_EventsDropped():
return eventsDropped(_that.droppedCount,_that.totalDropped);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  initialized,TResult? Function()?  shuttingDown,TResult? Function( String message)?  error,TResult? Function( double availableGb)?  diskSpaceLow,TResult? Function( String title,  String message,  String level,  List<String>? explicitTransports)?  notification,TResult? Function( BigInt droppedCount,  BigInt totalDropped)?  eventsDropped,}) {final _that = this;
switch (_that) {
case SystemEvent_Initialized() when initialized != null:
return initialized();case SystemEvent_ShuttingDown() when shuttingDown != null:
return shuttingDown();case SystemEvent_Error() when error != null:
return error(_that.message);case SystemEvent_DiskSpaceLow() when diskSpaceLow != null:
return diskSpaceLow(_that.availableGb);case SystemEvent_Notification() when notification != null:
return notification(_that.title,_that.message,_that.level,_that.explicitTransports);case SystemEvent_EventsDropped() when eventsDropped != null:
return eventsDropped(_that.droppedCount,_that.totalDropped);case _:
  return null;

}
}

}

/// @nodoc


class SystemEvent_Initialized extends SystemEvent {
  const SystemEvent_Initialized(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SystemEvent_Initialized);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SystemEvent.initialized()';
}


}




/// @nodoc


class SystemEvent_ShuttingDown extends SystemEvent {
  const SystemEvent_ShuttingDown(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SystemEvent_ShuttingDown);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SystemEvent.shuttingDown()';
}


}




/// @nodoc


class SystemEvent_Error extends SystemEvent {
  const SystemEvent_Error({required this.message}): super._();
  

 final  String message;

/// Create a copy of SystemEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SystemEvent_ErrorCopyWith<SystemEvent_Error> get copyWith => _$SystemEvent_ErrorCopyWithImpl<SystemEvent_Error>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SystemEvent_Error&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,message);

@override
String toString() {
  return 'SystemEvent.error(message: $message)';
}


}

/// @nodoc
abstract mixin class $SystemEvent_ErrorCopyWith<$Res> implements $SystemEventCopyWith<$Res> {
  factory $SystemEvent_ErrorCopyWith(SystemEvent_Error value, $Res Function(SystemEvent_Error) _then) = _$SystemEvent_ErrorCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$SystemEvent_ErrorCopyWithImpl<$Res>
    implements $SystemEvent_ErrorCopyWith<$Res> {
  _$SystemEvent_ErrorCopyWithImpl(this._self, this._then);

  final SystemEvent_Error _self;
  final $Res Function(SystemEvent_Error) _then;

/// Create a copy of SystemEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(SystemEvent_Error(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SystemEvent_DiskSpaceLow extends SystemEvent {
  const SystemEvent_DiskSpaceLow({required this.availableGb}): super._();
  

 final  double availableGb;

/// Create a copy of SystemEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SystemEvent_DiskSpaceLowCopyWith<SystemEvent_DiskSpaceLow> get copyWith => _$SystemEvent_DiskSpaceLowCopyWithImpl<SystemEvent_DiskSpaceLow>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SystemEvent_DiskSpaceLow&&(identical(other.availableGb, availableGb) || other.availableGb == availableGb));
}


@override
int get hashCode => Object.hash(runtimeType,availableGb);

@override
String toString() {
  return 'SystemEvent.diskSpaceLow(availableGb: $availableGb)';
}


}

/// @nodoc
abstract mixin class $SystemEvent_DiskSpaceLowCopyWith<$Res> implements $SystemEventCopyWith<$Res> {
  factory $SystemEvent_DiskSpaceLowCopyWith(SystemEvent_DiskSpaceLow value, $Res Function(SystemEvent_DiskSpaceLow) _then) = _$SystemEvent_DiskSpaceLowCopyWithImpl;
@useResult
$Res call({
 double availableGb
});




}
/// @nodoc
class _$SystemEvent_DiskSpaceLowCopyWithImpl<$Res>
    implements $SystemEvent_DiskSpaceLowCopyWith<$Res> {
  _$SystemEvent_DiskSpaceLowCopyWithImpl(this._self, this._then);

  final SystemEvent_DiskSpaceLow _self;
  final $Res Function(SystemEvent_DiskSpaceLow) _then;

/// Create a copy of SystemEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? availableGb = null,}) {
  return _then(SystemEvent_DiskSpaceLow(
availableGb: null == availableGb ? _self.availableGb : availableGb // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class SystemEvent_Notification extends SystemEvent {
  const SystemEvent_Notification({required this.title, required this.message, required this.level, final  List<String>? explicitTransports}): _explicitTransports = explicitTransports,super._();
  

 final  String title;
 final  String message;
 final  String level;
/// per-NotificationNode override list of
/// NotificationTransportKind names (Dart enum, serialised as strings).
/// The Dart NotificationRouter consumes this field to bypass the
/// matrix's `custom` rule and dispatch to the user-picked transports
/// directly. `None` or empty = use matrix routing.
 final  List<String>? _explicitTransports;
/// per-NotificationNode override list of
/// NotificationTransportKind names (Dart enum, serialised as strings).
/// The Dart NotificationRouter consumes this field to bypass the
/// matrix's `custom` rule and dispatch to the user-picked transports
/// directly. `None` or empty = use matrix routing.
 List<String>? get explicitTransports {
  final value = _explicitTransports;
  if (value == null) return null;
  if (_explicitTransports is EqualUnmodifiableListView) return _explicitTransports;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}


/// Create a copy of SystemEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SystemEvent_NotificationCopyWith<SystemEvent_Notification> get copyWith => _$SystemEvent_NotificationCopyWithImpl<SystemEvent_Notification>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SystemEvent_Notification&&(identical(other.title, title) || other.title == title)&&(identical(other.message, message) || other.message == message)&&(identical(other.level, level) || other.level == level)&&const DeepCollectionEquality().equals(other._explicitTransports, _explicitTransports));
}


@override
int get hashCode => Object.hash(runtimeType,title,message,level,const DeepCollectionEquality().hash(_explicitTransports));

@override
String toString() {
  return 'SystemEvent.notification(title: $title, message: $message, level: $level, explicitTransports: $explicitTransports)';
}


}

/// @nodoc
abstract mixin class $SystemEvent_NotificationCopyWith<$Res> implements $SystemEventCopyWith<$Res> {
  factory $SystemEvent_NotificationCopyWith(SystemEvent_Notification value, $Res Function(SystemEvent_Notification) _then) = _$SystemEvent_NotificationCopyWithImpl;
@useResult
$Res call({
 String title, String message, String level, List<String>? explicitTransports
});




}
/// @nodoc
class _$SystemEvent_NotificationCopyWithImpl<$Res>
    implements $SystemEvent_NotificationCopyWith<$Res> {
  _$SystemEvent_NotificationCopyWithImpl(this._self, this._then);

  final SystemEvent_Notification _self;
  final $Res Function(SystemEvent_Notification) _then;

/// Create a copy of SystemEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? title = null,Object? message = null,Object? level = null,Object? explicitTransports = freezed,}) {
  return _then(SystemEvent_Notification(
title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,level: null == level ? _self.level : level // ignore: cast_nullable_to_non_nullable
as String,explicitTransports: freezed == explicitTransports ? _self._explicitTransports : explicitTransports // ignore: cast_nullable_to_non_nullable
as List<String>?,
  ));
}


}

/// @nodoc


class SystemEvent_EventsDropped extends SystemEvent {
  const SystemEvent_EventsDropped({required this.droppedCount, required this.totalDropped}): super._();
  

/// Number of events that were dropped/skipped
 final  BigInt droppedCount;
/// Total number of events dropped since app start
 final  BigInt totalDropped;

/// Create a copy of SystemEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SystemEvent_EventsDroppedCopyWith<SystemEvent_EventsDropped> get copyWith => _$SystemEvent_EventsDroppedCopyWithImpl<SystemEvent_EventsDropped>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SystemEvent_EventsDropped&&(identical(other.droppedCount, droppedCount) || other.droppedCount == droppedCount)&&(identical(other.totalDropped, totalDropped) || other.totalDropped == totalDropped));
}


@override
int get hashCode => Object.hash(runtimeType,droppedCount,totalDropped);

@override
String toString() {
  return 'SystemEvent.eventsDropped(droppedCount: $droppedCount, totalDropped: $totalDropped)';
}


}

/// @nodoc
abstract mixin class $SystemEvent_EventsDroppedCopyWith<$Res> implements $SystemEventCopyWith<$Res> {
  factory $SystemEvent_EventsDroppedCopyWith(SystemEvent_EventsDropped value, $Res Function(SystemEvent_EventsDropped) _then) = _$SystemEvent_EventsDroppedCopyWithImpl;
@useResult
$Res call({
 BigInt droppedCount, BigInt totalDropped
});




}
/// @nodoc
class _$SystemEvent_EventsDroppedCopyWithImpl<$Res>
    implements $SystemEvent_EventsDroppedCopyWith<$Res> {
  _$SystemEvent_EventsDroppedCopyWithImpl(this._self, this._then);

  final SystemEvent_EventsDropped _self;
  final $Res Function(SystemEvent_EventsDropped) _then;

/// Create a copy of SystemEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? droppedCount = null,Object? totalDropped = null,}) {
  return _then(SystemEvent_EventsDropped(
droppedCount: null == droppedCount ? _self.droppedCount : droppedCount // ignore: cast_nullable_to_non_nullable
as BigInt,totalDropped: null == totalDropped ? _self.totalDropped : totalDropped // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

// dart format on
