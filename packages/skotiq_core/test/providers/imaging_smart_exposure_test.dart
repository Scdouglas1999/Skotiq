import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/imaging_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/session_optimizer_provider.dart';
import 'package:skotiq_core/src/services/session_optimizer_service.dart';
import 'package:skotiq_core/src/services/smart_night/exposure_calculator.dart';
import '../harness/in_memory_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('manual imaging starts with a short safe exposure', () async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Test rig',
            focalLength: 384,
            aperture: 80,
            defaultGain: 100,
            defaultOffset: 50,
          ),
        ),
        smartNightExposureContextProvider.overrideWith(
          (ref) async => const SmartNightExposureContext(
            camera: CameraExposureSpec(
              readNoiseE: 1.4,
              fullWellE: 50000,
              qePeak: 0.85,
            ),
            bortleClass: 8,
            focalLengthMm: 384,
            apertureMm: 80,
            pixelSizeMicrons: 3.76,
            userCapSeconds: 240,
            floorSeconds: 30,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(syncExposureFromProfileProvider);
    await Future<void>.delayed(Duration.zero);

    final settings = container.read(exposureSettingsProvider);
    expect(settings.frameType, FrameType.light);
    expect(settings.exposureTime, 2);
    expect(settings.gain, 100);
    expect(settings.offset, 50);
  });

  test('manual imaging does not consume Smart Night recommendations', () async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 8,
            name: 'Test rig',
            focalLength: 384,
            aperture: 80,
          ),
        ),
        smartNightExposureContextProvider.overrideWith(
          (ref) async => const SmartNightExposureContext(
            camera: CameraExposureSpec(
              readNoiseE: 1.4,
              fullWellE: 50000,
              qePeak: 0.85,
            ),
            bortleClass: 8,
            focalLengthMm: 384,
            apertureMm: 80,
            pixelSizeMicrons: 3.76,
            userCapSeconds: 240,
            floorSeconds: 30,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(manualExposureSettingsUpdaterProvider)
        .update(
          container.read(exposureSettingsProvider).copyWith(exposureTime: 45),
        );
    container.read(syncExposureFromProfileProvider);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(exposureSettingsProvider).exposureTime, 45);
  });
}
