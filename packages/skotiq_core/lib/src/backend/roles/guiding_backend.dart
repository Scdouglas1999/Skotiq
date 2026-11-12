import 'dart:async';

import '../../models/backend/backend_types.dart';
import '../../models/phd2_models.dart';
import '../../services/phd2_probe.dart';

/// Role interface covering guiding operations.
///
/// Guiding goes through one family, `guider*`, which the host answers with
/// the guider its profile names (PHD2 or the built-in multi-star guider). The
/// `phd2*` members are what only PHD2 has: its connection, its guide
/// algorithm settings and its calibration store. The built-in guider's own
/// settings are `builtinGuider*`.
///
/// Pulse-guiding the mount belongs to [DeviceBackend]; dithering during a
/// run is the sequencer's, which drives the same guider.
abstract class GuidingBackend {
  /// Probe whether a PHD2 instance is reachable on the given host/port.
  ///
  /// Used by the onboarding "Test connection" step before any device is paired.
  /// Host-local: the probe opens a socket to the PHD2 event server (default
  /// `localhost:4400`) on the machine running the rig, so the network backend
  /// — which has no way to reach the host's loopback PHD2 socket — does not
  /// support it.
  Future<bool> isPhd2Running({String host = 'localhost', int port = 4400});

  /// Shake hands with the PHD2 event server on the given host/port and report
  /// what answered: PHD2's version and the equipment profile it has selected.
  ///
  /// [isPhd2Running] only proves *a* process holds the port, which is not
  /// enough for the Settings page to tell the operator "PHD2 answered". This
  /// reads the `Version` event PHD2 sends to every connecting client and makes
  /// one read-only `get_profile` call, so the answer names the software it
  /// actually reached. Host-local for the same reason as [isPhd2Running]; the
  /// network backend forwards it to the master.
  Future<Phd2ProbeResult> phd2Probe({
    String host = 'localhost',
    int port = 4400,
  });

  Future<void> phd2Connect({String host = 'localhost', int port = 4400});

  Future<void> phd2Disconnect();

  Future<List<String>> phd2GetAlgoParamNames({required String axis});

  Future<double> phd2GetAlgoParam({required String axis, required String name});

  Future<void> phd2SetAlgoParam({
    required String axis,
    required String name,
    required double value,
  });

  /// Clear PHD2's stored calibration: `mount`, `ao` or `both`.
  Future<void> phd2ClearCalibration({String which = 'both'});

  /// Flip PHD2's calibration after a meridian flip.
  Future<void> phd2FlipCalibration();

  /// Start guiding and wait for the guider to settle.
  Future<void> guiderStartGuiding({
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  });

  Future<void> guiderStopGuiding();

  /// Dither and wait for the guider to settle.
  Future<void> guiderDither({
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  });

  /// Start guide-camera looping without issuing guide corrections.
  Future<void> guiderLoop();

  /// Hold guide corrections while the guider keeps its star, or resume them.
  Future<void> guiderSetPaused(bool paused);

  Future<(double, double)> guiderFindStar();

  Future<void> guiderSetLockPosition({
    required double x,
    required double y,
    bool exact = false,
  });

  Future<(double, double)> guiderGetLockPosition();

  Future<void> guiderDeselectStar();

  Future<Phd2StarImage> guiderGetStarImage({int size = 50});

  /// The guider's state, guide error and pixel scale, and for the built-in
  /// multi-star guider the stars it tracks. [Phd2Status.deviceId] names the
  /// guider that answered.
  Future<Phd2Status> guiderGetStatus();

  /// The guider's calibration of the mount.
  Future<Phd2CalibrationData> guiderGetCalibration();

  Future<BuiltinGuiderConfig> builtinGuiderGetConfig();

  Future<void> builtinGuiderSetConfig(BuiltinGuiderConfig config);
}
