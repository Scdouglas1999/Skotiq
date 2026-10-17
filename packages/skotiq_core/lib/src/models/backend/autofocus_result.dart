/// Autofocus result types.
///
/// These types mirror the Rust autofocus structs but are pure Dart types.
library;

/// A single focus data point (position and HFR)
class FocusDataPoint {
  final int position;
  final double hfr;
  final double? fwhm;
  final int starCount;

  const FocusDataPoint({
    required this.position,
    required this.hfr,
    this.fwhm,
    required this.starCount,
  });

  factory FocusDataPoint.fromJson(Map<String, dynamic> json) {
    return FocusDataPoint(
      position: json['position'] as int,
      hfr: (json['hfr'] as num).toDouble(),
      fwhm: (json['fwhm'] as num?)?.toDouble(),
      starCount: json['starCount'] as int? ?? json['star_count'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'position': position,
    'hfr': hfr,
    'fwhm': fwhm,
    'starCount': starCount,
  };
}

/// Autofocus result containing all data for display and analysis
class AutofocusResult {
  final int bestPosition;
  final double bestHfr;
  final List<FocusDataPoint> focusData;
  final String method;
  final double? temperature;
  final int timestamp;
  final double curveFitQuality;
  final bool backlashApplied;

  const AutofocusResult({
    required this.bestPosition,
    required this.bestHfr,
    required this.focusData,
    required this.method,
    this.temperature,
    required this.timestamp,
    required this.curveFitQuality,
    required this.backlashApplied,
  });

  factory AutofocusResult.fromJson(Map<String, dynamic> json) {
    return AutofocusResult(
      bestPosition:
          json['bestPosition'] as int? ?? json['best_position'] as int,
      bestHfr: (json['bestHfr'] as num? ?? json['best_hfr'] as num).toDouble(),
      focusData: (json['focusData'] as List? ?? json['focus_data'] as List)
          .map((e) => FocusDataPoint.fromJson(e as Map<String, dynamic>))
          .toList(),
      method: json['method'] as String,
      temperature: (json['temperature'] as num?)?.toDouble(),
      timestamp: json['timestamp'] as int,
      curveFitQuality:
          (json['curveFitQuality'] as num? ?? json['curve_fit_quality'] as num)
              .toDouble(),
      backlashApplied:
          json['backlashApplied'] as bool? ??
          json['backlash_applied'] as bool? ??
          false,
    );
  }

  Map<String, dynamic> toJson() => {
    'bestPosition': bestPosition,
    'bestHfr': bestHfr,
    'focusData': focusData.map((e) => e.toJson()).toList(),
    'method': method,
    'temperature': temperature,
    'timestamp': timestamp,
    'curveFitQuality': curveFitQuality,
    'backlashApplied': backlashApplied,
  };

  /// Check if this is a good focus result
  bool get isGoodFocus => curveFitQuality > 0.9;
}

/// Autofocus configuration
class AutofocusConfig {
  final double exposureTime;
  final int stepSize;
  final int stepsOut;
  final String method; // "VCurve", "Hyperbolic", "Parabolic"
  final int binning;

  const AutofocusConfig({
    required this.exposureTime,
    required this.stepSize,
    required this.stepsOut,
    required this.method,
    required this.binning,
  });

  factory AutofocusConfig.fromJson(Map<String, dynamic> json) {
    return AutofocusConfig(
      exposureTime:
          (json['exposureTime'] as num? ?? json['exposure_time'] as num)
              .toDouble(),
      stepSize: json['stepSize'] as int? ?? json['step_size'] as int,
      stepsOut: json['stepsOut'] as int? ?? json['steps_out'] as int,
      method: json['method'] as String,
      binning: json['binning'] as int,
    );
  }

  Map<String, dynamic> toJson() => {
    'exposureTime': exposureTime,
    'stepSize': stepSize,
    'stepsOut': stepsOut,
    'method': method,
    'binning': binning,
  };
}
