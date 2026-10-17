// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'target_suggestion.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$TargetSuggestion {

/// Database target ID
 int get targetId;/// Display name of the target
 String get targetName;/// Catalog identifier (e.g., "NGC 7000", "M31")
 String? get catalogId;/// Right Ascension in hours (0-24)
 double get raHours;/// Declination in degrees (-90 to +90)
 double get decDegrees;/// Overall score from 0-100
 double get totalScore;/// Breakdown of individual score components
/// Keys: altitude, moonDistance, transitProximity, darkness, airmass
 Map<String, double> get scoreBreakdown;/// Warnings about target conditions
@TargetWarningListConverter() List<TargetWarning> get warnings;/// Visibility information for this target
@TargetVisibilityInfoConverter() TargetVisibilityInfo get visibility;/// Human-readable explanation of why this target is suggested
 String get reasoning;/// Progress of data collection for this target (0.0 to 1.0)
/// 0.0 = no data collected, 1.0 = fully complete
 double get dataProgress;/// Object type (e.g., "Galaxy", "Emission Nebula", "Open Cluster")
 String? get objectType;/// Visual magnitude
 double? get magnitude;/// Angular size in arcminutes
 double? get sizeArcmin;/// Constellation abbreviation
 String? get constellation;/// Informational tags (e.g., "Mosaic recommended")
 List<String> get tags;
/// Create a copy of TargetSuggestion
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TargetSuggestionCopyWith<TargetSuggestion> get copyWith => _$TargetSuggestionCopyWithImpl<TargetSuggestion>(this as TargetSuggestion, _$identity);

  /// Serializes this TargetSuggestion to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TargetSuggestion&&(identical(other.targetId, targetId) || other.targetId == targetId)&&(identical(other.targetName, targetName) || other.targetName == targetName)&&(identical(other.catalogId, catalogId) || other.catalogId == catalogId)&&(identical(other.raHours, raHours) || other.raHours == raHours)&&(identical(other.decDegrees, decDegrees) || other.decDegrees == decDegrees)&&(identical(other.totalScore, totalScore) || other.totalScore == totalScore)&&const DeepCollectionEquality().equals(other.scoreBreakdown, scoreBreakdown)&&const DeepCollectionEquality().equals(other.warnings, warnings)&&(identical(other.visibility, visibility) || other.visibility == visibility)&&(identical(other.reasoning, reasoning) || other.reasoning == reasoning)&&(identical(other.dataProgress, dataProgress) || other.dataProgress == dataProgress)&&(identical(other.objectType, objectType) || other.objectType == objectType)&&(identical(other.magnitude, magnitude) || other.magnitude == magnitude)&&(identical(other.sizeArcmin, sizeArcmin) || other.sizeArcmin == sizeArcmin)&&(identical(other.constellation, constellation) || other.constellation == constellation)&&const DeepCollectionEquality().equals(other.tags, tags));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,targetId,targetName,catalogId,raHours,decDegrees,totalScore,const DeepCollectionEquality().hash(scoreBreakdown),const DeepCollectionEquality().hash(warnings),visibility,reasoning,dataProgress,objectType,magnitude,sizeArcmin,constellation,const DeepCollectionEquality().hash(tags));

@override
String toString() {
  return 'TargetSuggestion(targetId: $targetId, targetName: $targetName, catalogId: $catalogId, raHours: $raHours, decDegrees: $decDegrees, totalScore: $totalScore, scoreBreakdown: $scoreBreakdown, warnings: $warnings, visibility: $visibility, reasoning: $reasoning, dataProgress: $dataProgress, objectType: $objectType, magnitude: $magnitude, sizeArcmin: $sizeArcmin, constellation: $constellation, tags: $tags)';
}


}

