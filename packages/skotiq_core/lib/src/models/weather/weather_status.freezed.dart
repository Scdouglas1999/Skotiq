// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'weather_status.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$WeatherStatus {

/// Current alert level
 AlertLevel get currentLevel;/// Active alert (null if no alert)
 WeatherAlert? get activeAlert;/// Cloud motion analysis
 CloudMotion? get motion;/// Radar frames for animation
 List<RadarFrame> get radarFrames;/// Current frame index in animation
 int get currentFrameIndex;/// When the radar data behind this status was last fetched.
///
/// NULL until the first successful fetch lands. It is deliberately nullable
/// rather than defaulting to a sentinel: an epoch-zero placeholder here is
/// indistinguishable from a real timestamp downstream, and the card
/// rendered it as "Updated 20667 days ago" on every pre-fetch paint (and
/// for the whole session when the fetch never succeeds).
 DateTime? get lastUpdate;/// Whether data is currently loading
 bool get isLoading;/// Error message if update failed
 String? get errorMessage;
/// Create a copy of WeatherStatus
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$WeatherStatusCopyWith<WeatherStatus> get copyWith => _$WeatherStatusCopyWithImpl<WeatherStatus>(this as WeatherStatus, _$identity);

  /// Serializes this WeatherStatus to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is WeatherStatus&&(identical(other.currentLevel, currentLevel) || other.currentLevel == currentLevel)&&(identical(other.activeAlert, activeAlert) || other.activeAlert == activeAlert)&&(identical(other.motion, motion) || other.motion == motion)&&const DeepCollectionEquality().equals(other.radarFrames, radarFrames)&&(identical(other.currentFrameIndex, currentFrameIndex) || other.currentFrameIndex == currentFrameIndex)&&(identical(other.lastUpdate, lastUpdate) || other.lastUpdate == lastUpdate)&&(identical(other.isLoading, isLoading) || other.isLoading == isLoading)&&(identical(other.errorMessage, errorMessage) || other.errorMessage == errorMessage));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,currentLevel,activeAlert,motion,const DeepCollectionEquality().hash(radarFrames),currentFrameIndex,lastUpdate,isLoading,errorMessage);

@override
String toString() {
  return 'WeatherStatus(currentLevel: $currentLevel, activeAlert: $activeAlert, motion: $motion, radarFrames: $radarFrames, currentFrameIndex: $currentFrameIndex, lastUpdate: $lastUpdate, isLoading: $isLoading, errorMessage: $errorMessage)';
}


}

