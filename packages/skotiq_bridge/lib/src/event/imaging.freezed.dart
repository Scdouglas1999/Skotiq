// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'imaging.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ImagingEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ImagingEvent()';
}


}

/// @nodoc
class $ImagingEventCopyWith<$Res>  {
$ImagingEventCopyWith(ImagingEvent _, $Res Function(ImagingEvent) __);
}


/// Adds pattern-matching-related methods to [ImagingEvent].
extension ImagingEventPatterns on ImagingEvent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( ImagingEvent_ExposureStarted value)?  exposureStarted,TResult Function( ImagingEvent_ExposureStartedWithFrame value)?  exposureStartedWithFrame,TResult Function( ImagingEvent_ExposureProgress value)?  exposureProgress,TResult Function( ImagingEvent_ExposureCompleted value)?  exposureCompleted,TResult Function( ImagingEvent_ExposureCompletedWithFrame value)?  exposureCompletedWithFrame,TResult Function( ImagingEvent_ExposureFailed value)?  exposureFailed,TResult Function( ImagingEvent_ExposureCancelled value)?  exposureCancelled,TResult Function( ImagingEvent_DownloadStarted value)?  downloadStarted,TResult Function( ImagingEvent_DownloadCompleted value)?  downloadCompleted,TResult Function( ImagingEvent_ImageReady value)?  imageReady,TResult Function( ImagingEvent_ImageSaved value)?  imageSaved,TResult Function( ImagingEvent_IntegrationProgress value)?  integrationProgress,TResult Function( ImagingEvent_TemperatureChanged value)?  temperatureChanged,TResult Function( ImagingEvent_ExposureComplete value)?  exposureComplete,TResult Function( ImagingEvent_ExposureFailedOld value)?  exposureFailedOld,required TResult orElse(),}){
final _that = this;
switch (_that) {
case ImagingEvent_ExposureStarted() when exposureStarted != null:
return exposureStarted(_that);case ImagingEvent_ExposureStartedWithFrame() when exposureStartedWithFrame != null:
return exposureStartedWithFrame(_that);case ImagingEvent_ExposureProgress() when exposureProgress != null:
return exposureProgress(_that);case ImagingEvent_ExposureCompleted() when exposureCompleted != null:
return exposureCompleted(_that);case ImagingEvent_ExposureCompletedWithFrame() when exposureCompletedWithFrame != null:
return exposureCompletedWithFrame(_that);case ImagingEvent_ExposureFailed() when exposureFailed != null:
return exposureFailed(_that);case ImagingEvent_ExposureCancelled() when exposureCancelled != null:
return exposureCancelled(_that);case ImagingEvent_DownloadStarted() when downloadStarted != null:
return downloadStarted(_that);case ImagingEvent_DownloadCompleted() when downloadCompleted != null:
return downloadCompleted(_that);case ImagingEvent_ImageReady() when imageReady != null:
return imageReady(_that);case ImagingEvent_ImageSaved() when imageSaved != null:
return imageSaved(_that);case ImagingEvent_IntegrationProgress() when integrationProgress != null:
return integrationProgress(_that);case ImagingEvent_TemperatureChanged() when temperatureChanged != null:
return temperatureChanged(_that);case ImagingEvent_ExposureComplete() when exposureComplete != null:
return exposureComplete(_that);case ImagingEvent_ExposureFailedOld() when exposureFailedOld != null:
return exposureFailedOld(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( ImagingEvent_ExposureStarted value)  exposureStarted,required TResult Function( ImagingEvent_ExposureStartedWithFrame value)  exposureStartedWithFrame,required TResult Function( ImagingEvent_ExposureProgress value)  exposureProgress,required TResult Function( ImagingEvent_ExposureCompleted value)  exposureCompleted,required TResult Function( ImagingEvent_ExposureCompletedWithFrame value)  exposureCompletedWithFrame,required TResult Function( ImagingEvent_ExposureFailed value)  exposureFailed,required TResult Function( ImagingEvent_ExposureCancelled value)  exposureCancelled,required TResult Function( ImagingEvent_DownloadStarted value)  downloadStarted,required TResult Function( ImagingEvent_DownloadCompleted value)  downloadCompleted,required TResult Function( ImagingEvent_ImageReady value)  imageReady,required TResult Function( ImagingEvent_ImageSaved value)  imageSaved,required TResult Function( ImagingEvent_IntegrationProgress value)  integrationProgress,required TResult Function( ImagingEvent_TemperatureChanged value)  temperatureChanged,required TResult Function( ImagingEvent_ExposureComplete value)  exposureComplete,required TResult Function( ImagingEvent_ExposureFailedOld value)  exposureFailedOld,}){
final _that = this;
switch (_that) {
case ImagingEvent_ExposureStarted():
return exposureStarted(_that);case ImagingEvent_ExposureStartedWithFrame():
return exposureStartedWithFrame(_that);case ImagingEvent_ExposureProgress():
return exposureProgress(_that);case ImagingEvent_ExposureCompleted():
return exposureCompleted(_that);case ImagingEvent_ExposureCompletedWithFrame():
return exposureCompletedWithFrame(_that);case ImagingEvent_ExposureFailed():
return exposureFailed(_that);case ImagingEvent_ExposureCancelled():
return exposureCancelled(_that);case ImagingEvent_DownloadStarted():
return downloadStarted(_that);case ImagingEvent_DownloadCompleted():
return downloadCompleted(_that);case ImagingEvent_ImageReady():
return imageReady(_that);case ImagingEvent_ImageSaved():
return imageSaved(_that);case ImagingEvent_IntegrationProgress():
return integrationProgress(_that);case ImagingEvent_TemperatureChanged():
return temperatureChanged(_that);case ImagingEvent_ExposureComplete():
return exposureComplete(_that);case ImagingEvent_ExposureFailedOld():
return exposureFailedOld(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( ImagingEvent_ExposureStarted value)?  exposureStarted,TResult? Function( ImagingEvent_ExposureStartedWithFrame value)?  exposureStartedWithFrame,TResult? Function( ImagingEvent_ExposureProgress value)?  exposureProgress,TResult? Function( ImagingEvent_ExposureCompleted value)?  exposureCompleted,TResult? Function( ImagingEvent_ExposureCompletedWithFrame value)?  exposureCompletedWithFrame,TResult? Function( ImagingEvent_ExposureFailed value)?  exposureFailed,TResult? Function( ImagingEvent_ExposureCancelled value)?  exposureCancelled,TResult? Function( ImagingEvent_DownloadStarted value)?  downloadStarted,TResult? Function( ImagingEvent_DownloadCompleted value)?  downloadCompleted,TResult? Function( ImagingEvent_ImageReady value)?  imageReady,TResult? Function( ImagingEvent_ImageSaved value)?  imageSaved,TResult? Function( ImagingEvent_IntegrationProgress value)?  integrationProgress,TResult? Function( ImagingEvent_TemperatureChanged value)?  temperatureChanged,TResult? Function( ImagingEvent_ExposureComplete value)?  exposureComplete,TResult? Function( ImagingEvent_ExposureFailedOld value)?  exposureFailedOld,}){
final _that = this;
switch (_that) {
case ImagingEvent_ExposureStarted() when exposureStarted != null:
return exposureStarted(_that);case ImagingEvent_ExposureStartedWithFrame() when exposureStartedWithFrame != null:
return exposureStartedWithFrame(_that);case ImagingEvent_ExposureProgress() when exposureProgress != null:
return exposureProgress(_that);case ImagingEvent_ExposureCompleted() when exposureCompleted != null:
return exposureCompleted(_that);case ImagingEvent_ExposureCompletedWithFrame() when exposureCompletedWithFrame != null:
return exposureCompletedWithFrame(_that);case ImagingEvent_ExposureFailed() when exposureFailed != null:
return exposureFailed(_that);case ImagingEvent_ExposureCancelled() when exposureCancelled != null:
return exposureCancelled(_that);case ImagingEvent_DownloadStarted() when downloadStarted != null:
return downloadStarted(_that);case ImagingEvent_DownloadCompleted() when downloadCompleted != null:
return downloadCompleted(_that);case ImagingEvent_ImageReady() when imageReady != null:
return imageReady(_that);case ImagingEvent_ImageSaved() when imageSaved != null:
return imageSaved(_that);case ImagingEvent_IntegrationProgress() when integrationProgress != null:
return integrationProgress(_that);case ImagingEvent_TemperatureChanged() when temperatureChanged != null:
return temperatureChanged(_that);case ImagingEvent_ExposureComplete() when exposureComplete != null:
return exposureComplete(_that);case ImagingEvent_ExposureFailedOld() when exposureFailedOld != null:
return exposureFailedOld(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( double durationSecs,  FrameType frameType)?  exposureStarted,TResult Function( double durationSecs,  FrameType frameType,  int frameNumber,  int? totalFrames)?  exposureStartedWithFrame,TResult Function( double progress,  double remainingSecs)?  exposureProgress,TResult Function( String? filePath,  double hfr,  int starsDetected)?  exposureCompleted,TResult Function( int frameNumber,  int? totalFrames,  double hfr,  int starsDetected)?  exposureCompletedWithFrame,TResult Function( String error)?  exposureFailed,TResult Function()?  exposureCancelled,TResult Function()?  downloadStarted,TResult Function()?  downloadCompleted,TResult Function( int width,  int height)?  imageReady,TResult Function( String filePath)?  imageSaved,TResult Function( String phase,  double fraction,  int? framesDone,  int? framesTotal)?  integrationProgress,TResult Function( double tempCelsius,  double coolerPower)?  temperatureChanged,TResult Function( bool success)?  exposureComplete,TResult Function( String reason)?  exposureFailedOld,required TResult orElse(),}) {final _that = this;
switch (_that) {
case ImagingEvent_ExposureStarted() when exposureStarted != null:
return exposureStarted(_that.durationSecs,_that.frameType);case ImagingEvent_ExposureStartedWithFrame() when exposureStartedWithFrame != null:
return exposureStartedWithFrame(_that.durationSecs,_that.frameType,_that.frameNumber,_that.totalFrames);case ImagingEvent_ExposureProgress() when exposureProgress != null:
return exposureProgress(_that.progress,_that.remainingSecs);case ImagingEvent_ExposureCompleted() when exposureCompleted != null:
return exposureCompleted(_that.filePath,_that.hfr,_that.starsDetected);case ImagingEvent_ExposureCompletedWithFrame() when exposureCompletedWithFrame != null:
return exposureCompletedWithFrame(_that.frameNumber,_that.totalFrames,_that.hfr,_that.starsDetected);case ImagingEvent_ExposureFailed() when exposureFailed != null:
return exposureFailed(_that.error);case ImagingEvent_ExposureCancelled() when exposureCancelled != null:
return exposureCancelled();case ImagingEvent_DownloadStarted() when downloadStarted != null:
return downloadStarted();case ImagingEvent_DownloadCompleted() when downloadCompleted != null:
return downloadCompleted();case ImagingEvent_ImageReady() when imageReady != null:
return imageReady(_that.width,_that.height);case ImagingEvent_ImageSaved() when imageSaved != null:
return imageSaved(_that.filePath);case ImagingEvent_IntegrationProgress() when integrationProgress != null:
return integrationProgress(_that.phase,_that.fraction,_that.framesDone,_that.framesTotal);case ImagingEvent_TemperatureChanged() when temperatureChanged != null:
return temperatureChanged(_that.tempCelsius,_that.coolerPower);case ImagingEvent_ExposureComplete() when exposureComplete != null:
return exposureComplete(_that.success);case ImagingEvent_ExposureFailedOld() when exposureFailedOld != null:
return exposureFailedOld(_that.reason);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( double durationSecs,  FrameType frameType)  exposureStarted,required TResult Function( double durationSecs,  FrameType frameType,  int frameNumber,  int? totalFrames)  exposureStartedWithFrame,required TResult Function( double progress,  double remainingSecs)  exposureProgress,required TResult Function( String? filePath,  double hfr,  int starsDetected)  exposureCompleted,required TResult Function( int frameNumber,  int? totalFrames,  double hfr,  int starsDetected)  exposureCompletedWithFrame,required TResult Function( String error)  exposureFailed,required TResult Function()  exposureCancelled,required TResult Function()  downloadStarted,required TResult Function()  downloadCompleted,required TResult Function( int width,  int height)  imageReady,required TResult Function( String filePath)  imageSaved,required TResult Function( String phase,  double fraction,  int? framesDone,  int? framesTotal)  integrationProgress,required TResult Function( double tempCelsius,  double coolerPower)  temperatureChanged,required TResult Function( bool success)  exposureComplete,required TResult Function( String reason)  exposureFailedOld,}) {final _that = this;
switch (_that) {
case ImagingEvent_ExposureStarted():
return exposureStarted(_that.durationSecs,_that.frameType);case ImagingEvent_ExposureStartedWithFrame():
return exposureStartedWithFrame(_that.durationSecs,_that.frameType,_that.frameNumber,_that.totalFrames);case ImagingEvent_ExposureProgress():
return exposureProgress(_that.progress,_that.remainingSecs);case ImagingEvent_ExposureCompleted():
return exposureCompleted(_that.filePath,_that.hfr,_that.starsDetected);case ImagingEvent_ExposureCompletedWithFrame():
return exposureCompletedWithFrame(_that.frameNumber,_that.totalFrames,_that.hfr,_that.starsDetected);case ImagingEvent_ExposureFailed():
return exposureFailed(_that.error);case ImagingEvent_ExposureCancelled():
return exposureCancelled();case ImagingEvent_DownloadStarted():
return downloadStarted();case ImagingEvent_DownloadCompleted():
return downloadCompleted();case ImagingEvent_ImageReady():
return imageReady(_that.width,_that.height);case ImagingEvent_ImageSaved():
return imageSaved(_that.filePath);case ImagingEvent_IntegrationProgress():
return integrationProgress(_that.phase,_that.fraction,_that.framesDone,_that.framesTotal);case ImagingEvent_TemperatureChanged():
return temperatureChanged(_that.tempCelsius,_that.coolerPower);case ImagingEvent_ExposureComplete():
return exposureComplete(_that.success);case ImagingEvent_ExposureFailedOld():
return exposureFailedOld(_that.reason);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( double durationSecs,  FrameType frameType)?  exposureStarted,TResult? Function( double durationSecs,  FrameType frameType,  int frameNumber,  int? totalFrames)?  exposureStartedWithFrame,TResult? Function( double progress,  double remainingSecs)?  exposureProgress,TResult? Function( String? filePath,  double hfr,  int starsDetected)?  exposureCompleted,TResult? Function( int frameNumber,  int? totalFrames,  double hfr,  int starsDetected)?  exposureCompletedWithFrame,TResult? Function( String error)?  exposureFailed,TResult? Function()?  exposureCancelled,TResult? Function()?  downloadStarted,TResult? Function()?  downloadCompleted,TResult? Function( int width,  int height)?  imageReady,TResult? Function( String filePath)?  imageSaved,TResult? Function( String phase,  double fraction,  int? framesDone,  int? framesTotal)?  integrationProgress,TResult? Function( double tempCelsius,  double coolerPower)?  temperatureChanged,TResult? Function( bool success)?  exposureComplete,TResult? Function( String reason)?  exposureFailedOld,}) {final _that = this;
switch (_that) {
case ImagingEvent_ExposureStarted() when exposureStarted != null:
return exposureStarted(_that.durationSecs,_that.frameType);case ImagingEvent_ExposureStartedWithFrame() when exposureStartedWithFrame != null:
return exposureStartedWithFrame(_that.durationSecs,_that.frameType,_that.frameNumber,_that.totalFrames);case ImagingEvent_ExposureProgress() when exposureProgress != null:
return exposureProgress(_that.progress,_that.remainingSecs);case ImagingEvent_ExposureCompleted() when exposureCompleted != null:
return exposureCompleted(_that.filePath,_that.hfr,_that.starsDetected);case ImagingEvent_ExposureCompletedWithFrame() when exposureCompletedWithFrame != null:
return exposureCompletedWithFrame(_that.frameNumber,_that.totalFrames,_that.hfr,_that.starsDetected);case ImagingEvent_ExposureFailed() when exposureFailed != null:
return exposureFailed(_that.error);case ImagingEvent_ExposureCancelled() when exposureCancelled != null:
return exposureCancelled();case ImagingEvent_DownloadStarted() when downloadStarted != null:
return downloadStarted();case ImagingEvent_DownloadCompleted() when downloadCompleted != null:
return downloadCompleted();case ImagingEvent_ImageReady() when imageReady != null:
return imageReady(_that.width,_that.height);case ImagingEvent_ImageSaved() when imageSaved != null:
return imageSaved(_that.filePath);case ImagingEvent_IntegrationProgress() when integrationProgress != null:
return integrationProgress(_that.phase,_that.fraction,_that.framesDone,_that.framesTotal);case ImagingEvent_TemperatureChanged() when temperatureChanged != null:
return temperatureChanged(_that.tempCelsius,_that.coolerPower);case ImagingEvent_ExposureComplete() when exposureComplete != null:
return exposureComplete(_that.success);case ImagingEvent_ExposureFailedOld() when exposureFailedOld != null:
return exposureFailedOld(_that.reason);case _:
  return null;

}
}

}

/// @nodoc


class ImagingEvent_ExposureStarted extends ImagingEvent {
  const ImagingEvent_ExposureStarted({required this.durationSecs, required this.frameType}): super._();
  

 final  double durationSecs;
 final  FrameType frameType;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImagingEvent_ExposureStartedCopyWith<ImagingEvent_ExposureStarted> get copyWith => _$ImagingEvent_ExposureStartedCopyWithImpl<ImagingEvent_ExposureStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_ExposureStarted&&(identical(other.durationSecs, durationSecs) || other.durationSecs == durationSecs)&&(identical(other.frameType, frameType) || other.frameType == frameType));
}


@override
int get hashCode => Object.hash(runtimeType,durationSecs,frameType);

@override
String toString() {
  return 'ImagingEvent.exposureStarted(durationSecs: $durationSecs, frameType: $frameType)';
}


}

