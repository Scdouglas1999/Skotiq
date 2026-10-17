// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'weather_settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$WeatherSettings {

/// Distance threshold for alerts in kilometers
 double get triggerDistanceKm;/// Cloud density threshold for warnings (0-100 percent)
 double get cloudDensityThreshold;/// Lead time for alerts in minutes
 int get leadTimeMinutes;/// Enable weather safety monitoring.
///
/// Defaults OFF: with no weather source or hardware safety monitor
/// configured (the out-of-box state), an enabled monitor fails closed and
/// aborts every automated sequence within seconds — the flagship use case
/// broken on night one for the majority of rigs. Weather gating is now
/// opt-in; a user connects a weather source / safety monitor and turns
/// this on. Existing installs keep their persisted value.
 bool get weatherSafetyEnabled;/// Maximum safe humidity before weather safety pauses imaging
 double get maxHumidityPercent;/// Maximum safe wind speed before weather safety pauses imaging
 double get maxWindSpeedKph;/// Maximum safe cloud cover before weather safety pauses imaging
 double get maxCloudCoverPercent;/// Automatically park mount when weather threatens
 bool get autoParkEnabled;/// Automatically resume imaging when weather clears
 bool get autoResumeEnabled;/// Preferred radar data provider
 RadarProviderType get preferredProvider;/// How often to refresh radar data in seconds
 int get refreshIntervalSeconds;
/// Create a copy of WeatherSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$WeatherSettingsCopyWith<WeatherSettings> get copyWith => _$WeatherSettingsCopyWithImpl<WeatherSettings>(this as WeatherSettings, _$identity);

  /// Serializes this WeatherSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is WeatherSettings&&(identical(other.triggerDistanceKm, triggerDistanceKm) || other.triggerDistanceKm == triggerDistanceKm)&&(identical(other.cloudDensityThreshold, cloudDensityThreshold) || other.cloudDensityThreshold == cloudDensityThreshold)&&(identical(other.leadTimeMinutes, leadTimeMinutes) || other.leadTimeMinutes == leadTimeMinutes)&&(identical(other.weatherSafetyEnabled, weatherSafetyEnabled) || other.weatherSafetyEnabled == weatherSafetyEnabled)&&(identical(other.maxHumidityPercent, maxHumidityPercent) || other.maxHumidityPercent == maxHumidityPercent)&&(identical(other.maxWindSpeedKph, maxWindSpeedKph) || other.maxWindSpeedKph == maxWindSpeedKph)&&(identical(other.maxCloudCoverPercent, maxCloudCoverPercent) || other.maxCloudCoverPercent == maxCloudCoverPercent)&&(identical(other.autoParkEnabled, autoParkEnabled) || other.autoParkEnabled == autoParkEnabled)&&(identical(other.autoResumeEnabled, autoResumeEnabled) || other.autoResumeEnabled == autoResumeEnabled)&&(identical(other.preferredProvider, preferredProvider) || other.preferredProvider == preferredProvider)&&(identical(other.refreshIntervalSeconds, refreshIntervalSeconds) || other.refreshIntervalSeconds == refreshIntervalSeconds));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,triggerDistanceKm,cloudDensityThreshold,leadTimeMinutes,weatherSafetyEnabled,maxHumidityPercent,maxWindSpeedKph,maxCloudCoverPercent,autoParkEnabled,autoResumeEnabled,preferredProvider,refreshIntervalSeconds);

@override
String toString() {
  return 'WeatherSettings(triggerDistanceKm: $triggerDistanceKm, cloudDensityThreshold: $cloudDensityThreshold, leadTimeMinutes: $leadTimeMinutes, weatherSafetyEnabled: $weatherSafetyEnabled, maxHumidityPercent: $maxHumidityPercent, maxWindSpeedKph: $maxWindSpeedKph, maxCloudCoverPercent: $maxCloudCoverPercent, autoParkEnabled: $autoParkEnabled, autoResumeEnabled: $autoResumeEnabled, preferredProvider: $preferredProvider, refreshIntervalSeconds: $refreshIntervalSeconds)';
}


}

