const Object _unset = Object();

// BEGIN GENERATED equipment-profile wire
// dart format off
/// The REST `/api/profiles` body of an equipment profile.
class EquipmentProfile {
  const EquipmentProfile({
    required this.id,
    required this.name,
    this.description,
    this.cameraId,
    this.mountId,
    this.focuserId,
    this.filterWheelId,
    this.guiderId,
    this.guideCameraId,
    this.guideFocalLength,
    this.rotatorId,
    this.domeId,
    this.weatherId,
    this.safetyMonitorId,
    this.switchId,
    this.coverCalibratorId,
    this.focalLength = 0.0,
    this.aperture = 0.0,
    this.focalRatio,
    this.defaultGain,
    this.defaultOffset,
    this.defaultReadoutMode,
    this.defaultBinX = 1,
    this.defaultBinY = 1,
    this.defaultCoolingTemp,
    this.coolOnConnect = false,
    this.defaultCenteringExposure,
    this.filterNames,
    this.filterFocusOffsets,
    this.meridianFlipOverrides,
    this.cameraName,
    this.mountName,
    this.focuserName,
    this.filterWheelName,
    this.guiderName,
    this.guideCameraName,
    this.rotatorName,
    this.safetyMonitorName,
    this.switchName,
    this.telescopeName,
    this.telescopeFocalLength = 0.0,
    this.telescopeAperture = 0.0,
    this.profileIcon,
    this.profileColor,
    this.sortOrder = 0,
    this.isDefault = false,
    this.createdAt,
    this.updatedAt,
    this.isActive = false,
    this.pixelSize,
  });

