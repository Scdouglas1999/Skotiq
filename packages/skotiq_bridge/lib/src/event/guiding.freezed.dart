// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'guiding.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$GuidingEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuidingEvent()';
}


}

/// @nodoc
class $GuidingEventCopyWith<$Res>  {
$GuidingEventCopyWith(GuidingEvent _, $Res Function(GuidingEvent) __);
}


/// Adds pattern-matching-related methods to [GuidingEvent].
extension GuidingEventPatterns on GuidingEvent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( GuidingEvent_Connected value)?  connected,TResult Function( GuidingEvent_Disconnected value)?  disconnected,TResult Function( GuidingEvent_GuidingStarted value)?  guidingStarted,TResult Function( GuidingEvent_GuidingStopped value)?  guidingStopped,TResult Function( GuidingEvent_Paused value)?  paused,TResult Function( GuidingEvent_Resumed value)?  resumed,TResult Function( GuidingEvent_Settled value)?  settled,TResult Function( GuidingEvent_LostStar value)?  lostStar,TResult Function( GuidingEvent_DitherStarted value)?  ditherStarted,TResult Function( GuidingEvent_DitherCompleted value)?  ditherCompleted,TResult Function( GuidingEvent_Correction value)?  correction,TResult Function( GuidingEvent_Looping value)?  looping,TResult Function( GuidingEvent_Settling value)?  settling,TResult Function( GuidingEvent_Calibrating value)?  calibrating,TResult Function( GuidingEvent_CalibrationComplete value)?  calibrationComplete,TResult Function( GuidingEvent_StarSelected value)?  starSelected,TResult Function( GuidingEvent_AppState value)?  appState,TResult Function( GuidingEvent_GuideStats value)?  guideStats,required TResult orElse(),}){
final _that = this;
switch (_that) {
case GuidingEvent_Connected() when connected != null:
return connected(_that);case GuidingEvent_Disconnected() when disconnected != null:
return disconnected(_that);case GuidingEvent_GuidingStarted() when guidingStarted != null:
return guidingStarted(_that);case GuidingEvent_GuidingStopped() when guidingStopped != null:
return guidingStopped(_that);case GuidingEvent_Paused() when paused != null:
return paused(_that);case GuidingEvent_Resumed() when resumed != null:
return resumed(_that);case GuidingEvent_Settled() when settled != null:
return settled(_that);case GuidingEvent_LostStar() when lostStar != null:
return lostStar(_that);case GuidingEvent_DitherStarted() when ditherStarted != null:
return ditherStarted(_that);case GuidingEvent_DitherCompleted() when ditherCompleted != null:
return ditherCompleted(_that);case GuidingEvent_Correction() when correction != null:
return correction(_that);case GuidingEvent_Looping() when looping != null:
return looping(_that);case GuidingEvent_Settling() when settling != null:
return settling(_that);case GuidingEvent_Calibrating() when calibrating != null:
return calibrating(_that);case GuidingEvent_CalibrationComplete() when calibrationComplete != null:
return calibrationComplete(_that);case GuidingEvent_StarSelected() when starSelected != null:
return starSelected(_that);case GuidingEvent_AppState() when appState != null:
return appState(_that);case GuidingEvent_GuideStats() when guideStats != null:
return guideStats(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( GuidingEvent_Connected value)  connected,required TResult Function( GuidingEvent_Disconnected value)  disconnected,required TResult Function( GuidingEvent_GuidingStarted value)  guidingStarted,required TResult Function( GuidingEvent_GuidingStopped value)  guidingStopped,required TResult Function( GuidingEvent_Paused value)  paused,required TResult Function( GuidingEvent_Resumed value)  resumed,required TResult Function( GuidingEvent_Settled value)  settled,required TResult Function( GuidingEvent_LostStar value)  lostStar,required TResult Function( GuidingEvent_DitherStarted value)  ditherStarted,required TResult Function( GuidingEvent_DitherCompleted value)  ditherCompleted,required TResult Function( GuidingEvent_Correction value)  correction,required TResult Function( GuidingEvent_Looping value)  looping,required TResult Function( GuidingEvent_Settling value)  settling,required TResult Function( GuidingEvent_Calibrating value)  calibrating,required TResult Function( GuidingEvent_CalibrationComplete value)  calibrationComplete,required TResult Function( GuidingEvent_StarSelected value)  starSelected,required TResult Function( GuidingEvent_AppState value)  appState,required TResult Function( GuidingEvent_GuideStats value)  guideStats,}){
final _that = this;
switch (_that) {
case GuidingEvent_Connected():
return connected(_that);case GuidingEvent_Disconnected():
return disconnected(_that);case GuidingEvent_GuidingStarted():
return guidingStarted(_that);case GuidingEvent_GuidingStopped():
return guidingStopped(_that);case GuidingEvent_Paused():
return paused(_that);case GuidingEvent_Resumed():
return resumed(_that);case GuidingEvent_Settled():
return settled(_that);case GuidingEvent_LostStar():
return lostStar(_that);case GuidingEvent_DitherStarted():
return ditherStarted(_that);case GuidingEvent_DitherCompleted():
return ditherCompleted(_that);case GuidingEvent_Correction():
return correction(_that);case GuidingEvent_Looping():
return looping(_that);case GuidingEvent_Settling():
return settling(_that);case GuidingEvent_Calibrating():
return calibrating(_that);case GuidingEvent_CalibrationComplete():
return calibrationComplete(_that);case GuidingEvent_StarSelected():
return starSelected(_that);case GuidingEvent_AppState():
return appState(_that);case GuidingEvent_GuideStats():
return guideStats(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( GuidingEvent_Connected value)?  connected,TResult? Function( GuidingEvent_Disconnected value)?  disconnected,TResult? Function( GuidingEvent_GuidingStarted value)?  guidingStarted,TResult? Function( GuidingEvent_GuidingStopped value)?  guidingStopped,TResult? Function( GuidingEvent_Paused value)?  paused,TResult? Function( GuidingEvent_Resumed value)?  resumed,TResult? Function( GuidingEvent_Settled value)?  settled,TResult? Function( GuidingEvent_LostStar value)?  lostStar,TResult? Function( GuidingEvent_DitherStarted value)?  ditherStarted,TResult? Function( GuidingEvent_DitherCompleted value)?  ditherCompleted,TResult? Function( GuidingEvent_Correction value)?  correction,TResult? Function( GuidingEvent_Looping value)?  looping,TResult? Function( GuidingEvent_Settling value)?  settling,TResult? Function( GuidingEvent_Calibrating value)?  calibrating,TResult? Function( GuidingEvent_CalibrationComplete value)?  calibrationComplete,TResult? Function( GuidingEvent_StarSelected value)?  starSelected,TResult? Function( GuidingEvent_AppState value)?  appState,TResult? Function( GuidingEvent_GuideStats value)?  guideStats,}){
final _that = this;
switch (_that) {
case GuidingEvent_Connected() when connected != null:
return connected(_that);case GuidingEvent_Disconnected() when disconnected != null:
return disconnected(_that);case GuidingEvent_GuidingStarted() when guidingStarted != null:
return guidingStarted(_that);case GuidingEvent_GuidingStopped() when guidingStopped != null:
return guidingStopped(_that);case GuidingEvent_Paused() when paused != null:
return paused(_that);case GuidingEvent_Resumed() when resumed != null:
return resumed(_that);case GuidingEvent_Settled() when settled != null:
return settled(_that);case GuidingEvent_LostStar() when lostStar != null:
return lostStar(_that);case GuidingEvent_DitherStarted() when ditherStarted != null:
return ditherStarted(_that);case GuidingEvent_DitherCompleted() when ditherCompleted != null:
return ditherCompleted(_that);case GuidingEvent_Correction() when correction != null:
return correction(_that);case GuidingEvent_Looping() when looping != null:
return looping(_that);case GuidingEvent_Settling() when settling != null:
return settling(_that);case GuidingEvent_Calibrating() when calibrating != null:
return calibrating(_that);case GuidingEvent_CalibrationComplete() when calibrationComplete != null:
return calibrationComplete(_that);case GuidingEvent_StarSelected() when starSelected != null:
return starSelected(_that);case GuidingEvent_AppState() when appState != null:
return appState(_that);case GuidingEvent_GuideStats() when guideStats != null:
return guideStats(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  connected,TResult Function()?  disconnected,TResult Function()?  guidingStarted,TResult Function()?  guidingStopped,TResult Function()?  paused,TResult Function()?  resumed,TResult Function( double rms)?  settled,TResult Function()?  lostStar,TResult Function( double pixels)?  ditherStarted,TResult Function()?  ditherCompleted,TResult Function( double ra,  double dec,  double raRaw,  double decRaw)?  correction,TResult Function()?  looping,TResult Function()?  settling,TResult Function()?  calibrating,TResult Function()?  calibrationComplete,TResult Function( double x,  double y)?  starSelected,TResult Function( String state)?  appState,TResult Function( double snr,  double starMass)?  guideStats,required TResult orElse(),}) {final _that = this;
switch (_that) {
case GuidingEvent_Connected() when connected != null:
return connected();case GuidingEvent_Disconnected() when disconnected != null:
return disconnected();case GuidingEvent_GuidingStarted() when guidingStarted != null:
return guidingStarted();case GuidingEvent_GuidingStopped() when guidingStopped != null:
return guidingStopped();case GuidingEvent_Paused() when paused != null:
return paused();case GuidingEvent_Resumed() when resumed != null:
return resumed();case GuidingEvent_Settled() when settled != null:
return settled(_that.rms);case GuidingEvent_LostStar() when lostStar != null:
return lostStar();case GuidingEvent_DitherStarted() when ditherStarted != null:
return ditherStarted(_that.pixels);case GuidingEvent_DitherCompleted() when ditherCompleted != null:
return ditherCompleted();case GuidingEvent_Correction() when correction != null:
return correction(_that.ra,_that.dec,_that.raRaw,_that.decRaw);case GuidingEvent_Looping() when looping != null:
return looping();case GuidingEvent_Settling() when settling != null:
return settling();case GuidingEvent_Calibrating() when calibrating != null:
return calibrating();case GuidingEvent_CalibrationComplete() when calibrationComplete != null:
return calibrationComplete();case GuidingEvent_StarSelected() when starSelected != null:
return starSelected(_that.x,_that.y);case GuidingEvent_AppState() when appState != null:
return appState(_that.state);case GuidingEvent_GuideStats() when guideStats != null:
return guideStats(_that.snr,_that.starMass);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  connected,required TResult Function()  disconnected,required TResult Function()  guidingStarted,required TResult Function()  guidingStopped,required TResult Function()  paused,required TResult Function()  resumed,required TResult Function( double rms)  settled,required TResult Function()  lostStar,required TResult Function( double pixels)  ditherStarted,required TResult Function()  ditherCompleted,required TResult Function( double ra,  double dec,  double raRaw,  double decRaw)  correction,required TResult Function()  looping,required TResult Function()  settling,required TResult Function()  calibrating,required TResult Function()  calibrationComplete,required TResult Function( double x,  double y)  starSelected,required TResult Function( String state)  appState,required TResult Function( double snr,  double starMass)  guideStats,}) {final _that = this;
switch (_that) {
case GuidingEvent_Connected():
return connected();case GuidingEvent_Disconnected():
return disconnected();case GuidingEvent_GuidingStarted():
return guidingStarted();case GuidingEvent_GuidingStopped():
return guidingStopped();case GuidingEvent_Paused():
return paused();case GuidingEvent_Resumed():
return resumed();case GuidingEvent_Settled():
return settled(_that.rms);case GuidingEvent_LostStar():
return lostStar();case GuidingEvent_DitherStarted():
return ditherStarted(_that.pixels);case GuidingEvent_DitherCompleted():
return ditherCompleted();case GuidingEvent_Correction():
return correction(_that.ra,_that.dec,_that.raRaw,_that.decRaw);case GuidingEvent_Looping():
return looping();case GuidingEvent_Settling():
return settling();case GuidingEvent_Calibrating():
return calibrating();case GuidingEvent_CalibrationComplete():
return calibrationComplete();case GuidingEvent_StarSelected():
return starSelected(_that.x,_that.y);case GuidingEvent_AppState():
return appState(_that.state);case GuidingEvent_GuideStats():
return guideStats(_that.snr,_that.starMass);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  connected,TResult? Function()?  disconnected,TResult? Function()?  guidingStarted,TResult? Function()?  guidingStopped,TResult? Function()?  paused,TResult? Function()?  resumed,TResult? Function( double rms)?  settled,TResult? Function()?  lostStar,TResult? Function( double pixels)?  ditherStarted,TResult? Function()?  ditherCompleted,TResult? Function( double ra,  double dec,  double raRaw,  double decRaw)?  correction,TResult? Function()?  looping,TResult? Function()?  settling,TResult? Function()?  calibrating,TResult? Function()?  calibrationComplete,TResult? Function( double x,  double y)?  starSelected,TResult? Function( String state)?  appState,TResult? Function( double snr,  double starMass)?  guideStats,}) {final _that = this;
switch (_that) {
case GuidingEvent_Connected() when connected != null:
return connected();case GuidingEvent_Disconnected() when disconnected != null:
return disconnected();case GuidingEvent_GuidingStarted() when guidingStarted != null:
return guidingStarted();case GuidingEvent_GuidingStopped() when guidingStopped != null:
return guidingStopped();case GuidingEvent_Paused() when paused != null:
return paused();case GuidingEvent_Resumed() when resumed != null:
return resumed();case GuidingEvent_Settled() when settled != null:
return settled(_that.rms);case GuidingEvent_LostStar() when lostStar != null:
return lostStar();case GuidingEvent_DitherStarted() when ditherStarted != null:
return ditherStarted(_that.pixels);case GuidingEvent_DitherCompleted() when ditherCompleted != null:
return ditherCompleted();case GuidingEvent_Correction() when correction != null:
return correction(_that.ra,_that.dec,_that.raRaw,_that.decRaw);case GuidingEvent_Looping() when looping != null:
return looping();case GuidingEvent_Settling() when settling != null:
return settling();case GuidingEvent_Calibrating() when calibrating != null:
return calibrating();case GuidingEvent_CalibrationComplete() when calibrationComplete != null:
return calibrationComplete();case GuidingEvent_StarSelected() when starSelected != null:
return starSelected(_that.x,_that.y);case GuidingEvent_AppState() when appState != null:
return appState(_that.state);case GuidingEvent_GuideStats() when guideStats != null:
return guideStats(_that.snr,_that.starMass);case _:
  return null;

}
}

}

/// @nodoc


class GuidingEvent_Connected extends GuidingEvent {
  const GuidingEvent_Connected(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_Connected);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuidingEvent.connected()';
}


}




/// @nodoc


class GuidingEvent_Disconnected extends GuidingEvent {
  const GuidingEvent_Disconnected(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_Disconnected);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuidingEvent.disconnected()';
}


}




