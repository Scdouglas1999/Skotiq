import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';

void main() {
  test('manual centering takes the solve frame from the active profile', () {
    final centering = ManualCentering.of(
      const AppSettingsState(centeringSyncMount: false),
      const EquipmentProfileModel(name: 'Rig', defaultCenteringExposure: 4),
    );

    expect(centering.config.exposureTime, 4);
    expect(centering.config.syncMount, isFalse);
    expect(centering.config.maxIterations, ManualCentering.maxIterations);
    expect(centering.config.toleranceArcsec, ManualCentering.toleranceArcsec);
  });

  test('without a profile exposure the solve frame is 5 s', () {
    final centering = ManualCentering.of(const AppSettingsState(), null);
    expect(centering.config.exposureTime, 5);
  });

  test('a typed exposure replaces the profile one', () {
    final centering = ManualCentering.of(
      const AppSettingsState(),
      const EquipmentProfileModel(name: 'Rig', defaultCenteringExposure: 4),
      exposureSeconds: 1.5,
    );
    expect(centering.config.exposureTime, 1.5);
  });
}
