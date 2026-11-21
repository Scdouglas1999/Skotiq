import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/flat_wizard/flat_failure_diagnosis.dart';
import 'package:skotiq_core/models.dart';

void main() {
  FlatWizardState failed({
    required double min,
    required double max,
    double? minOverride,
    double? maxOverride,
    double? targetOverride,
    required double lastExposure,
    double globalTarget = 50,
  }) {
    return FlatWizardState(
      globalSettings: FlatWizardGlobalSettings(
        minExposure: min,
        maxExposure: max,
        histogramTarget: globalTarget,
      ),
      filterSettings: [
        FlatFilterSettings(
          filterName: 'Ha',
          filterPosition: 0,
          status: FilterCalibrationStatus.failed,
          minExposureOverride: minOverride,
          maxExposureOverride: maxOverride,
          histogramTargetOverride: targetOverride,
        ),
      ],
      aduHistory: [
        AduMeasurement(
          exposure: lastExposure,
          adu: 1000,
          timestamp: DateTime.utc(2026, 11, 1),
        ),
      ],
    );
  }

  test('a pinned filter names its own exposure, not the global maximum', () {
    final result = diagnoseFlatFailure(
      failed(
        min: 0.001,
        max: 30,
        minOverride: 2,
        maxOverride: 2,
        targetOverride: 40,
        lastExposure: 2,
      ),
    );
    expect(result, isNotNull);
    expect(result!.reason, contains('2.00'));
    expect(result.reason, contains('fixed'));
    expect(result.reason, isNot(contains('30')));
    expect(result.reason, contains('40%'));
    expect(result.reason, isNot(contains('50%')));
  });

  test('a filter with no overrides still names the global maximum', () {
    final result = diagnoseFlatFailure(
      failed(min: 0.001, max: 30, lastExposure: 30),
    );
    expect(result, isNotNull);
    expect(result!.reason, contains('30.0'));
    expect(result.reason, contains('maximum'));
    expect(result.reason, isNot(contains('fixed')));
  });
}
