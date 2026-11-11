import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

ScienceFrameQualityMetricsRow _row(double uniformityCv) =>
    ScienceFrameQualityMetricsRow(
      id: 1,
      timestamp: DateTime(2026, 11, 11, 8, 21),
      median: 2561,
      mean: 2562,
      stdDev: 42,
      mad: 0,
      background: 2561,
      noise: 5.9,
      snr: 0,
      dynamicRangeP1P99: 19,
      lowClipPercent: 0,
      highClipPercent: 0,
      uniformityCv: uniformityCv,
      gradientX: 0,
      gradientY: 0,
      processingTier: 'deferred',
      processingMs: 48,
    );

/// UX walk 2, F36: the Science tile showed "Uniformity CV 0.000", a zero the
/// native map reports when it could not measure, beside "—" tiles.
void main() {
  test('an unmeasured uniformity is null, a measured one is kept', () {
    expect(_row(0).measuredUniformityCv, isNull);
    expect(_row(double.nan).measuredUniformityCv, isNull);
    expect(_row(0.042).measuredUniformityCv, 0.042);
  });
}
