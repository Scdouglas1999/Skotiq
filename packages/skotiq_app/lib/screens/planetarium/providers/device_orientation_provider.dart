import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Whether the gyroscope sky aiming mode is active.
final gyroscopeAimingEnabledProvider = StateProvider<bool>((ref) => false);

/// Whether "Sync Mount" is active — when enabled, the device orientation
/// drives the physical mount via slew commands through the network backend.
/// Only functional when gyroscope aiming is also enabled and a mount is connected.
final gyroscopeMountSyncProvider = StateProvider<bool>((ref) => false);

/// Whether compass calibration has been acknowledged this session.
final compassCalibrationAcknowledgedProvider =
    StateProvider<bool>((ref) => false);

/// Raw device orientation from sensors: (altitude degrees, azimuth degrees).
/// Only emits when gyroscope aiming is enabled.
final deviceOrientationProvider =
    StateNotifierProvider<DeviceOrientationNotifier, DeviceOrientationState>(
        (ref) {
  return DeviceOrientationNotifier(ref);
});

/// State representing the device's physical orientation in horizontal coords.
class DeviceOrientationState {
  /// Device tilt altitude in degrees (-90 to +90).
  /// 0 = horizon, +90 = zenith, -90 = nadir.
  final double altitude;

  /// Compass azimuth in degrees (0-360).
  /// 0 = North, 90 = East, 180 = South, 270 = West.
  final double azimuth;

  /// Whether sensor data is being received.
  final bool isActive;

  /// Compass accuracy quality indicator.
  final CompassAccuracy compassAccuracy;

  const DeviceOrientationState({
    this.altitude = 0,
    this.azimuth = 0,
    this.isActive = false,
    this.compassAccuracy = CompassAccuracy.unknown,
  });

  DeviceOrientationState copyWith({
    double? altitude,
    double? azimuth,
    bool? isActive,
    CompassAccuracy? compassAccuracy,
  }) {
    return DeviceOrientationState(
      altitude: altitude ?? this.altitude,
      azimuth: azimuth ?? this.azimuth,
      isActive: isActive ?? this.isActive,
      compassAccuracy: compassAccuracy ?? this.compassAccuracy,
    );
  }
}

enum CompassAccuracy {
  unknown,
  unreliable,
  low,
  medium,
  high,
}

class DeviceOrientationNotifier extends StateNotifier<DeviceOrientationState> {
  final Ref _ref;
  StreamSubscription<AccelerometerEvent>? _accelerometerSub;
  StreamSubscription<MagnetometerEvent>? _magnetometerSub;

  // Raw sensor values
  double _accelX = 0, _accelY = 0, _accelZ = 0;
  double _magX = 0, _magY = 0, _magZ = 0;
  bool _hasAccel = false;
  bool _hasMag = false;

  // Low-pass filter coefficient (0-1, lower = more smoothing)
  static const double _smoothingAlpha = 0.15;
  double _smoothedAlt = 0;
  double _smoothedAz = 0;
  bool _hasSmoothedValues = false;

  // Throttle updates to ~30fps to avoid excessive state changes
  Timer? _updateTimer;
  static const Duration _updateInterval = Duration(milliseconds: 33);

  DeviceOrientationNotifier(this._ref) : super(const DeviceOrientationState()) {
    _ref.listen<bool>(gyroscopeAimingEnabledProvider, (previous, next) {
      if (next) {
        _startListening();
      } else {
        _stopListening();
      }
    });
  }