/// @nodoc
abstract mixin class $ImagingEvent_ExposureStartedCopyWith<$Res> implements $ImagingEventCopyWith<$Res> {
  factory $ImagingEvent_ExposureStartedCopyWith(ImagingEvent_ExposureStarted value, $Res Function(ImagingEvent_ExposureStarted) _then) = _$ImagingEvent_ExposureStartedCopyWithImpl;
@useResult
$Res call({
 double durationSecs, FrameType frameType
});




}
/// @nodoc
class _$ImagingEvent_ExposureStartedCopyWithImpl<$Res>
    implements $ImagingEvent_ExposureStartedCopyWith<$Res> {
  _$ImagingEvent_ExposureStartedCopyWithImpl(this._self, this._then);

  final ImagingEvent_ExposureStarted _self;
  final $Res Function(ImagingEvent_ExposureStarted) _then;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? durationSecs = null,Object? frameType = null,}) {
  return _then(ImagingEvent_ExposureStarted(
durationSecs: null == durationSecs ? _self.durationSecs : durationSecs // ignore: cast_nullable_to_non_nullable
as double,frameType: null == frameType ? _self.frameType : frameType // ignore: cast_nullable_to_non_nullable
as FrameType,
  ));
}


}

/// @nodoc


class ImagingEvent_ExposureStartedWithFrame extends ImagingEvent {
  const ImagingEvent_ExposureStartedWithFrame({required this.durationSecs, required this.frameType, required this.frameNumber, this.totalFrames}): super._();
  

