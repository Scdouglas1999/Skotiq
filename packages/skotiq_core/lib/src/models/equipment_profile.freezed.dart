// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'equipment_profile.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$EquipmentProfile {

 String get id; String get name; String? get description;// Device identifiers
 String? get cameraId; String? get mountId; String? get focuserId; String? get filterWheelId; String? get guiderId; String? get rotatorId; String? get domeId; String? get weatherId; String? get safetyMonitorId; String? get switchId; String? get coverCalibratorId;// Optical setup
 double get focalLength; double get aperture; double? get focalRatio;// Camera defaults
 int? get defaultGain; int? get defaultOffset; int get defaultBinX; int get defaultBinY; double? get defaultCoolingTemp; bool get coolOnConnect;// Centering/plate-solve exposure default (seconds)
 double? get defaultCenteringExposure;// Filter configuration (JSON-serialized in DB)
 String? get filterNames; String? get filterFocusOffsets;// Meridian flip settings overrides (JSON)
 String? get meridianFlipOverrides;// User-friendly device names
 String? get cameraName; String? get mountName; String? get focuserName; String? get filterWheelName; String? get guiderName; String? get rotatorName; String? get safetyMonitorName; String? get switchName;// Telescope/OTA information
 String? get telescopeName; double get telescopeFocalLength; double get telescopeAperture;// Profile customization
 String? get profileIcon; int? get profileColor; int get sortOrder; bool get isDefault;// Timestamps
 DateTime? get createdAt; DateTime? get updatedAt;// State flags
 bool get isActive;// Camera pixel size in microns (not in DB, used by bridge)
 double? get pixelSize;
/// Create a copy of EquipmentProfile
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EquipmentProfileCopyWith<EquipmentProfile> get copyWith => _$EquipmentProfileCopyWithImpl<EquipmentProfile>(this as EquipmentProfile, _$identity);

  /// Serializes this EquipmentProfile to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EquipmentProfile&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&(identical(other.cameraId, cameraId) || other.cameraId == cameraId)&&(identical(other.mountId, mountId) || other.mountId == mountId)&&(identical(other.focuserId, focuserId) || other.focuserId == focuserId)&&(identical(other.filterWheelId, filterWheelId) || other.filterWheelId == filterWheelId)&&(identical(other.guiderId, guiderId) || other.guiderId == guiderId)&&(identical(other.rotatorId, rotatorId) || other.rotatorId == rotatorId)&&(identical(other.domeId, domeId) || other.domeId == domeId)&&(identical(other.weatherId, weatherId) || other.weatherId == weatherId)&&(identical(other.safetyMonitorId, safetyMonitorId) || other.safetyMonitorId == safetyMonitorId)&&(identical(other.switchId, switchId) || other.switchId == switchId)&&(identical(other.coverCalibratorId, coverCalibratorId) || other.coverCalibratorId == coverCalibratorId)&&(identical(other.focalLength, focalLength) || other.focalLength == focalLength)&&(identical(other.aperture, aperture) || other.aperture == aperture)&&(identical(other.focalRatio, focalRatio) || other.focalRatio == focalRatio)&&(identical(other.defaultGain, defaultGain) || other.defaultGain == defaultGain)&&(identical(other.defaultOffset, defaultOffset) || other.defaultOffset == defaultOffset)&&(identical(other.defaultBinX, defaultBinX) || other.defaultBinX == defaultBinX)&&(identical(other.defaultBinY, defaultBinY) || other.defaultBinY == defaultBinY)&&(identical(other.defaultCoolingTemp, defaultCoolingTemp) || other.defaultCoolingTemp == defaultCoolingTemp)&&(identical(other.coolOnConnect, coolOnConnect) || other.coolOnConnect == coolOnConnect)&&(identical(other.defaultCenteringExposure, defaultCenteringExposure) || other.defaultCenteringExposure == defaultCenteringExposure)&&(identical(other.filterNames, filterNames) || other.filterNames == filterNames)&&(identical(other.filterFocusOffsets, filterFocusOffsets) || other.filterFocusOffsets == filterFocusOffsets)&&(identical(other.meridianFlipOverrides, meridianFlipOverrides) || other.meridianFlipOverrides == meridianFlipOverrides)&&(identical(other.cameraName, cameraName) || other.cameraName == cameraName)&&(identical(other.mountName, mountName) || other.mountName == mountName)&&(identical(other.focuserName, focuserName) || other.focuserName == focuserName)&&(identical(other.filterWheelName, filterWheelName) || other.filterWheelName == filterWheelName)&&(identical(other.guiderName, guiderName) || other.guiderName == guiderName)&&(identical(other.rotatorName, rotatorName) || other.rotatorName == rotatorName)&&(identical(other.safetyMonitorName, safetyMonitorName) || other.safetyMonitorName == safetyMonitorName)&&(identical(other.switchName, switchName) || other.switchName == switchName)&&(identical(other.telescopeName, telescopeName) || other.telescopeName == telescopeName)&&(identical(other.telescopeFocalLength, telescopeFocalLength) || other.telescopeFocalLength == telescopeFocalLength)&&(identical(other.telescopeAperture, telescopeAperture) || other.telescopeAperture == telescopeAperture)&&(identical(other.profileIcon, profileIcon) || other.profileIcon == profileIcon)&&(identical(other.profileColor, profileColor) || other.profileColor == profileColor)&&(identical(other.sortOrder, sortOrder) || other.sortOrder == sortOrder)&&(identical(other.isDefault, isDefault) || other.isDefault == isDefault)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.isActive, isActive) || other.isActive == isActive)&&(identical(other.pixelSize, pixelSize) || other.pixelSize == pixelSize));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,id,name,description,cameraId,mountId,focuserId,filterWheelId,guiderId,rotatorId,domeId,weatherId,safetyMonitorId,switchId,coverCalibratorId,focalLength,aperture,focalRatio,defaultGain,defaultOffset,defaultBinX,defaultBinY,defaultCoolingTemp,coolOnConnect,defaultCenteringExposure,filterNames,filterFocusOffsets,meridianFlipOverrides,cameraName,mountName,focuserName,filterWheelName,guiderName,rotatorName,safetyMonitorName,switchName,telescopeName,telescopeFocalLength,telescopeAperture,profileIcon,profileColor,sortOrder,isDefault,createdAt,updatedAt,isActive,pixelSize]);