/// @nodoc


class GuidingEvent_GuidingStarted extends GuidingEvent {
  const GuidingEvent_GuidingStarted(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_GuidingStarted);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuidingEvent.guidingStarted()';
}


}




/// @nodoc


class GuidingEvent_GuidingStopped extends GuidingEvent {
  const GuidingEvent_GuidingStopped(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_GuidingStopped);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuidingEvent.guidingStopped()';
}


}




/// @nodoc


class GuidingEvent_Paused extends GuidingEvent {
  const GuidingEvent_Paused(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_Paused);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuidingEvent.paused()';
}


}




/// @nodoc


class GuidingEvent_Resumed extends GuidingEvent {
  const GuidingEvent_Resumed(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_Resumed);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuidingEvent.resumed()';
}


}




/// @nodoc


class GuidingEvent_Settled extends GuidingEvent {
  const GuidingEvent_Settled({required this.rms}): super._();
  

 final  double rms;

/// Create a copy of GuidingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$GuidingEvent_SettledCopyWith<GuidingEvent_Settled> get copyWith => _$GuidingEvent_SettledCopyWithImpl<GuidingEvent_Settled>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_Settled&&(identical(other.rms, rms) || other.rms == rms));
}


@override
int get hashCode => Object.hash(runtimeType,rms);

