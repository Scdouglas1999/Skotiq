/// Image capture result types for Skotiq.
library;

/// Image statistics result
class ImageStatsResult {
  final double min;
  final double max;
  final double mean;
  final double median;
  final double stdDev;
  final double? hfr;

  /// Per-frame median star eccentricity (0.0 = round, →1.0 = trailed).
  /// `null` when the native detector could not honestly measure it (too few
  /// reliable stars) or the producing path ran no star detection.
  final double? eccentricity;
  final double? fwhm;
  final int starCount;

  const ImageStatsResult({
    required this.min,
    required this.max,
    required this.mean,
    required this.median,
    required this.stdDev,
    this.hfr,
    this.eccentricity,
    this.fwhm,
    required this.starCount,
  });

  /// Create from JSON (for network transport)
  factory ImageStatsResult.fromJson(Map<String, dynamic> json) {
    return ImageStatsResult(
      min: (json['min'] as num).toDouble(),
      max: (json['max'] as num).toDouble(),
      mean: (json['mean'] as num).toDouble(),
      median: (json['median'] as num).toDouble(),
      stdDev: (json['stdDev'] as num).toDouble(),
      hfr: json['hfr'] != null ? (json['hfr'] as num).toDouble() : null,
      eccentricity: json['eccentricity'] != null
          ? (json['eccentricity'] as num).toDouble()
          : null,
      fwhm: json['fwhm'] != null ? (json['fwhm'] as num).toDouble() : null,
      starCount: json['starCount'] as int,
    );
  }

  /// Convert to JSON (for network transport)
  Map<String, dynamic> toJson() => {
    'min': min,
    'max': max,
    'mean': mean,
    'median': median,
    'stdDev': stdDev,
    'hfr': hfr,
    'eccentricity': eccentricity,
    'fwhm': fwhm,
    'starCount': starCount,
  };
}

/// Captured image result from camera exposure
class CapturedImageResult {
  /// Image width in pixels
  final int width;

  /// Image height in pixels
  final int height;

  /// Display data, always RGBA (width*height*4 bytes, alpha=255).
  /// Conversion from RGB/grayscale is done in Rust for performance.
  final List<int> displayData;

  /// Histogram data (256 bins)
  final List<int> histogram;

  /// Image statistics
  final ImageStatsResult stats;

  /// Exposure time in seconds
  final double exposureTime;

  /// ISO 8601 timestamp when image was captured
  final String timestamp;

  /// True if source was color (RGB), false if grayscale. displayData is always RGBA.
  final bool isColor;

  const CapturedImageResult({
    required this.width,
    required this.height,
    required this.displayData,
    required this.histogram,
    required this.stats,
    required this.exposureTime,
    required this.timestamp,
    this.isColor = false,
  });

  /// Create from JSON (for network transport)
  factory CapturedImageResult.fromJson(Map<String, dynamic> json) {
    return CapturedImageResult(
      width: json['width'] as int,
      height: json['height'] as int,
      displayData: (json['displayData'] as List).cast<int>(),
      histogram: (json['histogram'] as List).cast<int>(),
      stats: ImageStatsResult.fromJson(json['stats'] as Map<String, dynamic>),
      exposureTime: (json['exposureTime'] as num).toDouble(),
      timestamp: json['timestamp'] as String,
      isColor: json['isColor'] as bool? ?? false,
    );
  }

  /// Convert to JSON (for network transport)
  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'displayData': displayData,
    'histogram': histogram,
    'stats': stats.toJson(),
    'exposureTime': exposureTime,
    'timestamp': timestamp,
    'isColor': isColor,
  };
}