@override
String toString() {
  return 'EquipmentProfile(id: $id, name: $name, description: $description, cameraId: $cameraId, mountId: $mountId, focuserId: $focuserId, filterWheelId: $filterWheelId, guiderId: $guiderId, rotatorId: $rotatorId, domeId: $domeId, weatherId: $weatherId, safetyMonitorId: $safetyMonitorId, switchId: $switchId, coverCalibratorId: $coverCalibratorId, focalLength: $focalLength, aperture: $aperture, focalRatio: $focalRatio, defaultGain: $defaultGain, defaultOffset: $defaultOffset, defaultBinX: $defaultBinX, defaultBinY: $defaultBinY, defaultCoolingTemp: $defaultCoolingTemp, coolOnConnect: $coolOnConnect, defaultCenteringExposure: $defaultCenteringExposure, filterNames: $filterNames, filterFocusOffsets: $filterFocusOffsets, meridianFlipOverrides: $meridianFlipOverrides, cameraName: $cameraName, mountName: $mountName, focuserName: $focuserName, filterWheelName: $filterWheelName, guiderName: $guiderName, rotatorName: $rotatorName, safetyMonitorName: $safetyMonitorName, switchName: $switchName, telescopeName: $telescopeName, telescopeFocalLength: $telescopeFocalLength, telescopeAperture: $telescopeAperture, profileIcon: $profileIcon, profileColor: $profileColor, sortOrder: $sortOrder, isDefault: $isDefault, createdAt: $createdAt, updatedAt: $updatedAt, isActive: $isActive, pixelSize: $pixelSize)';
}


}

