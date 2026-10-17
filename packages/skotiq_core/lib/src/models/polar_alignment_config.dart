import 'dart:typed_data';
import 'package:freezed_annotation/freezed_annotation.dart';

import 'backend/device_capabilities.dart';

part 'polar_alignment_config.freezed.dart';
part 'polar_alignment_config.g.dart';

/// Coerce a wire value that may arrive as an `int`, `double`, or numeric
/// `String` into a `double`. JSON transport (the `NetworkBackend` path)
/// collapses whole numbers to `int`, so a blind `as double` cast throws and
/// tears down the event subscription. Returns [fallback] for null/unparseable.
double _wireDouble(Object? value, {double fallback = 0.0}) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

/// Phase of the polar alignment process
enum PolarAlignPhase {
  /// Not running - waiting to start
  idle,

  /// Capturing and solving images to measure error
  measuring,

  /// Adjustment mode - showing live error updates
  adjusting,

  /// Successfully completed
  complete,

  /// Error occurred during alignment
  error,
}

/// Selects which polar-alignment algorithm to run.
enum PolarAlignmentMode {
  /// Three-Point Polar Alignment — requires a clear view of the celestial
  /// pole region (≈30° around Polaris in the northern hemisphere, or
  /// Sigma Octantis in the southern). Captures three plate-solved frames
  /// across a mount rotation arc, fits the rotation axis, and reports the
  /// offset from the true pole.
  threePoint,

  /// All-Sky Polar Alignment (Sharpcap-style). Works from any direction in
  /// the sky — no view of the pole region required. Captures one solved
  /// baseline frame, then re-solves every few seconds to measure drift
  /// caused by polar misalignment. Recovers the azimuth and altitude error
  /// vector in real time as the user adjusts the mount bolts.
  allSky,
}

extension PolarAlignmentModeExtension on PolarAlignmentMode {
  String get displayName {
    switch (this) {
      case PolarAlignmentMode.threePoint:
        return 'Three-Point (TPPA)';
      case PolarAlignmentMode.allSky:
        return 'All-Sky';
    }
  }

  String get description {
    switch (this) {
      case PolarAlignmentMode.threePoint:
        return 'Slew across a 30° arc near the celestial pole and fit '
            'the mount rotation axis. Requires the pole region to be clear.';
      case PolarAlignmentMode.allSky:
        return 'Plate-solve one frame anywhere in the sky, then track drift '
            'every few seconds. Works from any direction — no view of the '
            'pole required. Requires a plate solver (ASTAP).';
    }
  }
}

/// Extension for PolarAlignPhase display
extension PolarAlignPhaseExtension on PolarAlignPhase {
  String get displayName {
    switch (this) {
      case PolarAlignPhase.idle:
        return 'Ready';
      case PolarAlignPhase.measuring:
        return 'Measuring';
      case PolarAlignPhase.adjusting:
        return 'Adjusting';
      case PolarAlignPhase.complete:
        return 'Complete';
      case PolarAlignPhase.error:
        return 'Error';
    }
  }

  String get description {
    switch (this) {
      case PolarAlignPhase.idle:
        return 'Ready to start polar alignment';
      case PolarAlignPhase.measuring:
        return 'Capturing and plate solving images to calculate polar error';
      case PolarAlignPhase.adjusting:
        return 'Adjust your mount\'s altitude and azimuth knobs to minimize error';
      case PolarAlignPhase.complete:
        return 'Polar alignment completed successfully';
      case PolarAlignPhase.error:
        return 'An error occurred during polar alignment';
    }
  }

  bool get isActive =>
      this == PolarAlignPhase.measuring || this == PolarAlignPhase.adjusting;
}

/// Configuration for polar alignment capture settings
@freezed
abstract class PolarAlignmentConfig with _$PolarAlignmentConfig {
  const PolarAlignmentConfig._();