 final  double durationSecs;
 final  FrameType frameType;
 final  int frameNumber;
 final  int? totalFrames;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImagingEvent_ExposureStartedWithFrameCopyWith<ImagingEvent_ExposureStartedWithFrame> get copyWith => _$ImagingEvent_ExposureStartedWithFrameCopyWithImpl<ImagingEvent_ExposureStartedWithFrame>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_ExposureStartedWithFrame&&(identical(other.durationSecs, durationSecs) || other.durationSecs == durationSecs)&&(identical(other.frameType, frameType) || other.frameType == frameType)&&(identical(other.frameNumber, frameNumber) || other.frameNumber == frameNumber)&&(identical(other.totalFrames, totalFrames) || other.totalFrames == totalFrames));
}


@override
int get hashCode => Object.hash(runtimeType,durationSecs,frameType,frameNumber,totalFrames);

@override
String toString() {
  return 'ImagingEvent.exposureStartedWithFrame(durationSecs: $durationSecs, frameType: $frameType, frameNumber: $frameNumber, totalFrames: $totalFrames)';
}


}

/// @nodoc
abstract mixin class $ImagingEvent_ExposureStartedWithFrameCopyWith<$Res> implements $ImagingEventCopyWith<$Res> {
  factory $ImagingEvent_ExposureStartedWithFrameCopyWith(ImagingEvent_ExposureStartedWithFrame value, $Res Function(ImagingEvent_ExposureStartedWithFrame) _then) = _$ImagingEvent_ExposureStartedWithFrameCopyWithImpl;
@useResult
$Res call({
 double durationSecs, FrameType frameType, int frameNumber, int? totalFrames
});




}
/// @nodoc
class _$ImagingEvent_ExposureStartedWithFrameCopyWithImpl<$Res>
    implements $ImagingEvent_ExposureStartedWithFrameCopyWith<$Res> {
  _$ImagingEvent_ExposureStartedWithFrameCopyWithImpl(this._self, this._then);

  final ImagingEvent_ExposureStartedWithFrame _self;
  final $Res Function(ImagingEvent_ExposureStartedWithFrame) _then;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? durationSecs = null,Object? frameType = null,Object? frameNumber = null,Object? totalFrames = freezed,}) {
  return _then(ImagingEvent_ExposureStartedWithFrame(
durationSecs: null == durationSecs ? _self.durationSecs : durationSecs // ignore: cast_nullable_to_non_nullable
as double,frameType: null == frameType ? _self.frameType : frameType // ignore: cast_nullable_to_non_nullable
as FrameType,frameNumber: null == frameNumber ? _self.frameNumber : frameNumber // ignore: cast_nullable_to_non_nullable
as int,totalFrames: freezed == totalFrames ? _self.totalFrames : totalFrames // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}

/// @nodoc


class ImagingEvent_ExposureProgress extends ImagingEvent {
  const ImagingEvent_ExposureProgress({required this.progress, required this.remainingSecs}): super._();
  

 final  double progress;
 final  double remainingSecs;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImagingEvent_ExposureProgressCopyWith<ImagingEvent_ExposureProgress> get copyWith => _$ImagingEvent_ExposureProgressCopyWithImpl<ImagingEvent_ExposureProgress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_ExposureProgress&&(identical(other.progress, progress) || other.progress == progress)&&(identical(other.remainingSecs, remainingSecs) || other.remainingSecs == remainingSecs));
}


@override
int get hashCode => Object.hash(runtimeType,progress,remainingSecs);

@override
String toString() {
  return 'ImagingEvent.exposureProgress(progress: $progress, remainingSecs: $remainingSecs)';
}


}

/// @nodoc
abstract mixin class $ImagingEvent_ExposureProgressCopyWith<$Res> implements $ImagingEventCopyWith<$Res> {
  factory $ImagingEvent_ExposureProgressCopyWith(ImagingEvent_ExposureProgress value, $Res Function(ImagingEvent_ExposureProgress) _then) = _$ImagingEvent_ExposureProgressCopyWithImpl;
@useResult
$Res call({
 double progress, double remainingSecs
});




}
/// @nodoc
class _$ImagingEvent_ExposureProgressCopyWithImpl<$Res>
    implements $ImagingEvent_ExposureProgressCopyWith<$Res> {
  _$ImagingEvent_ExposureProgressCopyWithImpl(this._self, this._then);

  final ImagingEvent_ExposureProgress _self;
  final $Res Function(ImagingEvent_ExposureProgress) _then;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? progress = null,Object? remainingSecs = null,}) {
  return _then(ImagingEvent_ExposureProgress(
progress: null == progress ? _self.progress : progress // ignore: cast_nullable_to_non_nullable
as double,remainingSecs: null == remainingSecs ? _self.remainingSecs : remainingSecs // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class ImagingEvent_ExposureCompleted extends ImagingEvent {
  const ImagingEvent_ExposureCompleted({this.filePath, required this.hfr, required this.starsDetected}): super._();
  

 final  String? filePath;
 final  double hfr;
 final  int starsDetected;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImagingEvent_ExposureCompletedCopyWith<ImagingEvent_ExposureCompleted> get copyWith => _$ImagingEvent_ExposureCompletedCopyWithImpl<ImagingEvent_ExposureCompleted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_ExposureCompleted&&(identical(other.filePath, filePath) || other.filePath == filePath)&&(identical(other.hfr, hfr) || other.hfr == hfr)&&(identical(other.starsDetected, starsDetected) || other.starsDetected == starsDetected));
}


@override
int get hashCode => Object.hash(runtimeType,filePath,hfr,starsDetected);

@override
String toString() {
  return 'ImagingEvent.exposureCompleted(filePath: $filePath, hfr: $hfr, starsDetected: $starsDetected)';
}


}

