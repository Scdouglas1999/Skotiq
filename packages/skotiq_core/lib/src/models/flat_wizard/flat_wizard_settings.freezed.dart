// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'flat_wizard_settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$FlatWizardGlobalSettings {

/// Target histogram percentage (0-100), default 50%
 double get histogramTarget;/// Tolerance as percentage of target (1-25), default 10%
 double get tolerancePercent;/// Minimum exposure in seconds
 double get minExposure;/// Maximum exposure in seconds
 double get maxExposure;/// Number of frames to capture per filter
 int get frameCount;/// Default gain for flats
 int get gain;/// Default binning for flats
 int get binning;/// Save path for flat frames
 String? get savePath;/// Create date subfolder
 bool get createDateSubfolder;/// Create filter subfolders
 bool get createFilterSubfolders;// Magic-number defaults promoted from
// hardcoded constants in flat_wizard_service.dart.
/// Per-frame download timeout (seconds). Was hardcoded
/// `_imageDownloadTimeout = Duration(seconds: 60)`. Increase for very
/// large sensors or slow USB hubs.
 int get imageDownloadTimeoutSeconds;/// Max binary-search iterations for the calibration solver. Was a
/// `int maxIterations = 8` default parameter in the service. Fewer
/// iterations exits faster on stubborn filters but risks missing the
/// target ADU; more iterations is slower but more accurate.
 int get maxIterations;
/// Create a copy of FlatWizardGlobalSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FlatWizardGlobalSettingsCopyWith<FlatWizardGlobalSettings> get copyWith => _$FlatWizardGlobalSettingsCopyWithImpl<FlatWizardGlobalSettings>(this as FlatWizardGlobalSettings, _$identity);

  /// Serializes this FlatWizardGlobalSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FlatWizardGlobalSettings&&(identical(other.histogramTarget, histogramTarget) || other.histogramTarget == histogramTarget)&&(identical(other.tolerancePercent, tolerancePercent) || other.tolerancePercent == tolerancePercent)&&(identical(other.minExposure, minExposure) || other.minExposure == minExposure)&&(identical(other.maxExposure, maxExposure) || other.maxExposure == maxExposure)&&(identical(other.frameCount, frameCount) || other.frameCount == frameCount)&&(identical(other.gain, gain) || other.gain == gain)&&(identical(other.binning, binning) || other.binning == binning)&&(identical(other.savePath, savePath) || other.savePath == savePath)&&(identical(other.createDateSubfolder, createDateSubfolder) || other.createDateSubfolder == createDateSubfolder)&&(identical(other.createFilterSubfolders, createFilterSubfolders) || other.createFilterSubfolders == createFilterSubfolders)&&(identical(other.imageDownloadTimeoutSeconds, imageDownloadTimeoutSeconds) || other.imageDownloadTimeoutSeconds == imageDownloadTimeoutSeconds)&&(identical(other.maxIterations, maxIterations) || other.maxIterations == maxIterations));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,histogramTarget,tolerancePercent,minExposure,maxExposure,frameCount,gain,binning,savePath,createDateSubfolder,createFilterSubfolders,imageDownloadTimeoutSeconds,maxIterations);

@override
String toString() {
  return 'FlatWizardGlobalSettings(histogramTarget: $histogramTarget, tolerancePercent: $tolerancePercent, minExposure: $minExposure, maxExposure: $maxExposure, frameCount: $frameCount, gain: $gain, binning: $binning, savePath: $savePath, createDateSubfolder: $createDateSubfolder, createFilterSubfolders: $createFilterSubfolders, imageDownloadTimeoutSeconds: $imageDownloadTimeoutSeconds, maxIterations: $maxIterations)';
}


}