/// @nodoc
abstract mixin class $EquipmentProfileCopyWith<$Res>  {
  factory $EquipmentProfileCopyWith(EquipmentProfile value, $Res Function(EquipmentProfile) _then) = _$EquipmentProfileCopyWithImpl;
@useResult
$Res call({
 String id, String name, String? description, String? cameraId, String? mountId, String? focuserId, String? filterWheelId, String? guiderId, String? rotatorId, String? domeId, String? weatherId, String? safetyMonitorId, String? switchId, String? coverCalibratorId, double focalLength, double aperture, double? focalRatio, int? defaultGain, int? defaultOffset, int defaultBinX, int defaultBinY, double? defaultCoolingTemp, bool coolOnConnect, double? defaultCenteringExposure, String? filterNames, String? filterFocusOffsets, String? meridianFlipOverrides, String? cameraName, String? mountName, String? focuserName, String? filterWheelName, String? guiderName, String? rotatorName, String? safetyMonitorName, String? switchName, String? telescopeName, double telescopeFocalLength, double telescopeAperture, String? profileIcon, int? profileColor, int sortOrder, bool isDefault, DateTime? createdAt, DateTime? updatedAt, bool isActive, double? pixelSize
});




}
/// @nodoc
class _$EquipmentProfileCopyWithImpl<$Res>
    implements $EquipmentProfileCopyWith<$Res> {
  _$EquipmentProfileCopyWithImpl(this._self, this._then);

  final EquipmentProfile _self;
  final $Res Function(EquipmentProfile) _then;

/// Create a copy of EquipmentProfile
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? description = freezed,Object? cameraId = freezed,Object? mountId = freezed,Object? focuserId = freezed,Object? filterWheelId = freezed,Object? guiderId = freezed,Object? rotatorId = freezed,Object? domeId = freezed,Object? weatherId = freezed,Object? safetyMonitorId = freezed,Object? switchId = freezed,Object? coverCalibratorId = freezed,Object? focalLength = null,Object? aperture = null,Object? focalRatio = freezed,Object? defaultGain = freezed,Object? defaultOffset = freezed,Object? defaultBinX = null,Object? defaultBinY = null,Object? defaultCoolingTemp = freezed,Object? coolOnConnect = null,Object? defaultCenteringExposure = freezed,Object? filterNames = freezed,Object? filterFocusOffsets = freezed,Object? meridianFlipOverrides = freezed,Object? cameraName = freezed,Object? mountName = freezed,Object? focuserName = freezed,Object? filterWheelName = freezed,Object? guiderName = freezed,Object? rotatorName = freezed,Object? safetyMonitorName = freezed,Object? switchName = freezed,Object? telescopeName = freezed,Object? telescopeFocalLength = null,Object? telescopeAperture = null,Object? profileIcon = freezed,Object? profileColor = freezed,Object? sortOrder = null,Object? isDefault = null,Object? createdAt = freezed,Object? updatedAt = freezed,Object? isActive = null,Object? pixelSize = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,cameraId: freezed == cameraId ? _self.cameraId : cameraId // ignore: cast_nullable_to_non_nullable
as String?,mountId: freezed == mountId ? _self.mountId : mountId // ignore: cast_nullable_to_non_nullable
as String?,focuserId: freezed == focuserId ? _self.focuserId : focuserId // ignore: cast_nullable_to_non_nullable
as String?,filterWheelId: freezed == filterWheelId ? _self.filterWheelId : filterWheelId // ignore: cast_nullable_to_non_nullable
as String?,guiderId: freezed == guiderId ? _self.guiderId : guiderId // ignore: cast_nullable_to_non_nullable
as String?,rotatorId: freezed == rotatorId ? _self.rotatorId : rotatorId // ignore: cast_nullable_to_non_nullable
as String?,domeId: freezed == domeId ? _self.domeId : domeId // ignore: cast_nullable_to_non_nullable
as String?,weatherId: freezed == weatherId ? _self.weatherId : weatherId // ignore: cast_nullable_to_non_nullable
as String?,safetyMonitorId: freezed == safetyMonitorId ? _self.safetyMonitorId : safetyMonitorId // ignore: cast_nullable_to_non_nullable
as String?,switchId: freezed == switchId ? _self.switchId : switchId // ignore: cast_nullable_to_non_nullable
as String?,coverCalibratorId: freezed == coverCalibratorId ? _self.coverCalibratorId : coverCalibratorId // ignore: cast_nullable_to_non_nullable
as String?,focalLength: null == focalLength ? _self.focalLength : focalLength // ignore: cast_nullable_to_non_nullable
as double,aperture: null == aperture ? _self.aperture : aperture // ignore: cast_nullable_to_non_nullable
as double,focalRatio: freezed == focalRatio ? _self.focalRatio : focalRatio // ignore: cast_nullable_to_non_nullable
as double?,defaultGain: freezed == defaultGain ? _self.defaultGain : defaultGain // ignore: cast_nullable_to_non_nullable
as int?,defaultOffset: freezed == defaultOffset ? _self.defaultOffset : defaultOffset // ignore: cast_nullable_to_non_nullable
as int?,defaultBinX: null == defaultBinX ? _self.defaultBinX : defaultBinX // ignore: cast_nullable_to_non_nullable
as int,defaultBinY: null == defaultBinY ? _self.defaultBinY : defaultBinY // ignore: cast_nullable_to_non_nullable
as int,defaultCoolingTemp: freezed == defaultCoolingTemp ? _self.defaultCoolingTemp : defaultCoolingTemp // ignore: cast_nullable_to_non_nullable
as double?,coolOnConnect: null == coolOnConnect ? _self.coolOnConnect : coolOnConnect // ignore: cast_nullable_to_non_nullable
as bool,defaultCenteringExposure: freezed == defaultCenteringExposure ? _self.defaultCenteringExposure : defaultCenteringExposure // ignore: cast_nullable_to_non_nullable
as double?,filterNames: freezed == filterNames ? _self.filterNames : filterNames // ignore: cast_nullable_to_non_nullable
as String?,filterFocusOffsets: freezed == filterFocusOffsets ? _self.filterFocusOffsets : filterFocusOffsets // ignore: cast_nullable_to_non_nullable
as String?,meridianFlipOverrides: freezed == meridianFlipOverrides ? _self.meridianFlipOverrides : meridianFlipOverrides // ignore: cast_nullable_to_non_nullable
as String?,cameraName: freezed == cameraName ? _self.cameraName : cameraName // ignore: cast_nullable_to_non_nullable
as String?,mountName: freezed == mountName ? _self.mountName : mountName // ignore: cast_nullable_to_non_nullable
as String?,focuserName: freezed == focuserName ? _self.focuserName : focuserName // ignore: cast_nullable_to_non_nullable
as String?,filterWheelName: freezed == filterWheelName ? _self.filterWheelName : filterWheelName // ignore: cast_nullable_to_non_nullable
as String?,guiderName: freezed == guiderName ? _self.guiderName : guiderName // ignore: cast_nullable_to_non_nullable
as String?,rotatorName: freezed == rotatorName ? _self.rotatorName : rotatorName // ignore: cast_nullable_to_non_nullable
as String?,safetyMonitorName: freezed == safetyMonitorName ? _self.safetyMonitorName : safetyMonitorName // ignore: cast_nullable_to_non_nullable
as String?,switchName: freezed == switchName ? _self.switchName : switchName // ignore: cast_nullable_to_non_nullable
as String?,telescopeName: freezed == telescopeName ? _self.telescopeName : telescopeName // ignore: cast_nullable_to_non_nullable
as String?,telescopeFocalLength: null == telescopeFocalLength ? _self.telescopeFocalLength : telescopeFocalLength // ignore: cast_nullable_to_non_nullable
as double,telescopeAperture: null == telescopeAperture ? _self.telescopeAperture : telescopeAperture // ignore: cast_nullable_to_non_nullable
as double,profileIcon: freezed == profileIcon ? _self.profileIcon : profileIcon // ignore: cast_nullable_to_non_nullable
as String?,profileColor: freezed == profileColor ? _self.profileColor : profileColor // ignore: cast_nullable_to_non_nullable
as int?,sortOrder: null == sortOrder ? _self.sortOrder : sortOrder // ignore: cast_nullable_to_non_nullable
as int,isDefault: null == isDefault ? _self.isDefault : isDefault // ignore: cast_nullable_to_non_nullable
as bool,createdAt: freezed == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime?,updatedAt: freezed == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,isActive: null == isActive ? _self.isActive : isActive // ignore: cast_nullable_to_non_nullable
as bool,pixelSize: freezed == pixelSize ? _self.pixelSize : pixelSize // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}

}


