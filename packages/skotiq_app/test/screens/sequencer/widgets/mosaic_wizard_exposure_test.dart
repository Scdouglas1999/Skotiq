import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mosaic_wizard_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('mosaic wizard exposure settings use Smart Night recommendation', () {
    const exposureContext = SmartNightExposureContext(
      camera: CameraExposureSpec(
        readNoiseE: 1.4,
        fullWellE: 50000,
        qePeak: 0.85,
      ),
      bortleClass: 8,
      focalLengthMm: 384,
      apertureMm: 80,
      pixelSizeMicrons: 3.76,
      availableFilterNames: ['L'],
      userCapSeconds: 240,
      floorSeconds: 30,
    );

    final settings = mosaicWizardExposureSettingsForContext(exposureContext);

    expect(settings.exposureSeconds, 30);
    expect(settings.exposuresPerPanel, 10);
    expect(settings.filterName, 'L');
  });
}
