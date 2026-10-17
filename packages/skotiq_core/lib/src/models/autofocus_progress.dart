import 'dart:convert';
import 'dart:typed_data';

/// Progress data for autofocus operations, including V-curve points and star crops
class AutofocusProgressData {
  final int point;
  final int totalPoints;
  final double hfr;
  final int starCount;
  final FocusRange focusRange;
  final List<VCurvePoint> vcurvePoints;
  final List<StarCrop> starCrops;

  const AutofocusProgressData({
    required this.point,
    required this.totalPoints,
    required this.hfr,
    required this.starCount,
    required this.focusRange,
    required this.vcurvePoints,
    required this.starCrops,
  });

  /// Try to parse structured autofocus progress data from the progress detail string
  /// Returns null if the string is not valid JSON or not autofocus progress data
  static AutofocusProgressData? tryParse(String detail) {
    try {
      final json = jsonDecode(detail) as Map<String, dynamic>;
      if (json['type'] != 'autofocus_progress') {
        return null;
      }
      return AutofocusProgressData.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  factory AutofocusProgressData.fromJson(Map<String, dynamic> json) {
    return AutofocusProgressData(
      point: json['point'] as int,
      totalPoints: json['total_points'] as int,
      hfr: (json['hfr'] as num).toDouble(),
      starCount: json['star_count'] as int,
      focusRange: FocusRange.fromJson(
        json['focus_range'] as Map<String, dynamic>,
      ),
      vcurvePoints: (json['vcurve_points'] as List<dynamic>)
          .map((e) => VCurvePoint.fromJson(e as Map<String, dynamic>))
          .toList(),
      starCrops: (json['star_crops'] as List<dynamic>)
          .map((e) => StarCrop.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Get the minimum HFR from the V-curve points
  double get minHfr => vcurvePoints.isEmpty
      ? 0.0
      : vcurvePoints.map((p) => p.hfr).reduce((a, b) => a < b ? a : b);

  /// Get the maximum HFR from the V-curve points
  double get maxHfr => vcurvePoints.isEmpty
      ? 0.0
      : vcurvePoints.map((p) => p.hfr).reduce((a, b) => a > b ? a : b);
}

/// Focus position range for the autofocus run
class FocusRange {
  final int min;
  final int max;

  const FocusRange({required this.min, required this.max});

  factory FocusRange.fromJson(Map<String, dynamic> json) {
    return FocusRange(min: json['min'] as int, max: json['max'] as int);
  }
}

/// A single point on the V-curve
class VCurvePoint {
  final int position;
  final double hfr;

  const VCurvePoint({required this.position, required this.hfr});

  factory VCurvePoint.fromJson(Map<String, dynamic> json) {
    return VCurvePoint(
      position: json['position'] as int,
      hfr: (json['hfr'] as num).toDouble(),
    );
  }
}

/// A cropped star image for display in the UI
class StarCrop {
  final String pixelsBase64;
  final int width;
  final int height;
  final double hfr;
  final double snr;

  const StarCrop({
    required this.pixelsBase64,
    required this.width,
    required this.height,
    required this.hfr,
    required this.snr,
  });

  factory StarCrop.fromJson(Map<String, dynamic> json) {
    return StarCrop(
      pixelsBase64: json['pixels_base64'] as String,
      width: json['width'] as int,
      height: json['height'] as int,
      hfr: (json['hfr'] as num).toDouble(),
      snr: (json['snr'] as num).toDouble(),
    );
  }

  /// Decode the base64 pixels to a Uint8List for display
  Uint8List get pixels => base64Decode(pixelsBase64);
}
