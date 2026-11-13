/// Value type mirroring the `api_color_calibrate` JSON result — the solved
/// per-channel white balance applied to a master and the written calibrated
/// FITS path.
///
/// Pure, immutable value type with `fromJson`/`toJson` round-trip and value
/// equality, mirroring the native `ColorCalibrateResult` (camelCase via serde
/// `rename_all`). Decoded defensively (nullable + defaults) so a partial payload
/// never throws.
library;

/// The result of a per-channel colour calibration solve + apply. Mirrors the
/// native `ColorCalibrateResult`.
import '../../utils/json_validation.dart';

class ColorCalibrationResult {
  /// Path of the written calibrated master.
  final String outputPath;

  /// The solved per-channel scale factors, in channel order.
  final List<double> channelScale;

  /// Number of matched stars that informed the solve.
  final int matched;

  /// Robust RMS of the per-channel fit residuals (log10-flux units).
  final double residual;

  const ColorCalibrationResult({
    required this.outputPath,
    required this.channelScale,
    required this.matched,
    required this.residual,
  });

  factory ColorCalibrationResult.fromJson(Map<String, dynamic> json) {
    return ColorCalibrationResult(
      outputPath: json['outputPath'] is String
          ? json['outputPath'] as String
          : '',
      channelScale: lenientDoubleList(json['channelScale']),
      matched: lenientInt(json['matched']),
      residual: lenientDouble(json['residual']),
    );
  }

  Map<String, dynamic> toJson() => {
    'outputPath': outputPath,
    'channelScale': channelScale,
    'matched': matched,
    'residual': residual,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ColorCalibrationResult &&
          other.outputPath == outputPath &&
          _listEquals(other.channelScale, channelScale) &&
          other.matched == matched &&
          other.residual == residual;

  @override
  int get hashCode =>
      Object.hash(outputPath, Object.hashAll(channelScale), matched, residual);
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
