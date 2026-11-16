// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'centering.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ApiCenteringStep {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ApiCenteringStep);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ApiCenteringStep()';
}


}

/// @nodoc
class $ApiCenteringStepCopyWith<$Res>  {
$ApiCenteringStepCopyWith(ApiCenteringStep _, $Res Function(ApiCenteringStep) __);
}


/// Adds pattern-matching-related methods to [ApiCenteringStep].
extension ApiCenteringStepPatterns on ApiCenteringStep {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( ApiCenteringStep_Capturing value)?  capturing,TResult Function( ApiCenteringStep_Solved value)?  solved,TResult Function( ApiCenteringStep_Correcting value)?  correcting,TResult Function( ApiCenteringStep_Finished value)?  finished,required TResult orElse(),}){
final _that = this;
switch (_that) {
case ApiCenteringStep_Capturing() when capturing != null:
return capturing(_that);case ApiCenteringStep_Solved() when solved != null:
return solved(_that);case ApiCenteringStep_Correcting() when correcting != null:
return correcting(_that);case ApiCenteringStep_Finished() when finished != null:
return finished(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( ApiCenteringStep_Capturing value)  capturing,required TResult Function( ApiCenteringStep_Solved value)  solved,required TResult Function( ApiCenteringStep_Correcting value)  correcting,required TResult Function( ApiCenteringStep_Finished value)  finished,}){
final _that = this;
switch (_that) {
case ApiCenteringStep_Capturing():
return capturing(_that);case ApiCenteringStep_Solved():
return solved(_that);case ApiCenteringStep_Correcting():
return correcting(_that);case ApiCenteringStep_Finished():
return finished(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( ApiCenteringStep_Capturing value)?  capturing,TResult? Function( ApiCenteringStep_Solved value)?  solved,TResult? Function( ApiCenteringStep_Correcting value)?  correcting,TResult? Function( ApiCenteringStep_Finished value)?  finished,}){
final _that = this;
switch (_that) {
case ApiCenteringStep_Capturing() when capturing != null:
return capturing(_that);case ApiCenteringStep_Solved() when solved != null:
return solved(_that);case ApiCenteringStep_Correcting() when correcting != null:
return correcting(_that);case ApiCenteringStep_Finished() when finished != null:
return finished(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( int attempt)?  capturing,TResult Function( int attempt,  double raHours,  double decDegrees,  double separationArcsec)?  solved,TResult Function( int attempt)?  correcting,TResult Function( bool centered,  bool cancelled,  String message)?  finished,required TResult orElse(),}) {final _that = this;
switch (_that) {
case ApiCenteringStep_Capturing() when capturing != null:
return capturing(_that.attempt);case ApiCenteringStep_Solved() when solved != null:
return solved(_that.attempt,_that.raHours,_that.decDegrees,_that.separationArcsec);case ApiCenteringStep_Correcting() when correcting != null:
return correcting(_that.attempt);case ApiCenteringStep_Finished() when finished != null:
return finished(_that.centered,_that.cancelled,_that.message);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( int attempt)  capturing,required TResult Function( int attempt,  double raHours,  double decDegrees,  double separationArcsec)  solved,required TResult Function( int attempt)  correcting,required TResult Function( bool centered,  bool cancelled,  String message)  finished,}) {final _that = this;
switch (_that) {
case ApiCenteringStep_Capturing():
return capturing(_that.attempt);case ApiCenteringStep_Solved():
return solved(_that.attempt,_that.raHours,_that.decDegrees,_that.separationArcsec);case ApiCenteringStep_Correcting():
return correcting(_that.attempt);case ApiCenteringStep_Finished():
return finished(_that.centered,_that.cancelled,_that.message);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( int attempt)?  capturing,TResult? Function( int attempt,  double raHours,  double decDegrees,  double separationArcsec)?  solved,TResult? Function( int attempt)?  correcting,TResult? Function( bool centered,  bool cancelled,  String message)?  finished,}) {final _that = this;
switch (_that) {
case ApiCenteringStep_Capturing() when capturing != null:
return capturing(_that.attempt);case ApiCenteringStep_Solved() when solved != null:
return solved(_that.attempt,_that.raHours,_that.decDegrees,_that.separationArcsec);case ApiCenteringStep_Correcting() when correcting != null:
return correcting(_that.attempt);case ApiCenteringStep_Finished() when finished != null:
return finished(_that.centered,_that.cancelled,_that.message);case _:
  return null;

}
}

}

/// @nodoc


class ApiCenteringStep_Capturing extends ApiCenteringStep {
  const ApiCenteringStep_Capturing({required this.attempt}): super._();
  

 final  int attempt;

/// Create a copy of ApiCenteringStep
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ApiCenteringStep_CapturingCopyWith<ApiCenteringStep_Capturing> get copyWith => _$ApiCenteringStep_CapturingCopyWithImpl<ApiCenteringStep_Capturing>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ApiCenteringStep_Capturing&&(identical(other.attempt, attempt) || other.attempt == attempt));
}


@override
int get hashCode => Object.hash(runtimeType,attempt);

@override
String toString() {
  return 'ApiCenteringStep.capturing(attempt: $attempt)';
}


}