/// @nodoc
abstract mixin class $TargetSuggestionCopyWith<$Res>  {
  factory $TargetSuggestionCopyWith(TargetSuggestion value, $Res Function(TargetSuggestion) _then) = _$TargetSuggestionCopyWithImpl;
@useResult
$Res call({
 int targetId, String targetName, String? catalogId, double raHours, double decDegrees, double totalScore, Map<String, double> scoreBreakdown,@TargetWarningListConverter() List<TargetWarning> warnings,@TargetVisibilityInfoConverter() TargetVisibilityInfo visibility, String reasoning, double dataProgress, String? objectType, double? magnitude, double? sizeArcmin, String? constellation, List<String> tags
});




}
/// @nodoc
class _$TargetSuggestionCopyWithImpl<$Res>
    implements $TargetSuggestionCopyWith<$Res> {
  _$TargetSuggestionCopyWithImpl(this._self, this._then);

  final TargetSuggestion _self;
  final $Res Function(TargetSuggestion) _then;

/// Create a copy of TargetSuggestion
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? targetId = null,Object? targetName = null,Object? catalogId = freezed,Object? raHours = null,Object? decDegrees = null,Object? totalScore = null,Object? scoreBreakdown = null,Object? warnings = null,Object? visibility = null,Object? reasoning = null,Object? dataProgress = null,Object? objectType = freezed,Object? magnitude = freezed,Object? sizeArcmin = freezed,Object? constellation = freezed,Object? tags = null,}) {
  return _then(_self.copyWith(
targetId: null == targetId ? _self.targetId : targetId // ignore: cast_nullable_to_non_nullable
as int,targetName: null == targetName ? _self.targetName : targetName // ignore: cast_nullable_to_non_nullable
as String,catalogId: freezed == catalogId ? _self.catalogId : catalogId // ignore: cast_nullable_to_non_nullable
as String?,raHours: null == raHours ? _self.raHours : raHours // ignore: cast_nullable_to_non_nullable
as double,decDegrees: null == decDegrees ? _self.decDegrees : decDegrees // ignore: cast_nullable_to_non_nullable
as double,totalScore: null == totalScore ? _self.totalScore : totalScore // ignore: cast_nullable_to_non_nullable
as double,scoreBreakdown: null == scoreBreakdown ? _self.scoreBreakdown : scoreBreakdown // ignore: cast_nullable_to_non_nullable
as Map<String, double>,warnings: null == warnings ? _self.warnings : warnings // ignore: cast_nullable_to_non_nullable
as List<TargetWarning>,visibility: null == visibility ? _self.visibility : visibility // ignore: cast_nullable_to_non_nullable
as TargetVisibilityInfo,reasoning: null == reasoning ? _self.reasoning : reasoning // ignore: cast_nullable_to_non_nullable
as String,dataProgress: null == dataProgress ? _self.dataProgress : dataProgress // ignore: cast_nullable_to_non_nullable
as double,objectType: freezed == objectType ? _self.objectType : objectType // ignore: cast_nullable_to_non_nullable
as String?,magnitude: freezed == magnitude ? _self.magnitude : magnitude // ignore: cast_nullable_to_non_nullable
as double?,sizeArcmin: freezed == sizeArcmin ? _self.sizeArcmin : sizeArcmin // ignore: cast_nullable_to_non_nullable
as double?,constellation: freezed == constellation ? _self.constellation : constellation // ignore: cast_nullable_to_non_nullable
as String?,tags: null == tags ? _self.tags : tags // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}

}


/// Adds pattern-matching-related methods to [TargetSuggestion].
extension TargetSuggestionPatterns on TargetSuggestion {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TargetSuggestion value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TargetSuggestion() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TargetSuggestion value)  $default,){
final _that = this;
switch (_that) {
case _TargetSuggestion():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TargetSuggestion value)?  $default,){
final _that = this;
switch (_that) {
case _TargetSuggestion() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int targetId,  String targetName,  String? catalogId,  double raHours,  double decDegrees,  double totalScore,  Map<String, double> scoreBreakdown, @TargetWarningListConverter()  List<TargetWarning> warnings, @TargetVisibilityInfoConverter()  TargetVisibilityInfo visibility,  String reasoning,  double dataProgress,  String? objectType,  double? magnitude,  double? sizeArcmin,  String? constellation,  List<String> tags)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TargetSuggestion() when $default != null:
return $default(_that.targetId,_that.targetName,_that.catalogId,_that.raHours,_that.decDegrees,_that.totalScore,_that.scoreBreakdown,_that.warnings,_that.visibility,_that.reasoning,_that.dataProgress,_that.objectType,_that.magnitude,_that.sizeArcmin,_that.constellation,_that.tags);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int targetId,  String targetName,  String? catalogId,  double raHours,  double decDegrees,  double totalScore,  Map<String, double> scoreBreakdown, @TargetWarningListConverter()  List<TargetWarning> warnings, @TargetVisibilityInfoConverter()  TargetVisibilityInfo visibility,  String reasoning,  double dataProgress,  String? objectType,  double? magnitude,  double? sizeArcmin,  String? constellation,  List<String> tags)  $default,) {final _that = this;
switch (_that) {
case _TargetSuggestion():
return $default(_that.targetId,_that.targetName,_that.catalogId,_that.raHours,_that.decDegrees,_that.totalScore,_that.scoreBreakdown,_that.warnings,_that.visibility,_that.reasoning,_that.dataProgress,_that.objectType,_that.magnitude,_that.sizeArcmin,_that.constellation,_that.tags);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int targetId,  String targetName,  String? catalogId,  double raHours,  double decDegrees,  double totalScore,  Map<String, double> scoreBreakdown, @TargetWarningListConverter()  List<TargetWarning> warnings, @TargetVisibilityInfoConverter()  TargetVisibilityInfo visibility,  String reasoning,  double dataProgress,  String? objectType,  double? magnitude,  double? sizeArcmin,  String? constellation,  List<String> tags)?  $default,) {final _that = this;
switch (_that) {
case _TargetSuggestion() when $default != null:
return $default(_that.targetId,_that.targetName,_that.catalogId,_that.raHours,_that.decDegrees,_that.totalScore,_that.scoreBreakdown,_that.warnings,_that.visibility,_that.reasoning,_that.dataProgress,_that.objectType,_that.magnitude,_that.sizeArcmin,_that.constellation,_that.tags);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _TargetSuggestion implements TargetSuggestion {
  const _TargetSuggestion({required this.targetId, required this.targetName, this.catalogId, required this.raHours, required this.decDegrees, required this.totalScore, final  Map<String, double> scoreBreakdown = const <String, double>{}, @TargetWarningListConverter() final  List<TargetWarning> warnings = const <TargetWarning>[], @TargetVisibilityInfoConverter() required this.visibility, this.reasoning = '', this.dataProgress = 0.0, this.objectType, this.magnitude, this.sizeArcmin, this.constellation, final  List<String> tags = const <String>[]}): _scoreBreakdown = scoreBreakdown,_warnings = warnings,_tags = tags;
  factory _TargetSuggestion.fromJson(Map<String, dynamic> json) => _$TargetSuggestionFromJson(json);

/// Database target ID
@override final  int targetId;
/// Display name of the target
@override final  String targetName;
/// Catalog identifier (e.g., "NGC 7000", "M31")
@override final  String? catalogId;
/// Right Ascension in hours (0-24)
@override final  double raHours;
/// Declination in degrees (-90 to +90)
@override final  double decDegrees;
/// Overall score from 0-100
@override final  double totalScore;
/// Breakdown of individual score components
/// Keys: altitude, moonDistance, transitProximity, darkness, airmass
 final  Map<String, double> _scoreBreakdown;
/// Breakdown of individual score components
/// Keys: altitude, moonDistance, transitProximity, darkness, airmass
@override@JsonKey() Map<String, double> get scoreBreakdown {
  if (_scoreBreakdown is EqualUnmodifiableMapView) return _scoreBreakdown;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_scoreBreakdown);
}

/// Warnings about target conditions
 final  List<TargetWarning> _warnings;
/// Warnings about target conditions
@override@JsonKey()@TargetWarningListConverter() List<TargetWarning> get warnings {
  if (_warnings is EqualUnmodifiableListView) return _warnings;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_warnings);
}

/// Visibility information for this target
@override@TargetVisibilityInfoConverter() final  TargetVisibilityInfo visibility;
/// Human-readable explanation of why this target is suggested
@override@JsonKey() final  String reasoning;
/// Progress of data collection for this target (0.0 to 1.0)
/// 0.0 = no data collected, 1.0 = fully complete
@override@JsonKey() final  double dataProgress;
/// Object type (e.g., "Galaxy", "Emission Nebula", "Open Cluster")
@override final  String? objectType;
/// Visual magnitude
@override final  double? magnitude;
/// Angular size in arcminutes
@override final  double? sizeArcmin;
/// Constellation abbreviation
@override final  String? constellation;
/// Informational tags (e.g., "Mosaic recommended")
 final  List<String> _tags;
/// Informational tags (e.g., "Mosaic recommended")
@override@JsonKey() List<String> get tags {
  if (_tags is EqualUnmodifiableListView) return _tags;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_tags);
}


