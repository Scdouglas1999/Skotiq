// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'flat_wizard_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$AduMeasurement {

 double get exposure; double get adu; DateTime get timestamp;
/// Create a copy of AduMeasurement
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AduMeasurementCopyWith<AduMeasurement> get copyWith => _$AduMeasurementCopyWithImpl<AduMeasurement>(this as AduMeasurement, _$identity);

  /// Serializes this AduMeasurement to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AduMeasurement&&(identical(other.exposure, exposure) || other.exposure == exposure)&&(identical(other.adu, adu) || other.adu == adu)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,exposure,adu,timestamp);

@override
String toString() {
  return 'AduMeasurement(exposure: $exposure, adu: $adu, timestamp: $timestamp)';
}


}

/// @nodoc
abstract mixin class $AduMeasurementCopyWith<$Res>  {
  factory $AduMeasurementCopyWith(AduMeasurement value, $Res Function(AduMeasurement) _then) = _$AduMeasurementCopyWithImpl;
@useResult
$Res call({
 double exposure, double adu, DateTime timestamp
});




}
/// @nodoc
class _$AduMeasurementCopyWithImpl<$Res>
    implements $AduMeasurementCopyWith<$Res> {
  _$AduMeasurementCopyWithImpl(this._self, this._then);

  final AduMeasurement _self;
  final $Res Function(AduMeasurement) _then;

/// Create a copy of AduMeasurement
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? exposure = null,Object? adu = null,Object? timestamp = null,}) {
  return _then(_self.copyWith(
exposure: null == exposure ? _self.exposure : exposure // ignore: cast_nullable_to_non_nullable
as double,adu: null == adu ? _self.adu : adu // ignore: cast_nullable_to_non_nullable
as double,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}

}


/// Adds pattern-matching-related methods to [AduMeasurement].
extension AduMeasurementPatterns on AduMeasurement {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AduMeasurement value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AduMeasurement() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AduMeasurement value)  $default,){
final _that = this;
switch (_that) {
case _AduMeasurement():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AduMeasurement value)?  $default,){
final _that = this;
switch (_that) {
case _AduMeasurement() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double exposure,  double adu,  DateTime timestamp)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AduMeasurement() when $default != null:
return $default(_that.exposure,_that.adu,_that.timestamp);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double exposure,  double adu,  DateTime timestamp)  $default,) {final _that = this;
switch (_that) {
case _AduMeasurement():
return $default(_that.exposure,_that.adu,_that.timestamp);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double exposure,  double adu,  DateTime timestamp)?  $default,) {final _that = this;
switch (_that) {
case _AduMeasurement() when $default != null:
return $default(_that.exposure,_that.adu,_that.timestamp);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AduMeasurement implements AduMeasurement {
  const _AduMeasurement({required this.exposure, required this.adu, required this.timestamp});
  factory _AduMeasurement.fromJson(Map<String, dynamic> json) => _$AduMeasurementFromJson(json);

@override final  double exposure;
@override final  double adu;
@override final  DateTime timestamp;

/// Create a copy of AduMeasurement
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AduMeasurementCopyWith<_AduMeasurement> get copyWith => __$AduMeasurementCopyWithImpl<_AduMeasurement>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AduMeasurementToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AduMeasurement&&(identical(other.exposure, exposure) || other.exposure == exposure)&&(identical(other.adu, adu) || other.adu == adu)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,exposure,adu,timestamp);

@override
String toString() {
  return 'AduMeasurement(exposure: $exposure, adu: $adu, timestamp: $timestamp)';
}


}

/// @nodoc
abstract mixin class _$AduMeasurementCopyWith<$Res> implements $AduMeasurementCopyWith<$Res> {
  factory _$AduMeasurementCopyWith(_AduMeasurement value, $Res Function(_AduMeasurement) _then) = __$AduMeasurementCopyWithImpl;
@override @useResult
$Res call({
 double exposure, double adu, DateTime timestamp
});




}
/// @nodoc
class __$AduMeasurementCopyWithImpl<$Res>
    implements _$AduMeasurementCopyWith<$Res> {
  __$AduMeasurementCopyWithImpl(this._self, this._then);

  final _AduMeasurement _self;
  final $Res Function(_AduMeasurement) _then;

/// Create a copy of AduMeasurement
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? exposure = null,Object? adu = null,Object? timestamp = null,}) {
  return _then(_AduMeasurement(
exposure: null == exposure ? _self.exposure : exposure // ignore: cast_nullable_to_non_nullable
as double,adu: null == adu ? _self.adu : adu // ignore: cast_nullable_to_non_nullable
as double,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}


}


/// @nodoc
mixin _$SkyBrightnessMeasurement {

 double get adu; double get exposureUsed; DateTime get timestamp;
/// Create a copy of SkyBrightnessMeasurement
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkyBrightnessMeasurementCopyWith<SkyBrightnessMeasurement> get copyWith => _$SkyBrightnessMeasurementCopyWithImpl<SkyBrightnessMeasurement>(this as SkyBrightnessMeasurement, _$identity);

  /// Serializes this SkyBrightnessMeasurement to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkyBrightnessMeasurement&&(identical(other.adu, adu) || other.adu == adu)&&(identical(other.exposureUsed, exposureUsed) || other.exposureUsed == exposureUsed)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,adu,exposureUsed,timestamp);

@override
String toString() {
  return 'SkyBrightnessMeasurement(adu: $adu, exposureUsed: $exposureUsed, timestamp: $timestamp)';
}


}

/// @nodoc
abstract mixin class $SkyBrightnessMeasurementCopyWith<$Res>  {
  factory $SkyBrightnessMeasurementCopyWith(SkyBrightnessMeasurement value, $Res Function(SkyBrightnessMeasurement) _then) = _$SkyBrightnessMeasurementCopyWithImpl;
@useResult
$Res call({
 double adu, double exposureUsed, DateTime timestamp
});




}
/// @nodoc
class _$SkyBrightnessMeasurementCopyWithImpl<$Res>
    implements $SkyBrightnessMeasurementCopyWith<$Res> {
  _$SkyBrightnessMeasurementCopyWithImpl(this._self, this._then);

  final SkyBrightnessMeasurement _self;
  final $Res Function(SkyBrightnessMeasurement) _then;

/// Create a copy of SkyBrightnessMeasurement
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? adu = null,Object? exposureUsed = null,Object? timestamp = null,}) {
  return _then(_self.copyWith(
adu: null == adu ? _self.adu : adu // ignore: cast_nullable_to_non_nullable
as double,exposureUsed: null == exposureUsed ? _self.exposureUsed : exposureUsed // ignore: cast_nullable_to_non_nullable
as double,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}

}


/// Adds pattern-matching-related methods to [SkyBrightnessMeasurement].
extension SkyBrightnessMeasurementPatterns on SkyBrightnessMeasurement {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SkyBrightnessMeasurement value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SkyBrightnessMeasurement() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SkyBrightnessMeasurement value)  $default,){
final _that = this;
switch (_that) {
case _SkyBrightnessMeasurement():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SkyBrightnessMeasurement value)?  $default,){
final _that = this;
switch (_that) {
case _SkyBrightnessMeasurement() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double adu,  double exposureUsed,  DateTime timestamp)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SkyBrightnessMeasurement() when $default != null:
return $default(_that.adu,_that.exposureUsed,_that.timestamp);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double adu,  double exposureUsed,  DateTime timestamp)  $default,) {final _that = this;
switch (_that) {
case _SkyBrightnessMeasurement():
return $default(_that.adu,_that.exposureUsed,_that.timestamp);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double adu,  double exposureUsed,  DateTime timestamp)?  $default,) {final _that = this;
switch (_that) {
case _SkyBrightnessMeasurement() when $default != null:
return $default(_that.adu,_that.exposureUsed,_that.timestamp);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _SkyBrightnessMeasurement implements SkyBrightnessMeasurement {
  const _SkyBrightnessMeasurement({required this.adu, required this.exposureUsed, required this.timestamp});
  factory _SkyBrightnessMeasurement.fromJson(Map<String, dynamic> json) => _$SkyBrightnessMeasurementFromJson(json);

@override final  double adu;
@override final  double exposureUsed;
@override final  DateTime timestamp;

/// Create a copy of SkyBrightnessMeasurement
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SkyBrightnessMeasurementCopyWith<_SkyBrightnessMeasurement> get copyWith => __$SkyBrightnessMeasurementCopyWithImpl<_SkyBrightnessMeasurement>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SkyBrightnessMeasurementToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SkyBrightnessMeasurement&&(identical(other.adu, adu) || other.adu == adu)&&(identical(other.exposureUsed, exposureUsed) || other.exposureUsed == exposureUsed)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,adu,exposureUsed,timestamp);

@override
String toString() {
  return 'SkyBrightnessMeasurement(adu: $adu, exposureUsed: $exposureUsed, timestamp: $timestamp)';
}


}

/// @nodoc
abstract mixin class _$SkyBrightnessMeasurementCopyWith<$Res> implements $SkyBrightnessMeasurementCopyWith<$Res> {
  factory _$SkyBrightnessMeasurementCopyWith(_SkyBrightnessMeasurement value, $Res Function(_SkyBrightnessMeasurement) _then) = __$SkyBrightnessMeasurementCopyWithImpl;
@override @useResult
$Res call({
 double adu, double exposureUsed, DateTime timestamp
});




}
/// @nodoc
class __$SkyBrightnessMeasurementCopyWithImpl<$Res>
    implements _$SkyBrightnessMeasurementCopyWith<$Res> {
  __$SkyBrightnessMeasurementCopyWithImpl(this._self, this._then);

  final _SkyBrightnessMeasurement _self;
  final $Res Function(_SkyBrightnessMeasurement) _then;

/// Create a copy of SkyBrightnessMeasurement
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? adu = null,Object? exposureUsed = null,Object? timestamp = null,}) {
  return _then(_SkyBrightnessMeasurement(
adu: null == adu ? _self.adu : adu // ignore: cast_nullable_to_non_nullable
as double,exposureUsed: null == exposureUsed ? _self.exposureUsed : exposureUsed // ignore: cast_nullable_to_non_nullable
as double,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}


}


/// @nodoc
mixin _$FlatWizardState {

/// Current operating mode
 FlatWizardMode get mode;/// Global settings
 FlatWizardGlobalSettings get globalSettings;/// Per-filter settings
 List<FlatFilterSettings> get filterSettings;/// Saved filter presets
 List<FlatFilterPreset> get filterPresets;/// Current filter index being processed
 int get currentFilterIndex;/// Current frame index for active filter
 int get currentFrameIndex;/// Is capture/calibration in progress
 bool get isCapturing;/// Is currently exposing (for countdown)
 bool get isExposing;/// Current exposure start time (for countdown)
 DateTime? get exposureStartTime;/// Current exposure duration (for countdown)
 double? get currentExposureDuration;/// ADU measurements for convergence graph
 List<AduMeasurement> get aduHistory;/// Sky brightness measurements for rate tracking
 List<SkyBrightnessMeasurement> get skyBrightnessHistory;/// Calculated sky brightness change rate (ADU/s)
 double? get skyAduRate;/// Twilight mode for sky flats
 TwilightMode get twilightMode;/// Most recent captured image path
 String? get lastImagePath;/// Most recent captured image data (for preview, runtime only)
@RuntimeOnlyValueConverter() Object? get lastImageData;/// Error message if any
 String? get errorMessage;/// Warning message (non-fatal, informational)
 String? get warningMessage;/// Status message for progress display
 String? get statusMessage;/// Visualization toggles
 bool get showAduGraph; bool get showExposureTimeline; bool get showSkyBrightness; bool get showFilterCards; bool get showHistogramOverlay;
/// Create a copy of FlatWizardState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FlatWizardStateCopyWith<FlatWizardState> get copyWith => _$FlatWizardStateCopyWithImpl<FlatWizardState>(this as FlatWizardState, _$identity);

  /// Serializes this FlatWizardState to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FlatWizardState&&(identical(other.mode, mode) || other.mode == mode)&&(identical(other.globalSettings, globalSettings) || other.globalSettings == globalSettings)&&const DeepCollectionEquality().equals(other.filterSettings, filterSettings)&&const DeepCollectionEquality().equals(other.filterPresets, filterPresets)&&(identical(other.currentFilterIndex, currentFilterIndex) || other.currentFilterIndex == currentFilterIndex)&&(identical(other.currentFrameIndex, currentFrameIndex) || other.currentFrameIndex == currentFrameIndex)&&(identical(other.isCapturing, isCapturing) || other.isCapturing == isCapturing)&&(identical(other.isExposing, isExposing) || other.isExposing == isExposing)&&(identical(other.exposureStartTime, exposureStartTime) || other.exposureStartTime == exposureStartTime)&&(identical(other.currentExposureDuration, currentExposureDuration) || other.currentExposureDuration == currentExposureDuration)&&const DeepCollectionEquality().equals(other.aduHistory, aduHistory)&&const DeepCollectionEquality().equals(other.skyBrightnessHistory, skyBrightnessHistory)&&(identical(other.skyAduRate, skyAduRate) || other.skyAduRate == skyAduRate)&&(identical(other.twilightMode, twilightMode) || other.twilightMode == twilightMode)&&(identical(other.lastImagePath, lastImagePath) || other.lastImagePath == lastImagePath)&&const DeepCollectionEquality().equals(other.lastImageData, lastImageData)&&(identical(other.errorMessage, errorMessage) || other.errorMessage == errorMessage)&&(identical(other.warningMessage, warningMessage) || other.warningMessage == warningMessage)&&(identical(other.statusMessage, statusMessage) || other.statusMessage == statusMessage)&&(identical(other.showAduGraph, showAduGraph) || other.showAduGraph == showAduGraph)&&(identical(other.showExposureTimeline, showExposureTimeline) || other.showExposureTimeline == showExposureTimeline)&&(identical(other.showSkyBrightness, showSkyBrightness) || other.showSkyBrightness == showSkyBrightness)&&(identical(other.showFilterCards, showFilterCards) || other.showFilterCards == showFilterCards)&&(identical(other.showHistogramOverlay, showHistogramOverlay) || other.showHistogramOverlay == showHistogramOverlay));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,mode,globalSettings,const DeepCollectionEquality().hash(filterSettings),const DeepCollectionEquality().hash(filterPresets),currentFilterIndex,currentFrameIndex,isCapturing,isExposing,exposureStartTime,currentExposureDuration,const DeepCollectionEquality().hash(aduHistory),const DeepCollectionEquality().hash(skyBrightnessHistory),skyAduRate,twilightMode,lastImagePath,const DeepCollectionEquality().hash(lastImageData),errorMessage,warningMessage,statusMessage,showAduGraph,showExposureTimeline,showSkyBrightness,showFilterCards,showHistogramOverlay]);

@override
String toString() {
  return 'FlatWizardState(mode: $mode, globalSettings: $globalSettings, filterSettings: $filterSettings, filterPresets: $filterPresets, currentFilterIndex: $currentFilterIndex, currentFrameIndex: $currentFrameIndex, isCapturing: $isCapturing, isExposing: $isExposing, exposureStartTime: $exposureStartTime, currentExposureDuration: $currentExposureDuration, aduHistory: $aduHistory, skyBrightnessHistory: $skyBrightnessHistory, skyAduRate: $skyAduRate, twilightMode: $twilightMode, lastImagePath: $lastImagePath, lastImageData: $lastImageData, errorMessage: $errorMessage, warningMessage: $warningMessage, statusMessage: $statusMessage, showAduGraph: $showAduGraph, showExposureTimeline: $showExposureTimeline, showSkyBrightness: $showSkyBrightness, showFilterCards: $showFilterCards, showHistogramOverlay: $showHistogramOverlay)';
}


}

/// @nodoc
abstract mixin class $FlatWizardStateCopyWith<$Res>  {
  factory $FlatWizardStateCopyWith(FlatWizardState value, $Res Function(FlatWizardState) _then) = _$FlatWizardStateCopyWithImpl;
@useResult
$Res call({
 FlatWizardMode mode, FlatWizardGlobalSettings globalSettings, List<FlatFilterSettings> filterSettings, List<FlatFilterPreset> filterPresets, int currentFilterIndex, int currentFrameIndex, bool isCapturing, bool isExposing, DateTime? exposureStartTime, double? currentExposureDuration, List<AduMeasurement> aduHistory, List<SkyBrightnessMeasurement> skyBrightnessHistory, double? skyAduRate, TwilightMode twilightMode, String? lastImagePath,@RuntimeOnlyValueConverter() Object? lastImageData, String? errorMessage, String? warningMessage, String? statusMessage, bool showAduGraph, bool showExposureTimeline, bool showSkyBrightness, bool showFilterCards, bool showHistogramOverlay
});


$FlatWizardGlobalSettingsCopyWith<$Res> get globalSettings;

}
/// @nodoc
class _$FlatWizardStateCopyWithImpl<$Res>
    implements $FlatWizardStateCopyWith<$Res> {
  _$FlatWizardStateCopyWithImpl(this._self, this._then);

  final FlatWizardState _self;
  final $Res Function(FlatWizardState) _then;

/// Create a copy of FlatWizardState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? mode = null,Object? globalSettings = null,Object? filterSettings = null,Object? filterPresets = null,Object? currentFilterIndex = null,Object? currentFrameIndex = null,Object? isCapturing = null,Object? isExposing = null,Object? exposureStartTime = freezed,Object? currentExposureDuration = freezed,Object? aduHistory = null,Object? skyBrightnessHistory = null,Object? skyAduRate = freezed,Object? twilightMode = null,Object? lastImagePath = freezed,Object? lastImageData = freezed,Object? errorMessage = freezed,Object? warningMessage = freezed,Object? statusMessage = freezed,Object? showAduGraph = null,Object? showExposureTimeline = null,Object? showSkyBrightness = null,Object? showFilterCards = null,Object? showHistogramOverlay = null,}) {
  return _then(_self.copyWith(
mode: null == mode ? _self.mode : mode // ignore: cast_nullable_to_non_nullable
as FlatWizardMode,globalSettings: null == globalSettings ? _self.globalSettings : globalSettings // ignore: cast_nullable_to_non_nullable
as FlatWizardGlobalSettings,filterSettings: null == filterSettings ? _self.filterSettings : filterSettings // ignore: cast_nullable_to_non_nullable
as List<FlatFilterSettings>,filterPresets: null == filterPresets ? _self.filterPresets : filterPresets // ignore: cast_nullable_to_non_nullable
as List<FlatFilterPreset>,currentFilterIndex: null == currentFilterIndex ? _self.currentFilterIndex : currentFilterIndex // ignore: cast_nullable_to_non_nullable
as int,currentFrameIndex: null == currentFrameIndex ? _self.currentFrameIndex : currentFrameIndex // ignore: cast_nullable_to_non_nullable
as int,isCapturing: null == isCapturing ? _self.isCapturing : isCapturing // ignore: cast_nullable_to_non_nullable
as bool,isExposing: null == isExposing ? _self.isExposing : isExposing // ignore: cast_nullable_to_non_nullable
as bool,exposureStartTime: freezed == exposureStartTime ? _self.exposureStartTime : exposureStartTime // ignore: cast_nullable_to_non_nullable
as DateTime?,currentExposureDuration: freezed == currentExposureDuration ? _self.currentExposureDuration : currentExposureDuration // ignore: cast_nullable_to_non_nullable
as double?,aduHistory: null == aduHistory ? _self.aduHistory : aduHistory // ignore: cast_nullable_to_non_nullable
as List<AduMeasurement>,skyBrightnessHistory: null == skyBrightnessHistory ? _self.skyBrightnessHistory : skyBrightnessHistory // ignore: cast_nullable_to_non_nullable
as List<SkyBrightnessMeasurement>,skyAduRate: freezed == skyAduRate ? _self.skyAduRate : skyAduRate // ignore: cast_nullable_to_non_nullable
as double?,twilightMode: null == twilightMode ? _self.twilightMode : twilightMode // ignore: cast_nullable_to_non_nullable
as TwilightMode,lastImagePath: freezed == lastImagePath ? _self.lastImagePath : lastImagePath // ignore: cast_nullable_to_non_nullable
as String?,lastImageData: freezed == lastImageData ? _self.lastImageData : lastImageData ,errorMessage: freezed == errorMessage ? _self.errorMessage : errorMessage // ignore: cast_nullable_to_non_nullable
as String?,warningMessage: freezed == warningMessage ? _self.warningMessage : warningMessage // ignore: cast_nullable_to_non_nullable
as String?,statusMessage: freezed == statusMessage ? _self.statusMessage : statusMessage // ignore: cast_nullable_to_non_nullable
as String?,showAduGraph: null == showAduGraph ? _self.showAduGraph : showAduGraph // ignore: cast_nullable_to_non_nullable
as bool,showExposureTimeline: null == showExposureTimeline ? _self.showExposureTimeline : showExposureTimeline // ignore: cast_nullable_to_non_nullable
as bool,showSkyBrightness: null == showSkyBrightness ? _self.showSkyBrightness : showSkyBrightness // ignore: cast_nullable_to_non_nullable
as bool,showFilterCards: null == showFilterCards ? _self.showFilterCards : showFilterCards // ignore: cast_nullable_to_non_nullable
as bool,showHistogramOverlay: null == showHistogramOverlay ? _self.showHistogramOverlay : showHistogramOverlay // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}
/// Create a copy of FlatWizardState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$FlatWizardGlobalSettingsCopyWith<$Res> get globalSettings {
  
  return $FlatWizardGlobalSettingsCopyWith<$Res>(_self.globalSettings, (value) {
    return _then(_self.copyWith(globalSettings: value));
  });
}
}


/// Adds pattern-matching-related methods to [FlatWizardState].
extension FlatWizardStatePatterns on FlatWizardState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _FlatWizardState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _FlatWizardState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _FlatWizardState value)  $default,){
final _that = this;
switch (_that) {
case _FlatWizardState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _FlatWizardState value)?  $default,){
final _that = this;
switch (_that) {
case _FlatWizardState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( FlatWizardMode mode,  FlatWizardGlobalSettings globalSettings,  List<FlatFilterSettings> filterSettings,  List<FlatFilterPreset> filterPresets,  int currentFilterIndex,  int currentFrameIndex,  bool isCapturing,  bool isExposing,  DateTime? exposureStartTime,  double? currentExposureDuration,  List<AduMeasurement> aduHistory,  List<SkyBrightnessMeasurement> skyBrightnessHistory,  double? skyAduRate,  TwilightMode twilightMode,  String? lastImagePath, @RuntimeOnlyValueConverter()  Object? lastImageData,  String? errorMessage,  String? warningMessage,  String? statusMessage,  bool showAduGraph,  bool showExposureTimeline,  bool showSkyBrightness,  bool showFilterCards,  bool showHistogramOverlay)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _FlatWizardState() when $default != null:
return $default(_that.mode,_that.globalSettings,_that.filterSettings,_that.filterPresets,_that.currentFilterIndex,_that.currentFrameIndex,_that.isCapturing,_that.isExposing,_that.exposureStartTime,_that.currentExposureDuration,_that.aduHistory,_that.skyBrightnessHistory,_that.skyAduRate,_that.twilightMode,_that.lastImagePath,_that.lastImageData,_that.errorMessage,_that.warningMessage,_that.statusMessage,_that.showAduGraph,_that.showExposureTimeline,_that.showSkyBrightness,_that.showFilterCards,_that.showHistogramOverlay);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( FlatWizardMode mode,  FlatWizardGlobalSettings globalSettings,  List<FlatFilterSettings> filterSettings,  List<FlatFilterPreset> filterPresets,  int currentFilterIndex,  int currentFrameIndex,  bool isCapturing,  bool isExposing,  DateTime? exposureStartTime,  double? currentExposureDuration,  List<AduMeasurement> aduHistory,  List<SkyBrightnessMeasurement> skyBrightnessHistory,  double? skyAduRate,  TwilightMode twilightMode,  String? lastImagePath, @RuntimeOnlyValueConverter()  Object? lastImageData,  String? errorMessage,  String? warningMessage,  String? statusMessage,  bool showAduGraph,  bool showExposureTimeline,  bool showSkyBrightness,  bool showFilterCards,  bool showHistogramOverlay)  $default,) {final _that = this;
switch (_that) {
case _FlatWizardState():
return $default(_that.mode,_that.globalSettings,_that.filterSettings,_that.filterPresets,_that.currentFilterIndex,_that.currentFrameIndex,_that.isCapturing,_that.isExposing,_that.exposureStartTime,_that.currentExposureDuration,_that.aduHistory,_that.skyBrightnessHistory,_that.skyAduRate,_that.twilightMode,_that.lastImagePath,_that.lastImageData,_that.errorMessage,_that.warningMessage,_that.statusMessage,_that.showAduGraph,_that.showExposureTimeline,_that.showSkyBrightness,_that.showFilterCards,_that.showHistogramOverlay);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( FlatWizardMode mode,  FlatWizardGlobalSettings globalSettings,  List<FlatFilterSettings> filterSettings,  List<FlatFilterPreset> filterPresets,  int currentFilterIndex,  int currentFrameIndex,  bool isCapturing,  bool isExposing,  DateTime? exposureStartTime,  double? currentExposureDuration,  List<AduMeasurement> aduHistory,  List<SkyBrightnessMeasurement> skyBrightnessHistory,  double? skyAduRate,  TwilightMode twilightMode,  String? lastImagePath, @RuntimeOnlyValueConverter()  Object? lastImageData,  String? errorMessage,  String? warningMessage,  String? statusMessage,  bool showAduGraph,  bool showExposureTimeline,  bool showSkyBrightness,  bool showFilterCards,  bool showHistogramOverlay)?  $default,) {final _that = this;
switch (_that) {
case _FlatWizardState() when $default != null:
return $default(_that.mode,_that.globalSettings,_that.filterSettings,_that.filterPresets,_that.currentFilterIndex,_that.currentFrameIndex,_that.isCapturing,_that.isExposing,_that.exposureStartTime,_that.currentExposureDuration,_that.aduHistory,_that.skyBrightnessHistory,_that.skyAduRate,_that.twilightMode,_that.lastImagePath,_that.lastImageData,_that.errorMessage,_that.warningMessage,_that.statusMessage,_that.showAduGraph,_that.showExposureTimeline,_that.showSkyBrightness,_that.showFilterCards,_that.showHistogramOverlay);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _FlatWizardState implements FlatWizardState {
  const _FlatWizardState({this.mode = FlatWizardMode.quick, this.globalSettings = const FlatWizardGlobalSettings(), final  List<FlatFilterSettings> filterSettings = const [], final  List<FlatFilterPreset> filterPresets = const [], this.currentFilterIndex = 0, this.currentFrameIndex = 0, this.isCapturing = false, this.isExposing = false, this.exposureStartTime, this.currentExposureDuration, final  List<AduMeasurement> aduHistory = const [], final  List<SkyBrightnessMeasurement> skyBrightnessHistory = const [], this.skyAduRate, this.twilightMode = TwilightMode.dusk, this.lastImagePath, @RuntimeOnlyValueConverter() this.lastImageData, this.errorMessage, this.warningMessage, this.statusMessage, this.showAduGraph = true, this.showExposureTimeline = true, this.showSkyBrightness = true, this.showFilterCards = true, this.showHistogramOverlay = false}): _filterSettings = filterSettings,_filterPresets = filterPresets,_aduHistory = aduHistory,_skyBrightnessHistory = skyBrightnessHistory;
  factory _FlatWizardState.fromJson(Map<String, dynamic> json) => _$FlatWizardStateFromJson(json);

/// Current operating mode
@override@JsonKey() final  FlatWizardMode mode;
/// Global settings
@override@JsonKey() final  FlatWizardGlobalSettings globalSettings;
/// Per-filter settings
 final  List<FlatFilterSettings> _filterSettings;
/// Per-filter settings
@override@JsonKey() List<FlatFilterSettings> get filterSettings {
  if (_filterSettings is EqualUnmodifiableListView) return _filterSettings;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_filterSettings);
}

/// Saved filter presets
 final  List<FlatFilterPreset> _filterPresets;
/// Saved filter presets
@override@JsonKey() List<FlatFilterPreset> get filterPresets {
  if (_filterPresets is EqualUnmodifiableListView) return _filterPresets;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_filterPresets);
}

/// Current filter index being processed
@override@JsonKey() final  int currentFilterIndex;
/// Current frame index for active filter
@override@JsonKey() final  int currentFrameIndex;
/// Is capture/calibration in progress
@override@JsonKey() final  bool isCapturing;
/// Is currently exposing (for countdown)
@override@JsonKey() final  bool isExposing;
/// Current exposure start time (for countdown)
@override final  DateTime? exposureStartTime;
/// Current exposure duration (for countdown)
@override final  double? currentExposureDuration;
/// ADU measurements for convergence graph
 final  List<AduMeasurement> _aduHistory;
/// ADU measurements for convergence graph
@override@JsonKey() List<AduMeasurement> get aduHistory {
  if (_aduHistory is EqualUnmodifiableListView) return _aduHistory;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_aduHistory);
}

/// Sky brightness measurements for rate tracking
 final  List<SkyBrightnessMeasurement> _skyBrightnessHistory;
/// Sky brightness measurements for rate tracking
@override@JsonKey() List<SkyBrightnessMeasurement> get skyBrightnessHistory {
  if (_skyBrightnessHistory is EqualUnmodifiableListView) return _skyBrightnessHistory;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_skyBrightnessHistory);
}

/// Calculated sky brightness change rate (ADU/s)
@override final  double? skyAduRate;
/// Twilight mode for sky flats
@override@JsonKey() final  TwilightMode twilightMode;
/// Most recent captured image path
@override final  String? lastImagePath;
/// Most recent captured image data (for preview, runtime only)
@override@RuntimeOnlyValueConverter() final  Object? lastImageData;
/// Error message if any
@override final  String? errorMessage;
/// Warning message (non-fatal, informational)
@override final  String? warningMessage;
/// Status message for progress display
@override final  String? statusMessage;
/// Visualization toggles
@override@JsonKey() final  bool showAduGraph;
@override@JsonKey() final  bool showExposureTimeline;
@override@JsonKey() final  bool showSkyBrightness;
@override@JsonKey() final  bool showFilterCards;
@override@JsonKey() final  bool showHistogramOverlay;

/// Create a copy of FlatWizardState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$FlatWizardStateCopyWith<_FlatWizardState> get copyWith => __$FlatWizardStateCopyWithImpl<_FlatWizardState>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$FlatWizardStateToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _FlatWizardState&&(identical(other.mode, mode) || other.mode == mode)&&(identical(other.globalSettings, globalSettings) || other.globalSettings == globalSettings)&&const DeepCollectionEquality().equals(other._filterSettings, _filterSettings)&&const DeepCollectionEquality().equals(other._filterPresets, _filterPresets)&&(identical(other.currentFilterIndex, currentFilterIndex) || other.currentFilterIndex == currentFilterIndex)&&(identical(other.currentFrameIndex, currentFrameIndex) || other.currentFrameIndex == currentFrameIndex)&&(identical(other.isCapturing, isCapturing) || other.isCapturing == isCapturing)&&(identical(other.isExposing, isExposing) || other.isExposing == isExposing)&&(identical(other.exposureStartTime, exposureStartTime) || other.exposureStartTime == exposureStartTime)&&(identical(other.currentExposureDuration, currentExposureDuration) || other.currentExposureDuration == currentExposureDuration)&&const DeepCollectionEquality().equals(other._aduHistory, _aduHistory)&&const DeepCollectionEquality().equals(other._skyBrightnessHistory, _skyBrightnessHistory)&&(identical(other.skyAduRate, skyAduRate) || other.skyAduRate == skyAduRate)&&(identical(other.twilightMode, twilightMode) || other.twilightMode == twilightMode)&&(identical(other.lastImagePath, lastImagePath) || other.lastImagePath == lastImagePath)&&const DeepCollectionEquality().equals(other.lastImageData, lastImageData)&&(identical(other.errorMessage, errorMessage) || other.errorMessage == errorMessage)&&(identical(other.warningMessage, warningMessage) || other.warningMessage == warningMessage)&&(identical(other.statusMessage, statusMessage) || other.statusMessage == statusMessage)&&(identical(other.showAduGraph, showAduGraph) || other.showAduGraph == showAduGraph)&&(identical(other.showExposureTimeline, showExposureTimeline) || other.showExposureTimeline == showExposureTimeline)&&(identical(other.showSkyBrightness, showSkyBrightness) || other.showSkyBrightness == showSkyBrightness)&&(identical(other.showFilterCards, showFilterCards) || other.showFilterCards == showFilterCards)&&(identical(other.showHistogramOverlay, showHistogramOverlay) || other.showHistogramOverlay == showHistogramOverlay));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,mode,globalSettings,const DeepCollectionEquality().hash(_filterSettings),const DeepCollectionEquality().hash(_filterPresets),currentFilterIndex,currentFrameIndex,isCapturing,isExposing,exposureStartTime,currentExposureDuration,const DeepCollectionEquality().hash(_aduHistory),const DeepCollectionEquality().hash(_skyBrightnessHistory),skyAduRate,twilightMode,lastImagePath,const DeepCollectionEquality().hash(lastImageData),errorMessage,warningMessage,statusMessage,showAduGraph,showExposureTimeline,showSkyBrightness,showFilterCards,showHistogramOverlay]);

@override
String toString() {
  return 'FlatWizardState(mode: $mode, globalSettings: $globalSettings, filterSettings: $filterSettings, filterPresets: $filterPresets, currentFilterIndex: $currentFilterIndex, currentFrameIndex: $currentFrameIndex, isCapturing: $isCapturing, isExposing: $isExposing, exposureStartTime: $exposureStartTime, currentExposureDuration: $currentExposureDuration, aduHistory: $aduHistory, skyBrightnessHistory: $skyBrightnessHistory, skyAduRate: $skyAduRate, twilightMode: $twilightMode, lastImagePath: $lastImagePath, lastImageData: $lastImageData, errorMessage: $errorMessage, warningMessage: $warningMessage, statusMessage: $statusMessage, showAduGraph: $showAduGraph, showExposureTimeline: $showExposureTimeline, showSkyBrightness: $showSkyBrightness, showFilterCards: $showFilterCards, showHistogramOverlay: $showHistogramOverlay)';
}


}