/// @nodoc
abstract mixin class $ImagingEvent_ExposureCompletedCopyWith<$Res> implements $ImagingEventCopyWith<$Res> {
  factory $ImagingEvent_ExposureCompletedCopyWith(ImagingEvent_ExposureCompleted value, $Res Function(ImagingEvent_ExposureCompleted) _then) = _$ImagingEvent_ExposureCompletedCopyWithImpl;
@useResult
$Res call({
 String? filePath, double hfr, int starsDetected
});




}
/// @nodoc
class _$ImagingEvent_ExposureCompletedCopyWithImpl<$Res>
    implements $ImagingEvent_ExposureCompletedCopyWith<$Res> {
  _$ImagingEvent_ExposureCompletedCopyWithImpl(this._self, this._then);

  final ImagingEvent_ExposureCompleted _self;
  final $Res Function(ImagingEvent_ExposureCompleted) _then;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? filePath = freezed,Object? hfr = null,Object? starsDetected = null,}) {
  return _then(ImagingEvent_ExposureCompleted(
filePath: freezed == filePath ? _self.filePath : filePath // ignore: cast_nullable_to_non_nullable
as String?,hfr: null == hfr ? _self.hfr : hfr // ignore: cast_nullable_to_non_nullable
as double,starsDetected: null == starsDetected ? _self.starsDetected : starsDetected // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class ImagingEvent_ExposureCompletedWithFrame extends ImagingEvent {
  const ImagingEvent_ExposureCompletedWithFrame({required this.frameNumber, this.totalFrames, required this.hfr, required this.starsDetected}): super._();
  

 final  int frameNumber;
 final  int? totalFrames;
 final  double hfr;
 final  int starsDetected;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImagingEvent_ExposureCompletedWithFrameCopyWith<ImagingEvent_ExposureCompletedWithFrame> get copyWith => _$ImagingEvent_ExposureCompletedWithFrameCopyWithImpl<ImagingEvent_ExposureCompletedWithFrame>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_ExposureCompletedWithFrame&&(identical(other.frameNumber, frameNumber) || other.frameNumber == frameNumber)&&(identical(other.totalFrames, totalFrames) || other.totalFrames == totalFrames)&&(identical(other.hfr, hfr) || other.hfr == hfr)&&(identical(other.starsDetected, starsDetected) || other.starsDetected == starsDetected));
}


@override
int get hashCode => Object.hash(runtimeType,frameNumber,totalFrames,hfr,starsDetected);

@override
String toString() {
  return 'ImagingEvent.exposureCompletedWithFrame(frameNumber: $frameNumber, totalFrames: $totalFrames, hfr: $hfr, starsDetected: $starsDetected)';
}


}

