/// Typed device status models for Skotiq equipment.
///
/// These models provide type-safe access to device status information
/// returned from the backend, replacing dynamic/Map-based access patterns.
library;

import 'device_capabilities.dart' show TrackingRate;
import 'device_types.dart' show CameraState, PierSide;

// Camera status

/// Current status of a connected camera
class CameraStatus {
  final bool connected;
  final CameraState state;
  final double? sensorTemp;
  final double? coolerPower;
  final double? targetTemp;
  final bool coolerOn;
  final int gain;
  final int offset;
  final int binX;
  final int binY;
  final int sensorWidth;
  final int sensorHeight;
  final double pixelSizeX;
  final double pixelSizeY;
  final int maxAdu;
  final bool canCool;
  final bool canSetGain;
  final bool canSetOffset;

  const CameraStatus({
    required this.connected,
    required this.state,
    this.sensorTemp,
    this.coolerPower,
    this.targetTemp,
    required this.coolerOn,
    required this.gain,
    required this.offset,
    required this.binX,
    required this.binY,
    required this.sensorWidth,
    required this.sensorHeight,
    required this.pixelSizeX,
    required this.pixelSizeY,
    required this.maxAdu,
    required this.canCool,
    required this.canSetGain,
    required this.canSetOffset,
  });

  /// Create from JSON (for network transport)
  factory CameraStatus.fromJson(Map<String, dynamic> json) {
    return CameraStatus(
      connected: json['connected'] as bool? ?? false,
      state: _parseCameraState(json['state']),
      sensorTemp:
          (json['sensor_temp'] ?? json['sensorTemp'] ?? json['temperature'])
              ?.toDouble(),
      coolerPower: (json['cooler_power'] ?? json['coolerPower'])?.toDouble(),
      targetTemp:
          (json['target_temp'] ?? json['targetTemp'] ?? json['setpoint'])
              ?.toDouble(),
      coolerOn: json['cooler_on'] ?? json['coolerOn'] ?? false,
      gain: json['gain'] as int? ?? 0,
      offset: json['offset'] as int? ?? 0,
      binX: (json['bin_x'] ?? json['binX']) as int? ?? 1,
      binY: (json['bin_y'] ?? json['binY']) as int? ?? 1,
      sensorWidth: (json['sensor_width'] ?? json['sensorWidth']) as int? ?? 0,
      sensorHeight:
          (json['sensor_height'] ?? json['sensorHeight']) as int? ?? 0,
      pixelSizeX:
          (json['pixel_size_x'] ?? json['pixelSizeX'])?.toDouble() ?? 0.0,
      pixelSizeY:
          (json['pixel_size_y'] ?? json['pixelSizeY'])?.toDouble() ?? 0.0,
      maxAdu: (json['max_adu'] ?? json['maxAdu']) as int? ?? 65535,
      canCool: json['can_cool'] ?? json['canCool'] ?? false,
      canSetGain: json['can_set_gain'] ?? json['canSetGain'] ?? false,
      canSetOffset: json['can_set_offset'] ?? json['canSetOffset'] ?? false,
    );
  }

  /// Convert to JSON (for network transport)
  Map<String, dynamic> toJson() => {
    'connected': connected,
    'state': state.name,
    'sensorTemp': sensorTemp,
    'coolerPower': coolerPower,
    'targetTemp': targetTemp,
    'coolerOn': coolerOn,
    'gain': gain,
    'offset': offset,
    'binX': binX,
    'binY': binY,
    'sensorWidth': sensorWidth,
    'sensorHeight': sensorHeight,
    'pixelSizeX': pixelSizeX,
    'pixelSizeY': pixelSizeY,
    'maxAdu': maxAdu,
    'canCool': canCool,
    'canSetGain': canSetGain,
    'canSetOffset': canSetOffset,
  };

  static CameraState _parseCameraState(dynamic value) {
    if (value == null) return CameraState.idle;
    if (value is CameraState) return value;
    final str = value.toString().toLowerCase();
    return CameraState.values.firstWhere(
      (e) => e.name.toLowerCase() == str,
      orElse: () => CameraState.idle,
    );
  }
}

// Mount status

/// Current status of a connected mount
class MountStatus {
  final bool connected;
  final bool tracking;
  final bool slewing;
  final bool parked;
  final bool atHome;
  final PierSide sideOfPier;
  final double rightAscension; // Hours (0-24)
  final double declination; // Degrees (-90 to +90)