/// Adds pattern-matching-related methods to [EquipmentProfile].
extension EquipmentProfilePatterns on EquipmentProfile {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _EquipmentProfile value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _EquipmentProfile() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _EquipmentProfile value)  $default,){
final _that = this;
switch (_that) {
case _EquipmentProfile():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _EquipmentProfile value)?  $default,){
final _that = this;
switch (_that) {
case _EquipmentProfile() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  String? description,  String? cameraId,  String? mountId,  String? focuserId,  String? filterWheelId,  String? guiderId,  String? rotatorId,  String? domeId,  String? weatherId,  String? safetyMonitorId,  String? switchId,  String? coverCalibratorId,  double focalLength,  double aperture,  double? focalRatio,  int? defaultGain,  int? defaultOffset,  int defaultBinX,  int defaultBinY,  double? defaultCoolingTemp,  bool coolOnConnect,  double? defaultCenteringExposure,  String? filterNames,  String? filterFocusOffsets,  String? meridianFlipOverrides,  String? cameraName,  String? mountName,  String? focuserName,  String? filterWheelName,  String? guiderName,  String? rotatorName,  String? safetyMonitorName,  String? switchName,  String? telescopeName,  double telescopeFocalLength,  double telescopeAperture,  String? profileIcon,  int? profileColor,  int sortOrder,  bool isDefault,  DateTime? createdAt,  DateTime? updatedAt,  bool isActive,  double? pixelSize)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _EquipmentProfile() when $default != null:
return $default(_that.id,_that.name,_that.description,_that.cameraId,_that.mountId,_that.focuserId,_that.filterWheelId,_that.guiderId,_that.rotatorId,_that.domeId,_that.weatherId,_that.safetyMonitorId,_that.switchId,_that.coverCalibratorId,_that.focalLength,_that.aperture,_that.focalRatio,_that.defaultGain,_that.defaultOffset,_that.defaultBinX,_that.defaultBinY,_that.defaultCoolingTemp,_that.coolOnConnect,_that.defaultCenteringExposure,_that.filterNames,_that.filterFocusOffsets,_that.meridianFlipOverrides,_that.cameraName,_that.mountName,_that.focuserName,_that.filterWheelName,_that.guiderName,_that.rotatorName,_that.safetyMonitorName,_that.switchName,_that.telescopeName,_that.telescopeFocalLength,_that.telescopeAperture,_that.profileIcon,_that.profileColor,_that.sortOrder,_that.isDefault,_that.createdAt,_that.updatedAt,_that.isActive,_that.pixelSize);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  String? description,  String? cameraId,  String? mountId,  String? focuserId,  String? filterWheelId,  String? guiderId,  String? rotatorId,  String? domeId,  String? weatherId,  String? safetyMonitorId,  String? switchId,  String? coverCalibratorId,  double focalLength,  double aperture,  double? focalRatio,  int? defaultGain,  int? defaultOffset,  int defaultBinX,  int defaultBinY,  double? defaultCoolingTemp,  bool coolOnConnect,  double? defaultCenteringExposure,  String? filterNames,  String? filterFocusOffsets,  String? meridianFlipOverrides,  String? cameraName,  String? mountName,  String? focuserName,  String? filterWheelName,  String? guiderName,  String? rotatorName,  String? safetyMonitorName,  String? switchName,  String? telescopeName,  double telescopeFocalLength,  double telescopeAperture,  String? profileIcon,  int? profileColor,  int sortOrder,  bool isDefault,  DateTime? createdAt,  DateTime? updatedAt,  bool isActive,  double? pixelSize)  $default,) {final _that = this;
switch (_that) {
case _EquipmentProfile():
return $default(_that.id,_that.name,_that.description,_that.cameraId,_that.mountId,_that.focuserId,_that.filterWheelId,_that.guiderId,_that.rotatorId,_that.domeId,_that.weatherId,_that.safetyMonitorId,_that.switchId,_that.coverCalibratorId,_that.focalLength,_that.aperture,_that.focalRatio,_that.defaultGain,_that.defaultOffset,_that.defaultBinX,_that.defaultBinY,_that.defaultCoolingTemp,_that.coolOnConnect,_that.defaultCenteringExposure,_that.filterNames,_that.filterFocusOffsets,_that.meridianFlipOverrides,_that.cameraName,_that.mountName,_that.focuserName,_that.filterWheelName,_that.guiderName,_that.rotatorName,_that.safetyMonitorName,_that.switchName,_that.telescopeName,_that.telescopeFocalLength,_that.telescopeAperture,_that.profileIcon,_that.profileColor,_that.sortOrder,_that.isDefault,_that.createdAt,_that.updatedAt,_that.isActive,_that.pixelSize);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  String? description,  String? cameraId,  String? mountId,  String? focuserId,  String? filterWheelId,  String? guiderId,  String? rotatorId,  String? domeId,  String? weatherId,  String? safetyMonitorId,  String? switchId,  String? coverCalibratorId,  double focalLength,  double aperture,  double? focalRatio,  int? defaultGain,  int? defaultOffset,  int defaultBinX,  int defaultBinY,  double? defaultCoolingTemp,  bool coolOnConnect,  double? defaultCenteringExposure,  String? filterNames,  String? filterFocusOffsets,  String? meridianFlipOverrides,  String? cameraName,  String? mountName,  String? focuserName,  String? filterWheelName,  String? guiderName,  String? rotatorName,  String? safetyMonitorName,  String? switchName,  String? telescopeName,  double telescopeFocalLength,  double telescopeAperture,  String? profileIcon,  int? profileColor,  int sortOrder,  bool isDefault,  DateTime? createdAt,  DateTime? updatedAt,  bool isActive,  double? pixelSize)?  $default,) {final _that = this;
switch (_that) {
case _EquipmentProfile() when $default != null:
return $default(_that.id,_that.name,_that.description,_that.cameraId,_that.mountId,_that.focuserId,_that.filterWheelId,_that.guiderId,_that.rotatorId,_that.domeId,_that.weatherId,_that.safetyMonitorId,_that.switchId,_that.coverCalibratorId,_that.focalLength,_that.aperture,_that.focalRatio,_that.defaultGain,_that.defaultOffset,_that.defaultBinX,_that.defaultBinY,_that.defaultCoolingTemp,_that.coolOnConnect,_that.defaultCenteringExposure,_that.filterNames,_that.filterFocusOffsets,_that.meridianFlipOverrides,_that.cameraName,_that.mountName,_that.focuserName,_that.filterWheelName,_that.guiderName,_that.rotatorName,_that.safetyMonitorName,_that.switchName,_that.telescopeName,_that.telescopeFocalLength,_that.telescopeAperture,_that.profileIcon,_that.profileColor,_that.sortOrder,_that.isDefault,_that.createdAt,_that.updatedAt,_that.isActive,_that.pixelSize);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _EquipmentProfile implements EquipmentProfile {
  const _EquipmentProfile({required this.id, required this.name, this.description, this.cameraId, this.mountId, this.focuserId, this.filterWheelId, this.guiderId, this.rotatorId, this.domeId, this.weatherId, this.safetyMonitorId, this.switchId, this.coverCalibratorId, this.focalLength = 0.0, this.aperture = 0.0, this.focalRatio, this.defaultGain, this.defaultOffset, this.defaultBinX = 1, this.defaultBinY = 1, this.defaultCoolingTemp, this.coolOnConnect = false, this.defaultCenteringExposure, this.filterNames, this.filterFocusOffsets, this.meridianFlipOverrides, this.cameraName, this.mountName, this.focuserName, this.filterWheelName, this.guiderName, this.rotatorName, this.safetyMonitorName, this.switchName, this.telescopeName, this.telescopeFocalLength = 0.0, this.telescopeAperture = 0.0, this.profileIcon, this.profileColor, this.sortOrder = 0, this.isDefault = false, this.createdAt, this.updatedAt, this.isActive = false, this.pixelSize});
  factory _EquipmentProfile.fromJson(Map<String, dynamic> json) => _$EquipmentProfileFromJson(json);

@override final  String id;
@override final  String name;
@override final  String? description;
// Device identifiers
@override final  String? cameraId;
@override final  String? mountId;
@override final  String? focuserId;
@override final  String? filterWheelId;
@override final  String? guiderId;
@override final  String? rotatorId;
@override final  String? domeId;
@override final  String? weatherId;
@override final  String? safetyMonitorId;
@override final  String? switchId;
@override final  String? coverCalibratorId;
// Optical setup
@override@JsonKey() final  double focalLength;
@override@JsonKey() final  double aperture;
@override final  double? focalRatio;
// Camera defaults
@override final  int? defaultGain;
@override final  int? defaultOffset;
@override@JsonKey() final  int defaultBinX;
@override@JsonKey() final  int defaultBinY;
@override final  double? defaultCoolingTemp;
@override@JsonKey() final  bool coolOnConnect;
// Centering/plate-solve exposure default (seconds)
@override final  double? defaultCenteringExposure;
// Filter configuration (JSON-serialized in DB)
@override final  String? filterNames;
@override final  String? filterFocusOffsets;
// Meridian flip settings overrides (JSON)
@override final  String? meridianFlipOverrides;
// User-friendly device names
@override final  String? cameraName;
@override final  String? mountName;
@override final  String? focuserName;
@override final  String? filterWheelName;
@override final  String? guiderName;
@override final  String? rotatorName;
@override final  String? safetyMonitorName;
@override final  String? switchName;
// Telescope/OTA information
@override final  String? telescopeName;
@override@JsonKey() final  double telescopeFocalLength;
@override@JsonKey() final  double telescopeAperture;
// Profile customization
@override final  String? profileIcon;
@override final  int? profileColor;
@override@JsonKey() final  int sortOrder;
@override@JsonKey() final  bool isDefault;
// Timestamps
@override final  DateTime? createdAt;
@override final  DateTime? updatedAt;
// State flags
@override@JsonKey() final  bool isActive;
// Camera pixel size in microns (not in DB, used by bridge)
@override final  double? pixelSize;

/// Create a copy of EquipmentProfile
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$EquipmentProfileCopyWith<_EquipmentProfile> get copyWith => __$EquipmentProfileCopyWithImpl<_EquipmentProfile>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$EquipmentProfileToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _EquipmentProfile&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&(identical(other.cameraId, cameraId) || other.cameraId == cameraId)&&(identical(other.mountId, mountId) || other.mountId == mountId)&&(identical(other.focuserId, focuserId) || other.focuserId == focuserId)&&(identical(other.filterWheelId, filterWheelId) || other.filterWheelId == filterWheelId)&&(identical(other.guiderId, guiderId) || other.guiderId == guiderId)&&(identical(other.rotatorId, rotatorId) || other.rotatorId == rotatorId)&&(identical(other.domeId, domeId) || other.domeId == domeId)&&(identical(other.weatherId, weatherId) || other.weatherId == weatherId)&&(identical(other.safetyMonitorId, safetyMonitorId) || other.safetyMonitorId == safetyMonitorId)&&(identical(other.switchId, switchId) || other.switchId == switchId)&&(identical(other.coverCalibratorId, coverCalibratorId) || other.coverCalibratorId == coverCalibratorId)&&(identical(other.focalLength, focalLength) || other.focalLength == focalLength)&&(identical(other.aperture, aperture) || other.aperture == aperture)&&(identical(other.focalRatio, focalRatio) || other.focalRatio == focalRatio)&&(identical(other.defaultGain, defaultGain) || other.defaultGain == defaultGain)&&(identical(other.defaultOffset, defaultOffset) || other.defaultOffset == defaultOffset)&&(identical(other.defaultBinX, defaultBinX) || other.defaultBinX == defaultBinX)&&(identical(other.defaultBinY, defaultBinY) || other.defaultBinY == defaultBinY)&&(identical(other.defaultCoolingTemp, defaultCoolingTemp) || other.defaultCoolingTemp == defaultCoolingTemp)&&(identical(other.coolOnConnect, coolOnConnect) || other.coolOnConnect == coolOnConnect)&&(identical(other.defaultCenteringExposure, defaultCenteringExposure) || other.defaultCenteringExposure == defaultCenteringExposure)&&(identical(other.filterNames, filterNames) || other.filterNames == filterNames)&&(identical(other.filterFocusOffsets, filterFocusOffsets) || other.filterFocusOffsets == filterFocusOffsets)&&(identical(other.meridianFlipOverrides, meridianFlipOverrides) || other.meridianFlipOverrides == meridianFlipOverrides)&&(identical(other.cameraName, cameraName) || other.cameraName == cameraName)&&(identical(other.mountName, mountName) || other.mountName == mountName)&&(identical(other.focuserName, focuserName) || other.focuserName == focuserName)&&(identical(other.filterWheelName, filterWheelName) || other.filterWheelName == filterWheelName)&&(identical(other.guiderName, guiderName) || other.guiderName == guiderName)&&(identical(other.rotatorName, rotatorName) || other.rotatorName == rotatorName)&&(identical(other.safetyMonitorName, safetyMonitorName) || other.safetyMonitorName == safetyMonitorName)&&(identical(other.switchName, switchName) || other.switchName == switchName)&&(identical(other.telescopeName, telescopeName) || other.telescopeName == telescopeName)&&(identical(other.telescopeFocalLength, telescopeFocalLength) || other.telescopeFocalLength == telescopeFocalLength)&&(identical(other.telescopeAperture, telescopeAperture) || other.telescopeAperture == telescopeAperture)&&(identical(other.profileIcon, profileIcon) || other.profileIcon == profileIcon)&&(identical(other.profileColor, profileColor) || other.profileColor == profileColor)&&(identical(other.sortOrder, sortOrder) || other.sortOrder == sortOrder)&&(identical(other.isDefault, isDefault) || other.isDefault == isDefault)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.isActive, isActive) || other.isActive == isActive)&&(identical(other.pixelSize, pixelSize) || other.pixelSize == pixelSize));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,id,name,description,cameraId,mountId,focuserId,filterWheelId,guiderId,rotatorId,domeId,weatherId,safetyMonitorId,switchId,coverCalibratorId,focalLength,aperture,focalRatio,defaultGain,defaultOffset,defaultBinX,defaultBinY,defaultCoolingTemp,coolOnConnect,defaultCenteringExposure,filterNames,filterFocusOffsets,meridianFlipOverrides,cameraName,mountName,focuserName,filterWheelName,guiderName,rotatorName,safetyMonitorName,switchName,telescopeName,telescopeFocalLength,telescopeAperture,profileIcon,profileColor,sortOrder,isDefault,createdAt,updatedAt,isActive,pixelSize]);

