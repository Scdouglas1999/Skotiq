part of '../imaging_models.dart';

/// Frame type for imaging
enum FrameType {
  light,
  dark,
  flat,
  bias,
  darkFlat,
  snapshot;

  String get displayName {
    switch (this) {
      case FrameType.light:
        return 'Light';
      case FrameType.dark:
        return 'Dark';
      case FrameType.flat:
        return 'Flat';
      case FrameType.bias:
        return 'Bias';
      case FrameType.darkFlat:
        return 'Dark Flat';
      case FrameType.snapshot:
        return 'Snapshot';
    }
  }
}

/// Bayer pattern for color cameras
enum BayerPattern {
  rggb,
  bggr,
  grbg,
  gbrg;

  String get displayName => name.toUpperCase();
}

/// Debayer algorithm
enum DebayerAlgorithm {
  bilinear,
  vng,
  superPixel;

  String get displayName {
    switch (this) {
      case DebayerAlgorithm.bilinear:
        return 'Bilinear (Fast)';
      case DebayerAlgorithm.vng:
        return 'VNG (Quality)';
      case DebayerAlgorithm.superPixel:
        return 'Super Pixel (2x2)';
    }
  }
}

/// Image statistics
class ImageStats extends Equatable {
  final double? hfr;
  final double? fwhm;

  /// Per-frame median star eccentricity (0.0 = round, →1.0 = trailed).
  /// `null` when the native detector could not honestly measure it (too few
  /// reliable stars) or the producing path ran no star detection — never a
  /// fabricated value.
  final double? eccentricity;
  final int? starCount;
  final double? median;
  final double? mean;
  final double? stdDev;
  final double? min;
  final double? max;
  final double? mad;
  final double? snr;
  final double? background;
  final double? noise;

  const ImageStats({
    this.hfr,
    this.fwhm,
    this.eccentricity,
    this.starCount,
    this.median,
    this.mean,
    this.stdDev,
    this.min,
    this.max,
    this.mad,
    this.snr,
    this.background,
    this.noise,
  });

  factory ImageStats.fromJson(Map<String, dynamic> json) {
    return ImageStats(
      hfr: (json['hfr'] as num?)?.toDouble(),
      fwhm: (json['fwhm'] as num?)?.toDouble(),
      eccentricity: (json['eccentricity'] as num?)?.toDouble(),
      starCount: json['starCount'] as int?,
      median: (json['median'] as num?)?.toDouble(),
      mean: (json['mean'] as num?)?.toDouble(),
      stdDev: (json['stdDev'] as num?)?.toDouble(),
      min: (json['min'] as num?)?.toDouble(),
      max: (json['max'] as num?)?.toDouble(),
      mad: (json['mad'] as num?)?.toDouble(),
      snr: (json['snr'] as num?)?.toDouble(),
      background: (json['background'] as num?)?.toDouble(),
      noise: (json['noise'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'hfr': hfr,
      'fwhm': fwhm,
      'eccentricity': eccentricity,
      'starCount': starCount,
      'median': median,
      'mean': mean,
      'stdDev': stdDev,
      'min': min,
      'max': max,
      'mad': mad,
      'snr': snr,
      'background': background,
      'noise': noise,
    };
  }

  @override
  List<Object?> get props => [
    hfr,
    fwhm,
    eccentricity,
    starCount,
    median,
    mean,
    stdDev,
    min,
    max,
    mad,
    snr,
    background,
    noise,
  ];
}

/// Detected star information
class DetectedStar extends Equatable {
  final double x;
  final double y;
  final double flux;
  final double hfr;
  final double fwhm;
  final double peak;
  final double background;
  final double snr;

  const DetectedStar({
    required this.x,
    required this.y,
    required this.flux,
    required this.hfr,
    required this.fwhm,
    required this.peak,
    required this.background,
    required this.snr,
  });

  @override
  List<Object?> get props => [x, y, flux, hfr, fwhm, peak, background, snr];
}

/// Star detection result
class StarDetectionResult extends Equatable {
  final List<DetectedStar> stars;
  final int starCount;
  final double medianHfr;
  final double medianFwhm;
  final double medianSnr;
  final double background;
  final double noise;

  const StarDetectionResult({
    required this.stars,
    required this.starCount,
    required this.medianHfr,
    required this.medianFwhm,
    required this.medianSnr,
    required this.background,
    required this.noise,
  });

  @override
  List<Object?> get props => [
    stars,
    starCount,
    medianHfr,
    medianFwhm,
    medianSnr,
    background,
    noise,
  ];
}

/// Stretch parameters for image display
class StretchParams extends Equatable {
  final double shadows;
  final double highlights;
  final double midtones;

  const StretchParams({
    this.shadows = 0.0,
    this.highlights = 1.0,
    this.midtones = 0.5,
  });

  StretchParams copyWith({
    double? shadows,
    double? highlights,
    double? midtones,
  }) {
    return StretchParams(
      shadows: shadows ?? this.shadows,
      highlights: highlights ?? this.highlights,
      midtones: midtones ?? this.midtones,
    );
  }

  @override
  List<Object?> get props => [shadows, highlights, midtones];
}