/// @nodoc
abstract mixin class $ImagingEvent_ExposureCompletedWithFrameCopyWith<$Res> implements $ImagingEventCopyWith<$Res> {
  factory $ImagingEvent_ExposureCompletedWithFrameCopyWith(ImagingEvent_ExposureCompletedWithFrame value, $Res Function(ImagingEvent_ExposureCompletedWithFrame) _then) = _$ImagingEvent_ExposureCompletedWithFrameCopyWithImpl;
@useResult
$Res call({
 int frameNumber, int? totalFrames, double hfr, int starsDetected
});




}
/// @nodoc
class _$ImagingEvent_ExposureCompletedWithFrameCopyWithImpl<$Res>
    implements $ImagingEvent_ExposureCompletedWithFrameCopyWith<$Res> {
  _$ImagingEvent_ExposureCompletedWithFrameCopyWithImpl(this._self, this._then);

  final ImagingEvent_ExposureCompletedWithFrame _self;
  final $Res Function(ImagingEvent_ExposureCompletedWithFrame) _then;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? frameNumber = null,Object? totalFrames = freezed,Object? hfr = null,Object? starsDetected = null,}) {
  return _then(ImagingEvent_ExposureCompletedWithFrame(
frameNumber: null == frameNumber ? _self.frameNumber : frameNumber // ignore: cast_nullable_to_non_nullable
as int,totalFrames: freezed == totalFrames ? _self.totalFrames : totalFrames // ignore: cast_nullable_to_non_nullable
as int?,hfr: null == hfr ? _self.hfr : hfr // ignore: cast_nullable_to_non_nullable
as double,starsDetected: null == starsDetected ? _self.starsDetected : starsDetected // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class ImagingEvent_ExposureFailed extends ImagingEvent {
  const ImagingEvent_ExposureFailed({required this.error}): super._();
  

 final  String error;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImagingEvent_ExposureFailedCopyWith<ImagingEvent_ExposureFailed> get copyWith => _$ImagingEvent_ExposureFailedCopyWithImpl<ImagingEvent_ExposureFailed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_ExposureFailed&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode => Object.hash(runtimeType,error);

@override
String toString() {
  return 'ImagingEvent.exposureFailed(error: $error)';
}


}

/// @nodoc
abstract mixin class $ImagingEvent_ExposureFailedCopyWith<$Res> implements $ImagingEventCopyWith<$Res> {
  factory $ImagingEvent_ExposureFailedCopyWith(ImagingEvent_ExposureFailed value, $Res Function(ImagingEvent_ExposureFailed) _then) = _$ImagingEvent_ExposureFailedCopyWithImpl;
@useResult
$Res call({
 String error
});




}
/// @nodoc
class _$ImagingEvent_ExposureFailedCopyWithImpl<$Res>
    implements $ImagingEvent_ExposureFailedCopyWith<$Res> {
  _$ImagingEvent_ExposureFailedCopyWithImpl(this._self, this._then);

  final ImagingEvent_ExposureFailed _self;
  final $Res Function(ImagingEvent_ExposureFailed) _then;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? error = null,}) {
  return _then(ImagingEvent_ExposureFailed(
error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ImagingEvent_ExposureCancelled extends ImagingEvent {
  const ImagingEvent_ExposureCancelled(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_ExposureCancelled);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ImagingEvent.exposureCancelled()';
}


}




/// @nodoc


class ImagingEvent_DownloadStarted extends ImagingEvent {
  const ImagingEvent_DownloadStarted(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_DownloadStarted);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ImagingEvent.downloadStarted()';
}


}




/// @nodoc


class ImagingEvent_DownloadCompleted extends ImagingEvent {
  const ImagingEvent_DownloadCompleted(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_DownloadCompleted);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ImagingEvent.downloadCompleted()';
}


}




/// @nodoc


class ImagingEvent_ImageReady extends ImagingEvent {
  const ImagingEvent_ImageReady({required this.width, required this.height}): super._();
  

 final  int width;
 final  int height;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImagingEvent_ImageReadyCopyWith<ImagingEvent_ImageReady> get copyWith => _$ImagingEvent_ImageReadyCopyWithImpl<ImagingEvent_ImageReady>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_ImageReady&&(identical(other.width, width) || other.width == width)&&(identical(other.height, height) || other.height == height));
}