/// Create a copy of TargetSuggestion
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TargetSuggestionCopyWith<_TargetSuggestion> get copyWith => __$TargetSuggestionCopyWithImpl<_TargetSuggestion>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$TargetSuggestionToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TargetSuggestion&&(identical(other.targetId, targetId) || other.targetId == targetId)&&(identical(other.targetName, targetName) || other.targetName == targetName)&&(identical(other.catalogId, catalogId) || other.catalogId == catalogId)&&(identical(other.raHours, raHours) || other.raHours == raHours)&&(identical(other.decDegrees, decDegrees) || other.decDegrees == decDegrees)&&(identical(other.totalScore, totalScore) || other.totalScore == totalScore)&&const DeepCollectionEquality().equals(other._scoreBreakdown, _scoreBreakdown)&&const DeepCollectionEquality().equals(other._warnings, _warnings)&&(identical(other.visibility, visibility) || other.visibility == visibility)&&(identical(other.reasoning, reasoning) || other.reasoning == reasoning)&&(identical(other.dataProgress, dataProgress) || other.dataProgress == dataProgress)&&(identical(other.objectType, objectType) || other.objectType == objectType)&&(identical(other.magnitude, magnitude) || other.magnitude == magnitude)&&(identical(other.sizeArcmin, sizeArcmin) || other.sizeArcmin == sizeArcmin)&&(identical(other.constellation, constellation) || other.constellation == constellation)&&const DeepCollectionEquality().equals(other._tags, _tags));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,targetId,targetName,catalogId,raHours,decDegrees,totalScore,const DeepCollectionEquality().hash(_scoreBreakdown),const DeepCollectionEquality().hash(_warnings),visibility,reasoning,dataProgress,objectType,magnitude,sizeArcmin,constellation,const DeepCollectionEquality().hash(_tags));