/// @nodoc
abstract mixin class $WeatherSettingsCopyWith<$Res>  {
  factory $WeatherSettingsCopyWith(WeatherSettings value, $Res Function(WeatherSettings) _then) = _$WeatherSettingsCopyWithImpl;
@useResult
$Res call({
 double triggerDistanceKm, double cloudDensityThreshold, int leadTimeMinutes, bool weatherSafetyEnabled, double maxHumidityPercent, double maxWindSpeedKph, double maxCloudCoverPercent, bool autoParkEnabled, bool autoResumeEnabled, RadarProviderType preferredProvider, int refreshIntervalSeconds
});




}
/// @nodoc
class _$WeatherSettingsCopyWithImpl<$Res>
    implements $WeatherSettingsCopyWith<$Res> {
  _$WeatherSettingsCopyWithImpl(this._self, this._then);

  final WeatherSettings _self;
  final $Res Function(WeatherSettings) _then;

/// Create a copy of WeatherSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? triggerDistanceKm = null,Object? cloudDensityThreshold = null,Object? leadTimeMinutes = null,Object? weatherSafetyEnabled = null,Object? maxHumidityPercent = null,Object? maxWindSpeedKph = null,Object? maxCloudCoverPercent = null,Object? autoParkEnabled = null,Object? autoResumeEnabled = null,Object? preferredProvider = null,Object? refreshIntervalSeconds = null,}) {
  return _then(_self.copyWith(
triggerDistanceKm: null == triggerDistanceKm ? _self.triggerDistanceKm : triggerDistanceKm // ignore: cast_nullable_to_non_nullable
as double,cloudDensityThreshold: null == cloudDensityThreshold ? _self.cloudDensityThreshold : cloudDensityThreshold // ignore: cast_nullable_to_non_nullable
as double,leadTimeMinutes: null == leadTimeMinutes ? _self.leadTimeMinutes : leadTimeMinutes // ignore: cast_nullable_to_non_nullable
as int,weatherSafetyEnabled: null == weatherSafetyEnabled ? _self.weatherSafetyEnabled : weatherSafetyEnabled // ignore: cast_nullable_to_non_nullable
as bool,maxHumidityPercent: null == maxHumidityPercent ? _self.maxHumidityPercent : maxHumidityPercent // ignore: cast_nullable_to_non_nullable
as double,maxWindSpeedKph: null == maxWindSpeedKph ? _self.maxWindSpeedKph : maxWindSpeedKph // ignore: cast_nullable_to_non_nullable
as double,maxCloudCoverPercent: null == maxCloudCoverPercent ? _self.maxCloudCoverPercent : maxCloudCoverPercent // ignore: cast_nullable_to_non_nullable
as double,autoParkEnabled: null == autoParkEnabled ? _self.autoParkEnabled : autoParkEnabled // ignore: cast_nullable_to_non_nullable
as bool,autoResumeEnabled: null == autoResumeEnabled ? _self.autoResumeEnabled : autoResumeEnabled // ignore: cast_nullable_to_non_nullable
as bool,preferredProvider: null == preferredProvider ? _self.preferredProvider : preferredProvider // ignore: cast_nullable_to_non_nullable
as RadarProviderType,refreshIntervalSeconds: null == refreshIntervalSeconds ? _self.refreshIntervalSeconds : refreshIntervalSeconds // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [WeatherSettings].
extension WeatherSettingsPatterns on WeatherSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _WeatherSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _WeatherSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _WeatherSettings value)  $default,){
final _that = this;
switch (_that) {
case _WeatherSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _WeatherSettings value)?  $default,){
final _that = this;
switch (_that) {
case _WeatherSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double triggerDistanceKm,  double cloudDensityThreshold,  int leadTimeMinutes,  bool weatherSafetyEnabled,  double maxHumidityPercent,  double maxWindSpeedKph,  double maxCloudCoverPercent,  bool autoParkEnabled,  bool autoResumeEnabled,  RadarProviderType preferredProvider,  int refreshIntervalSeconds)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _WeatherSettings() when $default != null:
return $default(_that.triggerDistanceKm,_that.cloudDensityThreshold,_that.leadTimeMinutes,_that.weatherSafetyEnabled,_that.maxHumidityPercent,_that.maxWindSpeedKph,_that.maxCloudCoverPercent,_that.autoParkEnabled,_that.autoResumeEnabled,_that.preferredProvider,_that.refreshIntervalSeconds);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double triggerDistanceKm,  double cloudDensityThreshold,  int leadTimeMinutes,  bool weatherSafetyEnabled,  double maxHumidityPercent,  double maxWindSpeedKph,  double maxCloudCoverPercent,  bool autoParkEnabled,  bool autoResumeEnabled,  RadarProviderType preferredProvider,  int refreshIntervalSeconds)  $default,) {final _that = this;
switch (_that) {
case _WeatherSettings():
return $default(_that.triggerDistanceKm,_that.cloudDensityThreshold,_that.leadTimeMinutes,_that.weatherSafetyEnabled,_that.maxHumidityPercent,_that.maxWindSpeedKph,_that.maxCloudCoverPercent,_that.autoParkEnabled,_that.autoResumeEnabled,_that.preferredProvider,_that.refreshIntervalSeconds);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double triggerDistanceKm,  double cloudDensityThreshold,  int leadTimeMinutes,  bool weatherSafetyEnabled,  double maxHumidityPercent,  double maxWindSpeedKph,  double maxCloudCoverPercent,  bool autoParkEnabled,  bool autoResumeEnabled,  RadarProviderType preferredProvider,  int refreshIntervalSeconds)?  $default,) {final _that = this;
switch (_that) {
case _WeatherSettings() when $default != null:
return $default(_that.triggerDistanceKm,_that.cloudDensityThreshold,_that.leadTimeMinutes,_that.weatherSafetyEnabled,_that.maxHumidityPercent,_that.maxWindSpeedKph,_that.maxCloudCoverPercent,_that.autoParkEnabled,_that.autoResumeEnabled,_that.preferredProvider,_that.refreshIntervalSeconds);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _WeatherSettings implements WeatherSettings {
  const _WeatherSettings({this.triggerDistanceKm = 30.0, this.cloudDensityThreshold = 60.0, this.leadTimeMinutes = 15, this.weatherSafetyEnabled = false, this.maxHumidityPercent = 90.0, this.maxWindSpeedKph = 30.0, this.maxCloudCoverPercent = 80.0, this.autoParkEnabled = true, this.autoResumeEnabled = false, this.preferredProvider = RadarProviderType.auto, this.refreshIntervalSeconds = 300});
  factory _WeatherSettings.fromJson(Map<String, dynamic> json) => _$WeatherSettingsFromJson(json);

/// Distance threshold for alerts in kilometers
@override@JsonKey() final  double triggerDistanceKm;
/// Cloud density threshold for warnings (0-100 percent)
@override@JsonKey() final  double cloudDensityThreshold;
/// Lead time for alerts in minutes
@override@JsonKey() final  int leadTimeMinutes;
/// Enable weather safety monitoring.
///
/// Defaults OFF: with no weather source or hardware safety monitor
/// configured (the out-of-box state), an enabled monitor fails closed and
/// aborts every automated sequence within seconds — the flagship use case
/// broken on night one for the majority of rigs. Weather gating is now
/// opt-in; a user connects a weather source / safety monitor and turns
/// this on. Existing installs keep their persisted value.
@override@JsonKey() final  bool weatherSafetyEnabled;
/// Maximum safe humidity before weather safety pauses imaging
@override@JsonKey() final  double maxHumidityPercent;
/// Maximum safe wind speed before weather safety pauses imaging
@override@JsonKey() final  double maxWindSpeedKph;
/// Maximum safe cloud cover before weather safety pauses imaging
@override@JsonKey() final  double maxCloudCoverPercent;
/// Automatically park mount when weather threatens
@override@JsonKey() final  bool autoParkEnabled;
/// Automatically resume imaging when weather clears
@override@JsonKey() final  bool autoResumeEnabled;
/// Preferred radar data provider
@override@JsonKey() final  RadarProviderType preferredProvider;
/// How often to refresh radar data in seconds
@override@JsonKey() final  int refreshIntervalSeconds;

/// Create a copy of WeatherSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$WeatherSettingsCopyWith<_WeatherSettings> get copyWith => __$WeatherSettingsCopyWithImpl<_WeatherSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$WeatherSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _WeatherSettings&&(identical(other.triggerDistanceKm, triggerDistanceKm) || other.triggerDistanceKm == triggerDistanceKm)&&(identical(other.cloudDensityThreshold, cloudDensityThreshold) || other.cloudDensityThreshold == cloudDensityThreshold)&&(identical(other.leadTimeMinutes, leadTimeMinutes) || other.leadTimeMinutes == leadTimeMinutes)&&(identical(other.weatherSafetyEnabled, weatherSafetyEnabled) || other.weatherSafetyEnabled == weatherSafetyEnabled)&&(identical(other.maxHumidityPercent, maxHumidityPercent) || other.maxHumidityPercent == maxHumidityPercent)&&(identical(other.maxWindSpeedKph, maxWindSpeedKph) || other.maxWindSpeedKph == maxWindSpeedKph)&&(identical(other.maxCloudCoverPercent, maxCloudCoverPercent) || other.maxCloudCoverPercent == maxCloudCoverPercent)&&(identical(other.autoParkEnabled, autoParkEnabled) || other.autoParkEnabled == autoParkEnabled)&&(identical(other.autoResumeEnabled, autoResumeEnabled) || other.autoResumeEnabled == autoResumeEnabled)&&(identical(other.preferredProvider, preferredProvider) || other.preferredProvider == preferredProvider)&&(identical(other.refreshIntervalSeconds, refreshIntervalSeconds) || other.refreshIntervalSeconds == refreshIntervalSeconds));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,triggerDistanceKm,cloudDensityThreshold,leadTimeMinutes,weatherSafetyEnabled,maxHumidityPercent,maxWindSpeedKph,maxCloudCoverPercent,autoParkEnabled,autoResumeEnabled,preferredProvider,refreshIntervalSeconds);

@override
String toString() {
  return 'WeatherSettings(triggerDistanceKm: $triggerDistanceKm, cloudDensityThreshold: $cloudDensityThreshold, leadTimeMinutes: $leadTimeMinutes, weatherSafetyEnabled: $weatherSafetyEnabled, maxHumidityPercent: $maxHumidityPercent, maxWindSpeedKph: $maxWindSpeedKph, maxCloudCoverPercent: $maxCloudCoverPercent, autoParkEnabled: $autoParkEnabled, autoResumeEnabled: $autoResumeEnabled, preferredProvider: $preferredProvider, refreshIntervalSeconds: $refreshIntervalSeconds)';
}


}

/// @nodoc
abstract mixin class _$WeatherSettingsCopyWith<$Res> implements $WeatherSettingsCopyWith<$Res> {
  factory _$WeatherSettingsCopyWith(_WeatherSettings value, $Res Function(_WeatherSettings) _then) = __$WeatherSettingsCopyWithImpl;
@override @useResult
$Res call({
 double triggerDistanceKm, double cloudDensityThreshold, int leadTimeMinutes, bool weatherSafetyEnabled, double maxHumidityPercent, double maxWindSpeedKph, double maxCloudCoverPercent, bool autoParkEnabled, bool autoResumeEnabled, RadarProviderType preferredProvider, int refreshIntervalSeconds
});




}
/// @nodoc
class __$WeatherSettingsCopyWithImpl<$Res>
    implements _$WeatherSettingsCopyWith<$Res> {
  __$WeatherSettingsCopyWithImpl(this._self, this._then);

  final _WeatherSettings _self;
  final $Res Function(_WeatherSettings) _then;

/// Create a copy of WeatherSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? triggerDistanceKm = null,Object? cloudDensityThreshold = null,Object? leadTimeMinutes = null,Object? weatherSafetyEnabled = null,Object? maxHumidityPercent = null,Object? maxWindSpeedKph = null,Object? maxCloudCoverPercent = null,Object? autoParkEnabled = null,Object? autoResumeEnabled = null,Object? preferredProvider = null,Object? refreshIntervalSeconds = null,}) {
  return _then(_WeatherSettings(
triggerDistanceKm: null == triggerDistanceKm ? _self.triggerDistanceKm : triggerDistanceKm // ignore: cast_nullable_to_non_nullable
as double,cloudDensityThreshold: null == cloudDensityThreshold ? _self.cloudDensityThreshold : cloudDensityThreshold // ignore: cast_nullable_to_non_nullable
as double,leadTimeMinutes: null == leadTimeMinutes ? _self.leadTimeMinutes : leadTimeMinutes // ignore: cast_nullable_to_non_nullable
as int,weatherSafetyEnabled: null == weatherSafetyEnabled ? _self.weatherSafetyEnabled : weatherSafetyEnabled // ignore: cast_nullable_to_non_nullable
as bool,maxHumidityPercent: null == maxHumidityPercent ? _self.maxHumidityPercent : maxHumidityPercent // ignore: cast_nullable_to_non_nullable
as double,maxWindSpeedKph: null == maxWindSpeedKph ? _self.maxWindSpeedKph : maxWindSpeedKph // ignore: cast_nullable_to_non_nullable
as double,maxCloudCoverPercent: null == maxCloudCoverPercent ? _self.maxCloudCoverPercent : maxCloudCoverPercent // ignore: cast_nullable_to_non_nullable
as double,autoParkEnabled: null == autoParkEnabled ? _self.autoParkEnabled : autoParkEnabled // ignore: cast_nullable_to_non_nullable
as bool,autoResumeEnabled: null == autoResumeEnabled ? _self.autoResumeEnabled : autoResumeEnabled // ignore: cast_nullable_to_non_nullable
as bool,preferredProvider: null == preferredProvider ? _self.preferredProvider : preferredProvider // ignore: cast_nullable_to_non_nullable
as RadarProviderType,refreshIntervalSeconds: null == refreshIntervalSeconds ? _self.refreshIntervalSeconds : refreshIntervalSeconds // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
