import 'dart:math' as math;

import '../../models/backend/backend_types.dart';
import 'demo_devices.dart';
import 'demo_star_field.dart';

/// The air temperature the demo rig sits in, degrees C.
const double demoRigAmbientC = 15.0;

/// A move between two values that takes time: where it started, where it
/// goes, and when it gets there. The value in between is a straight line.
class DemoMove {
  DemoMove({
    required this.from,
    required this.to,
    required this.startedAt,
    required this.endsAt,
  });

  final double from;
  final double to;
  final DateTime startedAt;
  final DateTime endsAt;

  bool movingAt(DateTime t) => t.isBefore(endsAt);

  double valueAt(DateTime t) {
    if (!t.isBefore(endsAt)) return to;
    final total = endsAt.difference(startedAt).inMicroseconds;
    if (total <= 0) return to;
    final f = (t.difference(startedAt).inMicroseconds / total).clamp(0.0, 1.0);
    return from + (to - from) * f;
  }
}

/// One of the demo cameras, with a cooler whose sensor temperature moves
/// toward its set point (or back to ambient) at a fixed rate.
class DemoCamera {
  DemoCamera({
    required this.deviceId,
    required this.name,
    required this.sensorWidth,
    required this.sensorHeight,
    required this.canCool,
    required DateTime at,
  }) : _tempAnchorAt = at;

  final String deviceId;
  final String name;
  final int sensorWidth;
  final int sensorHeight;
  final bool canCool;

  static const double pixelSizeUm = 3.76;
  static const int gainMax = 300;
  static const int offsetMax = 100;
  static const int maxBin = 4;
  static const double coolestC = demoRigAmbientC - 40.0;

  /// Degrees C per second the sensor temperature changes by.
  static const double coolRateCPerSecond = 0.5;

  bool connected = false;
  int gain = 100;
  int offset = 10;
  int binX = 1;
  int binY = 1;
  bool coolerOn = false;
  double targetTempC = -10.0;

  double _tempAnchorC = demoRigAmbientC;
  DateTime _tempAnchorAt;

  /// The exposure in progress, if any.
  DemoExposure? exposure;

  /// The last frame this camera delivered.
  DemoCapturedFrame? lastFrame;

  double get _goalC => coolerOn ? targetTempC : demoRigAmbientC;

  double sensorTempAt(DateTime t) {
    final seconds = t.difference(_tempAnchorAt).inMicroseconds / 1e6;
    final step = coolRateCPerSecond * seconds;
    final goal = _goalC;
    if (_tempAnchorC > goal) return math.max(goal, _tempAnchorC - step);
    return math.min(goal, _tempAnchorC + step);
  }

  /// When the sensor gets to its goal, measured from [t].
  Duration timeToGoalFrom(DateTime t) {
    final remaining = (sensorTempAt(t) - _goalC).abs();
    return Duration(
      milliseconds: (remaining / coolRateCPerSecond * 1000).round(),
    );
  }

  /// Cooler power, percent: what holding the sensor below ambient takes, and
  /// more while it is still pulling down.
  double coolerPowerAt(DateTime t) {
    if (!coolerOn) return 0;
    final temp = sensorTempAt(t);
    final holding = (demoRigAmbientC - temp) / (demoRigAmbientC - coolestC);
    final pulling = (temp - targetTempC) > 0.05 ? 0.25 : 0.0;
    return ((holding + pulling) * 100).clamp(0.0, 100.0);
  }

  void setCooler({required bool on, double? targetC, required DateTime at}) {
    _tempAnchorC = sensorTempAt(at);
    _tempAnchorAt = at;
    coolerOn = on;
    if (targetC != null) targetTempC = targetC.clamp(coolestC, demoRigAmbientC);
  }

  CameraStatus statusAt(DateTime t) => CameraStatus(
    connected: connected,
    state: exposure == null ? CameraState.idle : CameraState.exposing,
    sensorTemp: sensorTempAt(t),
    coolerPower: canCool ? coolerPowerAt(t) : null,
    targetTemp: canCool ? targetTempC : null,
    coolerOn: canCool ? coolerOn : null,
    gain: gain,
    offset: offset,
    binX: binX,
    binY: binY,
    sensorWidth: sensorWidth,
    sensorHeight: sensorHeight,
    pixelSizeX: pixelSizeUm,
    pixelSizeY: pixelSizeUm,
    maxAdu: 65535,
    canCool: canCool,
    canSetGain: true,
    canSetOffset: true,
  );