/// @nodoc
abstract mixin class $WeatherStatusCopyWith<$Res>  {
  factory $WeatherStatusCopyWith(WeatherStatus value, $Res Function(WeatherStatus) _then) = _$WeatherStatusCopyWithImpl;
@useResult
$Res call({
 AlertLevel currentLevel, WeatherAlert? activeAlert, CloudMotion? motion, List<RadarFrame> radarFrames, int currentFrameIndex, DateTime? lastUpdate, bool isLoading, String? errorMessage
});


$WeatherAlertCopyWith<$Res>? get activeAlert;$CloudMotionCopyWith<$Res>? get motion;

}
/// @nodoc
class _$WeatherStatusCopyWithImpl<$Res>
    implements $WeatherStatusCopyWith<$Res> {
  _$WeatherStatusCopyWithImpl(this._self, this._then);

  final WeatherStatus _self;
  final $Res Function(WeatherStatus) _then;

/// Create a copy of WeatherStatus
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? currentLevel = null,Object? activeAlert = freezed,Object? motion = freezed,Object? radarFrames = null,Object? currentFrameIndex = null,Object? lastUpdate = freezed,Object? isLoading = null,Object? errorMessage = freezed,}) {
  return _then(_self.copyWith(
currentLevel: null == currentLevel ? _self.currentLevel : currentLevel // ignore: cast_nullable_to_non_nullable
as AlertLevel,activeAlert: freezed == activeAlert ? _self.activeAlert : activeAlert // ignore: cast_nullable_to_non_nullable
as WeatherAlert?,motion: freezed == motion ? _self.motion : motion // ignore: cast_nullable_to_non_nullable
as CloudMotion?,radarFrames: null == radarFrames ? _self.radarFrames : radarFrames // ignore: cast_nullable_to_non_nullable
as List<RadarFrame>,currentFrameIndex: null == currentFrameIndex ? _self.currentFrameIndex : currentFrameIndex // ignore: cast_nullable_to_non_nullable
as int,lastUpdate: freezed == lastUpdate ? _self.lastUpdate : lastUpdate // ignore: cast_nullable_to_non_nullable
as DateTime?,isLoading: null == isLoading ? _self.isLoading : isLoading // ignore: cast_nullable_to_non_nullable
as bool,errorMessage: freezed == errorMessage ? _self.errorMessage : errorMessage // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}
/// Create a copy of WeatherStatus
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WeatherAlertCopyWith<$Res>? get activeAlert {
    if (_self.activeAlert == null) {
    return null;
  }

  return $WeatherAlertCopyWith<$Res>(_self.activeAlert!, (value) {
    return _then(_self.copyWith(activeAlert: value));
  });
}/// Create a copy of WeatherStatus
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$CloudMotionCopyWith<$Res>? get motion {
    if (_self.motion == null) {
    return null;
  }

  return $CloudMotionCopyWith<$Res>(_self.motion!, (value) {
    return _then(_self.copyWith(motion: value));
  });
}
}


/// Adds pattern-matching-related methods to [WeatherStatus].
extension WeatherStatusPatterns on WeatherStatus {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _WeatherStatus value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _WeatherStatus() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _WeatherStatus value)  $default,){
final _that = this;
switch (_that) {
case _WeatherStatus():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _WeatherStatus value)?  $default,){
final _that = this;
switch (_that) {
case _WeatherStatus() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( AlertLevel currentLevel,  WeatherAlert? activeAlert,  CloudMotion? motion,  List<RadarFrame> radarFrames,  int currentFrameIndex,  DateTime? lastUpdate,  bool isLoading,  String? errorMessage)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _WeatherStatus() when $default != null:
return $default(_that.currentLevel,_that.activeAlert,_that.motion,_that.radarFrames,_that.currentFrameIndex,_that.lastUpdate,_that.isLoading,_that.errorMessage);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( AlertLevel currentLevel,  WeatherAlert? activeAlert,  CloudMotion? motion,  List<RadarFrame> radarFrames,  int currentFrameIndex,  DateTime? lastUpdate,  bool isLoading,  String? errorMessage)  $default,) {final _that = this;
switch (_that) {
case _WeatherStatus():
return $default(_that.currentLevel,_that.activeAlert,_that.motion,_that.radarFrames,_that.currentFrameIndex,_that.lastUpdate,_that.isLoading,_that.errorMessage);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( AlertLevel currentLevel,  WeatherAlert? activeAlert,  CloudMotion? motion,  List<RadarFrame> radarFrames,  int currentFrameIndex,  DateTime? lastUpdate,  bool isLoading,  String? errorMessage)?  $default,) {final _that = this;
switch (_that) {
case _WeatherStatus() when $default != null:
return $default(_that.currentLevel,_that.activeAlert,_that.motion,_that.radarFrames,_that.currentFrameIndex,_that.lastUpdate,_that.isLoading,_that.errorMessage);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _WeatherStatus implements WeatherStatus {
  const _WeatherStatus({this.currentLevel = AlertLevel.clear, this.activeAlert, this.motion, final  List<RadarFrame> radarFrames = const [], this.currentFrameIndex = 0, this.lastUpdate, this.isLoading = false, this.errorMessage}): _radarFrames = radarFrames;
  factory _WeatherStatus.fromJson(Map<String, dynamic> json) => _$WeatherStatusFromJson(json);

/// Current alert level
@override@JsonKey() final  AlertLevel currentLevel;
/// Active alert (null if no alert)
@override final  WeatherAlert? activeAlert;
/// Cloud motion analysis
@override final  CloudMotion? motion;
/// Radar frames for animation
 final  List<RadarFrame> _radarFrames;
/// Radar frames for animation
@override@JsonKey() List<RadarFrame> get radarFrames {
  if (_radarFrames is EqualUnmodifiableListView) return _radarFrames;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_radarFrames);
}

/// Current frame index in animation
@override@JsonKey() final  int currentFrameIndex;
/// When the radar data behind this status was last fetched.
///
/// NULL until the first successful fetch lands. It is deliberately nullable
/// rather than defaulting to a sentinel: an epoch-zero placeholder here is
/// indistinguishable from a real timestamp downstream, and the card
/// rendered it as "Updated 20667 days ago" on every pre-fetch paint (and
/// for the whole session when the fetch never succeeds).
@override final  DateTime? lastUpdate;
/// Whether data is currently loading
@override@JsonKey() final  bool isLoading;
/// Error message if update failed
@override final  String? errorMessage;

/// Create a copy of WeatherStatus
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$WeatherStatusCopyWith<_WeatherStatus> get copyWith => __$WeatherStatusCopyWithImpl<_WeatherStatus>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$WeatherStatusToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _WeatherStatus&&(identical(other.currentLevel, currentLevel) || other.currentLevel == currentLevel)&&(identical(other.activeAlert, activeAlert) || other.activeAlert == activeAlert)&&(identical(other.motion, motion) || other.motion == motion)&&const DeepCollectionEquality().equals(other._radarFrames, _radarFrames)&&(identical(other.currentFrameIndex, currentFrameIndex) || other.currentFrameIndex == currentFrameIndex)&&(identical(other.lastUpdate, lastUpdate) || other.lastUpdate == lastUpdate)&&(identical(other.isLoading, isLoading) || other.isLoading == isLoading)&&(identical(other.errorMessage, errorMessage) || other.errorMessage == errorMessage));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,currentLevel,activeAlert,motion,const DeepCollectionEquality().hash(_radarFrames),currentFrameIndex,lastUpdate,isLoading,errorMessage);

@override
String toString() {
  return 'WeatherStatus(currentLevel: $currentLevel, activeAlert: $activeAlert, motion: $motion, radarFrames: $radarFrames, currentFrameIndex: $currentFrameIndex, lastUpdate: $lastUpdate, isLoading: $isLoading, errorMessage: $errorMessage)';
}


}

/// @nodoc
abstract mixin class _$WeatherStatusCopyWith<$Res> implements $WeatherStatusCopyWith<$Res> {
  factory _$WeatherStatusCopyWith(_WeatherStatus value, $Res Function(_WeatherStatus) _then) = __$WeatherStatusCopyWithImpl;
@override @useResult
$Res call({
 AlertLevel currentLevel, WeatherAlert? activeAlert, CloudMotion? motion, List<RadarFrame> radarFrames, int currentFrameIndex, DateTime? lastUpdate, bool isLoading, String? errorMessage
});


@override $WeatherAlertCopyWith<$Res>? get activeAlert;@override $CloudMotionCopyWith<$Res>? get motion;

}
/// @nodoc
class __$WeatherStatusCopyWithImpl<$Res>
    implements _$WeatherStatusCopyWith<$Res> {
  __$WeatherStatusCopyWithImpl(this._self, this._then);

  final _WeatherStatus _self;
  final $Res Function(_WeatherStatus) _then;

/// Create a copy of WeatherStatus
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? currentLevel = null,Object? activeAlert = freezed,Object? motion = freezed,Object? radarFrames = null,Object? currentFrameIndex = null,Object? lastUpdate = freezed,Object? isLoading = null,Object? errorMessage = freezed,}) {
  return _then(_WeatherStatus(
currentLevel: null == currentLevel ? _self.currentLevel : currentLevel // ignore: cast_nullable_to_non_nullable
as AlertLevel,activeAlert: freezed == activeAlert ? _self.activeAlert : activeAlert // ignore: cast_nullable_to_non_nullable
as WeatherAlert?,motion: freezed == motion ? _self.motion : motion // ignore: cast_nullable_to_non_nullable
as CloudMotion?,radarFrames: null == radarFrames ? _self._radarFrames : radarFrames // ignore: cast_nullable_to_non_nullable
as List<RadarFrame>,currentFrameIndex: null == currentFrameIndex ? _self.currentFrameIndex : currentFrameIndex // ignore: cast_nullable_to_non_nullable
as int,lastUpdate: freezed == lastUpdate ? _self.lastUpdate : lastUpdate // ignore: cast_nullable_to_non_nullable
as DateTime?,isLoading: null == isLoading ? _self.isLoading : isLoading // ignore: cast_nullable_to_non_nullable
as bool,errorMessage: freezed == errorMessage ? _self.errorMessage : errorMessage // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

/// Create a copy of WeatherStatus
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WeatherAlertCopyWith<$Res>? get activeAlert {
    if (_self.activeAlert == null) {
    return null;
  }

  return $WeatherAlertCopyWith<$Res>(_self.activeAlert!, (value) {
    return _then(_self.copyWith(activeAlert: value));
  });
}/// Create a copy of WeatherStatus
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$CloudMotionCopyWith<$Res>? get motion {
    if (_self.motion == null) {
    return null;
  }

  return $CloudMotionCopyWith<$Res>(_self.motion!, (value) {
    return _then(_self.copyWith(motion: value));
  });
}
}

// dart format on