@override
String toString() {
  return 'EquipmentProfile(id: $id, name: $name, description: $description, cameraId: $cameraId, mountId: $mountId, focuserId: $focuserId, filterWheelId: $filterWheelId, guiderId: $guiderId, rotatorId: $rotatorId, domeId: $domeId, weatherId: $weatherId, safetyMonitorId: $safetyMonitorId, switchId: $switchId, coverCalibratorId: $coverCalibratorId, focalLength: $focalLength, aperture: $aperture, focalRatio: $focalRatio, defaultGain: $defaultGain, defaultOffset: $defaultOffset, defaultBinX: $defaultBinX, defaultBinY: $defaultBinY, defaultCoolingTemp: $defaultCoolingTemp, coolOnConnect: $coolOnConnect, defaultCenteringExposure: $defaultCenteringExposure, filterNames: $filterNames, filterFocusOffsets: $filterFocusOffsets, meridianFlipOverrides: $meridianFlipOverrides, cameraName: $cameraName, mountName: $mountName, focuserName: $focuserName, filterWheelName: $filterWheelName, guiderName: $guiderName, rotatorName: $rotatorName, safetyMonitorName: $safetyMonitorName, switchName: $switchName, telescopeName: $telescopeName, telescopeFocalLength: $telescopeFocalLength, telescopeAperture: $telescopeAperture, profileIcon: $profileIcon, profileColor: $profileColor, sortOrder: $sortOrder, isDefault: $isDefault, createdAt: $createdAt, updatedAt: $updatedAt, isActive: $isActive, pixelSize: $pixelSize)';
}


}

