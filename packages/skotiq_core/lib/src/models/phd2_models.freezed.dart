// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'phd2_models.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Phd2StarImage {

/// Frame number
 int get frame;/// Image width in pixels
 int get width;/// Image height in pixels
 int get height;/// Star centroid X position within the subframe
 double get starX;/// Star centroid Y position within the subframe
 double get starY;/// Raw pixel data (16-bit grayscale, row-major order)
/// Note: This is stored as Uint8List but represents 16-bit values
@Uint8ListConverter() Uint8List get pixels;
/// Create a copy of Phd2StarImage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Phd2StarImageCopyWith<Phd2StarImage> get copyWith => _$Phd2StarImageCopyWithImpl<Phd2StarImage>(this as Phd2StarImage, _$identity);

  /// Serializes this Phd2StarImage to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Phd2StarImage&&(identical(other.frame, frame) || other.frame == frame)&&(identical(other.width, width) || other.width == width)&&(identical(other.height, height) || other.height == height)&&(identical(other.starX, starX) || other.starX == starX)&&(identical(other.starY, starY) || other.starY == starY)&&const DeepCollectionEquality().equals(other.pixels, pixels));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,frame,width,height,starX,starY,const DeepCollectionEquality().hash(pixels));

@override
String toString() {
  return 'Phd2StarImage(frame: $frame, width: $width, height: $height, starX: $starX, starY: $starY, pixels: $pixels)';
}


}

/// @nodoc
abstract mixin class $Phd2StarImageCopyWith<$Res>  {
  factory $Phd2StarImageCopyWith(Phd2StarImage value, $Res Function(Phd2StarImage) _then) = _$Phd2StarImageCopyWithImpl;
@useResult
$Res call({
 int frame, int width, int height, double starX, double starY,@Uint8ListConverter() Uint8List pixels
});




}
/// @nodoc
class _$Phd2StarImageCopyWithImpl<$Res>
    implements $Phd2StarImageCopyWith<$Res> {
  _$Phd2StarImageCopyWithImpl(this._self, this._then);

  final Phd2StarImage _self;
  final $Res Function(Phd2StarImage) _then;

/// Create a copy of Phd2StarImage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? frame = null,Object? width = null,Object? height = null,Object? starX = null,Object? starY = null,Object? pixels = null,}) {
  return _then(_self.copyWith(
frame: null == frame ? _self.frame : frame // ignore: cast_nullable_to_non_nullable
as int,width: null == width ? _self.width : width // ignore: cast_nullable_to_non_nullable
as int,height: null == height ? _self.height : height // ignore: cast_nullable_to_non_nullable
as int,starX: null == starX ? _self.starX : starX // ignore: cast_nullable_to_non_nullable
as double,starY: null == starY ? _self.starY : starY // ignore: cast_nullable_to_non_nullable
as double,pixels: null == pixels ? _self.pixels : pixels // ignore: cast_nullable_to_non_nullable
as Uint8List,
  ));
}

}


/// Adds pattern-matching-related methods to [Phd2StarImage].
extension Phd2StarImagePatterns on Phd2StarImage {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Phd2StarImage value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Phd2StarImage() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Phd2StarImage value)  $default,){
final _that = this;
switch (_that) {
case _Phd2StarImage():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Phd2StarImage value)?  $default,){
final _that = this;
switch (_that) {
case _Phd2StarImage() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int frame,  int width,  int height,  double starX,  double starY, @Uint8ListConverter()  Uint8List pixels)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Phd2StarImage() when $default != null:
return $default(_that.frame,_that.width,_that.height,_that.starX,_that.starY,_that.pixels);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int frame,  int width,  int height,  double starX,  double starY, @Uint8ListConverter()  Uint8List pixels)  $default,) {final _that = this;
switch (_that) {
case _Phd2StarImage():
return $default(_that.frame,_that.width,_that.height,_that.starX,_that.starY,_that.pixels);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int frame,  int width,  int height,  double starX,  double starY, @Uint8ListConverter()  Uint8List pixels)?  $default,) {final _that = this;
switch (_that) {
case _Phd2StarImage() when $default != null:
return $default(_that.frame,_that.width,_that.height,_that.starX,_that.starY,_that.pixels);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Phd2StarImage implements Phd2StarImage {
  const _Phd2StarImage({required this.frame, required this.width, required this.height, required this.starX, required this.starY, @Uint8ListConverter() required this.pixels});
  factory _Phd2StarImage.fromJson(Map<String, dynamic> json) => _$Phd2StarImageFromJson(json);

/// Frame number
@override final  int frame;
/// Image width in pixels
@override final  int width;
/// Image height in pixels
@override final  int height;
/// Star centroid X position within the subframe
@override final  double starX;
/// Star centroid Y position within the subframe
@override final  double starY;
/// Raw pixel data (16-bit grayscale, row-major order)
/// Note: This is stored as Uint8List but represents 16-bit values
@override@Uint8ListConverter() final  Uint8List pixels;

/// Create a copy of Phd2StarImage
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$Phd2StarImageCopyWith<_Phd2StarImage> get copyWith => __$Phd2StarImageCopyWithImpl<_Phd2StarImage>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$Phd2StarImageToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Phd2StarImage&&(identical(other.frame, frame) || other.frame == frame)&&(identical(other.width, width) || other.width == width)&&(identical(other.height, height) || other.height == height)&&(identical(other.starX, starX) || other.starX == starX)&&(identical(other.starY, starY) || other.starY == starY)&&const DeepCollectionEquality().equals(other.pixels, pixels));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,frame,width,height,starX,starY,const DeepCollectionEquality().hash(pixels));

@override
String toString() {
  return 'Phd2StarImage(frame: $frame, width: $width, height: $height, starX: $starX, starY: $starY, pixels: $pixels)';
}


}

