// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'radar_frame.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$RadarFrame {

/// When this radar frame was captured
 DateTime get timestamp;/// URL template for map tiles
/// - For XYZ: template with {z}/{x}/{y} tokens
/// - For WMS: base URL (without bbox parameter)
 String get tileUrlTemplate;/// Geographic bounds - northern boundary
 double get north;/// Geographic bounds - southern boundary
 double get south;/// Geographic bounds - eastern boundary
 double get east;/// Geographic bounds - western boundary
 double get west;/// Opacity for animation blending (0.0-1.0)
 double get opacity;/// Per-cell radar intensity field over the frame's geographic bounds, in
/// row-major order (outer list = rows running NORTH→SOUTH, inner list =
/// columns running WEST→EAST), each value normalised to 0.0–1.0.
///
/// This is the real spatial radar signal decoded from the provider's tiles
/// (the reflectivity colormap mapped to intensity per pixel, downsampled to
/// this grid). When present and non-empty it lets the cloud-motion analyzer
/// track a genuine cloud centroid that MOVES between frames, instead of the
/// single uniform [opacity] box that carries no spatial structure.
///
/// The grid spans exactly [north]..[south] (rows) and [west]..[east]
/// (columns); cell (r, c) covers the geographic sub-rectangle obtained by
/// linearly interpolating those bounds. Null when the provider could not
/// decode per-cell data (e.g. a tile-less WMS layer or a fetch/decode
/// failure) — the analyzer then treats the frame as having no spatial data
/// and reports its honest unavailable reason rather than fabricating motion.
 List<List<double>>? get intensityGrid;/// True when this frame was produced but carries no usable radar signal
/// (the tile fetch or decode failed). Such a frame is emitted — rather than
/// silently dropped — so the analyzer/UI can report an honest "no spatial
/// radar data" state instead of acting on a fabricated uniform field. A
/// no-data frame never contributes density to the analysis.
 bool get isNoData;/// True if this is a forecast frame vs historical
 bool get isForecast;/// Type of tile service (XYZ or WMS)
 RadarTileType get tileType;/// WMS layer name(s) - only used when tileType is wms
 String? get wmsLayers;/// Additional WMS parameters (e.g., time, styles) - only used when tileType is wms
 Map<String, String>? get wmsAdditionalOptions;
/// Create a copy of RadarFrame
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RadarFrameCopyWith<RadarFrame> get copyWith => _$RadarFrameCopyWithImpl<RadarFrame>(this as RadarFrame, _$identity);

  /// Serializes this RadarFrame to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RadarFrame&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp)&&(identical(other.tileUrlTemplate, tileUrlTemplate) || other.tileUrlTemplate == tileUrlTemplate)&&(identical(other.north, north) || other.north == north)&&(identical(other.south, south) || other.south == south)&&(identical(other.east, east) || other.east == east)&&(identical(other.west, west) || other.west == west)&&(identical(other.opacity, opacity) || other.opacity == opacity)&&const DeepCollectionEquality().equals(other.intensityGrid, intensityGrid)&&(identical(other.isNoData, isNoData) || other.isNoData == isNoData)&&(identical(other.isForecast, isForecast) || other.isForecast == isForecast)&&(identical(other.tileType, tileType) || other.tileType == tileType)&&(identical(other.wmsLayers, wmsLayers) || other.wmsLayers == wmsLayers)&&const DeepCollectionEquality().equals(other.wmsAdditionalOptions, wmsAdditionalOptions));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,timestamp,tileUrlTemplate,north,south,east,west,opacity,const DeepCollectionEquality().hash(intensityGrid),isNoData,isForecast,tileType,wmsLayers,const DeepCollectionEquality().hash(wmsAdditionalOptions));

@override
String toString() {
  return 'RadarFrame(timestamp: $timestamp, tileUrlTemplate: $tileUrlTemplate, north: $north, south: $south, east: $east, west: $west, opacity: $opacity, intensityGrid: $intensityGrid, isNoData: $isNoData, isForecast: $isForecast, tileType: $tileType, wmsLayers: $wmsLayers, wmsAdditionalOptions: $wmsAdditionalOptions)';
}


}