  const factory PolarAlignmentConfig({
    /// Exposure time in seconds for each measurement image
    @Default(5.0) double exposureTime,

    /// Step size in degrees for mount rotation between measurements
    @Default(15.0) double stepSize,

    /// Camera binning (1, 2, 3, 4).
    ///
    /// 2 is the default because a binned frame plate-solves in a quarter of
    /// the time and the alignment measurement — where the mount's rotation
    /// axis sits — is unaffected: the axis is fitted from three solved sky
    /// positions, not from the resolution they were solved at.
    @Default(2) int binning,

    /// Whether observing from northern hemisphere
    @Default(true) bool isNorth,

    /// Whether to use manual rotation (user rotates mount) vs automatic slewing
    @Default(false) bool manualRotation,

    /// Direction to rotate (true = east, false = west) for auto rotation
    @Default(true) bool rotateEast,

    /// Timeout in seconds for one frame's plate solve.
    ///
    /// This is the whole budget for the frame, shared by the hinted solve and
    /// the blind fallback behind it. 30 s was the old default and it was not
    /// enough: on the owner's rig a full-resolution blind solve of a
    /// pole-region frame took 26.5 s on a good night and was killed
    /// mid-solve on a bad one.
    @Default(90.0) double solveTimeout,

    /// Delay between all-sky drift re-solves. Kept in the shared config so
    /// headless/API-started runs are recorded and replayed with the cadence
    /// they actually used rather than silently reverting to 3 seconds.
    @Default(3.0) double iterationCadenceSecs,

    /// Total error threshold in arcseconds to consider alignment complete
    /// When error drops below this value, auto-complete can be triggered
    @Default(30.0) double autoCompleteThreshold,

    /// Whether to start from current mount position or slew to pole first
    @Default(true) bool startFromCurrent,

    /// Camera gain (null = use camera default)
    int? gain,

    /// Camera offset (null = use camera default)
    int? offset,
  }) = _PolarAlignmentConfig;

  factory PolarAlignmentConfig.fromJson(Map<String, dynamic> json) =>
      _$PolarAlignmentConfigFromJson(json);

  /// Validate settings and return any validation errors.
  ///
  /// This uses conservative hardcoded gain/offset/binning bounds and is the
  /// fallback when the connected camera's capabilities are unknown. Prefer
  /// [validateForCamera] when a [CameraCapabilities] is available so the
  /// limits reflect the real hardware (or the host's, over the network).
  List<String> validate() {
    final errors = _validateCommon();

    if (binning < 1 || binning > 4) {
      errors.add('Binning must be between 1 and 4');
    }

    if (gain != null && (gain! < 0 || gain! > 1000)) {
      errors.add('Gain must be between 0 and 1000');
    }

    if (offset != null && (offset! < 0 || offset! > 255)) {
      errors.add('Offset must be between 0 and 255');
    }

    return errors;
  }

  /// Validate against the *actual* camera capabilities.
  ///
  /// Resolves the gain/offset/binning limits from the connected camera rather
  /// than hardcoded guesses. A `null` [caps] (capabilities not yet known)
  /// falls back to [validate]. Null [gain]/[offset] always pass — they mean
  /// "use the camera's current/default value" and are never coerced to 0.
  List<String> validateForCamera(CameraCapabilities? caps) {
    if (caps == null) return validate();

    final errors = _validateCommon();

    // Binning: bounded by the camera's advertised maximum when it can bin.
    final maxBin = (caps.canBin && caps.maxBinX >= 1 && caps.maxBinY >= 1)
        ? (caps.maxBinX < caps.maxBinY ? caps.maxBinX : caps.maxBinY)
        : 1;
    if (binning < 1 || binning > maxBin) {
      errors.add('Binning must be between 1 and $maxBin for this camera');
    }

    // Gain: only validated when explicitly set. null = camera default.
    if (gain != null) {
      if (!caps.canSetGain) {
        errors.add('This camera does not support setting gain');
      } else if (caps.gainMin != null && caps.gainMax != null) {
        if (gain! < caps.gainMin! || gain! > caps.gainMax!) {
          errors.add(
            'Gain must be between ${caps.gainMin} and ${caps.gainMax} '
            'for this camera',
          );
        }
      }
    }

    // Offset: only validated when explicitly set. null = camera default.
    if (offset != null) {
      if (!caps.canSetOffset) {
        errors.add('This camera does not support setting offset');
      } else if (caps.offsetMin != null && caps.offsetMax != null) {
        if (offset! < caps.offsetMin! || offset! > caps.offsetMax!) {
          errors.add(
            'Offset must be between ${caps.offsetMin} and ${caps.offsetMax} '
            'for this camera',
          );
        }
      }
    }

    return errors;
  }

  /// Range checks that are independent of the camera (exposure, rotation
  /// step, solve timeout, acceptance threshold). Shared by [validate] and
  /// [validateForCamera].
  List<String> _validateCommon() {
    final errors = <String>[];

    if (exposureTime < 0.1) {
      errors.add('Exposure time must be at least 0.1 seconds');
    }
    if (exposureTime > 300) {
      errors.add('Exposure time should not exceed 300 seconds');
    }

    if (stepSize < 5) {
      errors.add('Step size must be at least 5 degrees');
    }
    if (stepSize > 45) {
      errors.add('Step size should not exceed 45 degrees');
    }

    if (solveTimeout < 5) {
      errors.add('Solve timeout must be at least 5 seconds');
    }
    if (solveTimeout > 120) {
      errors.add('Solve timeout should not exceed 120 seconds');
    }

    if (iterationCadenceSecs < 0.5) {
      errors.add('All-sky iteration cadence must be at least 0.5 seconds');
    }
    if (iterationCadenceSecs > 60) {
      errors.add('All-sky iteration cadence should not exceed 60 seconds');
    }

    if (autoCompleteThreshold < 1) {
      errors.add('Auto-complete threshold must be at least 1 arcsecond');
    }
    if (autoCompleteThreshold > 300) {
      errors.add('Auto-complete threshold should not exceed 300 arcseconds');
    }

    return errors;
  }