/// @nodoc
abstract mixin class _$Phd2StarImageCopyWith<$Res> implements $Phd2StarImageCopyWith<$Res> {
  factory _$Phd2StarImageCopyWith(_Phd2StarImage value, $Res Function(_Phd2StarImage) _then) = __$Phd2StarImageCopyWithImpl;
@override @useResult
$Res call({
 int frame, int width, int height, double starX, double starY,@Uint8ListConverter() Uint8List pixels
});




}
/// @nodoc
class __$Phd2StarImageCopyWithImpl<$Res>
    implements _$Phd2StarImageCopyWith<$Res> {
  __$Phd2StarImageCopyWithImpl(this._self, this._then);

  final _Phd2StarImage _self;
  final $Res Function(_Phd2StarImage) _then;

/// Create a copy of Phd2StarImage
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? frame = null,Object? width = null,Object? height = null,Object? starX = null,Object? starY = null,Object? pixels = null,}) {
  return _then(_Phd2StarImage(
frame: null == frame ? _self.frame : frame // ignore: cast_nullable_to_non_nullable
as int,width: null == width ? _self.width : width // ignore: cast_nullable_to_non_nullable
as int,height: null == height ? _self.height : height // ignore: cast_nullable_to_non_nullable
as int,starX: null == starX ? _self.starX : starX // ignore: cast_nullable_to_non_nullable
as double,starY: null == starY ? _self.starY : starY // ignore: cast_nullable_to_non_nullable
as double,pixels: null == pixels ? _self.pixels : pixels // ignore: cast_nullable_to_non_nullable
as Uint8List,
  ));
}


}


/// @nodoc
mixin _$Phd2AlgoParam {

/// Parameter name (e.g., "Aggressiveness", "Hysteresis")
 String get name;/// Parameter value
 double get value;
/// Create a copy of Phd2AlgoParam
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Phd2AlgoParamCopyWith<Phd2AlgoParam> get copyWith => _$Phd2AlgoParamCopyWithImpl<Phd2AlgoParam>(this as Phd2AlgoParam, _$identity);

  /// Serializes this Phd2AlgoParam to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Phd2AlgoParam&&(identical(other.name, name) || other.name == name)&&(identical(other.value, value) || other.value == value));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,name,value);

@override
String toString() {
  return 'Phd2AlgoParam(name: $name, value: $value)';
}


}

/// @nodoc
abstract mixin class $Phd2AlgoParamCopyWith<$Res>  {
  factory $Phd2AlgoParamCopyWith(Phd2AlgoParam value, $Res Function(Phd2AlgoParam) _then) = _$Phd2AlgoParamCopyWithImpl;
@useResult
$Res call({
 String name, double value
});




}
/// @nodoc
class _$Phd2AlgoParamCopyWithImpl<$Res>
    implements $Phd2AlgoParamCopyWith<$Res> {
  _$Phd2AlgoParamCopyWithImpl(this._self, this._then);

  final Phd2AlgoParam _self;
  final $Res Function(Phd2AlgoParam) _then;

/// Create a copy of Phd2AlgoParam
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? name = null,Object? value = null,}) {
  return _then(_self.copyWith(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as double,
  ));
}

}


/// Adds pattern-matching-related methods to [Phd2AlgoParam].
extension Phd2AlgoParamPatterns on Phd2AlgoParam {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Phd2AlgoParam value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Phd2AlgoParam() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Phd2AlgoParam value)  $default,){
final _that = this;
switch (_that) {
case _Phd2AlgoParam():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Phd2AlgoParam value)?  $default,){
final _that = this;
switch (_that) {
case _Phd2AlgoParam() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String name,  double value)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Phd2AlgoParam() when $default != null:
return $default(_that.name,_that.value);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String name,  double value)  $default,) {final _that = this;
switch (_that) {
case _Phd2AlgoParam():
return $default(_that.name,_that.value);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String name,  double value)?  $default,) {final _that = this;
switch (_that) {
case _Phd2AlgoParam() when $default != null:
return $default(_that.name,_that.value);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Phd2AlgoParam implements Phd2AlgoParam {
  const _Phd2AlgoParam({required this.name, required this.value});
  factory _Phd2AlgoParam.fromJson(Map<String, dynamic> json) => _$Phd2AlgoParamFromJson(json);

/// Parameter name (e.g., "Aggressiveness", "Hysteresis")
@override final  String name;
/// Parameter value
@override final  double value;

/// Create a copy of Phd2AlgoParam
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$Phd2AlgoParamCopyWith<_Phd2AlgoParam> get copyWith => __$Phd2AlgoParamCopyWithImpl<_Phd2AlgoParam>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$Phd2AlgoParamToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Phd2AlgoParam&&(identical(other.name, name) || other.name == name)&&(identical(other.value, value) || other.value == value));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,name,value);

@override
String toString() {
  return 'Phd2AlgoParam(name: $name, value: $value)';
}


}