/// @nodoc
abstract mixin class $ApiCenteringStep_CapturingCopyWith<$Res> implements $ApiCenteringStepCopyWith<$Res> {
  factory $ApiCenteringStep_CapturingCopyWith(ApiCenteringStep_Capturing value, $Res Function(ApiCenteringStep_Capturing) _then) = _$ApiCenteringStep_CapturingCopyWithImpl;
@useResult
$Res call({
 int attempt
});




}
/// @nodoc
class _$ApiCenteringStep_CapturingCopyWithImpl<$Res>
    implements $ApiCenteringStep_CapturingCopyWith<$Res> {
  _$ApiCenteringStep_CapturingCopyWithImpl(this._self, this._then);

  final ApiCenteringStep_Capturing _self;
  final $Res Function(ApiCenteringStep_Capturing) _then;

/// Create a copy of ApiCenteringStep
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? attempt = null,}) {
  return _then(ApiCenteringStep_Capturing(
attempt: null == attempt ? _self.attempt : attempt // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class ApiCenteringStep_Solved extends ApiCenteringStep {
  const ApiCenteringStep_Solved({required this.attempt, required this.raHours, required this.decDegrees, required this.separationArcsec}): super._();
  

 final  int attempt;
 final  double raHours;
 final  double decDegrees;
 final  double separationArcsec;

/// Create a copy of ApiCenteringStep
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ApiCenteringStep_SolvedCopyWith<ApiCenteringStep_Solved> get copyWith => _$ApiCenteringStep_SolvedCopyWithImpl<ApiCenteringStep_Solved>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ApiCenteringStep_Solved&&(identical(other.attempt, attempt) || other.attempt == attempt)&&(identical(other.raHours, raHours) || other.raHours == raHours)&&(identical(other.decDegrees, decDegrees) || other.decDegrees == decDegrees)&&(identical(other.separationArcsec, separationArcsec) || other.separationArcsec == separationArcsec));
}


@override
int get hashCode => Object.hash(runtimeType,attempt,raHours,decDegrees,separationArcsec);

@override
String toString() {
  return 'ApiCenteringStep.solved(attempt: $attempt, raHours: $raHours, decDegrees: $decDegrees, separationArcsec: $separationArcsec)';
}


}

