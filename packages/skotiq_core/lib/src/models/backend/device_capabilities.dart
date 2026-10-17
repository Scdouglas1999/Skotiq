/// Device capability types for Skotiq.
///
/// These types mirror the Rust capability structs but are pure Dart types,
/// eliminating the dependency on the FRB bridge types.
library;

/// Mount tracking rates
enum TrackingRate { sidereal, lunar, solar, king, custom }

/// Camera capabilities
class CameraCapabilities {
  final int maxWidth;
  final int maxHeight;
  final int bitDepth;
  final bool hasShutter;
  final bool canSetCcdTemperature;
  final bool canSetCooler;
  final bool canGetCoolerPower;
  final bool canBin;
  final int maxBinX;
  final int maxBinY;
  final bool canAsymmetricBin;
  final bool canSetGain;
  final int? gainMin;
  final int? gainMax;
  final bool canSetOffset;
  final int? offsetMin;
  final int? offsetMax;
  final bool canAbortExposure;
  final bool canStopExposure;
  final bool canSubframe;
  final double? pixelSizeX;
  final double? pixelSizeY;
  final bool isColor;
  final String? bayerPattern;
  final String? sensorType;
  final bool hasFastReadout;
  final List<String> readoutModes;
  final double? exposureMin;
  final double? exposureMax;
  final double? ccdTemperature;
  final double? setCcdTemperature;
  final double? coolerPower;
  final bool? coolerOn;
  final double? coolerMinTempC;
  final double? coolerMaxTempC;

  const CameraCapabilities({
    required this.maxWidth,
    required this.maxHeight,
    required this.bitDepth,
    this.hasShutter = false,
    this.canSetCcdTemperature = false,
    this.canSetCooler = false,
    this.canGetCoolerPower = false,
    this.canBin = false,
    this.maxBinX = 1,
    this.maxBinY = 1,
    this.canAsymmetricBin = false,
    this.canSetGain = false,
    this.gainMin,
    this.gainMax,
    this.canSetOffset = false,
    this.offsetMin,
    this.offsetMax,
    this.canAbortExposure = false,
    this.canStopExposure = false,
    this.canSubframe = false,
    this.pixelSizeX,
    this.pixelSizeY,
    this.isColor = false,
    this.bayerPattern,
    this.sensorType,
    this.hasFastReadout = false,
    this.readoutModes = const [],
    this.exposureMin,
    this.exposureMax,
    this.ccdTemperature,
    this.setCcdTemperature,
    this.coolerPower,
    this.coolerOn,
    this.coolerMinTempC,
    this.coolerMaxTempC,
  });