@override
int get hashCode => Object.hash(runtimeType,width,height);

@override
String toString() {
  return 'ImagingEvent.imageReady(width: $width, height: $height)';
}


}

/// @nodoc
abstract mixin class $ImagingEvent_ImageReadyCopyWith<$Res> implements $ImagingEventCopyWith<$Res> {
  factory $ImagingEvent_ImageReadyCopyWith(ImagingEvent_ImageReady value, $Res Function(ImagingEvent_ImageReady) _then) = _$ImagingEvent_ImageReadyCopyWithImpl;
@useResult
$Res call({
 int width, int height
});




}
/// @nodoc
class _$ImagingEvent_ImageReadyCopyWithImpl<$Res>
    implements $ImagingEvent_ImageReadyCopyWith<$Res> {
  _$ImagingEvent_ImageReadyCopyWithImpl(this._self, this._then);

  final ImagingEvent_ImageReady _self;
  final $Res Function(ImagingEvent_ImageReady) _then;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? width = null,Object? height = null,}) {
  return _then(ImagingEvent_ImageReady(
width: null == width ? _self.width : width // ignore: cast_nullable_to_non_nullable
as int,height: null == height ? _self.height : height // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class ImagingEvent_ImageSaved extends ImagingEvent {
  const ImagingEvent_ImageSaved({required this.filePath}): super._();
  

 final  String filePath;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImagingEvent_ImageSavedCopyWith<ImagingEvent_ImageSaved> get copyWith => _$ImagingEvent_ImageSavedCopyWithImpl<ImagingEvent_ImageSaved>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_ImageSaved&&(identical(other.filePath, filePath) || other.filePath == filePath));
}


@override
int get hashCode => Object.hash(runtimeType,filePath);

@override
String toString() {
  return 'ImagingEvent.imageSaved(filePath: $filePath)';
}


}

