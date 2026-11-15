// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'mount.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$MountMoveGuider {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MountMoveGuider);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'MountMoveGuider()';
}


}

/// @nodoc
class $MountMoveGuiderCopyWith<$Res>  {
$MountMoveGuiderCopyWith(MountMoveGuider _, $Res Function(MountMoveGuider) __);
}


/// Adds pattern-matching-related methods to [MountMoveGuider].
extension MountMoveGuiderPatterns on MountMoveGuider {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( MountMoveGuider_Idle value)?  idle,TResult Function( MountMoveGuider_Stopped value)?  stopped,TResult Function( MountMoveGuider_Unanswered value)?  unanswered,TResult Function( MountMoveGuider_Refused value)?  refused,required TResult orElse(),}){
final _that = this;
switch (_that) {
case MountMoveGuider_Idle() when idle != null:
return idle(_that);case MountMoveGuider_Stopped() when stopped != null:
return stopped(_that);case MountMoveGuider_Unanswered() when unanswered != null:
return unanswered(_that);case MountMoveGuider_Refused() when refused != null:
return refused(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( MountMoveGuider_Idle value)  idle,required TResult Function( MountMoveGuider_Stopped value)  stopped,required TResult Function( MountMoveGuider_Unanswered value)  unanswered,required TResult Function( MountMoveGuider_Refused value)  refused,}){
final _that = this;
switch (_that) {
case MountMoveGuider_Idle():
return idle(_that);case MountMoveGuider_Stopped():
return stopped(_that);case MountMoveGuider_Unanswered():
return unanswered(_that);case MountMoveGuider_Refused():
return refused(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( MountMoveGuider_Idle value)?  idle,TResult? Function( MountMoveGuider_Stopped value)?  stopped,TResult? Function( MountMoveGuider_Unanswered value)?  unanswered,TResult? Function( MountMoveGuider_Refused value)?  refused,}){
final _that = this;
switch (_that) {
case MountMoveGuider_Idle() when idle != null:
return idle(_that);case MountMoveGuider_Stopped() when stopped != null:
return stopped(_that);case MountMoveGuider_Unanswered() when unanswered != null:
return unanswered(_that);case MountMoveGuider_Refused() when refused != null:
return refused(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  idle,TResult Function()?  stopped,TResult Function( String reason)?  unanswered,TResult Function( String reason)?  refused,required TResult orElse(),}) {final _that = this;
switch (_that) {
case MountMoveGuider_Idle() when idle != null:
return idle();case MountMoveGuider_Stopped() when stopped != null:
return stopped();case MountMoveGuider_Unanswered() when unanswered != null:
return unanswered(_that.reason);case MountMoveGuider_Refused() when refused != null:
return refused(_that.reason);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  idle,required TResult Function()  stopped,required TResult Function( String reason)  unanswered,required TResult Function( String reason)  refused,}) {final _that = this;
switch (_that) {
case MountMoveGuider_Idle():
return idle();case MountMoveGuider_Stopped():
return stopped();case MountMoveGuider_Unanswered():
return unanswered(_that.reason);case MountMoveGuider_Refused():
return refused(_that.reason);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  idle,TResult? Function()?  stopped,TResult? Function( String reason)?  unanswered,TResult? Function( String reason)?  refused,}) {final _that = this;
switch (_that) {
case MountMoveGuider_Idle() when idle != null:
return idle();case MountMoveGuider_Stopped() when stopped != null:
return stopped();case MountMoveGuider_Unanswered() when unanswered != null:
return unanswered(_that.reason);case MountMoveGuider_Refused() when refused != null:
return refused(_that.reason);case _:
  return null;

}
}

}

/// @nodoc


class MountMoveGuider_Idle extends MountMoveGuider {
  const MountMoveGuider_Idle(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MountMoveGuider_Idle);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'MountMoveGuider.idle()';
}


}




/// @nodoc


class MountMoveGuider_Stopped extends MountMoveGuider {
  const MountMoveGuider_Stopped(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MountMoveGuider_Stopped);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'MountMoveGuider.stopped()';
}


}




/// @nodoc


class MountMoveGuider_Unanswered extends MountMoveGuider {
  const MountMoveGuider_Unanswered({required this.reason}): super._();
  

 final  String reason;

/// Create a copy of MountMoveGuider
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MountMoveGuider_UnansweredCopyWith<MountMoveGuider_Unanswered> get copyWith => _$MountMoveGuider_UnansweredCopyWithImpl<MountMoveGuider_Unanswered>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MountMoveGuider_Unanswered&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'MountMoveGuider.unanswered(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $MountMoveGuider_UnansweredCopyWith<$Res> implements $MountMoveGuiderCopyWith<$Res> {
  factory $MountMoveGuider_UnansweredCopyWith(MountMoveGuider_Unanswered value, $Res Function(MountMoveGuider_Unanswered) _then) = _$MountMoveGuider_UnansweredCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$MountMoveGuider_UnansweredCopyWithImpl<$Res>
    implements $MountMoveGuider_UnansweredCopyWith<$Res> {
  _$MountMoveGuider_UnansweredCopyWithImpl(this._self, this._then);

  final MountMoveGuider_Unanswered _self;
  final $Res Function(MountMoveGuider_Unanswered) _then;

/// Create a copy of MountMoveGuider
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(MountMoveGuider_Unanswered(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class MountMoveGuider_Refused extends MountMoveGuider {
  const MountMoveGuider_Refused({required this.reason}): super._();
  

 final  String reason;

/// Create a copy of MountMoveGuider
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MountMoveGuider_RefusedCopyWith<MountMoveGuider_Refused> get copyWith => _$MountMoveGuider_RefusedCopyWithImpl<MountMoveGuider_Refused>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MountMoveGuider_Refused&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'MountMoveGuider.refused(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $MountMoveGuider_RefusedCopyWith<$Res> implements $MountMoveGuiderCopyWith<$Res> {
  factory $MountMoveGuider_RefusedCopyWith(MountMoveGuider_Refused value, $Res Function(MountMoveGuider_Refused) _then) = _$MountMoveGuider_RefusedCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$MountMoveGuider_RefusedCopyWithImpl<$Res>
    implements $MountMoveGuider_RefusedCopyWith<$Res> {
  _$MountMoveGuider_RefusedCopyWithImpl(this._self, this._then);

  final MountMoveGuider_Refused _self;
  final $Res Function(MountMoveGuider_Refused) _then;

/// Create a copy of MountMoveGuider
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(MountMoveGuider_Refused(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