@override
String toString() {
  return 'GuidingEvent.settled(rms: $rms)';
}


}

/// @nodoc
abstract mixin class $GuidingEvent_SettledCopyWith<$Res> implements $GuidingEventCopyWith<$Res> {
  factory $GuidingEvent_SettledCopyWith(GuidingEvent_Settled value, $Res Function(GuidingEvent_Settled) _then) = _$GuidingEvent_SettledCopyWithImpl;
@useResult
$Res call({
 double rms
});




}
/// @nodoc
class _$GuidingEvent_SettledCopyWithImpl<$Res>
    implements $GuidingEvent_SettledCopyWith<$Res> {
  _$GuidingEvent_SettledCopyWithImpl(this._self, this._then);

  final GuidingEvent_Settled _self;
  final $Res Function(GuidingEvent_Settled) _then;

/// Create a copy of GuidingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? rms = null,}) {
  return _then(GuidingEvent_Settled(
rms: null == rms ? _self.rms : rms // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class GuidingEvent_LostStar extends GuidingEvent {
  const GuidingEvent_LostStar(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_LostStar);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuidingEvent.lostStar()';
}


}




/// @nodoc


class GuidingEvent_DitherStarted extends GuidingEvent {
  const GuidingEvent_DitherStarted({required this.pixels}): super._();
  

 final  double pixels;

/// Create a copy of GuidingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$GuidingEvent_DitherStartedCopyWith<GuidingEvent_DitherStarted> get copyWith => _$GuidingEvent_DitherStartedCopyWithImpl<GuidingEvent_DitherStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_DitherStarted&&(identical(other.pixels, pixels) || other.pixels == pixels));
}


@override
int get hashCode => Object.hash(runtimeType,pixels);

@override
String toString() {
  return 'GuidingEvent.ditherStarted(pixels: $pixels)';
}


}