/// @nodoc
abstract mixin class _$FlatWizardStateCopyWith<$Res> implements $FlatWizardStateCopyWith<$Res> {
  factory _$FlatWizardStateCopyWith(_FlatWizardState value, $Res Function(_FlatWizardState) _then) = __$FlatWizardStateCopyWithImpl;
@override @useResult
$Res call({
 FlatWizardMode mode, FlatWizardGlobalSettings globalSettings, List<FlatFilterSettings> filterSettings, List<FlatFilterPreset> filterPresets, int currentFilterIndex, int currentFrameIndex, bool isCapturing, bool isExposing, DateTime? exposureStartTime, double? currentExposureDuration, List<AduMeasurement> aduHistory, List<SkyBrightnessMeasurement> skyBrightnessHistory, double? skyAduRate, TwilightMode twilightMode, String? lastImagePath,@RuntimeOnlyValueConverter() Object? lastImageData, String? errorMessage, String? warningMessage, String? statusMessage, bool showAduGraph, bool showExposureTimeline, bool showSkyBrightness, bool showFilterCards, bool showHistogramOverlay
});


@override $FlatWizardGlobalSettingsCopyWith<$Res> get globalSettings;

}
/// @nodoc
class __$FlatWizardStateCopyWithImpl<$Res>
    implements _$FlatWizardStateCopyWith<$Res> {
  __$FlatWizardStateCopyWithImpl(this._self, this._then);

  final _FlatWizardState _self;
  final $Res Function(_FlatWizardState) _then;

/// Create a copy of FlatWizardState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? mode = null,Object? globalSettings = null,Object? filterSettings = null,Object? filterPresets = null,Object? currentFilterIndex = null,Object? currentFrameIndex = null,Object? isCapturing = null,Object? isExposing = null,Object? exposureStartTime = freezed,Object? currentExposureDuration = freezed,Object? aduHistory = null,Object? skyBrightnessHistory = null,Object? skyAduRate = freezed,Object? twilightMode = null,Object? lastImagePath = freezed,Object? lastImageData = freezed,Object? errorMessage = freezed,Object? warningMessage = freezed,Object? statusMessage = freezed,Object? showAduGraph = null,Object? showExposureTimeline = null,Object? showSkyBrightness = null,Object? showFilterCards = null,Object? showHistogramOverlay = null,}) {
  return _then(_FlatWizardState(
mode: null == mode ? _self.mode : mode // ignore: cast_nullable_to_non_nullable
as FlatWizardMode,globalSettings: null == globalSettings ? _self.globalSettings : globalSettings // ignore: cast_nullable_to_non_nullable
as FlatWizardGlobalSettings,filterSettings: null == filterSettings ? _self._filterSettings : filterSettings // ignore: cast_nullable_to_non_nullable
as List<FlatFilterSettings>,filterPresets: null == filterPresets ? _self._filterPresets : filterPresets // ignore: cast_nullable_to_non_nullable
as List<FlatFilterPreset>,currentFilterIndex: null == currentFilterIndex ? _self.currentFilterIndex : currentFilterIndex // ignore: cast_nullable_to_non_nullable
as int,currentFrameIndex: null == currentFrameIndex ? _self.currentFrameIndex : currentFrameIndex // ignore: cast_nullable_to_non_nullable
as int,isCapturing: null == isCapturing ? _self.isCapturing : isCapturing // ignore: cast_nullable_to_non_nullable
as bool,isExposing: null == isExposing ? _self.isExposing : isExposing // ignore: cast_nullable_to_non_nullable
as bool,exposureStartTime: freezed == exposureStartTime ? _self.exposureStartTime : exposureStartTime // ignore: cast_nullable_to_non_nullable
as DateTime?,currentExposureDuration: freezed == currentExposureDuration ? _self.currentExposureDuration : currentExposureDuration // ignore: cast_nullable_to_non_nullable
as double?,aduHistory: null == aduHistory ? _self._aduHistory : aduHistory // ignore: cast_nullable_to_non_nullable
as List<AduMeasurement>,skyBrightnessHistory: null == skyBrightnessHistory ? _self._skyBrightnessHistory : skyBrightnessHistory // ignore: cast_nullable_to_non_nullable
as List<SkyBrightnessMeasurement>,skyAduRate: freezed == skyAduRate ? _self.skyAduRate : skyAduRate // ignore: cast_nullable_to_non_nullable
as double?,twilightMode: null == twilightMode ? _self.twilightMode : twilightMode // ignore: cast_nullable_to_non_nullable
as TwilightMode,lastImagePath: freezed == lastImagePath ? _self.lastImagePath : lastImagePath // ignore: cast_nullable_to_non_nullable
as String?,lastImageData: freezed == lastImageData ? _self.lastImageData : lastImageData ,errorMessage: freezed == errorMessage ? _self.errorMessage : errorMessage // ignore: cast_nullable_to_non_nullable
as String?,warningMessage: freezed == warningMessage ? _self.warningMessage : warningMessage // ignore: cast_nullable_to_non_nullable
as String?,statusMessage: freezed == statusMessage ? _self.statusMessage : statusMessage // ignore: cast_nullable_to_non_nullable
as String?,showAduGraph: null == showAduGraph ? _self.showAduGraph : showAduGraph // ignore: cast_nullable_to_non_nullable
as bool,showExposureTimeline: null == showExposureTimeline ? _self.showExposureTimeline : showExposureTimeline // ignore: cast_nullable_to_non_nullable
as bool,showSkyBrightness: null == showSkyBrightness ? _self.showSkyBrightness : showSkyBrightness // ignore: cast_nullable_to_non_nullable
as bool,showFilterCards: null == showFilterCards ? _self.showFilterCards : showFilterCards // ignore: cast_nullable_to_non_nullable
as bool,showHistogramOverlay: null == showHistogramOverlay ? _self.showHistogramOverlay : showHistogramOverlay // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

/// Create a copy of FlatWizardState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$FlatWizardGlobalSettingsCopyWith<$Res> get globalSettings {
  
  return $FlatWizardGlobalSettingsCopyWith<$Res>(_self.globalSettings, (value) {
    return _then(_self.copyWith(globalSettings: value));
  });
}
}

// dart format on
