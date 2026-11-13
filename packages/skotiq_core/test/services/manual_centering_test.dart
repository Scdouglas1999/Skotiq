import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';

void main() {
  test('manual centering takes the solve frame from the active profile', () {
    final centering = ManualCentering.of(
      const AppSettingsState(
        centeringSyncMount: false,
        plateSolveTimeout: 90,
        plateSolveSearchRadius: 12,
      ),
      const EquipmentProfileModel(
        name: 'Rig',
        defaultCenteringExposure: 4,
        defaultBinX: 3,
        defaultGain: 120,
        defaultOffset: 30,
      ),
    );

    expect(centering.config.exposureTime, 4);
    expect(centering.config.binning, 3);
    expect(centering.config.gain, 120);
    expect(centering.config.offset, 30);
    expect(centering.config.syncMount, isFalse);
    expect(centering.config.maxIterations, ManualCentering.maxIterations);
    expect(centering.config.toleranceArcsec, ManualCentering.toleranceArcsec);
    expect(centering.solver.timeoutSeconds, 90);
    expect(centering.solver.searchRadius, 12);
  });

  test('without a profile exposure the solve frame is 5 s at bin 2', () {
    final centering = ManualCentering.of(const AppSettingsState(), null);
    expect(centering.config.exposureTime, 5);
    expect(centering.config.binning, 2);
    expect(centering.config.gain, isNull);
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