/// @nodoc
abstract mixin class $GuidingEvent_DitherStartedCopyWith<$Res> implements $GuidingEventCopyWith<$Res> {
  factory $GuidingEvent_DitherStartedCopyWith(GuidingEvent_DitherStarted value, $Res Function(GuidingEvent_DitherStarted) _then) = _$GuidingEvent_DitherStartedCopyWithImpl;
@useResult
$Res call({
 double pixels
});




}
/// @nodoc
class _$GuidingEvent_DitherStartedCopyWithImpl<$Res>
    implements $GuidingEvent_DitherStartedCopyWith<$Res> {
  _$GuidingEvent_DitherStartedCopyWithImpl(this._self, this._then);

  final GuidingEvent_DitherStarted _self;
  final $Res Function(GuidingEvent_DitherStarted) _then;

/// Create a copy of GuidingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? pixels = null,}) {
  return _then(GuidingEvent_DitherStarted(
pixels: null == pixels ? _self.pixels : pixels // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class GuidingEvent_DitherCompleted extends GuidingEvent {
  const GuidingEvent_DitherCompleted(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_DitherCompleted);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuidingEvent.ditherCompleted()';
}


}




/// @nodoc


class GuidingEvent_Correction extends GuidingEvent {
  const GuidingEvent_Correction({required this.ra, required this.dec, required this.raRaw, required this.decRaw}): super._();
  

 final  double ra;
 final  double dec;
 final  double raRaw;
 final  double decRaw;

/// Create a copy of GuidingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$GuidingEvent_CorrectionCopyWith<GuidingEvent_Correction> get copyWith => _$GuidingEvent_CorrectionCopyWithImpl<GuidingEvent_Correction>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_Correction&&(identical(other.ra, ra) || other.ra == ra)&&(identical(other.dec, dec) || other.dec == dec)&&(identical(other.raRaw, raRaw) || other.raRaw == raRaw)&&(identical(other.decRaw, decRaw) || other.decRaw == decRaw));
}


@override
int get hashCode => Object.hash(runtimeType,ra,dec,raRaw,decRaw);

@override
String toString() {
  return 'GuidingEvent.correction(ra: $ra, dec: $dec, raRaw: $raRaw, decRaw: $decRaw)';
}


}

