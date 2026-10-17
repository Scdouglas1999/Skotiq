// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'transient_alert.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$TransientAlert {

/// Unique identifier for this alert
 String get id;/// Object name/designation (e.g., "SN 2024abc", "V404 Cyg")
 String get name;/// Type of transient event
 TransientType get type;/// Right ascension in hours (0-24)
 double get raHours;/// Declination in degrees (-90 to +90)
 double get decDegrees;/// Current magnitude (null if unknown)
 double? get magnitude;/// Peak/discovery magnitude if known
 double? get peakMagnitude;/// When the transient was discovered
 DateTime get discoveryTime;/// When this alert was last updated
 DateTime get lastUpdated;/// Source of the alert data
 TransientSource get source;/// URL to source announcement/page
 String? get sourceUrl;/// Priority level 1-10 (1=highest, 10=lowest)
 int get priority;/// User notes about this transient
 String? get notes;/// Spectral classification if available (e.g., "Type Ia", "He-rich")
 String? get classification;/// Current state of this alert
 TransientAlertState get state;
/// Create a copy of TransientAlert
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TransientAlertCopyWith<TransientAlert> get copyWith => _$TransientAlertCopyWithImpl<TransientAlert>(this as TransientAlert, _$identity);

  /// Serializes this TransientAlert to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TransientAlert&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.type, type) || other.type == type)&&(identical(other.raHours, raHours) || other.raHours == raHours)&&(identical(other.decDegrees, decDegrees) || other.decDegrees == decDegrees)&&(identical(other.magnitude, magnitude) || other.magnitude == magnitude)&&(identical(other.peakMagnitude, peakMagnitude) || other.peakMagnitude == peakMagnitude)&&(identical(other.discoveryTime, discoveryTime) || other.discoveryTime == discoveryTime)&&(identical(other.lastUpdated, lastUpdated) || other.lastUpdated == lastUpdated)&&(identical(other.source, source) || other.source == source)&&(identical(other.sourceUrl, sourceUrl) || other.sourceUrl == sourceUrl)&&(identical(other.priority, priority) || other.priority == priority)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.classification, classification) || other.classification == classification)&&(identical(other.state, state) || other.state == state));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,type,raHours,decDegrees,magnitude,peakMagnitude,discoveryTime,lastUpdated,source,sourceUrl,priority,notes,classification,state);

@override
String toString() {
  return 'TransientAlert(id: $id, name: $name, type: $type, raHours: $raHours, decDegrees: $decDegrees, magnitude: $magnitude, peakMagnitude: $peakMagnitude, discoveryTime: $discoveryTime, lastUpdated: $lastUpdated, source: $source, sourceUrl: $sourceUrl, priority: $priority, notes: $notes, classification: $classification, state: $state)';
}


}

/// @nodoc
abstract mixin class $TransientAlertCopyWith<$Res>  {
  factory $TransientAlertCopyWith(TransientAlert value, $Res Function(TransientAlert) _then) = _$TransientAlertCopyWithImpl;
@useResult
$Res call({
 String id, String name, TransientType type, double raHours, double decDegrees, double? magnitude, double? peakMagnitude, DateTime discoveryTime, DateTime lastUpdated, TransientSource source, String? sourceUrl, int priority, String? notes, String? classification, TransientAlertState state
});




}
/// @nodoc
class _$TransientAlertCopyWithImpl<$Res>
    implements $TransientAlertCopyWith<$Res> {
  _$TransientAlertCopyWithImpl(this._self, this._then);

  final TransientAlert _self;
  final $Res Function(TransientAlert) _then;

/// Create a copy of TransientAlert
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? type = null,Object? raHours = null,Object? decDegrees = null,Object? magnitude = freezed,Object? peakMagnitude = freezed,Object? discoveryTime = null,Object? lastUpdated = null,Object? source = null,Object? sourceUrl = freezed,Object? priority = null,Object? notes = freezed,Object? classification = freezed,Object? state = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as TransientType,raHours: null == raHours ? _self.raHours : raHours // ignore: cast_nullable_to_non_nullable
as double,decDegrees: null == decDegrees ? _self.decDegrees : decDegrees // ignore: cast_nullable_to_non_nullable
as double,magnitude: freezed == magnitude ? _self.magnitude : magnitude // ignore: cast_nullable_to_non_nullable
as double?,peakMagnitude: freezed == peakMagnitude ? _self.peakMagnitude : peakMagnitude // ignore: cast_nullable_to_non_nullable
as double?,discoveryTime: null == discoveryTime ? _self.discoveryTime : discoveryTime // ignore: cast_nullable_to_non_nullable
as DateTime,lastUpdated: null == lastUpdated ? _self.lastUpdated : lastUpdated // ignore: cast_nullable_to_non_nullable
as DateTime,source: null == source ? _self.source : source // ignore: cast_nullable_to_non_nullable
as TransientSource,sourceUrl: freezed == sourceUrl ? _self.sourceUrl : sourceUrl // ignore: cast_nullable_to_non_nullable
as String?,priority: null == priority ? _self.priority : priority // ignore: cast_nullable_to_non_nullable
as int,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,classification: freezed == classification ? _self.classification : classification // ignore: cast_nullable_to_non_nullable
as String?,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as TransientAlertState,
  ));
}

}