/// @nodoc
abstract mixin class $FlatWizardGlobalSettingsCopyWith<$Res>  {
  factory $FlatWizardGlobalSettingsCopyWith(FlatWizardGlobalSettings value, $Res Function(FlatWizardGlobalSettings) _then) = _$FlatWizardGlobalSettingsCopyWithImpl;
@useResult
$Res call({
 double histogramTarget, double tolerancePercent, double minExposure, double maxExposure, int frameCount, int gain, int binning, String? savePath, bool createDateSubfolder, bool createFilterSubfolders, int imageDownloadTimeoutSeconds, int maxIterations
});




}
/// @nodoc
class _$FlatWizardGlobalSettingsCopyWithImpl<$Res>
    implements $FlatWizardGlobalSettingsCopyWith<$Res> {
  _$FlatWizardGlobalSettingsCopyWithImpl(this._self, this._then);

  final FlatWizardGlobalSettings _self;
  final $Res Function(FlatWizardGlobalSettings) _then;

/// Create a copy of FlatWizardGlobalSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? histogramTarget = null,Object? tolerancePercent = null,Object? minExposure = null,Object? maxExposure = null,Object? frameCount = null,Object? gain = null,Object? binning = null,Object? savePath = freezed,Object? createDateSubfolder = null,Object? createFilterSubfolders = null,Object? imageDownloadTimeoutSeconds = null,Object? maxIterations = null,}) {
  return _then(_self.copyWith(
histogramTarget: null == histogramTarget ? _self.histogramTarget : histogramTarget // ignore: cast_nullable_to_non_nullable
as double,tolerancePercent: null == tolerancePercent ? _self.tolerancePercent : tolerancePercent // ignore: cast_nullable_to_non_nullable
as double,minExposure: null == minExposure ? _self.minExposure : minExposure // ignore: cast_nullable_to_non_nullable
as double,maxExposure: null == maxExposure ? _self.maxExposure : maxExposure // ignore: cast_nullable_to_non_nullable
as double,frameCount: null == frameCount ? _self.frameCount : frameCount // ignore: cast_nullable_to_non_nullable
as int,gain: null == gain ? _self.gain : gain // ignore: cast_nullable_to_non_nullable
as int,binning: null == binning ? _self.binning : binning // ignore: cast_nullable_to_non_nullable
as int,savePath: freezed == savePath ? _self.savePath : savePath // ignore: cast_nullable_to_non_nullable
as String?,createDateSubfolder: null == createDateSubfolder ? _self.createDateSubfolder : createDateSubfolder // ignore: cast_nullable_to_non_nullable
as bool,createFilterSubfolders: null == createFilterSubfolders ? _self.createFilterSubfolders : createFilterSubfolders // ignore: cast_nullable_to_non_nullable
as bool,imageDownloadTimeoutSeconds: null == imageDownloadTimeoutSeconds ? _self.imageDownloadTimeoutSeconds : imageDownloadTimeoutSeconds // ignore: cast_nullable_to_non_nullable
as int,maxIterations: null == maxIterations ? _self.maxIterations : maxIterations // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [FlatWizardGlobalSettings].
extension FlatWizardGlobalSettingsPatterns on FlatWizardGlobalSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _FlatWizardGlobalSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _FlatWizardGlobalSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _FlatWizardGlobalSettings value)  $default,){
final _that = this;
switch (_that) {
case _FlatWizardGlobalSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _FlatWizardGlobalSettings value)?  $default,){
final _that = this;
switch (_that) {
case _FlatWizardGlobalSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double histogramTarget,  double tolerancePercent,  double minExposure,  double maxExposure,  int frameCount,  int gain,  int binning,  String? savePath,  bool createDateSubfolder,  bool createFilterSubfolders,  int imageDownloadTimeoutSeconds,  int maxIterations)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _FlatWizardGlobalSettings() when $default != null:
return $default(_that.histogramTarget,_that.tolerancePercent,_that.minExposure,_that.maxExposure,_that.frameCount,_that.gain,_that.binning,_that.savePath,_that.createDateSubfolder,_that.createFilterSubfolders,_that.imageDownloadTimeoutSeconds,_that.maxIterations);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double histogramTarget,  double tolerancePercent,  double minExposure,  double maxExposure,  int frameCount,  int gain,  int binning,  String? savePath,  bool createDateSubfolder,  bool createFilterSubfolders,  int imageDownloadTimeoutSeconds,  int maxIterations)  $default,) {final _that = this;
switch (_that) {
case _FlatWizardGlobalSettings():
return $default(_that.histogramTarget,_that.tolerancePercent,_that.minExposure,_that.maxExposure,_that.frameCount,_that.gain,_that.binning,_that.savePath,_that.createDateSubfolder,_that.createFilterSubfolders,_that.imageDownloadTimeoutSeconds,_that.maxIterations);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double histogramTarget,  double tolerancePercent,  double minExposure,  double maxExposure,  int frameCount,  int gain,  int binning,  String? savePath,  bool createDateSubfolder,  bool createFilterSubfolders,  int imageDownloadTimeoutSeconds,  int maxIterations)?  $default,) {final _that = this;
switch (_that) {
case _FlatWizardGlobalSettings() when $default != null:
return $default(_that.histogramTarget,_that.tolerancePercent,_that.minExposure,_that.maxExposure,_that.frameCount,_that.gain,_that.binning,_that.savePath,_that.createDateSubfolder,_that.createFilterSubfolders,_that.imageDownloadTimeoutSeconds,_that.maxIterations);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _FlatWizardGlobalSettings implements FlatWizardGlobalSettings {
  const _FlatWizardGlobalSettings({this.histogramTarget = 50.0, this.tolerancePercent = 10.0, this.minExposure = 0.001, this.maxExposure = 30.0, this.frameCount = 30, this.gain = 0, this.binning = 1, this.savePath, this.createDateSubfolder = true, this.createFilterSubfolders = true, this.imageDownloadTimeoutSeconds = 60, this.maxIterations = 8});
  factory _FlatWizardGlobalSettings.fromJson(Map<String, dynamic> json) => _$FlatWizardGlobalSettingsFromJson(json);

/// Target histogram percentage (0-100), default 50%
@override@JsonKey() final  double histogramTarget;
/// Tolerance as percentage of target (1-25), default 10%
@override@JsonKey() final  double tolerancePercent;
/// Minimum exposure in seconds
@override@JsonKey() final  double minExposure;
/// Maximum exposure in seconds
@override@JsonKey() final  double maxExposure;
/// Number of frames to capture per filter
@override@JsonKey() final  int frameCount;
/// Default gain for flats
@override@JsonKey() final  int gain;
/// Default binning for flats
@override@JsonKey() final  int binning;
/// Save path for flat frames
@override final  String? savePath;
/// Create date subfolder
@override@JsonKey() final  bool createDateSubfolder;
/// Create filter subfolders
@override@JsonKey() final  bool createFilterSubfolders;
// Magic-number defaults promoted from
// hardcoded constants in flat_wizard_service.dart.
/// Per-frame download timeout (seconds). Was hardcoded
/// `_imageDownloadTimeout = Duration(seconds: 60)`. Increase for very
/// large sensors or slow USB hubs.
@override@JsonKey() final  int imageDownloadTimeoutSeconds;
/// Max binary-search iterations for the calibration solver. Was a
/// `int maxIterations = 8` default parameter in the service. Fewer
/// iterations exits faster on stubborn filters but risks missing the
/// target ADU; more iterations is slower but more accurate.
@override@JsonKey() final  int maxIterations;

/// Create a copy of FlatWizardGlobalSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$FlatWizardGlobalSettingsCopyWith<_FlatWizardGlobalSettings> get copyWith => __$FlatWizardGlobalSettingsCopyWithImpl<_FlatWizardGlobalSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$FlatWizardGlobalSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _FlatWizardGlobalSettings&&(identical(other.histogramTarget, histogramTarget) || other.histogramTarget == histogramTarget)&&(identical(other.tolerancePercent, tolerancePercent) || other.tolerancePercent == tolerancePercent)&&(identical(other.minExposure, minExposure) || other.minExposure == minExposure)&&(identical(other.maxExposure, maxExposure) || other.maxExposure == maxExposure)&&(identical(other.frameCount, frameCount) || other.frameCount == frameCount)&&(identical(other.gain, gain) || other.gain == gain)&&(identical(other.binning, binning) || other.binning == binning)&&(identical(other.savePath, savePath) || other.savePath == savePath)&&(identical(other.createDateSubfolder, createDateSubfolder) || other.createDateSubfolder == createDateSubfolder)&&(identical(other.createFilterSubfolders, createFilterSubfolders) || other.createFilterSubfolders == createFilterSubfolders)&&(identical(other.imageDownloadTimeoutSeconds, imageDownloadTimeoutSeconds) || other.imageDownloadTimeoutSeconds == imageDownloadTimeoutSeconds)&&(identical(other.maxIterations, maxIterations) || other.maxIterations == maxIterations));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,histogramTarget,tolerancePercent,minExposure,maxExposure,frameCount,gain,binning,savePath,createDateSubfolder,createFilterSubfolders,imageDownloadTimeoutSeconds,maxIterations);

@override
String toString() {
  return 'FlatWizardGlobalSettings(histogramTarget: $histogramTarget, tolerancePercent: $tolerancePercent, minExposure: $minExposure, maxExposure: $maxExposure, frameCount: $frameCount, gain: $gain, binning: $binning, savePath: $savePath, createDateSubfolder: $createDateSubfolder, createFilterSubfolders: $createFilterSubfolders, imageDownloadTimeoutSeconds: $imageDownloadTimeoutSeconds, maxIterations: $maxIterations)';
}


}

/// @nodoc
abstract mixin class _$FlatWizardGlobalSettingsCopyWith<$Res> implements $FlatWizardGlobalSettingsCopyWith<$Res> {
  factory _$FlatWizardGlobalSettingsCopyWith(_FlatWizardGlobalSettings value, $Res Function(_FlatWizardGlobalSettings) _then) = __$FlatWizardGlobalSettingsCopyWithImpl;
@override @useResult
$Res call({
 double histogramTarget, double tolerancePercent, double minExposure, double maxExposure, int frameCount, int gain, int binning, String? savePath, bool createDateSubfolder, bool createFilterSubfolders, int imageDownloadTimeoutSeconds, int maxIterations
});




}
/// @nodoc
class __$FlatWizardGlobalSettingsCopyWithImpl<$Res>
    implements _$FlatWizardGlobalSettingsCopyWith<$Res> {
  __$FlatWizardGlobalSettingsCopyWithImpl(this._self, this._then);

  final _FlatWizardGlobalSettings _self;
  final $Res Function(_FlatWizardGlobalSettings) _then;

/// Create a copy of FlatWizardGlobalSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? histogramTarget = null,Object? tolerancePercent = null,Object? minExposure = null,Object? maxExposure = null,Object? frameCount = null,Object? gain = null,Object? binning = null,Object? savePath = freezed,Object? createDateSubfolder = null,Object? createFilterSubfolders = null,Object? imageDownloadTimeoutSeconds = null,Object? maxIterations = null,}) {
  return _then(_FlatWizardGlobalSettings(
histogramTarget: null == histogramTarget ? _self.histogramTarget : histogramTarget // ignore: cast_nullable_to_non_nullable
as double,tolerancePercent: null == tolerancePercent ? _self.tolerancePercent : tolerancePercent // ignore: cast_nullable_to_non_nullable
as double,minExposure: null == minExposure ? _self.minExposure : minExposure // ignore: cast_nullable_to_non_nullable
as double,maxExposure: null == maxExposure ? _self.maxExposure : maxExposure // ignore: cast_nullable_to_non_nullable
as double,frameCount: null == frameCount ? _self.frameCount : frameCount // ignore: cast_nullable_to_non_nullable
as int,gain: null == gain ? _self.gain : gain // ignore: cast_nullable_to_non_nullable
as int,binning: null == binning ? _self.binning : binning // ignore: cast_nullable_to_non_nullable
as int,savePath: freezed == savePath ? _self.savePath : savePath // ignore: cast_nullable_to_non_nullable
as String?,createDateSubfolder: null == createDateSubfolder ? _self.createDateSubfolder : createDateSubfolder // ignore: cast_nullable_to_non_nullable
as bool,createFilterSubfolders: null == createFilterSubfolders ? _self.createFilterSubfolders : createFilterSubfolders // ignore: cast_nullable_to_non_nullable
as bool,imageDownloadTimeoutSeconds: null == imageDownloadTimeoutSeconds ? _self.imageDownloadTimeoutSeconds : imageDownloadTimeoutSeconds // ignore: cast_nullable_to_non_nullable
as int,maxIterations: null == maxIterations ? _self.maxIterations : maxIterations // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}


/// @nodoc
mixin _$FlatFilterSettings {

 String get filterName;/// Filter position in wheel (0-indexed)
 int get filterPosition;/// Whether this filter is enabled for capture
 bool get enabled;/// Override histogram target (null = use global)
 double? get histogramTargetOverride;/// Override tolerance (null = use global)
 double? get toleranceOverride;/// Override min exposure (null = use global)
 double? get minExposureOverride;/// Override max exposure (null = use global)
 double? get maxExposureOverride;/// Override frame count (null = use global)
 int? get frameCountOverride;/// Suggested exposure from history (informational)
 double? get suggestedExposure;/// Current calibrated exposure (set after tuning)
 double? get calibratedExposure;/// Frames captured so far
 int get capturedCount;/// Current measured ADU
 double? get currentAdu;/// Calibration status
 FilterCalibrationStatus get status;
/// Create a copy of FlatFilterSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FlatFilterSettingsCopyWith<FlatFilterSettings> get copyWith => _$FlatFilterSettingsCopyWithImpl<FlatFilterSettings>(this as FlatFilterSettings, _$identity);

  /// Serializes this FlatFilterSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FlatFilterSettings&&(identical(other.filterName, filterName) || other.filterName == filterName)&&(identical(other.filterPosition, filterPosition) || other.filterPosition == filterPosition)&&(identical(other.enabled, enabled) || other.enabled == enabled)&&(identical(other.histogramTargetOverride, histogramTargetOverride) || other.histogramTargetOverride == histogramTargetOverride)&&(identical(other.toleranceOverride, toleranceOverride) || other.toleranceOverride == toleranceOverride)&&(identical(other.minExposureOverride, minExposureOverride) || other.minExposureOverride == minExposureOverride)&&(identical(other.maxExposureOverride, maxExposureOverride) || other.maxExposureOverride == maxExposureOverride)&&(identical(other.frameCountOverride, frameCountOverride) || other.frameCountOverride == frameCountOverride)&&(identical(other.suggestedExposure, suggestedExposure) || other.suggestedExposure == suggestedExposure)&&(identical(other.calibratedExposure, calibratedExposure) || other.calibratedExposure == calibratedExposure)&&(identical(other.capturedCount, capturedCount) || other.capturedCount == capturedCount)&&(identical(other.currentAdu, currentAdu) || other.currentAdu == currentAdu)&&(identical(other.status, status) || other.status == status));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,filterName,filterPosition,enabled,histogramTargetOverride,toleranceOverride,minExposureOverride,maxExposureOverride,frameCountOverride,suggestedExposure,calibratedExposure,capturedCount,currentAdu,status);

@override
String toString() {
  return 'FlatFilterSettings(filterName: $filterName, filterPosition: $filterPosition, enabled: $enabled, histogramTargetOverride: $histogramTargetOverride, toleranceOverride: $toleranceOverride, minExposureOverride: $minExposureOverride, maxExposureOverride: $maxExposureOverride, frameCountOverride: $frameCountOverride, suggestedExposure: $suggestedExposure, calibratedExposure: $calibratedExposure, capturedCount: $capturedCount, currentAdu: $currentAdu, status: $status)';
}


}

/// @nodoc
abstract mixin class $FlatFilterSettingsCopyWith<$Res>  {
  factory $FlatFilterSettingsCopyWith(FlatFilterSettings value, $Res Function(FlatFilterSettings) _then) = _$FlatFilterSettingsCopyWithImpl;
@useResult
$Res call({
 String filterName, int filterPosition, bool enabled, double? histogramTargetOverride, double? toleranceOverride, double? minExposureOverride, double? maxExposureOverride, int? frameCountOverride, double? suggestedExposure, double? calibratedExposure, int capturedCount, double? currentAdu, FilterCalibrationStatus status
});




}
/// @nodoc
class _$FlatFilterSettingsCopyWithImpl<$Res>
    implements $FlatFilterSettingsCopyWith<$Res> {
  _$FlatFilterSettingsCopyWithImpl(this._self, this._then);

  final FlatFilterSettings _self;
  final $Res Function(FlatFilterSettings) _then;

/// Create a copy of FlatFilterSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? filterName = null,Object? filterPosition = null,Object? enabled = null,Object? histogramTargetOverride = freezed,Object? toleranceOverride = freezed,Object? minExposureOverride = freezed,Object? maxExposureOverride = freezed,Object? frameCountOverride = freezed,Object? suggestedExposure = freezed,Object? calibratedExposure = freezed,Object? capturedCount = null,Object? currentAdu = freezed,Object? status = null,}) {
  return _then(_self.copyWith(
filterName: null == filterName ? _self.filterName : filterName // ignore: cast_nullable_to_non_nullable
as String,filterPosition: null == filterPosition ? _self.filterPosition : filterPosition // ignore: cast_nullable_to_non_nullable
as int,enabled: null == enabled ? _self.enabled : enabled // ignore: cast_nullable_to_non_nullable
as bool,histogramTargetOverride: freezed == histogramTargetOverride ? _self.histogramTargetOverride : histogramTargetOverride // ignore: cast_nullable_to_non_nullable
as double?,toleranceOverride: freezed == toleranceOverride ? _self.toleranceOverride : toleranceOverride // ignore: cast_nullable_to_non_nullable
as double?,minExposureOverride: freezed == minExposureOverride ? _self.minExposureOverride : minExposureOverride // ignore: cast_nullable_to_non_nullable
as double?,maxExposureOverride: freezed == maxExposureOverride ? _self.maxExposureOverride : maxExposureOverride // ignore: cast_nullable_to_non_nullable
as double?,frameCountOverride: freezed == frameCountOverride ? _self.frameCountOverride : frameCountOverride // ignore: cast_nullable_to_non_nullable
as int?,suggestedExposure: freezed == suggestedExposure ? _self.suggestedExposure : suggestedExposure // ignore: cast_nullable_to_non_nullable
as double?,calibratedExposure: freezed == calibratedExposure ? _self.calibratedExposure : calibratedExposure // ignore: cast_nullable_to_non_nullable
as double?,capturedCount: null == capturedCount ? _self.capturedCount : capturedCount // ignore: cast_nullable_to_non_nullable
as int,currentAdu: freezed == currentAdu ? _self.currentAdu : currentAdu // ignore: cast_nullable_to_non_nullable
as double?,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as FilterCalibrationStatus,
  ));
}

}


/// Adds pattern-matching-related methods to [FlatFilterSettings].
extension FlatFilterSettingsPatterns on FlatFilterSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _FlatFilterSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _FlatFilterSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _FlatFilterSettings value)  $default,){
final _that = this;
switch (_that) {
case _FlatFilterSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _FlatFilterSettings value)?  $default,){
final _that = this;
switch (_that) {
case _FlatFilterSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String filterName,  int filterPosition,  bool enabled,  double? histogramTargetOverride,  double? toleranceOverride,  double? minExposureOverride,  double? maxExposureOverride,  int? frameCountOverride,  double? suggestedExposure,  double? calibratedExposure,  int capturedCount,  double? currentAdu,  FilterCalibrationStatus status)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _FlatFilterSettings() when $default != null:
return $default(_that.filterName,_that.filterPosition,_that.enabled,_that.histogramTargetOverride,_that.toleranceOverride,_that.minExposureOverride,_that.maxExposureOverride,_that.frameCountOverride,_that.suggestedExposure,_that.calibratedExposure,_that.capturedCount,_that.currentAdu,_that.status);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String filterName,  int filterPosition,  bool enabled,  double? histogramTargetOverride,  double? toleranceOverride,  double? minExposureOverride,  double? maxExposureOverride,  int? frameCountOverride,  double? suggestedExposure,  double? calibratedExposure,  int capturedCount,  double? currentAdu,  FilterCalibrationStatus status)  $default,) {final _that = this;
switch (_that) {
case _FlatFilterSettings():
return $default(_that.filterName,_that.filterPosition,_that.enabled,_that.histogramTargetOverride,_that.toleranceOverride,_that.minExposureOverride,_that.maxExposureOverride,_that.frameCountOverride,_that.suggestedExposure,_that.calibratedExposure,_that.capturedCount,_that.currentAdu,_that.status);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String filterName,  int filterPosition,  bool enabled,  double? histogramTargetOverride,  double? toleranceOverride,  double? minExposureOverride,  double? maxExposureOverride,  int? frameCountOverride,  double? suggestedExposure,  double? calibratedExposure,  int capturedCount,  double? currentAdu,  FilterCalibrationStatus status)?  $default,) {final _that = this;
switch (_that) {
case _FlatFilterSettings() when $default != null:
return $default(_that.filterName,_that.filterPosition,_that.enabled,_that.histogramTargetOverride,_that.toleranceOverride,_that.minExposureOverride,_that.maxExposureOverride,_that.frameCountOverride,_that.suggestedExposure,_that.calibratedExposure,_that.capturedCount,_that.currentAdu,_that.status);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _FlatFilterSettings implements FlatFilterSettings {
  const _FlatFilterSettings({required this.filterName, required this.filterPosition, this.enabled = true, this.histogramTargetOverride, this.toleranceOverride, this.minExposureOverride, this.maxExposureOverride, this.frameCountOverride, this.suggestedExposure, this.calibratedExposure, this.capturedCount = 0, this.currentAdu, this.status = FilterCalibrationStatus.pending});
  factory _FlatFilterSettings.fromJson(Map<String, dynamic> json) => _$FlatFilterSettingsFromJson(json);

@override final  String filterName;
/// Filter position in wheel (0-indexed)
@override final  int filterPosition;
/// Whether this filter is enabled for capture
@override@JsonKey() final  bool enabled;
/// Override histogram target (null = use global)
@override final  double? histogramTargetOverride;
/// Override tolerance (null = use global)
@override final  double? toleranceOverride;
/// Override min exposure (null = use global)
@override final  double? minExposureOverride;
/// Override max exposure (null = use global)
@override final  double? maxExposureOverride;
/// Override frame count (null = use global)
@override final  int? frameCountOverride;
/// Suggested exposure from history (informational)
@override final  double? suggestedExposure;
/// Current calibrated exposure (set after tuning)
@override final  double? calibratedExposure;
/// Frames captured so far
@override@JsonKey() final  int capturedCount;
/// Current measured ADU
@override final  double? currentAdu;
/// Calibration status
@override@JsonKey() final  FilterCalibrationStatus status;

/// Create a copy of FlatFilterSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$FlatFilterSettingsCopyWith<_FlatFilterSettings> get copyWith => __$FlatFilterSettingsCopyWithImpl<_FlatFilterSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$FlatFilterSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _FlatFilterSettings&&(identical(other.filterName, filterName) || other.filterName == filterName)&&(identical(other.filterPosition, filterPosition) || other.filterPosition == filterPosition)&&(identical(other.enabled, enabled) || other.enabled == enabled)&&(identical(other.histogramTargetOverride, histogramTargetOverride) || other.histogramTargetOverride == histogramTargetOverride)&&(identical(other.toleranceOverride, toleranceOverride) || other.toleranceOverride == toleranceOverride)&&(identical(other.minExposureOverride, minExposureOverride) || other.minExposureOverride == minExposureOverride)&&(identical(other.maxExposureOverride, maxExposureOverride) || other.maxExposureOverride == maxExposureOverride)&&(identical(other.frameCountOverride, frameCountOverride) || other.frameCountOverride == frameCountOverride)&&(identical(other.suggestedExposure, suggestedExposure) || other.suggestedExposure == suggestedExposure)&&(identical(other.calibratedExposure, calibratedExposure) || other.calibratedExposure == calibratedExposure)&&(identical(other.capturedCount, capturedCount) || other.capturedCount == capturedCount)&&(identical(other.currentAdu, currentAdu) || other.currentAdu == currentAdu)&&(identical(other.status, status) || other.status == status));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,filterName,filterPosition,enabled,histogramTargetOverride,toleranceOverride,minExposureOverride,maxExposureOverride,frameCountOverride,suggestedExposure,calibratedExposure,capturedCount,currentAdu,status);

@override
String toString() {
  return 'FlatFilterSettings(filterName: $filterName, filterPosition: $filterPosition, enabled: $enabled, histogramTargetOverride: $histogramTargetOverride, toleranceOverride: $toleranceOverride, minExposureOverride: $minExposureOverride, maxExposureOverride: $maxExposureOverride, frameCountOverride: $frameCountOverride, suggestedExposure: $suggestedExposure, calibratedExposure: $calibratedExposure, capturedCount: $capturedCount, currentAdu: $currentAdu, status: $status)';
}


}

/// @nodoc
abstract mixin class _$FlatFilterSettingsCopyWith<$Res> implements $FlatFilterSettingsCopyWith<$Res> {
  factory _$FlatFilterSettingsCopyWith(_FlatFilterSettings value, $Res Function(_FlatFilterSettings) _then) = __$FlatFilterSettingsCopyWithImpl;
@override @useResult
$Res call({
 String filterName, int filterPosition, bool enabled, double? histogramTargetOverride, double? toleranceOverride, double? minExposureOverride, double? maxExposureOverride, int? frameCountOverride, double? suggestedExposure, double? calibratedExposure, int capturedCount, double? currentAdu, FilterCalibrationStatus status
});




}
/// @nodoc
class __$FlatFilterSettingsCopyWithImpl<$Res>
    implements _$FlatFilterSettingsCopyWith<$Res> {
  __$FlatFilterSettingsCopyWithImpl(this._self, this._then);

  final _FlatFilterSettings _self;
  final $Res Function(_FlatFilterSettings) _then;

/// Create a copy of FlatFilterSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? filterName = null,Object? filterPosition = null,Object? enabled = null,Object? histogramTargetOverride = freezed,Object? toleranceOverride = freezed,Object? minExposureOverride = freezed,Object? maxExposureOverride = freezed,Object? frameCountOverride = freezed,Object? suggestedExposure = freezed,Object? calibratedExposure = freezed,Object? capturedCount = null,Object? currentAdu = freezed,Object? status = null,}) {
  return _then(_FlatFilterSettings(
filterName: null == filterName ? _self.filterName : filterName // ignore: cast_nullable_to_non_nullable
as String,filterPosition: null == filterPosition ? _self.filterPosition : filterPosition // ignore: cast_nullable_to_non_nullable
as int,enabled: null == enabled ? _self.enabled : enabled // ignore: cast_nullable_to_non_nullable
as bool,histogramTargetOverride: freezed == histogramTargetOverride ? _self.histogramTargetOverride : histogramTargetOverride // ignore: cast_nullable_to_non_nullable
as double?,toleranceOverride: freezed == toleranceOverride ? _self.toleranceOverride : toleranceOverride // ignore: cast_nullable_to_non_nullable
as double?,minExposureOverride: freezed == minExposureOverride ? _self.minExposureOverride : minExposureOverride // ignore: cast_nullable_to_non_nullable
as double?,maxExposureOverride: freezed == maxExposureOverride ? _self.maxExposureOverride : maxExposureOverride // ignore: cast_nullable_to_non_nullable
as double?,frameCountOverride: freezed == frameCountOverride ? _self.frameCountOverride : frameCountOverride // ignore: cast_nullable_to_non_nullable
as int?,suggestedExposure: freezed == suggestedExposure ? _self.suggestedExposure : suggestedExposure // ignore: cast_nullable_to_non_nullable
as double?,calibratedExposure: freezed == calibratedExposure ? _self.calibratedExposure : calibratedExposure // ignore: cast_nullable_to_non_nullable
as double?,capturedCount: null == capturedCount ? _self.capturedCount : capturedCount // ignore: cast_nullable_to_non_nullable
as int,currentAdu: freezed == currentAdu ? _self.currentAdu : currentAdu // ignore: cast_nullable_to_non_nullable
as double?,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as FilterCalibrationStatus,
  ));
}


}


/// @nodoc
mixin _$FlatFilterPreset {

 String get name; List<String> get filterNames;
/// Create a copy of FlatFilterPreset
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FlatFilterPresetCopyWith<FlatFilterPreset> get copyWith => _$FlatFilterPresetCopyWithImpl<FlatFilterPreset>(this as FlatFilterPreset, _$identity);

  /// Serializes this FlatFilterPreset to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FlatFilterPreset&&(identical(other.name, name) || other.name == name)&&const DeepCollectionEquality().equals(other.filterNames, filterNames));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,name,const DeepCollectionEquality().hash(filterNames));

@override
String toString() {
  return 'FlatFilterPreset(name: $name, filterNames: $filterNames)';
}


}

/// @nodoc
abstract mixin class $FlatFilterPresetCopyWith<$Res>  {
  factory $FlatFilterPresetCopyWith(FlatFilterPreset value, $Res Function(FlatFilterPreset) _then) = _$FlatFilterPresetCopyWithImpl;
@useResult
$Res call({
 String name, List<String> filterNames
});




}
/// @nodoc
class _$FlatFilterPresetCopyWithImpl<$Res>
    implements $FlatFilterPresetCopyWith<$Res> {
  _$FlatFilterPresetCopyWithImpl(this._self, this._then);

  final FlatFilterPreset _self;
  final $Res Function(FlatFilterPreset) _then;

/// Create a copy of FlatFilterPreset
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? name = null,Object? filterNames = null,}) {
  return _then(_self.copyWith(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,filterNames: null == filterNames ? _self.filterNames : filterNames // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}

}


/// Adds pattern-matching-related methods to [FlatFilterPreset].
extension FlatFilterPresetPatterns on FlatFilterPreset {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _FlatFilterPreset value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _FlatFilterPreset() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _FlatFilterPreset value)  $default,){
final _that = this;
switch (_that) {
case _FlatFilterPreset():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _FlatFilterPreset value)?  $default,){
final _that = this;
switch (_that) {
case _FlatFilterPreset() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String name,  List<String> filterNames)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _FlatFilterPreset() when $default != null:
return $default(_that.name,_that.filterNames);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String name,  List<String> filterNames)  $default,) {final _that = this;
switch (_that) {
case _FlatFilterPreset():
return $default(_that.name,_that.filterNames);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String name,  List<String> filterNames)?  $default,) {final _that = this;
switch (_that) {
case _FlatFilterPreset() when $default != null:
return $default(_that.name,_that.filterNames);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _FlatFilterPreset implements FlatFilterPreset {
  const _FlatFilterPreset({required this.name, required final  List<String> filterNames}): _filterNames = filterNames;
  factory _FlatFilterPreset.fromJson(Map<String, dynamic> json) => _$FlatFilterPresetFromJson(json);

@override final  String name;
 final  List<String> _filterNames;
@override List<String> get filterNames {
  if (_filterNames is EqualUnmodifiableListView) return _filterNames;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_filterNames);
}


/// Create a copy of FlatFilterPreset
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$FlatFilterPresetCopyWith<_FlatFilterPreset> get copyWith => __$FlatFilterPresetCopyWithImpl<_FlatFilterPreset>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$FlatFilterPresetToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _FlatFilterPreset&&(identical(other.name, name) || other.name == name)&&const DeepCollectionEquality().equals(other._filterNames, _filterNames));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,name,const DeepCollectionEquality().hash(_filterNames));

@override
String toString() {
  return 'FlatFilterPreset(name: $name, filterNames: $filterNames)';
}


}

/// @nodoc
abstract mixin class _$FlatFilterPresetCopyWith<$Res> implements $FlatFilterPresetCopyWith<$Res> {
  factory _$FlatFilterPresetCopyWith(_FlatFilterPreset value, $Res Function(_FlatFilterPreset) _then) = __$FlatFilterPresetCopyWithImpl;
@override @useResult
$Res call({
 String name, List<String> filterNames
});




}
/// @nodoc
class __$FlatFilterPresetCopyWithImpl<$Res>
    implements _$FlatFilterPresetCopyWith<$Res> {
  __$FlatFilterPresetCopyWithImpl(this._self, this._then);

  final _FlatFilterPreset _self;
  final $Res Function(_FlatFilterPreset) _then;

/// Create a copy of FlatFilterPreset
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? filterNames = null,}) {
  return _then(_FlatFilterPreset(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,filterNames: null == filterNames ? _self._filterNames : filterNames // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}


}

// dart format on