@override
String toString() {
  return 'TargetSuggestion(targetId: $targetId, targetName: $targetName, catalogId: $catalogId, raHours: $raHours, decDegrees: $decDegrees, totalScore: $totalScore, scoreBreakdown: $scoreBreakdown, warnings: $warnings, visibility: $visibility, reasoning: $reasoning, dataProgress: $dataProgress, objectType: $objectType, magnitude: $magnitude, sizeArcmin: $sizeArcmin, constellation: $constellation, tags: $tags)';
}


}

/// @nodoc
abstract mixin class _$TargetSuggestionCopyWith<$Res> implements $TargetSuggestionCopyWith<$Res> {
  factory _$TargetSuggestionCopyWith(_TargetSuggestion value, $Res Function(_TargetSuggestion) _then) = __$TargetSuggestionCopyWithImpl;
@override @useResult
$Res call({
 int targetId, String targetName, String? catalogId, double raHours, double decDegrees, double totalScore, Map<String, double> scoreBreakdown,@TargetWarningListConverter() List<TargetWarning> warnings,@TargetVisibilityInfoConverter() TargetVisibilityInfo visibility, String reasoning, double dataProgress, String? objectType, double? magnitude, double? sizeArcmin, String? constellation, List<String> tags
});




}
/// @nodoc
class __$TargetSuggestionCopyWithImpl<$Res>
    implements _$TargetSuggestionCopyWith<$Res> {
  __$TargetSuggestionCopyWithImpl(this._self, this._then);

  final _TargetSuggestion _self;
  final $Res Function(_TargetSuggestion) _then;

/// Create a copy of TargetSuggestion
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? targetId = null,Object? targetName = null,Object? catalogId = freezed,Object? raHours = null,Object? decDegrees = null,Object? totalScore = null,Object? scoreBreakdown = null,Object? warnings = null,Object? visibility = null,Object? reasoning = null,Object? dataProgress = null,Object? objectType = freezed,Object? magnitude = freezed,Object? sizeArcmin = freezed,Object? constellation = freezed,Object? tags = null,}) {
  return _then(_TargetSuggestion(
targetId: null == targetId ? _self.targetId : targetId // ignore: cast_nullable_to_non_nullable
as int,targetName: null == targetName ? _self.targetName : targetName // ignore: cast_nullable_to_non_nullable
as String,catalogId: freezed == catalogId ? _self.catalogId : catalogId // ignore: cast_nullable_to_non_nullable
as String?,raHours: null == raHours ? _self.raHours : raHours // ignore: cast_nullable_to_non_nullable
as double,decDegrees: null == decDegrees ? _self.decDegrees : decDegrees // ignore: cast_nullable_to_non_nullable
as double,totalScore: null == totalScore ? _self.totalScore : totalScore // ignore: cast_nullable_to_non_nullable
as double,scoreBreakdown: null == scoreBreakdown ? _self._scoreBreakdown : scoreBreakdown // ignore: cast_nullable_to_non_nullable
as Map<String, double>,warnings: null == warnings ? _self._warnings : warnings // ignore: cast_nullable_to_non_nullable
as List<TargetWarning>,visibility: null == visibility ? _self.visibility : visibility // ignore: cast_nullable_to_non_nullable
as TargetVisibilityInfo,reasoning: null == reasoning ? _self.reasoning : reasoning // ignore: cast_nullable_to_non_nullable
as String,dataProgress: null == dataProgress ? _self.dataProgress : dataProgress // ignore: cast_nullable_to_non_nullable
as double,objectType: freezed == objectType ? _self.objectType : objectType // ignore: cast_nullable_to_non_nullable
as String?,magnitude: freezed == magnitude ? _self.magnitude : magnitude // ignore: cast_nullable_to_non_nullable
as double?,sizeArcmin: freezed == sizeArcmin ? _self.sizeArcmin : sizeArcmin // ignore: cast_nullable_to_non_nullable
as double?,constellation: freezed == constellation ? _self.constellation : constellation // ignore: cast_nullable_to_non_nullable
as String?,tags: null == tags ? _self._tags : tags // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}


}


/// @nodoc
mixin _$TargetSuggestionConfig {

/// Minimum altitude in degrees for targets to be considered
 double get minAltitude;/// Maximum distance from moon in degrees (null = no limit)
 double? get maxMoonDistance;/// Preferred object types to prioritize (e.g., ["Galaxy", "Nebula"])
 List<String> get preferredObjectTypes;/// Whether to prioritize targets that need more data
 bool get prioritizeIncomplete;/// Minimum score (0-100) for a target to be suggested
 double get minScore;/// How to sort the suggestions
 SuggestionSortMode get sortMode;
/// Create a copy of TargetSuggestionConfig
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TargetSuggestionConfigCopyWith<TargetSuggestionConfig> get copyWith => _$TargetSuggestionConfigCopyWithImpl<TargetSuggestionConfig>(this as TargetSuggestionConfig, _$identity);

  /// Serializes this TargetSuggestionConfig to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TargetSuggestionConfig&&(identical(other.minAltitude, minAltitude) || other.minAltitude == minAltitude)&&(identical(other.maxMoonDistance, maxMoonDistance) || other.maxMoonDistance == maxMoonDistance)&&const DeepCollectionEquality().equals(other.preferredObjectTypes, preferredObjectTypes)&&(identical(other.prioritizeIncomplete, prioritizeIncomplete) || other.prioritizeIncomplete == prioritizeIncomplete)&&(identical(other.minScore, minScore) || other.minScore == minScore)&&(identical(other.sortMode, sortMode) || other.sortMode == sortMode));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,minAltitude,maxMoonDistance,const DeepCollectionEquality().hash(preferredObjectTypes),prioritizeIncomplete,minScore,sortMode);

@override
String toString() {
  return 'TargetSuggestionConfig(minAltitude: $minAltitude, maxMoonDistance: $maxMoonDistance, preferredObjectTypes: $preferredObjectTypes, prioritizeIncomplete: $prioritizeIncomplete, minScore: $minScore, sortMode: $sortMode)';
}


}

/// @nodoc
abstract mixin class $TargetSuggestionConfigCopyWith<$Res>  {
  factory $TargetSuggestionConfigCopyWith(TargetSuggestionConfig value, $Res Function(TargetSuggestionConfig) _then) = _$TargetSuggestionConfigCopyWithImpl;
@useResult
$Res call({
 double minAltitude, double? maxMoonDistance, List<String> preferredObjectTypes, bool prioritizeIncomplete, double minScore, SuggestionSortMode sortMode
});




}
/// @nodoc
class _$TargetSuggestionConfigCopyWithImpl<$Res>
    implements $TargetSuggestionConfigCopyWith<$Res> {
  _$TargetSuggestionConfigCopyWithImpl(this._self, this._then);

  final TargetSuggestionConfig _self;
  final $Res Function(TargetSuggestionConfig) _then;

/// Create a copy of TargetSuggestionConfig
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? minAltitude = null,Object? maxMoonDistance = freezed,Object? preferredObjectTypes = null,Object? prioritizeIncomplete = null,Object? minScore = null,Object? sortMode = null,}) {
  return _then(_self.copyWith(
minAltitude: null == minAltitude ? _self.minAltitude : minAltitude // ignore: cast_nullable_to_non_nullable
as double,maxMoonDistance: freezed == maxMoonDistance ? _self.maxMoonDistance : maxMoonDistance // ignore: cast_nullable_to_non_nullable
as double?,preferredObjectTypes: null == preferredObjectTypes ? _self.preferredObjectTypes : preferredObjectTypes // ignore: cast_nullable_to_non_nullable
as List<String>,prioritizeIncomplete: null == prioritizeIncomplete ? _self.prioritizeIncomplete : prioritizeIncomplete // ignore: cast_nullable_to_non_nullable
as bool,minScore: null == minScore ? _self.minScore : minScore // ignore: cast_nullable_to_non_nullable
as double,sortMode: null == sortMode ? _self.sortMode : sortMode // ignore: cast_nullable_to_non_nullable
as SuggestionSortMode,
  ));
}

}


