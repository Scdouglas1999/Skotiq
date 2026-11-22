// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'guider.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$GuiderActivity {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuiderActivity);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuiderActivity()';
}


}

/// @nodoc
class $GuiderActivityCopyWith<$Res>  {
$GuiderActivityCopyWith(GuiderActivity _, $Res Function(GuiderActivity) __);
}


/// Adds pattern-matching-related methods to [GuiderActivity].
extension GuiderActivityPatterns on GuiderActivity {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( GuiderActivity_Disconnected value)?  disconnected,TResult Function( GuiderActivity_Connected value)?  connected,TResult Function( GuiderActivity_Stopped value)?  stopped,TResult Function( GuiderActivity_Calibrating value)?  calibrating,TResult Function( GuiderActivity_Guiding value)?  guiding,TResult Function( GuiderActivity_Looping value)?  looping,TResult Function( GuiderActivity_Paused value)?  paused,TResult Function( GuiderActivity_Settling value)?  settling,TResult Function( GuiderActivity_LostLock value)?  lostLock,TResult Function( GuiderActivity_Unknown value)?  unknown,required TResult orElse(),}){
final _that = this;
switch (_that) {
case GuiderActivity_Disconnected() when disconnected != null:
return disconnected(_that);case GuiderActivity_Connected() when connected != null:
return connected(_that);case GuiderActivity_Stopped() when stopped != null:
return stopped(_that);case GuiderActivity_Calibrating() when calibrating != null:
return calibrating(_that);case GuiderActivity_Guiding() when guiding != null:
return guiding(_that);case GuiderActivity_Looping() when looping != null:
return looping(_that);case GuiderActivity_Paused() when paused != null:
return paused(_that);case GuiderActivity_Settling() when settling != null:
return settling(_that);case GuiderActivity_LostLock() when lostLock != null:
return lostLock(_that);case GuiderActivity_Unknown() when unknown != null:
return unknown(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( GuiderActivity_Disconnected value)  disconnected,required TResult Function( GuiderActivity_Connected value)  connected,required TResult Function( GuiderActivity_Stopped value)  stopped,required TResult Function( GuiderActivity_Calibrating value)  calibrating,required TResult Function( GuiderActivity_Guiding value)  guiding,required TResult Function( GuiderActivity_Looping value)  looping,required TResult Function( GuiderActivity_Paused value)  paused,required TResult Function( GuiderActivity_Settling value)  settling,required TResult Function( GuiderActivity_LostLock value)  lostLock,required TResult Function( GuiderActivity_Unknown value)  unknown,}){
final _that = this;
switch (_that) {
case GuiderActivity_Disconnected():
return disconnected(_that);case GuiderActivity_Connected():
return connected(_that);case GuiderActivity_Stopped():
return stopped(_that);case GuiderActivity_Calibrating():
return calibrating(_that);case GuiderActivity_Guiding():
return guiding(_that);case GuiderActivity_Looping():
return looping(_that);case GuiderActivity_Paused():
return paused(_that);case GuiderActivity_Settling():
return settling(_that);case GuiderActivity_LostLock():
return lostLock(_that);case GuiderActivity_Unknown():
return unknown(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( GuiderActivity_Disconnected value)?  disconnected,TResult? Function( GuiderActivity_Connected value)?  connected,TResult? Function( GuiderActivity_Stopped value)?  stopped,TResult? Function( GuiderActivity_Calibrating value)?  calibrating,TResult? Function( GuiderActivity_Guiding value)?  guiding,TResult? Function( GuiderActivity_Looping value)?  looping,TResult? Function( GuiderActivity_Paused value)?  paused,TResult? Function( GuiderActivity_Settling value)?  settling,TResult? Function( GuiderActivity_LostLock value)?  lostLock,TResult? Function( GuiderActivity_Unknown value)?  unknown,}){
final _that = this;
switch (_that) {
case GuiderActivity_Disconnected() when disconnected != null:
return disconnected(_that);case GuiderActivity_Connected() when connected != null:
return connected(_that);case GuiderActivity_Stopped() when stopped != null:
return stopped(_that);case GuiderActivity_Calibrating() when calibrating != null:
return calibrating(_that);case GuiderActivity_Guiding() when guiding != null:
return guiding(_that);case GuiderActivity_Looping() when looping != null:
return looping(_that);case GuiderActivity_Paused() when paused != null:
return paused(_that);case GuiderActivity_Settling() when settling != null:
return settling(_that);case GuiderActivity_LostLock() when lostLock != null:
return lostLock(_that);case GuiderActivity_Unknown() when unknown != null:
return unknown(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  disconnected,TResult Function()?  connected,TResult Function()?  stopped,TResult Function()?  calibrating,TResult Function()?  guiding,TResult Function()?  looping,TResult Function()?  paused,TResult Function()?  settling,TResult Function()?  lostLock,TResult Function( String field0)?  unknown,required TResult orElse(),}) {final _that = this;
switch (_that) {
case GuiderActivity_Disconnected() when disconnected != null:
return disconnected();case GuiderActivity_Connected() when connected != null:
return connected();case GuiderActivity_Stopped() when stopped != null:
return stopped();case GuiderActivity_Calibrating() when calibrating != null:
return calibrating();case GuiderActivity_Guiding() when guiding != null:
return guiding();case GuiderActivity_Looping() when looping != null:
return looping();case GuiderActivity_Paused() when paused != null:
return paused();case GuiderActivity_Settling() when settling != null:
return settling();case GuiderActivity_LostLock() when lostLock != null:
return lostLock();case GuiderActivity_Unknown() when unknown != null:
return unknown(_that.field0);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  disconnected,required TResult Function()  connected,required TResult Function()  stopped,required TResult Function()  calibrating,required TResult Function()  guiding,required TResult Function()  looping,required TResult Function()  paused,required TResult Function()  settling,required TResult Function()  lostLock,required TResult Function( String field0)  unknown,}) {final _that = this;
switch (_that) {
case GuiderActivity_Disconnected():
return disconnected();case GuiderActivity_Connected():
return connected();case GuiderActivity_Stopped():
return stopped();case GuiderActivity_Calibrating():
return calibrating();case GuiderActivity_Guiding():
return guiding();case GuiderActivity_Looping():
return looping();case GuiderActivity_Paused():
return paused();case GuiderActivity_Settling():
return settling();case GuiderActivity_LostLock():
return lostLock();case GuiderActivity_Unknown():
return unknown(_that.field0);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  disconnected,TResult? Function()?  connected,TResult? Function()?  stopped,TResult? Function()?  calibrating,TResult? Function()?  guiding,TResult? Function()?  looping,TResult? Function()?  paused,TResult? Function()?  settling,TResult? Function()?  lostLock,TResult? Function( String field0)?  unknown,}) {final _that = this;
switch (_that) {
case GuiderActivity_Disconnected() when disconnected != null:
return disconnected();case GuiderActivity_Connected() when connected != null:
return connected();case GuiderActivity_Stopped() when stopped != null:
return stopped();case GuiderActivity_Calibrating() when calibrating != null:
return calibrating();case GuiderActivity_Guiding() when guiding != null:
return guiding();case GuiderActivity_Looping() when looping != null:
return looping();case GuiderActivity_Paused() when paused != null:
return paused();case GuiderActivity_Settling() when settling != null:
return settling();case GuiderActivity_LostLock() when lostLock != null:
return lostLock();case GuiderActivity_Unknown() when unknown != null:
return unknown(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class GuiderActivity_Disconnected extends GuiderActivity {
  const GuiderActivity_Disconnected(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuiderActivity_Disconnected);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuiderActivity.disconnected()';
}


}




/// @nodoc


class GuiderActivity_Connected extends GuiderActivity {
  const GuiderActivity_Connected(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuiderActivity_Connected);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuiderActivity.connected()';
}


}




/// @nodoc


class GuiderActivity_Stopped extends GuiderActivity {
  const GuiderActivity_Stopped(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuiderActivity_Stopped);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuiderActivity.stopped()';
}


}




/// @nodoc


class GuiderActivity_Calibrating extends GuiderActivity {
  const GuiderActivity_Calibrating(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuiderActivity_Calibrating);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuiderActivity.calibrating()';
}


}




/// @nodoc


class GuiderActivity_Guiding extends GuiderActivity {
  const GuiderActivity_Guiding(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuiderActivity_Guiding);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuiderActivity.guiding()';
}


}




/// @nodoc


class GuiderActivity_Looping extends GuiderActivity {
  const GuiderActivity_Looping(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuiderActivity_Looping);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuiderActivity.looping()';
}


}