/// Adds pattern-matching-related methods to [TransientAlert].
extension TransientAlertPatterns on TransientAlert {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TransientAlert value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TransientAlert() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TransientAlert value)  $default,){
final _that = this;
switch (_that) {
case _TransientAlert():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TransientAlert value)?  $default,){
final _that = this;
switch (_that) {
case _TransientAlert() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  TransientType type,  double raHours,  double decDegrees,  double? magnitude,  double? peakMagnitude,  DateTime discoveryTime,  DateTime lastUpdated,  TransientSource source,  String? sourceUrl,  int priority,  String? notes,  String? classification,  TransientAlertState state)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TransientAlert() when $default != null:
return $default(_that.id,_that.name,_that.type,_that.raHours,_that.decDegrees,_that.magnitude,_that.peakMagnitude,_that.discoveryTime,_that.lastUpdated,_that.source,_that.sourceUrl,_that.priority,_that.notes,_that.classification,_that.state);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  TransientType type,  double raHours,  double decDegrees,  double? magnitude,  double? peakMagnitude,  DateTime discoveryTime,  DateTime lastUpdated,  TransientSource source,  String? sourceUrl,  int priority,  String? notes,  String? classification,  TransientAlertState state)  $default,) {final _that = this;
switch (_that) {
case _TransientAlert():
return $default(_that.id,_that.name,_that.type,_that.raHours,_that.decDegrees,_that.magnitude,_that.peakMagnitude,_that.discoveryTime,_that.lastUpdated,_that.source,_that.sourceUrl,_that.priority,_that.notes,_that.classification,_that.state);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  TransientType type,  double raHours,  double decDegrees,  double? magnitude,  double? peakMagnitude,  DateTime discoveryTime,  DateTime lastUpdated,  TransientSource source,  String? sourceUrl,  int priority,  String? notes,  String? classification,  TransientAlertState state)?  $default,) {final _that = this;
switch (_that) {
case _TransientAlert() when $default != null:
return $default(_that.id,_that.name,_that.type,_that.raHours,_that.decDegrees,_that.magnitude,_that.peakMagnitude,_that.discoveryTime,_that.lastUpdated,_that.source,_that.sourceUrl,_that.priority,_that.notes,_that.classification,_that.state);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _TransientAlert implements TransientAlert {
  const _TransientAlert({required this.id, required this.name, required this.type, required this.raHours, required this.decDegrees, this.magnitude, this.peakMagnitude, required this.discoveryTime, required this.lastUpdated, required this.source, this.sourceUrl, this.priority = 5, this.notes, this.classification, this.state = TransientAlertState.newAlert});
  factory _TransientAlert.fromJson(Map<String, dynamic> json) => _$TransientAlertFromJson(json);

/// Unique identifier for this alert
@override final  String id;
/// Object name/designation (e.g., "SN 2024abc", "V404 Cyg")
@override final  String name;
/// Type of transient event
@override final  TransientType type;
/// Right ascension in hours (0-24)
@override final  double raHours;
/// Declination in degrees (-90 to +90)
@override final  double decDegrees;
/// Current magnitude (null if unknown)
@override final  double? magnitude;
/// Peak/discovery magnitude if known
@override final  double? peakMagnitude;
/// When the transient was discovered
@override final  DateTime discoveryTime;
/// When this alert was last updated
@override final  DateTime lastUpdated;
/// Source of the alert data
@override final  TransientSource source;
/// URL to source announcement/page
@override final  String? sourceUrl;
/// Priority level 1-10 (1=highest, 10=lowest)
@override@JsonKey() final  int priority;
/// User notes about this transient
@override final  String? notes;
/// Spectral classification if available (e.g., "Type Ia", "He-rich")
@override final  String? classification;
/// Current state of this alert
@override@JsonKey() final  TransientAlertState state;

/// Create a copy of TransientAlert
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TransientAlertCopyWith<_TransientAlert> get copyWith => __$TransientAlertCopyWithImpl<_TransientAlert>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$TransientAlertToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TransientAlert&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.type, type) || other.type == type)&&(identical(other.raHours, raHours) || other.raHours == raHours)&&(identical(other.decDegrees, decDegrees) || other.decDegrees == decDegrees)&&(identical(other.magnitude, magnitude) || other.magnitude == magnitude)&&(identical(other.peakMagnitude, peakMagnitude) || other.peakMagnitude == peakMagnitude)&&(identical(other.discoveryTime, discoveryTime) || other.discoveryTime == discoveryTime)&&(identical(other.lastUpdated, lastUpdated) || other.lastUpdated == lastUpdated)&&(identical(other.source, source) || other.source == source)&&(identical(other.sourceUrl, sourceUrl) || other.sourceUrl == sourceUrl)&&(identical(other.priority, priority) || other.priority == priority)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.classification, classification) || other.classification == classification)&&(identical(other.state, state) || other.state == state));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,type,raHours,decDegrees,magnitude,peakMagnitude,discoveryTime,lastUpdated,source,sourceUrl,priority,notes,classification,state);