/// @nodoc
abstract mixin class _$Phd2AlgoParamCopyWith<$Res> implements $Phd2AlgoParamCopyWith<$Res> {
  factory _$Phd2AlgoParamCopyWith(_Phd2AlgoParam value, $Res Function(_Phd2AlgoParam) _then) = __$Phd2AlgoParamCopyWithImpl;
@override @useResult
$Res call({
 String name, double value
});




}
/// @nodoc
class __$Phd2AlgoParamCopyWithImpl<$Res>
    implements _$Phd2AlgoParamCopyWith<$Res> {
  __$Phd2AlgoParamCopyWithImpl(this._self, this._then);

  final _Phd2AlgoParam _self;
  final $Res Function(_Phd2AlgoParam) _then;

/// Create a copy of Phd2AlgoParam
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? value = null,}) {
  return _then(_Phd2AlgoParam(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}


/// @nodoc
mixin _$Phd2BrainParams {

/// RA axis parameter names
 List<String> get raParamNames;/// Dec axis parameter names
 List<String> get decParamNames;/// RA axis parameters (name -> value)
 Map<String, double> get raParams;/// Dec axis parameters (name -> value)
 Map<String, double> get decParams;
/// Create a copy of Phd2BrainParams
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Phd2BrainParamsCopyWith<Phd2BrainParams> get copyWith => _$Phd2BrainParamsCopyWithImpl<Phd2BrainParams>(this as Phd2BrainParams, _$identity);

  /// Serializes this Phd2BrainParams to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Phd2BrainParams&&const DeepCollectionEquality().equals(other.raParamNames, raParamNames)&&const DeepCollectionEquality().equals(other.decParamNames, decParamNames)&&const DeepCollectionEquality().equals(other.raParams, raParams)&&const DeepCollectionEquality().equals(other.decParams, decParams));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(raParamNames),const DeepCollectionEquality().hash(decParamNames),const DeepCollectionEquality().hash(raParams),const DeepCollectionEquality().hash(decParams));

@override
String toString() {
  return 'Phd2BrainParams(raParamNames: $raParamNames, decParamNames: $decParamNames, raParams: $raParams, decParams: $decParams)';
}


}

/// @nodoc
abstract mixin class $Phd2BrainParamsCopyWith<$Res>  {
  factory $Phd2BrainParamsCopyWith(Phd2BrainParams value, $Res Function(Phd2BrainParams) _then) = _$Phd2BrainParamsCopyWithImpl;
@useResult
$Res call({
 List<String> raParamNames, List<String> decParamNames, Map<String, double> raParams, Map<String, double> decParams
});




}
/// @nodoc
class _$Phd2BrainParamsCopyWithImpl<$Res>
    implements $Phd2BrainParamsCopyWith<$Res> {
  _$Phd2BrainParamsCopyWithImpl(this._self, this._then);

  final Phd2BrainParams _self;
  final $Res Function(Phd2BrainParams) _then;

/// Create a copy of Phd2BrainParams
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? raParamNames = null,Object? decParamNames = null,Object? raParams = null,Object? decParams = null,}) {
  return _then(_self.copyWith(
raParamNames: null == raParamNames ? _self.raParamNames : raParamNames // ignore: cast_nullable_to_non_nullable
as List<String>,decParamNames: null == decParamNames ? _self.decParamNames : decParamNames // ignore: cast_nullable_to_non_nullable
as List<String>,raParams: null == raParams ? _self.raParams : raParams // ignore: cast_nullable_to_non_nullable
as Map<String, double>,decParams: null == decParams ? _self.decParams : decParams // ignore: cast_nullable_to_non_nullable
as Map<String, double>,
  ));
}

}


/// Adds pattern-matching-related methods to [Phd2BrainParams].
extension Phd2BrainParamsPatterns on Phd2BrainParams {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Phd2BrainParams value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Phd2BrainParams() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Phd2BrainParams value)  $default,){
final _that = this;
switch (_that) {
case _Phd2BrainParams():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Phd2BrainParams value)?  $default,){
final _that = this;
switch (_that) {
case _Phd2BrainParams() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<String> raParamNames,  List<String> decParamNames,  Map<String, double> raParams,  Map<String, double> decParams)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Phd2BrainParams() when $default != null:
return $default(_that.raParamNames,_that.decParamNames,_that.raParams,_that.decParams);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<String> raParamNames,  List<String> decParamNames,  Map<String, double> raParams,  Map<String, double> decParams)  $default,) {final _that = this;
switch (_that) {
case _Phd2BrainParams():
return $default(_that.raParamNames,_that.decParamNames,_that.raParams,_that.decParams);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<String> raParamNames,  List<String> decParamNames,  Map<String, double> raParams,  Map<String, double> decParams)?  $default,) {final _that = this;
switch (_that) {
case _Phd2BrainParams() when $default != null:
return $default(_that.raParamNames,_that.decParamNames,_that.raParams,_that.decParams);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Phd2BrainParams implements Phd2BrainParams {
  const _Phd2BrainParams({required final  List<String> raParamNames, required final  List<String> decParamNames, required final  Map<String, double> raParams, required final  Map<String, double> decParams}): _raParamNames = raParamNames,_decParamNames = decParamNames,_raParams = raParams,_decParams = decParams;
  factory _Phd2BrainParams.fromJson(Map<String, dynamic> json) => _$Phd2BrainParamsFromJson(json);

/// RA axis parameter names
 final  List<String> _raParamNames;
/// RA axis parameter names
@override List<String> get raParamNames {
  if (_raParamNames is EqualUnmodifiableListView) return _raParamNames;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_raParamNames);
}

/// Dec axis parameter names
 final  List<String> _decParamNames;
/// Dec axis parameter names
@override List<String> get decParamNames {
  if (_decParamNames is EqualUnmodifiableListView) return _decParamNames;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_decParamNames);
}

/// RA axis parameters (name -> value)
 final  Map<String, double> _raParams;
/// RA axis parameters (name -> value)
@override Map<String, double> get raParams {
  if (_raParams is EqualUnmodifiableMapView) return _raParams;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_raParams);
}

/// Dec axis parameters (name -> value)
 final  Map<String, double> _decParams;
/// Dec axis parameters (name -> value)
@override Map<String, double> get decParams {
  if (_decParams is EqualUnmodifiableMapView) return _decParams;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_decParams);
}


/// Create a copy of Phd2BrainParams
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$Phd2BrainParamsCopyWith<_Phd2BrainParams> get copyWith => __$Phd2BrainParamsCopyWithImpl<_Phd2BrainParams>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$Phd2BrainParamsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Phd2BrainParams&&const DeepCollectionEquality().equals(other._raParamNames, _raParamNames)&&const DeepCollectionEquality().equals(other._decParamNames, _decParamNames)&&const DeepCollectionEquality().equals(other._raParams, _raParams)&&const DeepCollectionEquality().equals(other._decParams, _decParams));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_raParamNames),const DeepCollectionEquality().hash(_decParamNames),const DeepCollectionEquality().hash(_raParams),const DeepCollectionEquality().hash(_decParams));

@override
String toString() {
  return 'Phd2BrainParams(raParamNames: $raParamNames, decParamNames: $decParamNames, raParams: $raParams, decParams: $decParams)';
}


}

