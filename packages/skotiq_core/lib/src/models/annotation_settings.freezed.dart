// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'annotation_settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$AnnotationSettings {

/// Whether annotations are enabled
 bool get enabled;/// Magnitude cutoff for displayed objects (fainter = higher number)
 double get magnitudeCutoff;/// Minimum magnitude to display (brighter = lower number)
 double get minMagnitude;/// Object types to display
 Set<AnnotationObjectFilter> get visibleTypes;/// Whether to show object labels
 bool get showLabels;/// Whether to show magnitude values
 bool get showMagnitudes;/// Whether to fade annotations when mouse is not over image
 bool get fadeWhenNotHovering;/// Opacity when mouse is hovering over image (0.0-1.0)
 double get hoverOpacity;/// Opacity when mouse is not hovering (0.0-1.0)
 double get idleOpacity;/// Duration of fade animation in milliseconds
 int get fadeAnimationMs;/// Whether to enable click-to-identify
 bool get clickToIdentify;/// Search radius for click-to-identify in arcseconds
 double get clickSearchRadiusArcsec;/// Whether to auto-annotate new captured images
 bool get autoAnnotate;/// Maximum number of objects to display
 int get maxObjectsToDisplay;/// Fractional padding around the
/// catalog FOV bounding box. 0.05 = 5% padding (the historical
/// hardcoded default). Increase if large DSOs whose centre is just
/// off-frame are getting clipped from the overlay; decrease to query
/// faster on slow disks.
 double get catalogBboxPaddingFraction;/// Whether to show compass overlay (N/E arrows from plate solve rotation)
 bool get compassEnabled;/// Whether to show scale bar overlay (angular size reference)
 bool get scaleBarEnabled;/// Grid overlay type (none, pixel, or celestial RA/Dec)
 GridType get gridType;/// Whether to show plate solve residual vectors overlay
 bool get showSolveResiduals;
/// Create a copy of AnnotationSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AnnotationSettingsCopyWith<AnnotationSettings> get copyWith => _$AnnotationSettingsCopyWithImpl<AnnotationSettings>(this as AnnotationSettings, _$identity);

  /// Serializes this AnnotationSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AnnotationSettings&&(identical(other.enabled, enabled) || other.enabled == enabled)&&(identical(other.magnitudeCutoff, magnitudeCutoff) || other.magnitudeCutoff == magnitudeCutoff)&&(identical(other.minMagnitude, minMagnitude) || other.minMagnitude == minMagnitude)&&const DeepCollectionEquality().equals(other.visibleTypes, visibleTypes)&&(identical(other.showLabels, showLabels) || other.showLabels == showLabels)&&(identical(other.showMagnitudes, showMagnitudes) || other.showMagnitudes == showMagnitudes)&&(identical(other.fadeWhenNotHovering, fadeWhenNotHovering) || other.fadeWhenNotHovering == fadeWhenNotHovering)&&(identical(other.hoverOpacity, hoverOpacity) || other.hoverOpacity == hoverOpacity)&&(identical(other.idleOpacity, idleOpacity) || other.idleOpacity == idleOpacity)&&(identical(other.fadeAnimationMs, fadeAnimationMs) || other.fadeAnimationMs == fadeAnimationMs)&&(identical(other.clickToIdentify, clickToIdentify) || other.clickToIdentify == clickToIdentify)&&(identical(other.clickSearchRadiusArcsec, clickSearchRadiusArcsec) || other.clickSearchRadiusArcsec == clickSearchRadiusArcsec)&&(identical(other.autoAnnotate, autoAnnotate) || other.autoAnnotate == autoAnnotate)&&(identical(other.maxObjectsToDisplay, maxObjectsToDisplay) || other.maxObjectsToDisplay == maxObjectsToDisplay)&&(identical(other.catalogBboxPaddingFraction, catalogBboxPaddingFraction) || other.catalogBboxPaddingFraction == catalogBboxPaddingFraction)&&(identical(other.compassEnabled, compassEnabled) || other.compassEnabled == compassEnabled)&&(identical(other.scaleBarEnabled, scaleBarEnabled) || other.scaleBarEnabled == scaleBarEnabled)&&(identical(other.gridType, gridType) || other.gridType == gridType)&&(identical(other.showSolveResiduals, showSolveResiduals) || other.showSolveResiduals == showSolveResiduals));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,enabled,magnitudeCutoff,minMagnitude,const DeepCollectionEquality().hash(visibleTypes),showLabels,showMagnitudes,fadeWhenNotHovering,hoverOpacity,idleOpacity,fadeAnimationMs,clickToIdentify,clickSearchRadiusArcsec,autoAnnotate,maxObjectsToDisplay,catalogBboxPaddingFraction,compassEnabled,scaleBarEnabled,gridType,showSolveResiduals]);

@override
String toString() {
  return 'AnnotationSettings(enabled: $enabled, magnitudeCutoff: $magnitudeCutoff, minMagnitude: $minMagnitude, visibleTypes: $visibleTypes, showLabels: $showLabels, showMagnitudes: $showMagnitudes, fadeWhenNotHovering: $fadeWhenNotHovering, hoverOpacity: $hoverOpacity, idleOpacity: $idleOpacity, fadeAnimationMs: $fadeAnimationMs, clickToIdentify: $clickToIdentify, clickSearchRadiusArcsec: $clickSearchRadiusArcsec, autoAnnotate: $autoAnnotate, maxObjectsToDisplay: $maxObjectsToDisplay, catalogBboxPaddingFraction: $catalogBboxPaddingFraction, compassEnabled: $compassEnabled, scaleBarEnabled: $scaleBarEnabled, gridType: $gridType, showSolveResiduals: $showSolveResiduals)';
}


}