/// @nodoc
abstract mixin class $ImagingEvent_ImageSavedCopyWith<$Res> implements $ImagingEventCopyWith<$Res> {
  factory $ImagingEvent_ImageSavedCopyWith(ImagingEvent_ImageSaved value, $Res Function(ImagingEvent_ImageSaved) _then) = _$ImagingEvent_ImageSavedCopyWithImpl;
@useResult
$Res call({
 String filePath
});




}
/// @nodoc
class _$ImagingEvent_ImageSavedCopyWithImpl<$Res>
    implements $ImagingEvent_ImageSavedCopyWith<$Res> {
  _$ImagingEvent_ImageSavedCopyWithImpl(this._self, this._then);

  final ImagingEvent_ImageSaved _self;
  final $Res Function(ImagingEvent_ImageSaved) _then;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? filePath = null,}) {
  return _then(ImagingEvent_ImageSaved(
filePath: null == filePath ? _self.filePath : filePath // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ImagingEvent_IntegrationProgress extends ImagingEvent {
  const ImagingEvent_IntegrationProgress({required this.phase, required this.fraction, this.framesDone, this.framesTotal}): super._();
  

/// Current pipeline phase: one of `"calibrating"`, `"registering"`,
/// `"normalizing"`, `"weighting"`, `"integrating"`, `"writing"`, or
/// `"preview"`.
 final  String phase;
/// Overall completion fraction in `0.0..=1.0`, monotonically advancing
/// across the phase sequence above.
 final  double fraction;
/// Frames processed so far in the current phase (`None` when the phase
/// has no per-frame granularity, e.g. `integrating`/`writing`).
 final  int? framesDone;
/// Total frames in the current phase (`None` when N/A).
 final  int? framesTotal;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImagingEvent_IntegrationProgressCopyWith<ImagingEvent_IntegrationProgress> get copyWith => _$ImagingEvent_IntegrationProgressCopyWithImpl<ImagingEvent_IntegrationProgress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_IntegrationProgress&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.fraction, fraction) || other.fraction == fraction)&&(identical(other.framesDone, framesDone) || other.framesDone == framesDone)&&(identical(other.framesTotal, framesTotal) || other.framesTotal == framesTotal));
}


@override
int get hashCode => Object.hash(runtimeType,phase,fraction,framesDone,framesTotal);

@override
String toString() {
  return 'ImagingEvent.integrationProgress(phase: $phase, fraction: $fraction, framesDone: $framesDone, framesTotal: $framesTotal)';
}


}

