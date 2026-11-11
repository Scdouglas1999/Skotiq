import '../../database/database.dart' show ScienceFrameQualityMetricsRow;

extension FrameQualityReadings on ScienceFrameQualityMetricsRow {
  /// The field-uniformity CV, or null when it was not measured: the native
  /// quality map reports 0 when the frame has no background to scale the
  /// spread by, and a real sky is never exactly flat.
  double? get measuredUniformityCv =>
      uniformityCv.isFinite && uniformityCv > 0 ? uniformityCv : null;
}