/// @nodoc
abstract mixin class $GuidingEvent_CorrectionCopyWith<$Res> implements $GuidingEventCopyWith<$Res> {
  factory $GuidingEvent_CorrectionCopyWith(GuidingEvent_Correction value, $Res Function(GuidingEvent_Correction) _then) = _$GuidingEvent_CorrectionCopyWithImpl;
@useResult
$Res call({
 double ra, double dec, double raRaw, double decRaw
});




}
/// @nodoc
class _$GuidingEvent_CorrectionCopyWithImpl<$Res>
    implements $GuidingEvent_CorrectionCopyWith<$Res> {
  _$GuidingEvent_CorrectionCopyWithImpl(this._self, this._then);

  final GuidingEvent_Correction _self;
  final $Res Function(GuidingEvent_Correction) _then;

/// Create a copy of GuidingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? ra = null,Object? dec = null,Object? raRaw = null,Object? decRaw = null,}) {
  return _then(GuidingEvent_Correction(
ra: null == ra ? _self.ra : ra // ignore: cast_nullable_to_non_nullable
as double,dec: null == dec ? _self.dec : dec // ignore: cast_nullable_to_non_nullable
as double,raRaw: null == raRaw ? _self.raRaw : raRaw // ignore: cast_nullable_to_non_nullable
as double,decRaw: null == decRaw ? _self.decRaw : decRaw // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class GuidingEvent_Looping extends GuidingEvent {
  const GuidingEvent_Looping(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_Looping);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuidingEvent.looping()';
}


}




/// @nodoc


class GuidingEvent_Settling extends GuidingEvent {
  const GuidingEvent_Settling(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_Settling);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuidingEvent.settling()';
}


}