/// Adds pattern-matching-related methods to [TargetSuggestionConfig].
extension TargetSuggestionConfigPatterns on TargetSuggestionConfig {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TargetSuggestionConfig value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TargetSuggestionConfig() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TargetSuggestionConfig value)  $default,){
final _that = this;
switch (_that) {
case _TargetSuggestionConfig():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TargetSuggestionConfig value)?  $default,){
final _that = this;
switch (_that) {
case _TargetSuggestionConfig() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double minAltitude,  double? maxMoonDistance,  List<String> preferredObjectTypes,  bool prioritizeIncomplete,  double minScore,  SuggestionSortMode sortMode)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TargetSuggestionConfig() when $default != null:
return $default(_that.minAltitude,_that.maxMoonDistance,_that.preferredObjectTypes,_that.prioritizeIncomplete,_that.minScore,_that.sortMode);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double minAltitude,  double? maxMoonDistance,  List<String> preferredObjectTypes,  bool prioritizeIncomplete,  double minScore,  SuggestionSortMode sortMode)  $default,) {final _that = this;
switch (_that) {
case _TargetSuggestionConfig():
return $default(_that.minAltitude,_that.maxMoonDistance,_that.preferredObjectTypes,_that.prioritizeIncomplete,_that.minScore,_that.sortMode);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double minAltitude,  double? maxMoonDistance,  List<String> preferredObjectTypes,  bool prioritizeIncomplete,  double minScore,  SuggestionSortMode sortMode)?  $default,) {final _that = this;
switch (_that) {
case _TargetSuggestionConfig() when $default != null:
return $default(_that.minAltitude,_that.maxMoonDistance,_that.preferredObjectTypes,_that.prioritizeIncomplete,_that.minScore,_that.sortMode);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _TargetSuggestionConfig implements TargetSuggestionConfig {
  const _TargetSuggestionConfig({this.minAltitude = 30.0, this.maxMoonDistance, final  List<String> preferredObjectTypes = const <String>[], this.prioritizeIncomplete = true, this.minScore = 50.0, this.sortMode = SuggestionSortMode.bestScore}): _preferredObjectTypes = preferredObjectTypes;
  factory _TargetSuggestionConfig.fromJson(Map<String, dynamic> json) => _$TargetSuggestionConfigFromJson(json);

/// Minimum altitude in degrees for targets to be considered
@override@JsonKey() final  double minAltitude;
/// Maximum distance from moon in degrees (null = no limit)
@override final  double? maxMoonDistance;
/// Preferred object types to prioritize (e.g., ["Galaxy", "Nebula"])
 final  List<String> _preferredObjectTypes;
/// Preferred object types to prioritize (e.g., ["Galaxy", "Nebula"])
@override@JsonKey() List<String> get preferredObjectTypes {
  if (_preferredObjectTypes is EqualUnmodifiableListView) return _preferredObjectTypes;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_preferredObjectTypes);
}

/// Whether to prioritize targets that need more data
@override@JsonKey() final  bool prioritizeIncomplete;
/// Minimum score (0-100) for a target to be suggested
@override@JsonKey() final  double minScore;
/// How to sort the suggestions
@override@JsonKey() final  SuggestionSortMode sortMode;

/// Create a copy of TargetSuggestionConfig
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TargetSuggestionConfigCopyWith<_TargetSuggestionConfig> get copyWith => __$TargetSuggestionConfigCopyWithImpl<_TargetSuggestionConfig>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$TargetSuggestionConfigToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TargetSuggestionConfig&&(identical(other.minAltitude, minAltitude) || other.minAltitude == minAltitude)&&(identical(other.maxMoonDistance, maxMoonDistance) || other.maxMoonDistance == maxMoonDistance)&&const DeepCollectionEquality().equals(other._preferredObjectTypes, _preferredObjectTypes)&&(identical(other.prioritizeIncomplete, prioritizeIncomplete) || other.prioritizeIncomplete == prioritizeIncomplete)&&(identical(other.minScore, minScore) || other.minScore == minScore)&&(identical(other.sortMode, sortMode) || other.sortMode == sortMode));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,minAltitude,maxMoonDistance,const DeepCollectionEquality().hash(_preferredObjectTypes),prioritizeIncomplete,minScore,sortMode);