  /// Degrees above the horizon, or null when the mount cannot say.
  ///
  /// Nullable because the horizon frame is not a property of the mount alone:
  /// it needs an observing site, and the native side returns `None` (with the
  /// matching `availability` entry set to `unsupported`) whenever there is no
  /// site or the driver does not report alt/az. These three fields were
  /// non-nullable doubles that the FFI mapper filled with `?? 0.0`, so a
  /// parked simulated mount on a machine with no observing site printed
  /// `Alt 0.00° / Az 0.00°` — the horizon, stated as a measurement — in the
  /// same card that honestly printed `Pier --` two rows below.
  final double? altitude;

  /// Degrees clockwise from north, or null when the mount cannot say. See
  /// [altitude] for why this is nullable.
  final double? azimuth;

  /// Local sidereal time in hours, or null when the mount cannot say. See
  /// [altitude] for why this is nullable.
  final double? siderealTime;
  final TrackingRate trackingRate;
  final bool canPark;
  final bool canSlew;
  final bool canSync;
  final bool canPulseGuide;
  final bool canSetTrackingRate;
  final Map<String, String> availability;

  const MountStatus({
    required this.connected,
    required this.tracking,
    required this.slewing,
    required this.parked,
    required this.atHome,
    required this.sideOfPier,
    required this.rightAscension,
    required this.declination,
    this.altitude,
    this.azimuth,
    this.siderealTime,
    required this.trackingRate,
    required this.canPark,
    required this.canSlew,
    required this.canSync,
    required this.canPulseGuide,
    required this.canSetTrackingRate,
    this.availability = const {},
  });

  /// Create from JSON (for network transport)
  factory MountStatus.fromJson(Map<String, dynamic> json) {
    return MountStatus(
      connected: json['connected'] as bool? ?? false,
      tracking: json['tracking'] as bool? ?? false,
      slewing: json['slewing'] as bool? ?? false,
      parked: json['parked'] as bool? ?? false,
      atHome: json['at_home'] ?? json['atHome'] ?? false,
      sideOfPier: _parsePierSide(json['side_of_pier'] ?? json['sideOfPier']),
      rightAscension:
          (json['right_ascension'] ?? json['rightAscension'] ?? json['ra'])
              ?.toDouble() ??
          0.0,
      declination: (json['declination'] ?? json['dec'])?.toDouble() ?? 0.0,
      // No `?? 0.0`: a missing horizon-frame field means the mount could not
      // say, and 0° is a real altitude (the horizon), not a blank.
      altitude: (json['altitude'] ?? json['alt'])?.toDouble(),
      azimuth: (json['azimuth'] ?? json['az'])?.toDouble(),
      siderealTime:
          (json['sidereal_time'] ?? json['siderealTime'] ?? json['lst'])
              ?.toDouble(),
      trackingRate: _parseTrackingRate(
        json['tracking_rate'] ?? json['trackingRate'],
      ),
      canPark: json['can_park'] ?? json['canPark'] ?? false,
      canSlew: json['can_slew'] ?? json['canSlew'] ?? false,
      canSync: json['can_sync'] ?? json['canSync'] ?? false,
      canPulseGuide: json['can_pulse_guide'] ?? json['canPulseGuide'] ?? false,
      canSetTrackingRate:
          json['can_set_tracking_rate'] ?? json['canSetTrackingRate'] ?? false,
      availability:
          (json['availability'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ) ??
          const {},
    );
  }

  /// Convert to JSON (for network transport)
  Map<String, dynamic> toJson() => {
    'connected': connected,
    'tracking': tracking,
    'slewing': slewing,
    'parked': parked,
    'atHome': atHome,
    'sideOfPier': sideOfPier.name,
    'rightAscension': rightAscension,
    'declination': declination,
    'altitude': altitude,
    'azimuth': azimuth,
    'siderealTime': siderealTime,
    'trackingRate': trackingRate.name,
    'canPark': canPark,
    'canSlew': canSlew,
    'canSync': canSync,
    'canPulseGuide': canPulseGuide,
    'canSetTrackingRate': canSetTrackingRate,
    'availability': availability,
  };

  static PierSide _parsePierSide(dynamic value) {
    if (value == null) return PierSide.unknown;
    if (value is PierSide) return value;
    final str = value.toString().toLowerCase();
    return PierSide.values.firstWhere(
      (e) => e.name.toLowerCase() == str,
      orElse: () => PierSide.unknown,
    );
  }

  static TrackingRate _parseTrackingRate(dynamic value) {
    if (value == null) return TrackingRate.sidereal;
    if (value is TrackingRate) return value;
    final str = value.toString().toLowerCase();
    return TrackingRate.values.firstWhere(
      (e) => e.name.toLowerCase() == str,
      orElse: () => TrackingRate.sidereal,
    );
  }
}

// Focuser status

/// Current status of a connected focuser
class FocuserStatus {
  final bool connected;
  final int position;
  final bool moving;
  final double? temperature;
  final int maxPosition;
  final double stepSize;
  final bool isAbsolute;
  final bool hasTemperature;