  factory CameraCapabilities.fromJson(Map<String, dynamic> json) {
    return CameraCapabilities(
      maxWidth: json['maxWidth'] as int? ?? json['max_width'] as int? ?? 0,
      maxHeight: json['maxHeight'] as int? ?? json['max_height'] as int? ?? 0,
      bitDepth: json['bitDepth'] as int? ?? json['bit_depth'] as int? ?? 16,
      hasShutter:
          json['hasShutter'] as bool? ?? json['has_shutter'] as bool? ?? false,
      canSetCcdTemperature:
          json['canSetCcdTemperature'] as bool? ??
          json['can_set_ccd_temperature'] as bool? ??
          false,
      canSetCooler:
          json['canSetCooler'] as bool? ??
          json['can_set_cooler'] as bool? ??
          false,
      canGetCoolerPower:
          json['canGetCoolerPower'] as bool? ??
          json['can_get_cooler_power'] as bool? ??
          false,
      canBin: json['canBin'] as bool? ?? json['can_bin'] as bool? ?? false,
      maxBinX: json['maxBinX'] as int? ?? json['max_bin_x'] as int? ?? 1,
      maxBinY: json['maxBinY'] as int? ?? json['max_bin_y'] as int? ?? 1,
      canAsymmetricBin:
          json['canAsymmetricBin'] as bool? ??
          json['can_asymmetric_bin'] as bool? ??
          false,
      canSetGain:
          json['canSetGain'] as bool? ?? json['can_set_gain'] as bool? ?? false,
      gainMin: json['gainMin'] as int? ?? json['gain_min'] as int?,
      gainMax: json['gainMax'] as int? ?? json['gain_max'] as int?,
      canSetOffset:
          json['canSetOffset'] as bool? ??
          json['can_set_offset'] as bool? ??
          false,
      offsetMin: json['offsetMin'] as int? ?? json['offset_min'] as int?,
      offsetMax: json['offsetMax'] as int? ?? json['offset_max'] as int?,
      canAbortExposure:
          json['canAbortExposure'] as bool? ??
          json['can_abort_exposure'] as bool? ??
          false,
      canStopExposure:
          json['canStopExposure'] as bool? ??
          json['can_stop_exposure'] as bool? ??
          false,
      canSubframe:
          json['canSubframe'] as bool? ??
          json['can_subframe'] as bool? ??
          false,
      pixelSizeX:
          (json['pixelSizeX'] as num?)?.toDouble() ??
          (json['pixel_size_x'] as num?)?.toDouble(),
      pixelSizeY:
          (json['pixelSizeY'] as num?)?.toDouble() ??
          (json['pixel_size_y'] as num?)?.toDouble(),
      isColor: json['isColor'] as bool? ?? json['is_color'] as bool? ?? false,
      bayerPattern:
          json['bayerPattern'] as String? ?? json['bayer_pattern'] as String?,
      sensorType:
          json['sensorType'] as String? ?? json['sensor_type'] as String?,
      hasFastReadout:
          json['hasFastReadout'] as bool? ??
          json['has_fast_readout'] as bool? ??
          false,
      readoutModes:
          (json['readoutModes'] as List? ??
                  json['readout_modes'] as List? ??
                  [])
              .cast<String>(),
      exposureMin:
          (json['exposureMin'] as num?)?.toDouble() ??
          (json['exposure_min'] as num?)?.toDouble(),
      exposureMax:
          (json['exposureMax'] as num?)?.toDouble() ??
          (json['exposure_max'] as num?)?.toDouble(),
      ccdTemperature:
          (json['ccdTemperature'] as num?)?.toDouble() ??
          (json['ccd_temperature'] as num?)?.toDouble(),
      setCcdTemperature:
          (json['setCcdTemperature'] as num?)?.toDouble() ??
          (json['set_ccd_temperature'] as num?)?.toDouble(),
      coolerPower:
          (json['coolerPower'] as num?)?.toDouble() ??
          (json['cooler_power'] as num?)?.toDouble(),
      coolerOn: json['coolerOn'] as bool? ?? json['cooler_on'] as bool?,
      coolerMinTempC:
          (json['coolerMinTempC'] as num?)?.toDouble() ??
          (json['cooler_min_temp_c'] as num?)?.toDouble(),
      coolerMaxTempC:
          (json['coolerMaxTempC'] as num?)?.toDouble() ??
          (json['cooler_max_temp_c'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'maxWidth': maxWidth,
    'maxHeight': maxHeight,
    'bitDepth': bitDepth,
    'hasShutter': hasShutter,
    'canSetCcdTemperature': canSetCcdTemperature,
    'canSetCooler': canSetCooler,
    'canGetCoolerPower': canGetCoolerPower,
    'canBin': canBin,
    'maxBinX': maxBinX,
    'maxBinY': maxBinY,
    'canAsymmetricBin': canAsymmetricBin,
    'canSetGain': canSetGain,
    'gainMin': gainMin,
    'gainMax': gainMax,
    'canSetOffset': canSetOffset,
    'offsetMin': offsetMin,
    'offsetMax': offsetMax,
    'canAbortExposure': canAbortExposure,
    'canStopExposure': canStopExposure,
    'canSubframe': canSubframe,
    'pixelSizeX': pixelSizeX,
    'pixelSizeY': pixelSizeY,
    'isColor': isColor,
    'bayerPattern': bayerPattern,
    'sensorType': sensorType,
    'hasFastReadout': hasFastReadout,
    'readoutModes': readoutModes,
    'exposureMin': exposureMin,
    'exposureMax': exposureMax,
    'ccdTemperature': ccdTemperature,
    'setCcdTemperature': setCcdTemperature,
    'coolerPower': coolerPower,
    'coolerOn': coolerOn,
    'coolerMinTempC': coolerMinTempC,
    'coolerMaxTempC': coolerMaxTempC,
  };
}

/// Mount capabilities
class MountCapabilities {
  final bool canSlew;
  final bool canSlewAsync;
  final bool canSync;
  final bool canPark;
  final bool canUnpark;
  final bool canSetPark;
  final bool canPulseGuide;
  final bool canGetSideOfPier;
  final bool canSetSideOfPier;
  final bool canSetTracking;
  final bool canSetTrackingRate;
  final List<TrackingRate> supportedTrackingRates;
  final bool isEquatorial;
  final bool supportsAltAz;
  final bool canGetPointingState;
  final bool canFindHome;
  final bool? tracking;
  final TrackingRate? trackingRate;
  final bool canAbortSlew;
  final double? maxSlewRate;
  final bool canMoveAxis;
  final int axisCount;
  final double? minPulseGuideMs;
  final double? maxPulseGuideMs;

  const MountCapabilities({
    this.canSlew = false,
    this.canSlewAsync = false,
    this.canSync = false,
    this.canPark = false,
    this.canUnpark = false,
    this.canSetPark = false,
    this.canPulseGuide = false,
    this.canGetSideOfPier = false,
    this.canSetSideOfPier = false,
    this.canSetTracking = false,
    this.canSetTrackingRate = false,
    this.supportedTrackingRates = const [],
    this.isEquatorial = false,
    this.supportsAltAz = false,
    this.canGetPointingState = false,
    this.canFindHome = false,
    this.tracking,
    this.trackingRate,
    this.canAbortSlew = false,
    this.maxSlewRate,
    this.canMoveAxis = false,
    this.axisCount = 2,
    this.minPulseGuideMs,
    this.maxPulseGuideMs,
  });

  factory MountCapabilities.fromJson(Map<String, dynamic> json) {
    return MountCapabilities(
      canSlew: json['canSlew'] as bool? ?? json['can_slew'] as bool? ?? false,
      canSlewAsync:
          json['canSlewAsync'] as bool? ??
          json['can_slew_async'] as bool? ??
          false,
      canSync: json['canSync'] as bool? ?? json['can_sync'] as bool? ?? false,
      canPark: json['canPark'] as bool? ?? json['can_park'] as bool? ?? false,
      canUnpark:
          json['canUnpark'] as bool? ?? json['can_unpark'] as bool? ?? false,
      canSetPark:
          json['canSetPark'] as bool? ?? json['can_set_park'] as bool? ?? false,
      canPulseGuide:
          json['canPulseGuide'] as bool? ??
          json['can_pulse_guide'] as bool? ??
          false,
      canGetSideOfPier:
          json['canGetSideOfPier'] as bool? ??
          json['can_get_side_of_pier'] as bool? ??
          false,
      canSetSideOfPier:
          json['canSetSideOfPier'] as bool? ??
          json['can_set_side_of_pier'] as bool? ??
          false,
      canSetTracking:
          json['canSetTracking'] as bool? ??
          json['can_set_tracking'] as bool? ??
          false,
      canSetTrackingRate:
          json['canSetTrackingRate'] as bool? ??
          json['can_set_tracking_rate'] as bool? ??
          false,
      supportedTrackingRates: _parseTrackingRates(
        json['supportedTrackingRates'] ?? json['supported_tracking_rates'],
      ),
      isEquatorial:
          json['isEquatorial'] as bool? ??
          json['is_equatorial'] as bool? ??
          false,
      supportsAltAz:
          json['supportsAltAz'] as bool? ??
          json['supports_alt_az'] as bool? ??
          false,
      canGetPointingState:
          json['canGetPointingState'] as bool? ??
          json['can_get_pointing_state'] as bool? ??
          false,
      canFindHome:
          json['canFindHome'] as bool? ??
          json['can_find_home'] as bool? ??
          false,
      tracking: json['tracking'] as bool?,
      trackingRate: _parseTrackingRate(
        json['trackingRate'] ?? json['tracking_rate'],
      ),
      canAbortSlew:
          json['canAbortSlew'] as bool? ??
          json['can_abort_slew'] as bool? ??
          false,
      maxSlewRate:
          (json['maxSlewRate'] as num?)?.toDouble() ??
          (json['max_slew_rate'] as num?)?.toDouble(),
      canMoveAxis:
          json['canMoveAxis'] as bool? ??
          json['can_move_axis'] as bool? ??
          false,
      axisCount: json['axisCount'] as int? ?? json['axis_count'] as int? ?? 2,
      minPulseGuideMs:
          (json['minPulseGuideMs'] as num?)?.toDouble() ??
          (json['min_pulse_guide_ms'] as num?)?.toDouble(),
      maxPulseGuideMs:
          (json['maxPulseGuideMs'] as num?)?.toDouble() ??
          (json['max_pulse_guide_ms'] as num?)?.toDouble(),
    );
  }

  static List<TrackingRate> _parseTrackingRates(dynamic list) {
    if (list == null) return [];
    return (list as List)
        .map((e) => _parseTrackingRate(e) ?? TrackingRate.sidereal)
        .toList();
  }

  static TrackingRate? _parseTrackingRate(dynamic value) {
    if (value == null) return null;
    final str = value.toString().toLowerCase();
    return switch (str) {
      'sidereal' => TrackingRate.sidereal,
      'lunar' => TrackingRate.lunar,
      'solar' => TrackingRate.solar,
      'king' => TrackingRate.king,
      'custom' => TrackingRate.custom,
      _ => null,
    };
  }

  Map<String, dynamic> toJson() => {
    'canSlew': canSlew,
    'canSlewAsync': canSlewAsync,
    'canSync': canSync,
    'canPark': canPark,
    'canUnpark': canUnpark,
    'canSetPark': canSetPark,
    'canPulseGuide': canPulseGuide,
    'canGetSideOfPier': canGetSideOfPier,
    'canSetSideOfPier': canSetSideOfPier,
    'canSetTracking': canSetTracking,
    'canSetTrackingRate': canSetTrackingRate,
    'supportedTrackingRates': supportedTrackingRates
        .map((e) => e.name)
        .toList(),
    'isEquatorial': isEquatorial,
    'supportsAltAz': supportsAltAz,
    'canGetPointingState': canGetPointingState,
    'canFindHome': canFindHome,
    'tracking': tracking,
    'trackingRate': trackingRate?.name,
    'canAbortSlew': canAbortSlew,
    'maxSlewRate': maxSlewRate,
    'canMoveAxis': canMoveAxis,
    'axisCount': axisCount,
    'minPulseGuideMs': minPulseGuideMs,
    'maxPulseGuideMs': maxPulseGuideMs,
  };
}

/// Focuser capabilities
class FocuserCapabilities {
  final int maxPosition;
  final int maxIncrement;
  final double? stepSize;
  final bool absolute;
  final bool tempCompAvailable;
  final bool tempComp;
  final double? temperature;
  final bool isMoving;
  final int? position;
  final bool canHalt;
  final bool canReverse;
  final bool? reverse;

  const FocuserCapabilities({
    required this.maxPosition,
    required this.maxIncrement,
    this.stepSize,
    this.absolute = false,
    this.tempCompAvailable = false,
    this.tempComp = false,
    this.temperature,
    this.isMoving = false,
    this.position,
    this.canHalt = false,
    this.canReverse = false,
    this.reverse,
  });

  factory FocuserCapabilities.fromJson(Map<String, dynamic> json) {
    return FocuserCapabilities(
      maxPosition:
          json['maxPosition'] as int? ?? json['max_position'] as int? ?? 0,
      maxIncrement:
          json['maxIncrement'] as int? ?? json['max_increment'] as int? ?? 0,
      stepSize:
          (json['stepSize'] as num?)?.toDouble() ??
          (json['step_size'] as num?)?.toDouble(),
      absolute: json['absolute'] as bool? ?? false,
      tempCompAvailable:
          json['tempCompAvailable'] as bool? ??
          json['temp_comp_available'] as bool? ??
          false,
      tempComp:
          json['tempComp'] as bool? ?? json['temp_comp'] as bool? ?? false,
      temperature: (json['temperature'] as num?)?.toDouble(),
      isMoving:
          json['isMoving'] as bool? ?? json['is_moving'] as bool? ?? false,
      position: json['position'] as int?,
      canHalt: json['canHalt'] as bool? ?? json['can_halt'] as bool? ?? false,
      canReverse:
          json['canReverse'] as bool? ?? json['can_reverse'] as bool? ?? false,
      reverse: json['reverse'] as bool?,
    );
  }

  Map<String, dynamic> toJson() => {
    'maxPosition': maxPosition,
    'maxIncrement': maxIncrement,
    'stepSize': stepSize,
    'absolute': absolute,
    'tempCompAvailable': tempCompAvailable,
    'tempComp': tempComp,
    'temperature': temperature,
    'isMoving': isMoving,
    'position': position,
    'canHalt': canHalt,
    'canReverse': canReverse,
    'reverse': reverse,
  };
}

/// Filter wheel capabilities
class FilterWheelCapabilities {
  final int positionCount;
  final int? currentPosition;
  final List<String> filterNames;
  final List<int> focusOffsets;
  final bool isMoving;
  final bool canSetFilterNames;
  final bool canSetFocusOffsets;

  const FilterWheelCapabilities({
    required this.positionCount,
    this.currentPosition,
    this.filterNames = const [],
    this.focusOffsets = const [],
    this.isMoving = false,
    this.canSetFilterNames = false,
    this.canSetFocusOffsets = false,
  });

  factory FilterWheelCapabilities.fromJson(Map<String, dynamic> json) {
    return FilterWheelCapabilities(
      positionCount:
          json['positionCount'] as int? ?? json['position_count'] as int? ?? 0,
      currentPosition:
          json['currentPosition'] as int? ?? json['current_position'] as int?,
      filterNames:
          (json['filterNames'] as List? ?? json['filter_names'] as List? ?? [])
              .cast<String>(),
      focusOffsets:
          (json['focusOffsets'] as List? ??
                  json['focus_offsets'] as List? ??
                  [])
              .cast<int>(),
      isMoving:
          json['isMoving'] as bool? ?? json['is_moving'] as bool? ?? false,
      canSetFilterNames:
          json['canSetFilterNames'] as bool? ??
          json['can_set_filter_names'] as bool? ??
          false,
      canSetFocusOffsets:
          json['canSetFocusOffsets'] as bool? ??
          json['can_set_focus_offsets'] as bool? ??
          false,
    );
  }

  Map<String, dynamic> toJson() => {
    'positionCount': positionCount,
    'currentPosition': currentPosition,
    'filterNames': filterNames,
    'focusOffsets': focusOffsets,
    'isMoving': isMoving,
    'canSetFilterNames': canSetFilterNames,
    'canSetFocusOffsets': canSetFocusOffsets,
  };
}

/// Rotator capabilities
class RotatorCapabilities {
  final bool canReverse;
  final bool reverse;
  final double? stepSize;
  final bool isMoving;
  final double? mechanicalPosition;
  final double? position;
  final bool canMoveAbsolute;
  final bool canHalt;
  final bool canSync;
  final double? minAngleDeg;
  final double? maxAngleDeg;

  const RotatorCapabilities({
    this.canReverse = false,
    this.reverse = false,
    this.stepSize,
    this.isMoving = false,
    this.mechanicalPosition,
    this.position,
    this.canMoveAbsolute = false,
    this.canHalt = false,
    this.canSync = false,
    this.minAngleDeg,
    this.maxAngleDeg,
  });

  factory RotatorCapabilities.fromJson(Map<String, dynamic> json) {
    return RotatorCapabilities(
      canReverse:
          json['canReverse'] as bool? ?? json['can_reverse'] as bool? ?? false,
      reverse: json['reverse'] as bool? ?? false,
      stepSize:
          (json['stepSize'] as num?)?.toDouble() ??
          (json['step_size'] as num?)?.toDouble(),
      isMoving:
          json['isMoving'] as bool? ?? json['is_moving'] as bool? ?? false,
      mechanicalPosition:
          (json['mechanicalPosition'] as num?)?.toDouble() ??
          (json['mechanical_position'] as num?)?.toDouble(),
      position: (json['position'] as num?)?.toDouble(),
      canMoveAbsolute:
          json['canMoveAbsolute'] as bool? ??
          json['can_move_absolute'] as bool? ??
          false,
      canHalt: json['canHalt'] as bool? ?? json['can_halt'] as bool? ?? false,
      canSync: json['canSync'] as bool? ?? json['can_sync'] as bool? ?? false,
      minAngleDeg:
          (json['minAngleDeg'] as num?)?.toDouble() ??
          (json['min_angle_deg'] as num?)?.toDouble(),
      maxAngleDeg:
          (json['maxAngleDeg'] as num?)?.toDouble() ??
          (json['max_angle_deg'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'canReverse': canReverse,
    'reverse': reverse,
    'stepSize': stepSize,
    'isMoving': isMoving,
    'mechanicalPosition': mechanicalPosition,
    'position': position,
    'canMoveAbsolute': canMoveAbsolute,
    'canHalt': canHalt,
    'canSync': canSync,
    'minAngleDeg': minAngleDeg,
    'maxAngleDeg': maxAngleDeg,
  };
}

/// Dome capabilities
///
/// Mirrors the Rust `DomeCapabilities` struct exposed by
/// `bridge::device_capabilities::DomeCapabilities`. Added for to
/// drive capability-gated UI on dome controls (shutter, parking, slewing,
/// sync). Only flag fields are required for gating; dynamic state fields
/// (azimuth, slewing, etc.) are not exposed because the existing
/// `domeStateProvider` already provides live status.
class DomeCapabilities {
  final bool canSetAzimuth;
  final bool canPark;
  final bool canFindHome;
  final bool canSetShutter;
  final bool canSyncAzimuth;
  final bool canSlave;
  final bool canAbort;

  const DomeCapabilities({
    this.canSetAzimuth = false,
    this.canPark = false,
    this.canFindHome = false,
    this.canSetShutter = false,
    this.canSyncAzimuth = false,
    this.canSlave = false,
    this.canAbort = false,
  });

  factory DomeCapabilities.fromJson(Map<String, dynamic> json) {
    return DomeCapabilities(
      canSetAzimuth:
          json['canSetAzimuth'] as bool? ??
          json['can_set_azimuth'] as bool? ??
          false,
      canPark: json['canPark'] as bool? ?? json['can_park'] as bool? ?? false,
      canFindHome:
          json['canFindHome'] as bool? ??
          json['can_find_home'] as bool? ??
          false,
      canSetShutter:
          json['canSetShutter'] as bool? ??
          json['can_set_shutter'] as bool? ??
          false,
      canSyncAzimuth:
          json['canSyncAzimuth'] as bool? ??
          json['can_sync_azimuth'] as bool? ??
          false,
      canSlave:
          json['canSlave'] as bool? ?? json['can_slave'] as bool? ?? false,
      canAbort:
          json['canAbort'] as bool? ?? json['can_abort'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'canSetAzimuth': canSetAzimuth,
    'canPark': canPark,
    'canFindHome': canFindHome,
    'canSetShutter': canSetShutter,
    'canSyncAzimuth': canSyncAzimuth,
    'canSlave': canSlave,
    'canAbort': canAbort,
  };
}