@override
String toString() {
  return 'TransientAlert(id: $id, name: $name, type: $type, raHours: $raHours, decDegrees: $decDegrees, magnitude: $magnitude, peakMagnitude: $peakMagnitude, discoveryTime: $discoveryTime, lastUpdated: $lastUpdated, source: $source, sourceUrl: $sourceUrl, priority: $priority, notes: $notes, classification: $classification, state: $state)';
}


}

/// @nodoc
abstract mixin class _$TransientAlertCopyWith<$Res> implements $TransientAlertCopyWith<$Res> {
  factory _$TransientAlertCopyWith(_TransientAlert value, $Res Function(_TransientAlert) _then) = __$TransientAlertCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, TransientType type, double raHours, double decDegrees, double? magnitude, double? peakMagnitude, DateTime discoveryTime, DateTime lastUpdated, TransientSource source, String? sourceUrl, int priority, String? notes, String? classification, TransientAlertState state
});




}
/// @nodoc
class __$TransientAlertCopyWithImpl<$Res>
    implements _$TransientAlertCopyWith<$Res> {
  __$TransientAlertCopyWithImpl(this._self, this._then);

  final _TransientAlert _self;
  final $Res Function(_TransientAlert) _then;

/// Create a copy of TransientAlert
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? type = null,Object? raHours = null,Object? decDegrees = null,Object? magnitude = freezed,Object? peakMagnitude = freezed,Object? discoveryTime = null,Object? lastUpdated = null,Object? source = null,Object? sourceUrl = freezed,Object? priority = null,Object? notes = freezed,Object? classification = freezed,Object? state = null,}) {
  return _then(_TransientAlert(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as TransientType,raHours: null == raHours ? _self.raHours : raHours // ignore: cast_nullable_to_non_nullable
as double,decDegrees: null == decDegrees ? _self.decDegrees : decDegrees // ignore: cast_nullable_to_non_nullable
as double,magnitude: freezed == magnitude ? _self.magnitude : magnitude // ignore: cast_nullable_to_non_nullable
as double?,peakMagnitude: freezed == peakMagnitude ? _self.peakMagnitude : peakMagnitude // ignore: cast_nullable_to_non_nullable
as double?,discoveryTime: null == discoveryTime ? _self.discoveryTime : discoveryTime // ignore: cast_nullable_to_non_nullable
as DateTime,lastUpdated: null == lastUpdated ? _self.lastUpdated : lastUpdated // ignore: cast_nullable_to_non_nullable
as DateTime,source: null == source ? _self.source : source // ignore: cast_nullable_to_non_nullable
as TransientSource,sourceUrl: freezed == sourceUrl ? _self.sourceUrl : sourceUrl // ignore: cast_nullable_to_non_nullable
as String?,priority: null == priority ? _self.priority : priority // ignore: cast_nullable_to_non_nullable
as int,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,classification: freezed == classification ? _self.classification : classification // ignore: cast_nullable_to_non_nullable
as String?,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as TransientAlertState,
  ));
}


}


