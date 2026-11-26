import 'dart:math' as math;

import '../../models/backend/backend_types.dart';
import 'demo_devices.dart';

/// The demo guider's states, spelled as the guider status reports them.
abstract final class DemoGuiderState {
  static const stopped = 'Stopped';
  static const looping = 'Looping';
  static const settling = 'Settling';
  static const guiding = 'Guiding';
  static const paused = 'Paused';
}

/// The demo guider: it loops, guides and dithers on command, and while it
/// guides it reports small corrections around the lock position.
class DemoGuider {
  DemoGuider({int seed = 7}) : _random = math.Random(seed);

  static const double pixelScaleArcsec = 1.5;

  final math.Random _random;

  bool connected = false;
  String state = DemoGuiderState.stopped;
  double lockX = 412.6;
  double lockY = 301.2;
  double _rmsRa = 0;
  double _rmsDec = 0;
  String? stopReason;

  bool get guiding =>
      state == DemoGuiderState.guiding || state == DemoGuiderState.settling;

  /// One guide step: the error on each axis, pixels, and the running RMS.
  ({double ra, double dec}) step() {
    final ra = (_random.nextDouble() - 0.5) * 0.9;
    final dec = (_random.nextDouble() - 0.5) * 0.7;
    _rmsRa = math.sqrt(0.9 * _rmsRa * _rmsRa + 0.1 * ra * ra);
    _rmsDec = math.sqrt(0.9 * _rmsDec * _rmsDec + 0.1 * dec * dec);
    return (ra: ra, dec: dec);
  }

  void resetStats() {
    _rmsRa = 0.25;
    _rmsDec = 0.2;
  }

  Phd2Status status() {
    final active = guiding;
    final rmsRa = active ? _rmsRa * pixelScaleArcsec : 0.0;
    final rmsDec = active ? _rmsDec * pixelScaleArcsec : 0.0;
    return Phd2Status(
      deviceId: connected ? DemoDeviceIds.guider : null,
      state: connected ? state : DemoGuiderState.stopped,
      connected: connected,
      rmsRa: rmsRa,
      rmsDec: rmsDec,
      rmsTotal: math.sqrt(rmsRa * rmsRa + rmsDec * rmsDec),
      snr: state == DemoGuiderState.stopped ? 0 : 42.0,
      starMass: state == DemoGuiderState.stopped ? 0 : 18500,
      avgDistance: active ? (_rmsRa + _rmsDec) / 2 : 0,
      pixelScale: pixelScaleArcsec,
      stopReason: active ? null : stopReason,
    );
  }
}
