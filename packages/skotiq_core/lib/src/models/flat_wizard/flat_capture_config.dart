import 'package:equatable/equatable.dart';

import '../../services/flat_exposure_calculator.dart';
import 'flat_wizard_settings.dart';

/// The effective, capability-resolved capture configuration for a flat run.
///
/// Camera defaults come from the connected backend and active profile.
/// [forFilter] applies explicit overrides; that immutable configuration drives
/// exposure tuning, capture, FITS metadata and flat history for the filter.
///
/// Resolution rules (see `FlatWizardService.resolveCaptureConfig`):
///   * [maxAdu] is the PIXEL-CONTAINER full scale — the largest value that can
///     appear in the frame data whose mean the solver measures. The
///     driver-reported `CameraStatus.maxAdu` is authoritative; bit depth is used
///     only when the driver reports nothing, and is NOT allowed to cap the
///     driver value (12/14-bit drivers left-justify into a 16-bit container, so
///     a bitDepth-derived cap made the target physically unreachable — see
///     `FlatWizardService.resolveCaptureConfig`). Falls back to a safe 16-bit
///     [FlatExposureCalculator.fallbackMaxAdu] for display when nothing is
///     known; [rangeKnown] remains false and automatic capture must stop.
///   * [gain]/[offset] are `null` when the camera cannot set them, or when no
///     profile/live value exists — `null` means "camera/driver default", NOT
///     numeric zero. When a value exists it is clamped to the capability range.
///   * [binX]/[binY] honour the profile defaults, clamped to `maxBin*`, forced
///     symmetric only when the camera explicitly cannot bin asymmetrically, and
///     forced to 1×1 when the camera cannot bin at all.
class FlatCaptureConfig extends Equatable {
  /// Effective full-scale ADU of the PIXEL CONTAINER — the ceiling of the values
  /// the frame actually contains (65520 for a 12-bit sensor whose driver
  /// left-justifies into 16 bits, 65535 for a true 16-bit sensor, 4095 only for a
  /// driver that genuinely delivers right-justified 12-bit samples). Never zero.
  final int maxAdu;

  /// Effective sensor ADC bit depth, when known (display / diagnostics only —
  /// this is a precision figure, never a full-scale divisor; see [maxAdu]).
  final int? bitDepth;

  /// Effective gain to command, or `null` to use the camera/driver default
  /// (also `null` when the camera cannot set gain).
  final int? gain;

  /// Effective offset to command, or `null` for the camera/driver default.
  final int? offset;

  /// Effective binning to command (both axes).
  final int binX;
  final int binY;

  /// Whether the camera can set gain/offset. When false, no value is sent.
  final bool canSetGain;
  final bool canSetOffset;

  /// Capability ranges (null when unknown).
  final int? gainMin;
  final int? gainMax;
  final int? offsetMin;
  final int? offsetMax;

  /// Binning capability metadata.
  final bool canBin;
  final bool canAsymmetricBin;
  final int maxBinX;
  final int maxBinY;

  /// True when resolved against a remote master (the host owns the hardware).
  final bool hostAuthoritative;

  /// True when a camera-capability struct was available. When false, only safe
  /// fallbacks were used and the UI should present the range as approximate.
  final bool capabilitiesKnown;

  /// True when [maxAdu] came from the connected camera's status or bit-depth
  /// capabilities. A false value means the numeric range is only the generic
  /// 16-bit display fallback and must not be used to drive an automatic flat
  /// calibration: doing so can make a 12/14-bit camera chase an impossible
  /// target.
  final bool rangeKnown;

  const FlatCaptureConfig({
    this.maxAdu = FlatExposureCalculator.fallbackMaxAdu,
    this.bitDepth,
    this.gain,
    this.offset,
    this.binX = 1,
    this.binY = 1,
    this.canSetGain = false,
    this.canSetOffset = false,
    this.gainMin,
    this.gainMax,
    this.offsetMin,
    this.offsetMax,
    this.canBin = false,
    this.canAsymmetricBin = false,
    this.maxBinX = 1,
    this.maxBinY = 1,
    this.hostAuthoritative = false,
    this.capabilitiesKnown = false,
    this.rangeKnown = false,
  });

