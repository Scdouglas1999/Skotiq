/// The readings of a device slot as the imaging host sends them to a linked
/// client.
///
/// The connection half of a slot (state, device, error) is the same for every
/// device and travels with the slot's channel. A device whose card shows
/// readings names them here, one [SlotReadings] per state class, referenced
/// from its row in the device table.
library;

import '../../models/equipment/equipment_models.dart';
import '../runtime_mirror/runtime_mirror_codec.dart';

class SlotReadings<S> {
  const SlotReadings({
    required Map<String, dynamic> Function(S state) encode,
    required S Function(S current, Map<String, dynamic> readings) decode,
  }) : _encode = encode,
       _decode = decode;

  final Map<String, dynamic> Function(S state) _encode;
  final S Function(S current, Map<String, dynamic> readings) _decode;

  /// The readings of [state] as JSON (no NaN or infinity).
  Map<String, dynamic> encode(Object? state) => _encode(state as S);

  /// [current] with the host's readings in place of its own. [current]
  /// already holds the host's connection half and whatever only this client
  /// knows (its auto-reconnect choice).
  Object? decode(Object? current, Map<String, dynamic> readings) =>
      _decode(current as S, readings);
}

bool _flag(Object? value) => value == true;

/// To a tenth of a degree, which is what the cards show. A tracking mount's
/// altitude and azimuth move with every poll; sent in full they would make
/// every poll a message.
double? _tenths(double? degrees) {
  final value = finiteOrNull(degrees);
  return value == null ? null : (value * 10).roundToDouble() / 10;
}

const cameraReadings = SlotReadings<CameraStateSnapshot>(
  encode: _encodeCamera,
  decode: _decodeCamera,
);

Map<String, dynamic> _encodeCamera(CameraStateSnapshot s) => {
  'temperature': finiteOrNull(s.temperature),
  'coolerPower': finiteOrNull(s.coolerPower),
  'targetTemp': finiteOrNull(s.targetTemp),
  'gain': s.gain,
  'offset': s.offset,
  'binning': s.binning,
  'coolerOn': s.coolerOn,
  'isWarming': s.isWarming,
};

CameraStateSnapshot _decodeCamera(
  CameraStateSnapshot current,
  Map<String, dynamic> json,
) => CameraStateSnapshot(
  connectionState: current.connectionState,
  deviceId: current.deviceId,
  deviceName: current.deviceName,
  lastError: current.lastError,
  autoReconnectEnabled: current.autoReconnectEnabled,
  temperature: jsonDouble(json['temperature']),
  coolerPower: jsonDouble(json['coolerPower']),
  targetTemp: jsonDouble(json['targetTemp']) ?? current.targetTemp,
  gain: jsonInt(json['gain']),
  offset: jsonInt(json['offset']),
  binning: jsonString(json['binning']),
  coolerOn: json['coolerOn'] as bool?,
  isWarming: _flag(json['isWarming']),
  // The exposure follows the host camera's own events, which a client
  // receives itself: a start, progress at least every 2 s (so a client that
  // links mid-exposure shows it within that), and an end for every start.
  // The host's own flag is no substitute: a headless host's reads idle while
  // its run's frames expose, and every host's reads exposing for a moment
  // after each frame, after the end event a client would clear it with.
  isExposing: current.isExposing,
  exposureProgress: current.exposureProgress,
  // A camera the host sends is one it holds and reads; the re-read repeats
  // that at least every 30 s.
  lastSuccessfulCommunication: DateTime.now(),
);

const mountReadings = SlotReadings<MountState>(
  encode: _encodeMount,
  decode: _decodeMount,
);

Map<String, dynamic> _encodeMount(MountState s) => {
  'ra': finiteOrNull(s.ra),
  'dec': finiteOrNull(s.dec),
  'altitude': _tenths(s.altitude),
  'azimuth': _tenths(s.azimuth),
  'isTracking': s.isTracking,
  'isSlewing': s.isSlewing,
  'isParked': s.isParked,
  'isAtHome': s.isAtHome,
  'isHoming': s.isHoming,
  'homeUnconfirmed': s.homeUnconfirmed,
  'sideOfPier': s.sideOfPier,
  'trackingRate': s.trackingRate.name,
  'canSetTrackingRate': s.canSetTrackingRate,
  'canPark': s.canPark,
};