/// @nodoc
mixin _$TransientAlertSettings {

/// Which alert sources to monitor.
///
/// Defaults to the fetchable feed plus manual entry. It used to default to
/// {aavso, mpec, cbat, manual} — three sources that are never queried — so
/// out of the box the app reported it was monitoring feeds it was not.
/// TNS still needs its bot credentials before it can return anything (see
/// tnsApiKey and Settings > Science).
 Set<TransientSource> get enabledSources;/// Only show alerts brighter than this magnitude
 double get magnitudeThreshold;/// Which transient types to monitor
 Set<TransientType> get typesToMonitor;/// Show notification when new alerts arrive
 bool get notifyOnNew;/// Automatically queue bright transients for observation
 bool get autoQueueBright;/// Magnitude threshold for auto-queuing (brighter = lower number)
 double get autoQueueMagnitude;/// TNS (Transient Name Server) API key.
/// Required for TNS alerts. Obtain at https://www.wis-tns.org/
/// Leave empty to disable TNS source.
 String? get tnsApiKey;
/// Create a copy of TransientAlertSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TransientAlertSettingsCopyWith<TransientAlertSettings> get copyWith => _$TransientAlertSettingsCopyWithImpl<TransientAlertSettings>(this as TransientAlertSettings, _$identity);

  /// Serializes this TransientAlertSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TransientAlertSettings&&const DeepCollectionEquality().equals(other.enabledSources, enabledSources)&&(identical(other.magnitudeThreshold, magnitudeThreshold) || other.magnitudeThreshold == magnitudeThreshold)&&const DeepCollectionEquality().equals(other.typesToMonitor, typesToMonitor)&&(identical(other.notifyOnNew, notifyOnNew) || other.notifyOnNew == notifyOnNew)&&(identical(other.autoQueueBright, autoQueueBright) || other.autoQueueBright == autoQueueBright)&&(identical(other.autoQueueMagnitude, autoQueueMagnitude) || other.autoQueueMagnitude == autoQueueMagnitude)&&(identical(other.tnsApiKey, tnsApiKey) || other.tnsApiKey == tnsApiKey));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(enabledSources),magnitudeThreshold,const DeepCollectionEquality().hash(typesToMonitor),notifyOnNew,autoQueueBright,autoQueueMagnitude,tnsApiKey);

@override
String toString() {
  return 'TransientAlertSettings(enabledSources: $enabledSources, magnitudeThreshold: $magnitudeThreshold, typesToMonitor: $typesToMonitor, notifyOnNew: $notifyOnNew, autoQueueBright: $autoQueueBright, autoQueueMagnitude: $autoQueueMagnitude, tnsApiKey: $tnsApiKey)';
}


}

