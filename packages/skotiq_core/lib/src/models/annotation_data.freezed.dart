// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'annotation_data.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ImageAnnotation {

 String get imagePath; DateTime get timestamp; PlateSolveData get plateSolve; List<CelestialObjectAnnotation> get objects; bool get visible;
/// Create a copy of ImageAnnotation
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImageAnnotationCopyWith<ImageAnnotation> get copyWith => _$ImageAnnotationCopyWithImpl<ImageAnnotation>(this as ImageAnnotation, _$identity);

  /// Serializes this ImageAnnotation to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImageAnnotation&&(identical(other.imagePath, imagePath) || other.imagePath == imagePath)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp)&&(identical(other.plateSolve, plateSolve) || other.plateSolve == plateSolve)&&const DeepCollectionEquality().equals(other.objects, objects)&&(identical(other.visible, visible) || other.visible == visible));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,imagePath,timestamp,plateSolve,const DeepCollectionEquality().hash(objects),visible);

@override
String toString() {
  return 'ImageAnnotation(imagePath: $imagePath, timestamp: $timestamp, plateSolve: $plateSolve, objects: $objects, visible: $visible)';
}


}

/// @nodoc
abstract mixin class $ImageAnnotationCopyWith<$Res>  {
  factory $ImageAnnotationCopyWith(ImageAnnotation value, $Res Function(ImageAnnotation) _then) = _$ImageAnnotationCopyWithImpl;
@useResult
$Res call({
 String imagePath, DateTime timestamp, PlateSolveData plateSolve, List<CelestialObjectAnnotation> objects, bool visible
});


$PlateSolveDataCopyWith<$Res> get plateSolve;

}
/// @nodoc
class _$ImageAnnotationCopyWithImpl<$Res>
    implements $ImageAnnotationCopyWith<$Res> {
  _$ImageAnnotationCopyWithImpl(this._self, this._then);

  final ImageAnnotation _self;
  final $Res Function(ImageAnnotation) _then;

/// Create a copy of ImageAnnotation
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? imagePath = null,Object? timestamp = null,Object? plateSolve = null,Object? objects = null,Object? visible = null,}) {
  return _then(_self.copyWith(
imagePath: null == imagePath ? _self.imagePath : imagePath // ignore: cast_nullable_to_non_nullable
as String,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as DateTime,plateSolve: null == plateSolve ? _self.plateSolve : plateSolve // ignore: cast_nullable_to_non_nullable
as PlateSolveData,objects: null == objects ? _self.objects : objects // ignore: cast_nullable_to_non_nullable
as List<CelestialObjectAnnotation>,visible: null == visible ? _self.visible : visible // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}
/// Create a copy of ImageAnnotation
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PlateSolveDataCopyWith<$Res> get plateSolve {
  
  return $PlateSolveDataCopyWith<$Res>(_self.plateSolve, (value) {
    return _then(_self.copyWith(plateSolve: value));
  });
}
}


/// Adds pattern-matching-related methods to [ImageAnnotation].
extension ImageAnnotationPatterns on ImageAnnotation {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ImageAnnotation value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ImageAnnotation() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ImageAnnotation value)  $default,){
final _that = this;
switch (_that) {
case _ImageAnnotation():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ImageAnnotation value)?  $default,){
final _that = this;
switch (_that) {
case _ImageAnnotation() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String imagePath,  DateTime timestamp,  PlateSolveData plateSolve,  List<CelestialObjectAnnotation> objects,  bool visible)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ImageAnnotation() when $default != null:
return $default(_that.imagePath,_that.timestamp,_that.plateSolve,_that.objects,_that.visible);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String imagePath,  DateTime timestamp,  PlateSolveData plateSolve,  List<CelestialObjectAnnotation> objects,  bool visible)  $default,) {final _that = this;
switch (_that) {
case _ImageAnnotation():
return $default(_that.imagePath,_that.timestamp,_that.plateSolve,_that.objects,_that.visible);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String imagePath,  DateTime timestamp,  PlateSolveData plateSolve,  List<CelestialObjectAnnotation> objects,  bool visible)?  $default,) {final _that = this;
switch (_that) {
case _ImageAnnotation() when $default != null:
return $default(_that.imagePath,_that.timestamp,_that.plateSolve,_that.objects,_that.visible);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ImageAnnotation implements ImageAnnotation {
  const _ImageAnnotation({required this.imagePath, required this.timestamp, required this.plateSolve, required final  List<CelestialObjectAnnotation> objects, this.visible = true}): _objects = objects;
  factory _ImageAnnotation.fromJson(Map<String, dynamic> json) => _$ImageAnnotationFromJson(json);

@override final  String imagePath;
@override final  DateTime timestamp;
@override final  PlateSolveData plateSolve;
 final  List<CelestialObjectAnnotation> _objects;
@override List<CelestialObjectAnnotation> get objects {
  if (_objects is EqualUnmodifiableListView) return _objects;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_objects);
}

@override@JsonKey() final  bool visible;

/// Create a copy of ImageAnnotation
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ImageAnnotationCopyWith<_ImageAnnotation> get copyWith => __$ImageAnnotationCopyWithImpl<_ImageAnnotation>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ImageAnnotationToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ImageAnnotation&&(identical(other.imagePath, imagePath) || other.imagePath == imagePath)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp)&&(identical(other.plateSolve, plateSolve) || other.plateSolve == plateSolve)&&const DeepCollectionEquality().equals(other._objects, _objects)&&(identical(other.visible, visible) || other.visible == visible));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,imagePath,timestamp,plateSolve,const DeepCollectionEquality().hash(_objects),visible);

@override
String toString() {
  return 'ImageAnnotation(imagePath: $imagePath, timestamp: $timestamp, plateSolve: $plateSolve, objects: $objects, visible: $visible)';
}


}