/// @nodoc
abstract mixin class _$Phd2BrainParamsCopyWith<$Res> implements $Phd2BrainParamsCopyWith<$Res> {
  factory _$Phd2BrainParamsCopyWith(_Phd2BrainParams value, $Res Function(_Phd2BrainParams) _then) = __$Phd2BrainParamsCopyWithImpl;
@override @useResult
$Res call({
 List<String> raParamNames, List<String> decParamNames, Map<String, double> raParams, Map<String, double> decParams
});




}
/// @nodoc
class __$Phd2BrainParamsCopyWithImpl<$Res>
    implements _$Phd2BrainParamsCopyWith<$Res> {
  __$Phd2BrainParamsCopyWithImpl(this._self, this._then);

  final _Phd2BrainParams _self;
  final $Res Function(_Phd2BrainParams) _then;

/// Create a copy of Phd2BrainParams
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? raParamNames = null,Object? decParamNames = null,Object? raParams = null,Object? decParams = null,}) {
  return _then(_Phd2BrainParams(
raParamNames: null == raParamNames ? _self._raParamNames : raParamNames // ignore: cast_nullable_to_non_nullable
as List<String>,decParamNames: null == decParamNames ? _self._decParamNames : decParamNames // ignore: cast_nullable_to_non_nullable
as List<String>,raParams: null == raParams ? _self._raParams : raParams // ignore: cast_nullable_to_non_nullable
as Map<String, double>,decParams: null == decParams ? _self._decParams : decParams // ignore: cast_nullable_to_non_nullable
as Map<String, double>,
  ));
}


}


/// @nodoc
mixin _$GuideErrorPoint {

/// RA error (guide-camera pixels; see class docs)
 double get raError;/// Dec error (guide-camera pixels; see class docs)
 double get decError;/// Timestamp when this error was recorded
 DateTime get timestamp;
/// Create a copy of GuideErrorPoint
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$GuideErrorPointCopyWith<GuideErrorPoint> get copyWith => _$GuideErrorPointCopyWithImpl<GuideErrorPoint>(this as GuideErrorPoint, _$identity);

  /// Serializes this GuideErrorPoint to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GuideErrorPoint&&(identical(other.raError, raError) || other.raError == raError)&&(identical(other.decError, decError) || other.decError == decError)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,raError,decError,timestamp);

@override
String toString() {
  return 'GuideErrorPoint(raError: $raError, decError: $decError, timestamp: $timestamp)';
}


}