/// @nodoc


class GuiderActivity_Paused extends GuiderActivity {
  const GuiderActivity_Paused(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuiderActivity_Paused);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuiderActivity.paused()';
}


}




/// @nodoc


class GuiderActivity_Settling extends GuiderActivity {
  const GuiderActivity_Settling(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuiderActivity_Settling);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuiderActivity.settling()';
}


}




/// @nodoc


class GuiderActivity_LostLock extends GuiderActivity {
  const GuiderActivity_LostLock(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuiderActivity_LostLock);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuiderActivity.lostLock()';
}


}




/// @nodoc


class GuiderActivity_Unknown extends GuiderActivity {
  const GuiderActivity_Unknown(this.field0): super._();
  

 final  String field0;

/// Create a copy of GuiderActivity
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$GuiderActivity_UnknownCopyWith<GuiderActivity_Unknown> get copyWith => _$GuiderActivity_UnknownCopyWithImpl<GuiderActivity_Unknown>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuiderActivity_Unknown&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'GuiderActivity.unknown(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $GuiderActivity_UnknownCopyWith<$Res> implements $GuiderActivityCopyWith<$Res> {
  factory $GuiderActivity_UnknownCopyWith(GuiderActivity_Unknown value, $Res Function(GuiderActivity_Unknown) _then) = _$GuiderActivity_UnknownCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$GuiderActivity_UnknownCopyWithImpl<$Res>
    implements $GuiderActivity_UnknownCopyWith<$Res> {
  _$GuiderActivity_UnknownCopyWithImpl(this._self, this._then);

  final GuiderActivity_Unknown _self;
  final $Res Function(GuiderActivity_Unknown) _then;

/// Create a copy of GuiderActivity
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(GuiderActivity_Unknown(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