@override
String toString() {
  return 'TargetSuggestionConfig(minAltitude: $minAltitude, maxMoonDistance: $maxMoonDistance, preferredObjectTypes: $preferredObjectTypes, prioritizeIncomplete: $prioritizeIncomplete, minScore: $minScore, sortMode: $sortMode)';
}


}

/// @nodoc
abstract mixin class _$TargetSuggestionConfigCopyWith<$Res> implements $TargetSuggestionConfigCopyWith<$Res> {
  factory _$TargetSuggestionConfigCopyWith(_TargetSuggestionConfig value, $Res Function(_TargetSuggestionConfig) _then) = __$TargetSuggestionConfigCopyWithImpl;
@override @useResult
$Res call({
 double minAltitude, double? maxMoonDistance, List<String> preferredObjectTypes, bool prioritizeIncomplete, double minScore, SuggestionSortMode sortMode
});




}
/// @nodoc
class __$TargetSuggestionConfigCopyWithImpl<$Res>
    implements _$TargetSuggestionConfigCopyWith<$Res> {
  __$TargetSuggestionConfigCopyWithImpl(this._self, this._then);

  final _TargetSuggestionConfig _self;
  final $Res Function(_TargetSuggestionConfig) _then;

/// Create a copy of TargetSuggestionConfig
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? minAltitude = null,Object? maxMoonDistance = freezed,Object? preferredObjectTypes = null,Object? prioritizeIncomplete = null,Object? minScore = null,Object? sortMode = null,}) {
  return _then(_TargetSuggestionConfig(
minAltitude: null == minAltitude ? _self.minAltitude : minAltitude // ignore: cast_nullable_to_non_nullable
as double,maxMoonDistance: freezed == maxMoonDistance ? _self.maxMoonDistance : maxMoonDistance // ignore: cast_nullable_to_non_nullable
as double?,preferredObjectTypes: null == preferredObjectTypes ? _self._preferredObjectTypes : preferredObjectTypes // ignore: cast_nullable_to_non_nullable
as List<String>,prioritizeIncomplete: null == prioritizeIncomplete ? _self.prioritizeIncomplete : prioritizeIncomplete // ignore: cast_nullable_to_non_nullable
as bool,minScore: null == minScore ? _self.minScore : minScore // ignore: cast_nullable_to_non_nullable
as double,sortMode: null == sortMode ? _self.sortMode : sortMode // ignore: cast_nullable_to_non_nullable
as SuggestionSortMode,
  ));
}


}

// dart format on