  CameraCapabilities capabilitiesAt(DateTime t) => CameraCapabilities(
    maxWidth: sensorWidth,
    maxHeight: sensorHeight,
    bitDepth: 16,
    canSetCcdTemperature: canCool,
    canSetCooler: canCool,
    canGetCoolerPower: canCool,
    canBin: true,
    maxBinX: maxBin,
    maxBinY: maxBin,
    canSetGain: true,
    gainMin: 0,
    gainMax: gainMax,
    canSetOffset: true,
    offsetMin: 0,
    offsetMax: offsetMax,
    canAbortExposure: true,
    pixelSizeX: pixelSizeUm,
    pixelSizeY: pixelSizeUm,
    sensorType: 'Monochrome',
    exposureMin: 0.001,
    exposureMax: 3600,
    ccdTemperature: sensorTempAt(t),
    setCcdTemperature: canCool ? targetTempC : null,
    coolerPower: canCool ? coolerPowerAt(t) : null,
    coolerOn: canCool ? coolerOn : null,
    coolerMinTempC: canCool ? coolestC : null,
    coolerMaxTempC: canCool ? demoRigAmbientC : null,
  );
}

/// An exposure a demo camera is taking.
class DemoExposure {
  DemoExposure({
    required this.seconds,
    required this.startedAt,
    required this.frameType,
  });

  final double seconds;
  final DateTime startedAt;
  final String frameType;
  bool aborted = false;

  DateTime get endsAt =>
      startedAt.add(Duration(microseconds: (seconds * 1e6).round()));
}

/// A frame a demo camera delivered, with what it was taken with.
class DemoCapturedFrame {
  const DemoCapturedFrame({
    required this.frame,
    required this.endedAt,
    required this.exposureSeconds,
  });

  final DemoFrame frame;
  final DateTime endedAt;
  final double exposureSeconds;
}

/// The demo focuser: absolute, 0 to [maxPosition], best focus at [bestFocus].
class DemoFocuser {
  static const int maxPosition = 60000;
  static const int bestFocus = 31200;
  static const double stepsPerSecond = 2000;

  bool connected = false;
  double _position = 30000;
  DemoMove? move;

  int positionAt(DateTime t) => (move?.valueAt(t) ?? _position).round();

  bool movingAt(DateTime t) {
    final m = move;
    return m != null && m.movingAt(t);
  }

  /// Start a move to [target]; answers how long it takes.
  Duration moveTo(int target, DateTime t) {
    final from = positionAt(t).toDouble();
    final to = target.clamp(0, maxPosition).toDouble();
    final ms = math.max(
      200,
      ((to - from).abs() / stepsPerSecond * 1000).round(),
    );
    final duration = Duration(milliseconds: ms);
    move = DemoMove(from: from, to: to, startedAt: t, endsAt: t.add(duration));
    _position = to;
    return duration;
  }

  void halt(DateTime t) {
    _position = positionAt(t).toDouble();
    move = null;
  }

  /// The star width the camera sees: sharp at best focus, wider away from it.
  double starSigmaAt(DateTime t) =>
      (1.3 + (positionAt(t) - bestFocus).abs() / 900.0).clamp(1.3, 15.0);

  /// The focuser's temperature probe: ambient with a slow drift.
  double temperatureAt(DateTime t) =>
      demoRigAmbientC - 2.0 + 0.4 * math.sin(t.millisecondsSinceEpoch / 6e5);

  FocuserStatus statusAt(DateTime t) => FocuserStatus(
    connected: connected,
    position: positionAt(t),
    moving: movingAt(t),
    temperature: temperatureAt(t),
    maxPosition: maxPosition,
    stepSize: 4.0,
    isAbsolute: true,
    hasTemperature: true,
  );

  FocuserCapabilities capabilitiesAt(DateTime t) => FocuserCapabilities(
    maxPosition: maxPosition,
    maxIncrement: maxPosition,
    stepSize: 4.0,
    absolute: true,
    temperature: temperatureAt(t),
    isMoving: movingAt(t),
    position: positionAt(t),
    canHalt: true,
  );
}