  const FocuserStatus({
    required this.connected,
    required this.position,
    required this.moving,
    this.temperature,
    required this.maxPosition,
    required this.stepSize,
    required this.isAbsolute,
    required this.hasTemperature,
  });

  /// Create from JSON (for network transport)
  factory FocuserStatus.fromJson(Map<String, dynamic> json) {
    return FocuserStatus(
      connected: json['connected'] as bool? ?? false,
      position: json['position'] as int? ?? 0,
      moving: (json['moving'] ?? json['isMoving']) as bool? ?? false,
      temperature: json['temperature']?.toDouble(),
      maxPosition: (json['max_position'] ?? json['maxPosition']) as int? ?? 0,
      stepSize: (json['step_size'] ?? json['stepSize'])?.toDouble() ?? 0.0,
      isAbsolute: json['is_absolute'] ?? json['isAbsolute'] ?? false,
      hasTemperature:
          json['has_temperature'] ??
          json['hasTemperature'] ??
          (json['temperature'] != null),
    );
  }

  /// Convert to JSON (for network transport)
  Map<String, dynamic> toJson() => {
    'connected': connected,
    'position': position,
    'moving': moving,
    'temperature': temperature,
    'maxPosition': maxPosition,
    'stepSize': stepSize,
    'isAbsolute': isAbsolute,
    'hasTemperature': hasTemperature,
  };
}

// Filter wheel status

/// Current status of a connected filter wheel
class FilterWheelStatus {
  final bool connected;
  final int position;
  final bool moving;
  final int filterCount;
  final List<String> filterNames;

  const FilterWheelStatus({
    required this.connected,
    required this.position,
    required this.moving,
    required this.filterCount,
    required this.filterNames,
  });

  /// Get the name of the current filter
  String? get currentFilterName {
    if (position < 0 || position >= filterNames.length) return null;
    return filterNames[position];
  }

  /// Create from JSON (for network transport)
  factory FilterWheelStatus.fromJson(Map<String, dynamic> json) {
    return FilterWheelStatus(
      connected: json['connected'] as bool? ?? false,
      position: json['position'] as int? ?? 0,
      moving: json['moving'] as bool? ?? false,
      filterCount: (json['filter_count'] ?? json['filterCount']) as int? ?? 0,
      filterNames: (json['filter_names'] ?? json['filterNames'] ?? [])
          .cast<String>()
          .toList(),
    );
  }

  /// Convert to JSON (for network transport)
  Map<String, dynamic> toJson() => {
    'connected': connected,
    'position': position,
    'moving': moving,
    'filterCount': filterCount,
    'filterNames': filterNames,
  };
}

// Rotator status

/// Current status of a connected rotator
class RotatorStatus {
  final bool connected;
  final double position; // Degrees
  final bool moving;
  final double mechanicalPosition;
  final bool isMoving;
  final bool canReverse;

  const RotatorStatus({
    required this.connected,
    required this.position,
    required this.moving,
    required this.mechanicalPosition,
    required this.isMoving,
    required this.canReverse,
  });

  /// Create from JSON (for network transport)
  factory RotatorStatus.fromJson(Map<String, dynamic> json) {
    final position = json['position']?.toDouble() ?? 0.0;
    return RotatorStatus(
      connected: json['connected'] as bool? ?? false,
      position: position,
      moving: json['moving'] as bool? ?? false,
      mechanicalPosition:
          (json['mechanical_position'] ?? json['mechanicalPosition'])
              ?.toDouble() ??
          position,
      isMoving: json['is_moving'] ?? json['isMoving'] ?? false,
      canReverse: json['can_reverse'] ?? json['canReverse'] ?? false,
    );
  }

  /// Convert to JSON (for network transport)
  Map<String, dynamic> toJson() => {
    'connected': connected,
    'position': position,
    'moving': moving,
    'mechanicalPosition': mechanicalPosition,
    'isMoving': isMoving,
    'canReverse': canReverse,
  };
}