  void _startListening() {
    // Guard: only run on mobile platforms
    if (!_isMobilePlatform()) {
      state = state.copyWith(isActive: false);
      return;
    }

    _hasSmoothedValues = false;

    _accelerometerSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 20),
    ).listen(
      (event) {
        _accelX = event.x;
        _accelY = event.y;
        _accelZ = event.z;
        _hasAccel = true;
        _scheduleUpdate();
      },
      onError: (error) {
        developer.log('Accelerometer error: $error',
            name: 'DeviceOrientationProvider', level: 900, error: error);
        state = state.copyWith(isActive: false);
      },
    );

    _magnetometerSub = magnetometerEventStream(
      samplingPeriod: const Duration(milliseconds: 20),
    ).listen(
      (event) {
        _magX = event.x;
        _magY = event.y;
        _magZ = event.z;
        _hasMag = true;
        _scheduleUpdate();
      },
      onError: (error) {
        developer.log('Magnetometer error: $error',
            name: 'DeviceOrientationProvider', level: 900, error: error);
        state = state.copyWith(
          isActive: false,
          compassAccuracy: CompassAccuracy.unreliable,
        );
      },
    );

    state = state.copyWith(isActive: true);
  }

  void _stopListening() {
    _accelerometerSub?.cancel();
    _accelerometerSub = null;
    _magnetometerSub?.cancel();
    _magnetometerSub = null;
    _updateTimer?.cancel();
    _updateTimer = null;
    _hasAccel = false;
    _hasMag = false;
    _hasSmoothedValues = false;
    state = state.copyWith(isActive: false);
  }

  void _scheduleUpdate() {
    if (_updateTimer?.isActive ?? false) return;
    _updateTimer = Timer(_updateInterval, _computeOrientation);
  }

  void _computeOrientation() {
    if (!mounted) return;
    if (!_hasAccel || !_hasMag) return;

    // Compute device altitude from accelerometer.
    // Phone held upright (screen facing user): accelY ~ -9.8, accelZ ~ 0
    // Phone tilted back (screen facing sky): accelZ ~ -9.8, accelY ~ 0
    // We treat the phone as if the user is holding it up and looking through it.
    //
    // The altitude of where the phone is "pointing" (top edge direction):
    // When phone is vertical (portrait, screen toward user), top points at horizon -> alt=0
    // When phone is tilted back 90deg (screen faces sky), top points at zenith -> alt=90
    final accelMag =
        math.sqrt(_accelX * _accelX + _accelY * _accelY + _accelZ * _accelZ);
    if (accelMag < 0.1) return; // Free-fall, no valid data

    // Normalize accelerometer
    final ax = _accelX / accelMag;
    final ay = _accelY / accelMag;
    final az = _accelZ / accelMag;

    // Phone pointing direction (top of phone) altitude:
    // In Android sensor frame: X=right, Y=up (along phone), Z=out of screen
    // Gravity vector points down, so normalized gravity = (-ax, -ay, -az) in device frame
    // The "pointing direction" of the phone top is the +Y axis in device frame
    // Altitude = angle between device +Y axis and horizontal plane
    // sin(altitude) = dot(+Y_device, -gravity_normalized) projected...
    //
    // Actually: the altitude of where the top of the phone points is:
    // altitude = asin(-ay) when phone is in portrait
    // But we need to account for the phone being used as a "viewfinder":
    // The direction the *back camera* / screen normal points is the -Z axis.
    // For sky aiming, the relevant direction is where the phone "looks through":
    // that's the -Z direction (screen normal, pointing away from face).
    //
    // altitude = asin(az) -- az component of gravity tells us the tilt
    // (az=0 -> phone vertical -> looking at horizon, az=-1 -> screen faces up -> zenith)
    final altitude = math.asin((-az).clamp(-1.0, 1.0)) * 180.0 / math.pi;

    // Compute azimuth from magnetometer + accelerometer fusion.
    // We need to project the magnetic field vector onto the horizontal plane
    // as seen from the device's perspective.
    //
    // Build a rotation matrix from device frame to world frame:
    // Gravity direction (normalized, pointing up in world = -accel)
    final gx = -ax, gy = -ay, gz = -az;

    // East = cross(gravity_up, mag) normalized
    // This gives us the East direction in device frame
    var ex = gy * _magZ - gz * _magY;
    var ey = gz * _magX - gx * _magZ;
    var ez = gx * _magY - gy * _magX;
    final eMag = math.sqrt(ex * ex + ey * ey + ez * ez);
    if (eMag < 0.001) return; // Degenerate case
    ex /= eMag;
    ey /= eMag;
    ez /= eMag;

    // North = cross(east, gravity_up) normalized
    var nx = ey * gz - ez * gy;
    var ny = ez * gx - ex * gz;
    var nz = ex * gy - ey * gx;
    final nMag = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nMag < 0.001) return;
    nx /= nMag;
    ny /= nMag;
    nz /= nMag;

    // The phone's -Z direction (where screen points) projected onto the
    // horizontal plane gives us the azimuth. But for sky aiming, we want
    // the direction the phone's top (+Y in device frame) projects to horizontal.
    // Actually for "point phone at sky" mode, we want the -Z axis (screen normal).
    //
    // For the azimuth of where the phone is "looking" (the -Z direction):
    // Project -Z_device = (0, 0, -1) onto (north, east) axes:
    // north_component = dot(device_-Z, north_in_device) = -nz
    // east_component = dot(device_-Z, east_in_device) = -ez
    //
    // azimuth = atan2(east_component, north_component)
    var azimuth = math.atan2(-ez, -nz) * 180.0 / math.pi;
    if (azimuth < 0) azimuth += 360.0;

    // Assess compass accuracy from magnetic field magnitude
    final magMag = math.sqrt(_magX * _magX + _magY * _magY + _magZ * _magZ);
    CompassAccuracy accuracy;
    // Earth's magnetic field is typically 25-65 uT
    if (magMag < 10 || magMag > 100) {
      accuracy = CompassAccuracy.unreliable;
    } else if (magMag < 20 || magMag > 80) {
      accuracy = CompassAccuracy.low;
    } else if (magMag < 25 || magMag > 65) {
      accuracy = CompassAccuracy.medium;
    } else {
      accuracy = CompassAccuracy.high;
    }

    // Apply low-pass filter for smooth motion
    if (!_hasSmoothedValues) {
      _smoothedAlt = altitude;
      _smoothedAz = azimuth;
      _hasSmoothedValues = true;
    } else {
      _smoothedAlt = _smoothedAlt + _smoothingAlpha * (altitude - _smoothedAlt);

      // Handle azimuth wraparound (0/360 boundary)
      var azDiff = azimuth - _smoothedAz;
      if (azDiff > 180) azDiff -= 360;
      if (azDiff < -180) azDiff += 360;
      _smoothedAz = (_smoothedAz + _smoothingAlpha * azDiff) % 360;
      if (_smoothedAz < 0) _smoothedAz += 360;
    }

    state = DeviceOrientationState(
      altitude: _smoothedAlt.clamp(-90.0, 90.0),
      azimuth: _smoothedAz,
      isActive: true,
      compassAccuracy: accuracy,
    );
  }

  bool _isMobilePlatform() {
    return defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }
}

/// Converts device orientation (alt/az) to RA/Dec given current observer
/// location and time. Returns null if gyroscope aiming is not active.
/// Returns (raHours, decDegrees).
(double, double)? deviceOrientationToRaDec({
  required DeviceOrientationState orientation,
  required PlanetariumObserver location,
  required ObservationTimeState time,
}) {
  if (!orientation.isActive) return null;
  // Pointing the phone at the sky answers "what am I looking at" only for an
  // observer at a known place, so with no site there is no RA/Dec to return.
  final site = location.site;
  if (site == null) return null;

  final lst =
      AstronomyCalculations.localSiderealTime(time.time, site.longitude);

  final (raDeg, dec) = AstronomyCalculations.horizontalToEquatorial(
    altDeg: orientation.altitude,
    azDeg: orientation.azimuth,
    latitudeDeg: site.latitude,
    lstHours: lst,
  );

  return (raDeg / 15.0, dec);
}
