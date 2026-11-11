import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/flat_wizard/widgets/flat_preview_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

FlatWizardState _state(FilterCalibrationStatus status, {int captured = 1}) =>
    FlatWizardState(
      globalSettings: const FlatWizardGlobalSettings(frameCount: 30),
      filterSettings: [
        FlatFilterSettings(
          filterName: 'L',
          filterPosition: 0,
          status: status,
          capturedCount: captured,
        ),
      ],
      currentExposureDuration: 7.18,
    );

void main() {
  test('while frames are taken it says which frame and how long is left', () {
    expect(
      flatExposureProgressLine(
        _state(FilterCalibrationStatus.capturing),
        2.7,
      ),
      'Frame 2 of 30 · 2.7 s left · about 3m to go',
    );
  });

  test('the last frame has no time to go after it', () {
    expect(
      flatExposureProgressLine(
        _state(FilterCalibrationStatus.capturing, captured: 29),
        1.0,
      ),
      'Frame 30 of 30 · 1.0 s left',
    );
  });

  test('while the exposure is being found it says so', () {
    expect(
      flatExposureProgressLine(
        _state(FilterCalibrationStatus.calibrating, captured: 0),
        0.4,
      ),
      'Finding the exposure · 0.4 s left',
    );
  });
}
