part of '../integration_settings.dart';

/// Geometric transform model used to register subs onto the reference grid.
///
/// Mirrors the native `registration::TransformKind` accepted by the
/// `api_integrate_session` JSON contract (`"similarity"` / `"affine"` /
/// `"homography"`).
enum TransformModel {
  /// 4 dof — translation + rotation + uniform scale. Minimal sample 2 pairs.
  similarity,

  /// 6 dof — handles small differential field rotation + plate-scale drift.
  /// The default for most rigs.
  affine,

  /// 8 dof projective — for wide fields / uncorrected optics.
  homography;

  /// Wire token consumed by the native `align.model` field.
  String get wire {
    switch (this) {
      case TransformModel.similarity:
        return 'similarity';
      case TransformModel.affine:
        return 'affine';
      case TransformModel.homography:
        return 'homography';
    }
  }

  static TransformModel fromWire(String value) {
    switch (value) {
      case 'similarity':
        return TransformModel.similarity;
      case 'affine':
        return TransformModel.affine;
      case 'homography':
        return TransformModel.homography;
      default:
        throw ArgumentError.value(value, 'value', 'unknown TransformModel');
    }
  }
}

/// Output-pixel interpolation kernel used when resampling a sub onto the
/// reference grid. Mirrors native `registration::Interpolator`.
enum Resampler {
  /// Fast, live-parity bilinear.
  bilinear,

  /// Cubic Catmull-Rom — good sharpness / ringing tradeoff.
  catmullRom,

  /// Windowed-sinc Lanczos (a=3). Highest quality; the PixInsight default.
  lanczos3;

  String get wire {
    switch (this) {
      case Resampler.bilinear:
        return 'bilinear';
      case Resampler.catmullRom:
        return 'catmullRom';
      case Resampler.lanczos3:
        return 'lanczos3';
    }
  }

  static Resampler fromWire(String value) {
    switch (value) {
      case 'bilinear':
        return Resampler.bilinear;
      case 'catmullRom':
        return Resampler.catmullRom;
      case 'lanczos3':
        return Resampler.lanczos3;
      default:
        throw ArgumentError.value(value, 'value', 'unknown Resampler');
    }
  }
}

/// Per-sub weighting formula. Mirrors native `frame_weighting::WeightFormula`.
enum WeightFormula {
  /// Weight ∝ SNR.
  snr,

  /// Weight ∝ SNR² (PixInsight PSF-Signal-Weight spirit). The default.
  snrSquared,

  /// Weight ∝ (fwhm_ref / fwhm).
  fwhmInverse,

  /// Custom exponents over SNR / FWHM / eccentricity.
  custom;

  String get wire {
    switch (this) {
      case WeightFormula.snr:
        return 'snr';
      case WeightFormula.snrSquared:
        return 'snrSquared';
      case WeightFormula.fwhmInverse:
        return 'fwhmInverse';
      case WeightFormula.custom:
        return 'custom';
    }
  }

  static WeightFormula fromWire(String value) {
    switch (value) {
      case 'snr':
        return WeightFormula.snr;
      case 'snrSquared':
        return WeightFormula.snrSquared;
      case 'fwhmInverse':
        return WeightFormula.fwhmInverse;
      case 'custom':
        return WeightFormula.custom;
      default:
        throw ArgumentError.value(value, 'value', 'unknown WeightFormula');
    }
  }
}

/// Photometric normalization mode applied before integration. Mirrors native
/// `normalization::NormMode`.
enum NormalizationMode {
  /// One global additive + multiplicative coefficient per channel.
  global,

  /// A coarse additive+multiplicative grid (bilinearly interpolated) to soak up
  /// gradient drift through the night. The "long night / moving moon" preset.
  local;

  String get wire {
    switch (this) {
      case NormalizationMode.global:
        return 'global';
      case NormalizationMode.local:
        return 'local';
    }
  }

  static NormalizationMode fromWire(String value) {
    switch (value) {
      case 'global':
        return NormalizationMode.global;
      case 'local':
        return NormalizationMode.local;
      default:
        throw ArgumentError.value(value, 'value', 'unknown NormalizationMode');
    }
  }
}

/// Pixel combination operator. Mirrors native `integration::Combine`.
enum CombineMode {
  mean,
  median;

  String get wire => this == CombineMode.mean ? 'mean' : 'median';

  static CombineMode fromWire(String value) {
    switch (value) {
      case 'mean':
        return CombineMode.mean;
      case 'median':
        return CombineMode.median;
      default:
        throw ArgumentError.value(value, 'value', 'unknown CombineMode');
    }
  }
}

