import 'dart:async';

import '../../models/backend/backend_types.dart';
import '../../models/phd2_models.dart';
import '../../services/phd2_probe.dart';

/// Role interface covering guiding operations.
///
/// What this role owns:
///   * Direct PHD2 control (connect, start, stop, dither, parameters,
///     calibration, lock position, find-star, etc.).
///   * The driver-agnostic `guider*` abstraction routed by device id (so
///     future non-PHD2 guiders can land without changing service-layer code).
///   * Built-in guider configuration get/set (the FFI-only built-in guider).
///
/// What this role deliberately does NOT own:
///   * Pulse-guiding the mount — that lives in [DeviceBackend] because it is
///     a mount-driver primitive used by autofocus, manual jog, and PHD2-style
///     calibration alike.
///   * Plate solving — see [ImagingBackend].
///   * Auto-dithering during a sequence — the sequencer drives that through
///     [SequencerBackend.sequencerUpdateDitherConfig]; the guider role is the
///     transport.
abstract class GuidingBackend {
  // PHD2 Guiding (direct control)

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

  /// Connect to PHD2
  Future<void> phd2Connect({String host = 'localhost', int port = 4400});

  /// Disconnect from PHD2
  Future<void> phd2Disconnect();

  /// Start guiding
  Future<void> phd2StartGuiding({
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  });

  /// Stop guiding
  Future<void> phd2StopGuiding();

  /// Dither
  Future<void> phd2Dither({
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  });

  /// Get PHD2 status
  Future<Phd2Status> phd2GetStatus();

  /// Get star image from PHD2
  Future<Phd2StarImage> phd2GetStarImage({int size = 50});

  /// Get algorithm parameter names for an axis
  Future<List<String>> phd2GetAlgoParamNames({required String axis});

  /// Get algorithm parameter value
  Future<double> phd2GetAlgoParam({required String axis, required String name});

  /// Set algorithm parameter value
  Future<void> phd2SetAlgoParam({
    required String axis,
    required String name,
    required double value,
  });

  /// Pause or resume guiding
  Future<void> phd2SetPaused(bool paused);

  /// Clear calibration data
  Future<void> phd2ClearCalibration({String which = 'both'});

  /// Flip calibration (after meridian flip)
  Future<void> phd2FlipCalibration();

  /// Get current calibration data from PHD2
  Future<Phd2CalibrationData> phd2GetCalibrationData();

  /// Find a guide star automatically
  Future<(double, double)> phd2FindStar();

  /// Set guide star lock position
  Future<void> phd2SetLockPosition({
    required double x,
    required double y,
    bool exact = false,
  });

  /// Get current lock position
  Future<(double, double)> phd2GetLockPosition();

  /// Start looping exposures (without guiding)
  Future<void> phd2Loop();

  /// Deselect the current guide star
  Future<void> phd2DeselectStar();

  // Generic Guiding (driver-agnostic)

  /// Start guiding using the connected guider
  ///
  /// Routes to appropriate implementation (PHD2, or future guider types) based
  /// on the device ID. This abstraction allows future guider implementations
  /// to be added without changing service-level code.
  Future<void> guiderStartGuiding({
    required String deviceId,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  });

  /// Stop guiding on the specified guider
  Future<void> guiderStopGuiding({required String deviceId});

  /// Dither the guide star
  Future<void> guiderDither({
    required String deviceId,
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  });

  /// Start guide-camera looping without issuing guide corrections.
  Future<void> guiderLoop({required String deviceId});

  /// Automatically select a guide star.
  Future<(double, double)> guiderFindStar({required String deviceId});

  /// Set the guide-star lock position.
  Future<void> guiderSetLockPosition({
    required String deviceId,
    required double x,
    required double y,
    bool exact = false,
  });

  /// Get the current guide-star lock position.
  Future<(double, double)> guiderGetLockPosition({required String deviceId});

  /// Deselect the current guide star.
  Future<void> guiderDeselectStar({required String deviceId});

  /// Fetch the latest guide star image/crop.
  Future<Phd2StarImage> guiderGetStarImage({
    required String deviceId,
    int size = 50,
  });

  /// Get the built-in guider configuration.
  Future<BuiltinGuiderConfig> builtinGuiderGetConfig();

  /// Set the built-in guider configuration.
  Future<void> builtinGuiderSetConfig(BuiltinGuiderConfig config);
}
