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
///     [SequencerBackend.sequencerApplyRunConfig]; the guider role is the
///     transport.
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

  Future<void> phd2StartGuiding({
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  });

  Future<void> phd2StopGuiding();

  Future<void> phd2Dither({
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  });

  Future<Phd2Status> phd2GetStatus();

  Future<Phd2StarImage> phd2GetStarImage({int size = 50});

  Future<List<String>> phd2GetAlgoParamNames({required String axis});

  Future<double> phd2GetAlgoParam({required String axis, required String name});

  Future<void> phd2SetAlgoParam({
    required String axis,
    required String name,
    required double value,
  });

  Future<void> phd2SetPaused(bool paused);

  Future<void> phd2ClearCalibration({String which = 'both'});

  /// Flip calibration (after meridian flip)
  Future<void> phd2FlipCalibration();

  Future<Phd2CalibrationData> phd2GetCalibrationData();

  Future<(double, double)> phd2FindStar();

  Future<void> phd2SetLockPosition({
    required double x,
    required double y,
    bool exact = false,
  });

  Future<(double, double)> phd2GetLockPosition();

  /// Start looping exposures (without guiding)
  Future<void> phd2Loop();

  Future<void> phd2DeselectStar();

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

  Future<void> guiderStopGuiding({required String deviceId});

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

  Future<(double, double)> guiderFindStar({required String deviceId});

  Future<void> guiderSetLockPosition({
    required String deviceId,
    required double x,
    required double y,
    bool exact = false,
  });

  Future<(double, double)> guiderGetLockPosition({required String deviceId});

  Future<void> guiderDeselectStar({required String deviceId});

  Future<Phd2StarImage> guiderGetStarImage({
    required String deviceId,
    int size = 50,
  });

  /// The guider's state, guide error and pixel scale, and for the built-in
  /// multi-star guider the stars it tracks.
  Future<Phd2Status> guiderGetStatus({required String deviceId});

  /// The guider's calibration, in the shape PHD2 reports it.
  Future<Phd2CalibrationData> guiderGetCalibration({required String deviceId});

  Future<BuiltinGuiderConfig> builtinGuiderGetConfig();

  Future<void> builtinGuiderSetConfig(BuiltinGuiderConfig config);
}