/// Pixel rejection algorithm. Mirrors native `integration::Reject` plus the
/// JSON-contract `"auto"` sentinel (the native side resolves `"auto"` by sub
/// count: `<8 → percentile`, `8–24 → winsorizedSigma`, `≥25 → linearFit`).
enum RejectAlgorithm {
  /// Let the engine pick by sub count (the smart default).
  auto,
  none,
  sigmaClip,
  winsorizedSigma,
  linearFit,
  percentile,
  minMax;

  String get wire {
    switch (this) {
      case RejectAlgorithm.auto:
        return 'auto';
      case RejectAlgorithm.none:
        return 'none';
      case RejectAlgorithm.sigmaClip:
        return 'sigmaClip';
      case RejectAlgorithm.winsorizedSigma:
        return 'winsorizedSigma';
      case RejectAlgorithm.linearFit:
        return 'linearFit';
      case RejectAlgorithm.percentile:
        return 'percentile';
      case RejectAlgorithm.minMax:
        return 'minMax';
    }
  }

  static RejectAlgorithm fromWire(String value) {
    switch (value) {
      case 'auto':
        return RejectAlgorithm.auto;
      case 'none':
        return RejectAlgorithm.none;
      case 'sigmaClip':
        return RejectAlgorithm.sigmaClip;
      case 'winsorizedSigma':
        return RejectAlgorithm.winsorizedSigma;
      case 'linearFit':
        return RejectAlgorithm.linearFit;
      case 'percentile':
        return RejectAlgorithm.percentile;
      case 'minMax':
        return RejectAlgorithm.minMax;
      default:
        throw ArgumentError.value(value, 'value', 'unknown RejectAlgorithm');
    }
  }

  /// The algorithm the native `"auto"` rule would resolve to for [subCount].
  /// Pure mirror of the documented native rule, exposed so the settings UI can
  /// show the operator *which* algorithm a given night will actually use.
  static RejectAlgorithm resolveAuto(int subCount) {
    if (subCount < 8) return RejectAlgorithm.percentile;
    if (subCount < 25) return RejectAlgorithm.winsorizedSigma;
    return RejectAlgorithm.linearFit;
  }
}

/// Output sample format of the integrated master.
enum OutputBitDepth {
  /// Archival linear 32-bit float (default — no quantisation).
  f32,

  /// 16-bit unsigned (smaller, lossy).
  u16;

  String get wire => this == OutputBitDepth.f32 ? 'f32' : 'u16';

  static OutputBitDepth fromWire(String value) {
    switch (value) {
      case 'f32':
        return OutputBitDepth.f32;
      case 'u16':
        return OutputBitDepth.u16;
      default:
        throw ArgumentError.value(value, 'value', 'unknown OutputBitDepth');
    }
  }
}

/// Drizzle drop-deposition kernel. Mirrors native `drizzle::DrizzleKernel`
/// (the `DrizzleConfigArgs.kernel` wire token `"square"` / `"gaussian"` /
/// `"point"`).
enum DrizzleKernel {
  /// Square drop footprint (the native default).
  square,

  /// Gaussian-weighted drop — smoother, slightly softer reconstruction.
  gaussian,

  /// Point (delta) drop — sharpest, noisiest. For very high sub counts.
  point;

  String get wire {
    switch (this) {
      case DrizzleKernel.square:
        return 'square';
      case DrizzleKernel.gaussian:
        return 'gaussian';
      case DrizzleKernel.point:
        return 'point';
    }
  }

  static DrizzleKernel fromWire(String value) {
    switch (value) {
      case 'square':
        return DrizzleKernel.square;
      case 'gaussian':
        return DrizzleKernel.gaussian;
      case 'point':
        return DrizzleKernel.point;
      default:
        throw ArgumentError.value(value, 'value', 'unknown DrizzleKernel');
    }
  }
}

/// Point-spread-function family used by the deconvolution preview. Mirrors
/// native `deconvolution::PsfKind` (the `PsfArgs.kind` / `PsfReport.kind` wire
/// token `"empirical"` / `"moffat"` / `"gaussian"`).
enum PsfKind {
  /// PSF stacked from the frame's own stars (the native default; only available
  /// when `estimatePsf` is true).
  empirical,

  /// Analytic Moffat profile (heavier wings — closer to real seeing).
  moffat,

  /// Analytic Gaussian profile.
  gaussian;

  String get wire {
    switch (this) {
      case PsfKind.empirical:
        return 'empirical';
      case PsfKind.moffat:
        return 'moffat';
      case PsfKind.gaussian:
        return 'gaussian';
    }
  }

  static PsfKind fromWire(String value) {
    switch (value) {
      case 'empirical':
        return PsfKind.empirical;
      case 'moffat':
        return PsfKind.moffat;
      case 'gaussian':
        return PsfKind.gaussian;
      default:
        throw ArgumentError.value(value, 'value', 'unknown PsfKind');
    }
  }
}