/// @nodoc
abstract mixin class _$ImageAnnotationCopyWith<$Res> implements $ImageAnnotationCopyWith<$Res> {
  factory _$ImageAnnotationCopyWith(_ImageAnnotation value, $Res Function(_ImageAnnotation) _then) = __$ImageAnnotationCopyWithImpl;
@override @useResult
$Res call({
 String imagePath, DateTime timestamp, PlateSolveData plateSolve, List<CelestialObjectAnnotation> objects, bool visible
});


@override $PlateSolveDataCopyWith<$Res> get plateSolve;

}
/// @nodoc
class __$ImageAnnotationCopyWithImpl<$Res>
    implements _$ImageAnnotationCopyWith<$Res> {
  __$ImageAnnotationCopyWithImpl(this._self, this._then);

  final _ImageAnnotation _self;
  final $Res Function(_ImageAnnotation) _then;

/// Create a copy of ImageAnnotation
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? imagePath = null,Object? timestamp = null,Object? plateSolve = null,Object? objects = null,Object? visible = null,}) {
  return _then(_ImageAnnotation(
imagePath: null == imagePath ? _self.imagePath : imagePath // ignore: cast_nullable_to_non_nullable
as String,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as DateTime,plateSolve: null == plateSolve ? _self.plateSolve : plateSolve // ignore: cast_nullable_to_non_nullable
as PlateSolveData,objects: null == objects ? _self._objects : objects // ignore: cast_nullable_to_non_nullable
as List<CelestialObjectAnnotation>,visible: null == visible ? _self.visible : visible // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

/// Create a copy of ImageAnnotation
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PlateSolveDataCopyWith<$Res> get plateSolve {
  
  return $PlateSolveDataCopyWith<$Res>(_self.plateSolve, (value) {
    return _then(_self.copyWith(plateSolve: value));
  });
}
}


/// @nodoc
mixin _$PlateSolveData {

 double get ra; double get dec; double get pixelScale;// arcsec/pixel
 double get rotation;// degrees
 double get fieldWidth;// degrees
 double get fieldHeight;// degrees
 int get imageWidth;// pixels
 int get imageHeight;
/// Create a copy of PlateSolveData
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlateSolveDataCopyWith<PlateSolveData> get copyWith => _$PlateSolveDataCopyWithImpl<PlateSolveData>(this as PlateSolveData, _$identity);

  /// Serializes this PlateSolveData to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PlateSolveData&&(identical(other.ra, ra) || other.ra == ra)&&(identical(other.dec, dec) || other.dec == dec)&&(identical(other.pixelScale, pixelScale) || other.pixelScale == pixelScale)&&(identical(other.rotation, rotation) || other.rotation == rotation)&&(identical(other.fieldWidth, fieldWidth) || other.fieldWidth == fieldWidth)&&(identical(other.fieldHeight, fieldHeight) || other.fieldHeight == fieldHeight)&&(identical(other.imageWidth, imageWidth) || other.imageWidth == imageWidth)&&(identical(other.imageHeight, imageHeight) || other.imageHeight == imageHeight));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,ra,dec,pixelScale,rotation,fieldWidth,fieldHeight,imageWidth,imageHeight);

@override
String toString() {
  return 'PlateSolveData(ra: $ra, dec: $dec, pixelScale: $pixelScale, rotation: $rotation, fieldWidth: $fieldWidth, fieldHeight: $fieldHeight, imageWidth: $imageWidth, imageHeight: $imageHeight)';
}


}

/// @nodoc
abstract mixin class $PlateSolveDataCopyWith<$Res>  {
  factory $PlateSolveDataCopyWith(PlateSolveData value, $Res Function(PlateSolveData) _then) = _$PlateSolveDataCopyWithImpl;
@useResult
$Res call({
 double ra, double dec, double pixelScale, double rotation, double fieldWidth, double fieldHeight, int imageWidth, int imageHeight
});




}
/// @nodoc
class _$PlateSolveDataCopyWithImpl<$Res>
    implements $PlateSolveDataCopyWith<$Res> {
  _$PlateSolveDataCopyWithImpl(this._self, this._then);

  final PlateSolveData _self;
  final $Res Function(PlateSolveData) _then;

/// Create a copy of PlateSolveData
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? ra = null,Object? dec = null,Object? pixelScale = null,Object? rotation = null,Object? fieldWidth = null,Object? fieldHeight = null,Object? imageWidth = null,Object? imageHeight = null,}) {
  return _then(_self.copyWith(
ra: null == ra ? _self.ra : ra // ignore: cast_nullable_to_non_nullable
as double,dec: null == dec ? _self.dec : dec // ignore: cast_nullable_to_non_nullable
as double,pixelScale: null == pixelScale ? _self.pixelScale : pixelScale // ignore: cast_nullable_to_non_nullable
as double,rotation: null == rotation ? _self.rotation : rotation // ignore: cast_nullable_to_non_nullable
as double,fieldWidth: null == fieldWidth ? _self.fieldWidth : fieldWidth // ignore: cast_nullable_to_non_nullable
as double,fieldHeight: null == fieldHeight ? _self.fieldHeight : fieldHeight // ignore: cast_nullable_to_non_nullable
as double,imageWidth: null == imageWidth ? _self.imageWidth : imageWidth // ignore: cast_nullable_to_non_nullable
as int,imageHeight: null == imageHeight ? _self.imageHeight : imageHeight // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [PlateSolveData].
extension PlateSolveDataPatterns on PlateSolveData {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PlateSolveData value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PlateSolveData() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PlateSolveData value)  $default,){
final _that = this;
switch (_that) {
case _PlateSolveData():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PlateSolveData value)?  $default,){
final _that = this;
switch (_that) {
case _PlateSolveData() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double ra,  double dec,  double pixelScale,  double rotation,  double fieldWidth,  double fieldHeight,  int imageWidth,  int imageHeight)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PlateSolveData() when $default != null:
return $default(_that.ra,_that.dec,_that.pixelScale,_that.rotation,_that.fieldWidth,_that.fieldHeight,_that.imageWidth,_that.imageHeight);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double ra,  double dec,  double pixelScale,  double rotation,  double fieldWidth,  double fieldHeight,  int imageWidth,  int imageHeight)  $default,) {final _that = this;
switch (_that) {
case _PlateSolveData():
return $default(_that.ra,_that.dec,_that.pixelScale,_that.rotation,_that.fieldWidth,_that.fieldHeight,_that.imageWidth,_that.imageHeight);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double ra,  double dec,  double pixelScale,  double rotation,  double fieldWidth,  double fieldHeight,  int imageWidth,  int imageHeight)?  $default,) {final _that = this;
switch (_that) {
case _PlateSolveData() when $default != null:
return $default(_that.ra,_that.dec,_that.pixelScale,_that.rotation,_that.fieldWidth,_that.fieldHeight,_that.imageWidth,_that.imageHeight);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PlateSolveData implements PlateSolveData {
  const _PlateSolveData({required this.ra, required this.dec, required this.pixelScale, required this.rotation, required this.fieldWidth, required this.fieldHeight, required this.imageWidth, required this.imageHeight});
  factory _PlateSolveData.fromJson(Map<String, dynamic> json) => _$PlateSolveDataFromJson(json);

@override final  double ra;
@override final  double dec;
@override final  double pixelScale;
// arcsec/pixel
@override final  double rotation;
// degrees
@override final  double fieldWidth;
// degrees
@override final  double fieldHeight;
// degrees
@override final  int imageWidth;
// pixels
@override final  int imageHeight;

/// Create a copy of PlateSolveData
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PlateSolveDataCopyWith<_PlateSolveData> get copyWith => __$PlateSolveDataCopyWithImpl<_PlateSolveData>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PlateSolveDataToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PlateSolveData&&(identical(other.ra, ra) || other.ra == ra)&&(identical(other.dec, dec) || other.dec == dec)&&(identical(other.pixelScale, pixelScale) || other.pixelScale == pixelScale)&&(identical(other.rotation, rotation) || other.rotation == rotation)&&(identical(other.fieldWidth, fieldWidth) || other.fieldWidth == fieldWidth)&&(identical(other.fieldHeight, fieldHeight) || other.fieldHeight == fieldHeight)&&(identical(other.imageWidth, imageWidth) || other.imageWidth == imageWidth)&&(identical(other.imageHeight, imageHeight) || other.imageHeight == imageHeight));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,ra,dec,pixelScale,rotation,fieldWidth,fieldHeight,imageWidth,imageHeight);

@override
String toString() {
  return 'PlateSolveData(ra: $ra, dec: $dec, pixelScale: $pixelScale, rotation: $rotation, fieldWidth: $fieldWidth, fieldHeight: $fieldHeight, imageWidth: $imageWidth, imageHeight: $imageHeight)';
}


}

/// @nodoc
abstract mixin class _$PlateSolveDataCopyWith<$Res> implements $PlateSolveDataCopyWith<$Res> {
  factory _$PlateSolveDataCopyWith(_PlateSolveData value, $Res Function(_PlateSolveData) _then) = __$PlateSolveDataCopyWithImpl;
@override @useResult
$Res call({
 double ra, double dec, double pixelScale, double rotation, double fieldWidth, double fieldHeight, int imageWidth, int imageHeight
});




}
/// @nodoc
class __$PlateSolveDataCopyWithImpl<$Res>
    implements _$PlateSolveDataCopyWith<$Res> {
  __$PlateSolveDataCopyWithImpl(this._self, this._then);

  final _PlateSolveData _self;
  final $Res Function(_PlateSolveData) _then;

/// Create a copy of PlateSolveData
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? ra = null,Object? dec = null,Object? pixelScale = null,Object? rotation = null,Object? fieldWidth = null,Object? fieldHeight = null,Object? imageWidth = null,Object? imageHeight = null,}) {
  return _then(_PlateSolveData(
ra: null == ra ? _self.ra : ra // ignore: cast_nullable_to_non_nullable
as double,dec: null == dec ? _self.dec : dec // ignore: cast_nullable_to_non_nullable
as double,pixelScale: null == pixelScale ? _self.pixelScale : pixelScale // ignore: cast_nullable_to_non_nullable
as double,rotation: null == rotation ? _self.rotation : rotation // ignore: cast_nullable_to_non_nullable
as double,fieldWidth: null == fieldWidth ? _self.fieldWidth : fieldWidth // ignore: cast_nullable_to_non_nullable
as double,fieldHeight: null == fieldHeight ? _self.fieldHeight : fieldHeight // ignore: cast_nullable_to_non_nullable
as double,imageWidth: null == imageWidth ? _self.imageWidth : imageWidth // ignore: cast_nullable_to_non_nullable
as int,imageHeight: null == imageHeight ? _self.imageHeight : imageHeight // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}


/// @nodoc
mixin _$CelestialObjectAnnotation {

 String get id; String get name; ObjectType get type; double get ra;// J2000
 double get dec;// J2000
 double get x;// Image pixel X
 double get y;// Image pixel Y
 String? get catalogId;// e.g., "NGC 224", "M 31"
 String? get commonName;// Common name (e.g., "Andromeda Galaxy")
 double? get magnitude; double? get size;// arcminutes
 ObjectData? get detailedData; bool get visible;
/// Create a copy of CelestialObjectAnnotation
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CelestialObjectAnnotationCopyWith<CelestialObjectAnnotation> get copyWith => _$CelestialObjectAnnotationCopyWithImpl<CelestialObjectAnnotation>(this as CelestialObjectAnnotation, _$identity);

  /// Serializes this CelestialObjectAnnotation to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CelestialObjectAnnotation&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.type, type) || other.type == type)&&(identical(other.ra, ra) || other.ra == ra)&&(identical(other.dec, dec) || other.dec == dec)&&(identical(other.x, x) || other.x == x)&&(identical(other.y, y) || other.y == y)&&(identical(other.catalogId, catalogId) || other.catalogId == catalogId)&&(identical(other.commonName, commonName) || other.commonName == commonName)&&(identical(other.magnitude, magnitude) || other.magnitude == magnitude)&&(identical(other.size, size) || other.size == size)&&(identical(other.detailedData, detailedData) || other.detailedData == detailedData)&&(identical(other.visible, visible) || other.visible == visible));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,type,ra,dec,x,y,catalogId,commonName,magnitude,size,detailedData,visible);

@override
String toString() {
  return 'CelestialObjectAnnotation(id: $id, name: $name, type: $type, ra: $ra, dec: $dec, x: $x, y: $y, catalogId: $catalogId, commonName: $commonName, magnitude: $magnitude, size: $size, detailedData: $detailedData, visible: $visible)';
}


}

/// @nodoc
abstract mixin class $CelestialObjectAnnotationCopyWith<$Res>  {
  factory $CelestialObjectAnnotationCopyWith(CelestialObjectAnnotation value, $Res Function(CelestialObjectAnnotation) _then) = _$CelestialObjectAnnotationCopyWithImpl;
@useResult
$Res call({
 String id, String name, ObjectType type, double ra, double dec, double x, double y, String? catalogId, String? commonName, double? magnitude, double? size, ObjectData? detailedData, bool visible
});


$ObjectDataCopyWith<$Res>? get detailedData;

}
/// @nodoc
class _$CelestialObjectAnnotationCopyWithImpl<$Res>
    implements $CelestialObjectAnnotationCopyWith<$Res> {
  _$CelestialObjectAnnotationCopyWithImpl(this._self, this._then);

  final CelestialObjectAnnotation _self;
  final $Res Function(CelestialObjectAnnotation) _then;

/// Create a copy of CelestialObjectAnnotation
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? type = null,Object? ra = null,Object? dec = null,Object? x = null,Object? y = null,Object? catalogId = freezed,Object? commonName = freezed,Object? magnitude = freezed,Object? size = freezed,Object? detailedData = freezed,Object? visible = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as ObjectType,ra: null == ra ? _self.ra : ra // ignore: cast_nullable_to_non_nullable
as double,dec: null == dec ? _self.dec : dec // ignore: cast_nullable_to_non_nullable
as double,x: null == x ? _self.x : x // ignore: cast_nullable_to_non_nullable
as double,y: null == y ? _self.y : y // ignore: cast_nullable_to_non_nullable
as double,catalogId: freezed == catalogId ? _self.catalogId : catalogId // ignore: cast_nullable_to_non_nullable
as String?,commonName: freezed == commonName ? _self.commonName : commonName // ignore: cast_nullable_to_non_nullable
as String?,magnitude: freezed == magnitude ? _self.magnitude : magnitude // ignore: cast_nullable_to_non_nullable
as double?,size: freezed == size ? _self.size : size // ignore: cast_nullable_to_non_nullable
as double?,detailedData: freezed == detailedData ? _self.detailedData : detailedData // ignore: cast_nullable_to_non_nullable
as ObjectData?,visible: null == visible ? _self.visible : visible // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}
/// Create a copy of CelestialObjectAnnotation
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ObjectDataCopyWith<$Res>? get detailedData {
    if (_self.detailedData == null) {
    return null;
  }

  return $ObjectDataCopyWith<$Res>(_self.detailedData!, (value) {
    return _then(_self.copyWith(detailedData: value));
  });
}
}


/// Adds pattern-matching-related methods to [CelestialObjectAnnotation].
extension CelestialObjectAnnotationPatterns on CelestialObjectAnnotation {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _CelestialObjectAnnotation value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _CelestialObjectAnnotation() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _CelestialObjectAnnotation value)  $default,){
final _that = this;
switch (_that) {
case _CelestialObjectAnnotation():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _CelestialObjectAnnotation value)?  $default,){
final _that = this;
switch (_that) {
case _CelestialObjectAnnotation() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  ObjectType type,  double ra,  double dec,  double x,  double y,  String? catalogId,  String? commonName,  double? magnitude,  double? size,  ObjectData? detailedData,  bool visible)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _CelestialObjectAnnotation() when $default != null:
return $default(_that.id,_that.name,_that.type,_that.ra,_that.dec,_that.x,_that.y,_that.catalogId,_that.commonName,_that.magnitude,_that.size,_that.detailedData,_that.visible);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  ObjectType type,  double ra,  double dec,  double x,  double y,  String? catalogId,  String? commonName,  double? magnitude,  double? size,  ObjectData? detailedData,  bool visible)  $default,) {final _that = this;
switch (_that) {
case _CelestialObjectAnnotation():
return $default(_that.id,_that.name,_that.type,_that.ra,_that.dec,_that.x,_that.y,_that.catalogId,_that.commonName,_that.magnitude,_that.size,_that.detailedData,_that.visible);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  ObjectType type,  double ra,  double dec,  double x,  double y,  String? catalogId,  String? commonName,  double? magnitude,  double? size,  ObjectData? detailedData,  bool visible)?  $default,) {final _that = this;
switch (_that) {
case _CelestialObjectAnnotation() when $default != null:
return $default(_that.id,_that.name,_that.type,_that.ra,_that.dec,_that.x,_that.y,_that.catalogId,_that.commonName,_that.magnitude,_that.size,_that.detailedData,_that.visible);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _CelestialObjectAnnotation implements CelestialObjectAnnotation {
  const _CelestialObjectAnnotation({required this.id, required this.name, required this.type, required this.ra, required this.dec, required this.x, required this.y, this.catalogId, this.commonName, this.magnitude, this.size, this.detailedData, this.visible = true});
  factory _CelestialObjectAnnotation.fromJson(Map<String, dynamic> json) => _$CelestialObjectAnnotationFromJson(json);

@override final  String id;
@override final  String name;
@override final  ObjectType type;
@override final  double ra;
// J2000
@override final  double dec;
// J2000
@override final  double x;
// Image pixel X
@override final  double y;
// Image pixel Y
@override final  String? catalogId;
// e.g., "NGC 224", "M 31"
@override final  String? commonName;
// Common name (e.g., "Andromeda Galaxy")
@override final  double? magnitude;
@override final  double? size;
// arcminutes
@override final  ObjectData? detailedData;
@override@JsonKey() final  bool visible;

/// Create a copy of CelestialObjectAnnotation
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$CelestialObjectAnnotationCopyWith<_CelestialObjectAnnotation> get copyWith => __$CelestialObjectAnnotationCopyWithImpl<_CelestialObjectAnnotation>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$CelestialObjectAnnotationToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _CelestialObjectAnnotation&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.type, type) || other.type == type)&&(identical(other.ra, ra) || other.ra == ra)&&(identical(other.dec, dec) || other.dec == dec)&&(identical(other.x, x) || other.x == x)&&(identical(other.y, y) || other.y == y)&&(identical(other.catalogId, catalogId) || other.catalogId == catalogId)&&(identical(other.commonName, commonName) || other.commonName == commonName)&&(identical(other.magnitude, magnitude) || other.magnitude == magnitude)&&(identical(other.size, size) || other.size == size)&&(identical(other.detailedData, detailedData) || other.detailedData == detailedData)&&(identical(other.visible, visible) || other.visible == visible));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,type,ra,dec,x,y,catalogId,commonName,magnitude,size,detailedData,visible);

@override
String toString() {
  return 'CelestialObjectAnnotation(id: $id, name: $name, type: $type, ra: $ra, dec: $dec, x: $x, y: $y, catalogId: $catalogId, commonName: $commonName, magnitude: $magnitude, size: $size, detailedData: $detailedData, visible: $visible)';
}


}