/// @nodoc
abstract mixin class $GuideErrorPointCopyWith<$Res>  {
  factory $GuideErrorPointCopyWith(GuideErrorPoint value, $Res Function(GuideErrorPoint) _then) = _$GuideErrorPointCopyWithImpl;
@useResult
$Res call({
 double raError, double decError, DateTime timestamp
});




}
/// @nodoc
class _$GuideErrorPointCopyWithImpl<$Res>
    implements $GuideErrorPointCopyWith<$Res> {
  _$GuideErrorPointCopyWithImpl(this._self, this._then);

  final GuideErrorPoint _self;
  final $Res Function(GuideErrorPoint) _then;

/// Create a copy of GuideErrorPoint
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? raError = null,Object? decError = null,Object? timestamp = null,}) {
  return _then(_self.copyWith(
raError: null == raError ? _self.raError : raError // ignore: cast_nullable_to_non_nullable
as double,decError: null == decError ? _self.decError : decError // ignore: cast_nullable_to_non_nullable
as double,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}

}


/// Adds pattern-matching-related methods to [GuideErrorPoint].
extension GuideErrorPointPatterns on GuideErrorPoint {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _GuideErrorPoint value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _GuideErrorPoint() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _GuideErrorPoint value)  $default,){
final _that = this;
switch (_that) {
case _GuideErrorPoint():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _GuideErrorPoint value)?  $default,){
final _that = this;
switch (_that) {
case _GuideErrorPoint() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double raError,  double decError,  DateTime timestamp)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _GuideErrorPoint() when $default != null:
return $default(_that.raError,_that.decError,_that.timestamp);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double raError,  double decError,  DateTime timestamp)  $default,) {final _that = this;
switch (_that) {
case _GuideErrorPoint():
return $default(_that.raError,_that.decError,_that.timestamp);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double raError,  double decError,  DateTime timestamp)?  $default,) {final _that = this;
switch (_that) {
case _GuideErrorPoint() when $default != null:
return $default(_that.raError,_that.decError,_that.timestamp);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _GuideErrorPoint implements GuideErrorPoint {
  const _GuideErrorPoint({required this.raError, required this.decError, required this.timestamp});
  factory _GuideErrorPoint.fromJson(Map<String, dynamic> json) => _$GuideErrorPointFromJson(json);

/// RA error (guide-camera pixels; see class docs)
@override final  double raError;
/// Dec error (guide-camera pixels; see class docs)
@override final  double decError;
/// Timestamp when this error was recorded
@override final  DateTime timestamp;

/// Create a copy of GuideErrorPoint
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$GuideErrorPointCopyWith<_GuideErrorPoint> get copyWith => __$GuideErrorPointCopyWithImpl<_GuideErrorPoint>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$GuideErrorPointToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _GuideErrorPoint&&(identical(other.raError, raError) || other.raError == raError)&&(identical(other.decError, decError) || other.decError == decError)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,raError,decError,timestamp);

@override
String toString() {
  return 'GuideErrorPoint(raError: $raError, decError: $decError, timestamp: $timestamp)';
}


}

/// @nodoc
abstract mixin class _$GuideErrorPointCopyWith<$Res> implements $GuideErrorPointCopyWith<$Res> {
  factory _$GuideErrorPointCopyWith(_GuideErrorPoint value, $Res Function(_GuideErrorPoint) _then) = __$GuideErrorPointCopyWithImpl;
@override @useResult
$Res call({
 double raError, double decError, DateTime timestamp
});




}
/// @nodoc
class __$GuideErrorPointCopyWithImpl<$Res>
    implements _$GuideErrorPointCopyWith<$Res> {
  __$GuideErrorPointCopyWithImpl(this._self, this._then);

  final _GuideErrorPoint _self;
  final $Res Function(_GuideErrorPoint) _then;

/// Create a copy of GuideErrorPoint
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? raError = null,Object? decError = null,Object? timestamp = null,}) {
  return _then(_GuideErrorPoint(
raError: null == raError ? _self.raError : raError // ignore: cast_nullable_to_non_nullable
as double,decError: null == decError ? _self.decError : decError // ignore: cast_nullable_to_non_nullable
as double,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}


}


/// @nodoc
mixin _$Phd2GuideStats {

/// RMS error in RA (guide-camera pixels; see class docs)
 double get rmsRa;/// RMS error in Dec (guide-camera pixels; see class docs)
 double get rmsDec;/// Total RMS error (guide-camera pixels; see class docs)
 double get rmsTotal;/// Peak RA error (guide-camera pixels; see class docs)
 double get peakRa;/// Peak Dec error (guide-camera pixels; see class docs)
 double get peakDec;/// SNR of guide star
 double get snr;/// Star mass (brightness)
 double get starMass;/// HFD (Half Flux Diameter)
 double get hfd;/// Guide star X position
 double get starX;/// Guide star Y position
 double get starY;/// Pixel scale (arcsec/pixel)
 double get pixelScale;/// Number of guide STEPS measured — corrections, not exposures.
///
/// Zero while Loop Exposures is running (looping takes no corrections), so
/// this is also the gate the RMS/Peak readouts use to decide whether they
/// have anything to report. See [loopFrameCount] for the loop's own count.
 int get frameCount;/// Number of frames captured in the CURRENT Loop Exposures run.
///
/// Looping exists so the operator can judge star quality and exposure
/// length before picking a star, and `Frame Count` read `0` for the whole
/// loop because [frameCount] counts guide steps and a loop takes none. A
/// loop frame is not a guide correction, so it gets its own count, and each
/// new loop starts that count again — the number answers "how many frames
/// has THIS loop taken", not "how many since the guider connected".
 int get loopFrameCount;
/// Create a copy of Phd2GuideStats
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Phd2GuideStatsCopyWith<Phd2GuideStats> get copyWith => _$Phd2GuideStatsCopyWithImpl<Phd2GuideStats>(this as Phd2GuideStats, _$identity);

  /// Serializes this Phd2GuideStats to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Phd2GuideStats&&(identical(other.rmsRa, rmsRa) || other.rmsRa == rmsRa)&&(identical(other.rmsDec, rmsDec) || other.rmsDec == rmsDec)&&(identical(other.rmsTotal, rmsTotal) || other.rmsTotal == rmsTotal)&&(identical(other.peakRa, peakRa) || other.peakRa == peakRa)&&(identical(other.peakDec, peakDec) || other.peakDec == peakDec)&&(identical(other.snr, snr) || other.snr == snr)&&(identical(other.starMass, starMass) || other.starMass == starMass)&&(identical(other.hfd, hfd) || other.hfd == hfd)&&(identical(other.starX, starX) || other.starX == starX)&&(identical(other.starY, starY) || other.starY == starY)&&(identical(other.pixelScale, pixelScale) || other.pixelScale == pixelScale)&&(identical(other.frameCount, frameCount) || other.frameCount == frameCount)&&(identical(other.loopFrameCount, loopFrameCount) || other.loopFrameCount == loopFrameCount));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,rmsRa,rmsDec,rmsTotal,peakRa,peakDec,snr,starMass,hfd,starX,starY,pixelScale,frameCount,loopFrameCount);

@override
String toString() {
  return 'Phd2GuideStats(rmsRa: $rmsRa, rmsDec: $rmsDec, rmsTotal: $rmsTotal, peakRa: $peakRa, peakDec: $peakDec, snr: $snr, starMass: $starMass, hfd: $hfd, starX: $starX, starY: $starY, pixelScale: $pixelScale, frameCount: $frameCount, loopFrameCount: $loopFrameCount)';
}


}

/// @nodoc
abstract mixin class $Phd2GuideStatsCopyWith<$Res>  {
  factory $Phd2GuideStatsCopyWith(Phd2GuideStats value, $Res Function(Phd2GuideStats) _then) = _$Phd2GuideStatsCopyWithImpl;
@useResult
$Res call({
 double rmsRa, double rmsDec, double rmsTotal, double peakRa, double peakDec, double snr, double starMass, double hfd, double starX, double starY, double pixelScale, int frameCount, int loopFrameCount
});




}
/// @nodoc
class _$Phd2GuideStatsCopyWithImpl<$Res>
    implements $Phd2GuideStatsCopyWith<$Res> {
  _$Phd2GuideStatsCopyWithImpl(this._self, this._then);

  final Phd2GuideStats _self;
  final $Res Function(Phd2GuideStats) _then;

/// Create a copy of Phd2GuideStats
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? rmsRa = null,Object? rmsDec = null,Object? rmsTotal = null,Object? peakRa = null,Object? peakDec = null,Object? snr = null,Object? starMass = null,Object? hfd = null,Object? starX = null,Object? starY = null,Object? pixelScale = null,Object? frameCount = null,Object? loopFrameCount = null,}) {
  return _then(_self.copyWith(
rmsRa: null == rmsRa ? _self.rmsRa : rmsRa // ignore: cast_nullable_to_non_nullable
as double,rmsDec: null == rmsDec ? _self.rmsDec : rmsDec // ignore: cast_nullable_to_non_nullable
as double,rmsTotal: null == rmsTotal ? _self.rmsTotal : rmsTotal // ignore: cast_nullable_to_non_nullable
as double,peakRa: null == peakRa ? _self.peakRa : peakRa // ignore: cast_nullable_to_non_nullable
as double,peakDec: null == peakDec ? _self.peakDec : peakDec // ignore: cast_nullable_to_non_nullable
as double,snr: null == snr ? _self.snr : snr // ignore: cast_nullable_to_non_nullable
as double,starMass: null == starMass ? _self.starMass : starMass // ignore: cast_nullable_to_non_nullable
as double,hfd: null == hfd ? _self.hfd : hfd // ignore: cast_nullable_to_non_nullable
as double,starX: null == starX ? _self.starX : starX // ignore: cast_nullable_to_non_nullable
as double,starY: null == starY ? _self.starY : starY // ignore: cast_nullable_to_non_nullable
as double,pixelScale: null == pixelScale ? _self.pixelScale : pixelScale // ignore: cast_nullable_to_non_nullable
as double,frameCount: null == frameCount ? _self.frameCount : frameCount // ignore: cast_nullable_to_non_nullable
as int,loopFrameCount: null == loopFrameCount ? _self.loopFrameCount : loopFrameCount // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [Phd2GuideStats].
extension Phd2GuideStatsPatterns on Phd2GuideStats {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Phd2GuideStats value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Phd2GuideStats() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Phd2GuideStats value)  $default,){
final _that = this;
switch (_that) {
case _Phd2GuideStats():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Phd2GuideStats value)?  $default,){
final _that = this;
switch (_that) {
case _Phd2GuideStats() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double rmsRa,  double rmsDec,  double rmsTotal,  double peakRa,  double peakDec,  double snr,  double starMass,  double hfd,  double starX,  double starY,  double pixelScale,  int frameCount,  int loopFrameCount)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Phd2GuideStats() when $default != null:
return $default(_that.rmsRa,_that.rmsDec,_that.rmsTotal,_that.peakRa,_that.peakDec,_that.snr,_that.starMass,_that.hfd,_that.starX,_that.starY,_that.pixelScale,_that.frameCount,_that.loopFrameCount);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double rmsRa,  double rmsDec,  double rmsTotal,  double peakRa,  double peakDec,  double snr,  double starMass,  double hfd,  double starX,  double starY,  double pixelScale,  int frameCount,  int loopFrameCount)  $default,) {final _that = this;
switch (_that) {
case _Phd2GuideStats():
return $default(_that.rmsRa,_that.rmsDec,_that.rmsTotal,_that.peakRa,_that.peakDec,_that.snr,_that.starMass,_that.hfd,_that.starX,_that.starY,_that.pixelScale,_that.frameCount,_that.loopFrameCount);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double rmsRa,  double rmsDec,  double rmsTotal,  double peakRa,  double peakDec,  double snr,  double starMass,  double hfd,  double starX,  double starY,  double pixelScale,  int frameCount,  int loopFrameCount)?  $default,) {final _that = this;
switch (_that) {
case _Phd2GuideStats() when $default != null:
return $default(_that.rmsRa,_that.rmsDec,_that.rmsTotal,_that.peakRa,_that.peakDec,_that.snr,_that.starMass,_that.hfd,_that.starX,_that.starY,_that.pixelScale,_that.frameCount,_that.loopFrameCount);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Phd2GuideStats implements Phd2GuideStats {
  const _Phd2GuideStats({this.rmsRa = 0.0, this.rmsDec = 0.0, this.rmsTotal = 0.0, this.peakRa = 0.0, this.peakDec = 0.0, this.snr = 0.0, this.starMass = 0.0, this.hfd = 0.0, this.starX = 0.0, this.starY = 0.0, this.pixelScale = 0.0, this.frameCount = 0, this.loopFrameCount = 0});
  factory _Phd2GuideStats.fromJson(Map<String, dynamic> json) => _$Phd2GuideStatsFromJson(json);

/// RMS error in RA (guide-camera pixels; see class docs)
@override@JsonKey() final  double rmsRa;
/// RMS error in Dec (guide-camera pixels; see class docs)
@override@JsonKey() final  double rmsDec;
/// Total RMS error (guide-camera pixels; see class docs)
@override@JsonKey() final  double rmsTotal;
/// Peak RA error (guide-camera pixels; see class docs)
@override@JsonKey() final  double peakRa;
/// Peak Dec error (guide-camera pixels; see class docs)
@override@JsonKey() final  double peakDec;
/// SNR of guide star
@override@JsonKey() final  double snr;
/// Star mass (brightness)
@override@JsonKey() final  double starMass;
/// HFD (Half Flux Diameter)
@override@JsonKey() final  double hfd;
/// Guide star X position
@override@JsonKey() final  double starX;
/// Guide star Y position
@override@JsonKey() final  double starY;
/// Pixel scale (arcsec/pixel)
@override@JsonKey() final  double pixelScale;
/// Number of guide STEPS measured — corrections, not exposures.
///
/// Zero while Loop Exposures is running (looping takes no corrections), so
/// this is also the gate the RMS/Peak readouts use to decide whether they
/// have anything to report. See [loopFrameCount] for the loop's own count.
@override@JsonKey() final  int frameCount;
/// Number of frames captured in the CURRENT Loop Exposures run.
///
/// Looping exists so the operator can judge star quality and exposure
/// length before picking a star, and `Frame Count` read `0` for the whole
/// loop because [frameCount] counts guide steps and a loop takes none. A
/// loop frame is not a guide correction, so it gets its own count, and each
/// new loop starts that count again — the number answers "how many frames
/// has THIS loop taken", not "how many since the guider connected".
@override@JsonKey() final  int loopFrameCount;

/// Create a copy of Phd2GuideStats
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$Phd2GuideStatsCopyWith<_Phd2GuideStats> get copyWith => __$Phd2GuideStatsCopyWithImpl<_Phd2GuideStats>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$Phd2GuideStatsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Phd2GuideStats&&(identical(other.rmsRa, rmsRa) || other.rmsRa == rmsRa)&&(identical(other.rmsDec, rmsDec) || other.rmsDec == rmsDec)&&(identical(other.rmsTotal, rmsTotal) || other.rmsTotal == rmsTotal)&&(identical(other.peakRa, peakRa) || other.peakRa == peakRa)&&(identical(other.peakDec, peakDec) || other.peakDec == peakDec)&&(identical(other.snr, snr) || other.snr == snr)&&(identical(other.starMass, starMass) || other.starMass == starMass)&&(identical(other.hfd, hfd) || other.hfd == hfd)&&(identical(other.starX, starX) || other.starX == starX)&&(identical(other.starY, starY) || other.starY == starY)&&(identical(other.pixelScale, pixelScale) || other.pixelScale == pixelScale)&&(identical(other.frameCount, frameCount) || other.frameCount == frameCount)&&(identical(other.loopFrameCount, loopFrameCount) || other.loopFrameCount == loopFrameCount));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,rmsRa,rmsDec,rmsTotal,peakRa,peakDec,snr,starMass,hfd,starX,starY,pixelScale,frameCount,loopFrameCount);

@override
String toString() {
  return 'Phd2GuideStats(rmsRa: $rmsRa, rmsDec: $rmsDec, rmsTotal: $rmsTotal, peakRa: $peakRa, peakDec: $peakDec, snr: $snr, starMass: $starMass, hfd: $hfd, starX: $starX, starY: $starY, pixelScale: $pixelScale, frameCount: $frameCount, loopFrameCount: $loopFrameCount)';
}


}

/// @nodoc
abstract mixin class _$Phd2GuideStatsCopyWith<$Res> implements $Phd2GuideStatsCopyWith<$Res> {
  factory _$Phd2GuideStatsCopyWith(_Phd2GuideStats value, $Res Function(_Phd2GuideStats) _then) = __$Phd2GuideStatsCopyWithImpl;
@override @useResult
$Res call({
 double rmsRa, double rmsDec, double rmsTotal, double peakRa, double peakDec, double snr, double starMass, double hfd, double starX, double starY, double pixelScale, int frameCount, int loopFrameCount
});




}
/// @nodoc
class __$Phd2GuideStatsCopyWithImpl<$Res>
    implements _$Phd2GuideStatsCopyWith<$Res> {
  __$Phd2GuideStatsCopyWithImpl(this._self, this._then);

  final _Phd2GuideStats _self;
  final $Res Function(_Phd2GuideStats) _then;

/// Create a copy of Phd2GuideStats
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? rmsRa = null,Object? rmsDec = null,Object? rmsTotal = null,Object? peakRa = null,Object? peakDec = null,Object? snr = null,Object? starMass = null,Object? hfd = null,Object? starX = null,Object? starY = null,Object? pixelScale = null,Object? frameCount = null,Object? loopFrameCount = null,}) {
  return _then(_Phd2GuideStats(
rmsRa: null == rmsRa ? _self.rmsRa : rmsRa // ignore: cast_nullable_to_non_nullable
as double,rmsDec: null == rmsDec ? _self.rmsDec : rmsDec // ignore: cast_nullable_to_non_nullable
as double,rmsTotal: null == rmsTotal ? _self.rmsTotal : rmsTotal // ignore: cast_nullable_to_non_nullable
as double,peakRa: null == peakRa ? _self.peakRa : peakRa // ignore: cast_nullable_to_non_nullable
as double,peakDec: null == peakDec ? _self.peakDec : peakDec // ignore: cast_nullable_to_non_nullable
as double,snr: null == snr ? _self.snr : snr // ignore: cast_nullable_to_non_nullable
as double,starMass: null == starMass ? _self.starMass : starMass // ignore: cast_nullable_to_non_nullable
as double,hfd: null == hfd ? _self.hfd : hfd // ignore: cast_nullable_to_non_nullable
as double,starX: null == starX ? _self.starX : starX // ignore: cast_nullable_to_non_nullable
as double,starY: null == starY ? _self.starY : starY // ignore: cast_nullable_to_non_nullable
as double,pixelScale: null == pixelScale ? _self.pixelScale : pixelScale // ignore: cast_nullable_to_non_nullable
as double,frameCount: null == frameCount ? _self.frameCount : frameCount // ignore: cast_nullable_to_non_nullable
as int,loopFrameCount: null == loopFrameCount ? _self.loopFrameCount : loopFrameCount // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}


/// @nodoc
mixin _$Phd2CalibrationData {

/// Whether calibration is complete
 bool get isCalibrated;/// Calibration timestamp
 DateTime? get calibratedAt;/// RA calibration rate (pixels/ms)
 double? get raRate;/// Dec calibration rate (pixels/ms)
 double? get decRate;/// Camera rotation angle (degrees)
 double? get rotationAngle;/// Dec guide mode ("Auto", "North", "South", "Off")
 String? get decGuideMode;
/// Create a copy of Phd2CalibrationData
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Phd2CalibrationDataCopyWith<Phd2CalibrationData> get copyWith => _$Phd2CalibrationDataCopyWithImpl<Phd2CalibrationData>(this as Phd2CalibrationData, _$identity);

  /// Serializes this Phd2CalibrationData to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Phd2CalibrationData&&(identical(other.isCalibrated, isCalibrated) || other.isCalibrated == isCalibrated)&&(identical(other.calibratedAt, calibratedAt) || other.calibratedAt == calibratedAt)&&(identical(other.raRate, raRate) || other.raRate == raRate)&&(identical(other.decRate, decRate) || other.decRate == decRate)&&(identical(other.rotationAngle, rotationAngle) || other.rotationAngle == rotationAngle)&&(identical(other.decGuideMode, decGuideMode) || other.decGuideMode == decGuideMode));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,isCalibrated,calibratedAt,raRate,decRate,rotationAngle,decGuideMode);

@override
String toString() {
  return 'Phd2CalibrationData(isCalibrated: $isCalibrated, calibratedAt: $calibratedAt, raRate: $raRate, decRate: $decRate, rotationAngle: $rotationAngle, decGuideMode: $decGuideMode)';
}


}

/// @nodoc
abstract mixin class $Phd2CalibrationDataCopyWith<$Res>  {
  factory $Phd2CalibrationDataCopyWith(Phd2CalibrationData value, $Res Function(Phd2CalibrationData) _then) = _$Phd2CalibrationDataCopyWithImpl;
@useResult
$Res call({
 bool isCalibrated, DateTime? calibratedAt, double? raRate, double? decRate, double? rotationAngle, String? decGuideMode
});




}
/// @nodoc
class _$Phd2CalibrationDataCopyWithImpl<$Res>
    implements $Phd2CalibrationDataCopyWith<$Res> {
  _$Phd2CalibrationDataCopyWithImpl(this._self, this._then);

  final Phd2CalibrationData _self;
  final $Res Function(Phd2CalibrationData) _then;

/// Create a copy of Phd2CalibrationData
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? isCalibrated = null,Object? calibratedAt = freezed,Object? raRate = freezed,Object? decRate = freezed,Object? rotationAngle = freezed,Object? decGuideMode = freezed,}) {
  return _then(_self.copyWith(
isCalibrated: null == isCalibrated ? _self.isCalibrated : isCalibrated // ignore: cast_nullable_to_non_nullable
as bool,calibratedAt: freezed == calibratedAt ? _self.calibratedAt : calibratedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,raRate: freezed == raRate ? _self.raRate : raRate // ignore: cast_nullable_to_non_nullable
as double?,decRate: freezed == decRate ? _self.decRate : decRate // ignore: cast_nullable_to_non_nullable
as double?,rotationAngle: freezed == rotationAngle ? _self.rotationAngle : rotationAngle // ignore: cast_nullable_to_non_nullable
as double?,decGuideMode: freezed == decGuideMode ? _self.decGuideMode : decGuideMode // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [Phd2CalibrationData].
extension Phd2CalibrationDataPatterns on Phd2CalibrationData {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Phd2CalibrationData value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Phd2CalibrationData() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Phd2CalibrationData value)  $default,){
final _that = this;
switch (_that) {
case _Phd2CalibrationData():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Phd2CalibrationData value)?  $default,){
final _that = this;
switch (_that) {
case _Phd2CalibrationData() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool isCalibrated,  DateTime? calibratedAt,  double? raRate,  double? decRate,  double? rotationAngle,  String? decGuideMode)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Phd2CalibrationData() when $default != null:
return $default(_that.isCalibrated,_that.calibratedAt,_that.raRate,_that.decRate,_that.rotationAngle,_that.decGuideMode);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool isCalibrated,  DateTime? calibratedAt,  double? raRate,  double? decRate,  double? rotationAngle,  String? decGuideMode)  $default,) {final _that = this;
switch (_that) {
case _Phd2CalibrationData():
return $default(_that.isCalibrated,_that.calibratedAt,_that.raRate,_that.decRate,_that.rotationAngle,_that.decGuideMode);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool isCalibrated,  DateTime? calibratedAt,  double? raRate,  double? decRate,  double? rotationAngle,  String? decGuideMode)?  $default,) {final _that = this;
switch (_that) {
case _Phd2CalibrationData() when $default != null:
return $default(_that.isCalibrated,_that.calibratedAt,_that.raRate,_that.decRate,_that.rotationAngle,_that.decGuideMode);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Phd2CalibrationData implements Phd2CalibrationData {
  const _Phd2CalibrationData({this.isCalibrated = false, this.calibratedAt, this.raRate, this.decRate, this.rotationAngle, this.decGuideMode});
  factory _Phd2CalibrationData.fromJson(Map<String, dynamic> json) => _$Phd2CalibrationDataFromJson(json);

/// Whether calibration is complete
@override@JsonKey() final  bool isCalibrated;
/// Calibration timestamp
@override final  DateTime? calibratedAt;
/// RA calibration rate (pixels/ms)
@override final  double? raRate;
/// Dec calibration rate (pixels/ms)
@override final  double? decRate;
/// Camera rotation angle (degrees)
@override final  double? rotationAngle;
/// Dec guide mode ("Auto", "North", "South", "Off")
@override final  String? decGuideMode;

/// Create a copy of Phd2CalibrationData
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$Phd2CalibrationDataCopyWith<_Phd2CalibrationData> get copyWith => __$Phd2CalibrationDataCopyWithImpl<_Phd2CalibrationData>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$Phd2CalibrationDataToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Phd2CalibrationData&&(identical(other.isCalibrated, isCalibrated) || other.isCalibrated == isCalibrated)&&(identical(other.calibratedAt, calibratedAt) || other.calibratedAt == calibratedAt)&&(identical(other.raRate, raRate) || other.raRate == raRate)&&(identical(other.decRate, decRate) || other.decRate == decRate)&&(identical(other.rotationAngle, rotationAngle) || other.rotationAngle == rotationAngle)&&(identical(other.decGuideMode, decGuideMode) || other.decGuideMode == decGuideMode));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,isCalibrated,calibratedAt,raRate,decRate,rotationAngle,decGuideMode);

@override
String toString() {
  return 'Phd2CalibrationData(isCalibrated: $isCalibrated, calibratedAt: $calibratedAt, raRate: $raRate, decRate: $decRate, rotationAngle: $rotationAngle, decGuideMode: $decGuideMode)';
}


}

/// @nodoc
abstract mixin class _$Phd2CalibrationDataCopyWith<$Res> implements $Phd2CalibrationDataCopyWith<$Res> {
  factory _$Phd2CalibrationDataCopyWith(_Phd2CalibrationData value, $Res Function(_Phd2CalibrationData) _then) = __$Phd2CalibrationDataCopyWithImpl;
@override @useResult
$Res call({
 bool isCalibrated, DateTime? calibratedAt, double? raRate, double? decRate, double? rotationAngle, String? decGuideMode
});




}
/// @nodoc
class __$Phd2CalibrationDataCopyWithImpl<$Res>
    implements _$Phd2CalibrationDataCopyWith<$Res> {
  __$Phd2CalibrationDataCopyWithImpl(this._self, this._then);

  final _Phd2CalibrationData _self;
  final $Res Function(_Phd2CalibrationData) _then;

/// Create a copy of Phd2CalibrationData
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? isCalibrated = null,Object? calibratedAt = freezed,Object? raRate = freezed,Object? decRate = freezed,Object? rotationAngle = freezed,Object? decGuideMode = freezed,}) {
  return _then(_Phd2CalibrationData(
isCalibrated: null == isCalibrated ? _self.isCalibrated : isCalibrated // ignore: cast_nullable_to_non_nullable
as bool,calibratedAt: freezed == calibratedAt ? _self.calibratedAt : calibratedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,raRate: freezed == raRate ? _self.raRate : raRate // ignore: cast_nullable_to_non_nullable
as double?,decRate: freezed == decRate ? _self.decRate : decRate // ignore: cast_nullable_to_non_nullable
as double?,rotationAngle: freezed == rotationAngle ? _self.rotationAngle : rotationAngle // ignore: cast_nullable_to_non_nullable
as double?,decGuideMode: freezed == decGuideMode ? _self.decGuideMode : decGuideMode // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on