/// The demo filter wheel: seven slots, moving one slot in a quarter second.
class DemoFilterWheel {
  bool connected = false;
  List<String> names = List.of(demoRigFilterNames);
  int _position = 0;
  int? _target;
  DateTime? _arrivesAt;

  int get slotCount => demoRigFilterNames.length;

  bool movingAt(DateTime t) {
    final arrives = _arrivesAt;
    return arrives != null && t.isBefore(arrives);
  }

  int positionAt(DateTime t) {
    final target = _target;
    if (target != null && !movingAt(t)) {
      _position = target;
      _target = null;
      _arrivesAt = null;
    }
    return _position;
  }

  /// Start a move to [slot]; answers how long it takes.
  Duration moveTo(int slot, DateTime t) {
    final from = positionAt(t);
    final forward = (slot - from) % slotCount;
    final distance = math.min(forward, slotCount - forward);
    final duration = Duration(milliseconds: 600 + 250 * distance);
    _target = slot;
    _arrivesAt = t.add(duration);
    return duration;
  }

  String? nameOf(int slot) =>
      slot >= 0 && slot < names.length ? names[slot] : null;

  /// How much light the slot at [t] lets through, for the frame renderer.
  double throughputAt(DateTime t) {
    final name = nameOf(positionAt(t))?.toLowerCase();
    return switch (name) {
      'l' => 1.0,
      'r' || 'g' || 'b' => 0.4,
      'ha' || 'oiii' || 'sii' => 0.12,
      _ => 1.0,
    };
  }

  FilterWheelStatus statusAt(DateTime t) => FilterWheelStatus(
    connected: connected,
    position: positionAt(t),
    moving: movingAt(t),
    filterCount: slotCount,
    filterNames: List.unmodifiable(names),
  );

  FilterWheelCapabilities capabilitiesAt(DateTime t) => FilterWheelCapabilities(
    positionCount: slotCount,
    currentPosition: positionAt(t),
    filterNames: List.unmodifiable(names),
    isMoving: movingAt(t),
    canSetFilterNames: true,
  );
}

/// The demo rotator: turns at eight degrees a second; a sync shifts the sky
/// angle it reports without moving it.
class DemoRotator {
  static const double degreesPerSecond = 8.0;

  bool connected = false;
  bool reverse = false;
  double _mechanical = 0;
  double syncOffset = 0;
  DemoMove? move;

  double mechanicalAt(DateTime t) => _wrap360(move?.valueAt(t) ?? _mechanical);

  double positionAt(DateTime t) => _wrap360(mechanicalAt(t) + syncOffset);

  bool movingAt(DateTime t) {
    final m = move;
    return m != null && m.movingAt(t);
  }

  /// Start a move to sky angle [angle]; answers how long it takes.
  Duration moveTo(double angle, DateTime t) {
    final from = mechanicalAt(t);
    var delta = _wrap360(angle - syncOffset) - from;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    final ms = math.max(200, (delta.abs() / degreesPerSecond * 1000).round());
    final duration = Duration(milliseconds: ms);
    move = DemoMove(
      from: from,
      to: from + delta,
      startedAt: t,
      endsAt: t.add(duration),
    );
    _mechanical = from + delta;
    return duration;
  }

  void halt(DateTime t) {
    _mechanical = mechanicalAt(t);
    move = null;
  }

  void syncTo(double pa, DateTime t) {
    syncOffset = _wrap360(pa - mechanicalAt(t));
  }

  RotatorStatus statusAt(DateTime t) => RotatorStatus(
    connected: connected,
    position: positionAt(t),
    moving: movingAt(t),
    mechanicalPosition: mechanicalAt(t),
    isMoving: movingAt(t),
    canReverse: true,
  );

  RotatorCapabilities capabilitiesAt(DateTime t) => RotatorCapabilities(
    canReverse: true,
    reverse: reverse,
    stepSize: 0.1,
    isMoving: movingAt(t),
    mechanicalPosition: mechanicalAt(t),
    position: positionAt(t),
    canMoveAbsolute: true,
    canHalt: true,
    canSync: true,
  );
}

double _wrap360(double degrees) {
  final wrapped = degrees % 360.0;
  return wrapped < 0 ? wrapped + 360.0 : wrapped;
}