  factory EquipmentProfile.fromJson(Map<String, dynamic> json) =>
      EquipmentProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        cameraId: json['cameraId'] as String?,
        mountId: json['mountId'] as String?,
        focuserId: json['focuserId'] as String?,
        filterWheelId: json['filterWheelId'] as String?,
        guiderId: json['guiderId'] as String?,
        guideCameraId: json['guideCameraId'] as String?,
        guideFocalLength: (json['guideFocalLength'] as num?)?.toDouble(),
        rotatorId: json['rotatorId'] as String?,
        domeId: json['domeId'] as String?,
        weatherId: json['weatherId'] as String?,
        safetyMonitorId: json['safetyMonitorId'] as String?,
        switchId: json['switchId'] as String?,
        coverCalibratorId: json['coverCalibratorId'] as String?,
        focalLength: (json['focalLength'] as num?)?.toDouble() ?? 0.0,
        aperture: (json['aperture'] as num?)?.toDouble() ?? 0.0,
        focalRatio: (json['focalRatio'] as num?)?.toDouble(),
        defaultGain: (json['defaultGain'] as num?)?.toInt(),
        defaultOffset: (json['defaultOffset'] as num?)?.toInt(),
        defaultReadoutMode: json['defaultReadoutMode'] as String?,
        defaultBinX: (json['defaultBinX'] as num?)?.toInt() ?? 1,
        defaultBinY: (json['defaultBinY'] as num?)?.toInt() ?? 1,
        defaultCoolingTemp: (json['defaultCoolingTemp'] as num?)?.toDouble(),
        coolOnConnect: json['coolOnConnect'] as bool? ?? false,
        defaultCenteringExposure: (json['defaultCenteringExposure'] as num?)?.toDouble(),
        filterNames: json['filterNames'] as String?,
        filterFocusOffsets: json['filterFocusOffsets'] as String?,
        meridianFlipOverrides: json['meridianFlipOverrides'] as String?,
        cameraName: json['cameraName'] as String?,
        mountName: json['mountName'] as String?,
        focuserName: json['focuserName'] as String?,
        filterWheelName: json['filterWheelName'] as String?,
        guiderName: json['guiderName'] as String?,
        guideCameraName: json['guideCameraName'] as String?,
        rotatorName: json['rotatorName'] as String?,
        safetyMonitorName: json['safetyMonitorName'] as String?,
        switchName: json['switchName'] as String?,
        telescopeName: json['telescopeName'] as String?,
        telescopeFocalLength: (json['telescopeFocalLength'] as num?)?.toDouble() ?? 0.0,
        telescopeAperture: (json['telescopeAperture'] as num?)?.toDouble() ?? 0.0,
        profileIcon: json['profileIcon'] as String?,
        profileColor: (json['profileColor'] as num?)?.toInt(),
        sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
        isDefault: json['isDefault'] as bool? ?? false,
        createdAt: json['createdAt'] == null ? null : DateTime.parse(json['createdAt'] as String),
        updatedAt: json['updatedAt'] == null ? null : DateTime.parse(json['updatedAt'] as String),
        isActive: json['isActive'] as bool? ?? false,
        pixelSize: (json['pixelSize'] as num?)?.toDouble(),
      );

  final String id;
  final String name;
  final String? description;
  final String? cameraId;
  final String? mountId;
  final String? focuserId;
  final String? filterWheelId;
  final String? guiderId;
  final String? guideCameraId;
  final double? guideFocalLength;
  final String? rotatorId;
  final String? domeId;
  final String? weatherId;
  final String? safetyMonitorId;
  final String? switchId;
  final String? coverCalibratorId;
  final double focalLength;
  final double aperture;
  final double? focalRatio;
  final int? defaultGain;
  final int? defaultOffset;
  final String? defaultReadoutMode;
  final int defaultBinX;
  final int defaultBinY;
  final double? defaultCoolingTemp;
  final bool coolOnConnect;
  final double? defaultCenteringExposure;
  final String? filterNames;
  final String? filterFocusOffsets;
  final String? meridianFlipOverrides;
  final String? cameraName;
  final String? mountName;
  final String? focuserName;
  final String? filterWheelName;
  final String? guiderName;
  final String? guideCameraName;
  final String? rotatorName;
  final String? safetyMonitorName;
  final String? switchName;
  final String? telescopeName;
  final double telescopeFocalLength;
  final double telescopeAperture;
  final String? profileIcon;
  final int? profileColor;
  final int sortOrder;
  final bool isDefault;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool isActive;
  final double? pixelSize;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'description': description,
    'cameraId': cameraId,
    'mountId': mountId,
    'focuserId': focuserId,
    'filterWheelId': filterWheelId,
    'guiderId': guiderId,
    'guideCameraId': guideCameraId,
    'guideFocalLength': guideFocalLength,
    'rotatorId': rotatorId,
    'domeId': domeId,
    'weatherId': weatherId,
    'safetyMonitorId': safetyMonitorId,
    'switchId': switchId,
    'coverCalibratorId': coverCalibratorId,
    'focalLength': focalLength,
    'aperture': aperture,
    'focalRatio': focalRatio,
    'defaultGain': defaultGain,
    'defaultOffset': defaultOffset,
    'defaultReadoutMode': defaultReadoutMode,
    'defaultBinX': defaultBinX,
    'defaultBinY': defaultBinY,
    'defaultCoolingTemp': defaultCoolingTemp,
    'coolOnConnect': coolOnConnect,
    'defaultCenteringExposure': defaultCenteringExposure,
    'filterNames': filterNames,
    'filterFocusOffsets': filterFocusOffsets,
    'meridianFlipOverrides': meridianFlipOverrides,
    'cameraName': cameraName,
    'mountName': mountName,
    'focuserName': focuserName,
    'filterWheelName': filterWheelName,
    'guiderName': guiderName,
    'guideCameraName': guideCameraName,
    'rotatorName': rotatorName,
    'safetyMonitorName': safetyMonitorName,
    'switchName': switchName,
    'telescopeName': telescopeName,
    'telescopeFocalLength': telescopeFocalLength,
    'telescopeAperture': telescopeAperture,
    'profileIcon': profileIcon,
    'profileColor': profileColor,
    'sortOrder': sortOrder,
    'isDefault': isDefault,
    'createdAt': createdAt?.toIso8601String(),
    'updatedAt': updatedAt?.toIso8601String(),
    'isActive': isActive,
    'pixelSize': pixelSize,
  };

  /// A copy with the given fields replaced. A nullable field is
  /// cleared by passing null and kept by leaving it out.
  EquipmentProfile copyWith({
    String? id,
    String? name,
    Object? description = _unset,
    Object? cameraId = _unset,
    Object? mountId = _unset,
    Object? focuserId = _unset,
    Object? filterWheelId = _unset,
    Object? guiderId = _unset,
    Object? guideCameraId = _unset,
    Object? guideFocalLength = _unset,
    Object? rotatorId = _unset,
    Object? domeId = _unset,
    Object? weatherId = _unset,
    Object? safetyMonitorId = _unset,
    Object? switchId = _unset,
    Object? coverCalibratorId = _unset,
    double? focalLength,
    double? aperture,
    Object? focalRatio = _unset,
    Object? defaultGain = _unset,
    Object? defaultOffset = _unset,
    Object? defaultReadoutMode = _unset,
    int? defaultBinX,
    int? defaultBinY,
    Object? defaultCoolingTemp = _unset,
    bool? coolOnConnect,
    Object? defaultCenteringExposure = _unset,
    Object? filterNames = _unset,
    Object? filterFocusOffsets = _unset,
    Object? meridianFlipOverrides = _unset,
    Object? cameraName = _unset,
    Object? mountName = _unset,
    Object? focuserName = _unset,
    Object? filterWheelName = _unset,
    Object? guiderName = _unset,
    Object? guideCameraName = _unset,
    Object? rotatorName = _unset,
    Object? safetyMonitorName = _unset,
    Object? switchName = _unset,
    Object? telescopeName = _unset,
    double? telescopeFocalLength,
    double? telescopeAperture,
    Object? profileIcon = _unset,
    Object? profileColor = _unset,
    int? sortOrder,
    bool? isDefault,
    Object? createdAt = _unset,
    Object? updatedAt = _unset,
    bool? isActive,
    Object? pixelSize = _unset,
  }) {
    return EquipmentProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      description: identical(description, _unset) ? this.description : description as String?,
      cameraId: identical(cameraId, _unset) ? this.cameraId : cameraId as String?,
      mountId: identical(mountId, _unset) ? this.mountId : mountId as String?,
      focuserId: identical(focuserId, _unset) ? this.focuserId : focuserId as String?,
      filterWheelId: identical(filterWheelId, _unset) ? this.filterWheelId : filterWheelId as String?,
      guiderId: identical(guiderId, _unset) ? this.guiderId : guiderId as String?,
      guideCameraId: identical(guideCameraId, _unset) ? this.guideCameraId : guideCameraId as String?,
      guideFocalLength: identical(guideFocalLength, _unset) ? this.guideFocalLength : guideFocalLength as double?,
      rotatorId: identical(rotatorId, _unset) ? this.rotatorId : rotatorId as String?,
      domeId: identical(domeId, _unset) ? this.domeId : domeId as String?,
      weatherId: identical(weatherId, _unset) ? this.weatherId : weatherId as String?,
      safetyMonitorId: identical(safetyMonitorId, _unset) ? this.safetyMonitorId : safetyMonitorId as String?,
      switchId: identical(switchId, _unset) ? this.switchId : switchId as String?,
      coverCalibratorId: identical(coverCalibratorId, _unset) ? this.coverCalibratorId : coverCalibratorId as String?,
      focalLength: focalLength ?? this.focalLength,
      aperture: aperture ?? this.aperture,
      focalRatio: identical(focalRatio, _unset) ? this.focalRatio : focalRatio as double?,
      defaultGain: identical(defaultGain, _unset) ? this.defaultGain : defaultGain as int?,
      defaultOffset: identical(defaultOffset, _unset) ? this.defaultOffset : defaultOffset as int?,
      defaultReadoutMode: identical(defaultReadoutMode, _unset) ? this.defaultReadoutMode : defaultReadoutMode as String?,
      defaultBinX: defaultBinX ?? this.defaultBinX,
      defaultBinY: defaultBinY ?? this.defaultBinY,
      defaultCoolingTemp: identical(defaultCoolingTemp, _unset) ? this.defaultCoolingTemp : defaultCoolingTemp as double?,
      coolOnConnect: coolOnConnect ?? this.coolOnConnect,
      defaultCenteringExposure: identical(defaultCenteringExposure, _unset) ? this.defaultCenteringExposure : defaultCenteringExposure as double?,
      filterNames: identical(filterNames, _unset) ? this.filterNames : filterNames as String?,
      filterFocusOffsets: identical(filterFocusOffsets, _unset) ? this.filterFocusOffsets : filterFocusOffsets as String?,
      meridianFlipOverrides: identical(meridianFlipOverrides, _unset) ? this.meridianFlipOverrides : meridianFlipOverrides as String?,
      cameraName: identical(cameraName, _unset) ? this.cameraName : cameraName as String?,
      mountName: identical(mountName, _unset) ? this.mountName : mountName as String?,
      focuserName: identical(focuserName, _unset) ? this.focuserName : focuserName as String?,
      filterWheelName: identical(filterWheelName, _unset) ? this.filterWheelName : filterWheelName as String?,
      guiderName: identical(guiderName, _unset) ? this.guiderName : guiderName as String?,
      guideCameraName: identical(guideCameraName, _unset) ? this.guideCameraName : guideCameraName as String?,
      rotatorName: identical(rotatorName, _unset) ? this.rotatorName : rotatorName as String?,
      safetyMonitorName: identical(safetyMonitorName, _unset) ? this.safetyMonitorName : safetyMonitorName as String?,
      switchName: identical(switchName, _unset) ? this.switchName : switchName as String?,
      telescopeName: identical(telescopeName, _unset) ? this.telescopeName : telescopeName as String?,
      telescopeFocalLength: telescopeFocalLength ?? this.telescopeFocalLength,
      telescopeAperture: telescopeAperture ?? this.telescopeAperture,
      profileIcon: identical(profileIcon, _unset) ? this.profileIcon : profileIcon as String?,
      profileColor: identical(profileColor, _unset) ? this.profileColor : profileColor as int?,
      sortOrder: sortOrder ?? this.sortOrder,
      isDefault: isDefault ?? this.isDefault,
      createdAt: identical(createdAt, _unset) ? this.createdAt : createdAt as DateTime?,
      updatedAt: identical(updatedAt, _unset) ? this.updatedAt : updatedAt as DateTime?,
      isActive: isActive ?? this.isActive,
      pixelSize: identical(pixelSize, _unset) ? this.pixelSize : pixelSize as double?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EquipmentProfile &&
          other.runtimeType == runtimeType
          && other.id == id
          && other.name == name
          && other.description == description
          && other.cameraId == cameraId
          && other.mountId == mountId
          && other.focuserId == focuserId
          && other.filterWheelId == filterWheelId
          && other.guiderId == guiderId
          && other.guideCameraId == guideCameraId
          && other.guideFocalLength == guideFocalLength
          && other.rotatorId == rotatorId
          && other.domeId == domeId
          && other.weatherId == weatherId
          && other.safetyMonitorId == safetyMonitorId
          && other.switchId == switchId
          && other.coverCalibratorId == coverCalibratorId
          && other.focalLength == focalLength
          && other.aperture == aperture
          && other.focalRatio == focalRatio
          && other.defaultGain == defaultGain
          && other.defaultOffset == defaultOffset
          && other.defaultReadoutMode == defaultReadoutMode
          && other.defaultBinX == defaultBinX
          && other.defaultBinY == defaultBinY
          && other.defaultCoolingTemp == defaultCoolingTemp
          && other.coolOnConnect == coolOnConnect
          && other.defaultCenteringExposure == defaultCenteringExposure
          && other.filterNames == filterNames
          && other.filterFocusOffsets == filterFocusOffsets
          && other.meridianFlipOverrides == meridianFlipOverrides
          && other.cameraName == cameraName
          && other.mountName == mountName
          && other.focuserName == focuserName
          && other.filterWheelName == filterWheelName
          && other.guiderName == guiderName
          && other.guideCameraName == guideCameraName
          && other.rotatorName == rotatorName
          && other.safetyMonitorName == safetyMonitorName
          && other.switchName == switchName
          && other.telescopeName == telescopeName
          && other.telescopeFocalLength == telescopeFocalLength
          && other.telescopeAperture == telescopeAperture
          && other.profileIcon == profileIcon
          && other.profileColor == profileColor
          && other.sortOrder == sortOrder
          && other.isDefault == isDefault
          && other.createdAt == createdAt
          && other.updatedAt == updatedAt
          && other.isActive == isActive
          && other.pixelSize == pixelSize
      );

  @override
  int get hashCode => Object.hashAll([
    runtimeType,
    id,
    name,
    description,
    cameraId,
    mountId,
    focuserId,
    filterWheelId,
    guiderId,
    guideCameraId,
    guideFocalLength,
    rotatorId,
    domeId,
    weatherId,
    safetyMonitorId,
    switchId,
    coverCalibratorId,
    focalLength,
    aperture,
    focalRatio,
    defaultGain,
    defaultOffset,
    defaultReadoutMode,
    defaultBinX,
    defaultBinY,
    defaultCoolingTemp,
    coolOnConnect,
    defaultCenteringExposure,
    filterNames,
    filterFocusOffsets,
    meridianFlipOverrides,
    cameraName,
    mountName,
    focuserName,
    filterWheelName,
    guiderName,
    guideCameraName,
    rotatorName,
    safetyMonitorName,
    switchName,
    telescopeName,
    telescopeFocalLength,
    telescopeAperture,
    profileIcon,
    profileColor,
    sortOrder,
    isDefault,
    createdAt,
    updatedAt,
    isActive,
    pixelSize,
  ]);

  @override
  String toString() =>
      'EquipmentProfile('
      'id: $id, '
      'name: $name, '
      'description: $description, '
      'cameraId: $cameraId, '
      'mountId: $mountId, '
      'focuserId: $focuserId, '
      'filterWheelId: $filterWheelId, '
      'guiderId: $guiderId, '
      'guideCameraId: $guideCameraId, '
      'guideFocalLength: $guideFocalLength, '
      'rotatorId: $rotatorId, '
      'domeId: $domeId, '
      'weatherId: $weatherId, '
      'safetyMonitorId: $safetyMonitorId, '
      'switchId: $switchId, '
      'coverCalibratorId: $coverCalibratorId, '
      'focalLength: $focalLength, '
      'aperture: $aperture, '
      'focalRatio: $focalRatio, '
      'defaultGain: $defaultGain, '
      'defaultOffset: $defaultOffset, '
      'defaultReadoutMode: $defaultReadoutMode, '
      'defaultBinX: $defaultBinX, '
      'defaultBinY: $defaultBinY, '
      'defaultCoolingTemp: $defaultCoolingTemp, '
      'coolOnConnect: $coolOnConnect, '
      'defaultCenteringExposure: $defaultCenteringExposure, '
      'filterNames: $filterNames, '
      'filterFocusOffsets: $filterFocusOffsets, '
      'meridianFlipOverrides: $meridianFlipOverrides, '
      'cameraName: $cameraName, '
      'mountName: $mountName, '
      'focuserName: $focuserName, '
      'filterWheelName: $filterWheelName, '
      'guiderName: $guiderName, '
      'guideCameraName: $guideCameraName, '
      'rotatorName: $rotatorName, '
      'safetyMonitorName: $safetyMonitorName, '
      'switchName: $switchName, '
      'telescopeName: $telescopeName, '
      'telescopeFocalLength: $telescopeFocalLength, '
      'telescopeAperture: $telescopeAperture, '
      'profileIcon: $profileIcon, '
      'profileColor: $profileColor, '
      'sortOrder: $sortOrder, '
      'isDefault: $isDefault, '
      'createdAt: $createdAt, '
      'updatedAt: $updatedAt, '
      'isActive: $isActive, '
      'pixelSize: $pixelSize)'
      ;
}
// dart format on
// END GENERATED equipment-profile wire

extension EquipmentProfileExtension on EquipmentProfile {
  /// Get effective focal length (uses focalLength if set, otherwise telescopeFocalLength)
  double get effectiveFocalLength {
    return focalLength > 0 ? focalLength : telescopeFocalLength;
  }

  /// Get effective aperture (uses aperture if set, otherwise telescopeAperture)
  double get effectiveAperture {
    return aperture > 0 ? aperture : telescopeAperture;
  }

  double? get computedFocalRatio {
    if (focalRatio != null) return focalRatio;
    final ap = effectiveAperture;
    final fl = effectiveFocalLength;
    if (ap > 0 && fl > 0) {
      return fl / ap;
    }
    return null;
  }
}