/// @nodoc
abstract mixin class $TransientAlertSettingsCopyWith<$Res>  {
  factory $TransientAlertSettingsCopyWith(TransientAlertSettings value, $Res Function(TransientAlertSettings) _then) = _$TransientAlertSettingsCopyWithImpl;
@useResult
$Res call({
 Set<TransientSource> enabledSources, double magnitudeThreshold, Set<TransientType> typesToMonitor, bool notifyOnNew, bool autoQueueBright, double autoQueueMagnitude, String? tnsApiKey
});




}
/// @nodoc
class _$TransientAlertSettingsCopyWithImpl<$Res>
    implements $TransientAlertSettingsCopyWith<$Res> {
  _$TransientAlertSettingsCopyWithImpl(this._self, this._then);

  final TransientAlertSettings _self;
  final $Res Function(TransientAlertSettings) _then;

/// Create a copy of TransientAlertSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? enabledSources = null,Object? magnitudeThreshold = null,Object? typesToMonitor = null,Object? notifyOnNew = null,Object? autoQueueBright = null,Object? autoQueueMagnitude = null,Object? tnsApiKey = freezed,}) {
  return _then(_self.copyWith(
enabledSources: null == enabledSources ? _self.enabledSources : enabledSources // ignore: cast_nullable_to_non_nullable
as Set<TransientSource>,magnitudeThreshold: null == magnitudeThreshold ? _self.magnitudeThreshold : magnitudeThreshold // ignore: cast_nullable_to_non_nullable
as double,typesToMonitor: null == typesToMonitor ? _self.typesToMonitor : typesToMonitor // ignore: cast_nullable_to_non_nullable
as Set<TransientType>,notifyOnNew: null == notifyOnNew ? _self.notifyOnNew : notifyOnNew // ignore: cast_nullable_to_non_nullable
as bool,autoQueueBright: null == autoQueueBright ? _self.autoQueueBright : autoQueueBright // ignore: cast_nullable_to_non_nullable
as bool,autoQueueMagnitude: null == autoQueueMagnitude ? _self.autoQueueMagnitude : autoQueueMagnitude // ignore: cast_nullable_to_non_nullable
as double,tnsApiKey: freezed == tnsApiKey ? _self.tnsApiKey : tnsApiKey // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [TransientAlertSettings].
extension TransientAlertSettingsPatterns on TransientAlertSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TransientAlertSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TransientAlertSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TransientAlertSettings value)  $default,){
final _that = this;
switch (_that) {
case _TransientAlertSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TransientAlertSettings value)?  $default,){
final _that = this;
switch (_that) {
case _TransientAlertSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( Set<TransientSource> enabledSources,  double magnitudeThreshold,  Set<TransientType> typesToMonitor,  bool notifyOnNew,  bool autoQueueBright,  double autoQueueMagnitude,  String? tnsApiKey)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TransientAlertSettings() when $default != null:
return $default(_that.enabledSources,_that.magnitudeThreshold,_that.typesToMonitor,_that.notifyOnNew,_that.autoQueueBright,_that.autoQueueMagnitude,_that.tnsApiKey);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( Set<TransientSource> enabledSources,  double magnitudeThreshold,  Set<TransientType> typesToMonitor,  bool notifyOnNew,  bool autoQueueBright,  double autoQueueMagnitude,  String? tnsApiKey)  $default,) {final _that = this;
switch (_that) {
case _TransientAlertSettings():
return $default(_that.enabledSources,_that.magnitudeThreshold,_that.typesToMonitor,_that.notifyOnNew,_that.autoQueueBright,_that.autoQueueMagnitude,_that.tnsApiKey);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( Set<TransientSource> enabledSources,  double magnitudeThreshold,  Set<TransientType> typesToMonitor,  bool notifyOnNew,  bool autoQueueBright,  double autoQueueMagnitude,  String? tnsApiKey)?  $default,) {final _that = this;
switch (_that) {
case _TransientAlertSettings() when $default != null:
return $default(_that.enabledSources,_that.magnitudeThreshold,_that.typesToMonitor,_that.notifyOnNew,_that.autoQueueBright,_that.autoQueueMagnitude,_that.tnsApiKey);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _TransientAlertSettings implements TransientAlertSettings {
  const _TransientAlertSettings({final  Set<TransientSource> enabledSources = const {TransientSource.tns, TransientSource.manual}, this.magnitudeThreshold = 15.0, final  Set<TransientType> typesToMonitor = const {TransientType.nova, TransientType.supernova, TransientType.cataclysmic, TransientType.comet, TransientType.asteroid, TransientType.variableStar, TransientType.gammaRayBurst, TransientType.other}, this.notifyOnNew = true, this.autoQueueBright = false, this.autoQueueMagnitude = 10.0, this.tnsApiKey}): _enabledSources = enabledSources,_typesToMonitor = typesToMonitor;
  factory _TransientAlertSettings.fromJson(Map<String, dynamic> json) => _$TransientAlertSettingsFromJson(json);

/// Which alert sources to monitor.
///
/// Defaults to the fetchable feed plus manual entry. It used to default to
/// {aavso, mpec, cbat, manual} — three sources that are never queried — so
/// out of the box the app reported it was monitoring feeds it was not.
/// TNS still needs its bot credentials before it can return anything (see
/// tnsApiKey and Settings > Science).
 final  Set<TransientSource> _enabledSources;
/// Which alert sources to monitor.
///
/// Defaults to the fetchable feed plus manual entry. It used to default to
/// {aavso, mpec, cbat, manual} — three sources that are never queried — so
/// out of the box the app reported it was monitoring feeds it was not.
/// TNS still needs its bot credentials before it can return anything (see
/// tnsApiKey and Settings > Science).
@override@JsonKey() Set<TransientSource> get enabledSources {
  if (_enabledSources is EqualUnmodifiableSetView) return _enabledSources;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableSetView(_enabledSources);
}

/// Only show alerts brighter than this magnitude
@override@JsonKey() final  double magnitudeThreshold;
/// Which transient types to monitor
 final  Set<TransientType> _typesToMonitor;
/// Which transient types to monitor
@override@JsonKey() Set<TransientType> get typesToMonitor {
  if (_typesToMonitor is EqualUnmodifiableSetView) return _typesToMonitor;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableSetView(_typesToMonitor);
}

/// Show notification when new alerts arrive
@override@JsonKey() final  bool notifyOnNew;
/// Automatically queue bright transients for observation
@override@JsonKey() final  bool autoQueueBright;
/// Magnitude threshold for auto-queuing (brighter = lower number)
@override@JsonKey() final  double autoQueueMagnitude;
/// TNS (Transient Name Server) API key.
/// Required for TNS alerts. Obtain at https://www.wis-tns.org/
/// Leave empty to disable TNS source.
@override final  String? tnsApiKey;

/// Create a copy of TransientAlertSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TransientAlertSettingsCopyWith<_TransientAlertSettings> get copyWith => __$TransientAlertSettingsCopyWithImpl<_TransientAlertSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$TransientAlertSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TransientAlertSettings&&const DeepCollectionEquality().equals(other._enabledSources, _enabledSources)&&(identical(other.magnitudeThreshold, magnitudeThreshold) || other.magnitudeThreshold == magnitudeThreshold)&&const DeepCollectionEquality().equals(other._typesToMonitor, _typesToMonitor)&&(identical(other.notifyOnNew, notifyOnNew) || other.notifyOnNew == notifyOnNew)&&(identical(other.autoQueueBright, autoQueueBright) || other.autoQueueBright == autoQueueBright)&&(identical(other.autoQueueMagnitude, autoQueueMagnitude) || other.autoQueueMagnitude == autoQueueMagnitude)&&(identical(other.tnsApiKey, tnsApiKey) || other.tnsApiKey == tnsApiKey));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_enabledSources),magnitudeThreshold,const DeepCollectionEquality().hash(_typesToMonitor),notifyOnNew,autoQueueBright,autoQueueMagnitude,tnsApiKey);

@override
String toString() {
  return 'TransientAlertSettings(enabledSources: $enabledSources, magnitudeThreshold: $magnitudeThreshold, typesToMonitor: $typesToMonitor, notifyOnNew: $notifyOnNew, autoQueueBright: $autoQueueBright, autoQueueMagnitude: $autoQueueMagnitude, tnsApiKey: $tnsApiKey)';
}


}

/// @nodoc
abstract mixin class _$TransientAlertSettingsCopyWith<$Res> implements $TransientAlertSettingsCopyWith<$Res> {
  factory _$TransientAlertSettingsCopyWith(_TransientAlertSettings value, $Res Function(_TransientAlertSettings) _then) = __$TransientAlertSettingsCopyWithImpl;
@override @useResult
$Res call({
 Set<TransientSource> enabledSources, double magnitudeThreshold, Set<TransientType> typesToMonitor, bool notifyOnNew, bool autoQueueBright, double autoQueueMagnitude, String? tnsApiKey
});




}
/// @nodoc
class __$TransientAlertSettingsCopyWithImpl<$Res>
    implements _$TransientAlertSettingsCopyWith<$Res> {
  __$TransientAlertSettingsCopyWithImpl(this._self, this._then);

  final _TransientAlertSettings _self;
  final $Res Function(_TransientAlertSettings) _then;

/// Create a copy of TransientAlertSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? enabledSources = null,Object? magnitudeThreshold = null,Object? typesToMonitor = null,Object? notifyOnNew = null,Object? autoQueueBright = null,Object? autoQueueMagnitude = null,Object? tnsApiKey = freezed,}) {
  return _then(_TransientAlertSettings(
enabledSources: null == enabledSources ? _self._enabledSources : enabledSources // ignore: cast_nullable_to_non_nullable
as Set<TransientSource>,magnitudeThreshold: null == magnitudeThreshold ? _self.magnitudeThreshold : magnitudeThreshold // ignore: cast_nullable_to_non_nullable
as double,typesToMonitor: null == typesToMonitor ? _self._typesToMonitor : typesToMonitor // ignore: cast_nullable_to_non_nullable
as Set<TransientType>,notifyOnNew: null == notifyOnNew ? _self.notifyOnNew : notifyOnNew // ignore: cast_nullable_to_non_nullable
as bool,autoQueueBright: null == autoQueueBright ? _self.autoQueueBright : autoQueueBright // ignore: cast_nullable_to_non_nullable
as bool,autoQueueMagnitude: null == autoQueueMagnitude ? _self.autoQueueMagnitude : autoQueueMagnitude // ignore: cast_nullable_to_non_nullable
as double,tnsApiKey: freezed == tnsApiKey ? _self.tnsApiKey : tnsApiKey // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on