MountState _decodeMount(MountState current, Map<String, dynamic> json) {
  final rate = jsonString(json['trackingRate']);
  return MountState(
    connectionState: current.connectionState,
    deviceId: current.deviceId,
    deviceName: current.deviceName,
    lastError: current.lastError,
    autoReconnectEnabled: current.autoReconnectEnabled,
    ra: jsonDouble(json['ra']),
    dec: jsonDouble(json['dec']),
    altitude: jsonDouble(json['altitude']),
    azimuth: jsonDouble(json['azimuth']),
    isTracking: _flag(json['isTracking']),
    isSlewing: _flag(json['isSlewing']),
    isParked: _flag(json['isParked']),
    isAtHome: _flag(json['isAtHome']),
    isHoming: _flag(json['isHoming']),
    homeUnconfirmed: _flag(json['homeUnconfirmed']),
    sideOfPier: jsonString(json['sideOfPier']),
    trackingRate: TrackingRate.values.firstWhere(
      (value) => value.name == rate,
      orElse: () => current.trackingRate,
    ),
    canSetTrackingRate: _flag(json['canSetTrackingRate']),
    canPark: _flag(json['canPark']),
  );
}

const focuserReadings = SlotReadings<FocuserState>(
  encode: _encodeFocuser,
  decode: _decodeFocuser,
);

Map<String, dynamic> _encodeFocuser(FocuserState s) => {
  'position': s.position,
  'maxPosition': s.maxPosition,
  'stepSize': finiteOrNull(s.stepSize),
  'isAbsolute': s.isAbsolute,
  'hasTemperature': s.hasTemperature,
  'temperature': finiteOrNull(s.temperature),
  'isMoving': s.isMoving,
};

FocuserState _decodeFocuser(FocuserState current, Map<String, dynamic> json) =>
    FocuserState(
      connectionState: current.connectionState,
      deviceId: current.deviceId,
      deviceName: current.deviceName,
      lastError: current.lastError,
      autoReconnectEnabled: current.autoReconnectEnabled,
      position: jsonInt(json['position']),
      maxPosition: jsonInt(json['maxPosition']),
      stepSize: jsonDouble(json['stepSize']),
      isAbsolute: _flag(json['isAbsolute']),
      hasTemperature: _flag(json['hasTemperature']),
      temperature: jsonDouble(json['temperature']),
      isMoving: _flag(json['isMoving']),
    );

const filterWheelReadings = SlotReadings<FilterWheelState>(
  encode: _encodeFilterWheel,
  decode: _decodeFilterWheel,
);

Map<String, dynamic> _encodeFilterWheel(FilterWheelState s) => {
  'position': s.currentPosition,
  'filterNames': s.filterNames,
  'isMoving': s.isMoving,
};

FilterWheelState _decodeFilterWheel(
  FilterWheelState current,
  Map<String, dynamic> json,
) {
  final names = json['filterNames'];
  return FilterWheelState(
    connectionState: current.connectionState,
    deviceId: current.deviceId,
    deviceName: current.deviceName,
    lastError: current.lastError,
    autoReconnectEnabled: current.autoReconnectEnabled,
    currentPosition: jsonInt(json['position']),
    filterNames: names is List ? [for (final name in names) '$name'] : const [],
    isMoving: _flag(json['isMoving']),
  );
}

const rotatorReadings = SlotReadings<RotatorState>(
  encode: _encodeRotator,
  decode: _decodeRotator,
);

Map<String, dynamic> _encodeRotator(RotatorState s) => {
  'position': finiteOrNull(s.position),
  'mechanicalPosition': finiteOrNull(s.mechanicalPosition),
  'isMoving': s.isMoving,
  'isReversed': s.isReversed,
};

RotatorState _decodeRotator(RotatorState current, Map<String, dynamic> json) =>
    RotatorState(
      connectionState: current.connectionState,
      deviceId: current.deviceId,
      deviceName: current.deviceName,
      lastError: current.lastError,
      autoReconnectEnabled: current.autoReconnectEnabled,
      position: jsonDouble(json['position']),
      mechanicalPosition: jsonDouble(json['mechanicalPosition']),
      isMoving: _flag(json['isMoving']),
      isReversed: _flag(json['isReversed']),
    );