/// @nodoc
abstract mixin class $RadarFrameCopyWith<$Res>  {
  factory $RadarFrameCopyWith(RadarFrame value, $Res Function(RadarFrame) _then) = _$RadarFrameCopyWithImpl;
@useResult
$Res call({
 DateTime timestamp, String tileUrlTemplate, double north, double south, double east, double west, double opacity, List<List<double>>? intensityGrid, bool isNoData, bool isForecast, RadarTileType tileType, String? wmsLayers, Map<String, String>? wmsAdditionalOptions
});




}
/// @nodoc
class _$RadarFrameCopyWithImpl<$Res>
    implements $RadarFrameCopyWith<$Res> {
  _$RadarFrameCopyWithImpl(this._self, this._then);

  final RadarFrame _self;
  final $Res Function(RadarFrame) _then;

/// Create a copy of RadarFrame
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? timestamp = null,Object? tileUrlTemplate = null,Object? north = null,Object? south = null,Object? east = null,Object? west = null,Object? opacity = null,Object? intensityGrid = freezed,Object? isNoData = null,Object? isForecast = null,Object? tileType = null,Object? wmsLayers = freezed,Object? wmsAdditionalOptions = freezed,}) {
  return _then(_self.copyWith(
timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as DateTime,tileUrlTemplate: null == tileUrlTemplate ? _self.tileUrlTemplate : tileUrlTemplate // ignore: cast_nullable_to_non_nullable
as String,north: null == north ? _self.north : north // ignore: cast_nullable_to_non_nullable
as double,south: null == south ? _self.south : south // ignore: cast_nullable_to_non_nullable
as double,east: null == east ? _self.east : east // ignore: cast_nullable_to_non_nullable
as double,west: null == west ? _self.west : west // ignore: cast_nullable_to_non_nullable
as double,opacity: null == opacity ? _self.opacity : opacity // ignore: cast_nullable_to_non_nullable
as double,intensityGrid: freezed == intensityGrid ? _self.intensityGrid : intensityGrid // ignore: cast_nullable_to_non_nullable
as List<List<double>>?,isNoData: null == isNoData ? _self.isNoData : isNoData // ignore: cast_nullable_to_non_nullable
as bool,isForecast: null == isForecast ? _self.isForecast : isForecast // ignore: cast_nullable_to_non_nullable
as bool,tileType: null == tileType ? _self.tileType : tileType // ignore: cast_nullable_to_non_nullable
as RadarTileType,wmsLayers: freezed == wmsLayers ? _self.wmsLayers : wmsLayers // ignore: cast_nullable_to_non_nullable
as String?,wmsAdditionalOptions: freezed == wmsAdditionalOptions ? _self.wmsAdditionalOptions : wmsAdditionalOptions // ignore: cast_nullable_to_non_nullable
as Map<String, String>?,
  ));
}

}