/// @nodoc
abstract mixin class $ImagingEvent_IntegrationProgressCopyWith<$Res> implements $ImagingEventCopyWith<$Res> {
  factory $ImagingEvent_IntegrationProgressCopyWith(ImagingEvent_IntegrationProgress value, $Res Function(ImagingEvent_IntegrationProgress) _then) = _$ImagingEvent_IntegrationProgressCopyWithImpl;
@useResult
$Res call({
 String phase, double fraction, int? framesDone, int? framesTotal
});




}
/// @nodoc
class _$ImagingEvent_IntegrationProgressCopyWithImpl<$Res>
    implements $ImagingEvent_IntegrationProgressCopyWith<$Res> {
  _$ImagingEvent_IntegrationProgressCopyWithImpl(this._self, this._then);

  final ImagingEvent_IntegrationProgress _self;
  final $Res Function(ImagingEvent_IntegrationProgress) _then;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? phase = null,Object? fraction = null,Object? framesDone = freezed,Object? framesTotal = freezed,}) {
  return _then(ImagingEvent_IntegrationProgress(
phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as String,fraction: null == fraction ? _self.fraction : fraction // ignore: cast_nullable_to_non_nullable
as double,framesDone: freezed == framesDone ? _self.framesDone : framesDone // ignore: cast_nullable_to_non_nullable
as int?,framesTotal: freezed == framesTotal ? _self.framesTotal : framesTotal // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}

/// @nodoc


class ImagingEvent_TemperatureChanged extends ImagingEvent {
  const ImagingEvent_TemperatureChanged({required this.tempCelsius, required this.coolerPower}): super._();
  

 final  double tempCelsius;
 final  double coolerPower;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImagingEvent_TemperatureChangedCopyWith<ImagingEvent_TemperatureChanged> get copyWith => _$ImagingEvent_TemperatureChangedCopyWithImpl<ImagingEvent_TemperatureChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_TemperatureChanged&&(identical(other.tempCelsius, tempCelsius) || other.tempCelsius == tempCelsius)&&(identical(other.coolerPower, coolerPower) || other.coolerPower == coolerPower));
}


@override
int get hashCode => Object.hash(runtimeType,tempCelsius,coolerPower);

@override
String toString() {
  return 'ImagingEvent.temperatureChanged(tempCelsius: $tempCelsius, coolerPower: $coolerPower)';
}


}

/// @nodoc
abstract mixin class $ImagingEvent_TemperatureChangedCopyWith<$Res> implements $ImagingEventCopyWith<$Res> {
  factory $ImagingEvent_TemperatureChangedCopyWith(ImagingEvent_TemperatureChanged value, $Res Function(ImagingEvent_TemperatureChanged) _then) = _$ImagingEvent_TemperatureChangedCopyWithImpl;
@useResult
$Res call({
 double tempCelsius, double coolerPower
});




}
/// @nodoc
class _$ImagingEvent_TemperatureChangedCopyWithImpl<$Res>
    implements $ImagingEvent_TemperatureChangedCopyWith<$Res> {
  _$ImagingEvent_TemperatureChangedCopyWithImpl(this._self, this._then);

  final ImagingEvent_TemperatureChanged _self;
  final $Res Function(ImagingEvent_TemperatureChanged) _then;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? tempCelsius = null,Object? coolerPower = null,}) {
  return _then(ImagingEvent_TemperatureChanged(
tempCelsius: null == tempCelsius ? _self.tempCelsius : tempCelsius // ignore: cast_nullable_to_non_nullable
as double,coolerPower: null == coolerPower ? _self.coolerPower : coolerPower // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class ImagingEvent_ExposureComplete extends ImagingEvent {
  const ImagingEvent_ExposureComplete({required this.success}): super._();
  

 final  bool success;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImagingEvent_ExposureCompleteCopyWith<ImagingEvent_ExposureComplete> get copyWith => _$ImagingEvent_ExposureCompleteCopyWithImpl<ImagingEvent_ExposureComplete>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_ExposureComplete&&(identical(other.success, success) || other.success == success));
}


@override
int get hashCode => Object.hash(runtimeType,success);

@override
String toString() {
  return 'ImagingEvent.exposureComplete(success: $success)';
}


}

/// @nodoc
abstract mixin class $ImagingEvent_ExposureCompleteCopyWith<$Res> implements $ImagingEventCopyWith<$Res> {
  factory $ImagingEvent_ExposureCompleteCopyWith(ImagingEvent_ExposureComplete value, $Res Function(ImagingEvent_ExposureComplete) _then) = _$ImagingEvent_ExposureCompleteCopyWithImpl;
@useResult
$Res call({
 bool success
});




}
/// @nodoc
class _$ImagingEvent_ExposureCompleteCopyWithImpl<$Res>
    implements $ImagingEvent_ExposureCompleteCopyWith<$Res> {
  _$ImagingEvent_ExposureCompleteCopyWithImpl(this._self, this._then);

  final ImagingEvent_ExposureComplete _self;
  final $Res Function(ImagingEvent_ExposureComplete) _then;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? success = null,}) {
  return _then(ImagingEvent_ExposureComplete(
success: null == success ? _self.success : success // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class ImagingEvent_ExposureFailedOld extends ImagingEvent {
  const ImagingEvent_ExposureFailedOld({required this.reason}): super._();
  

 final  String reason;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImagingEvent_ExposureFailedOldCopyWith<ImagingEvent_ExposureFailedOld> get copyWith => _$ImagingEvent_ExposureFailedOldCopyWithImpl<ImagingEvent_ExposureFailedOld>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagingEvent_ExposureFailedOld&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'ImagingEvent.exposureFailedOld(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $ImagingEvent_ExposureFailedOldCopyWith<$Res> implements $ImagingEventCopyWith<$Res> {
  factory $ImagingEvent_ExposureFailedOldCopyWith(ImagingEvent_ExposureFailedOld value, $Res Function(ImagingEvent_ExposureFailedOld) _then) = _$ImagingEvent_ExposureFailedOldCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$ImagingEvent_ExposureFailedOldCopyWithImpl<$Res>
    implements $ImagingEvent_ExposureFailedOldCopyWith<$Res> {
  _$ImagingEvent_ExposureFailedOldCopyWithImpl(this._self, this._then);

  final ImagingEvent_ExposureFailedOld _self;
  final $Res Function(ImagingEvent_ExposureFailedOld) _then;

/// Create a copy of ImagingEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(ImagingEvent_ExposureFailedOld(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