/// @nodoc
abstract mixin class $AnnotationSettingsCopyWith<$Res>  {
  factory $AnnotationSettingsCopyWith(AnnotationSettings value, $Res Function(AnnotationSettings) _then) = _$AnnotationSettingsCopyWithImpl;
@useResult
$Res call({
 bool enabled, double magnitudeCutoff, double minMagnitude, Set<AnnotationObjectFilter> visibleTypes, bool showLabels, bool showMagnitudes, bool fadeWhenNotHovering, double hoverOpacity, double idleOpacity, int fadeAnimationMs, bool clickToIdentify, double clickSearchRadiusArcsec, bool autoAnnotate, int maxObjectsToDisplay, double catalogBboxPaddingFraction, bool compassEnabled, bool scaleBarEnabled, GridType gridType, bool showSolveResiduals
});




}
/// @nodoc
class _$AnnotationSettingsCopyWithImpl<$Res>
    implements $AnnotationSettingsCopyWith<$Res> {
  _$AnnotationSettingsCopyWithImpl(this._self, this._then);

  final AnnotationSettings _self;
  final $Res Function(AnnotationSettings) _then;

/// Create a copy of AnnotationSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? enabled = null,Object? magnitudeCutoff = null,Object? minMagnitude = null,Object? visibleTypes = null,Object? showLabels = null,Object? showMagnitudes = null,Object? fadeWhenNotHovering = null,Object? hoverOpacity = null,Object? idleOpacity = null,Object? fadeAnimationMs = null,Object? clickToIdentify = null,Object? clickSearchRadiusArcsec = null,Object? autoAnnotate = null,Object? maxObjectsToDisplay = null,Object? catalogBboxPaddingFraction = null,Object? compassEnabled = null,Object? scaleBarEnabled = null,Object? gridType = null,Object? showSolveResiduals = null,}) {
  return _then(_self.copyWith(
enabled: null == enabled ? _self.enabled : enabled // ignore: cast_nullable_to_non_nullable
as bool,magnitudeCutoff: null == magnitudeCutoff ? _self.magnitudeCutoff : magnitudeCutoff // ignore: cast_nullable_to_non_nullable
as double,minMagnitude: null == minMagnitude ? _self.minMagnitude : minMagnitude // ignore: cast_nullable_to_non_nullable
as double,visibleTypes: null == visibleTypes ? _self.visibleTypes : visibleTypes // ignore: cast_nullable_to_non_nullable
as Set<AnnotationObjectFilter>,showLabels: null == showLabels ? _self.showLabels : showLabels // ignore: cast_nullable_to_non_nullable
as bool,showMagnitudes: null == showMagnitudes ? _self.showMagnitudes : showMagnitudes // ignore: cast_nullable_to_non_nullable
as bool,fadeWhenNotHovering: null == fadeWhenNotHovering ? _self.fadeWhenNotHovering : fadeWhenNotHovering // ignore: cast_nullable_to_non_nullable
as bool,hoverOpacity: null == hoverOpacity ? _self.hoverOpacity : hoverOpacity // ignore: cast_nullable_to_non_nullable
as double,idleOpacity: null == idleOpacity ? _self.idleOpacity : idleOpacity // ignore: cast_nullable_to_non_nullable
as double,fadeAnimationMs: null == fadeAnimationMs ? _self.fadeAnimationMs : fadeAnimationMs // ignore: cast_nullable_to_non_nullable
as int,clickToIdentify: null == clickToIdentify ? _self.clickToIdentify : clickToIdentify // ignore: cast_nullable_to_non_nullable
as bool,clickSearchRadiusArcsec: null == clickSearchRadiusArcsec ? _self.clickSearchRadiusArcsec : clickSearchRadiusArcsec // ignore: cast_nullable_to_non_nullable
as double,autoAnnotate: null == autoAnnotate ? _self.autoAnnotate : autoAnnotate // ignore: cast_nullable_to_non_nullable
as bool,maxObjectsToDisplay: null == maxObjectsToDisplay ? _self.maxObjectsToDisplay : maxObjectsToDisplay // ignore: cast_nullable_to_non_nullable
as int,catalogBboxPaddingFraction: null == catalogBboxPaddingFraction ? _self.catalogBboxPaddingFraction : catalogBboxPaddingFraction // ignore: cast_nullable_to_non_nullable
as double,compassEnabled: null == compassEnabled ? _self.compassEnabled : compassEnabled // ignore: cast_nullable_to_non_nullable
as bool,scaleBarEnabled: null == scaleBarEnabled ? _self.scaleBarEnabled : scaleBarEnabled // ignore: cast_nullable_to_non_nullable
as bool,gridType: null == gridType ? _self.gridType : gridType // ignore: cast_nullable_to_non_nullable
as GridType,showSolveResiduals: null == showSolveResiduals ? _self.showSolveResiduals : showSolveResiduals // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [AnnotationSettings].
extension AnnotationSettingsPatterns on AnnotationSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AnnotationSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AnnotationSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AnnotationSettings value)  $default,){
final _that = this;
switch (_that) {
case _AnnotationSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AnnotationSettings value)?  $default,){
final _that = this;
switch (_that) {
case _AnnotationSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool enabled,  double magnitudeCutoff,  double minMagnitude,  Set<AnnotationObjectFilter> visibleTypes,  bool showLabels,  bool showMagnitudes,  bool fadeWhenNotHovering,  double hoverOpacity,  double idleOpacity,  int fadeAnimationMs,  bool clickToIdentify,  double clickSearchRadiusArcsec,  bool autoAnnotate,  int maxObjectsToDisplay,  double catalogBboxPaddingFraction,  bool compassEnabled,  bool scaleBarEnabled,  GridType gridType,  bool showSolveResiduals)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AnnotationSettings() when $default != null:
return $default(_that.enabled,_that.magnitudeCutoff,_that.minMagnitude,_that.visibleTypes,_that.showLabels,_that.showMagnitudes,_that.fadeWhenNotHovering,_that.hoverOpacity,_that.idleOpacity,_that.fadeAnimationMs,_that.clickToIdentify,_that.clickSearchRadiusArcsec,_that.autoAnnotate,_that.maxObjectsToDisplay,_that.catalogBboxPaddingFraction,_that.compassEnabled,_that.scaleBarEnabled,_that.gridType,_that.showSolveResiduals);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool enabled,  double magnitudeCutoff,  double minMagnitude,  Set<AnnotationObjectFilter> visibleTypes,  bool showLabels,  bool showMagnitudes,  bool fadeWhenNotHovering,  double hoverOpacity,  double idleOpacity,  int fadeAnimationMs,  bool clickToIdentify,  double clickSearchRadiusArcsec,  bool autoAnnotate,  int maxObjectsToDisplay,  double catalogBboxPaddingFraction,  bool compassEnabled,  bool scaleBarEnabled,  GridType gridType,  bool showSolveResiduals)  $default,) {final _that = this;
switch (_that) {
case _AnnotationSettings():
return $default(_that.enabled,_that.magnitudeCutoff,_that.minMagnitude,_that.visibleTypes,_that.showLabels,_that.showMagnitudes,_that.fadeWhenNotHovering,_that.hoverOpacity,_that.idleOpacity,_that.fadeAnimationMs,_that.clickToIdentify,_that.clickSearchRadiusArcsec,_that.autoAnnotate,_that.maxObjectsToDisplay,_that.catalogBboxPaddingFraction,_that.compassEnabled,_that.scaleBarEnabled,_that.gridType,_that.showSolveResiduals);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool enabled,  double magnitudeCutoff,  double minMagnitude,  Set<AnnotationObjectFilter> visibleTypes,  bool showLabels,  bool showMagnitudes,  bool fadeWhenNotHovering,  double hoverOpacity,  double idleOpacity,  int fadeAnimationMs,  bool clickToIdentify,  double clickSearchRadiusArcsec,  bool autoAnnotate,  int maxObjectsToDisplay,  double catalogBboxPaddingFraction,  bool compassEnabled,  bool scaleBarEnabled,  GridType gridType,  bool showSolveResiduals)?  $default,) {final _that = this;
switch (_that) {
case _AnnotationSettings() when $default != null:
return $default(_that.enabled,_that.magnitudeCutoff,_that.minMagnitude,_that.visibleTypes,_that.showLabels,_that.showMagnitudes,_that.fadeWhenNotHovering,_that.hoverOpacity,_that.idleOpacity,_that.fadeAnimationMs,_that.clickToIdentify,_that.clickSearchRadiusArcsec,_that.autoAnnotate,_that.maxObjectsToDisplay,_that.catalogBboxPaddingFraction,_that.compassEnabled,_that.scaleBarEnabled,_that.gridType,_that.showSolveResiduals);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AnnotationSettings implements AnnotationSettings {
  const _AnnotationSettings({this.enabled = true, this.magnitudeCutoff = 15.0, this.minMagnitude = -5.0, final  Set<AnnotationObjectFilter> visibleTypes = const {AnnotationObjectFilter.galaxies, AnnotationObjectFilter.nebulae, AnnotationObjectFilter.starClusters, AnnotationObjectFilter.planetaryNebulae}, this.showLabels = true, this.showMagnitudes = false, this.fadeWhenNotHovering = true, this.hoverOpacity = 0.8, this.idleOpacity = 0.2, this.fadeAnimationMs = 400, this.clickToIdentify = true, this.clickSearchRadiusArcsec = 30.0, this.autoAnnotate = true, this.maxObjectsToDisplay = 500, this.catalogBboxPaddingFraction = 0.05, this.compassEnabled = true, this.scaleBarEnabled = true, this.gridType = GridType.none, this.showSolveResiduals = false}): _visibleTypes = visibleTypes;
  factory _AnnotationSettings.fromJson(Map<String, dynamic> json) => _$AnnotationSettingsFromJson(json);

/// Whether annotations are enabled
@override@JsonKey() final  bool enabled;
/// Magnitude cutoff for displayed objects (fainter = higher number)
@override@JsonKey() final  double magnitudeCutoff;
/// Minimum magnitude to display (brighter = lower number)
@override@JsonKey() final  double minMagnitude;
/// Object types to display
 final  Set<AnnotationObjectFilter> _visibleTypes;
/// Object types to display
@override@JsonKey() Set<AnnotationObjectFilter> get visibleTypes {
  if (_visibleTypes is EqualUnmodifiableSetView) return _visibleTypes;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableSetView(_visibleTypes);
}

/// Whether to show object labels
@override@JsonKey() final  bool showLabels;
/// Whether to show magnitude values
@override@JsonKey() final  bool showMagnitudes;
/// Whether to fade annotations when mouse is not over image
@override@JsonKey() final  bool fadeWhenNotHovering;
/// Opacity when mouse is hovering over image (0.0-1.0)
@override@JsonKey() final  double hoverOpacity;
/// Opacity when mouse is not hovering (0.0-1.0)
@override@JsonKey() final  double idleOpacity;
/// Duration of fade animation in milliseconds
@override@JsonKey() final  int fadeAnimationMs;
/// Whether to enable click-to-identify
@override@JsonKey() final  bool clickToIdentify;
/// Search radius for click-to-identify in arcseconds
@override@JsonKey() final  double clickSearchRadiusArcsec;
/// Whether to auto-annotate new captured images
@override@JsonKey() final  bool autoAnnotate;
/// Maximum number of objects to display
@override@JsonKey() final  int maxObjectsToDisplay;
/// Fractional padding around the
/// catalog FOV bounding box. 0.05 = 5% padding (the historical
/// hardcoded default). Increase if large DSOs whose centre is just
/// off-frame are getting clipped from the overlay; decrease to query
/// faster on slow disks.
@override@JsonKey() final  double catalogBboxPaddingFraction;
/// Whether to show compass overlay (N/E arrows from plate solve rotation)
@override@JsonKey() final  bool compassEnabled;
/// Whether to show scale bar overlay (angular size reference)
@override@JsonKey() final  bool scaleBarEnabled;
/// Grid overlay type (none, pixel, or celestial RA/Dec)
@override@JsonKey() final  GridType gridType;
/// Whether to show plate solve residual vectors overlay
@override@JsonKey() final  bool showSolveResiduals;

/// Create a copy of AnnotationSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AnnotationSettingsCopyWith<_AnnotationSettings> get copyWith => __$AnnotationSettingsCopyWithImpl<_AnnotationSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AnnotationSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AnnotationSettings&&(identical(other.enabled, enabled) || other.enabled == enabled)&&(identical(other.magnitudeCutoff, magnitudeCutoff) || other.magnitudeCutoff == magnitudeCutoff)&&(identical(other.minMagnitude, minMagnitude) || other.minMagnitude == minMagnitude)&&const DeepCollectionEquality().equals(other._visibleTypes, _visibleTypes)&&(identical(other.showLabels, showLabels) || other.showLabels == showLabels)&&(identical(other.showMagnitudes, showMagnitudes) || other.showMagnitudes == showMagnitudes)&&(identical(other.fadeWhenNotHovering, fadeWhenNotHovering) || other.fadeWhenNotHovering == fadeWhenNotHovering)&&(identical(other.hoverOpacity, hoverOpacity) || other.hoverOpacity == hoverOpacity)&&(identical(other.idleOpacity, idleOpacity) || other.idleOpacity == idleOpacity)&&(identical(other.fadeAnimationMs, fadeAnimationMs) || other.fadeAnimationMs == fadeAnimationMs)&&(identical(other.clickToIdentify, clickToIdentify) || other.clickToIdentify == clickToIdentify)&&(identical(other.clickSearchRadiusArcsec, clickSearchRadiusArcsec) || other.clickSearchRadiusArcsec == clickSearchRadiusArcsec)&&(identical(other.autoAnnotate, autoAnnotate) || other.autoAnnotate == autoAnnotate)&&(identical(other.maxObjectsToDisplay, maxObjectsToDisplay) || other.maxObjectsToDisplay == maxObjectsToDisplay)&&(identical(other.catalogBboxPaddingFraction, catalogBboxPaddingFraction) || other.catalogBboxPaddingFraction == catalogBboxPaddingFraction)&&(identical(other.compassEnabled, compassEnabled) || other.compassEnabled == compassEnabled)&&(identical(other.scaleBarEnabled, scaleBarEnabled) || other.scaleBarEnabled == scaleBarEnabled)&&(identical(other.gridType, gridType) || other.gridType == gridType)&&(identical(other.showSolveResiduals, showSolveResiduals) || other.showSolveResiduals == showSolveResiduals));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,enabled,magnitudeCutoff,minMagnitude,const DeepCollectionEquality().hash(_visibleTypes),showLabels,showMagnitudes,fadeWhenNotHovering,hoverOpacity,idleOpacity,fadeAnimationMs,clickToIdentify,clickSearchRadiusArcsec,autoAnnotate,maxObjectsToDisplay,catalogBboxPaddingFraction,compassEnabled,scaleBarEnabled,gridType,showSolveResiduals]);

@override
String toString() {
  return 'AnnotationSettings(enabled: $enabled, magnitudeCutoff: $magnitudeCutoff, minMagnitude: $minMagnitude, visibleTypes: $visibleTypes, showLabels: $showLabels, showMagnitudes: $showMagnitudes, fadeWhenNotHovering: $fadeWhenNotHovering, hoverOpacity: $hoverOpacity, idleOpacity: $idleOpacity, fadeAnimationMs: $fadeAnimationMs, clickToIdentify: $clickToIdentify, clickSearchRadiusArcsec: $clickSearchRadiusArcsec, autoAnnotate: $autoAnnotate, maxObjectsToDisplay: $maxObjectsToDisplay, catalogBboxPaddingFraction: $catalogBboxPaddingFraction, compassEnabled: $compassEnabled, scaleBarEnabled: $scaleBarEnabled, gridType: $gridType, showSolveResiduals: $showSolveResiduals)';
}


}

/// @nodoc
abstract mixin class _$AnnotationSettingsCopyWith<$Res> implements $AnnotationSettingsCopyWith<$Res> {
  factory _$AnnotationSettingsCopyWith(_AnnotationSettings value, $Res Function(_AnnotationSettings) _then) = __$AnnotationSettingsCopyWithImpl;
@override @useResult
$Res call({
 bool enabled, double magnitudeCutoff, double minMagnitude, Set<AnnotationObjectFilter> visibleTypes, bool showLabels, bool showMagnitudes, bool fadeWhenNotHovering, double hoverOpacity, double idleOpacity, int fadeAnimationMs, bool clickToIdentify, double clickSearchRadiusArcsec, bool autoAnnotate, int maxObjectsToDisplay, double catalogBboxPaddingFraction, bool compassEnabled, bool scaleBarEnabled, GridType gridType, bool showSolveResiduals
});




}
/// @nodoc
class __$AnnotationSettingsCopyWithImpl<$Res>
    implements _$AnnotationSettingsCopyWith<$Res> {
  __$AnnotationSettingsCopyWithImpl(this._self, this._then);

  final _AnnotationSettings _self;
  final $Res Function(_AnnotationSettings) _then;

/// Create a copy of AnnotationSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? enabled = null,Object? magnitudeCutoff = null,Object? minMagnitude = null,Object? visibleTypes = null,Object? showLabels = null,Object? showMagnitudes = null,Object? fadeWhenNotHovering = null,Object? hoverOpacity = null,Object? idleOpacity = null,Object? fadeAnimationMs = null,Object? clickToIdentify = null,Object? clickSearchRadiusArcsec = null,Object? autoAnnotate = null,Object? maxObjectsToDisplay = null,Object? catalogBboxPaddingFraction = null,Object? compassEnabled = null,Object? scaleBarEnabled = null,Object? gridType = null,Object? showSolveResiduals = null,}) {
  return _then(_AnnotationSettings(
enabled: null == enabled ? _self.enabled : enabled // ignore: cast_nullable_to_non_nullable
as bool,magnitudeCutoff: null == magnitudeCutoff ? _self.magnitudeCutoff : magnitudeCutoff // ignore: cast_nullable_to_non_nullable
as double,minMagnitude: null == minMagnitude ? _self.minMagnitude : minMagnitude // ignore: cast_nullable_to_non_nullable
as double,visibleTypes: null == visibleTypes ? _self._visibleTypes : visibleTypes // ignore: cast_nullable_to_non_nullable
as Set<AnnotationObjectFilter>,showLabels: null == showLabels ? _self.showLabels : showLabels // ignore: cast_nullable_to_non_nullable
as bool,showMagnitudes: null == showMagnitudes ? _self.showMagnitudes : showMagnitudes // ignore: cast_nullable_to_non_nullable
as bool,fadeWhenNotHovering: null == fadeWhenNotHovering ? _self.fadeWhenNotHovering : fadeWhenNotHovering // ignore: cast_nullable_to_non_nullable
as bool,hoverOpacity: null == hoverOpacity ? _self.hoverOpacity : hoverOpacity // ignore: cast_nullable_to_non_nullable
as double,idleOpacity: null == idleOpacity ? _self.idleOpacity : idleOpacity // ignore: cast_nullable_to_non_nullable
as double,fadeAnimationMs: null == fadeAnimationMs ? _self.fadeAnimationMs : fadeAnimationMs // ignore: cast_nullable_to_non_nullable
as int,clickToIdentify: null == clickToIdentify ? _self.clickToIdentify : clickToIdentify // ignore: cast_nullable_to_non_nullable
as bool,clickSearchRadiusArcsec: null == clickSearchRadiusArcsec ? _self.clickSearchRadiusArcsec : clickSearchRadiusArcsec // ignore: cast_nullable_to_non_nullable
as double,autoAnnotate: null == autoAnnotate ? _self.autoAnnotate : autoAnnotate // ignore: cast_nullable_to_non_nullable
as bool,maxObjectsToDisplay: null == maxObjectsToDisplay ? _self.maxObjectsToDisplay : maxObjectsToDisplay // ignore: cast_nullable_to_non_nullable
as int,catalogBboxPaddingFraction: null == catalogBboxPaddingFraction ? _self.catalogBboxPaddingFraction : catalogBboxPaddingFraction // ignore: cast_nullable_to_non_nullable
as double,compassEnabled: null == compassEnabled ? _self.compassEnabled : compassEnabled // ignore: cast_nullable_to_non_nullable
as bool,scaleBarEnabled: null == scaleBarEnabled ? _self.scaleBarEnabled : scaleBarEnabled // ignore: cast_nullable_to_non_nullable
as bool,gridType: null == gridType ? _self.gridType : gridType // ignore: cast_nullable_to_non_nullable
as GridType,showSolveResiduals: null == showSolveResiduals ? _self.showSolveResiduals : showSolveResiduals // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}


/// @nodoc
mixin _$AnnotationMarkerStyle {

/// Color for galaxy markers (gold)
 int get galaxyColor;/// Color for nebula markers (magenta)
 int get nebulaColor;/// Color for star cluster markers (cyan)
 int get clusterColor;/// Color for planetary nebula markers (violet)
 int get planetaryNebulaColor;/// Color for star markers (white)
 int get starColor;/// Color for unknown/other markers (green)
 int get otherColor;/// Stroke width for marker outlines
 double get strokeWidth;/// Font size for labels
 double get labelFontSize;/// Whether to scale markers based on object size
 bool get scaleBySize;/// Minimum marker size in pixels
 double get minMarkerSize;/// Maximum marker size in pixels
 double get maxMarkerSize;
/// Create a copy of AnnotationMarkerStyle
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AnnotationMarkerStyleCopyWith<AnnotationMarkerStyle> get copyWith => _$AnnotationMarkerStyleCopyWithImpl<AnnotationMarkerStyle>(this as AnnotationMarkerStyle, _$identity);

  /// Serializes this AnnotationMarkerStyle to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AnnotationMarkerStyle&&(identical(other.galaxyColor, galaxyColor) || other.galaxyColor == galaxyColor)&&(identical(other.nebulaColor, nebulaColor) || other.nebulaColor == nebulaColor)&&(identical(other.clusterColor, clusterColor) || other.clusterColor == clusterColor)&&(identical(other.planetaryNebulaColor, planetaryNebulaColor) || other.planetaryNebulaColor == planetaryNebulaColor)&&(identical(other.starColor, starColor) || other.starColor == starColor)&&(identical(other.otherColor, otherColor) || other.otherColor == otherColor)&&(identical(other.strokeWidth, strokeWidth) || other.strokeWidth == strokeWidth)&&(identical(other.labelFontSize, labelFontSize) || other.labelFontSize == labelFontSize)&&(identical(other.scaleBySize, scaleBySize) || other.scaleBySize == scaleBySize)&&(identical(other.minMarkerSize, minMarkerSize) || other.minMarkerSize == minMarkerSize)&&(identical(other.maxMarkerSize, maxMarkerSize) || other.maxMarkerSize == maxMarkerSize));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,galaxyColor,nebulaColor,clusterColor,planetaryNebulaColor,starColor,otherColor,strokeWidth,labelFontSize,scaleBySize,minMarkerSize,maxMarkerSize);

@override
String toString() {
  return 'AnnotationMarkerStyle(galaxyColor: $galaxyColor, nebulaColor: $nebulaColor, clusterColor: $clusterColor, planetaryNebulaColor: $planetaryNebulaColor, starColor: $starColor, otherColor: $otherColor, strokeWidth: $strokeWidth, labelFontSize: $labelFontSize, scaleBySize: $scaleBySize, minMarkerSize: $minMarkerSize, maxMarkerSize: $maxMarkerSize)';
}


}

/// @nodoc
abstract mixin class $AnnotationMarkerStyleCopyWith<$Res>  {
  factory $AnnotationMarkerStyleCopyWith(AnnotationMarkerStyle value, $Res Function(AnnotationMarkerStyle) _then) = _$AnnotationMarkerStyleCopyWithImpl;
@useResult
$Res call({
 int galaxyColor, int nebulaColor, int clusterColor, int planetaryNebulaColor, int starColor, int otherColor, double strokeWidth, double labelFontSize, bool scaleBySize, double minMarkerSize, double maxMarkerSize
});




}
/// @nodoc
class _$AnnotationMarkerStyleCopyWithImpl<$Res>
    implements $AnnotationMarkerStyleCopyWith<$Res> {
  _$AnnotationMarkerStyleCopyWithImpl(this._self, this._then);

  final AnnotationMarkerStyle _self;
  final $Res Function(AnnotationMarkerStyle) _then;

/// Create a copy of AnnotationMarkerStyle
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? galaxyColor = null,Object? nebulaColor = null,Object? clusterColor = null,Object? planetaryNebulaColor = null,Object? starColor = null,Object? otherColor = null,Object? strokeWidth = null,Object? labelFontSize = null,Object? scaleBySize = null,Object? minMarkerSize = null,Object? maxMarkerSize = null,}) {
  return _then(_self.copyWith(
galaxyColor: null == galaxyColor ? _self.galaxyColor : galaxyColor // ignore: cast_nullable_to_non_nullable
as int,nebulaColor: null == nebulaColor ? _self.nebulaColor : nebulaColor // ignore: cast_nullable_to_non_nullable
as int,clusterColor: null == clusterColor ? _self.clusterColor : clusterColor // ignore: cast_nullable_to_non_nullable
as int,planetaryNebulaColor: null == planetaryNebulaColor ? _self.planetaryNebulaColor : planetaryNebulaColor // ignore: cast_nullable_to_non_nullable
as int,starColor: null == starColor ? _self.starColor : starColor // ignore: cast_nullable_to_non_nullable
as int,otherColor: null == otherColor ? _self.otherColor : otherColor // ignore: cast_nullable_to_non_nullable
as int,strokeWidth: null == strokeWidth ? _self.strokeWidth : strokeWidth // ignore: cast_nullable_to_non_nullable
as double,labelFontSize: null == labelFontSize ? _self.labelFontSize : labelFontSize // ignore: cast_nullable_to_non_nullable
as double,scaleBySize: null == scaleBySize ? _self.scaleBySize : scaleBySize // ignore: cast_nullable_to_non_nullable
as bool,minMarkerSize: null == minMarkerSize ? _self.minMarkerSize : minMarkerSize // ignore: cast_nullable_to_non_nullable
as double,maxMarkerSize: null == maxMarkerSize ? _self.maxMarkerSize : maxMarkerSize // ignore: cast_nullable_to_non_nullable
as double,
  ));
}

}


/// Adds pattern-matching-related methods to [AnnotationMarkerStyle].
extension AnnotationMarkerStylePatterns on AnnotationMarkerStyle {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AnnotationMarkerStyle value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AnnotationMarkerStyle() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AnnotationMarkerStyle value)  $default,){
final _that = this;
switch (_that) {
case _AnnotationMarkerStyle():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AnnotationMarkerStyle value)?  $default,){
final _that = this;
switch (_that) {
case _AnnotationMarkerStyle() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int galaxyColor,  int nebulaColor,  int clusterColor,  int planetaryNebulaColor,  int starColor,  int otherColor,  double strokeWidth,  double labelFontSize,  bool scaleBySize,  double minMarkerSize,  double maxMarkerSize)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AnnotationMarkerStyle() when $default != null:
return $default(_that.galaxyColor,_that.nebulaColor,_that.clusterColor,_that.planetaryNebulaColor,_that.starColor,_that.otherColor,_that.strokeWidth,_that.labelFontSize,_that.scaleBySize,_that.minMarkerSize,_that.maxMarkerSize);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int galaxyColor,  int nebulaColor,  int clusterColor,  int planetaryNebulaColor,  int starColor,  int otherColor,  double strokeWidth,  double labelFontSize,  bool scaleBySize,  double minMarkerSize,  double maxMarkerSize)  $default,) {final _that = this;
switch (_that) {
case _AnnotationMarkerStyle():
return $default(_that.galaxyColor,_that.nebulaColor,_that.clusterColor,_that.planetaryNebulaColor,_that.starColor,_that.otherColor,_that.strokeWidth,_that.labelFontSize,_that.scaleBySize,_that.minMarkerSize,_that.maxMarkerSize);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int galaxyColor,  int nebulaColor,  int clusterColor,  int planetaryNebulaColor,  int starColor,  int otherColor,  double strokeWidth,  double labelFontSize,  bool scaleBySize,  double minMarkerSize,  double maxMarkerSize)?  $default,) {final _that = this;
switch (_that) {
case _AnnotationMarkerStyle() when $default != null:
return $default(_that.galaxyColor,_that.nebulaColor,_that.clusterColor,_that.planetaryNebulaColor,_that.starColor,_that.otherColor,_that.strokeWidth,_that.labelFontSize,_that.scaleBySize,_that.minMarkerSize,_that.maxMarkerSize);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AnnotationMarkerStyle implements AnnotationMarkerStyle {
  const _AnnotationMarkerStyle({this.galaxyColor = 0xFFFFD700, this.nebulaColor = 0xFFFF00FF, this.clusterColor = 0xFF00FFFF, this.planetaryNebulaColor = 0xFF9400D3, this.starColor = 0xFFFFFFFF, this.otherColor = 0xFF00FF00, this.strokeWidth = 1.5, this.labelFontSize = 12.0, this.scaleBySize = true, this.minMarkerSize = 10.0, this.maxMarkerSize = 100.0});
  factory _AnnotationMarkerStyle.fromJson(Map<String, dynamic> json) => _$AnnotationMarkerStyleFromJson(json);

/// Color for galaxy markers (gold)
@override@JsonKey() final  int galaxyColor;
/// Color for nebula markers (magenta)
@override@JsonKey() final  int nebulaColor;
/// Color for star cluster markers (cyan)
@override@JsonKey() final  int clusterColor;
/// Color for planetary nebula markers (violet)
@override@JsonKey() final  int planetaryNebulaColor;
/// Color for star markers (white)
@override@JsonKey() final  int starColor;
/// Color for unknown/other markers (green)
@override@JsonKey() final  int otherColor;
/// Stroke width for marker outlines
@override@JsonKey() final  double strokeWidth;
/// Font size for labels
@override@JsonKey() final  double labelFontSize;
/// Whether to scale markers based on object size
@override@JsonKey() final  bool scaleBySize;
/// Minimum marker size in pixels
@override@JsonKey() final  double minMarkerSize;
/// Maximum marker size in pixels
@override@JsonKey() final  double maxMarkerSize;

/// Create a copy of AnnotationMarkerStyle
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AnnotationMarkerStyleCopyWith<_AnnotationMarkerStyle> get copyWith => __$AnnotationMarkerStyleCopyWithImpl<_AnnotationMarkerStyle>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AnnotationMarkerStyleToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AnnotationMarkerStyle&&(identical(other.galaxyColor, galaxyColor) || other.galaxyColor == galaxyColor)&&(identical(other.nebulaColor, nebulaColor) || other.nebulaColor == nebulaColor)&&(identical(other.clusterColor, clusterColor) || other.clusterColor == clusterColor)&&(identical(other.planetaryNebulaColor, planetaryNebulaColor) || other.planetaryNebulaColor == planetaryNebulaColor)&&(identical(other.starColor, starColor) || other.starColor == starColor)&&(identical(other.otherColor, otherColor) || other.otherColor == otherColor)&&(identical(other.strokeWidth, strokeWidth) || other.strokeWidth == strokeWidth)&&(identical(other.labelFontSize, labelFontSize) || other.labelFontSize == labelFontSize)&&(identical(other.scaleBySize, scaleBySize) || other.scaleBySize == scaleBySize)&&(identical(other.minMarkerSize, minMarkerSize) || other.minMarkerSize == minMarkerSize)&&(identical(other.maxMarkerSize, maxMarkerSize) || other.maxMarkerSize == maxMarkerSize));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,galaxyColor,nebulaColor,clusterColor,planetaryNebulaColor,starColor,otherColor,strokeWidth,labelFontSize,scaleBySize,minMarkerSize,maxMarkerSize);

@override
String toString() {
  return 'AnnotationMarkerStyle(galaxyColor: $galaxyColor, nebulaColor: $nebulaColor, clusterColor: $clusterColor, planetaryNebulaColor: $planetaryNebulaColor, starColor: $starColor, otherColor: $otherColor, strokeWidth: $strokeWidth, labelFontSize: $labelFontSize, scaleBySize: $scaleBySize, minMarkerSize: $minMarkerSize, maxMarkerSize: $maxMarkerSize)';
}


}

/// @nodoc
abstract mixin class _$AnnotationMarkerStyleCopyWith<$Res> implements $AnnotationMarkerStyleCopyWith<$Res> {
  factory _$AnnotationMarkerStyleCopyWith(_AnnotationMarkerStyle value, $Res Function(_AnnotationMarkerStyle) _then) = __$AnnotationMarkerStyleCopyWithImpl;
@override @useResult
$Res call({
 int galaxyColor, int nebulaColor, int clusterColor, int planetaryNebulaColor, int starColor, int otherColor, double strokeWidth, double labelFontSize, bool scaleBySize, double minMarkerSize, double maxMarkerSize
});




}
/// @nodoc
class __$AnnotationMarkerStyleCopyWithImpl<$Res>
    implements _$AnnotationMarkerStyleCopyWith<$Res> {
  __$AnnotationMarkerStyleCopyWithImpl(this._self, this._then);

  final _AnnotationMarkerStyle _self;
  final $Res Function(_AnnotationMarkerStyle) _then;

/// Create a copy of AnnotationMarkerStyle
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? galaxyColor = null,Object? nebulaColor = null,Object? clusterColor = null,Object? planetaryNebulaColor = null,Object? starColor = null,Object? otherColor = null,Object? strokeWidth = null,Object? labelFontSize = null,Object? scaleBySize = null,Object? minMarkerSize = null,Object? maxMarkerSize = null,}) {
  return _then(_AnnotationMarkerStyle(
galaxyColor: null == galaxyColor ? _self.galaxyColor : galaxyColor // ignore: cast_nullable_to_non_nullable
as int,nebulaColor: null == nebulaColor ? _self.nebulaColor : nebulaColor // ignore: cast_nullable_to_non_nullable
as int,clusterColor: null == clusterColor ? _self.clusterColor : clusterColor // ignore: cast_nullable_to_non_nullable
as int,planetaryNebulaColor: null == planetaryNebulaColor ? _self.planetaryNebulaColor : planetaryNebulaColor // ignore: cast_nullable_to_non_nullable
as int,starColor: null == starColor ? _self.starColor : starColor // ignore: cast_nullable_to_non_nullable
as int,otherColor: null == otherColor ? _self.otherColor : otherColor // ignore: cast_nullable_to_non_nullable
as int,strokeWidth: null == strokeWidth ? _self.strokeWidth : strokeWidth // ignore: cast_nullable_to_non_nullable
as double,labelFontSize: null == labelFontSize ? _self.labelFontSize : labelFontSize // ignore: cast_nullable_to_non_nullable
as double,scaleBySize: null == scaleBySize ? _self.scaleBySize : scaleBySize // ignore: cast_nullable_to_non_nullable
as bool,minMarkerSize: null == minMarkerSize ? _self.minMarkerSize : minMarkerSize // ignore: cast_nullable_to_non_nullable
as double,maxMarkerSize: null == maxMarkerSize ? _self.maxMarkerSize : maxMarkerSize // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}


/// @nodoc
mixin _$AnnotationPreset {

 String get name; Set<AnnotationObjectFilter> get visibleTypes; double get minMagnitude; double get magnitudeCutoff; bool get showLabels; bool get showMagnitudes; bool get isBuiltIn;
/// Create a copy of AnnotationPreset
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AnnotationPresetCopyWith<AnnotationPreset> get copyWith => _$AnnotationPresetCopyWithImpl<AnnotationPreset>(this as AnnotationPreset, _$identity);

  /// Serializes this AnnotationPreset to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AnnotationPreset&&(identical(other.name, name) || other.name == name)&&const DeepCollectionEquality().equals(other.visibleTypes, visibleTypes)&&(identical(other.minMagnitude, minMagnitude) || other.minMagnitude == minMagnitude)&&(identical(other.magnitudeCutoff, magnitudeCutoff) || other.magnitudeCutoff == magnitudeCutoff)&&(identical(other.showLabels, showLabels) || other.showLabels == showLabels)&&(identical(other.showMagnitudes, showMagnitudes) || other.showMagnitudes == showMagnitudes)&&(identical(other.isBuiltIn, isBuiltIn) || other.isBuiltIn == isBuiltIn));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,name,const DeepCollectionEquality().hash(visibleTypes),minMagnitude,magnitudeCutoff,showLabels,showMagnitudes,isBuiltIn);

@override
String toString() {
  return 'AnnotationPreset(name: $name, visibleTypes: $visibleTypes, minMagnitude: $minMagnitude, magnitudeCutoff: $magnitudeCutoff, showLabels: $showLabels, showMagnitudes: $showMagnitudes, isBuiltIn: $isBuiltIn)';
}


}

/// @nodoc
abstract mixin class $AnnotationPresetCopyWith<$Res>  {
  factory $AnnotationPresetCopyWith(AnnotationPreset value, $Res Function(AnnotationPreset) _then) = _$AnnotationPresetCopyWithImpl;
@useResult
$Res call({
 String name, Set<AnnotationObjectFilter> visibleTypes, double minMagnitude, double magnitudeCutoff, bool showLabels, bool showMagnitudes, bool isBuiltIn
});




}
/// @nodoc
class _$AnnotationPresetCopyWithImpl<$Res>
    implements $AnnotationPresetCopyWith<$Res> {
  _$AnnotationPresetCopyWithImpl(this._self, this._then);

  final AnnotationPreset _self;
  final $Res Function(AnnotationPreset) _then;

/// Create a copy of AnnotationPreset
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? name = null,Object? visibleTypes = null,Object? minMagnitude = null,Object? magnitudeCutoff = null,Object? showLabels = null,Object? showMagnitudes = null,Object? isBuiltIn = null,}) {
  return _then(_self.copyWith(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,visibleTypes: null == visibleTypes ? _self.visibleTypes : visibleTypes // ignore: cast_nullable_to_non_nullable
as Set<AnnotationObjectFilter>,minMagnitude: null == minMagnitude ? _self.minMagnitude : minMagnitude // ignore: cast_nullable_to_non_nullable
as double,magnitudeCutoff: null == magnitudeCutoff ? _self.magnitudeCutoff : magnitudeCutoff // ignore: cast_nullable_to_non_nullable
as double,showLabels: null == showLabels ? _self.showLabels : showLabels // ignore: cast_nullable_to_non_nullable
as bool,showMagnitudes: null == showMagnitudes ? _self.showMagnitudes : showMagnitudes // ignore: cast_nullable_to_non_nullable
as bool,isBuiltIn: null == isBuiltIn ? _self.isBuiltIn : isBuiltIn // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [AnnotationPreset].
extension AnnotationPresetPatterns on AnnotationPreset {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AnnotationPreset value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AnnotationPreset() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AnnotationPreset value)  $default,){
final _that = this;
switch (_that) {
case _AnnotationPreset():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AnnotationPreset value)?  $default,){
final _that = this;
switch (_that) {
case _AnnotationPreset() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String name,  Set<AnnotationObjectFilter> visibleTypes,  double minMagnitude,  double magnitudeCutoff,  bool showLabels,  bool showMagnitudes,  bool isBuiltIn)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AnnotationPreset() when $default != null:
return $default(_that.name,_that.visibleTypes,_that.minMagnitude,_that.magnitudeCutoff,_that.showLabels,_that.showMagnitudes,_that.isBuiltIn);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String name,  Set<AnnotationObjectFilter> visibleTypes,  double minMagnitude,  double magnitudeCutoff,  bool showLabels,  bool showMagnitudes,  bool isBuiltIn)  $default,) {final _that = this;
switch (_that) {
case _AnnotationPreset():
return $default(_that.name,_that.visibleTypes,_that.minMagnitude,_that.magnitudeCutoff,_that.showLabels,_that.showMagnitudes,_that.isBuiltIn);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String name,  Set<AnnotationObjectFilter> visibleTypes,  double minMagnitude,  double magnitudeCutoff,  bool showLabels,  bool showMagnitudes,  bool isBuiltIn)?  $default,) {final _that = this;
switch (_that) {
case _AnnotationPreset() when $default != null:
return $default(_that.name,_that.visibleTypes,_that.minMagnitude,_that.magnitudeCutoff,_that.showLabels,_that.showMagnitudes,_that.isBuiltIn);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AnnotationPreset implements AnnotationPreset {
  const _AnnotationPreset({required this.name, required final  Set<AnnotationObjectFilter> visibleTypes, required this.minMagnitude, required this.magnitudeCutoff, required this.showLabels, required this.showMagnitudes, this.isBuiltIn = false}): _visibleTypes = visibleTypes;
  factory _AnnotationPreset.fromJson(Map<String, dynamic> json) => _$AnnotationPresetFromJson(json);

@override final  String name;
 final  Set<AnnotationObjectFilter> _visibleTypes;
@override Set<AnnotationObjectFilter> get visibleTypes {
  if (_visibleTypes is EqualUnmodifiableSetView) return _visibleTypes;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableSetView(_visibleTypes);
}

@override final  double minMagnitude;
@override final  double magnitudeCutoff;
@override final  bool showLabels;
@override final  bool showMagnitudes;
@override@JsonKey() final  bool isBuiltIn;

/// Create a copy of AnnotationPreset
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AnnotationPresetCopyWith<_AnnotationPreset> get copyWith => __$AnnotationPresetCopyWithImpl<_AnnotationPreset>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AnnotationPresetToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AnnotationPreset&&(identical(other.name, name) || other.name == name)&&const DeepCollectionEquality().equals(other._visibleTypes, _visibleTypes)&&(identical(other.minMagnitude, minMagnitude) || other.minMagnitude == minMagnitude)&&(identical(other.magnitudeCutoff, magnitudeCutoff) || other.magnitudeCutoff == magnitudeCutoff)&&(identical(other.showLabels, showLabels) || other.showLabels == showLabels)&&(identical(other.showMagnitudes, showMagnitudes) || other.showMagnitudes == showMagnitudes)&&(identical(other.isBuiltIn, isBuiltIn) || other.isBuiltIn == isBuiltIn));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,name,const DeepCollectionEquality().hash(_visibleTypes),minMagnitude,magnitudeCutoff,showLabels,showMagnitudes,isBuiltIn);

@override
String toString() {
  return 'AnnotationPreset(name: $name, visibleTypes: $visibleTypes, minMagnitude: $minMagnitude, magnitudeCutoff: $magnitudeCutoff, showLabels: $showLabels, showMagnitudes: $showMagnitudes, isBuiltIn: $isBuiltIn)';
}


}

/// @nodoc
abstract mixin class _$AnnotationPresetCopyWith<$Res> implements $AnnotationPresetCopyWith<$Res> {
  factory _$AnnotationPresetCopyWith(_AnnotationPreset value, $Res Function(_AnnotationPreset) _then) = __$AnnotationPresetCopyWithImpl;
@override @useResult
$Res call({
 String name, Set<AnnotationObjectFilter> visibleTypes, double minMagnitude, double magnitudeCutoff, bool showLabels, bool showMagnitudes, bool isBuiltIn
});




}
/// @nodoc
class __$AnnotationPresetCopyWithImpl<$Res>
    implements _$AnnotationPresetCopyWith<$Res> {
  __$AnnotationPresetCopyWithImpl(this._self, this._then);

  final _AnnotationPreset _self;
  final $Res Function(_AnnotationPreset) _then;

/// Create a copy of AnnotationPreset
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? visibleTypes = null,Object? minMagnitude = null,Object? magnitudeCutoff = null,Object? showLabels = null,Object? showMagnitudes = null,Object? isBuiltIn = null,}) {
  return _then(_AnnotationPreset(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,visibleTypes: null == visibleTypes ? _self._visibleTypes : visibleTypes // ignore: cast_nullable_to_non_nullable
as Set<AnnotationObjectFilter>,minMagnitude: null == minMagnitude ? _self.minMagnitude : minMagnitude // ignore: cast_nullable_to_non_nullable
as double,magnitudeCutoff: null == magnitudeCutoff ? _self.magnitudeCutoff : magnitudeCutoff // ignore: cast_nullable_to_non_nullable
as double,showLabels: null == showLabels ? _self.showLabels : showLabels // ignore: cast_nullable_to_non_nullable
as bool,showMagnitudes: null == showMagnitudes ? _self.showMagnitudes : showMagnitudes // ignore: cast_nullable_to_non_nullable
as bool,isBuiltIn: null == isBuiltIn ? _self.isBuiltIn : isBuiltIn // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}


/// @nodoc
mixin _$CustomAnnotation {

 String get id; CustomAnnotationType get type;/// Image pixel X of the anchor point (center for circles, start for arrows, position for text)
 double get x; double get y;/// For circles: radius in pixels. For arrows: end X.
 double? get x2;/// For arrows: end Y.
 double? get y2;/// For circles: radius in pixels.
 double? get radius;/// Label text
 String get label;/// Color as ARGB int
 int get color;
/// Create a copy of CustomAnnotation
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CustomAnnotationCopyWith<CustomAnnotation> get copyWith => _$CustomAnnotationCopyWithImpl<CustomAnnotation>(this as CustomAnnotation, _$identity);

  /// Serializes this CustomAnnotation to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CustomAnnotation&&(identical(other.id, id) || other.id == id)&&(identical(other.type, type) || other.type == type)&&(identical(other.x, x) || other.x == x)&&(identical(other.y, y) || other.y == y)&&(identical(other.x2, x2) || other.x2 == x2)&&(identical(other.y2, y2) || other.y2 == y2)&&(identical(other.radius, radius) || other.radius == radius)&&(identical(other.label, label) || other.label == label)&&(identical(other.color, color) || other.color == color));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,type,x,y,x2,y2,radius,label,color);

@override
String toString() {
  return 'CustomAnnotation(id: $id, type: $type, x: $x, y: $y, x2: $x2, y2: $y2, radius: $radius, label: $label, color: $color)';
}


}

/// @nodoc
abstract mixin class $CustomAnnotationCopyWith<$Res>  {
  factory $CustomAnnotationCopyWith(CustomAnnotation value, $Res Function(CustomAnnotation) _then) = _$CustomAnnotationCopyWithImpl;
@useResult
$Res call({
 String id, CustomAnnotationType type, double x, double y, double? x2, double? y2, double? radius, String label, int color
});




}
/// @nodoc
class _$CustomAnnotationCopyWithImpl<$Res>
    implements $CustomAnnotationCopyWith<$Res> {
  _$CustomAnnotationCopyWithImpl(this._self, this._then);

  final CustomAnnotation _self;
  final $Res Function(CustomAnnotation) _then;

/// Create a copy of CustomAnnotation
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? type = null,Object? x = null,Object? y = null,Object? x2 = freezed,Object? y2 = freezed,Object? radius = freezed,Object? label = null,Object? color = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as CustomAnnotationType,x: null == x ? _self.x : x // ignore: cast_nullable_to_non_nullable
as double,y: null == y ? _self.y : y // ignore: cast_nullable_to_non_nullable
as double,x2: freezed == x2 ? _self.x2 : x2 // ignore: cast_nullable_to_non_nullable
as double?,y2: freezed == y2 ? _self.y2 : y2 // ignore: cast_nullable_to_non_nullable
as double?,radius: freezed == radius ? _self.radius : radius // ignore: cast_nullable_to_non_nullable
as double?,label: null == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String,color: null == color ? _self.color : color // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [CustomAnnotation].
extension CustomAnnotationPatterns on CustomAnnotation {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _CustomAnnotation value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _CustomAnnotation() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _CustomAnnotation value)  $default,){
final _that = this;
switch (_that) {
case _CustomAnnotation():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _CustomAnnotation value)?  $default,){
final _that = this;
switch (_that) {
case _CustomAnnotation() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  CustomAnnotationType type,  double x,  double y,  double? x2,  double? y2,  double? radius,  String label,  int color)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _CustomAnnotation() when $default != null:
return $default(_that.id,_that.type,_that.x,_that.y,_that.x2,_that.y2,_that.radius,_that.label,_that.color);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  CustomAnnotationType type,  double x,  double y,  double? x2,  double? y2,  double? radius,  String label,  int color)  $default,) {final _that = this;
switch (_that) {
case _CustomAnnotation():
return $default(_that.id,_that.type,_that.x,_that.y,_that.x2,_that.y2,_that.radius,_that.label,_that.color);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  CustomAnnotationType type,  double x,  double y,  double? x2,  double? y2,  double? radius,  String label,  int color)?  $default,) {final _that = this;
switch (_that) {
case _CustomAnnotation() when $default != null:
return $default(_that.id,_that.type,_that.x,_that.y,_that.x2,_that.y2,_that.radius,_that.label,_that.color);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _CustomAnnotation implements CustomAnnotation {
  const _CustomAnnotation({required this.id, required this.type, required this.x, required this.y, this.x2, this.y2, this.radius, this.label = '', this.color = 0xFFFF6B6B});
  factory _CustomAnnotation.fromJson(Map<String, dynamic> json) => _$CustomAnnotationFromJson(json);

@override final  String id;
@override final  CustomAnnotationType type;
/// Image pixel X of the anchor point (center for circles, start for arrows, position for text)
@override final  double x;
@override final  double y;
/// For circles: radius in pixels. For arrows: end X.
@override final  double? x2;
/// For arrows: end Y.
@override final  double? y2;
/// For circles: radius in pixels.
@override final  double? radius;
/// Label text
@override@JsonKey() final  String label;
/// Color as ARGB int
@override@JsonKey() final  int color;

/// Create a copy of CustomAnnotation
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$CustomAnnotationCopyWith<_CustomAnnotation> get copyWith => __$CustomAnnotationCopyWithImpl<_CustomAnnotation>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$CustomAnnotationToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _CustomAnnotation&&(identical(other.id, id) || other.id == id)&&(identical(other.type, type) || other.type == type)&&(identical(other.x, x) || other.x == x)&&(identical(other.y, y) || other.y == y)&&(identical(other.x2, x2) || other.x2 == x2)&&(identical(other.y2, y2) || other.y2 == y2)&&(identical(other.radius, radius) || other.radius == radius)&&(identical(other.label, label) || other.label == label)&&(identical(other.color, color) || other.color == color));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,type,x,y,x2,y2,radius,label,color);

@override
String toString() {
  return 'CustomAnnotation(id: $id, type: $type, x: $x, y: $y, x2: $x2, y2: $y2, radius: $radius, label: $label, color: $color)';
}


}

/// @nodoc
abstract mixin class _$CustomAnnotationCopyWith<$Res> implements $CustomAnnotationCopyWith<$Res> {
  factory _$CustomAnnotationCopyWith(_CustomAnnotation value, $Res Function(_CustomAnnotation) _then) = __$CustomAnnotationCopyWithImpl;
@override @useResult
$Res call({
 String id, CustomAnnotationType type, double x, double y, double? x2, double? y2, double? radius, String label, int color
});




}
/// @nodoc
class __$CustomAnnotationCopyWithImpl<$Res>
    implements _$CustomAnnotationCopyWith<$Res> {
  __$CustomAnnotationCopyWithImpl(this._self, this._then);

  final _CustomAnnotation _self;
  final $Res Function(_CustomAnnotation) _then;

/// Create a copy of CustomAnnotation
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? type = null,Object? x = null,Object? y = null,Object? x2 = freezed,Object? y2 = freezed,Object? radius = freezed,Object? label = null,Object? color = null,}) {
  return _then(_CustomAnnotation(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as CustomAnnotationType,x: null == x ? _self.x : x // ignore: cast_nullable_to_non_nullable
as double,y: null == y ? _self.y : y // ignore: cast_nullable_to_non_nullable
as double,x2: freezed == x2 ? _self.x2 : x2 // ignore: cast_nullable_to_non_nullable
as double?,y2: freezed == y2 ? _self.y2 : y2 // ignore: cast_nullable_to_non_nullable
as double?,radius: freezed == radius ? _self.radius : radius // ignore: cast_nullable_to_non_nullable
as double?,label: null == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String,color: null == color ? _self.color : color // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