  /// Create default configuration for quick start
  factory PolarAlignmentConfig.quickStart() => const PolarAlignmentConfig(
    exposureTime: 3.0,
    stepSize: 15.0,
    binning: 2,
    // A binned frame with a position hint solves in seconds; the timeout is
    // the ceiling, not the cost. 20 s was below what the blind fallback needs
    // to finish at all, which made "quick" mean "gives up".
    solveTimeout: 60.0,
  );

  /// Create configuration for high-precision alignment
  factory PolarAlignmentConfig.highPrecision() => const PolarAlignmentConfig(
    exposureTime: 10.0,
    stepSize: 30.0,
    binning: 1,
    // Unbinned frames are the slowest to solve, so this preset gets the
    // largest budget the validator accepts.
    solveTimeout: 120.0,
    autoCompleteThreshold: 10.0,
  );
}

/// A single polar alignment error measurement
@freezed
abstract class PolarAlignmentError with _$PolarAlignmentError {
  const PolarAlignmentError._();

  const factory PolarAlignmentError({
    /// Azimuth error in arcseconds (positive = east)
    required double azimuthError,

    /// Altitude error in arcseconds (positive = above pole)
    required double altitudeError,

    /// Total error in arcseconds (pythagorean combination)
    required double totalError,

    /// Current RA position (degrees)
    required double currentRa,

    /// Current Dec position (degrees)
    required double currentDec,

    /// Target RA for perfect alignment (degrees)
    required double targetRa,

    /// Target Dec for perfect alignment (degrees)
    required double targetDec,

    /// When this measurement was taken
    required DateTime timestamp,
  }) = _PolarAlignmentError;

  factory PolarAlignmentError.fromJson(Map<String, dynamic> json) =>
      _$PolarAlignmentErrorFromJson(json);

  /// Create from backend event data.
  ///
  /// Numeric fields are parsed defensively: over the JSON wire (the
  /// `NetworkBackend` path) whole numbers arrive as `int`, not `double`, and a
  /// raw `.toDouble()` on a non-num (or a missing key) would throw and kill the
  /// event subscription. [_wireDouble] accepts `int`/`double`/`String`.
  factory PolarAlignmentError.fromEventData(Map<String, dynamic> data) {
    return PolarAlignmentError(
      azimuthError: _wireDouble(data['azimuth_error']),
      altitudeError: _wireDouble(data['altitude_error']),
      totalError: _wireDouble(data['total_error']),
      currentRa: _wireDouble(data['current_ra']),
      currentDec: _wireDouble(data['current_dec']),
      targetRa: _wireDouble(data['target_ra']),
      targetDec: _wireDouble(data['target_dec']),
      timestamp: DateTime.now(),
    );
  }

  /// Whether this error is within acceptable tolerance
  bool isWithinTolerance(double thresholdArcsec) =>
      totalError <= thresholdArcsec;

  /// Get direction text for azimuth adjustment
  String get azimuthDirection {
    if (azimuthError.abs() < 1) return 'centered';
    return azimuthError > 0 ? 'east' : 'west';
  }

  /// Get direction text for altitude adjustment
  String get altitudeDirection {
    if (altitudeError.abs() < 1) return 'centered';
    return altitudeError > 0 ? 'up' : 'down';
  }

  /// On-screen direction to turn the azimuth bolt to reduce the current
  /// error. Positive [azimuthError] means the mechanical pole sits east of
  /// the true pole, which is corrected by rotating the azimuth bolt
  /// westward — the opposite side from where the bullseye marker sits,
  /// hence 'Left'.
  String get azimuthAdjustment => azimuthError > 0 ? 'Left' : 'Right';

  /// On-screen direction to move the altitude bolt to reduce the current
  /// error. Positive [altitudeError] means the mechanical pole sits above
  /// the true pole, corrected by lowering the bolt, hence 'Down'.
  String get altitudeAdjustment => altitudeError > 0 ? 'Down' : 'Up';