  /// Absolute target ADU for a histogram [percent] against this camera's
  /// effective full scale.
  double targetAduFor(double percent) =>
      FlatExposureCalculator.histogramPercentToAdu(
        percent,
        maxAdu: maxAdu,
      ).toDouble();

  /// The histogram percentage that an absolute [adu] represents against this
  /// camera's effective full scale.
  double percentForAdu(num adu) =>
      FlatExposureCalculator.aduToHistogramPercent(adu.round(), maxAdu: maxAdu);

  /// Apply explicit filter settings without silently changing calibration values.
  /// Validate the entire queue before moving the wheel or taking exposures.
  FlatCaptureConfig forFilter(FlatFilterSettings filter) {
    void validate(String name, int? value, bool supported, int? min, int? max) {
      if (value == null) return;
      if (!supported) {
        throw StateError(
          '${filter.filterName}: camera cannot set $name. '
          'Clear the override to use the camera default.',
        );
      }
      if ((min != null && value < min) || (max != null && value > max)) {
        throw StateError(
          '${filter.filterName}: $name $value is outside '
          'the camera range ${min ?? "?"}–${max ?? "?"}.',
        );
      }
    }

    validate('gain', filter.gainOverride, canSetGain, gainMin, gainMax);
    validate(
      'offset',
      filter.offsetOverride,
      canSetOffset,
      offsetMin,
      offsetMax,
    );
    return copyWith(gain: filter.gainOverride, offset: filter.offsetOverride);
  }

  FlatCaptureConfig copyWith({
    int? maxAdu,
    int? bitDepth,
    int? gain,
    int? offset,
    int? binX,
    int? binY,
    bool? canSetGain,
    bool? canSetOffset,
    int? gainMin,
    int? gainMax,
    int? offsetMin,
    int? offsetMax,
    bool? canBin,
    bool? canAsymmetricBin,
    int? maxBinX,
    int? maxBinY,
    bool? hostAuthoritative,
    bool? capabilitiesKnown,
    bool? rangeKnown,
  }) {
    return FlatCaptureConfig(
      maxAdu: maxAdu ?? this.maxAdu,
      bitDepth: bitDepth ?? this.bitDepth,
      gain: gain ?? this.gain,
      offset: offset ?? this.offset,
      binX: binX ?? this.binX,
      binY: binY ?? this.binY,
      canSetGain: canSetGain ?? this.canSetGain,
      canSetOffset: canSetOffset ?? this.canSetOffset,
      gainMin: gainMin ?? this.gainMin,
      gainMax: gainMax ?? this.gainMax,
      offsetMin: offsetMin ?? this.offsetMin,
      offsetMax: offsetMax ?? this.offsetMax,
      canBin: canBin ?? this.canBin,
      canAsymmetricBin: canAsymmetricBin ?? this.canAsymmetricBin,
      maxBinX: maxBinX ?? this.maxBinX,
      maxBinY: maxBinY ?? this.maxBinY,
      hostAuthoritative: hostAuthoritative ?? this.hostAuthoritative,
      capabilitiesKnown: capabilitiesKnown ?? this.capabilitiesKnown,
      rangeKnown: rangeKnown ?? this.rangeKnown,
    );
  }

  @override
  List<Object?> get props => [
    maxAdu,
    bitDepth,
    gain,
    offset,
    binX,
    binY,
    canSetGain,
    canSetOffset,
    gainMin,
    gainMax,
    offsetMin,
    offsetMax,
    canBin,
    canAsymmetricBin,
    maxBinX,
    maxBinY,
    hostAuthoritative,
    capabilitiesKnown,
    rangeKnown,
  ];
}