/// @nodoc


class GuidingEvent_Calibrating extends GuidingEvent {
  const GuidingEvent_Calibrating(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_Calibrating);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuidingEvent.calibrating()';
}


}




/// @nodoc


class GuidingEvent_CalibrationComplete extends GuidingEvent {
  const GuidingEvent_CalibrationComplete(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_CalibrationComplete);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'GuidingEvent.calibrationComplete()';
}


}




/// @nodoc


class GuidingEvent_StarSelected extends GuidingEvent {
  const GuidingEvent_StarSelected({required this.x, required this.y}): super._();
  

 final  double x;
 final  double y;

/// Create a copy of GuidingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$GuidingEvent_StarSelectedCopyWith<GuidingEvent_StarSelected> get copyWith => _$GuidingEvent_StarSelectedCopyWithImpl<GuidingEvent_StarSelected>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_StarSelected&&(identical(other.x, x) || other.x == x)&&(identical(other.y, y) || other.y == y));
}


@override
int get hashCode => Object.hash(runtimeType,x,y);

@override
String toString() {
  return 'GuidingEvent.starSelected(x: $x, y: $y)';
}


}

/// @nodoc
abstract mixin class $GuidingEvent_StarSelectedCopyWith<$Res> implements $GuidingEventCopyWith<$Res> {
  factory $GuidingEvent_StarSelectedCopyWith(GuidingEvent_StarSelected value, $Res Function(GuidingEvent_StarSelected) _then) = _$GuidingEvent_StarSelectedCopyWithImpl;
@useResult
$Res call({
 double x, double y
});




}
/// @nodoc
class _$GuidingEvent_StarSelectedCopyWithImpl<$Res>
    implements $GuidingEvent_StarSelectedCopyWith<$Res> {
  _$GuidingEvent_StarSelectedCopyWithImpl(this._self, this._then);

  final GuidingEvent_StarSelected _self;
  final $Res Function(GuidingEvent_StarSelected) _then;

/// Create a copy of GuidingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? x = null,Object? y = null,}) {
  return _then(GuidingEvent_StarSelected(
x: null == x ? _self.x : x // ignore: cast_nullable_to_non_nullable
as double,y: null == y ? _self.y : y // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class GuidingEvent_AppState extends GuidingEvent {
  const GuidingEvent_AppState({required this.state}): super._();
  

 final  String state;

/// Create a copy of GuidingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$GuidingEvent_AppStateCopyWith<GuidingEvent_AppState> get copyWith => _$GuidingEvent_AppStateCopyWithImpl<GuidingEvent_AppState>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_AppState&&(identical(other.state, state) || other.state == state));
}


@override
int get hashCode => Object.hash(runtimeType,state);

@override
String toString() {
  return 'GuidingEvent.appState(state: $state)';
}


}

/// @nodoc
abstract mixin class $GuidingEvent_AppStateCopyWith<$Res> implements $GuidingEventCopyWith<$Res> {
  factory $GuidingEvent_AppStateCopyWith(GuidingEvent_AppState value, $Res Function(GuidingEvent_AppState) _then) = _$GuidingEvent_AppStateCopyWithImpl;
@useResult
$Res call({
 String state
});




}
/// @nodoc
class _$GuidingEvent_AppStateCopyWithImpl<$Res>
    implements $GuidingEvent_AppStateCopyWith<$Res> {
  _$GuidingEvent_AppStateCopyWithImpl(this._self, this._then);

  final GuidingEvent_AppState _self;
  final $Res Function(GuidingEvent_AppState) _then;

/// Create a copy of GuidingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? state = null,}) {
  return _then(GuidingEvent_AppState(
state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class GuidingEvent_GuideStats extends GuidingEvent {
  const GuidingEvent_GuideStats({required this.snr, required this.starMass}): super._();
  

 final  double snr;
 final  double starMass;

/// Create a copy of GuidingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$GuidingEvent_GuideStatsCopyWith<GuidingEvent_GuideStats> get copyWith => _$GuidingEvent_GuideStatsCopyWithImpl<GuidingEvent_GuideStats>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuidingEvent_GuideStats&&(identical(other.snr, snr) || other.snr == snr)&&(identical(other.starMass, starMass) || other.starMass == starMass));
}


@override
int get hashCode => Object.hash(runtimeType,snr,starMass);

@override
String toString() {
  return 'GuidingEvent.guideStats(snr: $snr, starMass: $starMass)';
}


}

/// @nodoc
abstract mixin class $GuidingEvent_GuideStatsCopyWith<$Res> implements $GuidingEventCopyWith<$Res> {
  factory $GuidingEvent_GuideStatsCopyWith(GuidingEvent_GuideStats value, $Res Function(GuidingEvent_GuideStats) _then) = _$GuidingEvent_GuideStatsCopyWithImpl;
@useResult
$Res call({
 double snr, double starMass
});




}
/// @nodoc
class _$GuidingEvent_GuideStatsCopyWithImpl<$Res>
    implements $GuidingEvent_GuideStatsCopyWith<$Res> {
  _$GuidingEvent_GuideStatsCopyWithImpl(this._self, this._then);

  final GuidingEvent_GuideStats _self;
  final $Res Function(GuidingEvent_GuideStats) _then;

/// Create a copy of GuidingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? snr = null,Object? starMass = null,}) {
  return _then(GuidingEvent_GuideStats(
snr: null == snr ? _self.snr : snr // ignore: cast_nullable_to_non_nullable
as double,starMass: null == starMass ? _self.starMass : starMass // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

// dart format on
