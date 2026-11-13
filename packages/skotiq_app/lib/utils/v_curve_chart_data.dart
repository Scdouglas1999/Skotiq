import 'package:skotiq_core/models.dart' show FocusRange, VCurvePoint;
import 'package:skotiq_ui/skotiq_ui.dart'
    show VCurvePositionRange, VCurveSample;

/// The one place autofocus measurements become what the V-curve chart draws.
extension VCurvePointChartSamples on Iterable<VCurvePoint> {
  List<VCurveSample> toChartSamples() => [
        for (final point in this)
          VCurveSample(
            position: point.position,
            hfr: point.hfr,
            isRejected: point.isRejected,
          ),
      ];
}

extension FocusRangeChartRange on FocusRange {
  VCurvePositionRange toChartRange() => VCurvePositionRange(min: min, max: max);
}