/// Adds pattern-matching-related methods to [RadarFrame].
extension RadarFramePatterns on RadarFrame {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _RadarFrame value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _RadarFrame() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _RadarFrame value)  $default,){
final _that = this;
switch (_that) {
case _RadarFrame():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _RadarFrame value)?  $default,){
final _that = this;
switch (_that) {
case _RadarFrame() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( DateTime timestamp,  String tileUrlTemplate,  double north,  double south,  double east,  double west,  double opacity,  List<List<double>>? intensityGrid,  bool isNoData,  bool isForecast,  RadarTileType tileType,  String? wmsLayers,  Map<String, String>? wmsAdditionalOptions)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _RadarFrame() when $default != null:
return $default(_that.timestamp,_that.tileUrlTemplate,_that.north,_that.south,_that.east,_that.west,_that.opacity,_that.intensityGrid,_that.isNoData,_that.isForecast,_that.tileType,_that.wmsLayers,_that.wmsAdditionalOptions);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( DateTime timestamp,  String tileUrlTemplate,  double north,  double south,  double east,  double west,  double opacity,  List<List<double>>? intensityGrid,  bool isNoData,  bool isForecast,  RadarTileType tileType,  String? wmsLayers,  Map<String, String>? wmsAdditionalOptions)  $default,) {final _that = this;
switch (_that) {
case _RadarFrame():
return $default(_that.timestamp,_that.tileUrlTemplate,_that.north,_that.south,_that.east,_that.west,_that.opacity,_that.intensityGrid,_that.isNoData,_that.isForecast,_that.tileType,_that.wmsLayers,_that.wmsAdditionalOptions);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( DateTime timestamp,  String tileUrlTemplate,  double north,  double south,  double east,  double west,  double opacity,  List<List<double>>? intensityGrid,  bool isNoData,  bool isForecast,  RadarTileType tileType,  String? wmsLayers,  Map<String, String>? wmsAdditionalOptions)?  $default,) {final _that = this;
switch (_that) {
case _RadarFrame() when $default != null:
return $default(_that.timestamp,_that.tileUrlTemplate,_that.north,_that.south,_that.east,_that.west,_that.opacity,_that.intensityGrid,_that.isNoData,_that.isForecast,_that.tileType,_that.wmsLayers,_that.wmsAdditionalOptions);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _RadarFrame implements RadarFrame {
  const _RadarFrame({required this.timestamp, required this.tileUrlTemplate, required this.north, required this.south, required this.east, required this.west, this.opacity = 1.0, final  List<List<double>>? intensityGrid, this.isNoData = false, this.isForecast = false, this.tileType = RadarTileType.xyz, this.wmsLayers, final  Map<String, String>? wmsAdditionalOptions}): _intensityGrid = intensityGrid,_wmsAdditionalOptions = wmsAdditionalOptions;
  factory _RadarFrame.fromJson(Map<String, dynamic> json) => _$RadarFrameFromJson(json);

/// When this radar frame was captured
@override final  DateTime timestamp;
/// URL template for map tiles
/// - For XYZ: template with {z}/{x}/{y} tokens
/// - For WMS: base URL (without bbox parameter)
@override final  String tileUrlTemplate;
/// Geographic bounds - northern boundary
@override final  double north;
/// Geographic bounds - southern boundary
@override final  double south;
/// Geographic bounds - eastern boundary
@override final  double east;
/// Geographic bounds - western boundary
@override final  double west;
/// Opacity for animation blending (0.0-1.0)
@override@JsonKey() final  double opacity;
/// Per-cell radar intensity field over the frame's geographic bounds, in
/// row-major order (outer list = rows running NORTH→SOUTH, inner list =
/// columns running WEST→EAST), each value normalised to 0.0–1.0.
///
/// This is the real spatial radar signal decoded from the provider's tiles
/// (the reflectivity colormap mapped to intensity per pixel, downsampled to
/// this grid). When present and non-empty it lets the cloud-motion analyzer
/// track a genuine cloud centroid that MOVES between frames, instead of the
/// single uniform [opacity] box that carries no spatial structure.
///
/// The grid spans exactly [north]..[south] (rows) and [west]..[east]
/// (columns); cell (r, c) covers the geographic sub-rectangle obtained by
/// linearly interpolating those bounds. Null when the provider could not
/// decode per-cell data (e.g. a tile-less WMS layer or a fetch/decode
/// failure) — the analyzer then treats the frame as having no spatial data
/// and reports its honest unavailable reason rather than fabricating motion.
 final  List<List<double>>? _intensityGrid;
/// Per-cell radar intensity field over the frame's geographic bounds, in
/// row-major order (outer list = rows running NORTH→SOUTH, inner list =
/// columns running WEST→EAST), each value normalised to 0.0–1.0.
///
/// This is the real spatial radar signal decoded from the provider's tiles
/// (the reflectivity colormap mapped to intensity per pixel, downsampled to
/// this grid). When present and non-empty it lets the cloud-motion analyzer
/// track a genuine cloud centroid that MOVES between frames, instead of the
/// single uniform [opacity] box that carries no spatial structure.
///
/// The grid spans exactly [north]..[south] (rows) and [west]..[east]
/// (columns); cell (r, c) covers the geographic sub-rectangle obtained by
/// linearly interpolating those bounds. Null when the provider could not
/// decode per-cell data (e.g. a tile-less WMS layer or a fetch/decode
/// failure) — the analyzer then treats the frame as having no spatial data
/// and reports its honest unavailable reason rather than fabricating motion.
@override List<List<double>>? get intensityGrid {
  final value = _intensityGrid;
  if (value == null) return null;
  if (_intensityGrid is EqualUnmodifiableListView) return _intensityGrid;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

/// True when this frame was produced but carries no usable radar signal
/// (the tile fetch or decode failed). Such a frame is emitted — rather than
/// silently dropped — so the analyzer/UI can report an honest "no spatial
/// radar data" state instead of acting on a fabricated uniform field. A
/// no-data frame never contributes density to the analysis.
@override@JsonKey() final  bool isNoData;
/// True if this is a forecast frame vs historical
@override@JsonKey() final  bool isForecast;
/// Type of tile service (XYZ or WMS)
@override@JsonKey() final  RadarTileType tileType;
/// WMS layer name(s) - only used when tileType is wms
@override final  String? wmsLayers;
/// Additional WMS parameters (e.g., time, styles) - only used when tileType is wms
 final  Map<String, String>? _wmsAdditionalOptions;
/// Additional WMS parameters (e.g., time, styles) - only used when tileType is wms
@override Map<String, String>? get wmsAdditionalOptions {
  final value = _wmsAdditionalOptions;
  if (value == null) return null;
  if (_wmsAdditionalOptions is EqualUnmodifiableMapView) return _wmsAdditionalOptions;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(value);
}


/// Create a copy of RadarFrame
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RadarFrameCopyWith<_RadarFrame> get copyWith => __$RadarFrameCopyWithImpl<_RadarFrame>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$RadarFrameToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _RadarFrame&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp)&&(identical(other.tileUrlTemplate, tileUrlTemplate) || other.tileUrlTemplate == tileUrlTemplate)&&(identical(other.north, north) || other.north == north)&&(identical(other.south, south) || other.south == south)&&(identical(other.east, east) || other.east == east)&&(identical(other.west, west) || other.west == west)&&(identical(other.opacity, opacity) || other.opacity == opacity)&&const DeepCollectionEquality().equals(other._intensityGrid, _intensityGrid)&&(identical(other.isNoData, isNoData) || other.isNoData == isNoData)&&(identical(other.isForecast, isForecast) || other.isForecast == isForecast)&&(identical(other.tileType, tileType) || other.tileType == tileType)&&(identical(other.wmsLayers, wmsLayers) || other.wmsLayers == wmsLayers)&&const DeepCollectionEquality().equals(other._wmsAdditionalOptions, _wmsAdditionalOptions));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,timestamp,tileUrlTemplate,north,south,east,west,opacity,const DeepCollectionEquality().hash(_intensityGrid),isNoData,isForecast,tileType,wmsLayers,const DeepCollectionEquality().hash(_wmsAdditionalOptions));

@override
String toString() {
  return 'RadarFrame(timestamp: $timestamp, tileUrlTemplate: $tileUrlTemplate, north: $north, south: $south, east: $east, west: $west, opacity: $opacity, intensityGrid: $intensityGrid, isNoData: $isNoData, isForecast: $isForecast, tileType: $tileType, wmsLayers: $wmsLayers, wmsAdditionalOptions: $wmsAdditionalOptions)';
}


}

/// @nodoc
abstract mixin class _$RadarFrameCopyWith<$Res> implements $RadarFrameCopyWith<$Res> {
  factory _$RadarFrameCopyWith(_RadarFrame value, $Res Function(_RadarFrame) _then) = __$RadarFrameCopyWithImpl;
@override @useResult
$Res call({
 DateTime timestamp, String tileUrlTemplate, double north, double south, double east, double west, double opacity, List<List<double>>? intensityGrid, bool isNoData, bool isForecast, RadarTileType tileType, String? wmsLayers, Map<String, String>? wmsAdditionalOptions
});




}
/// @nodoc
class __$RadarFrameCopyWithImpl<$Res>
    implements _$RadarFrameCopyWith<$Res> {
  __$RadarFrameCopyWithImpl(this._self, this._then);

  final _RadarFrame _self;
  final $Res Function(_RadarFrame) _then;

/// Create a copy of RadarFrame
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? timestamp = null,Object? tileUrlTemplate = null,Object? north = null,Object? south = null,Object? east = null,Object? west = null,Object? opacity = null,Object? intensityGrid = freezed,Object? isNoData = null,Object? isForecast = null,Object? tileType = null,Object? wmsLayers = freezed,Object? wmsAdditionalOptions = freezed,}) {
  return _then(_RadarFrame(
timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as DateTime,tileUrlTemplate: null == tileUrlTemplate ? _self.tileUrlTemplate : tileUrlTemplate // ignore: cast_nullable_to_non_nullable
as String,north: null == north ? _self.north : north // ignore: cast_nullable_to_non_nullable
as double,south: null == south ? _self.south : south // ignore: cast_nullable_to_non_nullable
as double,east: null == east ? _self.east : east // ignore: cast_nullable_to_non_nullable
as double,west: null == west ? _self.west : west // ignore: cast_nullable_to_non_nullable
as double,opacity: null == opacity ? _self.opacity : opacity // ignore: cast_nullable_to_non_nullable
as double,intensityGrid: freezed == intensityGrid ? _self._intensityGrid : intensityGrid // ignore: cast_nullable_to_non_nullable
as List<List<double>>?,isNoData: null == isNoData ? _self.isNoData : isNoData // ignore: cast_nullable_to_non_nullable
as bool,isForecast: null == isForecast ? _self.isForecast : isForecast // ignore: cast_nullable_to_non_nullable
as bool,tileType: null == tileType ? _self.tileType : tileType // ignore: cast_nullable_to_non_nullable
as RadarTileType,wmsLayers: freezed == wmsLayers ? _self.wmsLayers : wmsLayers // ignore: cast_nullable_to_non_nullable
as String?,wmsAdditionalOptions: freezed == wmsAdditionalOptions ? _self._wmsAdditionalOptions : wmsAdditionalOptions // ignore: cast_nullable_to_non_nullable
as Map<String, String>?,
  ));
}


}

// dart format on