/// @nodoc
abstract mixin class $ApiCenteringStep_SolvedCopyWith<$Res> implements $ApiCenteringStepCopyWith<$Res> {
  factory $ApiCenteringStep_SolvedCopyWith(ApiCenteringStep_Solved value, $Res Function(ApiCenteringStep_Solved) _then) = _$ApiCenteringStep_SolvedCopyWithImpl;
@useResult
$Res call({
 int attempt, double raHours, double decDegrees, double separationArcsec
});




}
/// @nodoc
class _$ApiCenteringStep_SolvedCopyWithImpl<$Res>
    implements $ApiCenteringStep_SolvedCopyWith<$Res> {
  _$ApiCenteringStep_SolvedCopyWithImpl(this._self, this._then);

  final ApiCenteringStep_Solved _self;
  final $Res Function(ApiCenteringStep_Solved) _then;

/// Create a copy of ApiCenteringStep
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? attempt = null,Object? raHours = null,Object? decDegrees = null,Object? separationArcsec = null,}) {
  return _then(ApiCenteringStep_Solved(
attempt: null == attempt ? _self.attempt : attempt // ignore: cast_nullable_to_non_nullable
as int,raHours: null == raHours ? _self.raHours : raHours // ignore: cast_nullable_to_non_nullable
as double,decDegrees: null == decDegrees ? _self.decDegrees : decDegrees // ignore: cast_nullable_to_non_nullable
as double,separationArcsec: null == separationArcsec ? _self.separationArcsec : separationArcsec // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class ApiCenteringStep_Correcting extends ApiCenteringStep {
  const ApiCenteringStep_Correcting({required this.attempt}): super._();
  

 final  int attempt;

/// Create a copy of ApiCenteringStep
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ApiCenteringStep_CorrectingCopyWith<ApiCenteringStep_Correcting> get copyWith => _$ApiCenteringStep_CorrectingCopyWithImpl<ApiCenteringStep_Correcting>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ApiCenteringStep_Correcting&&(identical(other.attempt, attempt) || other.attempt == attempt));
}


@override
int get hashCode => Object.hash(runtimeType,attempt);

@override
String toString() {
  return 'ApiCenteringStep.correcting(attempt: $attempt)';
}


}

/// @nodoc
abstract mixin class $ApiCenteringStep_CorrectingCopyWith<$Res> implements $ApiCenteringStepCopyWith<$Res> {
  factory $ApiCenteringStep_CorrectingCopyWith(ApiCenteringStep_Correcting value, $Res Function(ApiCenteringStep_Correcting) _then) = _$ApiCenteringStep_CorrectingCopyWithImpl;
@useResult
$Res call({
 int attempt
});




}
/// @nodoc
class _$ApiCenteringStep_CorrectingCopyWithImpl<$Res>
    implements $ApiCenteringStep_CorrectingCopyWith<$Res> {
  _$ApiCenteringStep_CorrectingCopyWithImpl(this._self, this._then);

  final ApiCenteringStep_Correcting _self;
  final $Res Function(ApiCenteringStep_Correcting) _then;

/// Create a copy of ApiCenteringStep
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? attempt = null,}) {
  return _then(ApiCenteringStep_Correcting(
attempt: null == attempt ? _self.attempt : attempt // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class ApiCenteringStep_Finished extends ApiCenteringStep {
  const ApiCenteringStep_Finished({required this.centered, required this.cancelled, required this.message}): super._();
  

 final  bool centered;
 final  bool cancelled;
/// What happened, in operator words.
 final  String message;

/// Create a copy of ApiCenteringStep
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ApiCenteringStep_FinishedCopyWith<ApiCenteringStep_Finished> get copyWith => _$ApiCenteringStep_FinishedCopyWithImpl<ApiCenteringStep_Finished>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ApiCenteringStep_Finished&&(identical(other.centered, centered) || other.centered == centered)&&(identical(other.cancelled, cancelled) || other.cancelled == cancelled)&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,centered,cancelled,message);

@override
String toString() {
  return 'ApiCenteringStep.finished(centered: $centered, cancelled: $cancelled, message: $message)';
}


}

/// @nodoc
abstract mixin class $ApiCenteringStep_FinishedCopyWith<$Res> implements $ApiCenteringStepCopyWith<$Res> {
  factory $ApiCenteringStep_FinishedCopyWith(ApiCenteringStep_Finished value, $Res Function(ApiCenteringStep_Finished) _then) = _$ApiCenteringStep_FinishedCopyWithImpl;
@useResult
$Res call({
 bool centered, bool cancelled, String message
});




}
/// @nodoc
class _$ApiCenteringStep_FinishedCopyWithImpl<$Res>
    implements $ApiCenteringStep_FinishedCopyWith<$Res> {
  _$ApiCenteringStep_FinishedCopyWithImpl(this._self, this._then);

  final ApiCenteringStep_Finished _self;
  final $Res Function(ApiCenteringStep_Finished) _then;

/// Create a copy of ApiCenteringStep
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? centered = null,Object? cancelled = null,Object? message = null,}) {
  return _then(ApiCenteringStep_Finished(
centered: null == centered ? _self.centered : centered // ignore: cast_nullable_to_non_nullable
as bool,cancelled: null == cancelled ? _self.cancelled : cancelled // ignore: cast_nullable_to_non_nullable
as bool,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
