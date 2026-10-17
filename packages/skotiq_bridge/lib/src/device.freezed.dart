// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'device.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$FieldAvailability {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FieldAvailability);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'FieldAvailability()';
}


}

/// @nodoc
class $FieldAvailabilityCopyWith<$Res>  {
$FieldAvailabilityCopyWith(FieldAvailability _, $Res Function(FieldAvailability) __);
}


/// Adds pattern-matching-related methods to [FieldAvailability].
extension FieldAvailabilityPatterns on FieldAvailability {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( FieldAvailability_Available value)?  available,TResult Function( FieldAvailability_Unsupported value)?  unsupported,TResult Function( FieldAvailability_Error value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case FieldAvailability_Available() when available != null:
return available(_that);case FieldAvailability_Unsupported() when unsupported != null:
return unsupported(_that);case FieldAvailability_Error() when error != null:
return error(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( FieldAvailability_Available value)  available,required TResult Function( FieldAvailability_Unsupported value)  unsupported,required TResult Function( FieldAvailability_Error value)  error,}){
final _that = this;
switch (_that) {
case FieldAvailability_Available():
return available(_that);case FieldAvailability_Unsupported():
return unsupported(_that);case FieldAvailability_Error():
return error(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( FieldAvailability_Available value)?  available,TResult? Function( FieldAvailability_Unsupported value)?  unsupported,TResult? Function( FieldAvailability_Error value)?  error,}){
final _that = this;
switch (_that) {
case FieldAvailability_Available() when available != null:
return available(_that);case FieldAvailability_Unsupported() when unsupported != null:
return unsupported(_that);case FieldAvailability_Error() when error != null:
return error(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  available,TResult Function()?  unsupported,TResult Function( String field0)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case FieldAvailability_Available() when available != null:
return available();case FieldAvailability_Unsupported() when unsupported != null:
return unsupported();case FieldAvailability_Error() when error != null:
return error(_that.field0);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  available,required TResult Function()  unsupported,required TResult Function( String field0)  error,}) {final _that = this;
switch (_that) {
case FieldAvailability_Available():
return available();case FieldAvailability_Unsupported():
return unsupported();case FieldAvailability_Error():
return error(_that.field0);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  available,TResult? Function()?  unsupported,TResult? Function( String field0)?  error,}) {final _that = this;
switch (_that) {
case FieldAvailability_Available() when available != null:
return available();case FieldAvailability_Unsupported() when unsupported != null:
return unsupported();case FieldAvailability_Error() when error != null:
return error(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class FieldAvailability_Available extends FieldAvailability {
  const FieldAvailability_Available(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FieldAvailability_Available);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'FieldAvailability.available()';
}


}




/// @nodoc


class FieldAvailability_Unsupported extends FieldAvailability {
  const FieldAvailability_Unsupported(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FieldAvailability_Unsupported);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'FieldAvailability.unsupported()';
}


}




/// @nodoc


class FieldAvailability_Error extends FieldAvailability {
  const FieldAvailability_Error(this.field0): super._();
  

 final  String field0;

/// Create a copy of FieldAvailability
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FieldAvailability_ErrorCopyWith<FieldAvailability_Error> get copyWith => _$FieldAvailability_ErrorCopyWithImpl<FieldAvailability_Error>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FieldAvailability_Error&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'FieldAvailability.error(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $FieldAvailability_ErrorCopyWith<$Res> implements $FieldAvailabilityCopyWith<$Res> {
  factory $FieldAvailability_ErrorCopyWith(FieldAvailability_Error value, $Res Function(FieldAvailability_Error) _then) = _$FieldAvailability_ErrorCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$FieldAvailability_ErrorCopyWithImpl<$Res>
    implements $FieldAvailability_ErrorCopyWith<$Res> {
  _$FieldAvailability_ErrorCopyWithImpl(this._self, this._then);

  final FieldAvailability_Error _self;
  final $Res Function(FieldAvailability_Error) _then;

/// Create a copy of FieldAvailability
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(FieldAvailability_Error(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
