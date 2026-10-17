import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/imaging_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/session_optimizer_provider.dart';
import 'package:skotiq_core/src/services/session_optimizer_service.dart';
import 'package:skotiq_core/src/services/smart_night/exposure_calculator.dart';
import '../harness/in_memory_database.dart';

/// A pure-value Smart Night context used as the recommendation source. The
/// physics model rounds the recommendation to a clean value; with this rig the
/// floor (30 s) dominates, so [SmartNightExposureContext.recommendForFilter]
/// returns 30 s for the default (null) filter.
const _seedContext = SmartNightExposureContext(
  camera: CameraExposureSpec(readNoiseE: 1.4, fullWellE: 50000, qePeak: 0.85),
  bortleClass: 8,
  focalLengthMm: 384,
  apertureMm: 80,
  pixelSizeMicrons: 3.76,
  userCapSeconds: 240,
  floorSeconds: 30,
);

/// Builds a container wired with an active profile and a Smart Night context.
///
/// [defaultGain]/[defaultOffset] populate the profile so the gain/offset
/// seeding branch has values to push; [withContext] toggles whether the Smart
/// Night recommendation is available.
ProviderContainer _buildContainer({
  required int profileId,
  int? defaultGain,
  int? defaultOffset,
  bool withContext = true,
}) {
  return ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      activeEquipmentProfileProvider.overrideWithValue(
        EquipmentProfileModel(
          id: profileId,
          name: 'Test rig',
          focalLength: 384,
          aperture: 80,
          defaultGain: defaultGain,
          defaultOffset: defaultOffset,
        ),
      ),
      smartNightExposureContextProvider.overrideWith(
        (ref) async => withContext ? _seedContext : null,
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'seeds safe exposure and profile camera defaults when no snapshot is saved',
    () async {
      final container = _buildContainer(
        profileId: 11,
        defaultGain: 200,
        defaultOffset: 30,
      );
      addTearDown(container.dispose);

      expect(
        container.read(exposureSettingsUserDirtyProvider),
        isFalse,
        reason: 'dirty flag must default to false',
      );

      container.read(syncExposureFromProfileProvider);
      await pumpEventQueue(times: 20);

      final settings = container.read(exposureSettingsProvider);
      expect(settings.gain, 200, reason: 'profile defaultGain should seed');
      expect(settings.offset, 30, reason: 'profile defaultOffset should seed');
      expect(settings.frameType, FrameType.light);
      expect(
        settings.exposureTime,
        2,
        reason: 'manual imaging must use the safe cold-start exposure',
      );
    },
  );

  test(
    'manual values are preserved when profile hydration races the edit',
    () async {
      final container = _buildContainer(
        profileId: 12,
        defaultGain: 200,
        defaultOffset: 30,
      );
      addTearDown(container.dispose);

      // Simulate a manual edit through the same explicit persistence path used
      // by the capture controls.
      container
          .read(manualExposureSettingsUpdaterProvider)
          .update(
            container
                .read(exposureSettingsProvider)
                .copyWith(exposureTime: 45, gain: 77, offset: 11),
          );

      container.read(syncExposureFromProfileProvider);
      await pumpEventQueue(times: 20);

      final settings = container.read(exposureSettingsProvider);
      expect(settings.exposureTime, 45, reason: 'manual exposure preserved');
      expect(
        settings.gain,
        77,
        reason: 'manual gain preserved (no profile seed)',
      );
      expect(
        settings.offset,
        11,
        reason: 'manual offset preserved (no profile seed)',
      );
    },
  );

  test(
    'the cold-start value is no longer the historical 120 seconds',
    () async {
      final container = _buildContainer(profileId: 13);
      addTearDown(container.dispose);

      expect(
        container.read(exposureSettingsProvider).exposureTime,
        2,
        reason: 'sanity: snapshot default is short and safe',
      );

      container.read(syncExposureFromProfileProvider);
      await pumpEventQueue(times: 20);

      expect(
        container.read(exposureSettingsProvider).exposureTime,
        2,
        reason: 'manual imaging does not apply Smart Night recommendations',
      );
    },
  );
}