/// @nodoc
abstract mixin class _$CelestialObjectAnnotationCopyWith<$Res> implements $CelestialObjectAnnotationCopyWith<$Res> {
  factory _$CelestialObjectAnnotationCopyWith(_CelestialObjectAnnotation value, $Res Function(_CelestialObjectAnnotation) _then) = __$CelestialObjectAnnotationCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, ObjectType type, double ra, double dec, double x, double y, String? catalogId, String? commonName, double? magnitude, double? size, ObjectData? detailedData, bool visible
});


@override $ObjectDataCopyWith<$Res>? get detailedData;

}
/// @nodoc
class __$CelestialObjectAnnotationCopyWithImpl<$Res>
    implements _$CelestialObjectAnnotationCopyWith<$Res> {
  __$CelestialObjectAnnotationCopyWithImpl(this._self, this._then);

  final _CelestialObjectAnnotation _self;
  final $Res Function(_CelestialObjectAnnotation) _then;

/// Create a copy of CelestialObjectAnnotation
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? type = null,Object? ra = null,Object? dec = null,Object? x = null,Object? y = null,Object? catalogId = freezed,Object? commonName = freezed,Object? magnitude = freezed,Object? size = freezed,Object? detailedData = freezed,Object? visible = null,}) {
  return _then(_CelestialObjectAnnotation(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as ObjectType,ra: null == ra ? _self.ra : ra // ignore: cast_nullable_to_non_nullable
as double,dec: null == dec ? _self.dec : dec // ignore: cast_nullable_to_non_nullable
as double,x: null == x ? _self.x : x // ignore: cast_nullable_to_non_nullable
as double,y: null == y ? _self.y : y // ignore: cast_nullable_to_non_nullable
as double,catalogId: freezed == catalogId ? _self.catalogId : catalogId // ignore: cast_nullable_to_non_nullable
as String?,commonName: freezed == commonName ? _self.commonName : commonName // ignore: cast_nullable_to_non_nullable
as String?,magnitude: freezed == magnitude ? _self.magnitude : magnitude // ignore: cast_nullable_to_non_nullable
as double?,size: freezed == size ? _self.size : size // ignore: cast_nullable_to_non_nullable
as double?,detailedData: freezed == detailedData ? _self.detailedData : detailedData // ignore: cast_nullable_to_non_nullable
as ObjectData?,visible: null == visible ? _self.visible : visible // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

/// Create a copy of CelestialObjectAnnotation
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ObjectDataCopyWith<$Res>? get detailedData {
    if (_self.detailedData == null) {
    return null;
  }

  return $ObjectDataCopyWith<$Res>(_self.detailedData!, (value) {
    return _then(_self.copyWith(detailedData: value));
  });
}
}


/// @nodoc
mixin _$ObjectData {

// Basic info
 String? get description; String? get objectClass;// e.g., "Spiral Galaxy", "Open Cluster"
// Stellar data (for stars)
 SpectralClass? get spectralType; double? get temperature;// Kelvin
 double? get mass;// Solar masses
 double? get radius;// Solar radii
 double? get luminosity;// Solar luminosities
 double? get distance;// parsecs
 double? get parallax;// milliarcseconds
 String? get properMotion;// Exoplanet data
 List<ExoplanetData>? get exoplanets;// DSO data (galaxies, nebulae, clusters)
 double? get surfaceBrightness; double? get redshift; String? get morphology;// External references
 String? get simbadId; String? get wikipediaUrl; Map<String, String>? get catalogIds;// {"NGC": "224", "M": "31"}
// Cache metadata
 DateTime? get lastUpdated; String? get dataSource;
/// Create a copy of ObjectData
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ObjectDataCopyWith<ObjectData> get copyWith => _$ObjectDataCopyWithImpl<ObjectData>(this as ObjectData, _$identity);

  /// Serializes this ObjectData to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ObjectData&&(identical(other.description, description) || other.description == description)&&(identical(other.objectClass, objectClass) || other.objectClass == objectClass)&&(identical(other.spectralType, spectralType) || other.spectralType == spectralType)&&(identical(other.temperature, temperature) || other.temperature == temperature)&&(identical(other.mass, mass) || other.mass == mass)&&(identical(other.radius, radius) || other.radius == radius)&&(identical(other.luminosity, luminosity) || other.luminosity == luminosity)&&(identical(other.distance, distance) || other.distance == distance)&&(identical(other.parallax, parallax) || other.parallax == parallax)&&(identical(other.properMotion, properMotion) || other.properMotion == properMotion)&&const DeepCollectionEquality().equals(other.exoplanets, exoplanets)&&(identical(other.surfaceBrightness, surfaceBrightness) || other.surfaceBrightness == surfaceBrightness)&&(identical(other.redshift, redshift) || other.redshift == redshift)&&(identical(other.morphology, morphology) || other.morphology == morphology)&&(identical(other.simbadId, simbadId) || other.simbadId == simbadId)&&(identical(other.wikipediaUrl, wikipediaUrl) || other.wikipediaUrl == wikipediaUrl)&&const DeepCollectionEquality().equals(other.catalogIds, catalogIds)&&(identical(other.lastUpdated, lastUpdated) || other.lastUpdated == lastUpdated)&&(identical(other.dataSource, dataSource) || other.dataSource == dataSource));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,description,objectClass,spectralType,temperature,mass,radius,luminosity,distance,parallax,properMotion,const DeepCollectionEquality().hash(exoplanets),surfaceBrightness,redshift,morphology,simbadId,wikipediaUrl,const DeepCollectionEquality().hash(catalogIds),lastUpdated,dataSource]);

@override
String toString() {
  return 'ObjectData(description: $description, objectClass: $objectClass, spectralType: $spectralType, temperature: $temperature, mass: $mass, radius: $radius, luminosity: $luminosity, distance: $distance, parallax: $parallax, properMotion: $properMotion, exoplanets: $exoplanets, surfaceBrightness: $surfaceBrightness, redshift: $redshift, morphology: $morphology, simbadId: $simbadId, wikipediaUrl: $wikipediaUrl, catalogIds: $catalogIds, lastUpdated: $lastUpdated, dataSource: $dataSource)';
}


}

/// @nodoc
abstract mixin class $ObjectDataCopyWith<$Res>  {
  factory $ObjectDataCopyWith(ObjectData value, $Res Function(ObjectData) _then) = _$ObjectDataCopyWithImpl;
@useResult
$Res call({
 String? description, String? objectClass, SpectralClass? spectralType, double? temperature, double? mass, double? radius, double? luminosity, double? distance, double? parallax, String? properMotion, List<ExoplanetData>? exoplanets, double? surfaceBrightness, double? redshift, String? morphology, String? simbadId, String? wikipediaUrl, Map<String, String>? catalogIds, DateTime? lastUpdated, String? dataSource
});




}
/// @nodoc
class _$ObjectDataCopyWithImpl<$Res>
    implements $ObjectDataCopyWith<$Res> {
  _$ObjectDataCopyWithImpl(this._self, this._then);

  final ObjectData _self;
  final $Res Function(ObjectData) _then;

/// Create a copy of ObjectData
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? description = freezed,Object? objectClass = freezed,Object? spectralType = freezed,Object? temperature = freezed,Object? mass = freezed,Object? radius = freezed,Object? luminosity = freezed,Object? distance = freezed,Object? parallax = freezed,Object? properMotion = freezed,Object? exoplanets = freezed,Object? surfaceBrightness = freezed,Object? redshift = freezed,Object? morphology = freezed,Object? simbadId = freezed,Object? wikipediaUrl = freezed,Object? catalogIds = freezed,Object? lastUpdated = freezed,Object? dataSource = freezed,}) {
  return _then(_self.copyWith(
description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,objectClass: freezed == objectClass ? _self.objectClass : objectClass // ignore: cast_nullable_to_non_nullable
as String?,spectralType: freezed == spectralType ? _self.spectralType : spectralType // ignore: cast_nullable_to_non_nullable
as SpectralClass?,temperature: freezed == temperature ? _self.temperature : temperature // ignore: cast_nullable_to_non_nullable
as double?,mass: freezed == mass ? _self.mass : mass // ignore: cast_nullable_to_non_nullable
as double?,radius: freezed == radius ? _self.radius : radius // ignore: cast_nullable_to_non_nullable
as double?,luminosity: freezed == luminosity ? _self.luminosity : luminosity // ignore: cast_nullable_to_non_nullable
as double?,distance: freezed == distance ? _self.distance : distance // ignore: cast_nullable_to_non_nullable
as double?,parallax: freezed == parallax ? _self.parallax : parallax // ignore: cast_nullable_to_non_nullable
as double?,properMotion: freezed == properMotion ? _self.properMotion : properMotion // ignore: cast_nullable_to_non_nullable
as String?,exoplanets: freezed == exoplanets ? _self.exoplanets : exoplanets // ignore: cast_nullable_to_non_nullable
as List<ExoplanetData>?,surfaceBrightness: freezed == surfaceBrightness ? _self.surfaceBrightness : surfaceBrightness // ignore: cast_nullable_to_non_nullable
as double?,redshift: freezed == redshift ? _self.redshift : redshift // ignore: cast_nullable_to_non_nullable
as double?,morphology: freezed == morphology ? _self.morphology : morphology // ignore: cast_nullable_to_non_nullable
as String?,simbadId: freezed == simbadId ? _self.simbadId : simbadId // ignore: cast_nullable_to_non_nullable
as String?,wikipediaUrl: freezed == wikipediaUrl ? _self.wikipediaUrl : wikipediaUrl // ignore: cast_nullable_to_non_nullable
as String?,catalogIds: freezed == catalogIds ? _self.catalogIds : catalogIds // ignore: cast_nullable_to_non_nullable
as Map<String, String>?,lastUpdated: freezed == lastUpdated ? _self.lastUpdated : lastUpdated // ignore: cast_nullable_to_non_nullable
as DateTime?,dataSource: freezed == dataSource ? _self.dataSource : dataSource // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [ObjectData].
extension ObjectDataPatterns on ObjectData {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ObjectData value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ObjectData() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ObjectData value)  $default,){
final _that = this;
switch (_that) {
case _ObjectData():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ObjectData value)?  $default,){
final _that = this;
switch (_that) {
case _ObjectData() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? description,  String? objectClass,  SpectralClass? spectralType,  double? temperature,  double? mass,  double? radius,  double? luminosity,  double? distance,  double? parallax,  String? properMotion,  List<ExoplanetData>? exoplanets,  double? surfaceBrightness,  double? redshift,  String? morphology,  String? simbadId,  String? wikipediaUrl,  Map<String, String>? catalogIds,  DateTime? lastUpdated,  String? dataSource)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ObjectData() when $default != null:
return $default(_that.description,_that.objectClass,_that.spectralType,_that.temperature,_that.mass,_that.radius,_that.luminosity,_that.distance,_that.parallax,_that.properMotion,_that.exoplanets,_that.surfaceBrightness,_that.redshift,_that.morphology,_that.simbadId,_that.wikipediaUrl,_that.catalogIds,_that.lastUpdated,_that.dataSource);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? description,  String? objectClass,  SpectralClass? spectralType,  double? temperature,  double? mass,  double? radius,  double? luminosity,  double? distance,  double? parallax,  String? properMotion,  List<ExoplanetData>? exoplanets,  double? surfaceBrightness,  double? redshift,  String? morphology,  String? simbadId,  String? wikipediaUrl,  Map<String, String>? catalogIds,  DateTime? lastUpdated,  String? dataSource)  $default,) {final _that = this;
switch (_that) {
case _ObjectData():
return $default(_that.description,_that.objectClass,_that.spectralType,_that.temperature,_that.mass,_that.radius,_that.luminosity,_that.distance,_that.parallax,_that.properMotion,_that.exoplanets,_that.surfaceBrightness,_that.redshift,_that.morphology,_that.simbadId,_that.wikipediaUrl,_that.catalogIds,_that.lastUpdated,_that.dataSource);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? description,  String? objectClass,  SpectralClass? spectralType,  double? temperature,  double? mass,  double? radius,  double? luminosity,  double? distance,  double? parallax,  String? properMotion,  List<ExoplanetData>? exoplanets,  double? surfaceBrightness,  double? redshift,  String? morphology,  String? simbadId,  String? wikipediaUrl,  Map<String, String>? catalogIds,  DateTime? lastUpdated,  String? dataSource)?  $default,) {final _that = this;
switch (_that) {
case _ObjectData() when $default != null:
return $default(_that.description,_that.objectClass,_that.spectralType,_that.temperature,_that.mass,_that.radius,_that.luminosity,_that.distance,_that.parallax,_that.properMotion,_that.exoplanets,_that.surfaceBrightness,_that.redshift,_that.morphology,_that.simbadId,_that.wikipediaUrl,_that.catalogIds,_that.lastUpdated,_that.dataSource);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ObjectData implements ObjectData {
  const _ObjectData({this.description, this.objectClass, this.spectralType, this.temperature, this.mass, this.radius, this.luminosity, this.distance, this.parallax, this.properMotion, final  List<ExoplanetData>? exoplanets, this.surfaceBrightness, this.redshift, this.morphology, this.simbadId, this.wikipediaUrl, final  Map<String, String>? catalogIds, this.lastUpdated, this.dataSource}): _exoplanets = exoplanets,_catalogIds = catalogIds;
  factory _ObjectData.fromJson(Map<String, dynamic> json) => _$ObjectDataFromJson(json);

// Basic info
@override final  String? description;
@override final  String? objectClass;
// e.g., "Spiral Galaxy", "Open Cluster"
// Stellar data (for stars)
@override final  SpectralClass? spectralType;
@override final  double? temperature;
// Kelvin
@override final  double? mass;
// Solar masses
@override final  double? radius;
// Solar radii
@override final  double? luminosity;
// Solar luminosities
@override final  double? distance;
// parsecs
@override final  double? parallax;
// milliarcseconds
@override final  String? properMotion;
// Exoplanet data
 final  List<ExoplanetData>? _exoplanets;
// Exoplanet data
@override List<ExoplanetData>? get exoplanets {
  final value = _exoplanets;
  if (value == null) return null;
  if (_exoplanets is EqualUnmodifiableListView) return _exoplanets;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

// DSO data (galaxies, nebulae, clusters)
@override final  double? surfaceBrightness;
@override final  double? redshift;
@override final  String? morphology;
// External references
@override final  String? simbadId;
@override final  String? wikipediaUrl;
 final  Map<String, String>? _catalogIds;
@override Map<String, String>? get catalogIds {
  final value = _catalogIds;
  if (value == null) return null;
  if (_catalogIds is EqualUnmodifiableMapView) return _catalogIds;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(value);
}

// {"NGC": "224", "M": "31"}
// Cache metadata
@override final  DateTime? lastUpdated;
@override final  String? dataSource;

/// Create a copy of ObjectData
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ObjectDataCopyWith<_ObjectData> get copyWith => __$ObjectDataCopyWithImpl<_ObjectData>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ObjectDataToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ObjectData&&(identical(other.description, description) || other.description == description)&&(identical(other.objectClass, objectClass) || other.objectClass == objectClass)&&(identical(other.spectralType, spectralType) || other.spectralType == spectralType)&&(identical(other.temperature, temperature) || other.temperature == temperature)&&(identical(other.mass, mass) || other.mass == mass)&&(identical(other.radius, radius) || other.radius == radius)&&(identical(other.luminosity, luminosity) || other.luminosity == luminosity)&&(identical(other.distance, distance) || other.distance == distance)&&(identical(other.parallax, parallax) || other.parallax == parallax)&&(identical(other.properMotion, properMotion) || other.properMotion == properMotion)&&const DeepCollectionEquality().equals(other._exoplanets, _exoplanets)&&(identical(other.surfaceBrightness, surfaceBrightness) || other.surfaceBrightness == surfaceBrightness)&&(identical(other.redshift, redshift) || other.redshift == redshift)&&(identical(other.morphology, morphology) || other.morphology == morphology)&&(identical(other.simbadId, simbadId) || other.simbadId == simbadId)&&(identical(other.wikipediaUrl, wikipediaUrl) || other.wikipediaUrl == wikipediaUrl)&&const DeepCollectionEquality().equals(other._catalogIds, _catalogIds)&&(identical(other.lastUpdated, lastUpdated) || other.lastUpdated == lastUpdated)&&(identical(other.dataSource, dataSource) || other.dataSource == dataSource));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,description,objectClass,spectralType,temperature,mass,radius,luminosity,distance,parallax,properMotion,const DeepCollectionEquality().hash(_exoplanets),surfaceBrightness,redshift,morphology,simbadId,wikipediaUrl,const DeepCollectionEquality().hash(_catalogIds),lastUpdated,dataSource]);

@override
String toString() {
  return 'ObjectData(description: $description, objectClass: $objectClass, spectralType: $spectralType, temperature: $temperature, mass: $mass, radius: $radius, luminosity: $luminosity, distance: $distance, parallax: $parallax, properMotion: $properMotion, exoplanets: $exoplanets, surfaceBrightness: $surfaceBrightness, redshift: $redshift, morphology: $morphology, simbadId: $simbadId, wikipediaUrl: $wikipediaUrl, catalogIds: $catalogIds, lastUpdated: $lastUpdated, dataSource: $dataSource)';
}


}

/// @nodoc
abstract mixin class _$ObjectDataCopyWith<$Res> implements $ObjectDataCopyWith<$Res> {
  factory _$ObjectDataCopyWith(_ObjectData value, $Res Function(_ObjectData) _then) = __$ObjectDataCopyWithImpl;
@override @useResult
$Res call({
 String? description, String? objectClass, SpectralClass? spectralType, double? temperature, double? mass, double? radius, double? luminosity, double? distance, double? parallax, String? properMotion, List<ExoplanetData>? exoplanets, double? surfaceBrightness, double? redshift, String? morphology, String? simbadId, String? wikipediaUrl, Map<String, String>? catalogIds, DateTime? lastUpdated, String? dataSource
});




}
/// @nodoc
class __$ObjectDataCopyWithImpl<$Res>
    implements _$ObjectDataCopyWith<$Res> {
  __$ObjectDataCopyWithImpl(this._self, this._then);

  final _ObjectData _self;
  final $Res Function(_ObjectData) _then;

/// Create a copy of ObjectData
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? description = freezed,Object? objectClass = freezed,Object? spectralType = freezed,Object? temperature = freezed,Object? mass = freezed,Object? radius = freezed,Object? luminosity = freezed,Object? distance = freezed,Object? parallax = freezed,Object? properMotion = freezed,Object? exoplanets = freezed,Object? surfaceBrightness = freezed,Object? redshift = freezed,Object? morphology = freezed,Object? simbadId = freezed,Object? wikipediaUrl = freezed,Object? catalogIds = freezed,Object? lastUpdated = freezed,Object? dataSource = freezed,}) {
  return _then(_ObjectData(
description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,objectClass: freezed == objectClass ? _self.objectClass : objectClass // ignore: cast_nullable_to_non_nullable
as String?,spectralType: freezed == spectralType ? _self.spectralType : spectralType // ignore: cast_nullable_to_non_nullable
as SpectralClass?,temperature: freezed == temperature ? _self.temperature : temperature // ignore: cast_nullable_to_non_nullable
as double?,mass: freezed == mass ? _self.mass : mass // ignore: cast_nullable_to_non_nullable
as double?,radius: freezed == radius ? _self.radius : radius // ignore: cast_nullable_to_non_nullable
as double?,luminosity: freezed == luminosity ? _self.luminosity : luminosity // ignore: cast_nullable_to_non_nullable
as double?,distance: freezed == distance ? _self.distance : distance // ignore: cast_nullable_to_non_nullable
as double?,parallax: freezed == parallax ? _self.parallax : parallax // ignore: cast_nullable_to_non_nullable
as double?,properMotion: freezed == properMotion ? _self.properMotion : properMotion // ignore: cast_nullable_to_non_nullable
as String?,exoplanets: freezed == exoplanets ? _self._exoplanets : exoplanets // ignore: cast_nullable_to_non_nullable
as List<ExoplanetData>?,surfaceBrightness: freezed == surfaceBrightness ? _self.surfaceBrightness : surfaceBrightness // ignore: cast_nullable_to_non_nullable
as double?,redshift: freezed == redshift ? _self.redshift : redshift // ignore: cast_nullable_to_non_nullable
as double?,morphology: freezed == morphology ? _self.morphology : morphology // ignore: cast_nullable_to_non_nullable
as String?,simbadId: freezed == simbadId ? _self.simbadId : simbadId // ignore: cast_nullable_to_non_nullable
as String?,wikipediaUrl: freezed == wikipediaUrl ? _self.wikipediaUrl : wikipediaUrl // ignore: cast_nullable_to_non_nullable
as String?,catalogIds: freezed == catalogIds ? _self._catalogIds : catalogIds // ignore: cast_nullable_to_non_nullable
as Map<String, String>?,lastUpdated: freezed == lastUpdated ? _self.lastUpdated : lastUpdated // ignore: cast_nullable_to_non_nullable
as DateTime?,dataSource: freezed == dataSource ? _self.dataSource : dataSource // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$ExoplanetData {

 String get name; double? get mass;// Jupiter masses
 double? get radius;// Jupiter radii
 double? get orbitalPeriod;// days
 double? get semiMajorAxis;// AU
 double? get eccentricity; String? get discoveryMethod; int? get discoveryYear; double? get equilibriumTemp;
/// Create a copy of ExoplanetData
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ExoplanetDataCopyWith<ExoplanetData> get copyWith => _$ExoplanetDataCopyWithImpl<ExoplanetData>(this as ExoplanetData, _$identity);

  /// Serializes this ExoplanetData to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ExoplanetData&&(identical(other.name, name) || other.name == name)&&(identical(other.mass, mass) || other.mass == mass)&&(identical(other.radius, radius) || other.radius == radius)&&(identical(other.orbitalPeriod, orbitalPeriod) || other.orbitalPeriod == orbitalPeriod)&&(identical(other.semiMajorAxis, semiMajorAxis) || other.semiMajorAxis == semiMajorAxis)&&(identical(other.eccentricity, eccentricity) || other.eccentricity == eccentricity)&&(identical(other.discoveryMethod, discoveryMethod) || other.discoveryMethod == discoveryMethod)&&(identical(other.discoveryYear, discoveryYear) || other.discoveryYear == discoveryYear)&&(identical(other.equilibriumTemp, equilibriumTemp) || other.equilibriumTemp == equilibriumTemp));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,name,mass,radius,orbitalPeriod,semiMajorAxis,eccentricity,discoveryMethod,discoveryYear,equilibriumTemp);

@override
String toString() {
  return 'ExoplanetData(name: $name, mass: $mass, radius: $radius, orbitalPeriod: $orbitalPeriod, semiMajorAxis: $semiMajorAxis, eccentricity: $eccentricity, discoveryMethod: $discoveryMethod, discoveryYear: $discoveryYear, equilibriumTemp: $equilibriumTemp)';
}


}

/// @nodoc
abstract mixin class $ExoplanetDataCopyWith<$Res>  {
  factory $ExoplanetDataCopyWith(ExoplanetData value, $Res Function(ExoplanetData) _then) = _$ExoplanetDataCopyWithImpl;
@useResult
$Res call({
 String name, double? mass, double? radius, double? orbitalPeriod, double? semiMajorAxis, double? eccentricity, String? discoveryMethod, int? discoveryYear, double? equilibriumTemp
});




}
/// @nodoc
class _$ExoplanetDataCopyWithImpl<$Res>
    implements $ExoplanetDataCopyWith<$Res> {
  _$ExoplanetDataCopyWithImpl(this._self, this._then);

  final ExoplanetData _self;
  final $Res Function(ExoplanetData) _then;

/// Create a copy of ExoplanetData
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? name = null,Object? mass = freezed,Object? radius = freezed,Object? orbitalPeriod = freezed,Object? semiMajorAxis = freezed,Object? eccentricity = freezed,Object? discoveryMethod = freezed,Object? discoveryYear = freezed,Object? equilibriumTemp = freezed,}) {
  return _then(_self.copyWith(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,mass: freezed == mass ? _self.mass : mass // ignore: cast_nullable_to_non_nullable
as double?,radius: freezed == radius ? _self.radius : radius // ignore: cast_nullable_to_non_nullable
as double?,orbitalPeriod: freezed == orbitalPeriod ? _self.orbitalPeriod : orbitalPeriod // ignore: cast_nullable_to_non_nullable
as double?,semiMajorAxis: freezed == semiMajorAxis ? _self.semiMajorAxis : semiMajorAxis // ignore: cast_nullable_to_non_nullable
as double?,eccentricity: freezed == eccentricity ? _self.eccentricity : eccentricity // ignore: cast_nullable_to_non_nullable
as double?,discoveryMethod: freezed == discoveryMethod ? _self.discoveryMethod : discoveryMethod // ignore: cast_nullable_to_non_nullable
as String?,discoveryYear: freezed == discoveryYear ? _self.discoveryYear : discoveryYear // ignore: cast_nullable_to_non_nullable
as int?,equilibriumTemp: freezed == equilibriumTemp ? _self.equilibriumTemp : equilibriumTemp // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}

}


/// Adds pattern-matching-related methods to [ExoplanetData].
extension ExoplanetDataPatterns on ExoplanetData {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ExoplanetData value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ExoplanetData() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ExoplanetData value)  $default,){
final _that = this;
switch (_that) {
case _ExoplanetData():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ExoplanetData value)?  $default,){
final _that = this;
switch (_that) {
case _ExoplanetData() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String name,  double? mass,  double? radius,  double? orbitalPeriod,  double? semiMajorAxis,  double? eccentricity,  String? discoveryMethod,  int? discoveryYear,  double? equilibriumTemp)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ExoplanetData() when $default != null:
return $default(_that.name,_that.mass,_that.radius,_that.orbitalPeriod,_that.semiMajorAxis,_that.eccentricity,_that.discoveryMethod,_that.discoveryYear,_that.equilibriumTemp);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String name,  double? mass,  double? radius,  double? orbitalPeriod,  double? semiMajorAxis,  double? eccentricity,  String? discoveryMethod,  int? discoveryYear,  double? equilibriumTemp)  $default,) {final _that = this;
switch (_that) {
case _ExoplanetData():
return $default(_that.name,_that.mass,_that.radius,_that.orbitalPeriod,_that.semiMajorAxis,_that.eccentricity,_that.discoveryMethod,_that.discoveryYear,_that.equilibriumTemp);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String name,  double? mass,  double? radius,  double? orbitalPeriod,  double? semiMajorAxis,  double? eccentricity,  String? discoveryMethod,  int? discoveryYear,  double? equilibriumTemp)?  $default,) {final _that = this;
switch (_that) {
case _ExoplanetData() when $default != null:
return $default(_that.name,_that.mass,_that.radius,_that.orbitalPeriod,_that.semiMajorAxis,_that.eccentricity,_that.discoveryMethod,_that.discoveryYear,_that.equilibriumTemp);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ExoplanetData implements ExoplanetData {
  const _ExoplanetData({required this.name, this.mass, this.radius, this.orbitalPeriod, this.semiMajorAxis, this.eccentricity, this.discoveryMethod, this.discoveryYear, this.equilibriumTemp});
  factory _ExoplanetData.fromJson(Map<String, dynamic> json) => _$ExoplanetDataFromJson(json);

@override final  String name;
@override final  double? mass;
// Jupiter masses
@override final  double? radius;
// Jupiter radii
@override final  double? orbitalPeriod;
// days
@override final  double? semiMajorAxis;
// AU
@override final  double? eccentricity;
@override final  String? discoveryMethod;
@override final  int? discoveryYear;
@override final  double? equilibriumTemp;

/// Create a copy of ExoplanetData
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ExoplanetDataCopyWith<_ExoplanetData> get copyWith => __$ExoplanetDataCopyWithImpl<_ExoplanetData>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ExoplanetDataToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ExoplanetData&&(identical(other.name, name) || other.name == name)&&(identical(other.mass, mass) || other.mass == mass)&&(identical(other.radius, radius) || other.radius == radius)&&(identical(other.orbitalPeriod, orbitalPeriod) || other.orbitalPeriod == orbitalPeriod)&&(identical(other.semiMajorAxis, semiMajorAxis) || other.semiMajorAxis == semiMajorAxis)&&(identical(other.eccentricity, eccentricity) || other.eccentricity == eccentricity)&&(identical(other.discoveryMethod, discoveryMethod) || other.discoveryMethod == discoveryMethod)&&(identical(other.discoveryYear, discoveryYear) || other.discoveryYear == discoveryYear)&&(identical(other.equilibriumTemp, equilibriumTemp) || other.equilibriumTemp == equilibriumTemp));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,name,mass,radius,orbitalPeriod,semiMajorAxis,eccentricity,discoveryMethod,discoveryYear,equilibriumTemp);

@override
String toString() {
  return 'ExoplanetData(name: $name, mass: $mass, radius: $radius, orbitalPeriod: $orbitalPeriod, semiMajorAxis: $semiMajorAxis, eccentricity: $eccentricity, discoveryMethod: $discoveryMethod, discoveryYear: $discoveryYear, equilibriumTemp: $equilibriumTemp)';
}


}

/// @nodoc
abstract mixin class _$ExoplanetDataCopyWith<$Res> implements $ExoplanetDataCopyWith<$Res> {
  factory _$ExoplanetDataCopyWith(_ExoplanetData value, $Res Function(_ExoplanetData) _then) = __$ExoplanetDataCopyWithImpl;
@override @useResult
$Res call({
 String name, double? mass, double? radius, double? orbitalPeriod, double? semiMajorAxis, double? eccentricity, String? discoveryMethod, int? discoveryYear, double? equilibriumTemp
});




}
/// @nodoc
class __$ExoplanetDataCopyWithImpl<$Res>
    implements _$ExoplanetDataCopyWith<$Res> {
  __$ExoplanetDataCopyWithImpl(this._self, this._then);

  final _ExoplanetData _self;
  final $Res Function(_ExoplanetData) _then;

/// Create a copy of ExoplanetData
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? mass = freezed,Object? radius = freezed,Object? orbitalPeriod = freezed,Object? semiMajorAxis = freezed,Object? eccentricity = freezed,Object? discoveryMethod = freezed,Object? discoveryYear = freezed,Object? equilibriumTemp = freezed,}) {
  return _then(_ExoplanetData(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,mass: freezed == mass ? _self.mass : mass // ignore: cast_nullable_to_non_nullable
as double?,radius: freezed == radius ? _self.radius : radius // ignore: cast_nullable_to_non_nullable
as double?,orbitalPeriod: freezed == orbitalPeriod ? _self.orbitalPeriod : orbitalPeriod // ignore: cast_nullable_to_non_nullable
as double?,semiMajorAxis: freezed == semiMajorAxis ? _self.semiMajorAxis : semiMajorAxis // ignore: cast_nullable_to_non_nullable
as double?,eccentricity: freezed == eccentricity ? _self.eccentricity : eccentricity // ignore: cast_nullable_to_non_nullable
as double?,discoveryMethod: freezed == discoveryMethod ? _self.discoveryMethod : discoveryMethod // ignore: cast_nullable_to_non_nullable
as String?,discoveryYear: freezed == discoveryYear ? _self.discoveryYear : discoveryYear // ignore: cast_nullable_to_non_nullable
as int?,equilibriumTemp: freezed == equilibriumTemp ? _self.equilibriumTemp : equilibriumTemp // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}


}

// dart format on
