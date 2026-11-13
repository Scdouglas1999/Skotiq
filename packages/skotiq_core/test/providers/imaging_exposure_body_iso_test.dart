import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../harness/in_memory_database.dart';

final _canonSpeeds = IsoSensitivity(const [100, 200, 400, 800, 1600, 3200]);

ProviderContainer _container(ExposureSensitivity sensitivity) {
  return ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      activeEquipmentProfileProvider.overrideWithValue(
        const EquipmentProfileModel(id: 31, name: 'DSLR rig', defaultGain: 100),
      ),
      cameraSensitivityProvider.overrideWithValue(sensitivity),
    ],
  );
}

/// The camera connects and its first status read reports [gain].
void _connect(ProviderContainer container, int gain) {
  final camera = container.read(cameraStateProvider.notifier);
  camera.setConnecting('native:gphoto2:0:757362:canon_eos_6d', 'Canon EOS 6D');
  camera.setConnected();
  camera.updateReadout(gain: gain, offset: 0, binX: 1, binY: 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the ISO a DSLR body reports at connect becomes the capture ISO',
    () async {
      final container = _container(_canonSpeeds);
      addTearDown(container.dispose);
      container.read(syncExposureFromProfileProvider);
      await pumpEventQueue(times: 20);
      expect(container.read(exposureSettingsProvider).gain, 100);

      _connect(container, 800);
      await pumpEventQueue(times: 20);

      expect(container.read(exposureSettingsProvider).gain, 800);
    },
  );

  test('a body connected before the screen opens is read at once', () async {
    final container = _container(_canonSpeeds);
    addTearDown(container.dispose);
    _connect(container, 1600);

    container.read(syncExposureFromProfileProvider);
    await pumpEventQueue(times: 20);

    expect(container.read(exposureSettingsProvider).gain, 1600);
  });

  test(
    'an ISO picked after connect is not replaced by the next status read',
    () async {
      final container = _container(_canonSpeeds);
      addTearDown(container.dispose);
      container.read(syncExposureFromProfileProvider);
      await pumpEventQueue(times: 20);
      _connect(container, 800);
      await pumpEventQueue(times: 20);

      container
          .read(manualExposureSettingsUpdaterProvider)
          .update(
            container.read(exposureSettingsProvider).copyWith(gain: 3200),
          );
      container
          .read(cameraStateProvider.notifier)
          .updateReadout(gain: 800, offset: 0, binX: 1, binY: 1);
      await pumpEventQueue(times: 20);

      expect(container.read(exposureSettingsProvider).gain, 3200);
    },
  );

  test('a gain camera keeps the gain Skotiq sets', () async {
    final container = _container(const GainSensitivity(min: 0, max: 600));
    addTearDown(container.dispose);
    container.read(syncExposureFromProfileProvider);
    await pumpEventQueue(times: 20);

    _connect(container, 0);
    await pumpEventQueue(times: 20);

    expect(container.read(exposureSettingsProvider).gain, 100);
  });
}