/// @nodoc
abstract mixin class _$EquipmentProfileCopyWith<$Res> implements $EquipmentProfileCopyWith<$Res> {
  factory _$EquipmentProfileCopyWith(_EquipmentProfile value, $Res Function(_EquipmentProfile) _then) = __$EquipmentProfileCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, String? description, String? cameraId, String? mountId, String? focuserId, String? filterWheelId, String? guiderId, String? rotatorId, String? domeId, String? weatherId, String? safetyMonitorId, String? switchId, String? coverCalibratorId, double focalLength, double aperture, double? focalRatio, int? defaultGain, int? defaultOffset, int defaultBinX, int defaultBinY, double? defaultCoolingTemp, bool coolOnConnect, double? defaultCenteringExposure, String? filterNames, String? filterFocusOffsets, String? meridianFlipOverrides, String? cameraName, String? mountName, String? focuserName, String? filterWheelName, String? guiderName, String? rotatorName, String? safetyMonitorName, String? switchName, String? telescopeName, double telescopeFocalLength, double telescopeAperture, String? profileIcon, int? profileColor, int sortOrder, bool isDefault, DateTime? createdAt, DateTime? updatedAt, bool isActive, double? pixelSize
});




}
/// @nodoc
class __$EquipmentProfileCopyWithImpl<$Res>
    implements _$EquipmentProfileCopyWith<$Res> {
  __$EquipmentProfileCopyWithImpl(this._self, this._then);

  final _EquipmentProfile _self;
  final $Res Function(_EquipmentProfile) _then;

/// Create a copy of EquipmentProfile
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? description = freezed,Object? cameraId = freezed,Object? mountId = freezed,Object? focuserId = freezed,Object? filterWheelId = freezed,Object? guiderId = freezed,Object? rotatorId = freezed,Object? domeId = freezed,Object? weatherId = freezed,Object? safetyMonitorId = freezed,Object? switchId = freezed,Object? coverCalibratorId = freezed,Object? focalLength = null,Object? aperture = null,Object? focalRatio = freezed,Object? defaultGain = freezed,Object? defaultOffset = freezed,Object? defaultBinX = null,Object? defaultBinY = null,Object? defaultCoolingTemp = freezed,Object? coolOnConnect = null,Object? defaultCenteringExposure = freezed,Object? filterNames = freezed,Object? filterFocusOffsets = freezed,Object? meridianFlipOverrides = freezed,Object? cameraName = freezed,Object? mountName = freezed,Object? focuserName = freezed,Object? filterWheelName = freezed,Object? guiderName = freezed,Object? rotatorName = freezed,Object? safetyMonitorName = freezed,Object? switchName = freezed,Object? telescopeName = freezed,Object? telescopeFocalLength = null,Object? telescopeAperture = null,Object? profileIcon = freezed,Object? profileColor = freezed,Object? sortOrder = null,Object? isDefault = null,Object? createdAt = freezed,Object? updatedAt = freezed,Object? isActive = null,Object? pixelSize = freezed,}) {
  return _then(_EquipmentProfile(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,cameraId: freezed == cameraId ? _self.cameraId : cameraId // ignore: cast_nullable_to_non_nullable
as String?,mountId: freezed == mountId ? _self.mountId : mountId // ignore: cast_nullable_to_non_nullable
as String?,focuserId: freezed == focuserId ? _self.focuserId : focuserId // ignore: cast_nullable_to_non_nullable
as String?,filterWheelId: freezed == filterWheelId ? _self.filterWheelId : filterWheelId // ignore: cast_nullable_to_non_nullable
as String?,guiderId: freezed == guiderId ? _self.guiderId : guiderId // ignore: cast_nullable_to_non_nullable
as String?,rotatorId: freezed == rotatorId ? _self.rotatorId : rotatorId // ignore: cast_nullable_to_non_nullable
as String?,domeId: freezed == domeId ? _self.domeId : domeId // ignore: cast_nullable_to_non_nullable
as String?,weatherId: freezed == weatherId ? _self.weatherId : weatherId // ignore: cast_nullable_to_non_nullable
as String?,safetyMonitorId: freezed == safetyMonitorId ? _self.safetyMonitorId : safetyMonitorId // ignore: cast_nullable_to_non_nullable
as String?,switchId: freezed == switchId ? _self.switchId : switchId // ignore: cast_nullable_to_non_nullable
as String?,coverCalibratorId: freezed == coverCalibratorId ? _self.coverCalibratorId : coverCalibratorId // ignore: cast_nullable_to_non_nullable
as String?,focalLength: null == focalLength ? _self.focalLength : focalLength // ignore: cast_nullable_to_non_nullable
as double,aperture: null == aperture ? _self.aperture : aperture // ignore: cast_nullable_to_non_nullable
as double,focalRatio: freezed == focalRatio ? _self.focalRatio : focalRatio // ignore: cast_nullable_to_non_nullable
as double?,defaultGain: freezed == defaultGain ? _self.defaultGain : defaultGain // ignore: cast_nullable_to_non_nullable
as int?,defaultOffset: freezed == defaultOffset ? _self.defaultOffset : defaultOffset // ignore: cast_nullable_to_non_nullable
as int?,defaultBinX: null == defaultBinX ? _self.defaultBinX : defaultBinX // ignore: cast_nullable_to_non_nullable
as int,defaultBinY: null == defaultBinY ? _self.defaultBinY : defaultBinY // ignore: cast_nullable_to_non_nullable
as int,defaultCoolingTemp: freezed == defaultCoolingTemp ? _self.defaultCoolingTemp : defaultCoolingTemp // ignore: cast_nullable_to_non_nullable
as double?,coolOnConnect: null == coolOnConnect ? _self.coolOnConnect : coolOnConnect // ignore: cast_nullable_to_non_nullable
as bool,defaultCenteringExposure: freezed == defaultCenteringExposure ? _self.defaultCenteringExposure : defaultCenteringExposure // ignore: cast_nullable_to_non_nullable
as double?,filterNames: freezed == filterNames ? _self.filterNames : filterNames // ignore: cast_nullable_to_non_nullable
as String?,filterFocusOffsets: freezed == filterFocusOffsets ? _self.filterFocusOffsets : filterFocusOffsets // ignore: cast_nullable_to_non_nullable
as String?,meridianFlipOverrides: freezed == meridianFlipOverrides ? _self.meridianFlipOverrides : meridianFlipOverrides // ignore: cast_nullable_to_non_nullable
as String?,cameraName: freezed == cameraName ? _self.cameraName : cameraName // ignore: cast_nullable_to_non_nullable
as String?,mountName: freezed == mountName ? _self.mountName : mountName // ignore: cast_nullable_to_non_nullable
as String?,focuserName: freezed == focuserName ? _self.focuserName : focuserName // ignore: cast_nullable_to_non_nullable
as String?,filterWheelName: freezed == filterWheelName ? _self.filterWheelName : filterWheelName // ignore: cast_nullable_to_non_nullable
as String?,guiderName: freezed == guiderName ? _self.guiderName : guiderName // ignore: cast_nullable_to_non_nullable
as String?,rotatorName: freezed == rotatorName ? _self.rotatorName : rotatorName // ignore: cast_nullable_to_non_nullable
as String?,safetyMonitorName: freezed == safetyMonitorName ? _self.safetyMonitorName : safetyMonitorName // ignore: cast_nullable_to_non_nullable
as String?,switchName: freezed == switchName ? _self.switchName : switchName // ignore: cast_nullable_to_non_nullable
as String?,telescopeName: freezed == telescopeName ? _self.telescopeName : telescopeName // ignore: cast_nullable_to_non_nullable
as String?,telescopeFocalLength: null == telescopeFocalLength ? _self.telescopeFocalLength : telescopeFocalLength // ignore: cast_nullable_to_non_nullable
as double,telescopeAperture: null == telescopeAperture ? _self.telescopeAperture : telescopeAperture // ignore: cast_nullable_to_non_nullable
as double,profileIcon: freezed == profileIcon ? _self.profileIcon : profileIcon // ignore: cast_nullable_to_non_nullable
as String?,profileColor: freezed == profileColor ? _self.profileColor : profileColor // ignore: cast_nullable_to_non_nullable
as int?,sortOrder: null == sortOrder ? _self.sortOrder : sortOrder // ignore: cast_nullable_to_non_nullable
as int,isDefault: null == isDefault ? _self.isDefault : isDefault // ignore: cast_nullable_to_non_nullable
as bool,createdAt: freezed == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime?,updatedAt: freezed == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,isActive: null == isActive ? _self.isActive : isActive // ignore: cast_nullable_to_non_nullable
as bool,pixelSize: freezed == pixelSize ? _self.pixelSize : pixelSize // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}


}

// dart format on
