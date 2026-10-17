// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'update_manifest.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$UpdateFileInfo {

 String get path; int get size; String get sha256;
/// Create a copy of UpdateFileInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UpdateFileInfoCopyWith<UpdateFileInfo> get copyWith => _$UpdateFileInfoCopyWithImpl<UpdateFileInfo>(this as UpdateFileInfo, _$identity);

  /// Serializes this UpdateFileInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UpdateFileInfo&&(identical(other.path, path) || other.path == path)&&(identical(other.size, size) || other.size == size)&&(identical(other.sha256, sha256) || other.sha256 == sha256));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,path,size,sha256);

@override
String toString() {
  return 'UpdateFileInfo(path: $path, size: $size, sha256: $sha256)';
}


}

/// @nodoc
abstract mixin class $UpdateFileInfoCopyWith<$Res>  {
  factory $UpdateFileInfoCopyWith(UpdateFileInfo value, $Res Function(UpdateFileInfo) _then) = _$UpdateFileInfoCopyWithImpl;
@useResult
$Res call({
 String path, int size, String sha256
});




}
/// @nodoc
class _$UpdateFileInfoCopyWithImpl<$Res>
    implements $UpdateFileInfoCopyWith<$Res> {
  _$UpdateFileInfoCopyWithImpl(this._self, this._then);

  final UpdateFileInfo _self;
  final $Res Function(UpdateFileInfo) _then;

/// Create a copy of UpdateFileInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? path = null,Object? size = null,Object? sha256 = null,}) {
  return _then(_self.copyWith(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,size: null == size ? _self.size : size // ignore: cast_nullable_to_non_nullable
as int,sha256: null == sha256 ? _self.sha256 : sha256 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [UpdateFileInfo].
extension UpdateFileInfoPatterns on UpdateFileInfo {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _UpdateFileInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _UpdateFileInfo() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _UpdateFileInfo value)  $default,){
final _that = this;
switch (_that) {
case _UpdateFileInfo():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _UpdateFileInfo value)?  $default,){
final _that = this;
switch (_that) {
case _UpdateFileInfo() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String path,  int size,  String sha256)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _UpdateFileInfo() when $default != null:
return $default(_that.path,_that.size,_that.sha256);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String path,  int size,  String sha256)  $default,) {final _that = this;
switch (_that) {
case _UpdateFileInfo():
return $default(_that.path,_that.size,_that.sha256);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String path,  int size,  String sha256)?  $default,) {final _that = this;
switch (_that) {
case _UpdateFileInfo() when $default != null:
return $default(_that.path,_that.size,_that.sha256);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _UpdateFileInfo implements UpdateFileInfo {
  const _UpdateFileInfo({required this.path, required this.size, required this.sha256});
  factory _UpdateFileInfo.fromJson(Map<String, dynamic> json) => _$UpdateFileInfoFromJson(json);

@override final  String path;
@override final  int size;
@override final  String sha256;

/// Create a copy of UpdateFileInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$UpdateFileInfoCopyWith<_UpdateFileInfo> get copyWith => __$UpdateFileInfoCopyWithImpl<_UpdateFileInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$UpdateFileInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _UpdateFileInfo&&(identical(other.path, path) || other.path == path)&&(identical(other.size, size) || other.size == size)&&(identical(other.sha256, sha256) || other.sha256 == sha256));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,path,size,sha256);

@override
String toString() {
  return 'UpdateFileInfo(path: $path, size: $size, sha256: $sha256)';
}


}

/// @nodoc
abstract mixin class _$UpdateFileInfoCopyWith<$Res> implements $UpdateFileInfoCopyWith<$Res> {
  factory _$UpdateFileInfoCopyWith(_UpdateFileInfo value, $Res Function(_UpdateFileInfo) _then) = __$UpdateFileInfoCopyWithImpl;
@override @useResult
$Res call({
 String path, int size, String sha256
});




}
/// @nodoc
class __$UpdateFileInfoCopyWithImpl<$Res>
    implements _$UpdateFileInfoCopyWith<$Res> {
  __$UpdateFileInfoCopyWithImpl(this._self, this._then);

  final _UpdateFileInfo _self;
  final $Res Function(_UpdateFileInfo) _then;

/// Create a copy of UpdateFileInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? path = null,Object? size = null,Object? sha256 = null,}) {
  return _then(_UpdateFileInfo(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,size: null == size ? _self.size : size // ignore: cast_nullable_to_non_nullable
as int,sha256: null == sha256 ? _self.sha256 : sha256 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}


/// @nodoc
mixin _$UpdateManifest {

/// Version string (e.g., "2.1.0")
 String get version;/// Build number for ordering
 int get buildNumber;/// Release date
 DateTime get releaseDate;/// Target platform (windows, macos, linux)
 String get platform;/// Architecture (x64, arm64)
 String get arch;/// Minimum version required to update from
 String? get minVersion;/// Map of file path to file info
 Map<String, UpdateFileInfo> get files;/// Total uncompressed size in bytes
 int get totalSize;/// Compressed package size in bytes
 int get compressedSize;/// SHA-256 hash of the downloaded package archive
 String? get packageSha256;/// Download URL for the update package
 String get downloadUrl;/// Release notes (markdown)
 String? get releaseNotes;/// Ed25519 signature for the canonical manifest payload
 String? get signature;
/// Create a copy of UpdateManifest
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UpdateManifestCopyWith<UpdateManifest> get copyWith => _$UpdateManifestCopyWithImpl<UpdateManifest>(this as UpdateManifest, _$identity);

  /// Serializes this UpdateManifest to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UpdateManifest&&(identical(other.version, version) || other.version == version)&&(identical(other.buildNumber, buildNumber) || other.buildNumber == buildNumber)&&(identical(other.releaseDate, releaseDate) || other.releaseDate == releaseDate)&&(identical(other.platform, platform) || other.platform == platform)&&(identical(other.arch, arch) || other.arch == arch)&&(identical(other.minVersion, minVersion) || other.minVersion == minVersion)&&const DeepCollectionEquality().equals(other.files, files)&&(identical(other.totalSize, totalSize) || other.totalSize == totalSize)&&(identical(other.compressedSize, compressedSize) || other.compressedSize == compressedSize)&&(identical(other.packageSha256, packageSha256) || other.packageSha256 == packageSha256)&&(identical(other.downloadUrl, downloadUrl) || other.downloadUrl == downloadUrl)&&(identical(other.releaseNotes, releaseNotes) || other.releaseNotes == releaseNotes)&&(identical(other.signature, signature) || other.signature == signature));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,version,buildNumber,releaseDate,platform,arch,minVersion,const DeepCollectionEquality().hash(files),totalSize,compressedSize,packageSha256,downloadUrl,releaseNotes,signature);

@override
String toString() {
  return 'UpdateManifest(version: $version, buildNumber: $buildNumber, releaseDate: $releaseDate, platform: $platform, arch: $arch, minVersion: $minVersion, files: $files, totalSize: $totalSize, compressedSize: $compressedSize, packageSha256: $packageSha256, downloadUrl: $downloadUrl, releaseNotes: $releaseNotes, signature: $signature)';
}


}

/// @nodoc
abstract mixin class $UpdateManifestCopyWith<$Res>  {
  factory $UpdateManifestCopyWith(UpdateManifest value, $Res Function(UpdateManifest) _then) = _$UpdateManifestCopyWithImpl;
@useResult
$Res call({
 String version, int buildNumber, DateTime releaseDate, String platform, String arch, String? minVersion, Map<String, UpdateFileInfo> files, int totalSize, int compressedSize, String? packageSha256, String downloadUrl, String? releaseNotes, String? signature
});




}
/// @nodoc
class _$UpdateManifestCopyWithImpl<$Res>
    implements $UpdateManifestCopyWith<$Res> {
  _$UpdateManifestCopyWithImpl(this._self, this._then);

  final UpdateManifest _self;
  final $Res Function(UpdateManifest) _then;

/// Create a copy of UpdateManifest
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? version = null,Object? buildNumber = null,Object? releaseDate = null,Object? platform = null,Object? arch = null,Object? minVersion = freezed,Object? files = null,Object? totalSize = null,Object? compressedSize = null,Object? packageSha256 = freezed,Object? downloadUrl = null,Object? releaseNotes = freezed,Object? signature = freezed,}) {
  return _then(_self.copyWith(
version: null == version ? _self.version : version // ignore: cast_nullable_to_non_nullable
as String,buildNumber: null == buildNumber ? _self.buildNumber : buildNumber // ignore: cast_nullable_to_non_nullable
as int,releaseDate: null == releaseDate ? _self.releaseDate : releaseDate // ignore: cast_nullable_to_non_nullable
as DateTime,platform: null == platform ? _self.platform : platform // ignore: cast_nullable_to_non_nullable
as String,arch: null == arch ? _self.arch : arch // ignore: cast_nullable_to_non_nullable
as String,minVersion: freezed == minVersion ? _self.minVersion : minVersion // ignore: cast_nullable_to_non_nullable
as String?,files: null == files ? _self.files : files // ignore: cast_nullable_to_non_nullable
as Map<String, UpdateFileInfo>,totalSize: null == totalSize ? _self.totalSize : totalSize // ignore: cast_nullable_to_non_nullable
as int,compressedSize: null == compressedSize ? _self.compressedSize : compressedSize // ignore: cast_nullable_to_non_nullable
as int,packageSha256: freezed == packageSha256 ? _self.packageSha256 : packageSha256 // ignore: cast_nullable_to_non_nullable
as String?,downloadUrl: null == downloadUrl ? _self.downloadUrl : downloadUrl // ignore: cast_nullable_to_non_nullable
as String,releaseNotes: freezed == releaseNotes ? _self.releaseNotes : releaseNotes // ignore: cast_nullable_to_non_nullable
as String?,signature: freezed == signature ? _self.signature : signature // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [UpdateManifest].
extension UpdateManifestPatterns on UpdateManifest {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _UpdateManifest value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _UpdateManifest() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _UpdateManifest value)  $default,){
final _that = this;
switch (_that) {
case _UpdateManifest():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _UpdateManifest value)?  $default,){
final _that = this;
switch (_that) {
case _UpdateManifest() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String version,  int buildNumber,  DateTime releaseDate,  String platform,  String arch,  String? minVersion,  Map<String, UpdateFileInfo> files,  int totalSize,  int compressedSize,  String? packageSha256,  String downloadUrl,  String? releaseNotes,  String? signature)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _UpdateManifest() when $default != null:
return $default(_that.version,_that.buildNumber,_that.releaseDate,_that.platform,_that.arch,_that.minVersion,_that.files,_that.totalSize,_that.compressedSize,_that.packageSha256,_that.downloadUrl,_that.releaseNotes,_that.signature);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String version,  int buildNumber,  DateTime releaseDate,  String platform,  String arch,  String? minVersion,  Map<String, UpdateFileInfo> files,  int totalSize,  int compressedSize,  String? packageSha256,  String downloadUrl,  String? releaseNotes,  String? signature)  $default,) {final _that = this;
switch (_that) {
case _UpdateManifest():
return $default(_that.version,_that.buildNumber,_that.releaseDate,_that.platform,_that.arch,_that.minVersion,_that.files,_that.totalSize,_that.compressedSize,_that.packageSha256,_that.downloadUrl,_that.releaseNotes,_that.signature);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String version,  int buildNumber,  DateTime releaseDate,  String platform,  String arch,  String? minVersion,  Map<String, UpdateFileInfo> files,  int totalSize,  int compressedSize,  String? packageSha256,  String downloadUrl,  String? releaseNotes,  String? signature)?  $default,) {final _that = this;
switch (_that) {
case _UpdateManifest() when $default != null:
return $default(_that.version,_that.buildNumber,_that.releaseDate,_that.platform,_that.arch,_that.minVersion,_that.files,_that.totalSize,_that.compressedSize,_that.packageSha256,_that.downloadUrl,_that.releaseNotes,_that.signature);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _UpdateManifest extends UpdateManifest {
  const _UpdateManifest({required this.version, required this.buildNumber, required this.releaseDate, required this.platform, required this.arch, this.minVersion, required final  Map<String, UpdateFileInfo> files, required this.totalSize, required this.compressedSize, this.packageSha256, required this.downloadUrl, this.releaseNotes, this.signature}): _files = files,super._();
  factory _UpdateManifest.fromJson(Map<String, dynamic> json) => _$UpdateManifestFromJson(json);

/// Version string (e.g., "2.1.0")
@override final  String version;
/// Build number for ordering
@override final  int buildNumber;
/// Release date
@override final  DateTime releaseDate;
/// Target platform (windows, macos, linux)
@override final  String platform;
/// Architecture (x64, arm64)
@override final  String arch;
/// Minimum version required to update from
@override final  String? minVersion;
/// Map of file path to file info
 final  Map<String, UpdateFileInfo> _files;
/// Map of file path to file info
@override Map<String, UpdateFileInfo> get files {
  if (_files is EqualUnmodifiableMapView) return _files;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_files);
}

/// Total uncompressed size in bytes
@override final  int totalSize;
/// Compressed package size in bytes
@override final  int compressedSize;
/// SHA-256 hash of the downloaded package archive
@override final  String? packageSha256;
/// Download URL for the update package
@override final  String downloadUrl;
/// Release notes (markdown)
@override final  String? releaseNotes;
/// Ed25519 signature for the canonical manifest payload
@override final  String? signature;

/// Create a copy of UpdateManifest
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$UpdateManifestCopyWith<_UpdateManifest> get copyWith => __$UpdateManifestCopyWithImpl<_UpdateManifest>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$UpdateManifestToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _UpdateManifest&&(identical(other.version, version) || other.version == version)&&(identical(other.buildNumber, buildNumber) || other.buildNumber == buildNumber)&&(identical(other.releaseDate, releaseDate) || other.releaseDate == releaseDate)&&(identical(other.platform, platform) || other.platform == platform)&&(identical(other.arch, arch) || other.arch == arch)&&(identical(other.minVersion, minVersion) || other.minVersion == minVersion)&&const DeepCollectionEquality().equals(other._files, _files)&&(identical(other.totalSize, totalSize) || other.totalSize == totalSize)&&(identical(other.compressedSize, compressedSize) || other.compressedSize == compressedSize)&&(identical(other.packageSha256, packageSha256) || other.packageSha256 == packageSha256)&&(identical(other.downloadUrl, downloadUrl) || other.downloadUrl == downloadUrl)&&(identical(other.releaseNotes, releaseNotes) || other.releaseNotes == releaseNotes)&&(identical(other.signature, signature) || other.signature == signature));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,version,buildNumber,releaseDate,platform,arch,minVersion,const DeepCollectionEquality().hash(_files),totalSize,compressedSize,packageSha256,downloadUrl,releaseNotes,signature);

@override
String toString() {
  return 'UpdateManifest(version: $version, buildNumber: $buildNumber, releaseDate: $releaseDate, platform: $platform, arch: $arch, minVersion: $minVersion, files: $files, totalSize: $totalSize, compressedSize: $compressedSize, packageSha256: $packageSha256, downloadUrl: $downloadUrl, releaseNotes: $releaseNotes, signature: $signature)';
}


}

/// @nodoc
abstract mixin class _$UpdateManifestCopyWith<$Res> implements $UpdateManifestCopyWith<$Res> {
  factory _$UpdateManifestCopyWith(_UpdateManifest value, $Res Function(_UpdateManifest) _then) = __$UpdateManifestCopyWithImpl;
@override @useResult
$Res call({
 String version, int buildNumber, DateTime releaseDate, String platform, String arch, String? minVersion, Map<String, UpdateFileInfo> files, int totalSize, int compressedSize, String? packageSha256, String downloadUrl, String? releaseNotes, String? signature
});




}
/// @nodoc
class __$UpdateManifestCopyWithImpl<$Res>
    implements _$UpdateManifestCopyWith<$Res> {
  __$UpdateManifestCopyWithImpl(this._self, this._then);

  final _UpdateManifest _self;
  final $Res Function(_UpdateManifest) _then;

/// Create a copy of UpdateManifest
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? version = null,Object? buildNumber = null,Object? releaseDate = null,Object? platform = null,Object? arch = null,Object? minVersion = freezed,Object? files = null,Object? totalSize = null,Object? compressedSize = null,Object? packageSha256 = freezed,Object? downloadUrl = null,Object? releaseNotes = freezed,Object? signature = freezed,}) {
  return _then(_UpdateManifest(
version: null == version ? _self.version : version // ignore: cast_nullable_to_non_nullable
as String,buildNumber: null == buildNumber ? _self.buildNumber : buildNumber // ignore: cast_nullable_to_non_nullable
as int,releaseDate: null == releaseDate ? _self.releaseDate : releaseDate // ignore: cast_nullable_to_non_nullable
as DateTime,platform: null == platform ? _self.platform : platform // ignore: cast_nullable_to_non_nullable
as String,arch: null == arch ? _self.arch : arch // ignore: cast_nullable_to_non_nullable
as String,minVersion: freezed == minVersion ? _self.minVersion : minVersion // ignore: cast_nullable_to_non_nullable
as String?,files: null == files ? _self._files : files // ignore: cast_nullable_to_non_nullable
as Map<String, UpdateFileInfo>,totalSize: null == totalSize ? _self.totalSize : totalSize // ignore: cast_nullable_to_non_nullable
as int,compressedSize: null == compressedSize ? _self.compressedSize : compressedSize // ignore: cast_nullable_to_non_nullable
as int,packageSha256: freezed == packageSha256 ? _self.packageSha256 : packageSha256 // ignore: cast_nullable_to_non_nullable
as String?,downloadUrl: null == downloadUrl ? _self.downloadUrl : downloadUrl // ignore: cast_nullable_to_non_nullable
as String,releaseNotes: freezed == releaseNotes ? _self.releaseNotes : releaseNotes // ignore: cast_nullable_to_non_nullable
as String?,signature: freezed == signature ? _self.signature : signature // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$VersionInfo {

/// Latest stable version
 String get latestVersion;/// Latest build number
 int get latestBuildNumber;/// Available channels
 Map<String, ChannelInfo> get channels;/// Minimum supported version (older versions must update)
 String? get minSupportedVersion;/// Server version for compatibility checks
 String? get serverVersion;
/// Create a copy of VersionInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$VersionInfoCopyWith<VersionInfo> get copyWith => _$VersionInfoCopyWithImpl<VersionInfo>(this as VersionInfo, _$identity);

  /// Serializes this VersionInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is VersionInfo&&(identical(other.latestVersion, latestVersion) || other.latestVersion == latestVersion)&&(identical(other.latestBuildNumber, latestBuildNumber) || other.latestBuildNumber == latestBuildNumber)&&const DeepCollectionEquality().equals(other.channels, channels)&&(identical(other.minSupportedVersion, minSupportedVersion) || other.minSupportedVersion == minSupportedVersion)&&(identical(other.serverVersion, serverVersion) || other.serverVersion == serverVersion));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,latestVersion,latestBuildNumber,const DeepCollectionEquality().hash(channels),minSupportedVersion,serverVersion);

@override
String toString() {
  return 'VersionInfo(latestVersion: $latestVersion, latestBuildNumber: $latestBuildNumber, channels: $channels, minSupportedVersion: $minSupportedVersion, serverVersion: $serverVersion)';
}


}

/// @nodoc
abstract mixin class $VersionInfoCopyWith<$Res>  {
  factory $VersionInfoCopyWith(VersionInfo value, $Res Function(VersionInfo) _then) = _$VersionInfoCopyWithImpl;
@useResult
$Res call({
 String latestVersion, int latestBuildNumber, Map<String, ChannelInfo> channels, String? minSupportedVersion, String? serverVersion
});




}
/// @nodoc
class _$VersionInfoCopyWithImpl<$Res>
    implements $VersionInfoCopyWith<$Res> {
  _$VersionInfoCopyWithImpl(this._self, this._then);

  final VersionInfo _self;
  final $Res Function(VersionInfo) _then;

/// Create a copy of VersionInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? latestVersion = null,Object? latestBuildNumber = null,Object? channels = null,Object? minSupportedVersion = freezed,Object? serverVersion = freezed,}) {
  return _then(_self.copyWith(
latestVersion: null == latestVersion ? _self.latestVersion : latestVersion // ignore: cast_nullable_to_non_nullable
as String,latestBuildNumber: null == latestBuildNumber ? _self.latestBuildNumber : latestBuildNumber // ignore: cast_nullable_to_non_nullable
as int,channels: null == channels ? _self.channels : channels // ignore: cast_nullable_to_non_nullable
as Map<String, ChannelInfo>,minSupportedVersion: freezed == minSupportedVersion ? _self.minSupportedVersion : minSupportedVersion // ignore: cast_nullable_to_non_nullable
as String?,serverVersion: freezed == serverVersion ? _self.serverVersion : serverVersion // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [VersionInfo].
extension VersionInfoPatterns on VersionInfo {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _VersionInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _VersionInfo() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _VersionInfo value)  $default,){
final _that = this;
switch (_that) {
case _VersionInfo():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _VersionInfo value)?  $default,){
final _that = this;
switch (_that) {
case _VersionInfo() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String latestVersion,  int latestBuildNumber,  Map<String, ChannelInfo> channels,  String? minSupportedVersion,  String? serverVersion)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _VersionInfo() when $default != null:
return $default(_that.latestVersion,_that.latestBuildNumber,_that.channels,_that.minSupportedVersion,_that.serverVersion);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String latestVersion,  int latestBuildNumber,  Map<String, ChannelInfo> channels,  String? minSupportedVersion,  String? serverVersion)  $default,) {final _that = this;
switch (_that) {
case _VersionInfo():
return $default(_that.latestVersion,_that.latestBuildNumber,_that.channels,_that.minSupportedVersion,_that.serverVersion);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String latestVersion,  int latestBuildNumber,  Map<String, ChannelInfo> channels,  String? minSupportedVersion,  String? serverVersion)?  $default,) {final _that = this;
switch (_that) {
case _VersionInfo() when $default != null:
return $default(_that.latestVersion,_that.latestBuildNumber,_that.channels,_that.minSupportedVersion,_that.serverVersion);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _VersionInfo implements VersionInfo {
  const _VersionInfo({required this.latestVersion, required this.latestBuildNumber, required final  Map<String, ChannelInfo> channels, this.minSupportedVersion, this.serverVersion}): _channels = channels;
  factory _VersionInfo.fromJson(Map<String, dynamic> json) => _$VersionInfoFromJson(json);

/// Latest stable version
@override final  String latestVersion;
/// Latest build number
@override final  int latestBuildNumber;
/// Available channels
 final  Map<String, ChannelInfo> _channels;
/// Available channels
@override Map<String, ChannelInfo> get channels {
  if (_channels is EqualUnmodifiableMapView) return _channels;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_channels);
}

/// Minimum supported version (older versions must update)
@override final  String? minSupportedVersion;
/// Server version for compatibility checks
@override final  String? serverVersion;

/// Create a copy of VersionInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$VersionInfoCopyWith<_VersionInfo> get copyWith => __$VersionInfoCopyWithImpl<_VersionInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$VersionInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _VersionInfo&&(identical(other.latestVersion, latestVersion) || other.latestVersion == latestVersion)&&(identical(other.latestBuildNumber, latestBuildNumber) || other.latestBuildNumber == latestBuildNumber)&&const DeepCollectionEquality().equals(other._channels, _channels)&&(identical(other.minSupportedVersion, minSupportedVersion) || other.minSupportedVersion == minSupportedVersion)&&(identical(other.serverVersion, serverVersion) || other.serverVersion == serverVersion));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,latestVersion,latestBuildNumber,const DeepCollectionEquality().hash(_channels),minSupportedVersion,serverVersion);

@override
String toString() {
  return 'VersionInfo(latestVersion: $latestVersion, latestBuildNumber: $latestBuildNumber, channels: $channels, minSupportedVersion: $minSupportedVersion, serverVersion: $serverVersion)';
}


}

/// @nodoc
abstract mixin class _$VersionInfoCopyWith<$Res> implements $VersionInfoCopyWith<$Res> {
  factory _$VersionInfoCopyWith(_VersionInfo value, $Res Function(_VersionInfo) _then) = __$VersionInfoCopyWithImpl;
@override @useResult
$Res call({
 String latestVersion, int latestBuildNumber, Map<String, ChannelInfo> channels, String? minSupportedVersion, String? serverVersion
});




}
/// @nodoc
class __$VersionInfoCopyWithImpl<$Res>
    implements _$VersionInfoCopyWith<$Res> {
  __$VersionInfoCopyWithImpl(this._self, this._then);

  final _VersionInfo _self;
  final $Res Function(_VersionInfo) _then;

/// Create a copy of VersionInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? latestVersion = null,Object? latestBuildNumber = null,Object? channels = null,Object? minSupportedVersion = freezed,Object? serverVersion = freezed,}) {
  return _then(_VersionInfo(
latestVersion: null == latestVersion ? _self.latestVersion : latestVersion // ignore: cast_nullable_to_non_nullable
as String,latestBuildNumber: null == latestBuildNumber ? _self.latestBuildNumber : latestBuildNumber // ignore: cast_nullable_to_non_nullable
as int,channels: null == channels ? _self._channels : channels // ignore: cast_nullable_to_non_nullable
as Map<String, ChannelInfo>,minSupportedVersion: freezed == minSupportedVersion ? _self.minSupportedVersion : minSupportedVersion // ignore: cast_nullable_to_non_nullable
as String?,serverVersion: freezed == serverVersion ? _self.serverVersion : serverVersion // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$ChannelInfo {

 String get version; String get manifestUrl;
/// Create a copy of ChannelInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ChannelInfoCopyWith<ChannelInfo> get copyWith => _$ChannelInfoCopyWithImpl<ChannelInfo>(this as ChannelInfo, _$identity);

  /// Serializes this ChannelInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ChannelInfo&&(identical(other.version, version) || other.version == version)&&(identical(other.manifestUrl, manifestUrl) || other.manifestUrl == manifestUrl));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,version,manifestUrl);

@override
String toString() {
  return 'ChannelInfo(version: $version, manifestUrl: $manifestUrl)';
}


}

/// @nodoc
abstract mixin class $ChannelInfoCopyWith<$Res>  {
  factory $ChannelInfoCopyWith(ChannelInfo value, $Res Function(ChannelInfo) _then) = _$ChannelInfoCopyWithImpl;
@useResult
$Res call({
 String version, String manifestUrl
});




}
/// @nodoc
class _$ChannelInfoCopyWithImpl<$Res>
    implements $ChannelInfoCopyWith<$Res> {
  _$ChannelInfoCopyWithImpl(this._self, this._then);

  final ChannelInfo _self;
  final $Res Function(ChannelInfo) _then;

/// Create a copy of ChannelInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? version = null,Object? manifestUrl = null,}) {
  return _then(_self.copyWith(
version: null == version ? _self.version : version // ignore: cast_nullable_to_non_nullable
as String,manifestUrl: null == manifestUrl ? _self.manifestUrl : manifestUrl // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [ChannelInfo].
extension ChannelInfoPatterns on ChannelInfo {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ChannelInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ChannelInfo() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ChannelInfo value)  $default,){
final _that = this;
switch (_that) {
case _ChannelInfo():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ChannelInfo value)?  $default,){
final _that = this;
switch (_that) {
case _ChannelInfo() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String version,  String manifestUrl)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ChannelInfo() when $default != null:
return $default(_that.version,_that.manifestUrl);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String version,  String manifestUrl)  $default,) {final _that = this;
switch (_that) {
case _ChannelInfo():
return $default(_that.version,_that.manifestUrl);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String version,  String manifestUrl)?  $default,) {final _that = this;
switch (_that) {
case _ChannelInfo() when $default != null:
return $default(_that.version,_that.manifestUrl);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ChannelInfo implements ChannelInfo {
  const _ChannelInfo({required this.version, required this.manifestUrl});
  factory _ChannelInfo.fromJson(Map<String, dynamic> json) => _$ChannelInfoFromJson(json);

@override final  String version;
@override final  String manifestUrl;

/// Create a copy of ChannelInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ChannelInfoCopyWith<_ChannelInfo> get copyWith => __$ChannelInfoCopyWithImpl<_ChannelInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ChannelInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ChannelInfo&&(identical(other.version, version) || other.version == version)&&(identical(other.manifestUrl, manifestUrl) || other.manifestUrl == manifestUrl));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,version,manifestUrl);

@override
String toString() {
  return 'ChannelInfo(version: $version, manifestUrl: $manifestUrl)';
}


}

/// @nodoc
abstract mixin class _$ChannelInfoCopyWith<$Res> implements $ChannelInfoCopyWith<$Res> {
  factory _$ChannelInfoCopyWith(_ChannelInfo value, $Res Function(_ChannelInfo) _then) = __$ChannelInfoCopyWithImpl;
@override @useResult
$Res call({
 String version, String manifestUrl
});




}
/// @nodoc
class __$ChannelInfoCopyWithImpl<$Res>
    implements _$ChannelInfoCopyWith<$Res> {
  __$ChannelInfoCopyWithImpl(this._self, this._then);

  final _ChannelInfo _self;
  final $Res Function(_ChannelInfo) _then;

/// Create a copy of ChannelInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? version = null,Object? manifestUrl = null,}) {
  return _then(_ChannelInfo(
version: null == version ? _self.version : version // ignore: cast_nullable_to_non_nullable
as String,manifestUrl: null == manifestUrl ? _self.manifestUrl : manifestUrl // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