  /// Format error as human-readable string
  String formatError() {
    final azDir = azimuthError > 0 ? 'E' : 'W';
    final altDir = altitudeError > 0 ? 'Up' : 'Dn';
    return 'Az: ${azimuthError.abs().toStringAsFixed(1)}" $azDir, '
        'Alt: ${altitudeError.abs().toStringAsFixed(1)}" $altDir, '
        'Total: ${totalError.toStringAsFixed(1)}"';
  }
}

/// Runtime state for polar alignment process
@freezed
abstract class PolarAlignmentState with _$PolarAlignmentState {
  const PolarAlignmentState._();

  const factory PolarAlignmentState({
    /// Current phase of alignment
    @Default(PolarAlignPhase.idle) PolarAlignPhase phase,

    /// Current measurement point (1-3 during measuring, 0 during adjusting)
    @Default(0) int currentPoint,

    /// Status message to display to user
    @Default('Ready to start polar alignment') String statusMessage,

    /// Current error measurements (null if not yet calculated)
    PolarAlignmentError? currentError,

    /// Initial error when adjustment phase started (for progress tracking)
    PolarAlignmentError? initialError,

    /// Most recent captured image (JPEG bytes for display)
    @NullableUint8ListConverter() Uint8List? imageData,

    /// Image width
    int? imageWidth,

    /// Image height
    int? imageHeight,

    /// Solved RA from last image (degrees)
    double? solvedRa,

    /// Solved Dec from last image (degrees)
    double? solvedDec,

    /// Error message if phase is error
    String? errorMessage,

    /// Configuration used for this alignment run
    PolarAlignmentConfig? config,

    /// When alignment started
    DateTime? startedAt,
  }) = _PolarAlignmentState;

  factory PolarAlignmentState.fromJson(Map<String, dynamic> json) =>
      _$PolarAlignmentStateFromJson(json);

  /// Whether alignment is currently running
  bool get isRunning => phase.isActive;

  /// Whether we have error data to display
  bool get hasError => currentError != null;

  /// Whether we have an image to display
  bool get hasImage => imageData != null && imageData!.isNotEmpty;

  /// Calculate improvement percentage from initial error
  double? get improvementPercent {
    if (initialError == null || currentError == null) return null;
    if (initialError!.totalError == 0) return 100.0;
    final improvement =
        (initialError!.totalError - currentError!.totalError) /
        initialError!.totalError *
        100;
    return improvement.clamp(0.0, 100.0);
  }

  /// Whether current error is below auto-complete threshold
  bool isWithinThreshold(double thresholdArcsec) {
    if (currentError == null) return false;
    return currentError!.totalError <= thresholdArcsec;
  }
}

/// Result of a completed polar alignment session
@freezed
abstract class PolarAlignmentResult with _$PolarAlignmentResult {
  const PolarAlignmentResult._();

  const factory PolarAlignmentResult({
    /// Initial error at start of adjustment phase
    required PolarAlignmentError initialError,

    /// Final error when alignment completed or stopped
    required PolarAlignmentError finalError,

    /// When alignment started
    required DateTime startedAt,

    /// When alignment completed
    required DateTime completedAt,

    /// Configuration used for this alignment
    required PolarAlignmentConfig config,

    /// Whether alignment was auto-completed (reached threshold)
    @Default(false) bool autoCompleted,

    /// Equipment profile ID used (for history tracking)
    int? equipmentProfileId,
  }) = _PolarAlignmentResult;

  factory PolarAlignmentResult.fromJson(Map<String, dynamic> json) =>
      _$PolarAlignmentResultFromJson(json);

  /// Calculate total improvement in arcseconds
  double get improvementArcsec =>
      initialError.totalError - finalError.totalError;

  /// Calculate improvement percentage
  double get improvementPercent {
    if (initialError.totalError == 0) return 100.0;
    return (improvementArcsec / initialError.totalError * 100).clamp(
      0.0,
      100.0,
    );
  }

  /// Duration of the alignment session
  Duration get duration => completedAt.difference(startedAt);

  /// Whether this was a successful alignment (significant improvement)
  bool get wasSuccessful =>
      finalError.totalError < initialError.totalError * 0.5 ||
      finalError.totalError < 60; // Less than 1 arcminute
}

/// Custom JSON converter for nullable Uint8List
class NullableUint8ListConverter
    implements JsonConverter<Uint8List?, List<int>?> {
  const NullableUint8ListConverter();

  @override
  Uint8List? fromJson(List<int>? json) =>
      json != null ? Uint8List.fromList(json) : null;

  @override
  List<int>? toJson(Uint8List? object) => object?.toList();
}
