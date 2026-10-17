part of '../imaging_models.dart';

class ExposureSettings extends Equatable {
  final double exposureTime;
  final int gain;
  final int offset;
  final int binningX;
  final int binningY;
  final String? filter;
  final FrameType frameType;

  /// Legacy boolean readout-speed flag. Kept verbatim for persistence
  /// back-compat: profiles/sequences saved before [readoutModeIndex] existed
  /// only stored this boolean. New code should prefer [readoutModeIndex] and
  /// use [resolveReadoutModeIndex] / [readoutIsFast] to bridge the two.
  final bool fastReadout;

  /// Index into the camera's reported readout-mode list. `null` means the user
  /// has not picked an explicit mode, in which case [fastReadout] is the
  /// authoritative source (mapped via [resolveReadoutModeIndex]).
  final int? readoutModeIndex;

  const ExposureSettings({
    required this.exposureTime,
    required this.gain,
    required this.offset,
    this.binningX = 1,
    this.binningY = 1,
    this.filter,
    this.frameType = FrameType.light,
    this.fastReadout = false,
    this.readoutModeIndex,
  });

  String get binning => '${binningX}x$binningY';

  /// Resolves the concrete readout-mode index to send to the camera given the
  /// camera's [modeCount].
  ///
  /// When [readoutModeIndex] is set it wins outright. Otherwise we fall back to
  /// the legacy [fastReadout] flag: by vendor convention the fast mode is the
  /// last entry in the readout-mode list and the slow mode is the first.
  int resolveReadoutModeIndex(int modeCount) =>
      readoutModeIndex ?? (fastReadout ? modeCount - 1 : 0);

  /// Whether the resolved readout mode is the camera's fast mode given
  /// [modeCount].
  ///
  /// When [readoutModeIndex] is set, "fast" means it points at the last mode;
  /// otherwise the legacy [fastReadout] flag is authoritative. The UI uses this
  /// to keep [fastReadout] in sync when an explicit mode is chosen.
  bool readoutIsFast(int modeCount) => readoutModeIndex != null
      ? readoutModeIndex == modeCount - 1
      : fastReadout;

  ExposureSettings copyWith({
    double? exposureTime,
    int? gain,
    int? offset,
    int? binningX,
    int? binningY,
    String? filter,
    FrameType? frameType,
    bool? fastReadout,
    int? readoutModeIndex,
  }) {
    return ExposureSettings(
      exposureTime: exposureTime ?? this.exposureTime,
      gain: gain ?? this.gain,
      offset: offset ?? this.offset,
      binningX: binningX ?? this.binningX,
      binningY: binningY ?? this.binningY,
      filter: filter ?? this.filter,
      frameType: frameType ?? this.frameType,
      fastReadout: fastReadout ?? this.fastReadout,
      readoutModeIndex: readoutModeIndex ?? this.readoutModeIndex,
    );
  }

  @override
  List<Object?> get props => [
    exposureTime,
    gain,
    offset,
    binningX,
    binningY,
    filter,
    frameType,
    fastReadout,
    readoutModeIndex,
  ];
}

/// Cooling settings
class CoolingSettings extends Equatable {
  final double targetTemp;
  final bool enabled;
  final double warmupRate;
  final double cooldownRate;

  const CoolingSettings({
    this.targetTemp = -10.0,
    this.enabled = false,
    this.warmupRate = 2.0,
    this.cooldownRate = 5.0,
  });

  CoolingSettings copyWith({
    double? targetTemp,
    bool? enabled,
    double? warmupRate,
    double? cooldownRate,
  }) {
    return CoolingSettings(
      targetTemp: targetTemp ?? this.targetTemp,
      enabled: enabled ?? this.enabled,
      warmupRate: warmupRate ?? this.warmupRate,
      cooldownRate: cooldownRate ?? this.cooldownRate,
    );
  }

  @override
  List<Object?> get props => [targetTemp, enabled, warmupRate, cooldownRate];
}