/// Star-size-reduction algorithm. Mirrors native
/// `star_reduction::StarReduceMethod` (the `ReduceStarsConfigArgs.method` wire
/// token — the native side accepts both the snake_case `"screened_residual"` /
/// `"morphological_erosion"` and their collapsed forms).
enum StarReduceMethod {
  /// Greyscale morphological erosion confined to the star mask.
  morphologicalErosion,

  /// Screened residual subtraction (the native default — gentler on faint
  /// stars).
  screenedResidual;

  String get wire {
    switch (this) {
      case StarReduceMethod.morphologicalErosion:
        return 'morphological_erosion';
      case StarReduceMethod.screenedResidual:
        return 'screened_residual';
    }
  }

  static StarReduceMethod fromWire(String value) {
    switch (value) {
      // Accept the canonical snake_case and the collapsed/camel forms the
      // native parser also tolerates.
      case 'morphological_erosion':
      case 'morphologicalErosion':
        return StarReduceMethod.morphologicalErosion;
      case 'screened_residual':
      case 'screenedResidual':
        return StarReduceMethod.screenedResidual;
      default:
        throw ArgumentError.value(value, 'value', 'unknown StarReduceMethod');
    }
  }
}

/// Narrowband palette mix. `sho` / `hoo` mirror the native canonical weight
/// tables (`channel_combine::{sho_palette, hoo_palette}` via the
/// `CombineChannelsArgs.palette` wire token); `custom` carries explicit
/// per-channel weights, and `none` leaves the master in its native colour.
enum NarrowbandPalette {
  /// No palette mix (default — broadband / OSC colour).
  none,

  /// SHO (Hubble): S II→R, Hα→G, O III→B.
  sho,

  /// HOO (bicolour): Hα→R, O III→G+B.
  hoo,

  /// Caller-supplied per-input `[r, g, b]` weight triples ([customWeights]).
  custom;

  String get wire {
    switch (this) {
      case NarrowbandPalette.none:
        return 'none';
      case NarrowbandPalette.sho:
        return 'sho';
      case NarrowbandPalette.hoo:
        return 'hoo';
      case NarrowbandPalette.custom:
        return 'custom';
    }
  }

  static NarrowbandPalette fromWire(String value) {
    switch (value) {
      case 'none':
        return NarrowbandPalette.none;
      case 'sho':
        return NarrowbandPalette.sho;
      case 'hoo':
        return NarrowbandPalette.hoo;
      case 'custom':
        return NarrowbandPalette.custom;
      default:
        throw ArgumentError.value(value, 'value', 'unknown NarrowbandPalette');
    }
  }
}

/// Named smart-default presets for [IntegrationSettings].
///
/// Each preset is a curated point in the (speed ↔ quality) tradeoff space; the
/// [IntegrationSettings.preset] factory materialises one. `balanced` is the
/// app-wide default.
enum IntegrationPreset {
  /// Fast: bilinear resample, lighter weighting — for quick look / huge sub
  /// counts where the user accepts a sharpness hit for speed.
  fast,

  /// Balanced (default): Lanczos-3, SNR² weighting, auto rejection, global
  /// normalization. The everyday archival setting.
  balanced,

  /// Maximum quality: Lanczos-3, SNR² weighting, auto rejection, generates the
  /// rejection map, f32 output. (Distortion/drizzle remain off by default —
  /// they need real-data tuning, see the design doc's honest deferrals.)
  maximumQuality,

  /// Few subs (<8): percentile-clip rejection, which is robust when the sample
  /// column is too short for sigma statistics.
  fewSubs,

  /// Long night / moving gradient: local normalization grid to track sky-glow
  /// drift through the session.
  longNightGradient;

  /// Stable wire token for persistence.
  String get wire {
    switch (this) {
      case IntegrationPreset.fast:
        return 'fast';
      case IntegrationPreset.balanced:
        return 'balanced';
      case IntegrationPreset.maximumQuality:
        return 'maximumQuality';
      case IntegrationPreset.fewSubs:
        return 'fewSubs';
      case IntegrationPreset.longNightGradient:
        return 'longNightGradient';
    }
  }

  static IntegrationPreset? fromWire(String value) {
    for (final p in IntegrationPreset.values) {
      if (p.wire == value) return p;
    }
    return null;
  }

  /// Human-facing label.
  String get label {
    switch (this) {
      case IntegrationPreset.fast:
        return 'Fast';
      case IntegrationPreset.balanced:
        return 'Balanced';
      case IntegrationPreset.maximumQuality:
        return 'Maximum Quality';
      case IntegrationPreset.fewSubs:
        return 'Few Subs';
      case IntegrationPreset.longNightGradient:
        return 'Long Night / Gradient';
    }
  }
}