/// Cooling status
class CoolingStatus extends Equatable {
  final double currentTemp;
  final double targetTemp;
  final double coolerPower;
  final bool isAtTarget;
  final bool isCooling;

  const CoolingStatus({
    this.currentTemp = 20.0,
    this.targetTemp = -10.0,
    this.coolerPower = 0.0,
    this.isAtTarget = false,
    this.isCooling = false,
  });

  CoolingStatus copyWith({
    double? currentTemp,
    double? targetTemp,
    double? coolerPower,
    bool? isAtTarget,
    bool? isCooling,
  }) {
    return CoolingStatus(
      currentTemp: currentTemp ?? this.currentTemp,
      targetTemp: targetTemp ?? this.targetTemp,
      coolerPower: coolerPower ?? this.coolerPower,
      isAtTarget: isAtTarget ?? this.isAtTarget,
      isCooling: isCooling ?? this.isCooling,
    );
  }

  @override
  List<Object?> get props => [
    currentTemp,
    targetTemp,
    coolerPower,
    isAtTarget,
    isCooling,
  ];
}

/// Focus/Autofocus settings (persists across navigation)
class FocusSettings extends Equatable {
  /// Manual focus step size
  final int stepSize;

  /// Autofocus method
  final String method;

  /// Autofocus step size
  final int afStepSize;

  /// Number of steps out from center
  final int stepsOut;

  /// Exposures per focus point
  final int exposuresPerPoint;

  /// Exposure time for autofocus
  final double exposureTime;

  const FocusSettings({
    this.stepSize = 100,
    this.method = 'V-Curve',
    this.afStepSize = 100,
    this.stepsOut = 7,
    this.exposuresPerPoint = 1,
    this.exposureTime = 3.0,
  });

  FocusSettings copyWith({
    int? stepSize,
    String? method,
    int? afStepSize,
    int? stepsOut,
    int? exposuresPerPoint,
    double? exposureTime,
  }) {
    return FocusSettings(
      stepSize: stepSize ?? this.stepSize,
      method: method ?? this.method,
      afStepSize: afStepSize ?? this.afStepSize,
      stepsOut: stepsOut ?? this.stepsOut,
      exposuresPerPoint: exposuresPerPoint ?? this.exposuresPerPoint,
      exposureTime: exposureTime ?? this.exposureTime,
    );
  }

  @override
  List<Object?> get props => [
    stepSize,
    method,
    afStepSize,
    stepsOut,
    exposuresPerPoint,
    exposureTime,
  ];
}

/// Dither/Settle settings for guiding (persists across navigation)
class DitherSettings extends Equatable {
  /// Dither amount in pixels
  final double ditherAmount;

  /// Settle threshold in pixels
  final double settlePixels;

  /// Settle time in seconds
  final double settleTime;

  /// Whether to settle after dither
  final bool settleAfterDither;

  const DitherSettings({
    this.ditherAmount = 5.0,
    this.settlePixels = 1.0,
    this.settleTime = 10.0,
    this.settleAfterDither = true,
  });

  DitherSettings copyWith({
    double? ditherAmount,
    double? settlePixels,
    double? settleTime,
    bool? settleAfterDither,
  }) {
    return DitherSettings(
      ditherAmount: ditherAmount ?? this.ditherAmount,
      settlePixels: settlePixels ?? this.settlePixels,
      settleTime: settleTime ?? this.settleTime,
      settleAfterDither: settleAfterDither ?? this.settleAfterDither,
    );
  }

  @override
  List<Object?> get props => [
    ditherAmount,
    settlePixels,
    settleTime,
    settleAfterDither,
  ];
}

/// Slew coordinates for mount tab (persists across navigation)
class SlewCoordinates extends Equatable {
  /// Right Ascension in hours
  final String raText;

  /// Declination in degrees
  final String decText;

  const SlewCoordinates({this.raText = '', this.decText = ''});

  SlewCoordinates copyWith({String? raText, String? decText}) {
    return SlewCoordinates(
      raText: raText ?? this.raText,
      decText: decText ?? this.decText,
    );
  }

  @override
  List<Object?> get props => [raText, decText];
}
